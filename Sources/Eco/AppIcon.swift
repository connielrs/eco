import AppKit

/// Estilos de ícono que se pueden elegir en Ajustes.
enum AppIconStyle: String, CaseIterable, Identifiable {
    case dark
    case light

    var id: String { rawValue }

    var label: String {
        switch self {
        case .dark: return "Oscuro"
        case .light: return "Claro"
        }
    }
}

/// Dibuja el logo de Eco (una onda de cinco barras) y lo aplica como ícono de la app.
/// Se dibuja con código para no depender de archivos de imagen ni de Xcode.
enum EcoIcon {
    /// Alturas de las cinco barras, como fracción del lado del ícono.
    private static let barHeights: [CGFloat] = [18, 38, 58, 38, 18].map { $0 / 104 }
    private static let barWidth: CGFloat = 7 / 104
    private static let barStep: CGFloat = 12 / 104

    private static let darkBackground = NSColor(srgbRed: 0.11, green: 0.11, blue: 0.118, alpha: 1)

    /// Ícono de la app en el estilo pedido, con el margen y las esquinas que usa macOS.
    static func appIcon(_ style: AppIconStyle, size: CGFloat = 1024) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            // Cuadrado redondeado: 824/1024 del lienzo, como los íconos de macOS.
            let side = rect.width * 824 / 1024
            let body = NSRect(x: (rect.width - side) / 2, y: (rect.height - side) / 2 + rect.height * 0.01,
                              width: side, height: side)
            let shape = NSBezierPath(roundedRect: body, xRadius: side * 0.225, yRadius: side * 0.225)

            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
            shadow.shadowBlurRadius = rect.width * 0.012
            shadow.shadowOffset = NSSize(width: 0, height: -rect.width * 0.008)
            shadow.set()
            (style == .dark ? darkBackground : NSColor.white).setFill()
            shape.fill()
            NSGraphicsContext.restoreGraphicsState()

            if style == .light {
                NSColor.black.withAlphaComponent(0.08).setStroke()
                shape.lineWidth = max(1, rect.width * 0.002)
                shape.stroke()
            }

            (style == .dark ? NSColor.white : darkBackground).setFill()
            drawBars(in: body)
            return true
        }
    }

    /// Ícono de la barra de menú: solo la onda, en blanco y negro para que macOS lo adapte al modo.
    static func menuBarImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            NSColor.black.setFill()
            // Un poco más grande que en el ícono de la app, porque acá no hay fondo.
            drawBars(in: rect.insetBy(dx: -3, dy: -3), widthScale: 1.25)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Eco"
        return image
    }

    private static func drawBars(in box: NSRect, widthScale: CGFloat = 1) {
        let width = box.width * barWidth * widthScale
        let step = box.width * barStep
        for (index, fraction) in barHeights.enumerated() {
            let height = box.height * fraction
            let centerX = box.midX + CGFloat(index - 2) * step
            let bar = NSRect(x: centerX - width / 2, y: box.midY - height / 2, width: width, height: height)
            NSBezierPath(roundedRect: bar, xRadius: width / 2, yRadius: width / 2).fill()
        }
    }

    /// Aplica el estilo como ícono de la app (Finder, Ajustes del Sistema, listas de permisos).
    /// El oscuro viene incluido en la app; el claro se pone como ícono personalizado.
    static func apply(_ style: AppIconStyle) {
        let path = Bundle.main.bundlePath
        guard path.hasSuffix(".app") else { return }
        if style == .dark {
            NSWorkspace.shared.setIcon(nil, forFile: path, options: [])
        } else {
            NSWorkspace.shared.setIcon(appIcon(style), forFile: path, options: [])
        }
        NSApp.applicationIconImage = appIcon(style, size: 512)
    }

    /// Escribe el set de íconos que necesita `iconutil` para generar AppIcon.icns.
    static func writeIconset(_ style: AppIconStyle, to folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for base in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let pixels = CGFloat(base * scale)
                let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
                try png(appIcon(style, size: pixels), pixels: Int(pixels)).write(to: folder.appendingPathComponent(name))
            }
        }
    }

    static func png(_ image: NSImage, pixels: Int) -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        )!
        rep.size = NSSize(width: pixels, height: pixels)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:]) ?? Data()
    }
}
