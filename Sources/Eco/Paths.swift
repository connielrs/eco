import Foundation

/// Carpetas donde Eco guarda sus datos dentro del Mac.
enum Paths {
    static let support: URL = {
        // ECO_DATA_DIR permite usar otra carpeta en las pruebas por línea de comandos.
        if let custom = ProcessInfo.processInfo.environment["ECO_DATA_DIR"] {
            return ensure(URL(fileURLWithPath: custom, isDirectory: true))
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return ensure(base.appendingPathComponent("Eco", isDirectory: true))
    }()

    static let models = ensure(support.appendingPathComponent("Models", isDirectory: true))
    static let meetings = ensure(support.appendingPathComponent("Meetings", isDirectory: true))

    static func file(_ name: String) -> URL { support.appendingPathComponent(name) }

    @discardableResult
    static func ensure(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
