import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            DictionaryView()
                .tabItem { Label("Diccionario", systemImage: "character.book.closed") }
            PermissionsView()
                .tabItem { Label("Permisos", systemImage: "lock.shield") }
        }
        .frame(minWidth: 520, minHeight: 420)
    }
}

struct GeneralSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var model = ModelStatus.shared
    @ObservedObject private var permissions = Permissions.shared

    var body: some View {
        Form {
            if !permissions.allGranted {
                Section("Para empezar, da estos permisos") {
                    PermissionRow(
                        title: "Micrófono",
                        detail: "Para escuchar lo que dictas.",
                        granted: permissions.microphone == .authorized,
                        action: permissions.requestMicrophone
                    )
                    PermissionRow(
                        title: "Accesibilidad",
                        detail: "Para detectar el atajo y pegar el texto en cualquier app.",
                        granted: permissions.accessibility,
                        action: permissions.requestAccessibility
                    )
                }
            }
            Section("Dictado") {
                Picker("Mantén apretada", selection: $settings.hotkey) {
                    ForEach(Hotkey.allCases) { Text($0.label).tag($0) }
                }
                Text("Apriétala dos veces para dictar sin mantenerla. Otra vez para terminar, o Esc para descartar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if settings.hotkey == .fn && HotkeyMonitor.fnKeyHasSystemAction && !DictationController.shared.isInterceptingFn {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("La tecla Fn tiene otra acción en macOS (emojis o cambio de idioma). En Ajustes del Sistema → Teclado, cambia \"Al presionar la tecla 🌐\" a \"No hacer nada\".")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Button("Abrir ajustes de Teclado") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
                        }
                    }
                }
                Picker("Idioma", selection: $settings.language) {
                    ForEach(DictationLanguage.allCases) { Text($0.label).tag($0) }
                }
            }
            Section("Limpieza con Apple Intelligence") {
                Toggle("Limpiar el texto (puntuación, muletillas y correcciones)", isOn: $settings.cleanupEnabled)
                if settings.cleanupEnabled, let reason = TextCleaner.unavailableReason {
                    Text("\(reason) Mientras tanto se pega el texto tal como se transcribió.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Section("Modelo de voz") {
                Picker("Modelo", selection: $settings.voiceModel) {
                    ForEach(VoiceModel.allCases) { Text($0.label).tag($0) }
                }
                Text(settings.voiceModel.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Text(model.label)
                    Spacer()
                    if case .downloading(let progress) = model.state {
                        ProgressView(value: progress).frame(width: 120)
                    } else if model.state == .loading {
                        ProgressView().controlSize(.small)
                    } else if case .failed = model.state {
                        Button("Reintentar") { Task { try? await Transcriber.shared.prepare() } }
                    }
                }
            }
            Section("App") {
                Toggle("Abrir Eco al iniciar sesión", isOn: $settings.launchAtLogin)
            }
        }
        .formStyle(.grouped)
        .onAppear { permissions.startWatching() }
    }
}

struct PermissionsView: View {
    @ObservedObject private var permissions = Permissions.shared

    var body: some View {
        Form {
            Section {
                PermissionRow(
                    title: "Micrófono",
                    detail: "Para escuchar lo que dictas.",
                    granted: permissions.microphone == .authorized,
                    action: permissions.requestMicrophone
                )
                PermissionRow(
                    title: "Accesibilidad",
                    detail: "Para detectar el atajo y pegar el texto en cualquier app.",
                    granted: permissions.accessibility,
                    action: permissions.requestAccessibility
                )
            } footer: {
                Text("El de accesibilidad se activa en Ajustes del Sistema → Privacidad y seguridad → Accesibilidad.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { permissions.startWatching() }
        .onDisappear { permissions.stopWatching() }
    }
}

struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(granted ? .green : .orange)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted {
                Button("Dar permiso", action: action)
            }
        }
    }
}
