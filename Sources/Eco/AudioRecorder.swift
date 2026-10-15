import AVFoundation

/// Graba el micrófono y lo deja en el formato que necesita Whisper (16 kHz, mono).
final class AudioRecorder: @unchecked Sendable {
    static let sampleRate: Double = 16_000

    /// Nivel de la voz entre 0 y 1, para dibujar la onda.
    var onLevel: ((Float) -> Void)?

    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private let lock = NSLock()
    private var samples: [Float] = []
    private let target = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: AudioRecorder.sampleRate, channels: 1, interleaved: false
    )!

    func start() throws {
        lock.withLock { samples.removeAll(keepingCapacity: true) }

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
    }

    /// Detiene la grabación y devuelve el audio grabado.
    func stop() -> [Float] {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        return lock.withLock { samples }
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
