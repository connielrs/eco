import AppKit
import ApplicationServices

/// Aprende de las correcciones: después de pegar un dictado, vuelve a leer el campo de texto
/// (con Accesibilidad) y, si se cambió una palabra por otra parecida, la agrega al diccionario.
/// Solo funciona en apps que dejan leer su texto; en las demás no hace nada.
@MainActor
final class CorrectionLearner {
    static let shared = CorrectionLearner()

    /// Muestra un aviso cuando aprende algo.
    var onLearned: ((String, String) -> Void)?

    private struct Pending {
        let element: AXUIElement
        let pid: pid_t
        let inserted: String
        let before: String
        let after: String
        let pastedAt: Date
    }

    private var pending: Pending?
    private var timer: Timer?
    private var activationObserver: Any?
    /// Se deja de vigilar un dictado después de este tiempo.
    private static let watchTime: TimeInterval = 180

    func start() {
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { CorrectionLearner.shared.check() }
        }
    }

    /// Se llama justo después de pegar: guarda el campo y el texto que quedó alrededor.
    func watch(inserted text: String) {
        check()
        guard let element = Self.focusedElement() else { return }
        // Esperar a que la app procese el pegado antes de leer.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard let value = Self.value(of: element),
                  let range = value.range(of: text, options: .backwards)
            else { return }
            var pid: pid_t = 0
            AXUIElementGetPid(element, &pid)
            self.pending = Pending(
                element: element,
                pid: pid,
                inserted: text,
                before: String(value[..<range.lowerBound]),
                after: String(value[range.upperBound...]),
                pastedAt: Date()
            )
            self.timer?.invalidate()
            self.timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in
                MainActor.assumeIsolated { CorrectionLearner.shared.check() }
            }
        }
    }

    /// Compara el texto actual del campo con lo que se pegó.
    func check() {
        guard let pending else { return }
        if Date().timeIntervalSince(pending.pastedAt) > Self.watchTime {
            stop()
            return
        }
        guard let value = Self.value(of: pending.element) else {
            stop()
            return
        }
        // Solo se mira el tramo del dictado: el texto de antes y de después tiene que seguir igual.
        guard value.hasPrefix(pending.before), value.hasSuffix(pending.after),
              value.count >= pending.before.count + pending.after.count
        else { return }
        let start = value.index(value.startIndex, offsetBy: pending.before.count)
        let end = value.index(value.endIndex, offsetBy: -pending.after.count)
        let edited = String(value[start..<end])
        guard edited != pending.inserted else { return }

        if let (wrong, right) = Self.correction(from: pending.inserted, to: edited), Self.isWorthLearning(wrong: wrong, right: right, in: edited) {
            PersonalDictionary.shared.learn(wrong: wrong, right: right)
            onLearned?(wrong, right)
            stop()
        }
    }

    private func stop() {
        pending = nil
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Comparación

    /// Busca un solo cambio pequeño y parecido entre el texto pegado y el editado.
    /// Devuelve (palabra mal transcrita, palabra corregida) o nil si fue otra cosa.
    nonisolated static func correction(from original: String, to edited: String) -> (String, String)? {
        let old = words(original)
        let new = words(edited)
        guard !old.isEmpty, !new.isEmpty else { return nil }

        // Quitar las palabras iguales del principio y del final.
        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < old.count - prefix, suffix < new.count - prefix,
              old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }

        let oldSpan = Array(old[prefix..<(old.count - suffix)])
        let newSpan = Array(new[prefix..<(new.count - suffix)])
        // Un solo cambio chico: hasta 3 palabras que pasan a ser 1 o 2 (por ejemplo "Guru vic" → "Guruvic").
        guard (1...3).contains(oldSpan.count), (1...2).contains(newSpan.count) else { return nil }

        let wrong = oldSpan.joined(separator: " ")
        let right = newSpan.joined(separator: " ")
        // Ignorar cambios de mayúsculas o tildes: dependen del contexto ("esta" / "está").
        guard fold(wrong) != fold(right) else { return nil }
        guard right.count >= 3, right.contains(where: \.isLetter) else { return nil }

        // Tienen que parecerse: si cambió por una palabra muy distinta, es una edición, no una corrección.
        let a = fold(wrong).replacingOccurrences(of: " ", with: "")
        let b = fold(right).replacingOccurrences(of: " ", with: "")
        let distance = levenshtein(Array(a), Array(b))
        guard Double(distance) <= Double(max(a.count, b.count)) * 0.5 else { return nil }
        return (wrong, right)
    }

    /// Evita aprender cambios de estilo ("cositas" → "cosas"). Se aprende si lo transcrito no es una
    /// palabra real ("Kurao"), o si la corrección es un nombre propio: con mayúscula en medio de la frase
    /// ("Connie" → "Coni", "cloud code" → "Claude Code"). Al inicio de una frase la mayúscula no cuenta,
    /// para no aprender cosas como "Ya" → "Yo".
    static func isWorthLearning(wrong: String, right: String, in edited: String) -> Bool {
        let wrongIsReal = wrong.split(separator: " ").allSatisfy { isRealWord(String($0)) }
        if !wrongIsReal { return true }
        guard right.first?.isUppercase == true, let range = edited.range(of: right) else { return false }
        let before = edited[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
        guard let previous = before.last else { return false }
        return !".!?¡¿\n:".contains(previous)
    }

    private static func isRealWord(_ word: String) -> Bool {
        let checker = NSSpellChecker.shared
        for language in ["es", "en"] {
            let range = checker.checkSpelling(
                of: word, startingAt: 0, language: language, wrap: false,
                inSpellDocumentWithTag: 0, wordCount: nil
            )
            if range.location == NSNotFound { return true }
        }
        return false
    }

    nonisolated private static func words(_ text: String) -> [String] {
        text.split { !($0.isLetter || $0.isNumber || $0 == "'" || $0 == "-") }.map(String.init)
    }

    nonisolated private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "es"))
    }

    nonisolated private static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var previous = Array(0...b.count)
        for (i, ca) in a.enumerated() {
            var current = [i + 1] + Array(repeating: 0, count: b.count)
            for (j, cb) in b.enumerated() {
                current[j + 1] = min(previous[j + 1] + 1, current[j] + 1, previous[j] + (ca == cb ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }

    // MARK: - Accesibilidad

    private static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.3)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return nil }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.3)
        return element
    }

    private static func value(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
