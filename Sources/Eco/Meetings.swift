import Foundation

struct TranscriptLine: Codable, Equatable, Identifiable {
    enum Speaker: String, Codable {
        case me
        case others

        var label: String { self == .me ? "Tú" : "Otros" }
    }

    var id = UUID()
    var speaker: Speaker
    /// Segundos desde el inicio de la reunión.
    var start: Double
    var text: String
}

struct Meeting: Codable, Identifiable, Equatable {
    enum Status: Codable, Equatable {
        case recording
        case transcribing
        case summarizing
        case done
        case failed(String)

        var label: String {
            switch self {
            case .recording: return "Grabando"
            case .transcribing: return "Transcribiendo…"
            case .summarizing: return "Resumiendo…"
            case .done: return "Lista"
            case .failed: return "Error"
            }
        }

        var isProcessing: Bool { self == .transcribing || self == .summarizing }
    }

    var id = UUID()
    var title: String
    var startedAt: Date
    var duration: TimeInterval = 0
    var status: Status = .recording
    var transcript: [TranscriptLine] = []
    var summary: String?
    /// Si la persona le cambió el nombre, no se reemplaza por el título que propone el resumen.
    var titleEdited = false

    var folder: URL { Paths.meetings.appendingPathComponent(id.uuidString, isDirectory: true) }
    var micFile: URL { folder.appendingPathComponent("microfono.caf") }
    var systemFile: URL { folder.appendingPathComponent("sistema.caf") }

    var transcriptText: String {
        transcript.map { "\($0.speaker.label): \($0.text)" }.joined(separator: "\n\n")
    }

    static func defaultTitle(for date: Date) -> String {
        "Reunión del " + date.formatted(.dateTime.day().month(.wide).hour().minute())
    }
}

/// Lista de reuniones guardada en el Mac.
@MainActor
final class MeetingStore: ObservableObject {
    static let shared = MeetingStore()

    @Published private(set) var meetings: [Meeting]
    private let store = JSONStore<[Meeting]>("meetings.json")

    private init() {
        meetings = store.load() ?? []
    }

    func meeting(_ id: UUID) -> Meeting? { meetings.first { $0.id == id } }

    func insert(_ meeting: Meeting) {
        meetings.insert(meeting, at: 0)
        save()
    }

    func update(_ id: UUID, _ change: (inout Meeting) -> Void) {
        guard let index = meetings.firstIndex(where: { $0.id == id }) else { return }
        change(&meetings[index])
        save()
    }

    func rename(_ id: UUID, to title: String) {
        update(id) {
            $0.title = title
            $0.titleEdited = true
        }
    }

    func delete(_ id: UUID) {
        guard let meeting = meeting(id) else { return }
        try? FileManager.default.removeItem(at: meeting.folder)
        meetings.removeAll { $0.id == id }
        save()
    }

    private func save() { store.save(meetings) }
}
