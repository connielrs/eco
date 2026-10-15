import AppKit

/// Empieza y termina la grabación de una reunión.
@MainActor
final class MeetingRecorder: ObservableObject {
    static let shared = MeetingRecorder()

    @Published private(set) var current: Meeting?
    @Published private(set) var elapsed: TimeInterval = 0

    /// Se llama cuando termina una grabación, con el id de la reunión, para procesarla.
    var onFinished: ((UUID) -> Void)?

    private let microphone = MicrophoneFileRecorder()
    private let system = SystemAudioRecorder()
    private var timer: Timer?

    var isRecording: Bool { current != nil }

    func start() throws {
        guard current == nil else { return }
        guard Permissions.shared.microphone == .authorized else {
            throw RecordingError.failed("Falta el permiso de micrófono.")
        }
        let now = Date()
        let meeting = Meeting(title: Meeting.defaultTitle(for: now), startedAt: now)
        Paths.ensure(meeting.folder)

        do {
            try microphone.start(writingTo: meeting.micFile)
        } catch {
            throw RecordingError.failed("No se pudo grabar el micrófono: \(error.localizedDescription)")
        }
        do {
            try system.start(writingTo: meeting.systemFile)
        } catch {
            microphone.stop()
            try? FileManager.default.removeItem(at: meeting.folder)
            throw error
        }

        MeetingStore.shared.insert(meeting)
        current = meeting
        elapsed = 0
        DictationController.shared.isEnabled = false
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in
                let recorder = MeetingRecorder.shared
                if let start = recorder.current?.startedAt { recorder.elapsed = Date().timeIntervalSince(start) }
            }
        }
    }

    func stop() {
        guard let meeting = current else { return }
        timer?.invalidate()
        timer = nil
        microphone.stop()
        system.stop()
        let duration = Date().timeIntervalSince(meeting.startedAt)
        MeetingStore.shared.update(meeting.id) {
            $0.duration = duration
            $0.status = .transcribing
        }
        current = nil
        elapsed = 0
        DictationController.shared.isEnabled = true
        onFinished?(meeting.id)
    }

    static func format(_ interval: TimeInterval) -> String {
        let seconds = Int(interval)
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let rest = seconds % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, rest)
            : String(format: "%02d:%02d", minutes, rest)
    }
}
