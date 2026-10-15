import Foundation

/// Guarda y lee un valor Codable en un archivo JSON dentro de la carpeta de Eco.
struct JSONStore<Value: Codable> {
    let url: URL

    init(_ fileName: String) {
        url = Paths.file(fileName)
    }

    func load() -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Value.self, from: data)
    }

    func save(_ value: Value) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
