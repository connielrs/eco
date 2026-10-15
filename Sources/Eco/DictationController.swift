import AppKit

/// Coordina un dictado: escuchar, transcribir, limpiar y pegar.
@MainActor
final class DictationController: ObservableObject {
    static let shared = DictationController()

    enum State: Equatable {
        case idle
        case listening
        case processing
        case message(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var level: Float = 0

    private let hotkey = HotkeyMonitor()
    private let recorder = AudioRecorder()
    private var startedAt = Date()
    private var targetApp: NSRunningApplication?
    private var messageTask: Task<Void, Never>?

    /// Si es false, el atajo no hace nada (por ejemplo mientras se graba una reunión).
    var isEnabled = true

    func start() {
        recorder.onLevel = { [weak self] value in
            Task { @MainActor in self?.level = value }
        }
        hotkey.onPress = { [weak self] in self?.begin() }
        hotkey.onRelease = { [weak self] in self?.finish() }
        hotkey.onCancel = { [weak self] in self?.cancel() }
        hotkey.start()
    }

    private func begin() {
        guard isEnabled, state != .processing else { return }
        guard Permissions.shared.microphone == .authorized else {
            show("Falta el permiso de micrófono")
            return
        }
        guard Permissions.shared.accessibility else {
            show("Falta el permiso de accesibilidad")
            return
        }
        do {
            try recorder.start()
        } catch {
            show(error.localizedDescription)
            return
        }
        messageTask?.cancel()
        startedAt = Date()
        targetApp = NSWorkspace.shared.frontmostApplication
        state = .listening
    }

    private func cancel() {
        guard state == .listening else { return }
        _ = recorder.stop()
        state = .idle
    }

    private func finish() {
        guard state == .listening else { return }
        let samples = recorder.stop()
        level = 0
        let duration = Date().timeIntervalSince(startedAt)

        guard duration >= 0.3, AudioRecorder.containsSpeech(samples) else {
            state = .idle
            return
        }

        state = .processing
        let appName = targetApp?.localizedName
        Task {
            do {
                let result = try await DictationPipeline.process(samples, duration: duration, appName: appName)
                guard !result.isEmpty else {
                    state = .idle
                    return
                }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(result, forType: .string)
                state = .idle
            } catch {
                show(error.localizedDescription)
            }
        }
    }

    func show(_ message: String) {
        state = .message(message)
        messageTask?.cancel()
        messageTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            if !Task.isCancelled, case .message = state { state = .idle }
        }
    }
}

/// Lo que se hace con el audio de un dictado hasta obtener el texto final.
enum DictationPipeline {
    static func process(_ samples: [Float], duration: TimeInterval, appName: String?) async throws -> String {
        let language = await AppSettings.shared.language.whisperCode
        let text = try await Transcriber.shared.transcribe(samples, language: language)
        return text
    }
}
