import Foundation
import WhisperKit

/// Transcribe y resume una reunión ya grabada.
@MainActor
final class MeetingProcessor {
    static let shared = MeetingProcessor()

    /// Instancia aparte del modelo para que procesar una reunión larga no bloquee los dictados.
    private var transcriber = Transcriber(reportsStatus: false, variant: Transcriber.selectedVariant)
    private var queue: [UUID] = []
    private var running = false

    /// Al abrir la app, retoma las reuniones que quedaron a medio procesar.
    func resumePending() {
        for meeting in MeetingStore.shared.meetings.reversed() {
            if meeting.status == .recording {
                // La app se cerró grabando: se procesa lo que alcanzó a quedar guardado.
                MeetingStore.shared.update(meeting.id) { $0.status = .transcribing }
                enqueue(meeting.id)
            } else if meeting.status.isProcessing {
                enqueue(meeting.id)
            }
        }
    }

    func enqueue(_ id: UUID) {
        guard !queue.contains(id) else { return }
        queue.append(id)
        Task { await runQueue() }
    }

    /// Vuelve a generar el resumen con la transcripción existente.
    func resummarize(_ id: UUID) {
        MeetingStore.shared.update(id) { $0.status = .summarizing }
        enqueue(id)
    }

    private func runQueue() async {
        guard !running else { return }
        running = true
        // Usar el modelo elegido en Ajustes en ese momento.
        if await transcriber.modelVariant != Transcriber.selectedVariant {
            transcriber = Transcriber(reportsStatus: false, variant: Transcriber.selectedVariant)
        }
        while !queue.isEmpty {
            let id = queue.removeFirst()
            await process(id)
        }
        running = false
        await transcriber.unload()
    }

    private func process(_ id: UUID) async {
        guard var meeting = MeetingStore.shared.meeting(id) else { return }
        do {
            if meeting.status == .transcribing || meeting.transcript.isEmpty {
                MeetingStore.shared.update(id) { $0.status = .transcribing }
                let language = AppSettings.shared.language.whisperCode
                let dictionary = PersonalDictionary.shared.snapshot
                let lines = try await transcribe(meeting, language: language, dictionary: dictionary)
                MeetingStore.shared.update(id) {
                    $0.transcript = lines
                    if $0.duration == 0, let last = lines.last { $0.duration = last.start }
                    $0.status = .summarizing
                }
                meeting = MeetingStore.shared.meeting(id) ?? meeting
            }

            guard !meeting.transcript.isEmpty else {
                MeetingStore.shared.update(id) {
                    $0.summary = $0.systemAudioSilent == true
                        ? "No se detectó voz en la grabación. El audio del Mac quedó en silencio: revisa que Eco tenga permiso en Ajustes del Sistema → Privacidad y seguridad → Grabación de pantalla y audio del sistema."
                        : "No se detectó voz en la grabación."
                    $0.status = .done
                }
                return
            }

            let summary = try await MeetingSummarizer.summarize(meeting.transcriptText)
            MeetingStore.shared.update(id) {
                $0.summary = summary.markdown
                if let title = summary.title, !$0.titleEdited { $0.title = title }
                $0.status = .done
            }
        } catch {
            MeetingStore.shared.update(id) { $0.status = .failed(error.localizedDescription) }
        }
    }

    private func transcribe(_ meeting: Meeting, language: String?, dictionary: DictionarySnapshot) async throws -> [TranscriptLine] {
        var mine: [TranscriptLine] = []
        var theirs: [TranscriptLine] = []
        let files = FileManager.default
        if files.fileExists(atPath: meeting.micFile.path) {
            mine = try await lines(from: meeting.micFile, speaker: .me, language: language)
        }
        if files.fileExists(atPath: meeting.systemFile.path) {
            theirs = try await lines(from: meeting.systemFile, speaker: .others, language: language)
        }
        let merged = Self.merge(mine: mine, theirs: theirs)
        return merged.map { line in
            var line = line
            line.text = dictionary.apply(to: line.text)
            return line
        }
    }

    private func lines(from file: URL, speaker: TranscriptLine.Speaker, language: String?) async throws -> [TranscriptLine] {
        let segments: [TranscriptionSegment]
        do {
            segments = try await transcriber.transcribeFile(at: file, language: language)
        } catch {
            // Un archivo vacío (por ejemplo sin audio del sistema) no debe arruinar toda la reunión.
            NSLog("Eco: no se pudo transcribir \(file.lastPathComponent): \(error)")
            return []
        }
        let lines = segments.compactMap { segment -> TranscriptLine? in
            let text = Transcriber.clean(segment.text)
            guard !text.isEmpty else { return nil }
            return TranscriptLine(speaker: speaker, start: Double(segment.start), text: text)
        }
        // Whisper a veces repite "Gracias." en cada tramo de silencio: se quitan esas rachas.
        return Transcriber.removeRepeatedRunsIndices(lines.map(\.text)).map { lines[$0] }
    }

    /// Junta las dos pistas en orden. Si el micrófono captó lo mismo que sonó por los parlantes
    /// (eco sin audífonos), se descarta esa línea del micrófono.
    static func merge(mine: [TranscriptLine], theirs: [TranscriptLine]) -> [TranscriptLine] {
        let filteredMine = mine.filter { line in
            !theirs.contains { other in
                abs(other.start - line.start) < 8 && similarity(line.text, other.text) > 0.5
            }
        }
        let sorted = (filteredMine + theirs).sorted { $0.start < $1.start }

        // Unir líneas seguidas de la misma persona para que se lea como párrafos.
        var result: [TranscriptLine] = []
        for line in sorted {
            if var last = result.last, last.speaker == line.speaker, last.text.count < 600 {
                last.text += " " + line.text
                result[result.count - 1] = last
            } else {
                result.append(line)
            }
        }
        return result
    }

    private static func similarity(_ a: String, _ b: String) -> Double {
        let wordsA = Set(a.lowercased().split { !$0.isLetter && !$0.isNumber })
        let wordsB = Set(b.lowercased().split { !$0.isLetter && !$0.isNumber })
        guard !wordsA.isEmpty, !wordsB.isEmpty else { return 0 }
        return Double(wordsA.intersection(wordsB).count) / Double(min(wordsA.count, wordsB.count))
    }
}
