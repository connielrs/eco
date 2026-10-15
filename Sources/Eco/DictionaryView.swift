import SwiftUI

/// Campos del formulario para agregar palabras.
/// (Se usa un ObservableObject porque @State necesita las macros de Xcode.)
final class DictionaryForm: ObservableObject {
    @Published var newWord = ""
    @Published var newSoundsLike = ""
}

struct DictionaryView: View {
    @ObservedObject private var dictionary = PersonalDictionary.shared
    @StateObject private var form = DictionaryForm()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Nombres y términos que Eco tiene que escribir siempre igual. En \"Se transcribe como\" pon, separadas por coma, las formas en que suele salir mal.")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack {
                TextField("Palabra (ej. Guruvic)", text: $form.newWord)
                TextField("Se transcribe como (ej. Gurubik, Guru Vic)", text: $form.newSoundsLike)
                Button("Agregar") {
                    dictionary.add(word: form.newWord, soundsLike: form.newSoundsLike)
                    form.newWord = ""
                    form.newSoundsLike = ""
                }
                .disabled(form.newWord.trimmingCharacters(in: .whitespaces).isEmpty)
                .keyboardShortcut(.defaultAction)
            }

            Table($dictionary.entries) {
                TableColumn("Palabra") { $entry in
                    TextField("Palabra", text: $entry.word)
                }
                TableColumn("Se transcribe como") { $entry in
                    TextField("Variantes", text: $entry.soundsLike)
                }
                TableColumn("") { $entry in
                    Button {
                        dictionary.remove(entry)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Borrar")
                }
                .width(28)
            }
        }
        .padding()
    }
}
