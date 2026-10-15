import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            PermissionsView()
                .tabItem { Label("Permisos", systemImage: "lock.shield") }
        }
        .frame(minWidth: 520, minHeight: 420)
    }
}

struct GeneralSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section("Dictado") {
                Picker("Mantén apretada", selection: $settings.hotkey) {
                    ForEach(Hotkey.allCases) { Text($0.label).tag($0) }
                }
                Picker("Idioma", selection: $settings.language) {
                    ForEach(DictationLanguage.allCases) { Text($0.label).tag($0) }
                }
            }
            Section("App") {
                Toggle("Abrir Eco al iniciar sesión", isOn: $settings.launchAtLogin)
            }
        }
        .formStyle(.grouped)
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
