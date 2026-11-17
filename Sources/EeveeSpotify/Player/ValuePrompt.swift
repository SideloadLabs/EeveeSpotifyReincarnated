import UIKit

// boxes to type into, for the speed & pitch menu and the equalizer: a value finer than a slider's steps or past
// its ends (opened by holding a value), and a name.
enum ValuePrompt {
    static func make(title: String, value: Double, range: ClosedRange<Double>, text: (Double) -> String,
                     keyboard: UIKeyboardType, dark: Bool = false, set: @escaping (Double) -> Void) -> UIAlertController {
        let alert = UIAlertController(title: title, message: "speed_pitch_range".localizeWithFormat(text(range.lowerBound), text(range.upperBound)),
                                      preferredStyle: .alert)
        if dark { alert.overrideUserInterfaceStyle = .dark }
        let typed = { [weak alert] in number(alert?.textFields?.first?.text).flatMap { range.contains($0) ? $0 : nil } }
        let ok = UIAlertAction(title: "OK".uiKitLocalized, style: .default) { _ in
            if let value = typed() { set(value) }
        }
        ok.isEnabled = false
        alert.addTextField { field in
            field.placeholder = editable(value)
            field.keyboardType = keyboard
            if dark { field.keyboardAppearance = .dark }
            field.textAlignment = .center
            field.addAction(UIAction { _ in ok.isEnabled = typed() != nil }, for: .editingChanged)
        }
        alert.addAction(UIAlertAction(title: "Cancel".uiKitLocalized, style: .cancel))
        alert.addAction(ok)
        alert.preferredAction = ok
        return alert
    }

    // a box to type a name; OK only once there is one.
    static func name(title: String, message: String?, placeholder: String, done: @escaping (String) -> Void) -> UIAlertController {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        let typed = { [weak alert] in (alert?.textFields?.first?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        let ok = UIAlertAction(title: "OK".uiKitLocalized, style: .default) { _ in
            if !typed().isEmpty { done(typed()) }
        }
        ok.isEnabled = false
        alert.addTextField { field in
            field.placeholder = placeholder
            field.autocapitalizationType = .sentences
            field.addAction(UIAction { _ in ok.isEnabled = !typed().isEmpty }, for: .editingChanged)
        }
        alert.addAction(UIAlertAction(title: "Cancel".uiKitLocalized, style: .cancel))
        alert.addAction(ok)
        alert.preferredAction = ok
        return alert
    }

    // over whatever is on top, from a settings page.
    static func present(_ controller: UIViewController) {
        var host = WindowHelper.shared.rootViewController
        while let presented = host.presentedViewController, !presented.isBeingDismissed { host = presented }
        host.present(controller, animated: true)
    }

    // up to two decimals, without trailing zeros.
    static func plain(_ value: Double) -> String {
        var number = String(format: "%.2f", value)
        while number.contains("."), number.hasSuffix("0") || number.hasSuffix(".") { number.removeLast() }
        return number
    }

    // a value as it's typed: no unit, the locale's decimal mark.
    static func editable(_ value: Double) -> String {
        plain(value).replacingOccurrences(of: ".", with: Locale.current.decimalSeparator ?? ".")
    }

    // the typed number to hundredths, with either decimal mark and any sign or unit around it.
    static func number(_ text: String?) -> Double? {
        guard let text else { return nil }
        let digits = text.replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: "\u{2212}", with: "-")
            .filter { "0123456789.+-".contains($0) }
        return Double(digits).map(hundredths)
    }

    // values typed, slid and held are all kept to hundredths, so they compare equal to what was shown.
    static func hundredths(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }
}
