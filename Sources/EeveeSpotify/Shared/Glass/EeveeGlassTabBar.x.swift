import Orion
import UIKit
import ObjectiveC
import EeveeSpotifyC

struct EeveeGlassTabBarGroup: HookGroup {}

// MARK: - reading Spotify's tab items

private func tabItems(_ tabBar: UIView) -> [UIView] {
    guard let row = EeveeViewTree.row(in: tabBar) else { return [] }
    let visible = row.arrangedSubviews.filter { !$0.isHidden && $0.bounds.width >= 20 }
    return visible.sorted {
        EeveeViewTree.frame(of: $0, in: tabBar).origin.x < EeveeViewTree.frame(of: $1, in: tabBar).origin.x
    }
}

private func labelIn(_ item: UIView) -> UILabel? {
    var label: UILabel?
    EeveeViewTree.forEachView(item) { v in
        if label == nil, let l = v as? UILabel, !(l.text ?? "").isEmpty { label = l }
    }
    return label
}

private func iconIn(_ item: UIView) -> UIView? {
    var icon: UIView?
    EeveeViewTree.forEachView(item) { v in
        guard icon == nil, v.bounds.width >= 2 else { return }
        if v is UIImageView || NSStringFromClass(type(of: v)).contains("IconView") { icon = v }
    }
    return icon
}

/// Spotify paints the selected tab's label white and the rest a mid grey.
private func isActive(_ item: UIView) -> Bool {
    guard let color = labelIn(item)?.textColor else { return false }
    var white: CGFloat = 0, alpha: CGFloat = 0
    if color.getWhite(&white, alpha: &alpha) { return white > 0.95 }
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
    guard color.getRed(&r, green: &g, blue: &b, alpha: &alpha) else { return false }
    return min(r, min(g, b)) > 0.95
}

// MARK: - icon glyphs

private let glyphCache = NSCache<NSString, UIImage>()

private func renderLayer(_ layer: CALayer, size: CGSize) -> UIImage? {
    guard size.width > 0, size.height > 0 else { return nil }
    let renderer = UIGraphicsImageRenderer(size: size)
    let image = renderer.image { context in
        layer.render(in: context.cgContext)
    }
    return image.withRenderingMode(.alwaysTemplate)
}

/// The private SPTEncoreIcon a live icon view was built with, read straight
/// out of its `icon` ivar — Encore keeps no getter for it. `object_getIvar`
/// is only valid to use here because the ivar's own type encoding is
/// checked first; calling it on a non-object ivar would misread raw bytes
/// as a pointer.
private func encoreIconOf(_ view: UIView) -> AnyObject? {
    guard let ivar = class_getInstanceVariable(type(of: view), "icon"),
          let typeEncoding = ivar_getTypeEncoding(ivar),
          typeEncoding.pointee == 0x40 // '@' — an object ivar
    else { return nil }
    return object_getIvar(view, ivar) as AnyObject?
}

private func glyphOf(_ item: UIView, active: Bool) -> UIImage? {
    guard let live = iconIn(item) else { return nil }
    let size = live.bounds.size
    guard size.width >= 2, size.height >= 2 else { return nil }

    reflection: if let icon = encoreIconOf(live),
                   let iconViewClass = NSClassFromString("SPTEncoreIconView") {
        let nameSelector = Selector(("name"))
        let name = (icon.responds(to: nameSelector) ? icon.perform(nameSelector)?.takeUnretainedValue() : nil)
            .map { "\($0)" } ?? "\(icon)"
        let cacheKey = "\(name) \(active) \(size)" as NSString
        if let cached = glyphCache.object(forKey: cacheKey) { return cached }

        guard let allocated = (iconViewClass as AnyObject).perform(Selector(("alloc")))?.takeUnretainedValue(),
              let inited = allocated.perform(Selector(("initWithIcon:")), with: icon)?.takeUnretainedValue(),
              let view = inited as? UIView
        else { break reflection }

        view.frame = CGRect(origin: .zero, size: size)
        let foregroundSelector = Selector(("setForegroundColor:"))
        if view.responds(to: foregroundSelector) { _ = view.perform(foregroundSelector, with: UIColor.white) }
        let activeForegroundSelector = Selector(("setActiveForegroundColor:"))
        if view.responds(to: activeForegroundSelector) { _ = view.perform(activeForegroundSelector, with: UIColor.white) }
        EeveeSetBool(view, Selector(("setIsActive:")), active)
        view.layoutIfNeeded()

        if let rendered = renderLayer(view.layer, size: size) {
            glyphCache.setObject(rendered, forKey: cacheKey)
            return rendered
        }
    }

    return renderLayer(live.layer, size: size)
}

// MARK: - passing a tap on

private func fireTapRecognizers(_ view: UIView) -> Bool {
    guard let targetsIvar = class_getInstanceVariable(UIGestureRecognizer.self, "_targets") else { return false }
    var fired = false
    for recognizer in view.gestureRecognizers ?? [] {
        guard let tap = recognizer as? UITapGestureRecognizer, tap.isEnabled else { continue }
        guard let pairs = object_getIvar(recognizer, targetsIvar) as? NSArray else { continue }
        for case let pair as AnyObject in pairs {
            guard let targetIvar = class_getInstanceVariable(type(of: pair), "_target"),
                  let actionIvar = class_getInstanceVariable(type(of: pair), "_action"),
                  let target = object_getIvar(pair, targetIvar) as AnyObject?
            else { continue }

            let pairPointer = Unmanaged.passUnretained(pair).toOpaque()
            let action = pairPointer
                .advanced(by: ivar_getOffset(actionIvar))
                .assumingMemoryBound(to: Selector.self)
                .pointee

            guard target.responds(to: action) else { continue }
            writeDebugLog("[GlassTabBar] tap -> \(NSStringFromClass(type(of: target))) \(action)")
            _ = target.perform(action, with: recognizer)
            fired = true
        }
    }
    return fired
}

private func forwardTap(_ item: UIView) {
    var sent = false
    EeveeViewTree.forEachView(item) { v in
        if !sent { sent = fireTapRecognizers(v) }
    }
    guard !sent else { return }
    EeveeViewTree.forEachView(item) { v in
        guard !sent, let control = v as? UIControl else { return }
        control.sendActions(for: .touchUpInside)
        sent = true
    }
}

// MARK: - the system bar

private final class EeveeSystemTabBar: UITabBar, UITabBarDelegate {
    weak var stockBar: UIView?
    var sources: [UIView] = []

    func tabBar(_ tabBar: UITabBar, didSelect item: UITabBarItem) {
        guard let index = items?.firstIndex(of: item), index < sources.count else { return }
        forwardTap(sources[index])
        // Spotify repaints its labels a moment later; a tap it did not take
        // (a link Spotify itself blocked, say) snaps the selection back to
        // whatever Spotify's own state actually is.
        let stock = stockBar
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            if let stock { syncTabBar(stock) }
        }
    }
}

private var tabBarKey: UInt8 = 0
private var missingIconRetries = 0
private weak var lastSyncedStockBar: UIView?

private func removeSystemTabBar(_ stockBar: UIView) {
    guard let bar = objc_getAssociatedObject(stockBar, &tabBarKey) as? UIView else { return }
    bar.removeFromSuperview()
    objc_setAssociatedObject(stockBar, &tabBarKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    for sub in stockBar.subviews {
        sub.alpha = 1
        sub.isUserInteractionEnabled = true
    }
}

private func syncTabBar(_ stockBar: UIView) {
    guard EeveeGlass.isEnabled else {
        removeSystemTabBar(stockBar)
        return
    }
    lastSyncedStockBar = stockBar

    let bar: EeveeSystemTabBar
    if let existing = objc_getAssociatedObject(stockBar, &tabBarKey) as? EeveeSystemTabBar {
        bar = existing
    } else {
        bar = EeveeSystemTabBar(frame: stockBar.bounds)
        bar.delegate = bar
        bar.stockBar = stockBar
        objc_setAssociatedObject(stockBar, &tabBarKey, bar, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    for sub in stockBar.subviews where sub !== bar {
        sub.alpha = 0
        sub.isUserInteractionEnabled = false
    }
    stockBar.superview?.layer.backgroundColor = nil

    let sources = tabItems(stockBar)
    guard !sources.isEmpty else { return }

    if !sources.elementsEqual(bar.sources, by: { $0 === $1 }) {
        let items = sources.enumerated().map { index, source in
            UITabBarItem(title: labelIn(source)?.text, image: nil, tag: index)
        }
        bar.sources = sources
        bar.setItems(items, animated: false)
    }

    var selected: UITabBarItem?
    var missing = false
    for (index, item) in (bar.items ?? []).enumerated() where index < sources.count {
        let source = sources[index]
        if item.image == nil { item.image = glyphOf(source, active: false) }
        if item.selectedImage == nil || item.selectedImage == item.image {
            item.selectedImage = glyphOf(source, active: true)
        }
        if item.image == nil || item.selectedImage == nil { missing = true }
        if let title = labelIn(source)?.text, !title.isEmpty, title != item.title {
            item.title = title
        }
        if selected == nil, isActive(source) { selected = item }
    }
    if let selected, bar.selectedItem !== selected {
        bar.selectedItem = selected
    }
    // An icon view Spotify hasn't built yet is looked for again shortly,
    // not left blank until the next unrelated layout pass happens to retry.
    if missing, missingIconRetries < 40 {
        missingIconRetries += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { syncTabBar(stockBar) }
    }

    let bounds = stockBar.bounds
    let width = bounds.width
    let height = max(bounds.height, bar.sizeThatFits(CGSize(width: width, height: bounds.height)).height)
    let frame = CGRect(x: 0, y: bounds.maxY - height, width: width, height: height)
    if bar.frame != frame { bar.frame = frame }
    if bar.superview !== stockBar {
        stockBar.addSubview(bar)
    } else if stockBar.subviews.last !== bar {
        stockBar.bringSubviewToFront(bar)
    }
}

// MARK: - hooks

private func tabBarOf(_ item: UIView) -> UIView? {
    guard let barClass = NSClassFromString(EeveeTabBarViewHook.targetName) else { return nil }
    var current: UIView? = item.superview
    while let v = current {
        if v.isKind(of: barClass) { return v }
        current = v.superview
    }
    return nil
}

/// The bar's own layout pass runs before Spotify has finished filling the
/// row, so each item is also synced as it lays itself out — the same
/// reasoning as EeveeGlassHooks.x.swift's didAddSubview:/didMoveToWindow
/// hooks on the search field.
private func itemDidLayOut(_ item: UIView) {
    guard let bar = tabBarOf(item) else { return }
    syncTabBar(bar)
}

class EeveeTabBarViewHook: ClassHook<UIView> {
    typealias Group = EeveeGlassTabBarGroup

    // NavigationUI_TabBarImpl.TabBarView
    static let targetName = "_TtC23NavigationUI_TabBarImpl10TabBarView"

    func layoutSubviews() {
        orig.layoutSubviews()
        syncTabBar(target)
    }
}

class EeveeTabBarItemHook: ClassHook<UIView> {
    typealias Group = EeveeGlassTabBarGroup

    // NavigationUI_TabBarImpl.TabBarItemElementView
    static let targetName = "_TtC23NavigationUI_TabBarImpl21TabBarItemElementView"

    func layoutSubviews() {
        orig.layoutSubviews()
        itemDidLayOut(target)
    }
}

class EeveeCreateMenuTabBarItemHook: ClassHook<UIView> {
    typealias Group = EeveeGlassTabBarGroup

    // CreateMenu_TabBarItemImpl.CreateMenuTabBarItemView — the mod's own
    // "Create" tab, laid out through a different element type than the rest.
    static let targetName = "_TtC25CreateMenu_TabBarItemImpl24CreateMenuTabBarItemView"

    func layoutSubviews() {
        orig.layoutSubviews()
        itemDidLayOut(target)
    }
}

class EeveeTabBarContainerHook: ClassHook<UIViewController> {
    typealias Group = EeveeGlassTabBarGroup

    // NavigationUI_TabBarImpl.TabBarContainerImpl — a tab changed from
    // elsewhere (a deep link, the side drawer) repaints Spotify's own
    // labels without ever running a layout pass of its own, so this is the
    // one hook here that isn't a layoutSubviews override.
    static let targetName = "_TtC23NavigationUI_TabBarImpl19TabBarContainerImpl"

    func setSelectedViewController(_ controller: UIViewController?) {
        orig.setSelectedViewController(controller)
        DispatchQueue.main.async {
            if let bar = lastSyncedStockBar { syncTabBar(bar) }
        }
    }
}

// MARK: - activation

func activateEeveeTabBarGlass() {
    guard EeveeGlass.isEnabled else { return }

    let targets = [
        EeveeTabBarViewHook.targetName,
        EeveeTabBarItemHook.targetName,
        EeveeCreateMenuTabBarItemHook.targetName,
        EeveeTabBarContainerHook.targetName,
    ]
    let allExist = targets.allSatisfy { NSClassFromString($0) != nil }
    writeDebugLog("[GlassTabBar] classesFound=\(allExist ? "Y" : "N")")

    guard allExist else { return }
    EeveeGlassTabBarGroup().activate()
}
