import Foundation
import SwiftUI
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
                let dictionary = await PersonalDictionary.shared.snapshot
                let start = Date()
                let transcribed = try await Transcriber.shared.transcribe(
                    samples, language: language == "auto" ? nil : language
                )
                let text = dictionary.apply(to: transcribed)
                print("TRANSCRIPCIÓN (\(String(format: "%.2f", Date().timeIntervalSince(start))) s): \(transcribed)")
                let cleanStart = Date()
                let cleaned = dictionary.apply(to: await TextCleaner.clean(text, vocabulary: dictionary.vocabulary))
                print("LIMPIO (\(String(format: "%.2f", Date().timeIntervalSince(cleanStart))) s): \(cleaned)")
                return 0
            case "--render-bar":
                await renderBar(into: URL(fileURLWithPath: path))
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

    @MainActor
    private static func renderBar(into folder: URL) {
        let levels: [Float] = [0.1, 0.3, 0.6, 0.9, 0.5, 0.7, 1, 0.4, 0.2, 0.6, 0.8, 0.3, 0.5, 0.2, 0.1, 0.05]
        let states: [(String, DictationController.State)] = [
            ("escuchando", .listening), ("procesando", .processing), ("aviso", .message("Falta el permiso de micrófono")),
        ]
        for (name, state) in states {
            DictationController.shared.preview(state, levels: levels)
            let renderer = ImageRenderer(content: FloatingBarView().frame(width: 360, height: 64).background(Color.gray.opacity(0.4)))
            renderer.scale = 2
            if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: folder.appendingPathComponent("barra-\(name).png"))
            }
        }
    }

    private static func usage() -> Int32 {
        print("Uso: Eco --transcribe <audio> [es|en|auto] | Eco --clean <texto>")
        return 2
    }
}
