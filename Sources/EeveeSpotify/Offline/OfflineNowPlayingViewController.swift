import UIKit
import MediaPlayer
import AVFoundation

public final class OfflineNowPlayingViewController: UIViewController {
    public static let shared = OfflineNowPlayingViewController()
    public static var isPresented = false

    private let gradientLayer = CAGradientLayer()

    private let dismissButton = UIButton(type: .system)
    private let headerTitleLabel = UILabel()
    private let headerSubtitleLabel = UILabel()
    private let optionsButton = UIButton(type: .system)

    private let artworkImageView = UIImageView()
    private let artworkShadowView = UIView()

    private let titleLabel = UILabel()
    private let artistLabel = UILabel()
    private let offlineCheckmarkView = UIImageView()

    private let scrubberSlider = UISlider()
    private let timeElapsedLabel = UILabel()
    private let timeRemainingLabel = UILabel()

    private let shuffleButton = UIButton(type: .system)
    private let prevButton = UIButton(type: .system)
    private let playPauseButton = UIButton(type: .system)
    private let nextButton = UIButton(type: .system)
    private let repeatButton = UIButton(type: .system)

    private let deviceIconView = UIImageView()
    private let deviceLabel = UILabel()
    private let queueButton = UIButton(type: .system)

    private var updateTimer: Timer?
    private var isDraggingScrubber = false

    public override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        setupBackground()
        setupUI()
        setupGestures()
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        gradientLayer.frame = view.bounds
        artworkShadowView.layer.shadowPath = UIBezierPath(roundedRect: artworkShadowView.bounds, cornerRadius: 10).cgPath
    }

    public func show(in targetWindow: UIWindow? = nil) {
        guard let window = targetWindow ?? OfflinePresentationHelper.activeWindow,
              let host = window.rootViewController?.viewIfLoaded,
              !OfflineNowPlayingViewController.isPresented else { return }
        OfflineNowPlayingViewController.isPresented = true
        OfflineGlobalPlayerOverlay.shared.updateVisibility()

        loadViewIfNeeded()
        view.frame = host.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.transform = CGAffineTransform(translationX: 0, y: host.bounds.height)
        host.addSubview(view)

        updateUI()
        startTimer()

        UIView.animate(
            withDuration: 0.35,
            delay: 0,
            usingSpringWithDamping: 0.88,
            initialSpringVelocity: 0.5,
            options: [.curveEaseOut],
            animations: {
                self.view.transform = .identity
            }
        )
    }

    @objc public func didTapDismiss() {
        guard OfflineNowPlayingViewController.isPresented else { return }
        stopTimer()
        UIView.animate(withDuration: 0.25, animations: {
            self.view.transform = CGAffineTransform(translationX: 0, y: self.view.bounds.height)
        }) { _ in
            self.view.removeFromSuperview()
            self.view.transform = .identity
            OfflineNowPlayingViewController.isPresented = false
            OfflineGlobalPlayerOverlay.shared.updateVisibility()
        }
    }

    private func setupBackground() {
        view.backgroundColor = UIColor(red: 18/255, green: 18/255, blue: 18/255, alpha: 1.0)
        gradientLayer.colors = [
            UIColor(red: 45/255, green: 45/255, blue: 48/255, alpha: 1.0).cgColor,
            UIColor(red: 18/255, green: 18/255, blue: 18/255, alpha: 1.0).cgColor
        ]
        gradientLayer.locations = [0.0, 0.65]
        view.layer.insertSublayer(gradientLayer, at: 0)
    }

    private func setupUI() {
        let confHeader = UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
        dismissButton.setImage(UIImage(systemName: "chevron.down", withConfiguration: confHeader), for: .normal)
        dismissButton.tintColor = .white
        dismissButton.addTarget(self, action: #selector(didTapDismiss), for: .touchUpInside)
        dismissButton.translatesAutoresizingMaskIntoConstraints = false

        headerTitleLabel.text = "offline_playing_from".localized
        headerTitleLabel.font = UIFont.systemFont(ofSize: 10, weight: .bold)
        headerTitleLabel.textColor = UIColor(white: 0.7, alpha: 1.0)
        headerTitleLabel.textAlignment = .center
        headerTitleLabel.translatesAutoresizingMaskIntoConstraints = false

        headerSubtitleLabel.text = "offline_downloaded_tracks".localized
        headerSubtitleLabel.font = UIFont.systemFont(ofSize: 12, weight: .bold)
        headerSubtitleLabel.textColor = .white
        headerSubtitleLabel.textAlignment = .center
        headerSubtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        let headerTextStack = UIStackView(arrangedSubviews: [headerTitleLabel, headerSubtitleLabel])
        headerTextStack.axis = .vertical
        headerTextStack.spacing = 2
        headerTextStack.alignment = .center
        headerTextStack.translatesAutoresizingMaskIntoConstraints = false

        optionsButton.setImage(UIImage(systemName: "ellipsis", withConfiguration: confHeader), for: .normal)
        optionsButton.tintColor = .white
        optionsButton.addTarget(self, action: #selector(didTapOptions), for: .touchUpInside)
        optionsButton.translatesAutoresizingMaskIntoConstraints = false

        artworkShadowView.backgroundColor = .clear
        artworkShadowView.layer.shadowColor = UIColor.black.cgColor
        artworkShadowView.layer.shadowOpacity = 0.55
        artworkShadowView.layer.shadowRadius = 18
        artworkShadowView.layer.shadowOffset = CGSize(width: 0, height: 8)
        artworkShadowView.translatesAutoresizingMaskIntoConstraints = false

        artworkImageView.contentMode = .scaleAspectFill
        artworkImageView.layer.cornerRadius = 10
        artworkImageView.layer.masksToBounds = true
        artworkImageView.backgroundColor = UIColor(white: 0.15, alpha: 1.0)
        artworkImageView.translatesAutoresizingMaskIntoConstraints = false
        artworkShadowView.addSubview(artworkImageView)

        titleLabel.font = UIFont.systemFont(ofSize: 21, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        artistLabel.font = UIFont.systemFont(ofSize: 15, weight: .medium)
        artistLabel.textColor = UIColor(white: 0.72, alpha: 1.0)
        artistLabel.lineBreakMode = .byTruncatingTail
        artistLabel.translatesAutoresizingMaskIntoConstraints = false

        let metadataStack = UIStackView(arrangedSubviews: [titleLabel, artistLabel])
        metadataStack.axis = .vertical
        metadataStack.spacing = 3
        metadataStack.translatesAutoresizingMaskIntoConstraints = false

        let confCheck = UIImage.SymbolConfiguration(pointSize: 22, weight: .bold)
        offlineCheckmarkView.image = UIImage(systemName: "checkmark.circle.fill", withConfiguration: confCheck)
        offlineCheckmarkView.tintColor = UIColor(red: 30/255, green: 215/255, blue: 96/255, alpha: 1.0)
        offlineCheckmarkView.translatesAutoresizingMaskIntoConstraints = false

        scrubberSlider.minimumTrackTintColor = .white
        scrubberSlider.maximumTrackTintColor = UIColor(white: 0.28, alpha: 1.0)
        let thumbImg = createThumbImage(size: 10, color: .white)
        scrubberSlider.setThumbImage(thumbImg, for: .normal)
        scrubberSlider.setThumbImage(createThumbImage(size: 14, color: .white), for: .highlighted)
        scrubberSlider.addTarget(self, action: #selector(sliderTouchDown), for: .touchDown)
        scrubberSlider.addTarget(self, action: #selector(sliderValueChanged), for: .valueChanged)
        scrubberSlider.addTarget(self, action: #selector(sliderTouchUp), for: [.touchUpInside, .touchUpOutside])
        scrubberSlider.translatesAutoresizingMaskIntoConstraints = false

        timeElapsedLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        timeElapsedLabel.textColor = UIColor(white: 0.65, alpha: 1.0)
        timeElapsedLabel.text = "0:00"
        timeElapsedLabel.translatesAutoresizingMaskIntoConstraints = false

        timeRemainingLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        timeRemainingLabel.textColor = UIColor(white: 0.65, alpha: 1.0)
        timeRemainingLabel.text = "-0:00"
        timeRemainingLabel.textAlignment = .right
        timeRemainingLabel.translatesAutoresizingMaskIntoConstraints = false

        let confCtrl = UIImage.SymbolConfiguration(pointSize: 20, weight: .regular)
        let confSkip = UIImage.SymbolConfiguration(pointSize: 26, weight: .medium)

        shuffleButton.setImage(UIImage(systemName: "shuffle", withConfiguration: confCtrl), for: .normal)
        shuffleButton.tintColor = UIColor(white: 0.7, alpha: 1.0)
        shuffleButton.addTarget(self, action: #selector(didTapShuffle), for: .touchUpInside)

        prevButton.setImage(UIImage(systemName: "backward.end.fill", withConfiguration: confSkip), for: .normal)
        prevButton.tintColor = .white
        prevButton.addTarget(self, action: #selector(didTapPrev), for: .touchUpInside)

        playPauseButton.backgroundColor = .white
        playPauseButton.layer.cornerRadius = 32
        playPauseButton.tintColor = .black
        playPauseButton.layer.masksToBounds = true
        playPauseButton.setImage(UIImage(systemName: "pause.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 24, weight: .bold)), for: .normal)
        playPauseButton.addTarget(self, action: #selector(didTapPlayPause), for: .touchUpInside)
        playPauseButton.translatesAutoresizingMaskIntoConstraints = false

        nextButton.setImage(UIImage(systemName: "forward.end.fill", withConfiguration: confSkip), for: .normal)
        nextButton.tintColor = .white
        nextButton.addTarget(self, action: #selector(didTapNext), for: .touchUpInside)

        repeatButton.setImage(UIImage(systemName: "repeat", withConfiguration: confCtrl), for: .normal)
        repeatButton.tintColor = UIColor(white: 0.7, alpha: 1.0)
        repeatButton.addTarget(self, action: #selector(didTapRepeat), for: .touchUpInside)

        let controlsStack = UIStackView(arrangedSubviews: [shuffleButton, prevButton, playPauseButton, nextButton, repeatButton])
        controlsStack.axis = .horizontal
        controlsStack.distribution = .equalSpacing
        controlsStack.alignment = .center
        controlsStack.translatesAutoresizingMaskIntoConstraints = false

        let confDev = UIImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        deviceIconView.image = UIImage(systemName: "speaker.wave.2.fill", withConfiguration: confDev)
        deviceIconView.tintColor = UIColor(red: 30/255, green: 215/255, blue: 96/255, alpha: 1.0)
        deviceIconView.translatesAutoresizingMaskIntoConstraints = false

        deviceLabel.text = "offline_this_device".localized
        deviceLabel.font = UIFont.systemFont(ofSize: 12, weight: .semibold)
        deviceLabel.textColor = UIColor(red: 30/255, green: 215/255, blue: 96/255, alpha: 1.0)
        deviceLabel.translatesAutoresizingMaskIntoConstraints = false

        let devStack = UIStackView(arrangedSubviews: [deviceIconView, deviceLabel])
        devStack.axis = .horizontal
        devStack.spacing = 6
        devStack.alignment = .center
        devStack.translatesAutoresizingMaskIntoConstraints = false

        queueButton.setImage(UIImage(systemName: "list.bullet", withConfiguration: confHeader), for: .normal)
        queueButton.tintColor = .white
        queueButton.addTarget(self, action: #selector(didTapQueue), for: .touchUpInside)
        queueButton.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(dismissButton)
        view.addSubview(headerTextStack)
        view.addSubview(optionsButton)
        view.addSubview(artworkShadowView)
        view.addSubview(metadataStack)
        view.addSubview(offlineCheckmarkView)
        view.addSubview(scrubberSlider)
        view.addSubview(timeElapsedLabel)
        view.addSubview(timeRemainingLabel)
        view.addSubview(controlsStack)
        view.addSubview(devStack)
        view.addSubview(queueButton)

        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            dismissButton.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 18),
            dismissButton.centerYAnchor.constraint(equalTo: headerTextStack.centerYAnchor),
            dismissButton.widthAnchor.constraint(equalToConstant: 32),
            dismissButton.heightAnchor.constraint(equalToConstant: 32),

            headerTextStack.topAnchor.constraint(equalTo: safe.topAnchor, constant: 8),
            headerTextStack.centerXAnchor.constraint(equalTo: safe.centerXAnchor),

            optionsButton.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -18),
            optionsButton.centerYAnchor.constraint(equalTo: headerTextStack.centerYAnchor),
            optionsButton.widthAnchor.constraint(equalToConstant: 32),
            optionsButton.heightAnchor.constraint(equalToConstant: 32),

            artworkShadowView.topAnchor.constraint(equalTo: headerTextStack.bottomAnchor, constant: 28),
            artworkShadowView.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 32),
            artworkShadowView.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -32),
            artworkShadowView.heightAnchor.constraint(equalTo: artworkShadowView.widthAnchor),

            artworkImageView.leadingAnchor.constraint(equalTo: artworkShadowView.leadingAnchor),
            artworkImageView.trailingAnchor.constraint(equalTo: artworkShadowView.trailingAnchor),
            artworkImageView.topAnchor.constraint(equalTo: artworkShadowView.topAnchor),
            artworkImageView.bottomAnchor.constraint(equalTo: artworkShadowView.bottomAnchor),

            metadataStack.topAnchor.constraint(equalTo: artworkShadowView.bottomAnchor, constant: 26),
            metadataStack.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 32),
            metadataStack.trailingAnchor.constraint(lessThanOrEqualTo: offlineCheckmarkView.leadingAnchor, constant: -12),

            offlineCheckmarkView.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -32),
            offlineCheckmarkView.centerYAnchor.constraint(equalTo: metadataStack.centerYAnchor),
            offlineCheckmarkView.widthAnchor.constraint(equalToConstant: 26),
            offlineCheckmarkView.heightAnchor.constraint(equalToConstant: 26),

            scrubberSlider.topAnchor.constraint(equalTo: metadataStack.bottomAnchor, constant: 20),
            scrubberSlider.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 30),
            scrubberSlider.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -30),
            scrubberSlider.heightAnchor.constraint(equalToConstant: 16),

            timeElapsedLabel.topAnchor.constraint(equalTo: scrubberSlider.bottomAnchor, constant: 4),
            timeElapsedLabel.leadingAnchor.constraint(equalTo: scrubberSlider.leadingAnchor),

            timeRemainingLabel.topAnchor.constraint(equalTo: scrubberSlider.bottomAnchor, constant: 4),
            timeRemainingLabel.trailingAnchor.constraint(equalTo: scrubberSlider.trailingAnchor),

            controlsStack.topAnchor.constraint(equalTo: timeElapsedLabel.bottomAnchor, constant: 14),
            controlsStack.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 28),
            controlsStack.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -28),

            playPauseButton.widthAnchor.constraint(equalToConstant: 64),
            playPauseButton.heightAnchor.constraint(equalToConstant: 64),

            devStack.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 32),
            devStack.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -12),

            queueButton.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -32),
            queueButton.centerYAnchor.constraint(equalTo: devStack.centerYAnchor),
            queueButton.widthAnchor.constraint(equalToConstant: 32),
            queueButton.heightAnchor.constraint(equalToConstant: 32)
        ])
    }

    private func setupGestures() {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
        view.addGestureRecognizer(pan)
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: view)
        let velocity = gesture.velocity(in: view)

        switch gesture.state {
        case .changed:
            if translation.y > 0 {
                view.transform = CGAffineTransform(translationX: 0, y: translation.y)
            }
        case .ended, .cancelled:
            if translation.y > 120 || velocity.y > 600 {
                didTapDismiss()
            } else {
                UIView.animate(withDuration: 0.25) {
                    self.view.transform = .identity
                }
            }
        default:
            break
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

    private var displayedTrackID: String?

    public func updateUI() {
        guard let track = OfflinePlaybackController.shared.currentTrack else {
            didTapDismiss()
            return
        }

        displayedTrackID = track.id
        titleLabel.text = track.title
        artistLabel.text = track.artist

        let coverFile = OfflineLibraryStore.storesDirectory.appendingPathComponent("\(track.id).jpg")
        if FileManager.default.fileExists(atPath: coverFile.path), let img = UIImage(contentsOfFile: coverFile.path) {
            artworkImageView.image = img
            updateBackgroundGradient(from: img)
        } else {
            artworkImageView.image = UIImage(systemName: "music.note")
        }

        let isPlaying = OfflinePlaybackController.shared.isPlaying
        let confIcon = UIImage.SymbolConfiguration(pointSize: 24, weight: .bold)
        let iconName = isPlaying ? "pause.fill" : "play.fill"
        playPauseButton.setImage(UIImage(systemName: iconName, withConfiguration: confIcon), for: .normal)

        let green = UIColor(red: 30/255, green: 215/255, blue: 96/255, alpha: 1.0)
        shuffleButton.tintColor = OfflinePlaybackController.shared.isShuffleEnabled ? green : UIColor(white: 0.7, alpha: 1.0)
        repeatButton.tintColor = OfflinePlaybackController.shared.isRepeatEnabled ? green : UIColor(white: 0.7, alpha: 1.0)
    }

    private func updateBackgroundGradient(from image: UIImage) {
        guard let cgImg = image.cgImage else { return }
        let color = averageColor(from: cgImg)
        UIView.animate(withDuration: 0.3) {
            self.gradientLayer.colors = [
                color.cgColor,
                UIColor(red: 18/255, green: 18/255, blue: 18/255, alpha: 1.0).cgColor
            ]
        }
    }

    private func averageColor(from cgImg: CGImage) -> UIColor {
        let width = 1
        let height = 1
        var rgba = [UInt8](repeating: 0, count: 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let ctx = CGContext(data: &rgba, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 4, space: colorSpace, bitmapInfo: bitmapInfo.rawValue) else {
            return UIColor(red: 45/255, green: 45/255, blue: 48/255, alpha: 1.0)
        }
        ctx.draw(cgImg, in: CGRect(x: 0, y: 0, width: width, height: height))
        let r = CGFloat(rgba[0]) / 255.0
        let g = CGFloat(rgba[1]) / 255.0
        let b = CGFloat(rgba[2]) / 255.0
        return UIColor(red: min(r * 0.7, 0.45), green: min(g * 0.7, 0.45), blue: min(b * 0.7, 0.45), alpha: 1.0)
    }

    private func startTimer() {
        stopTimer()
        updateTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
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
            didTapDismiss()
            return
        }

        if displayedTrackID != track.id {
            updateUI()
        }

        if !isDraggingScrubber {
            let dur = max(controller.duration, 1.0)
            let curr = controller.currentTime
            scrubberSlider.maximumValue = Float(dur)
            scrubberSlider.value = Float(curr)

            timeElapsedLabel.text = formatSeconds(curr)
            let rem = dur - curr
            timeRemainingLabel.text = "-\(formatSeconds(rem))"
        }

        let isPlaying = controller.isPlaying
        let confIcon = UIImage.SymbolConfiguration(pointSize: 24, weight: .bold)
        let iconName = isPlaying ? "pause.fill" : "play.fill"
        playPauseButton.setImage(UIImage(systemName: iconName, withConfiguration: confIcon), for: .normal)
    }

    private func formatSeconds(_ sec: TimeInterval) -> String {
        guard sec.isFinite && !sec.isNaN && sec >= 0 else { return "0:00" }
        let m = Int(sec) / 60
        let s = Int(sec) % 60
        return String(format: "%d:%02d", m, s)
    }

    @objc private func didTapPlayPause() {
        OfflinePlaybackController.shared.togglePlayPause()
        refreshProgress()
    }

    @objc private func didTapPrev() {
        _ = OfflinePlaybackController.shared.playPrevious()
        updateUI()
    }

    @objc private func didTapNext() {
        _ = OfflinePlaybackController.shared.playNext()
        updateUI()
    }

    @objc private func didTapShuffle() {
        OfflinePlaybackController.shared.toggleShuffle()
        updateUI()
    }

    @objc private func didTapRepeat() {
        OfflinePlaybackController.shared.toggleRepeat()
        updateUI()
    }

    @objc private func didTapQueue() {
        didTapDismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
            OfflineLibraryViewController.present()
        }
    }

    @objc private func didTapOptions() {
        guard let track = OfflinePlaybackController.shared.currentTrack else { return }
        let alert = UIAlertController(title: track.title, message: track.artist, preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "offline_remove_track".localized, style: .destructive) { [weak self] _ in
            do {
                try OfflineLibraryStore.shared.removeDownloaded(id: track.id)
                self?.didTapDismiss()
            } catch {
                OfflineDownloadPillHUD.shared.completeError(title: track.title, errorMessage: error.localizedDescription)
            }
        })
        alert.addAction(UIAlertAction(title: "offline_close".localized, style: .cancel))
        if let pop = alert.popoverPresentationController {
            pop.sourceView = optionsButton
            pop.sourceRect = optionsButton.bounds
        }
        OfflinePresentationHelper.safePresent(alert)
    }

    @objc private func sliderTouchDown() {
        isDraggingScrubber = true
    }

    @objc private func sliderValueChanged() {
        let current = TimeInterval(scrubberSlider.value)
        let total = OfflinePlaybackController.shared.duration
        timeElapsedLabel.text = formatSeconds(current)
        timeRemainingLabel.text = "-\(formatSeconds(max(0, total - current)))"
    }

    @objc private func sliderTouchUp() {
        isDraggingScrubber = false
        OfflinePlaybackController.shared.seek(to: TimeInterval(scrubberSlider.value))
    }
}
