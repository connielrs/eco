import Foundation
import WhisperKit

/// Estado del modelo de voz, para mostrarlo en el menú y en ajustes.
@MainActor
final class ModelStatus: ObservableObject {
    static let shared = ModelStatus()

    enum State: Equatable {
        case idle
        case downloading(Double)
        case loading
        case ready
        case failed(String)
    }

    @Published var state: State = .idle

    var label: String {
        switch state {
        case .idle: return "Modelo de voz pendiente"
        case .downloading(let progress): return "Descargando modelo de voz… \(Int(progress * 100)) %"
        case .loading: return "Preparando modelo de voz…"
        case .ready: return "Modelo de voz listo"
        case .failed(let message): return "Error con el modelo de voz: \(message)"
        }
    }
}

/// Transcribe audio con WhisperKit dentro del Mac.
actor Transcriber {
    static let shared = Transcriber()
    /// Whisper large-v3 turbo comprimido: buena precisión en español e inglés y rápido en Apple Silicon.
    static let modelVariant = "large-v3-v20240930_turbo_632MB"

    private var kit: WhisperKit?
    private var loading: Task<WhisperKit, Error>?

    /// Frases que Whisper inventa cuando el audio es casi silencio.
    private static let hallucinations = [
        "subtítulos realizados por la comunidad de amara.org",
        "subtítulos por la comunidad de amara.org",
        "gracias por ver el video",
        "gracias por ver",
        "¡gracias por ver!",
        "thank you for watching",
        "thanks for watching",
        "suscríbete",
        "música",
        "[música]",
        "[blank_audio]",
    ]

    /// Descarga el modelo si hace falta y lo deja cargado.
    @discardableResult
    func prepare() async throws -> WhisperKit {
        if let kit { return kit }
        if let loading { return try await loading.value }

        let task = Task { () throws -> WhisperKit in
            let folder = try await Self.modelFolder()
            await MainActor.run { ModelStatus.shared.state = .loading }
            let config = WhisperKitConfig(
                modelFolder: folder.path,
                tokenizerFolder: Paths.models,
                verbose: false,
                logLevel: .error,
                prewarm: true,
                load: true,
                download: false
            )
            return try await WhisperKit(config)
        }
        loading = task
        do {
            let kit = try await task.value
            self.kit = kit
            loading = nil
            await MainActor.run { ModelStatus.shared.state = .ready }
            return kit
        } catch {
            loading = nil
            let message = error.localizedDescription
            await MainActor.run { ModelStatus.shared.state = .failed(message) }
            throw error
        }
    }

    var isReady: Bool { kit != nil }

    /// Transcribe audio de 16 kHz.
    /// No se le pasan las palabras del diccionario como pista (promptTokens): con WhisperKit 0.18 y este
    /// modelo la transcripción sale vacía. El diccionario se aplica después, con reemplazos.
    func transcribe(_ samples: [Float], language: String?) async throws -> String {
        let kit = try await prepare()
        var options = Self.options(language: language)
        options.withoutTimestamps = true
        let results = try await kit.transcribe(audioArray: samples, decodeOptions: options)
        let text = results.map(\.text).joined(separator: " ")
        return Self.clean(text)
    }

    /// Transcribe un archivo largo (reuniones) y devuelve los fragmentos con sus tiempos.
    func transcribeFile(at url: URL, language: String?) async throws -> [TranscriptionSegment] {
        let kit = try await prepare()
        let options = Self.options(language: language)
        let results: [TranscriptionResult] = try await kit.transcribe(audioPath: url.path, decodeOptions: options)
        return results.flatMap(\.segments)
    }

    static func clean(_ raw: String) -> String {
        var text = raw.replacingOccurrences(of: #"<\|[^|]*\|>"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = text.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " .!¡"))
        if hallucinations.contains(where: { normalized == $0.trimmingCharacters(in: CharacterSet(charactersIn: " .!¡")) }) {
            return ""
        }
        return text
    }

    private static func options(language: String?) -> DecodingOptions {
        DecodingOptions(
            task: .transcribe,
            language: language,
            temperature: 0,
            usePrefillPrompt: true,
            detectLanguage: language == nil,
            skipSpecialTokens: true,
            suppressBlank: true,
            chunkingStrategy: .vad
        )
    }

    /// Carpeta del modelo en el Mac; si no está, lo descarga mostrando el progreso.
    private static func modelFolder() async throws -> URL {
        let defaultsKey = "modelFolder.\(modelVariant)"
        if let saved = UserDefaults.standard.string(forKey: defaultsKey) {
            let url = URL(fileURLWithPath: saved)
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("AudioEncoder.mlmodelc").path) {
                return url
            }
        }
        await MainActor.run { ModelStatus.shared.state = .downloading(0) }
        let folder = try await WhisperKit.download(variant: modelVariant, downloadBase: Paths.models) { progress in
            let fraction = progress.fractionCompleted
            Task { @MainActor in ModelStatus.shared.state = .downloading(fraction) }
        }
        UserDefaults.standard.set(folder.path, forKey: defaultsKey)
        return folder
    }
}
