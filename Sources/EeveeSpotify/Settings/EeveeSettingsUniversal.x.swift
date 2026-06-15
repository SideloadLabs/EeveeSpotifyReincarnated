import Orion
import SwiftUI
import UIKit

// Universal settings integration.
// Split into multiple HookGroups so missing classes in newer Spotify builds
// (e.g., RootSettingsViewController removed in 9.1.36) don't crash when activating.
struct UniversalSettingsIntegrationProfileGroup: HookGroup { }
struct UniversalSettingsIntegrationSettingsVCGroup: HookGroup { }
struct UniversalSettingsIntegrationRootSettingsVCGroup: HookGroup { }
struct UniversalSettingsIntegrationNavGroup: HookGroup { }

// 9.1.44 dropped ProfileSettingsSection; Settings root is now SettingsListViewController.
struct UniversalSettingsIntegrationListVCGroup: HookGroup { }

// MARK: - Primary: ProfileSettingsSection hook for settings menu row
class UniversalProfileSettingsSectionHook: ClassHook<NSObject> {
    typealias Group = UniversalSettingsIntegrationProfileGroup
    static let targetName = "ProfileSettingsSection"
    
    func numberOfRows() -> Int {
        let original = orig.numberOfRows()
        return original + 1
    }
    
    func didSelectRow(_ row: Int) {
        let originalRows = orig.numberOfRows()
        
        if row == originalRows {
            openEeveeSettingsFromHook()
            return
        }
        
        orig.didSelectRow(row)
    }
    
    func cellForRow(_ row: Int) -> UITableViewCell {
        let originalRows = orig.numberOfRows()
        
        if row == originalRows {
            let settingsTableCell = Dynamic.SPTSettingsTableViewCell
                .alloc(interface: SPTSettingsTableViewCell.self)
                .initWithStyle(3, reuseIdentifier: "EeveeSpotify")
            
            let tableViewCell = Dynamic.convert(settingsTableCell, to: UITableViewCell.self)
            
            tableViewCell.accessoryView = type(
                of: Dynamic.SPTDisclosureAccessoryView
                    .alloc(interface: SPTDisclosureAccessoryView.self)
            )
            .disclosureAccessoryView()
            
            tableViewCell.textLabel?.text = "EeveeSpotify"
            
            return tableViewCell
        }
        
        return orig.cellForRow(row)
    }
    
    private func openEeveeSettingsFromHook() {
        // Try to find the root settings controller
        let rootSettingsController = WindowHelper.shared.findFirstViewController("RootSettingsViewController")
            ?? WindowHelper.shared.findFirstViewController("SettingsViewController")
            ?? WindowHelper.shared.findFirstViewController("ProfileViewController")
        
        guard let rootController = rootSettingsController,
              let navigationController = rootController.navigationController else {
            return
        }
        
        let eeveeSettingsController = EeveeSettingsViewController(
            rootController.view.bounds,
            settingsView: AnyView(EeveeSettingsView(navigationController: navigationController)),
            navigationTitle: "EeveeSpotify"
        )
        
        let button = UIButton()
        
        if let githubImage = BundleHelper.shared.uiImage("github") {
            button.setImage(githubImage.withRenderingMode(.alwaysOriginal), for: .normal)
        } else {
             // Fallback if github image is missing
             button.setImage(UIImage(systemName: "globe"), for: .normal)
        }
        
        button.addTarget(
            eeveeSettingsController,
            action: #selector(eeveeSettingsController.openRepositoryUrl(_:)),
            for: .touchUpInside
        )
        
        let menuBarItem = UIBarButtonItem(customView: button)
        menuBarItem.customView?.heightAnchor.constraint(equalToConstant: 22).isActive = true
        menuBarItem.customView?.widthAnchor.constraint(equalToConstant: 22).isActive = true
        eeveeSettingsController.navigationItem.rightBarButtonItem = menuBarItem
        
        navigationController.pushViewController(eeveeSettingsController, animated: true)
    }
}

// MARK: - Global Helper to avoid Orion Hooking Issues with setupEeveeButton
// This logic is moved outside the ClassHook so Orion doesn't try to find it as an Obj-C method on the target class.
func injectEeveeButton(into target: UIViewController) {
    NSLog("[EeveeSpotify] injectEeveeButton called for \(String(describing: type(of: target)))")
    
    // Check if the button already exists in rightBarButtonItems
    if let rightItems = target.navigationItem.rightBarButtonItems {
        if rightItems.contains(where: { $0.tag == 1337 }) {
             NSLog("[EeveeSpotify] Button already exists (tag 1337)")
             return 
        }
    }

    NSLog("[EeveeSpotify] Creating and injecting button...")
    
    let button = UIButton(type: .system)
    // Use system image to guarantee visibility and avoid crashes
    let image = UIImage(systemName: "gearshape.fill") ?? UIImage()
    button.setImage(image, for: .normal)
    button.tintColor = .white
    
    let action = UIAction { [weak target] _ in
        guard let target = target, let navigationController = target.navigationController else { 
            NSLog("[EeveeSpotify] Navigation controller not found")
            return 
        }
        
        NSLog("[EeveeSpotify] Opening EeveeSettings...")
        
        let eeveeSettingsController = EeveeSettingsViewController(
            target.view.bounds,
            settingsView: AnyView(EeveeSettingsView(navigationController: navigationController)),
            navigationTitle: "EeveeSpotify"
        )
        
        // Add GitHub button to the Eevee settings page itself
        let subButton = UIButton(type: .system)
        
        // Try loading hex image, fallback to system "globe" if it fails or bundle is missing
        let bundleImage = BundleHelper.shared.uiImage("hex")
        // Check if the image returned from BundleHelper is valid (has a size)
        if let bundleImage = bundleImage, bundleImage.size != .zero {
            subButton.setImage(bundleImage.withRenderingMode(.alwaysOriginal), for: .normal)
        } else {
             subButton.setImage(UIImage(systemName: "globe"), for: .normal)
        }
        
        subButton.tintColor = .white
        
        let subAction = UIAction { [weak eeveeSettingsController] _ in
            eeveeSettingsController?.openRepositoryUrl(subButton)
        }
        subButton.addAction(subAction, for: .touchUpInside)
        
        let menuBarItem = UIBarButtonItem(customView: subButton)
        menuBarItem.customView?.heightAnchor.constraint(equalToConstant: 22).isActive = true
        menuBarItem.customView?.widthAnchor.constraint(equalToConstant: 22).isActive = true
        eeveeSettingsController.navigationItem.rightBarButtonItem = menuBarItem
        
        navigationController.pushViewController(eeveeSettingsController, animated: true)
    }
    
    button.addAction(action, for: .touchUpInside)
    
    let item = UIBarButtonItem(customView: button)
    item.tag = 1337 // Tag to prevent duplicate addition
    item.customView?.widthAnchor.constraint(equalToConstant: 22).isActive = true
    item.customView?.heightAnchor.constraint(equalToConstant: 22).isActive = true
    
    var items = target.navigationItem.rightBarButtonItems ?? []
    items.insert(item, at: 0) // Prepend instead of append to ensure visibility
    target.navigationItem.rightBarButtonItems = items
    
    NSLog("[EeveeSpotify] Button injected. Items count: \(items.count)")
}

// MARK: - Fallback: Hook SettingsViewController directly (New UI)
class SettingsViewControllerHook: ClassHook<UIViewController> {
    typealias Group = UniversalSettingsIntegrationSettingsVCGroup
    static let targetName = "SettingsViewController"

    func viewDidLoad() {
        orig.viewDidLoad()
        injectEeveeButton(into: target)
    }

    func viewWillAppear(_ animated: Bool) {
        orig.viewWillAppear(animated)
        injectEeveeButton(into: target)
    }
}

// MARK: - Fallback: Hook RootSettingsViewController directly
class RootSettingsViewControllerHook: ClassHook<UIViewController> {
    typealias Group = UniversalSettingsIntegrationRootSettingsVCGroup
    static let targetName = "RootSettingsViewController"

    func viewDidLoad() {
        orig.viewDidLoad()
        injectEeveeButton(into: target)
    }

    func viewWillAppear(_ animated: Bool) {
        orig.viewWillAppear(animated)
        injectEeveeButton(into: target)
    }
}

class SettingsListViewControllerHook: ClassHook<UIViewController> {
    typealias Group = UniversalSettingsIntegrationListVCGroup
    static let targetName = "_TtC21Settings_PlatformImpl26SettingsListViewController"

    func viewDidLoad() {
        orig.viewDidLoad()
        injectEeveeButton(into: target)
    }

    func viewWillAppear(_ animated: Bool) {
        orig.viewWillAppear(animated)
        injectEeveeButton(into: target)
    }

    func viewDidLayoutSubviews() {
        orig.viewDidLayoutSubviews()
        injectEeveeInlineRow(into: target)
    }
}

private let eeveeInlineRowTag = 1338
private let eeveeInlineRowHeight: CGFloat = 68
private let eeveeInlineRowTitle = "EeveeSpotify"

func injectEeveeInlineRow(into vc: UIViewController) {
    // Each Spotify page sits in a MusicAppPageHostingViewController wrapper; the list VC is its child.
    // Inject only when this VC's enclosing wrapper is the earliest wrapper containing a SettingsListViewController.
    guard let stack = vc.navigationController?.viewControllers,
          let listClass = NSClassFromString("_TtC21Settings_PlatformImpl26SettingsListViewController") else { return }
    let enclosing = enclosingStackVC(of: vc, in: stack)
    let rootSettingsHost = stack.first { subtreeContains($0, ofClass: listClass) }
    guard let enclosing = enclosing, enclosing === rootSettingsHost else { return }
    guard let cv = findFirstCollectionView(in: vc.view) else {
        NSLog("[EeveeSpotify] inlineRow: no UICollectionView in view tree")
        return
    }
    if cv.viewWithTag(eeveeInlineRowTag) != nil { return }

    let row = UIButton(type: .custom)
    row.tag = eeveeInlineRowTag
    row.backgroundColor = .clear
    row.frame = CGRect(x: 0, y: -eeveeInlineRowHeight, width: cv.bounds.width, height: eeveeInlineRowHeight)
    row.autoresizingMask = [.flexibleWidth]

    let textWidth = cv.bounds.width - 60
    let title = UILabel(frame: CGRect(x: 20, y: 12, width: textWidth, height: 20))
    title.text = eeveeInlineRowTitle
    title.textColor = .white
    title.font = UIFont.systemFont(ofSize: 16)
    title.autoresizingMask = [.flexibleWidth]
    row.addSubview(title)

    let subtitle = UILabel(frame: CGRect(x: 20, y: 34, width: textWidth, height: 18))
    subtitle.text = "eevee_inline_subtitle_text".localized
    subtitle.textColor = UIColor(white: 1.0, alpha: 0.6)
    subtitle.font = UIFont.systemFont(ofSize: 13)
    subtitle.autoresizingMask = [.flexibleWidth]
    row.addSubview(subtitle)

    let chevron = UIImageView(image: UIImage(systemName: "chevron.right"))
    chevron.tintColor = UIColor(white: 1.0, alpha: 0.55)
    chevron.contentMode = .scaleAspectFit
    let chevSize: CGFloat = 14
    chevron.frame = CGRect(
        x: cv.bounds.width - 20 - chevSize,
        y: (eeveeInlineRowHeight - chevSize) / 2,
        width: chevSize,
        height: chevSize
    )
    chevron.autoresizingMask = [.flexibleLeftMargin]
    row.addSubview(chevron)

    let separator = UIView(frame: CGRect(
        x: 20,
        y: eeveeInlineRowHeight - 0.5,
        width: cv.bounds.width - 20,
        height: 0.5
    ))
    separator.backgroundColor = UIColor(white: 1.0, alpha: 0.08)
    separator.autoresizingMask = [.flexibleWidth]
    row.addSubview(separator)

    row.addAction(UIAction { [weak vc] _ in
        guard let vc = vc else { return }
        pushEeveeSettings(from: vc)
    }, for: .touchUpInside)

    cv.addSubview(row)

    var inset = cv.contentInset
    inset.top += eeveeInlineRowHeight
    cv.contentInset = inset
    var indicator = cv.verticalScrollIndicatorInsets
    indicator.top += eeveeInlineRowHeight
    cv.verticalScrollIndicatorInsets = indicator
    cv.setContentOffset(CGPoint(x: 0, y: -inset.top), animated: false)

    NSLog("[EeveeSpotify] Injected inline EeveeSpotify row into Settings list")
}

private func enclosingStackVC(of vc: UIViewController, in stack: [UIViewController]) -> UIViewController? {
    var cur: UIViewController? = vc
    while let c = cur {
        if stack.contains(where: { $0 === c }) { return c }
        cur = c.parent
    }
    return nil
}

private func subtreeContains(_ root: UIViewController, ofClass cls: AnyClass) -> Bool {
    if type(of: root) == cls { return true }
    for child in root.children {
        if subtreeContains(child, ofClass: cls) { return true }
    }
    return false
}

private func findFirstCollectionView(in view: UIView) -> UICollectionView? {
    if let cv = view as? UICollectionView { return cv }
    for sub in view.subviews {
        if let found = findFirstCollectionView(in: sub) { return found }
    }
    return nil
}

private func pushEeveeSettings(from vc: UIViewController) {
    guard let nav = vc.navigationController else { return }
    let host = EeveeSettingsViewController(
        vc.view.bounds,
        settingsView: AnyView(EeveeSettingsView(navigationController: nav)),
        navigationTitle: "EeveeSpotify"
    )

    let subButton = UIButton(type: .system)
    if let bundleImage = BundleHelper.shared.uiImage("hex"), bundleImage.size != .zero {
        subButton.setImage(bundleImage.withRenderingMode(.alwaysOriginal), for: .normal)
    } else {
        subButton.setImage(UIImage(systemName: "globe"), for: .normal)
    }
    subButton.tintColor = .white
    subButton.addAction(UIAction { [weak host] _ in
        host?.openRepositoryUrl(subButton)
    }, for: .touchUpInside)

    let menuBarItem = UIBarButtonItem(customView: subButton)
    menuBarItem.customView?.heightAnchor.constraint(equalToConstant: 22).isActive = true
    menuBarItem.customView?.widthAnchor.constraint(equalToConstant: 22).isActive = true
    host.navigationItem.rightBarButtonItem = menuBarItem

    nav.pushViewController(host, animated: true)
}

// MARK: - Generic Fallback: Hook UINavigationController to catch Settings by title/class name
class SettingsNavigationStackHook: ClassHook<UINavigationController> {
    typealias Group = UniversalSettingsIntegrationNavGroup

    func pushViewController(_ viewController: UIViewController, animated: Bool) {
        orig.pushViewController(viewController, animated: animated)
        
        let targetVC = viewController
        
        // Check both immediately and with a delay
        let checkBlock = {
            let className = String(describing: type(of: targetVC))
            
            // Check title - localized "Settings" / "Preferences" in Spotify-supported languages
            let settingsTitles: Set<String> = [
                // English
                "Settings", "Preferences",
                // German
                "Einstellungen", "Präferenzen",
                // French
                "Paramètres", "Préférences",
                // Spanish
                "Configuración", "Ajustes", "Preferencias",
                // Italian
                "Impostazioni", "Preferenze",
                // Portuguese
                "Definições", "Configurações", "Preferências",
                // Dutch
                "Instellingen", "Voorkeuren",
                // Turkish
                "Ayarlar", "Tercihler",
                // Polish
                "Ustawienia", "Preferencje",
                // Russian
                "Настройки", "Параметры",
                // Ukrainian
                "Налаштування", "Параметри",
                // Czech
                "Nastavení", "Předvolby",
                // Swedish
                "Inställningar",
                // Norwegian
                "Innstillinger",
                // Danish
                "Indstillinger",
                // Finnish
                "Asetukset",
                // Hungarian
                "Beállítások",
                // Romanian
                "Setări", "Preferințe",
                // Slovak
                "Nastavenia",
                // Croatian/Bosnian/Serbian
                "Postavke", "Podešavanja",
                // Slovenian
                "Nastavitve",
                // Bulgarian
                "Настройки",
                // Greek
                "Ρυθμίσεις", "Προτιμήσεις",
                // Hebrew
                "הגדרות", "העדפות",
                // Arabic
                "الإعدادات", "التفضيلات",
                // Persian
                "تنظیمات", "ترجیحات",
                // Japanese
                "設定", "環境設定",
                // Korean
                "설정", "환경설정",
                // Chinese (Simplified)
                "设置", "偏好设置",
                // Chinese (Traditional)
                "設定", "偏好設定",
                // Thai
                "การตั้งค่า",
                // Vietnamese
                "Cài đặt", "Tùy chọn",
                // Indonesian
                "Pengaturan", "Setelan", "Preferensi",
                // Malay
                "Tetapan", "Keutamaan",
                // Filipino
                "Mga Setting", "Mga Kagustuhan",
                // Hindi
                "सेटिंग", "प्राथमिकताएं",
                // Bengali
                "সেটিংস",
                // Tamil
                "அமைப்புகள்",
                // Catalan
                "Configuració", "Preferències",
                // Basque
                "Ezarpenak",
                // Galician
                "Configuración", "Preferencias",
            ]
            if let title = targetVC.title, settingsTitles.contains(title) {
                NSLog("[EeveeSpotify] Detected Settings via Title: \(className)")
                injectEeveeButton(into: targetVC)
                return
            }
            
            // Check class name
            if className.contains("Settings") && !className.contains("Eevee") {
                NSLog("[EeveeSpotify] Detected Settings via Class Name: \(className)")
                injectEeveeButton(into: targetVC)
                return
            }
        }
        
        checkBlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: checkBlock)
    }
}
