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
            case "--compare":
                // Eco --compare <audio> <modelo>: transcribe con otro modelo para comparar precisión.
                let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: path)
                let transcriber = Transcriber(reportsStatus: false, variant: arguments[2])
                try await transcriber.prepare()
                _ = try await transcriber.transcribe(Array(samples.prefix(16_000 * 3)), language: "es")
                let start = Date()
                let text = try await transcriber.transcribe(samples, language: "es")
                print("[\(arguments[2])] \(String(format: "%.2f", Date().timeIntervalSince(start))) s: \(text)")
                return 0
            case "--render-iconset":
                // Eco --render-iconset <carpeta.iconset> [dark|light]
                let style = AppIconStyle(rawValue: arguments.count > 2 ? arguments[2] : "dark") ?? .dark
                try await MainActor.run { try EcoIcon.writeIconset(style, to: URL(fileURLWithPath: path)) }
                return 0
            case "--test-writer":
                // Eco --test-writer <carpeta>: escribe audio de prueba con 9 canales y en estéreo intercalado.
                try testWriter(folder: URL(fileURLWithPath: path))
                return 0
            case "--record-system":
                // Eco --record-system <archivo.caf> [segundos]: graba el audio del Mac.
                let recorder = SystemAudioRecorder()
                try recorder.start(writingTo: URL(fileURLWithPath: path))
                try await Task.sleep(for: .seconds(Double(arguments.count > 2 ? arguments[2] : "5") ?? 5))
                recorder.stop()
                print("GRABADO: \(path)")
                return 0
            case "--record-both":
                // Eco --record-both <carpeta> [segundos]: graba micrófono y audio del Mac a la vez.
                let folder = URL(fileURLWithPath: path)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let seconds = Double(arguments.count > 2 ? arguments[2] : "6") ?? 6
                let microphone = MicrophoneFileRecorder()
                let system = SystemAudioRecorder()
                try system.start(writingTo: folder.appendingPathComponent("sistema.caf"))
                try microphone.start(writingTo: folder.appendingPathComponent("microfono.caf"))
                try await Task.sleep(for: .seconds(seconds))
                let peak = system.peak
                microphone.stop()
                system.stop()
                try "pico sistema \(peak)\n".write(to: folder.appendingPathComponent("resultado.txt"), atomically: true, encoding: .utf8)
                return 0
            case "--segments":
                // Eco --segments <audio>: muestra los fragmentos con tiempos, como en las reuniones.
                let segments = try await Transcriber.shared.transcribeFile(at: URL(fileURLWithPath: path), language: "es")
                for segment in segments { print(String(format: "%6.1f-%6.1f", segment.start, segment.end), segment.text) }
                return 0
            case "--clean":
                print(TextCleaner.unavailableReason ?? "Apple Intelligence disponible")
                let dictionary = await PersonalDictionary.shared.snapshot
                let start = Date()
                // Mismo filtro que se aplica a lo que entrega Whisper.
                let raw = dictionary.apply(to: Transcriber.clean(arguments[1]))
                let cleaned = dictionary.apply(to: await TextCleaner.clean(raw, vocabulary: dictionary.vocabulary))
                print("LIMPIO (\(String(format: "%.2f", Date().timeIntervalSince(start))) s, IA: \(TextCleaner.needsCleanup(raw) ? "sí" : "no")): \(cleaned)")
                return 0
            default:
                return usage()
            }
        } catch {
            print("ERROR: \(error)")
            return 1
        }
    }

    private static func testWriter(folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let cases: [(String, AVAudioChannelCount, Bool, MonoFileWriter.Mix)] = [
            ("microfono-9-canales", 9, false, .firstChannel), ("sistema-estereo", 2, true, .average),
        ]
        for (name, channels, interleaved, mix) in cases {
            let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels))!
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, interleaved: interleaved, channelLayout: layout)
            let url = folder.appendingPathComponent("\(name).caf")
            let writer = try MonoFileWriter(url: url, sourceSampleRate: 48_000, mix: mix)
            var phase: Float = 0
            for _ in 0..<(48_000 * 3 / 512) {
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
                buffer.frameLength = 512
                for frame in 0..<512 {
                    let value = sinf(phase) * 0.3
                    phase += 2 * .pi * 440 / 48_000
                    for channel in 0..<Int(channels) {
                        if interleaved { buffer.floatChannelData![0][frame * Int(channels) + channel] = value }
                        else { buffer.floatChannelData![channel][frame] = value }
                    }
                }
                writer.write(buffer)
            }
            print("\(name): \(writer.framesWritten) muestras a 16 kHz")
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
