import AppKit

/// Detecta en cualquier app cuando se mantiene apretada la tecla elegida para dictar.
@MainActor
final class HotkeyMonitor {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    /// Se llama si mientras se mantiene el atajo se aprieta otra tecla (por ejemplo Fn + flecha).
    var onCancel: (() -> Void)?

    private var monitors: [Any] = []
    private var isDown = false

    func start() {
        stop()
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { event in
            MainActor.assumeIsolated { self.handle(event) }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { event in
            MainActor.assumeIsolated { self.handle(event) }
            return event
        }) {
            monitors.append(local)
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        isDown = false
    }

    private func handle(_ event: NSEvent) {
        if event.type == .keyDown {
            if isDown {
                isDown = false
                onCancel?()
            }
            return
        }

        guard let pressed = Self.state(of: AppSettings.shared.hotkey, in: event) else { return }
        if pressed && !isDown {
            isDown = true
            onPress?()
        } else if !pressed && isDown {
            isDown = false
            onRelease?()
        }
    }

    /// Devuelve si la tecla del atajo quedó apretada o suelta, o nil si el evento es de otra tecla.
    private static func state(of hotkey: Hotkey, in event: NSEvent) -> Bool? {
        let flags = event.modifierFlags
        switch hotkey {
        case .fn:
            guard event.keyCode == 63 else { return nil }
            return flags.contains(.function)
        case .rightOption:
            guard event.keyCode == 61 else { return nil }
            return flags.contains(.option)
        case .rightCommand:
            guard event.keyCode == 54 else { return nil }
            return flags.contains(.command)
        }
    }

    /// macOS puede usar la tecla Fn para abrir los emojis o cambiar el idioma del teclado.
    /// Para dictar con Fn conviene que esté en "No hacer nada".
    /// Si el valor no existe, macOS usa su acción por defecto (emojis o cambio de idioma).
    static var fnKeyHasSystemAction: Bool {
        guard let value = UserDefaults(suiteName: "com.apple.HIToolbox")?.object(forKey: "AppleFnUsageType") as? Int else {
            return true
        }
        return value != 0
    }
}
