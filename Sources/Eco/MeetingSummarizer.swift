import Foundation
import FoundationModels

/// Resume reuniones con Apple Intelligence. El modelo tiene una ventana de contexto chica,
/// así que las reuniones largas se resumen por partes y después se juntan.
enum MeetingSummarizer {
    struct Summary {
        var title: String?
        var markdown: String
    }

    private static let model = SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)
    /// Caracteres de transcripción por parte (aprox. 1.500 tokens, deja espacio para instrucciones y respuesta).
    private static let chunkSize = 5_000

    private static let notesInstructions = """
    Tomas notas de una parte de una reunión. "Tú" es la persona dueña de las notas y "Otros" \
    son las demás personas. Escribe en español, en viñetas cortas: los temas tratados, las decisiones \
    o acuerdos, y las tareas pendientes con quién las hará si se dice. No inventes nada que no esté \
    en la transcripción. Responde solo con las viñetas.
    """

    private static let summaryInstructions = """
    Escribes el resumen final de una reunión a partir de notas o de su transcripción. \
    "Tú" es la persona dueña de las notas y "Otros" son las demás personas. Escribe en español, \
    claro y breve, sin inventar nada. Usa exactamente este formato en Markdown:

    Título: <título corto de la reunión, máximo 6 palabras>

    ## Resumen
    - <3 a 6 viñetas con lo más importante>

    ## Acuerdos
    - <cada acuerdo o decisión; si no hubo, escribe "- Sin acuerdos registrados">

    ## Tareas
    - <cada tarea, con responsable si se dijo; si no hubo, escribe "- Sin tareas registradas">
    """

    static func summarize(_ transcript: String) async throws -> Summary {
        guard model.isAvailable else {
            throw RecordingError.failed(TextCleaner.unavailableReason ?? "Apple Intelligence no está disponible.")
        }
        var material = transcript
        // Reducir por partes hasta que quepa en una sola petición.
        var rounds = 0
        while material.count > chunkSize && rounds < 4 {
            var notes: [String] = []
            for chunk in chunks(of: material, size: chunkSize) {
                notes.append(try await respond(notesInstructions, chunk, maxTokens: 400))
            }
            material = notes.joined(separator: "\n")
            rounds += 1
        }
        let output = try await respond(summaryInstructions, material, maxTokens: 700)
        return parse(output)
    }

    private static func respond(_ instructions: String, _ text: String, maxTokens: Int) async throws -> String {
        let session = LanguageModelSession(model: model, instructions: instructions)
        do {
            let response = try await session.respond(
                to: text,
                options: GenerationOptions(sampling: .greedy, maximumResponseTokens: maxTokens)
            )
            return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch LanguageModelSession.GenerationError.exceededContextWindowSize {
            // Si igual no cabe, se divide en dos y se resume cada mitad.
            guard text.count > 800 else { throw RecordingError.failed("La reunión no se pudo resumir.") }
            let halves = chunks(of: text, size: text.count / 2 + 1)
            var parts: [String] = []
            for half in halves { parts.append(try await respond(notesInstructions, half, maxTokens: 300)) }
            let joined = parts.joined(separator: "\n")
            return instructions == notesInstructions ? joined : try await respond(instructions, joined, maxTokens: maxTokens)
        }
    }

    /// Divide el texto en partes sin cortar líneas.
    static func chunks(of text: String, size: Int) -> [String] {
        var result: [String] = []
        var current = ""
        for line in text.components(separatedBy: "\n") {
            if current.count + line.count + 1 > size, !current.isEmpty {
                result.append(current)
                current = ""
            }
            if line.count > size {
                var rest = Substring(line)
                while rest.count > size {
                    result.append(String(rest.prefix(size)))
                    rest = rest.dropFirst(size)
                }
                current = String(rest)
            } else {
                current += (current.isEmpty ? "" : "\n") + line
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// Separa el título del resto. El modelo a veces escribe "Título: …" y a veces solo una primera línea en negrita.
    static func parse(_ output: String) -> Summary {
        var lines = output.components(separatedBy: "\n")
        var title: String?
        let decoration = CharacterSet(charactersIn: "\"*#_ ")
        if let index = lines.firstIndex(where: { $0.lowercased().contains("título:") || $0.lowercased().contains("titulo:") }) {
            title = lines[index].split(separator: ":", maxSplits: 1).last.map {
                $0.trimmingCharacters(in: decoration)
            }
            lines.remove(at: index)
        } else if let index = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            let first = lines[index].trimmingCharacters(in: .whitespaces)
            if !first.hasPrefix("##") && !first.hasPrefix("-") && first.count <= 80 {
                title = first.trimmingCharacters(in: decoration)
                lines.remove(at: index)
            }
        }
        let markdown = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return Summary(title: title?.isEmpty == true ? nil : title, markdown: markdown)
    }
}
