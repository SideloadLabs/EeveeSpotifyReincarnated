import UIKit

public enum OfflinePresentationHelper {
    static var activeWindow: UIWindow? {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene, windowScene.activationState == .foregroundActive else { continue }
            if let window = windowScene.windows.first(where: \.isKeyWindow) ?? windowScene.windows.first {
                return window
            }
        }

        let windows = UIApplication.shared.windows
        return windows.first(where: \.isKeyWindow) ?? windows.first
    }

    public static func findSafePresenter() -> UIViewController? {
        guard let root = activeWindow?.rootViewController else { return nil }
        var top = root

        while let presented = top.presentedViewController {
            top = presented
        }

        if top.isBeingPresented || top.isBeingDismissed {
            return nil
        }

        guard top.isViewLoaded, top.view.window != nil else {
            if root.isViewLoaded, root.view.window != nil, root.presentedViewController == nil, !root.isBeingPresented, !root.isBeingDismissed {
                return root
            }
            return nil
        }

        return top
    }

    public static func safePresent(
        _ vc: UIViewController,
        from sourceVC: UIViewController? = nil,
        animated: Bool = true,
        completion: (() -> Void)? = nil
    ) {
        DispatchQueue.main.async {
            var presenter = sourceVC
            if presenter == nil || presenter?.isBeingPresented == true || presenter?.isBeingDismissed == true || presenter?.presentedViewController != nil || presenter?.view.window == nil {
                presenter = findSafePresenter()
            }

            guard let target = presenter,
                  target.presentedViewController == nil,
                  !target.isBeingPresented,
                  !target.isBeingDismissed,
                  target.isViewLoaded,
                  target.view.window != nil else {
                return
            }

            target.present(vc, animated: animated, completion: completion)
        }
    }
}
