import EeveeSpotifyC
import Orion
import UIKit

struct GlassTabBarGroup: HookGroup {}

// A real UITabBar over Spotify's hidden one: iOS 26 renders it as native Liquid Glass, and taps are replayed on Spotify's items.
@available(iOS 26.0, *)
final class GlassSystemTabBar: UITabBar, UITabBarDelegate {
    weak var stock: UIView?
    var sources: [GlassTabSource] = []

    func tabBar(_ tabBar: UITabBar, didSelect item: UITabBarItem) {
        guard let index = items?.firstIndex(of: item), index < sources.count else { return }
        switch sources[index] {
        case .stock(let source):
            CustomTabs.deselect()
            if !EeveeFireTap(source) {
                eeveeLog("[EeveeSpotify][Glass] Tab %d '%@' tap FAILED", index, item.title ?? "")
            }
        case .custom(let tab):
            CustomTabs.open(tab)
            if let stock { GlassTabBar.sync(stock) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            if let stock = self?.stock { GlassTabBar.sync(stock) }
        }
    }
}

enum GlassTabSource: Equatable {
    case stock(UIView)
    case custom(CustomTab)
}

@available(iOS 26.0, *)
enum GlassTabBar {
    static let meter = PerfMeter("Glass][TabBar")
    static weak var stock: UIView?
    private static var barKey: UInt8 = 0
    private static var iconCache: [IconKey: UIImage] = [:]
    private static var liveMisses: [IconKey: Int] = [:]
    private static weak var row: UIStackView?
    private static weak var platterView: UIView?
    private static var retries = 0
    private static var launchTabApplied = false
    private static var filmKey: UInt8 = 0
    private static var platterLogged = false
    private static let tintObserver = NotificationCenter.default.addObserver(
        forName: .eeveeAlbumColorChanged, object: nil, queue: .main
    ) { _ in
        if let stock, let bar = objc_getAssociatedObject(stock, &barKey) as? GlassSystemTabBar { applyTint(bar) }
    }
    private static var options = UserDefaults.tabBarOptions
    private static var appliedOptions: TabBarOptions?
    private static let observer = NotificationCenter.default.addObserver(
        forName: .eeveeTabBarOptionsChanged, object: nil, queue: .main
    ) { _ in
        options = UserDefaults.tabBarOptions
        // Launch skips the hook when no custom tab is saved yet, so the first add has to arm it before the bar syncs.
        activateGlassCustomTabs()
        if let stock { sync(stock) }
    }

    static func sync(_ stock: UIView) {
        _ = observer
        _ = tintObserver
        self.stock = stock
        let bar = systemBar(on: stock)
        guard let row = tabRow(in: stock) else { return }
        row.superview?.layoutIfNeeded()

        let tabs = row.arrangedSubviews.filter { !$0.isHidden && $0.bounds.width >= 20 }
        guard !tabs.isEmpty else { return }
        let labels = Dictionary(tabs.map { (ObjectIdentifier($0), label(in: $0)) }) { first, _ in first }
        func labelOf(_ tab: UIView) -> UILabel? { labels[ObjectIdentifier(tab)] ?? nil }
        func title(_ tab: UIView) -> String? { labelOf(tab)?.text }

        rememberTitles(tabs.compactMap(title), of: tabs.count)
        func key(_ source: GlassTabSource) -> String? {
            switch source {
            case .stock(let tab): return title(tab)
            case .custom(let tab): return tab.key
            }
        }
        func name(_ source: GlassTabSource) -> String? {
            switch source {
            case .stock(let tab): return title(tab)
            case .custom(let tab): return tab.displayTitle
            }
        }
        let customTabs = CustomTabs.available ? options.customTabs : []
        let sources = options.arrange(tabs.map(GlassTabSource.stock) + customTabs.map(GlassTabSource.custom), title: key)
        if sources != bar.sources || appliedOptions != options {
            bar.sources = sources
            appliedOptions = options
            bar.setItems(sources.enumerated().map {
                UITabBarItem(title: options.hideLabels ? nil : name($0.element), image: nil, tag: $0.offset)
            }, animated: false)
        }

        var missing = false
        let items = bar.items ?? []
        let activeFlags = sources.map { source -> Bool in
            guard case .stock(let tab) = source else { return false }
            return isActive(tab, label: labelOf(tab))
        }
        for ((item, entry), active) in zip(zip(items, sources), activeFlags) {
            let shownTitle = options.hideLabels ? nil : name(entry)
            if shownTitle != item.title { item.title = shownTitle }
            switch entry {
            case .custom(let tab):
                if item.image == nil {
                    item.image = tab.outlineImage
                    item.selectedImage = tab.image
                }
            case .stock(let source):
                let stockTitle = title(source)
                let normal = glyph(of: source, title: stockTitle, active: false, isActive: active)
                let filled = glyph(of: source, title: stockTitle, active: true, isActive: active)
                if let image = normal ?? filled, item.image !== image { item.image = image }
                if let image = filled ?? normal, item.selectedImage !== image { item.selectedImage = image }
            }
            missing = missing || item.image == nil
        }
        let custom = CustomTabs.selectedKey.flatMap { key in sources.firstIndex { if case .custom(let tab) = $0 { return tab.key == key } else { return false } } }
        let active = custom ?? activeFlags.firstIndex(of: true)
        if let active, active < items.count, bar.selectedItem !== items[active] { bar.selectedItem = items[active] }
        if missing && retries < 40 {
            retries += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { sync(stock) }
        }

        reveal(bar, over: stock, ready: !missing || retries >= 40)
        applyLaunchTab(tabs, title: title, label: labelOf)
        applyTint(bar)

        let frame = barFrame(in: stock)
        if bar.frame != frame { bar.frame = frame }
        if stock.subviews.last !== bar { stock.bringSubviewToFront(bar) }
    }

    // Spotify's own bar stays up until ours has every icon, so launch never shows an empty glass bar.
    private static func reveal(_ bar: GlassSystemTabBar, over stock: UIView, ready: Bool) {
        guard ready else { return }
        for sub in stock.subviews where sub !== bar && sub.alpha != 0 {
            sub.alpha = 0
            sub.isUserInteractionEnabled = false
        }
        guard bar.isHidden else { return }
        bar.alpha = 0
        bar.isHidden = false
        // Items laid out while hidden keep squashed labels, so they're rebuilt once visible.
        let selected = bar.selectedItem.flatMap { bar.items?.firstIndex(of: $0) }
        let fresh = (bar.items ?? []).map { UITabBarItem(title: $0.title, image: $0.image, selectedImage: $0.selectedImage) }
        bar.setItems(fresh, animated: false)
        if let selected, selected < fresh.count { bar.selectedItem = fresh[selected] }
        bar.layoutIfNeeded()
        UIView.animate(withDuration: 0.2) { bar.alpha = 1 }
        eeveeLog("[EeveeSpotify][Glass] Tab bar revealed after %d retries", retries)
    }

    private static func applyTint(_ bar: GlassSystemTabBar) {
        let color = options.albumTint == true ? AlbumColor.current?.withAlphaComponent(0.2) : nil
        guard let platter = platter(in: bar) else {
            if !platterLogged, color != nil {
                platterLogged = true
                eeveeLog("[EeveeSpotify][Glass] Tab bar platter not found, tint skipped")
            }
            return
        }
        let host = (platter as? UIVisualEffectView)?.contentView ?? platter
        let film: UIView
        if let existing = objc_getAssociatedObject(bar, &filmKey) as? UIView {
            film = existing
        } else {
            film = UIView()
            film.isUserInteractionEnabled = false
            objc_setAssociatedObject(bar, &filmKey, film, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        if film.superview !== host { host.insertSubview(film, at: 0) }
        film.frame = host.bounds
        film.layer.cornerRadius = host.bounds.height / 2
        film.layer.cornerCurve = .continuous
        if film.backgroundColor != color {
            UIView.animate(withDuration: 0.4) { film.backgroundColor = color }
        }
    }

    private static func platter(in bar: UIView) -> UIView? {
        if let platterView, platterView.isDescendant(of: bar), platterView.bounds.width > 100 { return platterView }
        platterView = bar.eeveeFirst(UIView.self) {
            $0 !== bar && NSStringFromClass(type(of: $0)).hasSuffix("PlatterView") && $0.bounds.width > 100
        }
        return platterView
    }

    private static func rememberTitles(_ titles: [String], of count: Int) {
        let titles = titles.filter { !$0.isEmpty }
        guard titles.count == count, titles != UserDefaults.knownTabs else { return }
        UserDefaults.knownTabs = titles
    }

    private static func applyLaunchTab(_ tabs: [UIView], title: (UIView) -> String?, label: (UIView) -> UILabel?) {
        guard !launchTabApplied, tabs.allSatisfy({ !(title($0) ?? "").isEmpty }) else { return }
        launchTabApplied = true
        guard let wanted = options.launchTab,
              let tab = tabs.first(where: { title($0) == wanted }),
              !isActive(tab, label: label(tab)) else { return }
        let fired = EeveeFireTap(tab)
        eeveeLog("[EeveeSpotify][Glass] Launch tab '%@' %@", wanted, fired ? "opened" : "FAILED")
    }

    private static func isActive(_ tab: UIView, label: UILabel?) -> Bool {
        iconIsActive(tab) == true || label?.textColor.isWhite == true
    }

    // Spotify lays its iPad tab bar out as a short full-width strip, well under the height a tab bar
    // needs for an icon plus a label. Inheriting that height squashes the items, so the glass bar gets
    // a floor of its own and is centred on Spotify's strip to keep the row where it was.
    private static let minimumBarHeight: CGFloat = 50

    private static func barFrame(in stock: UIView) -> CGRect {
        let bounds = stock.bounds
        guard bounds.height > 0, bounds.height < minimumBarHeight else { return bounds }
        return CGRect(x: bounds.minX, y: bounds.midY - minimumBarHeight / 2,
                      width: bounds.width, height: minimumBarHeight)
    }

    private static func systemBar(on stock: UIView) -> GlassSystemTabBar {
        if let bar = objc_getAssociatedObject(stock, &barKey) as? GlassSystemTabBar { return bar }
        let bar = GlassSystemTabBar(frame: barFrame(in: stock))
        bar.isHidden = true
        bar.overrideUserInterfaceStyle = .dark
        bar.tintColor = UIColor(red: 0.12, green: 0.84, blue: 0.38, alpha: 1)
        bar.delegate = bar
        bar.stock = stock
        // The bar is a touch taller than Spotify's strip on iPad, so it must not be clipped away.
        stock.clipsToBounds = false
        retries = 0
        objc_setAssociatedObject(stock, &barKey, bar, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        stock.addSubview(bar)
        return bar
    }

    private static func tabRow(in stock: UIView) -> UIStackView? {
        if let row, row.isDescendant(of: stock), row.arrangedSubviews.count >= 3 { return row }
        row = firstRow(in: stock)
        return row
    }

    private static func firstRow(in view: UIView) -> UIStackView? {
        var queue = view.subviews
        while !queue.isEmpty {
            let next = queue.removeFirst()
            if let stack = next as? UIStackView, stack.arrangedSubviews.count >= 3 { return stack }
            if !(next is GlassSystemTabBar) { queue += next.subviews }
        }
        return nil
    }

    private static func label(in item: UIView) -> UILabel? {
        item.eeveeFirst(UILabel.self) { !($0.text ?? "").isEmpty }
    }

    private static func iconView(in item: UIView) -> UIView? {
        item.eeveeFirst(UIView.self) { NSStringFromClass(type(of: $0)) == "SPTEncoreIconView" && $0.bounds.width >= 2 }
    }

    private static func iconIsActive(_ item: UIView) -> Bool? {
        guard let icon = iconView(in: item), icon.responds(to: NSSelectorFromString("isActive")) else { return nil }
        return icon.value(forKey: "isActive") as? Bool
    }

    private struct IconKey: Hashable {
        let title: String
        let active: Bool
        var file: String { active ? "\(title)-active" : title }
    }

    // Disk icons stand in until a live render replaces them, or for good once live renders keep failing.
    private static func glyph(of item: UIView, title: String?, active: Bool, isActive: Bool) -> UIImage? {
        guard let title else { return nil }
        let key = IconKey(title: title, active: active)
        if let cached = iconCache[key] { return cached }
        let stored = TabIconStore.load(key.file)
        guard stored == nil || liveMisses[key, default: 0] < 20 else { return stored }
        if let image = iconView(in: item).flatMap({ EeveeEncoreIconImage($0, active) ?? (isActive == active ? EeveeRenderTemplate($0) : nil) }) {
            TabIconStore.save(image, for: key.file)
            iconCache[key] = image
            return image
        }
        liveMisses[key, default: 0] += 1
        return stored
    }
}

class GlassTabBarViewHook: ClassHook<UIView> {
    typealias Group = GlassTabBarGroup
    static let targetName = "_TtC23NavigationUI_TabBarImpl10TabBarView"

    func layoutSubviews() {
        orig.layoutSubviews()
        guard #available(iOS 26.0, *) else { return }
        activateGlassCustomTabs()
        GlassTabBar.meter.measure { GlassTabBar.sync(target) }
    }
}

class GlassTabBarContainerHook: ClassHook<UIViewController> {
    typealias Group = GlassTabBarGroup
    static let targetName = "_TtC23NavigationUI_TabBarImpl19TabBarContainerImpl"

    func setSelectedViewController(_ controller: UIViewController) {
        orig.setSelectedViewController(controller)
        guard #available(iOS 26.0, *) else { return }
        DispatchQueue.main.async {
            guard let stock = GlassTabBar.stock else { return }
            GlassTabBar.meter.measure { GlassTabBar.sync(stock) }
        }
    }
}

struct CustomTabsGroup: HookGroup {}

enum CustomTabs {
    static weak var dispatcher: NSObject?
    fileprivate(set) static var available = false
    private(set) static var selectedKey: String?
    private static weak var page: UIViewController?
    private static var watch: Timer?
    private static let navigate = NSSelectorFromString("navigateToURI:options:interactionID:")

    // Spotify's own link dispatcher keeps the URI in-app; the system route would ask to open the other Spotify install.
    static func open(_ tab: CustomTab) {
        guard let url = URL(string: tab.uri) else {
            eeveeLog("[EeveeSpotify][CustomTabs] '%@' has an invalid URI %@", tab.title, tab.uri)
            return
        }
        guard let dispatcher, dispatcher.responds(to: navigate) else {
            eeveeLog("[EeveeSpotify][CustomTabs] '%@' not opened: link dispatcher not captured yet", tab.title)
            return
        }
        typealias Navigate = @convention(c) (NSObject, Selector, NSURL, Int64, AnyObject?) -> Void
        unsafeBitCast(dispatcher.method(for: navigate), to: Navigate.self)(dispatcher, navigate, url as NSURL, 0, nil)
        select(tab)
    }

    // The page is pushed on the current Spotify tab, so the custom tab stays selected only while that page is on screen.
    private static func select(_ tab: CustomTab) {
        selectedKey = tab.key
        page = nil
        watch?.invalidate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            guard selectedKey == tab.key else { return }
            watch?.invalidate()
            watch = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                guard let current = page else {
                    page = topController()
                    return
                }
                guard current.view.window == nil else { return }
                deselect()
            }
            watch?.fire()
        }
    }

    static func deselect() {
        guard selectedKey != nil else { return }
        selectedKey = nil
        page = nil
        watch?.invalidate()
        watch = nil
        if #available(iOS 26.0, *), let stock = GlassTabBar.stock { GlassTabBar.sync(stock) }
    }

    private static func topController() -> UIViewController? {
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow)
        var controller = window?.rootViewController
        while let current = controller {
            if let presented = current.presentedViewController { controller = presented; continue }
            if let nav = current as? UINavigationController, let top = nav.topViewController { controller = top; continue }
            if let visible = current.children.last(where: { $0.viewIfLoaded?.window != nil && $0.view.bounds.height > 300 }) {
                controller = visible
                continue
            }
            return current
        }
        return nil
    }

    static func capture(_ object: NSObject, _ via: String) {
        guard dispatcher !== object else { return }
        dispatcher = object
        eeveeLog("[EeveeSpotify][CustomTabs] Link dispatcher captured via %@", via)
    }
}

class LinkDispatcherHook: ClassHook<NSObject> {
    typealias Group = CustomTabsGroup
    static let targetName = "SPTLinkDispatcherImplementation"

    func setMainUILoaded(_ loaded: Bool) {
        orig.setMainUILoaded(loaded)
        CustomTabs.capture(target, "setMainUILoaded")
    }

    func navigateToURI(_ uri: NSURL, options: Int64, interactionID: AnyObject?) {
        CustomTabs.capture(target, "navigation")
        orig.navigateToURI(uri, options: options, interactionID: interactionID)
    }
}

func activateGlassCustomTabs() {
    guard !CustomTabs.available else { return }
    let glass = LiquidGlass.launchOptions
    let count = UserDefaults.tabBarOptions.customTabs.count
    guard glass.enabled, glass.tabBar, count > 0 else { return }
    guard #available(iOS 26.0, *) else { return }
    let start = CFAbsoluteTimeGetCurrent()
    let found = NSClassFromString(LinkDispatcherHook.targetName) != nil
    if found {
        CustomTabsGroup().activate()
        CustomTabs.available = true
    }
    eeveeLog("[EeveeSpotify][CustomTabs] %d tabs, link dispatcher %@ (%.2f ms)", count, found ? "hooked" : "MISSING, custom tabs hidden",
             (CFAbsoluteTimeGetCurrent() - start) * 1000)
}
