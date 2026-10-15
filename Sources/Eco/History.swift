import AppKit
import SwiftUI

struct HistoryEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var date: Date
    var appName: String?
    /// Lo que transcribió Whisper, antes de limpiar.
    var raw: String
    /// El texto que se pegó.
    var text: String
    var duration: TimeInterval
}

/// Historial de dictados, guardado en el Mac.
@MainActor
final class DictationHistory: ObservableObject {
    static let shared = DictationHistory()
    private static let limit = 5000

    @Published private(set) var entries: [HistoryEntry]
    private let store = JSONStore<[HistoryEntry]>("history.json")

    private init() {
        entries = store.load() ?? []
    }

    func add(_ entry: HistoryEntry) {
        entries.insert(entry, at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
        store.save(entries)
    }

    func remove(_ entry: HistoryEntry) {
        entries.removeAll { $0.id == entry.id }
        store.save(entries)
    }

    func removeAll() {
        entries.removeAll()
        store.save(entries)
    }
}

final class HistorySearch: ObservableObject {
    @Published var query = ""
    @Published var confirmingClear = false
    @Published var copiedID: UUID?
}

struct HistoryView: View {
    @ObservedObject private var history = DictationHistory.shared
    @StateObject private var search = HistorySearch()

    private var filtered: [HistoryEntry] {
        let query = search.query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return history.entries }
        return history.entries.filter {
            $0.text.localizedCaseInsensitiveContains(query) || $0.raw.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Buscar en tus dictados", text: $search.query)
                    .textFieldStyle(.plain)
                Spacer()
                Button("Borrar todo") { search.confirmingClear = true }
                    .disabled(history.entries.isEmpty)
            }
            .padding(12)
            Divider()

            if filtered.isEmpty {
                Spacer()
                Text(history.entries.isEmpty ? "Todavía no hay dictados." : "No hay resultados.")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                List(filtered) { entry in
                    HistoryRow(entry: entry, copied: search.copiedID == entry.id) {
                        TextInserter.copy(entry.text)
                        search.copiedID = entry.id
                    } onDelete: {
                        history.remove(entry)
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 520, minHeight: 420)
        .confirmationDialog("¿Borrar todo el historial?", isPresented: $search.confirmingClear) {
            Button("Borrar todo", role: .destructive) { history.removeAll() }
        } message: {
            Text("No se puede deshacer.")
        }
    }
}

struct HistoryRow: View {
    let entry: HistoryEntry
    let copied: Bool
    let onCopy: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                    if let app = entry.appName {
                        Text("·")
                        Text(app)
                    }
                    if entry.raw != entry.text {
                        Text("·")
                        Text("Original: \(entry.raw)")
                            .lineLimit(1)
                            .help(entry.raw)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onCopy) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copiar")
            Button(action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Borrar")
        }
        .padding(.vertical, 4)
    }
}
