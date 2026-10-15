import Foundation

struct DictionaryEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    /// Cómo se escribe la palabra.
    var word: String
    /// Formas en que se suele transcribir mal, separadas por coma. Se reemplazan siempre por `word`.
    var soundsLike: String = ""

    var variants: [String] {
        soundsLike.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

/// Diccionario personal: corrige palabras que se transcriben mal y le dice a la limpieza cómo se escriben.
@MainActor
final class PersonalDictionary: ObservableObject {
    static let shared = PersonalDictionary()

    @Published var entries: [DictionaryEntry] {
        didSet { store.save(entries) }
    }

    private let store = JSONStore<[DictionaryEntry]>("dictionary.json")

    private init() {
        entries = store.load() ?? Self.starter
        if store.load() == nil { store.save(entries) }
    }

    /// Palabras de partida, para que Eco conozca los nombres de siempre desde el primer día.
    private static let starter: [DictionaryEntry] = [
        DictionaryEntry(word: "Guruvic", soundsLike: "Gurubik, Guru Vic, Gurubic, Guruvik"),
        DictionaryEntry(word: "Curao", soundsLike: "Kurao"),
        DictionaryEntry(word: "Yutori", soundsLike: "Utori, Llutori"),
        DictionaryEntry(word: "Coni", soundsLike: "Connie, Cony, Conni"),
        DictionaryEntry(word: "Innovación Austral", soundsLike: ""),
        DictionaryEntry(word: "Linear", soundsLike: ""),
    ]

    var vocabulary: [String] {
        entries.map { $0.word.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    var snapshot: DictionarySnapshot { DictionarySnapshot(entries: entries) }

    func add(word: String, soundsLike: String) {
        let word = word.trimmingCharacters(in: .whitespaces)
        guard !word.isEmpty else { return }
        entries.append(DictionaryEntry(word: word, soundsLike: soundsLike))
    }

    /// Guarda una corrección: si la palabra ya existe, suma la variante; si no, crea la entrada.
    func learn(wrong: String, right: String) {
        if let index = entries.firstIndex(where: { $0.word.caseInsensitiveCompare(right) == .orderedSame }) {
            let known = entries[index].variants.contains { $0.caseInsensitiveCompare(wrong) == .orderedSame }
            guard !known else { return }
            let current = entries[index].soundsLike.trimmingCharacters(in: .whitespaces)
            entries[index].soundsLike = current.isEmpty ? wrong : current + ", " + wrong
        } else {
            entries.append(DictionaryEntry(word: right, soundsLike: wrong))
        }
    }

    func remove(_ entry: DictionaryEntry) {
        entries.removeAll { $0.id == entry.id }
    }
}

/// Copia del diccionario que se puede usar fuera del hilo principal.
struct DictionarySnapshot: Sendable {
    let entries: [DictionaryEntry]

    var vocabulary: [String] {
        entries.map { $0.word.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Reemplaza las variantes mal transcritas y deja cada palabra escrita como está guardada.
    func apply(to text: String) -> String {
        var result = text
        for entry in entries {
            let word = entry.word.trimmingCharacters(in: .whitespaces)
            guard !word.isEmpty else { continue }
            for variant in entry.variants + [word] {
                let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: variant) + "(?![\\p{L}\\p{N}])"
                guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
                let range = NSRange(result.startIndex..., in: result)
                result = regex.stringByReplacingMatches(
                    in: result, range: range, withTemplate: NSRegularExpression.escapedTemplate(for: word)
                )
            }
        }
        return result
    }
}

extension DictionaryEntry: @unchecked Sendable {}
