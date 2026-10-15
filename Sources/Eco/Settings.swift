import Foundation
import ServiceManagement

enum Hotkey: String, CaseIterable, Identifiable {
    case fn
    case rightOption
    case rightCommand

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fn: return "Fn (🌐)"
        case .rightOption: return "Opción derecha (⌥)"
        case .rightCommand: return "Comando derecho (⌘)"
        }
    }
}

enum DictationLanguage: String, CaseIterable, Identifiable {
    case spanish = "es"
    case english = "en"
    case auto

    var id: String { rawValue }

    var label: String {
        switch self {
        case .spanish: return "Español (entiende palabras en inglés)"
        case .english: return "Inglés"
        case .auto: return "Detectar automáticamente"
        }
    }

    /// Código que recibe Whisper; nil deja que detecte el idioma.
    var whisperCode: String? { self == .auto ? nil : rawValue }
}

/// Preferencias de Eco, guardadas en UserDefaults.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let defaults = UserDefaults.standard

    @Published var hotkey: Hotkey {
        didSet { defaults.set(hotkey.rawValue, forKey: "hotkey") }
    }
    @Published var language: DictationLanguage {
        didSet { defaults.set(language.rawValue, forKey: "language") }
    }
    @Published var cleanupEnabled: Bool {
        didSet { defaults.set(cleanupEnabled, forKey: "cleanupEnabled") }
    }
    @Published var launchAtLogin: Bool {
        didSet { updateLoginItem() }
    }

    private init() {
        hotkey = Hotkey(rawValue: defaults.string(forKey: "hotkey") ?? "") ?? .fn
        language = DictationLanguage(rawValue: defaults.string(forKey: "language") ?? "") ?? .spanish
        cleanupEnabled = defaults.object(forKey: "cleanupEnabled") as? Bool ?? true
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func updateLoginItem() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Eco: no se pudo cambiar el inicio automático: \(error)")
        }
    }
}
