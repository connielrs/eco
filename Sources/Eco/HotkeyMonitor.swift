import AppKit

/// Detecta en cualquier app cuando se mantiene apretada la tecla elegida para dictar.
@MainActor
final class HotkeyMonitor {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    /// Se llama si mientras se mantiene el atajo se aprieta otra tecla (por ejemplo Fn + flecha).
    var onCancel: (() -> Void)?
    /// Se llama al apretar Esc (para descartar un dictado fijo).
    var onEscape: (() -> Void)?

    private var monitors: [Any] = []
    private var isDown = false
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var retryTimer: Timer?

    /// Usa un "event tap" que intercepta la tecla Fn antes que macOS, para que no abra los emojis
    /// ni cambie el idioma del teclado. Necesita el permiso de accesibilidad; mientras no esté,
    /// se escucha el teclado sin interceptarlo y se reintenta cada pocos segundos.
    func start() {
        stop()
        if startTap() { return }
        startMonitors()
        retryTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard AXIsProcessTrusted() else { return }
                self.start()
            }
        }
    }

    private func startTap() -> Bool {
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue) | CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: hotkeyTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            NSLog("Eco: no se pudo interceptar el teclado (falta accesibilidad), se escucha sin interceptar")
            return false
        }
        NSLog("Eco: interceptando la tecla del atajo")
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        tapSource = source
        return true
    }

    /// Procesa un evento del tap. Devuelve false si hay que tragarse el evento.
    fileprivate func handleTapEvent(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return true
        }
        guard let nsEvent = NSEvent(cgEvent: event) else { return true }
        handle(nsEvent)
        // La tecla Fn no sigue hacia macOS: así no se abren los emojis.
        if type == .flagsChanged, nsEvent.keyCode == 63, AppSettings.shared.hotkey == .fn {
            return false
        }
        return true
    }

    private func startMonitors() {
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
        retryTimer?.invalidate()
        retryTimer = nil
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        }
        tap = nil
        tapSource = nil
        isDown = false
    }

    private func handle(_ event: NSEvent) {
        if event.type == .keyDown {
            if event.keyCode == 53 { onEscape?() }
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

    /// true si Eco está interceptando la tecla Fn (y macOS ya no la usa para emojis).
    var isIntercepting: Bool { tap != nil }

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

/// Función C que recibe los eventos del tap. Corre en el hilo principal porque la fuente está en su run loop.
private func hotkeyTapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
    let keep = MainActor.assumeIsolated { monitor.handleTapEvent(type: type, event: event) }
    return keep ? Unmanaged.passUnretained(event) : nil
}
