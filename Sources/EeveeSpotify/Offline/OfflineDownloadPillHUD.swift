import UIKit

public class CircularProgressView: UIView {
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let trackLayer = CAShapeLayer()
    private let progressLayer = CAShapeLayer()
    private let iconImageView = UIImageView()
    private let percentLabel = UILabel()

    public override init(frame: CGRect) {
        super.init(frame: frame)
        setupUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    private func setupUI() {
        backgroundColor = .clear

        spinner.color = UIColor(red: 30/255, green: 215/255, blue: 96/255, alpha: 1.0)
        spinner.hidesWhenStopped = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(spinner)

        trackLayer.strokeColor = UIColor(white: 0.3, alpha: 0.6).cgColor
        trackLayer.fillColor = UIColor.clear.cgColor
        trackLayer.lineWidth = 3.0
        trackLayer.lineCap = .round
        layer.addSublayer(trackLayer)

        progressLayer.strokeColor = UIColor(red: 30/255, green: 215/255, blue: 96/255, alpha: 1.0).cgColor
        progressLayer.fillColor = UIColor.clear.cgColor
        progressLayer.lineWidth = 3.0
        progressLayer.lineCap = .round
        progressLayer.strokeEnd = 0.0
        layer.addSublayer(progressLayer)

        percentLabel.font = UIFont.systemFont(ofSize: 9, weight: .bold)
        percentLabel.textColor = .white
        percentLabel.textAlignment = .center
        percentLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(percentLabel)

        iconImageView.contentMode = .scaleAspectFit
        iconImageView.tintColor = .white
        iconImageView.isHidden = true
        iconImageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconImageView)

        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),

            percentLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            percentLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            iconImageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconImageView.widthAnchor.constraint(equalToConstant: 18),
            iconImageView.heightAnchor.constraint(equalToConstant: 18)
        ])
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        trackLayer.frame = bounds
        progressLayer.frame = bounds

        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius = max(2, (min(bounds.width, bounds.height) - 4) / 2)
        let path = UIBezierPath(
            arcCenter: center,
            radius: radius,
            startAngle: -CGFloat.pi / 2,
            endAngle: 1.5 * CGFloat.pi,
            clockwise: true
        )

        trackLayer.path = path.cgPath
        progressLayer.path = path.cgPath
    }

    public func setProgress(_ progress: Double, animated: Bool = true) {
        spinner.stopAnimating()
        spinner.isHidden = true

        trackLayer.isHidden = false
        progressLayer.isHidden = false
        iconImageView.isHidden = true
        percentLabel.isHidden = false

        let p = max(0.0, min(1.0, progress))
        percentLabel.text = "\(Int(p * 100))%"

        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? 0.2 : 0)
        progressLayer.strokeEnd = CGFloat(p)
        progressLayer.strokeColor = UIColor(red: 30/255, green: 215/255, blue: 96/255, alpha: 1.0).cgColor
        CATransaction.commit()
    }

    public func setIndeterminate() {
        trackLayer.isHidden = true
        progressLayer.isHidden = true
        iconImageView.isHidden = true
        percentLabel.isHidden = true

        spinner.isHidden = false
        spinner.startAnimating()
    }

    public func setSuccess() {
        spinner.stopAnimating()
        spinner.isHidden = true
        percentLabel.isHidden = true

        trackLayer.isHidden = false
        progressLayer.isHidden = false
        progressLayer.strokeEnd = 1.0
        progressLayer.strokeColor = UIColor(red: 30/255, green: 215/255, blue: 96/255, alpha: 1.0).cgColor

        iconImageView.isHidden = false
        let conf = UIImage.SymbolConfiguration(pointSize: 16, weight: .bold)
        iconImageView.image = UIImage(systemName: "checkmark", withConfiguration: conf)
        iconImageView.tintColor = UIColor(red: 30/255, green: 215/255, blue: 96/255, alpha: 1.0)
    }

    public func setError() {
        spinner.stopAnimating()
        spinner.isHidden = true
        percentLabel.isHidden = true

        trackLayer.isHidden = false
        progressLayer.isHidden = false
        progressLayer.strokeEnd = 1.0
        progressLayer.strokeColor = UIColor(red: 255/255, green: 80/255, blue: 80/255, alpha: 1.0).cgColor

        iconImageView.isHidden = false
        let conf = UIImage.SymbolConfiguration(pointSize: 16, weight: .bold)
        iconImageView.image = UIImage(systemName: "exclamationmark", withConfiguration: conf)
        iconImageView.tintColor = UIColor(red: 255/255, green: 80/255, blue: 80/255, alpha: 1.0)
    }
}

public final class OfflineDownloadPillHUD: UIView {
    public static let shared = OfflineDownloadPillHUD()

    private let blurView = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterialDark))
    private let progressView = CircularProgressView()
    private let titleLabel = UILabel()
    private let statusLabel = UILabel()
    private let closeButton = UIButton(type: .system)

    private var hideWorkItem: DispatchWorkItem?
    private var isVisible = false

    private init() {
        super.init(frame: .zero)
        setupPillUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupPillUI()
    }

    private func setupPillUI() {
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerRadius = 24
        layer.masksToBounds = false

        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.55
        layer.shadowOffset = CGSize(width: 0, height: 6)
        layer.shadowRadius = 12

        layer.borderWidth = 1.0
        layer.borderColor = UIColor(white: 0.28, alpha: 0.8).cgColor

        blurView.layer.cornerRadius = 24
        blurView.layer.masksToBounds = true
        blurView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(blurView)

        progressView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(progressView)

        titleLabel.textColor = .white
        titleLabel.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.textColor = UIColor(white: 0.75, alpha: 1.0)
        statusLabel.font = UIFont.systemFont(ofSize: 11, weight: .regular)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        let labelStack = UIStackView(arrangedSubviews: [titleLabel, statusLabel])
        labelStack.axis = .vertical
        labelStack.spacing = 1
        labelStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(labelStack)

        let conf = UIImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        closeButton.setImage(UIImage(systemName: "xmark.circle.fill", withConfiguration: conf), for: .normal)
        closeButton.tintColor = UIColor(white: 0.55, alpha: 1.0)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.addTarget(self, action: #selector(handleClose), for: .touchUpInside)
        addSubview(closeButton)

        NSLayoutConstraint.activate([
            blurView.leadingAnchor.constraint(equalTo: leadingAnchor),
            blurView.trailingAnchor.constraint(equalTo: trailingAnchor),
            blurView.topAnchor.constraint(equalTo: topAnchor),
            blurView.bottomAnchor.constraint(equalTo: bottomAnchor),

            heightAnchor.constraint(equalToConstant: 48),

            progressView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            progressView.centerYAnchor.constraint(equalTo: centerYAnchor),
            progressView.widthAnchor.constraint(equalToConstant: 30),
            progressView.heightAnchor.constraint(equalToConstant: 30),

            labelStack.leadingAnchor.constraint(equalTo: progressView.trailingAnchor, constant: 10),
            labelStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            labelStack.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -8),

            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 24),
            closeButton.heightAnchor.constraint(equalToConstant: 24)
        ])
    }

    public func show(title: String, initialStatus: String? = nil) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.hideWorkItem?.cancel()

            self.titleLabel.text = title
            self.statusLabel.text = initialStatus ?? "offline_searching".localized
            self.statusLabel.textColor = UIColor(white: 0.75, alpha: 1.0)
            self.progressView.setIndeterminate()

            guard let window = OfflinePresentationHelper.activeWindow else { return }

            if self.superview !== window {
                self.removeFromSuperview()
                window.addSubview(self)
                NSLayoutConstraint.activate([
                    self.centerXAnchor.constraint(equalTo: window.centerXAnchor),
                    self.topAnchor.constraint(equalTo: window.safeAreaLayoutGuide.topAnchor, constant: 8),
                    self.widthAnchor.constraint(lessThanOrEqualTo: window.widthAnchor, constant: -32),
                    self.widthAnchor.constraint(greaterThanOrEqualToConstant: 260)
                ])
            }

            if !self.isVisible {
                self.isVisible = true
                self.alpha = 0
                self.transform = CGAffineTransform(translationX: 0, y: -60)

                UIView.animate(withDuration: 0.4, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0.6, options: .curveEaseOut, animations: {
                    self.alpha = 1.0
                    self.transform = .identity
                })
            }
        }
    }

    public func updateProgress(title: String? = nil, progress: Double, status: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if let t = title { self.titleLabel.text = t }
            self.statusLabel.text = status
            self.statusLabel.textColor = UIColor(white: 0.75, alpha: 1.0)
            self.progressView.setProgress(progress, animated: true)
        }
    }

    public func completeSuccess(title: String, message: String? = nil) {
        show(title: title, initialStatus: "")
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.titleLabel.text = title
            self.statusLabel.text = message ?? "offline_saved".localized
            self.statusLabel.textColor = UIColor(red: 30/255, green: 215/255, blue: 96/255, alpha: 1.0)
            self.progressView.setSuccess()

            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.success)

            self.scheduleDismiss(delay: 2.8)
        }
    }

    public func completeError(title: String, errorMessage: String, delay: Double = 5.0) {
        show(title: title, initialStatus: "")
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.titleLabel.text = title
            self.statusLabel.text = errorMessage
            self.statusLabel.textColor = UIColor(red: 255/255, green: 100/255, blue: 100/255, alpha: 1.0)
            self.progressView.setError()

            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.error)

            self.scheduleDismiss(delay: delay)
        }
    }

    @objc private func handleClose() {
        dismiss()
    }

    private func scheduleDismiss(delay: Double) {
        hideWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.dismiss()
        }
        hideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    public func dismiss() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.isVisible else { return }
            self.isVisible = false

            UIView.animate(withDuration: 0.3, delay: 0, options: .curveEaseIn, animations: {
                self.alpha = 0
                self.transform = CGAffineTransform(translationX: 0, y: -60)
            }) { _ in
                self.removeFromSuperview()
            }
        }
    }
}
