import AVFoundation
import CoreAudio

/// Graba el audio que suena en el Mac (las otras personas de la reunión) con un "process tap" de Core Audio.
/// No necesita meter un bot en la llamada: escucha la mezcla de audio del sistema.
final class SystemAudioRecorder: @unchecked Sendable {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var file: AVAudioFile?
    private let queue = DispatchQueue(label: "cl.guruvic.eco.system-audio", qos: .userInitiated)
    private let fileLock = NSLock()

    func start(writingTo url: URL) throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.name = "Eco"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(description, &tap), "crear la captura de audio")
        tapID = tap

        let outputUID = try Self.defaultOutputDeviceUID()
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Eco reunión",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        var aggregateDevice = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateDevice), "crear el dispositivo de audio")
        aggregateID = aggregateDevice

        var streamDescription = try Self.tapFormat(tap)
        guard let format = AVAudioFormat(streamDescription: &streamDescription) else {
            throw RecordingError.failed("No se reconoce el formato del audio del sistema.")
        }
        file = try AVAudioFile(
            forWriting: url,
            settings: MeetingAudio.fileSettings(sampleRate: format.sampleRate, channels: format.channelCount),
            commonFormat: .pcmFormatFloat32,
            interleaved: format.isInterleaved
        )

        var proc: AudioDeviceIOProcID?
        try check(AudioDeviceCreateIOProcIDWithBlock(&proc, aggregateDevice, queue) { [weak self] _, input, _, _, _ in
            guard let self,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil)
            else { return }
            self.fileLock.withLock { try? self.file?.write(from: buffer) }
        }, "leer el audio del sistema")
        procID = proc
        try check(AudioDeviceStart(aggregateDevice, proc), "empezar a grabar el audio del sistema")
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        fileLock.withLock { file = nil }
    }

    private func check(_ status: OSStatus, _ action: String) throws {
        guard status == noErr else {
            stop()
            throw RecordingError.failed("No se pudo \(action) (código \(status)).")
        }
    }

    private static func tapFormat(_ tap: AudioObjectID) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var description = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &description)
        guard status == noErr else { throw RecordingError.failed("No se pudo leer el formato del audio del sistema.") }
        return description
    }

    private static func defaultOutputDeviceUID() throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == noErr else {
            throw RecordingError.failed("No se encontró la salida de audio del Mac.")
        }
        address.mSelector = kAudioDevicePropertyDeviceUID
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uid) == noErr, let uid else {
            throw RecordingError.failed("No se encontró la salida de audio del Mac.")
        }
        return uid.takeRetainedValue() as String
    }
}

/// Graba el micrófono a un archivo durante una reunión, con cancelación de eco
/// para no captar de nuevo lo que sale por los parlantes.
final class MicrophoneFileRecorder: @unchecked Sendable {
    private var engine: AVAudioEngine?
    private var file: AVAudioFile?
    private let fileLock = NSLock()

    func start(writingTo url: URL) throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        do {
            try input.setVoiceProcessingEnabled(true)
            input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
        } catch {
            NSLog("Eco: no se pudo activar la cancelación de eco: \(error)")
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw EcoError.noMicrophone }

        let file = try AVAudioFile(
            forWriting: url,
            settings: MeetingAudio.fileSettings(sampleRate: format.sampleRate, channels: format.channelCount),
            commonFormat: .pcmFormatFloat32,
            interleaved: format.isInterleaved
        )
        self.file = file
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.fileLock.withLock { try? self.file?.write(from: buffer) }
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
    }

    func stop() {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        fileLock.withLock { file = nil }
    }
}

enum MeetingAudio {
    /// AAC dentro de CAF: ocupa poco (~30 MB por hora) y el archivo sigue legible si la app se cierra de golpe.
    static func fileSettings(sampleRate: Double, channels: AVAudioChannelCount) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: 48_000 * Int(channels),
        ]
    }
}

enum RecordingError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let message): return message
        }
    }
}
