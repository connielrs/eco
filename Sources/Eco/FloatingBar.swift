import AppKit
import Combine
import SwiftUI

/// Barra pequeña abajo al centro que muestra cuando Eco escucha o procesa.
/// Es un panel que no se activa, así la app donde se escribe no pierde el foco.
@MainActor
final class FloatingBar {
    private let panel: NSPanel
    private var cancellable: AnyCancellable?
    private static let size = NSSize(width: 360, height: 64)

    init() {
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: FloatingBarView())
    }

    func start() {
        cancellable = DictationController.shared.$state
            .removeDuplicates()
            .sink { [weak self] state in
                Task { @MainActor in self?.update(for: state) }
            }
    }

    private func update(for state: DictationController.State) {
        if state == .idle {
            panel.orderOut(nil)
        } else {
            if !panel.isVisible { position() }
            panel.orderFrontRegardless()
        }
    }

    /// Ubica la barra en la pantalla donde está el mouse, abajo al centro.
    private func position() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let origin = NSPoint(x: frame.midX - Self.size.width / 2, y: frame.minY + 18)
        panel.setFrame(NSRect(origin: origin, size: Self.size), display: true)
    }
}

struct FloatingBarView: View {
    @ObservedObject private var dictation = DictationController.shared

    var body: some View {
        HStack(spacing: 10) {
            switch dictation.state {
            case .listening:
                if dictation.isLocked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                }
                Waveform(levels: dictation.levels)
            case .processing:
                ProcessingDots()
            case .message(let text):
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
                Text(text)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            case .notice(let text):
                Image(systemName: "sparkles")
                    .foregroundStyle(.yellow)
                Text(text)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            case .idle:
                EmptyView()
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
        .background(Capsule().fill(Color.black.opacity(0.88)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 6)
    }
}

/// Barras que siguen el volumen de la voz.
struct Waveform: View {
    let levels: [Float]

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(Color.white)
                    .frame(width: 3, height: 4 + CGFloat(level) * 18)
            }
        }
        .frame(height: 22)
        .animation(.easeOut(duration: 0.08), value: levels)
    }
}

/// Tres puntos que se encienden por turnos mientras se transcribe y limpia.
struct ProcessingDots: View {
    var body: some View {
        TimelineView(.animation) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<3) { index in
                    let phase = (time * 2.4 - Double(index) * 0.35).truncatingRemainder(dividingBy: 1.2)
                    Circle()
                        .fill(Color.white)
                        .frame(width: 6, height: 6)
                        .opacity(phase < 0.5 ? 1 : 0.3)
                }
            }
        }
        .frame(width: 54, height: 22)
    }
}
