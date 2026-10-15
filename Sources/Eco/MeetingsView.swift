import AppKit
import SwiftUI

final class MeetingsUIState: ObservableObject {
    @Published var selection: UUID?
    @Published var confirmingDelete = false
    @Published var copied: String?
}

struct MeetingsView: View {
    @ObservedObject private var store = MeetingStore.shared
    @ObservedObject private var recorder = MeetingRecorder.shared
    @StateObject private var ui = MeetingsUIState()

    var body: some View {
        NavigationSplitView {
            List(store.meetings, selection: $ui.selection) { meeting in
                MeetingRow(meeting: meeting).tag(meeting.id)
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 250)
            .safeAreaInset(edge: .bottom) {
                Button {
                    toggleRecording()
                } label: {
                    Label(
                        recorder.isRecording ? "Terminar (\(MeetingRecorder.format(recorder.elapsed)))" : "Grabar reunión",
                        systemImage: recorder.isRecording ? "stop.circle.fill" : "record.circle"
                    )
                    .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .tint(recorder.isRecording ? .red : nil)
                .padding(10)
            }
        } detail: {
            if let id = ui.selection, let meeting = store.meeting(id) {
                MeetingDetail(meeting: meeting, ui: ui)
            } else {
                Text(store.meetings.isEmpty ? "Todavía no hay reuniones grabadas." : "Elige una reunión.")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 760, minHeight: 520)
        .onAppear {
            if ui.selection == nil { ui.selection = store.meetings.first?.id }
        }
    }

    private func toggleRecording() {
        if recorder.isRecording {
            recorder.stop()
        } else {
            do {
                try recorder.start()
                ui.selection = recorder.current?.id
            } catch {
                let alert = NSAlert()
                alert.messageText = "No se pudo grabar la reunión"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }
}

struct MeetingRow: View {
    let meeting: Meeting

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(meeting.title).lineLimit(1)
            HStack(spacing: 6) {
                Text(meeting.startedAt.formatted(date: .abbreviated, time: .shortened))
                if meeting.duration > 0 {
                    Text("· \(MeetingRecorder.format(meeting.duration))")
                }
                if meeting.status != .done {
                    Text("· \(meeting.status.label)")
                        .foregroundStyle(meeting.status == .recording ? .red : .orange)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }
}

struct MeetingDetail: View {
    let meeting: Meeting
    @ObservedObject var ui: MeetingsUIState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                TextField("Nombre de la reunión", text: Binding(
                    get: { meeting.title },
                    set: { MeetingStore.shared.rename(meeting.id, to: $0) }
                ))
                .textFieldStyle(.plain)
                .font(.title2.weight(.semibold))

                HStack(spacing: 8) {
                    Text(meeting.startedAt.formatted(date: .complete, time: .shortened))
                    if meeting.duration > 0 { Text("· \(MeetingRecorder.format(meeting.duration))") }
                }
                .font(.callout)
                .foregroundStyle(.secondary)

                actions

                statusView

                if let summary = meeting.summary {
                    VStack(alignment: .leading, spacing: 8) {
                        MarkdownText(markdown: summary)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
                }

                if !meeting.transcript.isEmpty {
                    Text("Transcripción").font(.headline)
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(meeting.transcript) { line in
                            HStack(alignment: .top, spacing: 10) {
                                Text(line.speaker.label)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(line.speaker == .me ? Color.accentColor : .secondary)
                                    .frame(width: 44, alignment: .leading)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(MeetingRecorder.format(line.start))
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.tertiary)
                                    Text(line.text).textSelection(.enabled)
                                }
                            }
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .confirmationDialog("¿Borrar esta reunión?", isPresented: $ui.confirmingDelete) {
            Button("Borrar", role: .destructive) {
                ui.selection = nil
                MeetingStore.shared.delete(meeting.id)
            }
        } message: {
            Text("Se borran la transcripción, el resumen y los audios. No se puede deshacer.")
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button {
                copy(meeting.summary ?? "", label: "resumen")
            } label: {
                Label(ui.copied == "resumen" ? "Copiado" : "Copiar resumen", systemImage: "doc.on.doc")
            }
            .disabled(meeting.summary == nil)
            Button {
                copy(meeting.transcriptText, label: "transcripción")
            } label: {
                Label(ui.copied == "transcripción" ? "Copiada" : "Copiar transcripción", systemImage: "text.quote")
            }
            .disabled(meeting.transcript.isEmpty)
            Menu {
                Button("Volver a generar el resumen") { MeetingProcessor.shared.resummarize(meeting.id) }
                    .disabled(meeting.transcript.isEmpty || meeting.status.isProcessing)
                Button("Volver a transcribir") {
                    MeetingStore.shared.update(meeting.id) { $0.status = .transcribing }
                    MeetingProcessor.shared.enqueue(meeting.id)
                }
                .disabled(meeting.status.isProcessing || meeting.status == .recording)
                Button("Mostrar audios en Finder") { NSWorkspace.shared.activateFileViewerSelecting([meeting.folder]) }
                Divider()
                Button("Borrar reunión…", role: .destructive) { ui.confirmingDelete = true }
                    .disabled(meeting.status == .recording)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .controlSize(.small)
    }

    @ViewBuilder
    private var statusView: some View {
        switch meeting.status {
        case .recording:
            Label("Grabando…", systemImage: "record.circle.fill").foregroundStyle(.red)
        case .transcribing, .summarizing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(meeting.status == .transcribing
                     ? "Transcribiendo la reunión. Puede tardar unos minutos si fue larga."
                     : "Generando el resumen…")
                    .foregroundStyle(.secondary)
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Button("Reintentar") {
                    MeetingStore.shared.update(meeting.id) {
                        $0.status = $0.transcript.isEmpty ? .transcribing : .summarizing
                    }
                    MeetingProcessor.shared.enqueue(meeting.id)
                }
            }
        case .done:
            EmptyView()
        }
    }

    private func copy(_ text: String, label: String) {
        TextInserter.copy(text)
        ui.copied = label
    }
}

/// Muestra el Markdown simple del resumen (títulos y viñetas).
struct MarkdownText: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(markdown.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("#") {
                    Text(inline(trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "# "))))
                        .font(.headline)
                        .padding(.top, 6)
                } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•")
                        Text(inline(String(trimmed.dropFirst(2)))).textSelection(.enabled)
                    }
                } else if !trimmed.isEmpty {
                    Text(inline(trimmed)).textSelection(.enabled)
                }
            }
        }
    }

    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }
}
