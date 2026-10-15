import Foundation
import AVFoundation
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
            case "--test-meeting":
                // Eco --test-meeting <voz-propia.wav> <voz-otros.wav>; usar con ECO_DATA_DIR apuntando a una carpeta de prueba.
                try await testMeeting(mine: URL(fileURLWithPath: path), theirs: URL(fileURLWithPath: arguments[2]))
                return 0
            case "--summarize":
                let text = try String(contentsOfFile: path, encoding: .utf8)
                let start = Date()
                let summary = try await MeetingSummarizer.summarize(text)
                print("RESUMEN (\(Int(Date().timeIntervalSince(start))) s, \(text.count) caracteres): \(summary.title ?? "-")\n\(summary.markdown)")
                return 0
            case "--test-learn":
                // Eco --test-learn "<texto pegado>" "<texto editado>"
                if let (wrong, right) = CorrectionLearner.correction(from: path, to: arguments[2]),
                   await CorrectionLearner.isWorthLearning(wrong: wrong, right: right, in: arguments[2]) {
                    print("APRENDE: \(wrong) → \(right)")
                } else {
                    print("NO APRENDE")
                }
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
    private static func testMeeting(mine: URL, theirs: URL) async throws {
        let meeting = Meeting(title: Meeting.defaultTitle(for: Date()), startedAt: Date(), status: .transcribing)
        Paths.ensure(meeting.folder)
        try reencode(mine, to: meeting.micFile)
        try reencode(theirs, to: meeting.systemFile)
        MeetingStore.shared.insert(meeting)
        let start = Date()
        MeetingProcessor.shared.enqueue(meeting.id)
        while let current = MeetingStore.shared.meeting(meeting.id), current.status.isProcessing {
            try await Task.sleep(for: .milliseconds(300))
        }
        let result = MeetingStore.shared.meeting(meeting.id)!
        print("ESTADO: \(result.status) en \(Int(Date().timeIntervalSince(start))) s")
        print("TÍTULO: \(result.title)")
        print("TRANSCRIPCIÓN:\n\(result.transcriptText)")
        print("RESUMEN:\n\(result.summary ?? "-")")
    }

    /// Pasa un audio al mismo formato que usan las grabaciones de reuniones (AAC en CAF).
    private static func reencode(_ source: URL, to destination: URL) throws {
        let input = try AVAudioFile(forReading: source)
        let format = input.processingFormat
        let output = try AVAudioFile(
            forWriting: destination,
            settings: MeetingAudio.fileSettings(sampleRate: format.sampleRate, channels: format.channelCount),
            commonFormat: .pcmFormatFloat32,
            interleaved: format.isInterleaved
        )
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
        while input.framePosition < input.length {
            try input.read(into: buffer)
            try output.write(from: buffer)
        }
    }

    @MainActor
    private static func renderBar(into folder: URL) {
        let levels: [Float] = [0.1, 0.3, 0.6, 0.9, 0.5, 0.7, 1, 0.4, 0.2, 0.6, 0.8, 0.3, 0.5, 0.2, 0.1, 0.05]
        let states: [(String, DictationController.State)] = [
            ("escuchando", .listening), ("fijo", .listening), ("procesando", .processing), ("aviso", .message("Falta el permiso de micrófono")),
        ]
        for (name, state) in states {
            DictationController.shared.preview(state, levels: levels, locked: name == "fijo")
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
