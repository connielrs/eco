import AppKit
import AVFoundation
import ApplicationServices

/// Estado de los permisos que Eco necesita.
@MainActor
final class Permissions: ObservableObject {
    static let shared = Permissions()

    @Published private(set) var microphone: AVAuthorizationStatus = .notDetermined
    @Published private(set) var accessibility = false

    private var timer: Timer?

    private init() {
        refresh()
    }

    var allGranted: Bool { microphone == .authorized && accessibility }

    func refresh() {
        microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        accessibility = AXIsProcessTrusted()
    }

    /// Revisa los permisos cada segundo mientras la ventana de ajustes está abierta,
    /// porque el de accesibilidad se da desde Ajustes del Sistema.
    func startWatching() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in Permissions.shared.refresh() }
        }
    }

    func stopWatching() {
        timer?.invalidate()
        timer = nil
    }

    func requestMicrophone() {
        if microphone == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                Task { @MainActor in Permissions.shared.refresh() }
            }
        } else {
            openPrivacyPane("Privacy_Microphone")
        }
    }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            openPrivacyPane("Privacy_Accessibility")
        }
    }

    func openPrivacyPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}
