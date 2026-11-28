import Orion
import UIKit

// puts SpeedPitchMenuView into the full-screen player's ⋯ menu. the menu is Spotify's context menu sheet,
// whose rows come from item factories with no way in, so the row goes into its table's header (or footer).
// every sheet uses the same controller, so only the menu that comes up just after a tap on the player's ⋯
// gets it, not the sleep timer or other sheets the player opens.
struct SpeedPitchMenuGroup: HookGroup {}

class SpeedPitchPlayerHeaderHook: ClassHook<UIViewController> {
    typealias Group = SpeedPitchMenuGroup
    static let targetName = "_TtC20NowPlaying_ModesImpl18HeaderElementsUnit"

    func viewDidLayoutSubviews() {
        orig.viewDidLayoutSubviews()
        guard let root = target.viewIfLoaded else { return }
        SpeedPitchMenu.watchMoreButton(in: root)
    }
}

class SpeedPitchContextMenuHook: ClassHook<UIViewController> {
    typealias Group = SpeedPitchMenuGroup
    static let targetName = "_TtC24ContextMenu_InternalImpl25ContextMenuViewController"

    func viewDidLayoutSubviews() {
        orig.viewDidLayoutSubviews()
        SpeedPitchMenu.install(in: target)
    }

    func viewDidAppear(_ animated: Bool) {
        orig.viewDidAppear(animated)
        SpeedPitchMenu.block(of: target)?.refresh()
    }
}

enum SpeedPitchMenu {
    // a menu this soon after the ⋯ tap is the player's.
    private static let menuAfterTap: CFTimeInterval = 3

    private static var moreTappedAt: CFTimeInterval = 0
    private static weak var watchedButton: UIView?
    private static var blockKey: UInt8 = 0
    private static var decidedKey: UInt8 = 0
    private static var loggedStructure = false

    private final class TapWatcher: NSObject {
        @objc func tapped() {
            SpeedPitchMenu.moreTappedAt = CACurrentMediaTime()
        }
    }

    private static let watcher = TapWatcher()

    // the ⋯ is the view Spotify labels "Context menu" in the player's header.
    static func watchMoreButton(in root: UIView) {
        if let watchedButton, watchedButton.isDescendant(of: root) { return }
        guard let button = root.eeveeFirst(UIView.self, where: { $0.accessibilityIdentifier == "Context menu" }) else { return }
        watchedButton = button
        // a control is watched through its own touch down: a recognizer on it took part in its touches, and a
        // touch up can come after the ⋯ card already used the tap.
        if let control = button as? UIControl {
            control.addTarget(watcher, action: #selector(TapWatcher.tapped), for: .touchDown)
        } else {
            let tap = UITapGestureRecognizer(target: watcher, action: #selector(TapWatcher.tapped))
            tap.cancelsTouchesInView = false
            tap.delaysTouchesEnded = false
            button.addGestureRecognizer(tap)
        }
    }

    static func block(of menu: UIViewController) -> SpeedPitchMenuView? {
        objc_getAssociatedObject(menu, &blockKey) as? SpeedPitchMenuView
    }

    // decided once per menu; the tap is used up, so a sheet that menu opens in turn isn't taken for it.
    private static func isPlayerMenu(_ menu: UIViewController) -> Bool {
        if let decided = objc_getAssociatedObject(menu, &decidedKey) as? Bool { return decided }
        let ours = moreTappedAt > 0 && CACurrentMediaTime() - moreTappedAt < menuAfterTap
        if ours { moreTappedAt = 0 }
        objc_setAssociatedObject(menu, &decidedKey, ours, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return ours
    }

    static func install(in menu: UIViewController) {
        guard let root = menu.viewIfLoaded, isPlayerMenu(menu) else { return }
        guard let table = root.eeveeFirst(UITableView.self) else {
            eeveeLog("[EeveeSpotify][SpeedPitch] no table in %@, left out of the menu", NSStringFromClass(type(of: menu)))
            objc_setAssociatedObject(menu, &decidedKey, false, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            return
        }
        let width = table.bounds.width
        guard width > 0 else { return }
        let fontChanged = copyRowFont(from: table)

        guard let block = block(of: menu) else {
            let headerFree = (table.tableHeaderView?.bounds.height ?? 0) < 1
            let footerFree = (table.tableFooterView?.bounds.height ?? 0) < 1
            if !loggedStructure {
                loggedStructure = true
                eeveeLog("[EeveeSpotify][SpeedPitch] menu table %@, header %@, footer %@", NSStringFromClass(type(of: table)),
                         table.tableHeaderView.map { NSStringFromClass(type(of: $0)) } ?? "none",
                         table.tableFooterView.map { NSStringFromClass(type(of: $0)) } ?? "none")
            }
            guard headerFree || footerFree else {
                eeveeLog("[EeveeSpotify][SpeedPitch] the menu's header and footer are both Spotify's, left out")
                objc_setAssociatedObject(menu, &decidedKey, false, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
                return
            }
            let block = SpeedPitchMenuView(frame: CGRect(x: 0, y: 0, width: width, height: SpeedPitchMenuView.height()))
            block.table = table
            block.inFooter = !headerFree
            objc_setAssociatedObject(menu, &blockKey, block, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            place(block, in: table)
            return
        }

        // put it back when Spotify replaced the view, or at the table's new width.
        let placed = block.inFooter ? table.tableFooterView : table.tableHeaderView
        if fontChanged { block.fontChanged() }
        if placed !== block || abs(block.frame.width - width) > 0.5 || fontChanged {
            block.frame = CGRect(x: 0, y: block.frame.minY, width: width, height: SpeedPitchMenuView.height())
            place(block, in: table)
        }
    }

    // the font and title x most of Spotify's rows share (not a track header's), which already follow the iOS text
    // size. whether either changed.
    private static func copyRowFont(from table: UITableView) -> Bool {
        let titles = table.visibleCells.compactMap { $0.eeveeFirst(UILabel.self, where: { !($0.text ?? "").isEmpty }) }
        let fonts = Dictionary(grouping: titles, by: \.font)
        guard let most = fonts.max(by: { $0.value.count < $1.value.count }), let font = most.key else { return false }
        let x = most.value[0].convert(CGPoint.zero, to: table).x.rounded()
        guard font != SpeedPitchMenuView.rowFont || x != SpeedPitchMenuView.titleX else { return false }
        SpeedPitchMenuView.rowFont = font
        SpeedPitchMenuView.titleX = x
        return true
    }

    private static func place(_ block: SpeedPitchMenuView, in table: UITableView) {
        if block.inFooter { table.tableFooterView = block } else { table.tableHeaderView = block }
        table.invalidateIntrinsicContentSize()
    }

    static func activate() {
        let missing = [SpeedPitchPlayerHeaderHook.targetName, SpeedPitchContextMenuHook.targetName].filter { NSClassFromString($0) == nil }
        guard missing.isEmpty else {
            eeveeLog("[EeveeSpotify][SpeedPitch] menu skipped, missing %@", missing.joined(separator: ", "))
            return
        }
        SpeedPitchMenuGroup().activate()
    }
}
