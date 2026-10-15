import AppKit

// Modo de prueba por línea de comandos: `Eco --transcribe archivo.wav`.
if CommandLine.arguments.count > 2, CommandLine.arguments[1].hasPrefix("--") {
    Task {
        let code = await CommandLineTool.run(Array(CommandLine.arguments.dropFirst()))
        exit(code)
    }
    RunLoop.main.run()
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
