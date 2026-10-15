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

enum VoiceModel: String, CaseIterable, Identifiable {
    case fast
    case precise

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fast: return "Rápido (recomendado)"
        case .precise: return "Preciso"
        }
    }

    var detail: String {
        switch self {
        case .fast: return "Transcribe en la mitad del tiempo. Ocupa 630 MB."
        case .precise: return "Se equivoca menos con palabras chilenas y nombres, pero tarda el doble. Ocupa 1,5 GB."
        }
    }

    /// Modelo de WhisperKit (ambos son Whisper large-v3 turbo; el rápido está comprimido).
    var variant: String {
        switch self {
        case .fast: return "large-v3-v20240930_turbo_632MB"
        case .precise: return "large-v3-v20240930_turbo"
        }
    }
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
    @Published var voiceModel: VoiceModel {
        didSet {
            defaults.set(voiceModel.rawValue, forKey: "voiceModel")
            let variant = voiceModel.variant
            Task { await Transcriber.shared.switchModel(to: variant) }
        }
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
        voiceModel = VoiceModel(rawValue: defaults.string(forKey: "voiceModel") ?? "") ?? .fast
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
