import AVFoundation

/// Graba el micrófono y lo deja en el formato que necesita Whisper (16 kHz, mono).
final class AudioRecorder: @unchecked Sendable {
    static let sampleRate: Double = 16_000

    /// Nivel de la voz entre 0 y 1, para dibujar la onda.
    var onLevel: ((Float) -> Void)?

    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var configurationObserver: NSObjectProtocol?
    private let lock = NSLock()
    private var samples: [Float] = []
    private let target = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: AudioRecorder.sampleRate, channels: 1, interleaved: false
    )!

    func start() throws {
        lock.withLock { samples.removeAll(keepingCapacity: true) }
        try startEngine()
    }

    private func startEngine() throws {
        // Un motor nuevo en cada grabación toma siempre el micrófono elegido en el sistema.
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw EcoError.noMicrophone }
        converter = AVAudioConverter(from: format, to: target)

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        engine.prepare()
        try engine.start()
        self.engine = engine

        // Si macOS cambia el micrófono o la salida de audio a mitad del dictado, el motor se detiene
        // sin avisar y el resto del dictado se perdería. Se reconecta y se sigue grabando.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            guard let self, self.engine === engine else { return }
            NSLog("Eco: cambió la configuración de audio, se reconecta el micrófono")
            self.teardown()
            try? self.startEngine()
        }
    }

    private func teardown() {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
    }

    /// Detiene la grabación y devuelve el audio grabado.
    func stop() -> [Float] {
        teardown()
        return lock.withLock { samples }
    }

    /// Guarda el audio de un dictado como WAV (16 kHz, mono) y deja solo los últimos `keep`.
    /// Sirve para revisar qué se grabó si una transcripción sale incompleta.
    static func saveRecording(_ samples: [Float], keep: Int = 5) {
        let folder = Paths.ensure(Paths.support.appendingPathComponent("Grabaciones", isDirectory: true))
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let url = folder.appendingPathComponent("dictado_\(formatter.string(from: Date())).wav")
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData?[0].update(from: source.baseAddress!, count: samples.count)
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
        ]
        if let file = try? AVAudioFile(forWriting: url, settings: settings) {
            try? file.write(from: buffer)
        }
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for old in files.filter({ $0.pathExtension == "wav" }).sorted(by: { $0.lastPathComponent > $1.lastPathComponent }).dropFirst(keep) {
            try? FileManager.default.removeItem(at: old)
        }
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        if let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 {
            var sum: Float = 0
            for index in 0..<Int(buffer.frameLength) { sum += channel[index] * channel[index] }
            let rms = (sum / Float(buffer.frameLength)).squareRoot()
            onLevel?(min(1, rms * 12))
        }

        guard let converter else { return }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }

        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let data = output.floatChannelData?[0] else { return }
        let chunk = UnsafeBufferPointer(start: data, count: Int(output.frameLength))
        lock.withLock { samples.append(contentsOf: chunk) }
    }

    /// Indica si el audio tiene voz: busca algún tramo de 30 ms con volumen suficiente.
    static func containsSpeech(_ samples: [Float]) -> Bool {
        let window = Int(sampleRate * 0.03)
        guard samples.count > window else { return false }
        var index = 0
        while index + window <= samples.count {
            var sum: Float = 0
            for value in samples[index..<(index + window)] { sum += value * value }
            if (sum / Float(window)).squareRoot() > 0.012 { return true }
            index += window
        }
        return false
    }
}

enum EcoError: LocalizedError {
    case noMicrophone
    case modelNotReady

    var errorDescription: String? {
        switch self {
        case .noMicrophone: return "No se encontró un micrófono."
        case .modelNotReady: return "El modelo de voz todavía se está preparando."
        }
    }
}
