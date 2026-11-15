import UIKit
import SwiftUI

public class OfflineLibraryViewController: UIViewController {
    private var hostingController: UIHostingController<OfflineLibraryView>?

    public override func viewDidLoad() {
        super.viewDidLoad()
        title = "offline_downloaded_tracks".localized
        view.backgroundColor = .black
        overrideUserInterfaceStyle = .dark

        let hosting = UIHostingController(rootView: OfflineLibraryView())
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        hosting.view.backgroundColor = .black
        hosting.overrideUserInterfaceStyle = .dark

        addChild(hosting)
        view.addSubview(hosting.view)
        hosting.didMove(toParent: self)
        self.hostingController = hosting

        NSLayoutConstraint.activate([
            hosting.view.topAnchor.constraint(equalTo: view.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            hosting.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        hostingController?.rootView = OfflineLibraryView()
    }

    public static func present(from parent: UIViewController? = nil) {
        let vc = OfflineLibraryViewController()
        let nav = UINavigationController(rootViewController: vc)
        nav.modalPresentationStyle = .pageSheet
        OfflinePresentationHelper.safePresent(nav, from: parent)
    }
}
