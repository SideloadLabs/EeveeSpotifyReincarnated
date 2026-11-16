import UIKit

// the Speed & pitch row in the player's ⋯ menu: a row like Spotify's own that opens in place onto the speed
// and pitch sliders. it sits in the menu table's header (or footer, when Spotify uses the header), so opening
// it resizes that view inside a table update and the rows under it move with it.
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
        Self.style(title, font: Self.font(.body), color: Self.primary)
        title.text = "speed_pitch".localized
        Self.style(summary, font: Self.digits(Self.font(.subheadline)), color: Self.secondary)
        summary.textAlignment = .right
        chevron.image = Self.symbol("chevron.down", size: 13, weight: .semibold, color: Self.secondary)
        chevron.contentMode = .center
        for view in [icon, title, summary, chevron] as [UIView] {
            view.isUserInteractionEnabled = false
            row.addSubview(view)
        }

        addSubview(panel)
        let nameFont = Self.font(.subheadline)
        Self.style(speedName, font: nameFont, color: Self.secondary)
        speedName.text = "speed_pitch_speed".localized
        Self.style(pitchName, font: nameFont, color: Self.secondary)
        pitchName.text = "speed_pitch_pitch".localized
        Self.style(followsName, font: nameFont, color: Self.primary)
        followsName.text = "speed_pitch_follows".localized
        speedSlider.accessibilityLabel = "speed_pitch_speed".localized
        pitchSlider.accessibilityLabel = "speed_pitch_pitch".localized
        follows.accessibilityLabel = "speed_pitch_follows".localized
        follows.addTarget(self, action: #selector(followsChanged), for: .valueChanged)
        for view in [speedName, speedValue, speedSlider, pitchName, pitchValue, pitchSlider, followsName, follows] as [UIView] {
            panel.addSubview(view)
        }

        refresh()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
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
        let speedAvailable = SpeedPitch.speedAvailable
        if !speedSlider.isTracking { shownSpeed = SpeedPitch.snapped(SpeedPitch.speed) }
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
        UIView.performWithoutAnimation {
            speedValue.setTitle(speedAvailable ? Self.speedText(shownSpeed) : unavailable, for: .normal)
            pitchValue.setTitle(!pitchAvailable ? unavailable : following ? "speed_pitch_follows_value".localized : Self.pitchText(pitch), for: .normal)
            speedValue.layoutIfNeeded()
            pitchValue.layoutIfNeeded()
        }
        let pitchFree = pitchAvailable && !following
        pitchSlider.isEnabled = pitchFree
        pitchSlider.alpha = pitchFree ? 1 : 0.4
        speedValue.isEnabled = speedAvailable && shownSpeed != 1
        pitchValue.isEnabled = pitchFree && pitch != 0
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
            if speedPending || SpeedPitch.snapped(SpeedPitch.speed) != shownSpeed { sendSpeed() }
        } else {
            slider.value = Float(shownPitch)
        }
    }

    private func sendSpeed() {
        speedPending = false
        speedSentAt = CACurrentMediaTime()
        SpeedPitch.speed = shownSpeed
    }

    @objc private func resetSpeed() {
        shownSpeed = 1
        sendSpeed()
        speedSlider.setValue(1, animated: true)
        showValues()
    }

    @objc private func resetPitch() {
        shownPitch = 0
        SpeedPitch.semitones = 0
        pitchSlider.setValue(0, animated: true)
        showValues()
    }

    @objc private func followsChanged() {
        UserDefaults.speedPitchOptions.pitchFollowsSpeed = follows.isOn
        SpeedPitch.applyPitchFollowsSpeed(follows.isOn)
        feedback.selectionChanged()
        refresh()
    }

    // MARK: - parts

    private func valueButton(_ reset: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.titleLabel?.font = Self.digits(Self.font(.subheadline, weight: .semibold))
        button.tintColor = Self.primary
        button.setTitleColor(Self.primary, for: .normal)
        button.setTitleColor(Self.primary.withAlphaComponent(0.4), for: .highlighted)
        button.setTitleColor(Self.primary, for: .disabled)
        button.contentHorizontalAlignment = .right
        button.accessibilityHint = "speed_pitch_reset_hint".localized
        button.addTarget(self, action: reset, for: .touchUpInside)
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

    private static func pitchText(_ pitch: Double) -> String {
        pitch == 0 ? "0" : "speed_pitch_semitones".localizeWithFormat(String(format: "%+.0f", pitch))
    }

    // MARK: - look, drawn from its own measures so it fits Spotify's sheet in any eevee appearance

    private static let primary = UIColor.white

    private static var secondary: UIColor {
        UIColor(white: 1, alpha: UIAccessibility.isDarkerSystemColorsEnabled ? 0.8 : 0.65)
    }

    // the system font at a text style's size, stopping at extra large so the row still fits.
    private static func font(_ style: UIFont.TextStyle, weight: UIFont.Weight = .regular) -> UIFont {
        var category = UIApplication.shared.preferredContentSizeCategory
        if category > .extraLarge { category = .extraLarge }
        let size = UIFont.preferredFont(forTextStyle: style, compatibleWith: UITraitCollection(preferredContentSizeCategory: category)).pointSize
        return .systemFont(ofSize: size, weight: weight)
    }

    // digits of one width, so a value doesn't shuffle as it counts.
    private static func digits(_ font: UIFont) -> UIFont {
        .monospacedDigitSystemFont(ofSize: font.pointSize, weight: font.fontDescriptor.weight)
    }

    private static func style(_ label: UILabel, font: UIFont, color: UIColor) {
        label.font = font
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

private extension UIFontDescriptor {
    var weight: UIFont.Weight {
        let traits = object(forKey: .traits) as? [UIFontDescriptor.TraitKey: Any]
        return (traits?[.weight] as? CGFloat).map { UIFont.Weight($0) } ?? .regular
    }
}
