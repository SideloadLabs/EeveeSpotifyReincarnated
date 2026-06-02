import UIKit

struct SponsorBlockToastAction {
    enum Style { case primary, secondary, destructive }
    let title: String?
    let systemImage: String?
    let style: Style
    let tintOverride: UIColor?
    let handler: () -> Void

    init(title: String? = nil, systemImage: String? = nil, style: Style, tintOverride: UIColor? = nil, handler: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.style = style
        self.tintOverride = tintOverride
        self.handler = handler
    }
}

final class SponsorBlockToastView: UIView {}

final class SponsorBlockToast {
    static let shared = SponsorBlockToast()
    private(set) weak var currentView: UIView?
    private var dismissWork: DispatchWorkItem?

    func show(_ message: String) {
        let d = UserDefaults.sponsorBlockOptions.toastDuration
        show(message: message, actions: [], duration: max(0.5, d))
    }

    func showAction(message: String, actionTitle: String, action: @escaping () -> Void) {
        show(
            message: message,
            actions: [.init(title: actionTitle, style: .primary, handler: action)],
            duration: 6.0
        )
    }

    func dismissNow() {
        DispatchQueue.main.async { self.dismiss() }
    }

    func show(message: String, actions: [SponsorBlockToastAction], duration: TimeInterval = 2.2) {
        DispatchQueue.main.async {
            self.presentOnMain(message: message, actions: actions, duration: duration)
        }
    }

    private func presentOnMain(message: String, actions: [SponsorBlockToastAction], duration: TimeInterval) {
        guard let window = activeKeyWindow() else { return }

        currentView?.removeFromSuperview()
        dismissWork?.cancel()

        let toast = SponsorBlockToastView()
        toast.backgroundColor = UIColor.black.withAlphaComponent(0.88)
        toast.layer.cornerRadius = 14
        toast.layer.masksToBounds = true
        toast.translatesAutoresizingMaskIntoConstraints = false
        toast.alpha = 0
        toast.isUserInteractionEnabled = true

        let swipe = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipeDismiss(_:)))
        swipe.direction = .up
        toast.addGestureRecognizer(swipe)

        let label = UILabel()
        label.text = message
        label.textColor = .white
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.numberOfLines = 2
        label.textAlignment = .left
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .vertical)

        toast.addSubview(label)
        window.addSubview(toast)

        var constraints: [NSLayoutConstraint] = [
            toast.centerXAnchor.constraint(equalTo: window.centerXAnchor),
            toast.topAnchor.constraint(equalTo: window.safeAreaLayoutGuide.topAnchor, constant: 12),
            toast.widthAnchor.constraint(lessThanOrEqualTo: window.widthAnchor, multiplier: 0.94),
            label.leadingAnchor.constraint(equalTo: toast.leadingAnchor, constant: 16),
            label.topAnchor.constraint(equalTo: toast.topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: toast.bottomAnchor, constant: -10),
        ]

        if actions.isEmpty {
            constraints.append(label.trailingAnchor.constraint(equalTo: toast.trailingAnchor, constant: -16))
        } else {
            let stack = UIStackView()
            stack.axis = .horizontal
            stack.spacing = 6
            stack.translatesAutoresizingMaskIntoConstraints = false
            toast.addSubview(stack)

            for action in actions {
                let btn = ToastActionButton(action: action) { [weak self, weak toast] handler in
                    handler()
                    // Yank the toast out immediately — no fade — so it can't intercept
                    // anything post-tap and the slider has zero competition for touches.
                    self?.dismissWork?.cancel()
                    toast?.isUserInteractionEnabled = false
                    toast?.removeFromSuperview()
                }
                stack.addArrangedSubview(btn)
            }

            constraints += [
                stack.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 12),
                stack.trailingAnchor.constraint(equalTo: toast.trailingAnchor, constant: -8),
                stack.centerYAnchor.constraint(equalTo: toast.centerYAnchor),
            ]
        }

        NSLayoutConstraint.activate(constraints)
        currentView = toast

        UIView.animate(withDuration: 0.2) { toast.alpha = 1 }

        let work = DispatchWorkItem { [weak toast] in
            guard let toast else { return }
            toast.isUserInteractionEnabled = false
            UIView.animate(withDuration: 0.25, animations: { toast.alpha = 0 }) { _ in
                toast.removeFromSuperview()
            }
        }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    @objc private func handleSwipeDismiss(_ recog: UISwipeGestureRecognizer) {
        dismissWork?.cancel()
        guard let toast = currentView else { return }
        toast.isUserInteractionEnabled = false
        UIView.animate(withDuration: 0.18,
                       animations: { toast.alpha = 0; toast.transform = CGAffineTransform(translationX: 0, y: -30) },
                       completion: { _ in toast.removeFromSuperview() })
    }

    private func dismiss() {
        dismissWork?.cancel()
        guard let toast = currentView else { return }
        toast.isUserInteractionEnabled = false
        UIView.animate(withDuration: 0.15, animations: { toast.alpha = 0 }) { _ in
            toast.removeFromSuperview()
        }
    }

    private func activeKeyWindow() -> UIWindow? {
        for scene in UIApplication.shared.connectedScenes {
            guard let ws = scene as? UIWindowScene,
                  ws.activationState == .foregroundActive else { continue }
            if let key = ws.windows.first(where: { $0.isKeyWindow }) { return key }
            if let any = ws.windows.first { return any }
        }
        return nil
    }
}

private final class ToastActionButton: UIButton {
    private let handler: () -> Void
    private let onTap: (@escaping () -> Void) -> Void

    init(action: SponsorBlockToastAction, onTap: @escaping (@escaping () -> Void) -> Void) {
        self.handler = action.handler
        self.onTap = onTap
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerRadius = 10
        layer.masksToBounds = true
        backgroundColor = UIColor.white.withAlphaComponent(0.10)

        let tint: UIColor = action.tintOverride ?? {
            switch action.style {
            case .primary:     return UIColor(red: 0.18, green: 0.84, blue: 0.45, alpha: 1)
            case .secondary:   return .white
            case .destructive: return .systemRed
            }
        }()

        if let symbol = action.systemImage {
            let config = UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
            let img = UIImage(systemName: symbol, withConfiguration: config)?
                .withRenderingMode(.alwaysTemplate)
            setImage(img, for: .normal)
            tintColor = tint
            contentEdgeInsets = UIEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
            adjustsImageWhenHighlighted = false
            widthAnchor.constraint(greaterThanOrEqualToConstant: 38).isActive = true
        } else {
            setTitle(action.title, for: .normal)
            titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
            setTitleColor(tint, for: .normal)
            contentEdgeInsets = UIEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        }
        addTarget(self, action: #selector(tapped), for: .touchUpInside)
        heightAnchor.constraint(greaterThanOrEqualToConstant: 34).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func tapped() {
        onTap(handler)
    }
}
