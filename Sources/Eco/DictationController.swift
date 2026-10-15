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
        /// Aviso positivo (por ejemplo, una palabra aprendida).
        case notice(String)
    }

    @Published private(set) var state: State = .idle
    /// true cuando el dictado quedó fijo con doble toque y no hay que mantener la tecla.
    @Published private(set) var isLocked = false
    /// Últimos niveles de la voz, para la onda de la barra flotante.
    @Published private(set) var levels = [Float](repeating: 0, count: DictationController.barCount)
    static let barCount = 16

    private let hotkey = HotkeyMonitor()
    private let recorder = AudioRecorder()
    private var startedAt = Date()
    private var targetApp: NSRunningApplication?
    private var messageTask: Task<Void, Never>?

    /// Cómo se está usando el atajo en este dictado.
    private enum HotkeyMode {
        case none
        /// Tecla apretada: al soltar se pega, o si fue un toque corto se espera el segundo.
        case holding
        /// Hubo un toque corto: si llega otro pronto, el dictado queda fijo.
        case waitingSecondTap
        /// Dictado fijo: el próximo toque lo termina.
        case locked
    }

    private var mode: HotkeyMode = .none
    private var pressedAt = Date()
    private var secondTapTask: Task<Void, Never>?
    /// Un toque más corto que esto cuenta como toque (no como mantener apretado).
    private static let tapDuration: TimeInterval = 0.3
    /// Tiempo máximo entre los dos toques.
    private static let doubleTapWindow: Duration = .milliseconds(400)

    /// Si es false, el atajo no hace nada (por ejemplo mientras se graba una reunión).
    var isEnabled = true

    func start() {
        recorder.onLevel = { [weak self] value in
            Task { @MainActor in self?.push(level: value) }
        }
        hotkey.onPress = { [weak self] in self?.hotkeyPressed() }
        hotkey.onRelease = { [weak self] in self?.hotkeyReleased() }
        hotkey.onCancel = { [weak self] in self?.hotkeyInterrupted() }
        hotkey.onEscape = { [weak self] in self?.escapePressed() }
        hotkey.start()

        CorrectionLearner.shared.onLearned = { [weak self] wrong, right in
            self?.notify("Aprendí: \(wrong) → \(right)")
        }
        CorrectionLearner.shared.start()
    }

    /// Muestra un aviso positivo solo si no se está dictando.
    func notify(_ text: String) {
        guard state == .idle else { return }
        state = .notice(text)
        messageTask?.cancel()
        messageTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            if !Task.isCancelled, case .notice = state { state = .idle }
        }
    }

    private func hotkeyPressed() {
        switch mode {
        case .none:
            begin()
            if state == .listening {
                mode = .holding
                pressedAt = Date()
            }
        case .waitingSecondTap:
            // Segundo toque: el dictado queda fijo. La grabación ya venía corriendo desde el primero.
            secondTapTask?.cancel()
            mode = .locked
            isLocked = true
        case .locked:
            resetMode()
            finish()
        case .holding:
            break
        }
    }

    private func hotkeyReleased() {
        guard mode == .holding else { return }
        if Date().timeIntervalSince(pressedAt) < Self.tapDuration {
            mode = .waitingSecondTap
            secondTapTask = Task {
                try? await Task.sleep(for: Self.doubleTapWindow)
                guard !Task.isCancelled, mode == .waitingSecondTap else { return }
                // Fue un toque suelto: no se dicta nada.
                resetMode()
                cancel()
            }
        } else {
            resetMode()
            finish()
        }
    }

    /// Se apretó otra tecla junto con el atajo (por ejemplo Fn + flecha): no era un dictado.
    private func hotkeyInterrupted() {
        guard mode == .holding || mode == .waitingSecondTap else { return }
        resetMode()
        cancel()
    }

    /// Esc descarta un dictado fijo sin pegar nada.
    private func escapePressed() {
        guard mode == .locked else { return }
        resetMode()
        cancel()
    }

    private func resetMode() {
        secondTapTask?.cancel()
        mode = .none
        isLocked = false
    }

    private func begin() {
        guard state != .processing else { return }
        CorrectionLearner.shared.check()
        guard isEnabled else {
            show("Grabando reunión: el dictado está en pausa")
            return
        }
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
        levels = [Float](repeating: 0, count: Self.barCount)
        let duration = Date().timeIntervalSince(startedAt)

        guard duration >= 0.3, AudioRecorder.containsSpeech(samples) else {
            state = .idle
            return
        }

        state = .processing
        let appName = targetApp?.localizedName
        Task {
            do {
                let result = try await DictationPipeline.process(samples)
                guard !result.text.isEmpty else {
                    state = .idle
                    return
                }
                TextInserter.insert(result.text)
                CorrectionLearner.shared.watch(inserted: result.text)
                DictationHistory.shared.add(HistoryEntry(
                    date: Date(), appName: appName, raw: result.raw, text: result.text, duration: duration
                ))
                state = .idle
            } catch {
                show(error.localizedDescription)
            }
        }
    }

    /// Solo para generar imágenes de la barra desde la línea de comandos.
    func preview(_ state: State, levels: [Float], locked: Bool = false) {
        self.state = state
        self.levels = levels
        self.isLocked = locked
    }

    private func push(level: Float) {
        guard state == .listening else { return }
        levels.removeFirst()
        levels.append(level)
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
    struct Result {
        var raw: String
        var text: String
    }

    static func process(_ samples: [Float]) async throws -> Result {
        let settings = await AppSettings.shared
        let language = await settings.language.whisperCode
        let dictionary = await PersonalDictionary.shared.snapshot
        let transcribed = try await Transcriber.shared.transcribe(samples, language: language)
        guard !transcribed.isEmpty else { return Result(raw: "", text: "") }
        let raw = dictionary.apply(to: transcribed)
        guard await settings.cleanupEnabled else { return Result(raw: raw, text: raw) }
        let cleaned = await TextCleaner.clean(raw, vocabulary: dictionary.vocabulary)
        return Result(raw: transcribed, text: dictionary.apply(to: cleaned))
    }
}
