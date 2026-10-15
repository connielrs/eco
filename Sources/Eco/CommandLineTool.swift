import Foundation
import WhisperKit

/// Pruebas sin interfaz, para revisar la transcripción y la limpieza con archivos de audio.
enum CommandLineTool {
    static func run(_ arguments: [String]) async -> Int32 {
        guard arguments.count >= 2 else { return usage() }
        let path = arguments[1]
        let language = arguments.count > 2 ? arguments[2] : "es"
        do {
            switch arguments[0] {
            case "--transcribe":
                let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: path)
                let start = Date()
                let text = try await Transcriber.shared.transcribe(samples, language: language == "auto" ? nil : language)
                print("TRANSCRIPCIÓN (\(String(format: "%.2f", Date().timeIntervalSince(start))) s): \(text)")
                let cleanStart = Date()
                let cleaned = await TextCleaner.clean(text)
                print("LIMPIO (\(String(format: "%.2f", Date().timeIntervalSince(cleanStart))) s): \(cleaned)")
                return 0
            case "--clean":
                print(TextCleaner.unavailableReason ?? "Apple Intelligence disponible")
                print("LIMPIO: \(await TextCleaner.clean(arguments[1]))")
                return 0
            default:
                return usage()
            }
        } catch {
            print("ERROR: \(error)")
            return 1
        }
    }

    private static func usage() -> Int32 {
        print("Uso: Eco --transcribe <audio> [es|en|auto] | Eco --clean <texto>")
        return 2
    }
}
