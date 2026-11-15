import Orion
import UIKit
import SwiftUI

public class OfflineLibraryPlaylistRowView: UIView {
    private let iconContainer = UIView()
    private let iconImageView = UIImageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let chevronImageView = UIImageView()

    public weak var navigationController: UINavigationController?
    public weak var parentViewController: UIViewController?

    public override init(frame: CGRect) {
        super.init(frame: frame)
        setupUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    private func setupUI() {
        backgroundColor = UIColor(white: 0.1, alpha: 0.95)
        layer.cornerRadius = 10
        layer.borderWidth = 0.5
        layer.borderColor = UIColor(white: 0.2, alpha: 0.6).cgColor
        layer.masksToBounds = true
        translatesAutoresizingMaskIntoConstraints = false

        iconContainer.layer.cornerRadius = 8
        iconContainer.layer.masksToBounds = true
        iconContainer.backgroundColor = UIColor(red: 30/255, green: 215/255, blue: 96/255, alpha: 1.0)
        iconContainer.translatesAutoresizingMaskIntoConstraints = false

        let conf = UIImage.SymbolConfiguration(pointSize: 26, weight: .bold)
        iconImageView.image = UIImage(systemName: "arrow.down.circle.fill", withConfiguration: conf)
        iconImageView.tintColor = .black
        iconImageView.contentMode = .scaleAspectFit
        iconImageView.translatesAutoresizingMaskIntoConstraints = false
        iconContainer.addSubview(iconImageView)

        titleLabel.text = "offline_downloaded_tracks".localized
        titleLabel.font = UIFont.systemFont(ofSize: 16, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        subtitleLabel.font = UIFont.systemFont(ofSize: 13, weight: .regular)
        subtitleLabel.textColor = UIColor(white: 0.7, alpha: 1.0)
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        let chevConf = UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        chevronImageView.image = UIImage(systemName: "chevron.right", withConfiguration: chevConf)
        chevronImageView.tintColor = UIColor(white: 0.5, alpha: 1.0)
        chevronImageView.contentMode = .scaleAspectFit
        chevronImageView.translatesAutoresizingMaskIntoConstraints = false

        let textStack = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        textStack.axis = .vertical
        textStack.spacing = 3
        textStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconContainer)
        addSubview(textStack)
        addSubview(chevronImageView)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 68),

            iconContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            iconContainer.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconContainer.widthAnchor.constraint(equalToConstant: 48),
            iconContainer.heightAnchor.constraint(equalToConstant: 48),

            iconImageView.centerXAnchor.constraint(equalTo: iconContainer.centerXAnchor),
            iconImageView.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor),
            iconImageView.widthAnchor.constraint(equalToConstant: 30),
            iconImageView.heightAnchor.constraint(equalToConstant: 30),

            textStack.leadingAnchor.constraint(equalTo: iconContainer.trailingAnchor, constant: 12),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: chevronImageView.leadingAnchor, constant: -8),

            chevronImageView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            chevronImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevronImageView.widthAnchor.constraint(equalToConstant: 14),
            chevronImageView.heightAnchor.constraint(equalToConstant: 14)
        ])

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        addGestureRecognizer(tap)
        isUserInteractionEnabled = true

        refreshSubtitle()
        NotificationCenter.default.addObserver(self, selector: #selector(refreshSubtitle),
                                               name: OfflineLibraryStore.changed, object: nil)
    }

    @objc public func refreshSubtitle() {
        let count = OfflineLibraryStore.shared.downloadedTracks().count
        if count == 0 {
            subtitleLabel.text = "offline_library_row_empty".localized
        } else {
            subtitleLabel.text = String(format: "offline_library_row_count".localized, count)
        }
    }

    @objc private func handleTap() {
        guard window != nil else { return }
        let controller = OfflineLibraryViewController()

        if let nav = navigationController ?? parentViewController?.navigationController {
            guard !(nav.topViewController is OfflineLibraryViewController),
                  nav.transitionCoordinator == nil, nav.presentedViewController == nil else { return }
            EeveeLog.checkpoint("[Offline][Library] downloaded screen push began")
            nav.pushViewController(controller, animated: true)
            EeveeLog.checkpoint("[Offline][Library] downloaded screen push returned")
        } else if let parent = parentViewController {
            let nav = UINavigationController(rootViewController: controller)
            nav.modalPresentationStyle = .fullScreen
            OfflinePresentationHelper.safePresent(nav, from: parent)
        } else {
            OfflineLibraryViewController.present()
        }
    }
}

class YourLibraryViewControllerHook: ClassHook<UIViewController> {
    typealias Group = OfflineHookGroup
    static let targetName = "_TtC28YourLibrary_YourLibraryXImpl25YourLibraryViewController"

    func viewDidLoad() {
        EeveeLog.checkpoint("[Offline][Library] viewDidLoad began")
        orig.viewDidLoad()
        EeveeLog.checkpoint("[Offline][Library] viewDidLoad returned")
    }

    func viewWillAppear(_ animated: Bool) {
        EeveeLog.checkpoint("[Offline][Library] viewWillAppear began")
        orig.viewWillAppear(animated)
        EeveeLog.checkpoint("[Offline][Library] viewWillAppear returned")
    }

    func viewDidAppear(_ animated: Bool) {
        EeveeLog.checkpoint("[Offline][Library] viewDidAppear began")
        orig.viewDidAppear(animated)
        EeveeLog.checkpoint("[Offline][Library] viewDidAppear returned")
        DispatchQueue.main.async { [weak controller = target] in
            guard let controller, let view = controller.viewIfLoaded, view.window != nil else { return }
            Self.injectOfflinePlaylistRow(in: controller, root: view)
        }
    }

    private static func injectOfflinePlaylistRow(in controller: UIViewController, root: UIView) {
        let tag = 77702
        guard !root.subviews.contains(where: { $0.tag == tag }) else { return }
        EeveeLog.checkpoint("[Offline][Library] offline row install began")
        let rowView = OfflineLibraryPlaylistRowView(frame: .zero)
        rowView.tag = tag
        rowView.navigationController = controller.navigationController
        rowView.parentViewController = controller
        root.addSubview(rowView)

        NSLayoutConstraint.activate([
            rowView.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 52),
            rowView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            rowView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16)
        ])
        EeveeLog.checkpoint("[Offline][Library] offline row install finished")
    }
}
