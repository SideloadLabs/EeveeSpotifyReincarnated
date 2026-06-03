import SwiftUI
import UIKit 

class EeveeSettingsViewController: SPTPageViewController {
    let settingsView: AnyView
    
    init(_ frame: CGRect, settingsView: AnyView, navigationTitle: String) {
        self.settingsView = settingsView
        super.init(nibName: nil, bundle: nil)
        
        title = navigationTitle
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        let hostingController = UIHostingController(rootView: settingsView)
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        hostingController.view.backgroundColor = .clear
        
        view.addSubview(hostingController.view)
        addChild(hostingController)
        hostingController.didMove(toParent: self)
        
        NSLayoutConstraint.activate([
            hostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
            hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }
    
    @objc func openRepositoryUrl(_ sender: UIButton) {
        UIApplication.shared.open(URL(string: "https://github.com/jaydenjcpy/EeveeSpotifyReincarnated")!)
    }
}
