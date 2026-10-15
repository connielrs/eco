import AVFoundation
import CoreAudio

/// Graba el audio que suena en el Mac (las otras personas de la reunión) con un "process tap" de Core Audio.
/// No necesita meter un bot en la llamada: escucha la mezcla de audio del sistema.
final class SystemAudioRecorder: @unchecked Sendable {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var writer: MonoFileWriter?
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
        let writer = try MonoFileWriter(url: url, sourceSampleRate: format.sampleRate, mix: .average)
        fileLock.withLock { self.writer = writer }

        var proc: AudioDeviceIOProcID?
        try check(AudioDeviceCreateIOProcIDWithBlock(&proc, aggregateDevice, queue) { [weak self] _, input, _, _, _ in
            guard let self,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil)
            else { return }
            self.fileLock.withLock { self.writer }?.write(buffer)
        }, "leer el audio del sistema")
        procID = proc
        try check(AudioDeviceStart(aggregateDevice, proc), "empezar a grabar el audio del sistema")
    }

    /// Volumen máximo grabado hasta ahora (0 si el audio del Mac estuvo en silencio).
    var peak: Float { fileLock.withLock { writer?.peak ?? 0 } }

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
        fileLock.withLock { writer = nil }
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

/// Graba el micrófono a un archivo durante una reunión.
///
/// Usa `AVAudioRecorder` y no `AVAudioEngine`: el motor de audio también abre la salida de los parlantes
/// y, al hacerlo, la captura del audio del Mac queda en silencio. Por la misma razón no se usa la
/// cancelación de eco; el eco que capte el micrófono se descarta después, al juntar las dos pistas.
final class MicrophoneFileRecorder: @unchecked Sendable {
    private var recorder: AVAudioRecorder?

    func start(writingTo url: URL) throws {
        let recorder = try AVAudioRecorder(url: url, settings: MeetingAudio.fileSettings(sampleRate: 16_000, channels: 1))
        guard recorder.record() else { throw EcoError.noMicrophone }
        self.recorder = recorder
    }

    func stop() {
        recorder?.stop()
        recorder = nil
    }
}

/// Escribe audio de reunión en mono a 16 kHz (AAC en CAF), sin importar cuántos canales traiga la fuente.
/// El micrófono con cancelación de eco llega con 9 canales y el audio del Mac en estéreo; el formato
/// comprimido no acepta todos esos canales, así que antes se convierte a un solo canal.
final class MonoFileWriter: @unchecked Sendable {
    enum Mix {
        /// Solo el primer canal (el micrófono con cancelación de eco deja la voz en el canal 0).
        case firstChannel
        /// Promedio de todos los canales (audio estéreo del Mac).
        case average
    }

    private let file: AVAudioFile
    private let mix: Mix
    private let monoSource: AVAudioFormat
    private let target: AVAudioFormat
    private let converter: AVAudioConverter
    private let lock = NSLock()
    private var reportedError = false
    private(set) var framesWritten: AVAudioFramePosition = 0
    /// Volumen máximo escrito (0 a 1). Si queda en 0, la fuente estuvo en silencio.
    private(set) var peak: Float = 0

    init(url: URL, sourceSampleRate: Double, mix: Mix) throws {
        guard let monoSource = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sourceSampleRate, channels: 1, interleaved: false),
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: monoSource, to: target)
        else { throw RecordingError.failed("No se pudo preparar el formato de grabación.") }
        self.monoSource = monoSource
        self.target = target
        self.converter = converter
        self.mix = mix
        file = try AVAudioFile(
            forWriting: url,
            settings: MeetingAudio.fileSettings(sampleRate: 16_000, channels: 1),
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frames > 0, channels > 0, let data = buffer.floatChannelData,
              let mono = AVAudioPCMBuffer(pcmFormat: monoSource, frameCapacity: AVAudioFrameCount(frames)),
              let out = mono.floatChannelData?[0]
        else { return }
        mono.frameLength = AVAudioFrameCount(frames)

        // Juntar los canales en uno, sirva el buffer intercalado o por canal.
        let interleaved = buffer.format.isInterleaved
        let stride = buffer.stride
        let used = mix == .firstChannel ? 1 : channels
        for frame in 0..<frames {
            var sum: Float = 0
            for channel in 0..<used {
                sum += interleaved ? data[0][frame * stride + channel] : data[channel][frame]
            }
            out[frame] = sum / Float(used)
        }
        var bufferPeak: Float = 0
        for frame in 0..<frames { bufferPeak = max(bufferPeak, abs(out[frame])) }

        let capacity = AVAudioFrameCount(Double(frames) * target.sampleRate / monoSource.sampleRate) + 32
        guard let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var consumed = false
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return mono
        }
        lock.withLock {
            do {
                if let error { throw error }
                try file.write(from: converted)
                framesWritten += AVAudioFramePosition(converted.frameLength)
                peak = max(peak, bufferPeak)
            } catch {
                if !reportedError {
                    reportedError = true
                    NSLog("Eco: no se pudo escribir el audio de la reunión: \(error)")
                }
            }
        }
    }
}

enum MeetingAudio {
    /// AAC dentro de CAF: ocupa poco (~15 MB por hora en mono) y el archivo sigue legible si la app se cierra de golpe.
    static func fileSettings(sampleRate: Double, channels: AVAudioChannelCount) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: 32_000 * Int(channels),
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
