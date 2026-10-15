import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let statusLine = NSMenuItem(title: "Eco está listo", action: nil, keyEquivalent: "")
    private var meetingItem: NSMenuItem!
    private var windows: [String: NSWindow] = [:]
    private let floatingBar = FloatingBar()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Eco")
        statusItem.menu = buildMenu()

        DictationController.shared.start()
        MeetingRecorder.shared.onFinished = { id in MeetingProcessor.shared.enqueue(id) }
        MeetingProcessor.shared.resumePending()
        floatingBar.start()
        observeStatus()
        Task { try? await Transcriber.shared.prepare() }
        TextCleaner.prewarm()

        if !Permissions.shared.allGranted {
            showSettings()
        }
    }

    private var observers: [Any] = []

    /// Mantiene la primera línea del menú al día con el estado del modelo y del dictado.
    private func observeStatus() {
        observers.append(ModelStatus.shared.$state.sink { [weak self] _ in
            Task { @MainActor in self?.refreshStatus() }
        })
        observers.append(DictationController.shared.$state.sink { [weak self] _ in
            Task { @MainActor in self?.refreshStatus() }
        })
        observers.append(MeetingRecorder.shared.$elapsed.sink { [weak self] _ in
            Task { @MainActor in self?.refreshStatus() }
        })
    }

    private func refreshStatus() {
        let model = ModelStatus.shared
        let recorder = MeetingRecorder.shared
        if recorder.isRecording {
            let time = MeetingRecorder.format(recorder.elapsed)
            meetingItem.title = "Terminar reunión (\(time))"
            statusItem.button?.image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Grabando reunión")
            statusItem.button?.contentTintColor = .systemRed
            setStatus("Grabando reunión · \(time)")
            return
        }
        meetingItem.title = "Grabar reunión"
        statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Eco")
        statusItem.button?.contentTintColor = nil
        switch DictationController.shared.state {
        case .listening:
            setStatus("Escuchando…")
        case .processing:
            setStatus("Procesando…")
        default:
            if model.state == .ready {
                let key = AppSettings.shared.hotkey.label
                setStatus("Listo. Mantén \(key) para dictar")
            } else {
                setStatus(model.label)
            }
        }
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())
        meetingItem = item("Grabar reunión", #selector(toggleMeeting), key: "r")
        menu.addItem(meetingItem)
        menu.addItem(item("Reuniones…", #selector(openMeetings), key: "m"))
        menu.addItem(.separator())
        menu.addItem(item("Historial de dictados…", #selector(openHistory), key: "h"))
        menu.addItem(item("Ajustes…", #selector(openSettings), key: ","))
        menu.addItem(.separator())
        menu.addItem(item("Salir de Eco", #selector(quit), key: "q"))
        return menu
    }

    func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    func setStatus(_ text: String) {
        statusLine.title = text
    }

    @objc private func openSettings() { showSettings() }

    @objc private func toggleMeeting() {
        let recorder = MeetingRecorder.shared
        if recorder.isRecording {
            recorder.stop()
        } else {
            do {
                try recorder.start()
                openMeetings()
            } catch {
                let alert = NSAlert()
                alert.messageText = "No se pudo grabar la reunión"
                alert.informativeText = error.localizedDescription
                NSApp.activate()
                alert.runModal()
            }
        }
        refreshStatus()
    }

    @objc private func openMeetings() {
        showWindow(id: "meetings", title: "Reuniones", size: NSSize(width: 900, height: 620)) {
            MeetingsView()
        }
    }

    @objc private func openHistory() {
        showWindow(id: "history", title: "Historial de dictados", size: NSSize(width: 620, height: 520)) {
            HistoryView()
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }

    func showSettings() {
        showWindow(id: "settings", title: "Ajustes de Eco", size: NSSize(width: 560, height: 460)) {
            SettingsView()
        }
    }

    /// Abre (o trae al frente) una ventana de SwiftUI identificada por `id`.
    func showWindow<Content: View>(id: String, title: String, size: NSSize, @ViewBuilder content: () -> Content) {
        if let window = windows[id] {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: content())
        window.setContentSize(size)
        window.center()
        windows[id] = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}
