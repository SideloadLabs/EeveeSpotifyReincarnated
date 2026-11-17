import CoreText
import UIKit

// the Speed & pitch row in the player's ⋯ menu: a row like Spotify's own that opens in place onto the speed
// and pitch sliders; holding a value opens a box to type one. it sits in the menu table's header (or footer,
// when Spotify uses the header), so opening it resizes that view inside a table update and the rows under it
// move with it.
final class SpeedPitchMenuView: UIView {
    private static let rowHeight: CGFloat = 56
    private static let sliderHeight: CGFloat = 72
    private static let switchHeight: CGFloat = 44
    private static let panelBottom: CGFloat = 12
    private static let margin: CGFloat = 16
    private static let gap: CGFloat = 8
    // speed goes to the engine at most this often while the slider moves.
    private static let speedInterval: CFTimeInterval = 0.05

    // open or closed for the rest of the session.
    private static var isOpen = false

    static func height() -> CGFloat {
        rowHeight + (isOpen ? 2 * sliderHeight + switchHeight + panelBottom : 0)
    }

    weak var table: UITableView?
    var inFooter = false

    private let row = UIControl()
    private let icon = UIImageView()
    private let title = UILabel()
    private let summary = UILabel()
    private let chevron = UIImageView()
    private let panel = UIView()
    private let speedName = UILabel()
    private let pitchName = UILabel()
    private let followsName = UILabel()
    private lazy var speedValue = valueButton(#selector(resetSpeed))
    private lazy var pitchValue = valueButton(#selector(resetPitch))
    private lazy var speedSlider = slider(range: SpeedPitch.speedRange, normal: 1, low: "tortoise.fill", high: "hare.fill")
    private lazy var pitchSlider = slider(range: SpeedPitch.pitchRange, normal: 0, low: "arrow.down", high: "arrow.up")
    private let follows = UISwitch()
    private let feedback = UISelectionFeedbackGenerator()

    private var shownSpeed = 1.0
    private var shownPitch = 0.0
    private var speedSentAt: CFTimeInterval = 0
    private var speedPending = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        backgroundColor = .clear
        // every color is set where it's drawn, so nothing flashes the system blue as the sheet appears.
        tintColor = Self.primary

        row.addTarget(self, action: #selector(toggle), for: .touchUpInside)
        row.addTarget(self, action: #selector(highlightRow), for: [.touchDown, .touchDragEnter])
        row.addTarget(self, action: #selector(unhighlightRow), for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
        row.isAccessibilityElement = true
        row.accessibilityTraits = .button
        addSubview(row)

        icon.image = Self.symbol("speedometer", size: 20, color: Self.secondary)
        icon.contentMode = .center
        Self.style(title, color: Self.primary)
        title.text = "speed_pitch".localized
        Self.style(summary, color: Self.secondary)
        summary.textAlignment = .right
        chevron.image = Self.symbol("chevron.down", size: 13, weight: .semibold, color: Self.secondary)
        chevron.contentMode = .center
        for view in [icon, title, summary, chevron] as [UIView] {
            view.isUserInteractionEnabled = false
            row.addSubview(view)
        }

        addSubview(panel)
        Self.style(speedName, color: Self.secondary)
        speedName.text = "speed_pitch_speed".localized
        Self.style(pitchName, color: Self.secondary)
        pitchName.text = "speed_pitch_pitch".localized
        Self.style(followsName, color: Self.primary)
        followsName.text = "speed_pitch_follows".localized
        speedSlider.accessibilityLabel = "speed_pitch_speed".localized
        pitchSlider.accessibilityLabel = "speed_pitch_pitch".localized
        follows.accessibilityLabel = "speed_pitch_follows".localized
        follows.addTarget(self, action: #selector(followsChanged), for: .valueChanged)
        for view in [speedName, speedValue, speedSlider, pitchName, pitchValue, pitchSlider, followsName, follows] as [UIView] {
            panel.addSubview(view)
        }

        applyFonts()
        refresh()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        adoptRowFont()
        let width = bounds.width, margin = Self.margin, rowHeight = Self.rowHeight
        row.frame = CGRect(x: 0, y: 0, width: width, height: rowHeight)
        icon.frame = CGRect(x: margin, y: (rowHeight - 24) / 2, width: 24, height: 24)
        chevron.frame = CGRect(x: width - margin - 20, y: (rowHeight - 20) / 2, width: 20, height: 20)
        let titleX = margin + 24 + margin
        let titleWidth = min(title.sizeThatFits(CGSize(width: .greatestFiniteMagnitude, height: rowHeight)).width,
                             chevron.frame.minX - titleX - Self.gap)
        title.frame = CGRect(x: titleX, y: 0, width: max(0, titleWidth), height: rowHeight)
        let summaryX = title.frame.maxX + Self.gap
        summary.frame = CGRect(x: summaryX, y: 0, width: max(0, chevron.frame.minX - Self.gap - summaryX), height: rowHeight)

        panel.frame = CGRect(x: 0, y: rowHeight, width: width, height: 2 * Self.sliderHeight + Self.switchHeight + Self.panelBottom)
        var y: CGFloat = 0
        for (name, value, slider) in [(speedName, speedValue, speedSlider), (pitchName, pitchValue, pitchSlider)] {
            name.frame = CGRect(x: margin, y: y + 4, width: width / 2 - margin, height: 24)
            value.frame = CGRect(x: width / 2, y: y + 4, width: width / 2 - margin, height: 24)
            slider.frame = CGRect(x: margin, y: y + 30, width: width - 2 * margin, height: 36)
            slider.layoutIfNeeded()
            Self.placeTick(on: slider)
            y += Self.sliderHeight
        }
        let size = follows.sizeThatFits(.zero)
        follows.frame = CGRect(x: width - margin - size.width, y: y + (Self.switchHeight - size.height) / 2, width: size.width, height: size.height)
        followsName.frame = CGRect(x: margin, y: y, width: max(0, follows.frame.minX - margin - Self.gap), height: Self.switchHeight)
    }

    // MARK: - state

    // what the engine has now, onto the controls (not while a finger is on one).
    func refresh() {
        adoptRowFont()
        let speedAvailable = SpeedPitch.speedAvailable
        if !speedSlider.isTracking { shownSpeed = SpeedPitch.speed }
        if !pitchSlider.isTracking { shownPitch = SpeedPitch.semitones }
        speedSlider.value = Float(shownSpeed)
        pitchSlider.value = Float(shownPitch)
        speedSlider.isEnabled = speedAvailable
        speedSlider.alpha = speedAvailable ? 1 : 0.4
        // following needs the engine in Spotify's chain, which the pitch-only fallback isn't.
        follows.isOn = UserDefaults.speedPitchOptions.pitchFollowsSpeed
        follows.isEnabled = speedAvailable
        follows.alpha = speedAvailable ? 1 : 0.4
        followsName.alpha = follows.alpha
        showValues()
    }

    private func showValues() {
        let speedAvailable = SpeedPitch.speedAvailable, pitchAvailable = SpeedPitch.pitchAvailable
        // while pitch follows a speed off normal, the speed sets the pitch and the semitones aren't played.
        let following = speedAvailable && follows.isOn && shownSpeed != 1
        let pitch = following ? 0 : shownPitch
        let unavailable = "speed_pitch_unavailable".localized
        // a speed set before the engine lost Spotify's output still shows, so a tap can put it back to 1x.
        let kept = !speedAvailable && shownSpeed != 1
        UIView.performWithoutAnimation {
            speedValue.setTitle(speedAvailable || kept ? Self.speedText(shownSpeed) : unavailable, for: .normal)
            pitchValue.setTitle(!pitchAvailable ? unavailable : following ? "speed_pitch_follows_value".localized : Self.pitchText(pitch), for: .normal)
            speedValue.layoutIfNeeded()
            pitchValue.layoutIfNeeded()
        }
        let pitchFree = pitchAvailable && !following
        pitchSlider.isEnabled = pitchFree
        pitchSlider.alpha = pitchFree ? 1 : 0.4
        // on at normal too, for holding.
        speedValue.isEnabled = speedAvailable || kept
        pitchValue.isEnabled = pitchFree
        speedValue.accessibilityHint = shownSpeed != 1 ? "speed_pitch_reset_hint".localized : nil
        pitchValue.accessibilityHint = pitch != 0 ? "speed_pitch_reset_hint".localized : nil
        speedSlider.accessibilityValue = speedAvailable ? Self.speedText(shownSpeed) : unavailable
        pitchSlider.accessibilityValue = following ? "speed_pitch_follows_value".localized : Self.pitchText(pitch)

        var changed: [String] = []
        if shownSpeed != 1 { changed.append(Self.speedText(shownSpeed)) }
        if pitch != 0 { changed.append(Self.pitchText(pitch)) }
        summary.text = Self.isOpen ? nil : changed.joined(separator: "  ")
        row.accessibilityLabel = (["speed_pitch".localized] + changed).joined(separator: ", ")
        row.accessibilityValue = (Self.isOpen ? "speed_pitch_expanded" : "speed_pitch_collapsed").localized
        chevron.transform = Self.isOpen ? CGAffineTransform(rotationAngle: .pi) : .identity
        panel.alpha = Self.isOpen ? 1 : 0
        panel.accessibilityElementsHidden = !Self.isOpen
    }

    // MARK: - actions

    @objc private func highlightRow() {
        row.backgroundColor = UIColor(white: 1, alpha: 0.08)
    }

    @objc private func unhighlightRow() {
        UIView.animate(withDuration: 0.2) { self.row.backgroundColor = .clear }
    }

    @objc private func toggle() {
        Self.isOpen.toggle()
        if Self.isOpen { refresh() }
        guard let table else { return }
        var frame = self.frame
        frame.size.height = Self.height()
        let animations = {
            table.beginUpdates()
            self.frame = frame
            if self.inFooter { table.tableFooterView = self } else { table.tableHeaderView = self }
            self.showValues()
            self.layoutIfNeeded()
            table.endUpdates()
        }
        let completion = { (_: Bool) in
            if Self.isOpen { table.scrollRectToVisible(table.convert(self.bounds, from: self), animated: true) }
        }
        if UIAccessibility.isReduceMotionEnabled {
            UIView.performWithoutAnimation(animations)
            completion(true)
        } else {
            UIView.animate(withDuration: 0.45, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 0,
                           options: [.allowUserInteraction, .beginFromCurrentState], animations: animations, completion: completion)
        }
        // the sheet sizes itself to the table, so it has to measure again.
        table.invalidateIntrinsicContentSize()
        var sheet = table.superview
        for _ in 0..<4 {
            sheet?.setNeedsLayout()
            sheet = sheet?.superview
        }
        UIAccessibility.post(notification: .layoutChanged, argument: Self.isOpen ? speedSlider : nil)
    }

    @objc private func sliderMoved(_ slider: UISlider) {
        if slider === speedSlider {
            let speed = SpeedPitch.snapped(Double(slider.value))
            guard speed != shownSpeed else { return }
            if speed == 1 || shownSpeed == 1 { feedback.selectionChanged() }
            shownSpeed = speed
            let wait = Self.speedInterval - (CACurrentMediaTime() - speedSentAt)
            if wait <= 0 {
                sendSpeed()
            } else if !speedPending {
                speedPending = true
                DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                    if let self, self.speedPending { self.sendSpeed() }
                }
            }
        } else {
            let pitch = Double(slider.value).rounded()
            guard pitch != shownPitch else { return }
            if pitch == 0 || shownPitch == 0 { feedback.selectionChanged() }
            shownPitch = pitch
            SpeedPitch.semitones = pitch
        }
        showValues()
    }

    @objc private func sliderReleased(_ slider: UISlider) {
        if slider === speedSlider {
            slider.value = Float(shownSpeed)
            if speedPending || SpeedPitch.speed != shownSpeed { sendSpeed() }
        } else {
            slider.value = Float(shownPitch)
        }
    }

    private func sendSpeed() {
        speedPending = false
        speedSentAt = CACurrentMediaTime()
        SpeedPitch.speed = shownSpeed
    }

    private func setSpeed(_ speed: Double) {
        shownSpeed = speed
        sendSpeed()
        speedSlider.setValue(Float(speed), animated: true)
        showValues()
    }

    private func setPitch(_ pitch: Double) {
        shownPitch = pitch
        SpeedPitch.semitones = pitch
        pitchSlider.setValue(Float(pitch), animated: true)
        showValues()
    }

    @objc private func resetSpeed() {
        if shownSpeed != 1 { setSpeed(1) }
    }

    @objc private func resetPitch() {
        if shownPitch != 0 { setPitch(0) }
    }

    @objc private func held(_ press: UILongPressGestureRecognizer) {
        // while speed is unavailable only a tap's reset is taken, so there's nothing to type.
        guard press.state == .began, let value = press.view, value !== speedValue || SpeedPitch.speedAvailable else { return }
        feedback.selectionChanged()
        askValue(for: value)
    }

    private func askValue(for value: UIView) {
        if value === speedValue {
            ask("speed_pitch_speed".localized, value: shownSpeed, range: SpeedPitch.typedSpeedRange, text: Self.speedText,
                keyboard: .decimalPad) { [weak self] in self?.setSpeed($0) }
        } else {
            ask("speed_pitch_pitch".localized, value: shownPitch, range: SpeedPitch.typedPitchRange, text: Self.pitchText,
                keyboard: .numbersAndPunctuation) { [weak self] in self?.setPitch($0) }
        }
    }

    // dark like the sheet it opens over.
    private func ask(_ title: String, value: Double, range: ClosedRange<Double>, text: (Double) -> String,
                     keyboard: UIKeyboardType, set: @escaping (Double) -> Void) {
        guard let host = presenter() else { return }
        host.present(ValuePrompt.make(title: title, value: value, range: range, text: text, keyboard: keyboard, dark: true, set: set),
                     animated: true)
    }

    // the controller on top of the sheet this row is in.
    private func presenter() -> UIViewController? {
        var responder: UIResponder? = next
        while let current = responder, !(current is UIViewController) { responder = current.next }
        var host = responder as? UIViewController
        while let presented = host?.presentedViewController, !presented.isBeingDismissed { host = presented }
        return host
    }

    @objc private func followsChanged() {
        UserDefaults.speedPitchOptions.pitchFollowsSpeed = follows.isOn
        SpeedPitch.applyPitchFollowsSpeed(follows.isOn)
        feedback.selectionChanged()
        refresh()
    }

    // MARK: - parts

    // a tap resets the value; holding it, or VoiceOver's action, opens the box to type one.
    private func valueButton(_ reset: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.tintColor = Self.primary
        button.setTitleColor(Self.primary, for: .normal)
        button.setTitleColor(Self.primary.withAlphaComponent(0.4), for: .highlighted)
        button.setTitleColor(Self.primary, for: .disabled)
        button.contentHorizontalAlignment = .right
        button.addTarget(self, action: reset, for: .touchUpInside)
        button.addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(held(_:))))
        button.accessibilityCustomActions = [UIAccessibilityCustomAction(name: "speed_pitch_type".localized) { [weak self, weak button] _ in
            guard let self, let button, button.isEnabled else { return false }
            self.askValue(for: button)
            return true
        }]
        return button
    }

    // normal sits mid-track rather than at an end, so neither side fills; a tick marks where normal is.
    private func slider(range: ClosedRange<Double>, normal: Float, low: String, high: String) -> UISlider {
        let slider = UISlider()
        slider.minimumValue = Float(range.lowerBound)
        slider.maximumValue = Float(range.upperBound)
        let track = UIColor(white: 1, alpha: 0.2)
        slider.minimumTrackTintColor = track
        slider.maximumTrackTintColor = track
        slider.minimumValueImage = Self.endImage(low, size: 13)
        slider.maximumValueImage = Self.endImage(high, size: 17)
        let tick = TickView()
        tick.backgroundColor = Self.secondary
        tick.layer.cornerRadius = 1
        tick.isUserInteractionEnabled = false
        tick.normal = normal
        slider.insertSubview(tick, at: 0)
        slider.addTarget(self, action: #selector(sliderMoved(_:)), for: .valueChanged)
        slider.addTarget(self, action: #selector(sliderReleased(_:)), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        return slider
    }

    private final class TickView: UIView {
        var normal: Float = 0
    }

    // the tick at normal's x on the track, found the way the thumb is placed.
    private static func placeTick(on slider: UISlider) {
        guard let tick = slider.subviews.first(where: { $0 is TickView }) as? TickView else { return }
        let track = slider.trackRect(forBounds: slider.bounds)
        let thumb = slider.thumbRect(forBounds: slider.bounds, trackRect: track, value: tick.normal)
        tick.frame = CGRect(x: thumb.midX.rounded() - 1, y: track.midY - 6, width: 2, height: 12)
        slider.sendSubviewToBack(tick)
    }

    private static func speedText(_ speed: Double) -> String {
        String(format: "%.2f×", speed)
    }

    // whole semitones without decimals, a typed fraction with them.
    private static func pitchText(_ pitch: Double) -> String {
        pitch == 0 ? "0" : "speed_pitch_semitones".localizeWithFormat((pitch < 0 ? "" : "+") + ValuePrompt.plain(pitch))
    }

    // MARK: - look, drawn from its own measures so it fits Spotify's sheet in any eevee appearance

    private static let primary = UIColor.white

    private static var secondary: UIColor {
        UIColor(white: 1, alpha: UIAccessibility.isDarkerSystemColorsEnabled ? 0.8 : 0.65)
    }

    // the face of Spotify's own menu rows, read off them, so the row follows whatever font Spotify ships.
    private static var rowFont: UIFont?
    // until those rows are found; nil (the system font) if Spotify renames it.
    private static let standIn = UIFont(name: "SpotifyMixUI-Regular", size: 16)

    private func applyFonts() {
        let name = Self.font(.subheadline)
        title.font = Self.titleFont()
        summary.font = Self.digits(name)
        for label in [speedName, pitchName, followsName] { label.font = name }
        for button in [speedValue, pitchValue] { button.titleLabel?.font = Self.digits(Self.font(.subheadline, bold: true)) }
    }

    // the table makes its rows before laying out its header, so this usually lands before the menu is drawn;
    // refresh() tries again as it appears.
    private func adoptRowFont() {
        guard Self.rowFont == nil, let table, let found = Self.spotifyRowFont(in: table) else { return }
        Self.rowFont = found
        eeveeLog("[EeveeSpotify][SpeedPitch] menu font %@ %.1f, from Spotify's rows", found.fontName, found.pointSize)
        applyFonts()
        setNeedsLayout()
    }

    // the face most of the rows' labels use, so the track's own title at the top isn't the one taken.
    private static func spotifyRowFont(in table: UITableView) -> UIFont? {
        var faces: [String: (font: UIFont, count: Int)] = [:]
        var queue: [UIView] = table.visibleCells
        while let view = queue.popLast() {
            queue += view.subviews
            guard let label = view as? UILabel, !label.isHidden, label.text?.isEmpty == false else { continue }
            // styled text carries its own font, which the label's font property may not reflect.
            guard let font = label.attributedText?.attribute(.font, at: 0, effectiveRange: nil) as? UIFont ?? label.font else { continue }
            faces["\(font.fontName) \(font.pointSize)", default: (font, 0)].count += 1
        }
        return faces.values.max { $0.count < $1.count }?.font
    }

    // a text style's size, stopping at extra large so the row still fits.
    private static func size(_ style: UIFont.TextStyle) -> CGFloat {
        var category = UIApplication.shared.preferredContentSizeCategory
        if category > .extraLarge { category = .extraLarge }
        return UIFont.preferredFont(forTextStyle: style, compatibleWith: UITraitCollection(preferredContentSizeCategory: category)).pointSize
    }

    private static func font(_ style: UIFont.TextStyle, bold: Bool = false) -> UIFont {
        let points = size(style)
        guard let face = rowFont ?? standIn else { return .systemFont(ofSize: points, weight: bold ? .semibold : .regular) }
        let descriptor = face.fontDescriptor
        guard bold, let boldFace = descriptor.withSymbolicTraits(descriptor.symbolicTraits.union(.traitBold)) else { return face.withSize(points) }
        return UIFont(descriptor: boldFace, size: points)
    }

    // as Spotify sets its own row titles.
    private static func titleFont() -> UIFont {
        guard let rowFont else { return font(.body) }
        return rowFont.withSize(min(rowFont.pointSize, size(.body)))
    }

    // digits of one width where the face has them, so a value doesn't shuffle as it counts.
    private static func digits(_ font: UIFont) -> UIFont {
        let tabular: [UIFontDescriptor.FeatureKey: Any] = [
            UIFontDescriptor.FeatureKey(kCTFontOpenTypeFeatureTag as String): "tnum",
            UIFontDescriptor.FeatureKey(kCTFontOpenTypeFeatureValue as String): 1,
        ]
        return UIFont(descriptor: font.fontDescriptor.addingAttributes([.featureSettings: [tabular]]), size: font.pointSize)
    }

    private static func style(_ label: UILabel, color: UIColor) {
        label.textColor = color
        label.adjustsFontForContentSizeCategory = false
    }

    // a glyph with its color drawn in, so it never passes through a tint.
    private static func symbol(_ name: String, size: CGFloat, weight: UIImage.SymbolWeight = .regular, color: UIColor) -> UIImage? {
        UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: size, weight: weight))?
            .withTintColor(color, renderingMode: .alwaysOriginal)
    }

    // a glyph centered in a box of one size, so both sliders' tracks start and end at the same x.
    private static func endImage(_ name: String, size: CGFloat) -> UIImage? {
        guard let glyph = symbol(name, size: size, weight: .medium, color: secondary) else { return nil }
        let box = CGSize(width: 24, height: 24)
        return UIGraphicsImageRenderer(size: box).image { _ in
            glyph.draw(at: CGPoint(x: (box.width - glyph.size.width) / 2, y: (box.height - glyph.size.height) / 2))
        }
    }
}
