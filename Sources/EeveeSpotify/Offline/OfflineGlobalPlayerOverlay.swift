import UIKit
import MediaPlayer
import AVFoundation

public final class OfflineGlobalPlayerOverlay: UIView {
    public static let shared = OfflineGlobalPlayerOverlay()

    private let coverImageView = UIImageView()
    private let titleLabel = UILabel()
    private let artistLabel = UILabel()
    private let timeLabel = UILabel()
    private let scrubberSlider = UISlider()

    private let downloadedIcon = UIImageView()
    private let playPauseButton = UIButton(type: .system)
    private let nextButton = UIButton(type: .system)
    private let closeButton = UIButton(type: .system)
    private var controlsStack: UIStackView!

    private var updateTimer: Timer?
    private var isDraggingSlider = false
    private var hiddenSpotifyBars: [(view: UIView, hidden: Bool, alpha: CGFloat)] = []
    private var scanTickCount: Int = 0
    private var displayedTrackID: String?

    private override init(frame: CGRect) {
        super.init(frame: frame)
        setupUI()
        setupGestures()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
        setupGestures()
    }

    private func setupUI() {
        backgroundColor = UIColor(red: 33/255, green: 33/255, blue: 33/255, alpha: 0.98)
        layer.cornerRadius = 8
        layer.masksToBounds = false
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.55
        layer.shadowRadius = 8
        layer.shadowOffset = CGSize(width: 0, height: -2)

        coverImageView.translatesAutoresizingMaskIntoConstraints = false
        coverImageView.contentMode = .scaleAspectFill
        coverImageView.layer.cornerRadius = 4
        coverImageView.layer.masksToBounds = true
        coverImageView.backgroundColor = UIColor(white: 0.2, alpha: 1.0)
        coverImageView.image = UIImage(systemName: "music.note")
        coverImageView.tintColor = .white
        addSubview(coverImageView)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = UIFont.systemFont(ofSize: 13, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(titleLabel)

        artistLabel.translatesAutoresizingMaskIntoConstraints = false
        artistLabel.font = UIFont.systemFont(ofSize: 11, weight: .regular)
        artistLabel.textColor = UIColor(white: 0.72, alpha: 1.0)
        artistLabel.lineBreakMode = .byTruncatingTail
        artistLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(artistLabel)

        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        timeLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        timeLabel.textColor = UIColor(white: 0.55, alpha: 1.0)
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(timeLabel)

        let confCheck = UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        let confPlay = UIImage.SymbolConfiguration(pointSize: 24, weight: .bold)
        let confClose = UIImage.SymbolConfiguration(pointSize: 14, weight: .medium)

        downloadedIcon.image = UIImage(systemName: "checkmark.circle.fill", withConfiguration: confCheck)
        downloadedIcon.tintColor = UIColor(red: 30/255, green: 215/255, blue: 96/255, alpha: 1.0)
        downloadedIcon.contentMode = .scaleAspectFit
        downloadedIcon.isAccessibilityElement = true
        downloadedIcon.accessibilityLabel = "offline_downloaded".localized

        playPauseButton.setImage(UIImage(systemName: "pause.fill", withConfiguration: confPlay), for: .normal)
        playPauseButton.tintColor = .white
        playPauseButton.addTarget(self, action: #selector(didTapPlayPause), for: .touchUpInside)

        nextButton.setImage(UIImage(systemName: "forward.fill", withConfiguration: confCheck), for: .normal)
        nextButton.tintColor = .white
        nextButton.addTarget(self, action: #selector(didTapNext), for: .touchUpInside)

        closeButton.setImage(UIImage(systemName: "xmark", withConfiguration: confClose), for: .normal)
        closeButton.tintColor = UIColor(white: 0.6, alpha: 1.0)
        closeButton.addTarget(self, action: #selector(didTapClose), for: .touchUpInside)

        controlsStack = UIStackView(arrangedSubviews: [downloadedIcon, playPauseButton, nextButton, closeButton])
        controlsStack.axis = .horizontal
        controlsStack.spacing = 5
        controlsStack.alignment = .center
        controlsStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(controlsStack)

        scrubberSlider.translatesAutoresizingMaskIntoConstraints = false
        scrubberSlider.minimumTrackTintColor = UIColor(red: 30/255, green: 215/255, blue: 96/255, alpha: 1.0)
        scrubberSlider.maximumTrackTintColor = UIColor(white: 0.22, alpha: 1.0)
        let normalThumb = createThumbImage(size: 4, color: UIColor(red: 30/255, green: 215/255, blue: 96/255, alpha: 1.0))
        let highlightedThumb = createThumbImage(size: 10, color: .white)
        scrubberSlider.setThumbImage(normalThumb, for: .normal)
        scrubberSlider.setThumbImage(highlightedThumb, for: .highlighted)
        scrubberSlider.addTarget(self, action: #selector(sliderTouchDown), for: .touchDown)
        scrubberSlider.addTarget(self, action: #selector(sliderValueChanged), for: .valueChanged)
        scrubberSlider.addTarget(self, action: #selector(sliderTouchUp), for: [.touchUpInside, .touchUpOutside])
        addSubview(scrubberSlider)

        NSLayoutConstraint.activate([
            coverImageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            coverImageView.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -2),
            coverImageView.widthAnchor.constraint(equalToConstant: 40),
            coverImageView.heightAnchor.constraint(equalToConstant: 40),

            titleLabel.leadingAnchor.constraint(equalTo: coverImageView.trailingAnchor, constant: 10),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: controlsStack.leadingAnchor, constant: -8),

            artistLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            artistLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            artistLabel.trailingAnchor.constraint(lessThanOrEqualTo: timeLabel.leadingAnchor, constant: -6),

            timeLabel.leadingAnchor.constraint(equalTo: artistLabel.trailingAnchor, constant: 6),
            timeLabel.centerYAnchor.constraint(equalTo: artistLabel.centerYAnchor),
            timeLabel.trailingAnchor.constraint(lessThanOrEqualTo: controlsStack.leadingAnchor, constant: -8),

            controlsStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            controlsStack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -2),
            downloadedIcon.widthAnchor.constraint(equalToConstant: 20),
            downloadedIcon.heightAnchor.constraint(equalToConstant: 20),
            playPauseButton.widthAnchor.constraint(equalToConstant: 34),
            nextButton.widthAnchor.constraint(equalToConstant: 34),
            closeButton.widthAnchor.constraint(equalToConstant: 30),
            playPauseButton.heightAnchor.constraint(equalToConstant: 44),
            nextButton.heightAnchor.constraint(equalTo: playPauseButton.heightAnchor),
            closeButton.heightAnchor.constraint(equalTo: playPauseButton.heightAnchor),

            scrubberSlider.bottomAnchor.constraint(equalTo: bottomAnchor, constant: 2),
            scrubberSlider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            scrubberSlider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            scrubberSlider.heightAnchor.constraint(equalToConstant: 4)
        ])
    }

    private var lastOverlayTapTime: TimeInterval = 0

    private func setupGestures() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(didTapOverlay))
        tap.cancelsTouchesInView = false
        addGestureRecognizer(tap)
    }

    @objc private func didTapOverlay(_ recognizer: UITapGestureRecognizer) {
        let loc = recognizer.location(in: self)
        if controlsStack.frame.contains(loc) || scrubberSlider.frame.contains(loc) {
            return
        }

        let now = Date().timeIntervalSince1970
        guard now - lastOverlayTapTime > 0.4 else { return }
        lastOverlayTapTime = now

        let targetWindow = window ?? OfflinePresentationHelper.activeWindow
        OfflineNowPlayingViewController.shared.show(in: targetWindow)
    }

    public func show(track: OfflineTrack) {
        guard let window = OfflinePresentationHelper.activeWindow,
              let host = window.rootViewController?.viewIfLoaded else { return }

        layer.removeAllAnimations()
        transform = .identity
        alpha = 1
        updateVisibility()

        updateMetadata(track: track)
        findAndHideSpotifyBars(in: window)

        if superview !== host {
            removeFromSuperview()
            host.addSubview(self)
            translatesAutoresizingMaskIntoConstraints = false

            NSLayoutConstraint.activate([
                leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 8),
                trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -8),
                bottomAnchor.constraint(equalTo: host.safeAreaLayoutGuide.bottomAnchor, constant: -56),
                heightAnchor.constraint(equalToConstant: 58)
            ])
        }

        startTimer()
    }

    func updateVisibility() {
        isHidden = OfflineNowPlayingViewController.isPresented
        if !isHidden { superview?.bringSubviewToFront(self) }
    }

    public func hide() {
        stopTimer()
        UIView.animate(withDuration: 0.25, animations: {
            self.transform = CGAffineTransform(translationX: 0, y: 70)
            self.alpha = 0
        }) { _ in
            if OfflinePlaybackController.shared.currentTrack == nil {
                self.removeFromSuperview()
                self.transform = .identity
                self.restoreSpotifyBars()
            }
        }
    }

    public func updateMetadata(track: OfflineTrack) {
        displayedTrackID = track.id
        titleLabel.text = track.title
        artistLabel.text = track.artist

        let coverFile = OfflineLibraryStore.storesDirectory.appendingPathComponent("\(track.id).jpg")
        if FileManager.default.fileExists(atPath: coverFile.path), let img = UIImage(contentsOfFile: coverFile.path) {
            coverImageView.image = img
        } else {
            coverImageView.image = UIImage(systemName: "music.note")
        }
    }

    private func startTimer() {
        stopTimer()
        updateTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            self?.refreshProgress()
        }
    }

    private func stopTimer() {
        updateTimer?.invalidate()
        updateTimer = nil
    }

    private func refreshProgress() {
        let controller = OfflinePlaybackController.shared
        guard let track = controller.currentTrack else {
            hide()
            return
        }

        if !isDraggingSlider {
            let dur = max(controller.duration, 1.0)
            let curr = controller.currentTime
            scrubberSlider.maximumValue = Float(dur)
            scrubberSlider.value = Float(curr)

            let curStr = formatSeconds(curr)
            let durStr = formatSeconds(dur)
            timeLabel.text = "• \(curStr)/\(durStr)"
        }

        let isPlaying = controller.isPlaying
        let confPlay = UIImage.SymbolConfiguration(pointSize: 25, weight: .bold)
        let iconName = isPlaying ? "pause.fill" : "play.fill"
        playPauseButton.setImage(UIImage(systemName: iconName, withConfiguration: confPlay), for: .normal)

        if displayedTrackID != track.id {
            updateMetadata(track: track)
        }

        for (view, _, _) in hiddenSpotifyBars {
            if !view.isHidden {
                view.isHidden = true
                view.alpha = 0
            }
        }

        scanTickCount += 1
        if scanTickCount % 5 == 0 {
            if let window = OfflinePresentationHelper.activeWindow {
                findAndHideSpotifyBars(in: window)
            }
        }
    }

    private func createThumbImage(size: CGFloat, color: UIColor) -> UIImage {
        UIGraphicsBeginImageContextWithOptions(CGSize(width: size, height: size), false, 0.0)
        let ctx = UIGraphicsGetCurrentContext()
        ctx?.setFillColor(color.cgColor)
        ctx?.fillEllipse(in: CGRect(x: 0, y: 0, width: size, height: size))
        let img = UIGraphicsGetImageFromCurrentImageContext() ?? UIImage()
        UIGraphicsEndImageContext()
        return img
    }

    private func formatSeconds(_ sec: TimeInterval) -> String {
        guard sec.isFinite && !sec.isNaN && sec >= 0 else { return "0:00" }
        let m = Int(sec) / 60
        let s = Int(sec) % 60
        return String(format: "%d:%02d", m, s)
    }

    private var lastPlayPauseTapTime: TimeInterval = 0

    @objc private func didTapPlayPause() {
        let now = Date().timeIntervalSince1970
        guard now - lastPlayPauseTapTime > 0.3 else { return }
        lastPlayPauseTapTime = now

        OfflinePlaybackController.shared.togglePlayPause()
        refreshProgress()
    }

    @objc private func didTapNext() {
        _ = OfflinePlaybackController.shared.playNext()
        refreshProgress()
    }

    @objc private func didTapClose() {
        OfflinePlaybackController.shared.stop()
        hide()
    }

    @objc private func sliderTouchDown() {
        isDraggingSlider = true
    }

    @objc private func sliderValueChanged() {
        let current = TimeInterval(scrubberSlider.value)
        let total = OfflinePlaybackController.shared.duration
        timeLabel.text = "• \(formatSeconds(current))/\(formatSeconds(total))"
    }

    @objc private func sliderTouchUp() {
        isDraggingSlider = false
        OfflinePlaybackController.shared.seek(to: TimeInterval(scrubberSlider.value))
    }

    private func findTabBarView(in view: UIView) -> UIView? {
        if view === self || view.isDescendant(of: self) { return nil }
        if view is UITabBar { return view }

        let className = NSStringFromClass(type(of: view)).lowercased()
        let isTab = className.contains("tabbar") || className.contains("tab_bar") || className.contains("bottomnavigation")
        if isTab && view.frame.height >= 40 && view.frame.height <= 110 {
            return view
        }

        for sub in view.subviews {
            if let found = findTabBarView(in: sub) {
                return found
            }
        }
        return nil
    }

    private func findAndHideSpotifyBars(in window: UIWindow) {
        guard let root = window.rootViewController?.view else { return }
        collectSpotifyBars(in: root)

    }

    private func collectSpotifyBars(in view: UIView) {
        if view === self || view.isDescendant(of: self) { return }
        if view is UITabBar { return }

        let className = NSStringFromClass(type(of: view)).lowercased()
        if className.contains("tabbar") || className.contains("tab_bar") || className.contains("bottomnavigation") {
            return
        }

        let isPlayerBar = className.contains("nowplaying") ||
                          className.contains("playback") ||
                          className.contains("baroverlay") ||
                          className.contains("minibar") ||
                          className.contains("npv") ||
                          className.contains("gaia") ||
                          className.contains("connectbar")

        if isPlayerBar, view.bounds.height > 0, view.bounds.height <= 90,
           !className.contains("cell"), !className.contains("scroll"),
           !hiddenSpotifyBars.contains(where: { $0.view === view }) {
            hiddenSpotifyBars.append((view, view.isHidden, view.alpha))
            view.isHidden = true
            view.alpha = 0
        }
        for sub in view.subviews {
            collectSpotifyBars(in: sub)
        }
    }

    private func restoreSpotifyBars() {
        for (view, hidden, alpha) in hiddenSpotifyBars {
            view.isHidden = hidden
            view.alpha = alpha
        }
        hiddenSpotifyBars.removeAll()
    }
}
