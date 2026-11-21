import Orion
import UIKit

struct HomeSectionsGroup: HookGroup {}
struct HomeSectionHeadingsGroup: HookGroup {}
struct HomePillsGroup: HookGroup {}

enum HomePart: String, CaseIterable, Codable {
    case shortcuts, promos, previews, dj, pills
    case episodeCarousels = "episode_carousels"
    case shortcutsOnly = "shortcuts_only"

    var marker: String? {
        switch self {
        case .shortcuts: return "Home_AnchorsAndShortcutsKit"
        case .promos: return "Discovery_PromoElement"
        case .previews: return "Discovery_PreviewElement"
        case .dj: return "Discovery_DJElement"
        case .episodeCarousels, .shortcutsOnly, .pills: return nil
        }
    }
}

extension UserDefaults {
    @UserDefault(key: "eeveeHomeHidden", defaultValue: [HomePart]())
    private static var homeHiddenSections

    @UserDefault(key: "eeveeHomeEpisodeCarouselsHidden", defaultValue: false)
    private static var homeEpisodeCarouselsHidden

    @UserDefault(key: "eeveeHomeFeedHidden", defaultValue: false)
    private static var homeFeedHidden

    static var homeHidden: [HomePart] {
        get {
            var parts = homeHiddenSections
            if homeEpisodeCarouselsHidden { parts.append(.episodeCarousels) }
            if homeFeedHidden { parts.append(.shortcutsOnly) }
            return parts
        }
        set {
            homeEpisodeCarouselsHidden = newValue.contains(.episodeCarousels)
            homeFeedHidden = newValue.contains(.shortcutsOnly)
            homeHiddenSections = newValue.filter { $0 != .episodeCarousels && $0 != .shortcutsOnly }
        }
    }
}

enum HomeDeclutter {
    static let launchHidden = Set(UserDefaults.homeHidden)
    // Shortcuts-only filtering happens in the response parser, before any cells exist.
    static let hidden = launchHidden.subtracting([.shortcutsOnly])
    static let meter = PerfMeter("Home][Declutter")
    private static let videoShelfTitle = "Videos you might like"
    private static let hidesMarkedSections = hidden.contains { $0.marker != nil }
    private static let checksFeedContent = hidden.contains(.episodeCarousels)
    private static var verdictKey: UInt8 = 0
    private static var logged = Set<HomePart>()

    private final class Verdict {
        weak var content: UIView?
        let part: HomePart?
        let final: Bool
        let time = CACurrentMediaTime()
        init(content: UIView?, part: HomePart?, final: Bool) { self.content = content; self.part = part; self.final = final }
    }

    static func hiddenSection(for cell: UICollectionViewCell) -> HomePart? {
        let content = cell.contentView.subviews.first
        if checksFeedContent, let part = classifyFeedContent(content) { return part }
        guard hidesMarkedSections else { return nil }
        if let verdict = objc_getAssociatedObject(cell, &verdictKey) as? Verdict, verdict.content === content, content != nil,
           verdict.final || CACurrentMediaTime() - verdict.time < 1 {
            return verdict.part
        }
        let result = classify(cell)
        objc_setAssociatedObject(cell, &verdictKey, Verdict(content: content, part: result.part, final: result.final), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return result.part
    }

    private static func classifyFeedContent(_ content: UIView?) -> HomePart? {
        guard let content, let root = content.subviews.first?.subviews.first else { return nil }
        let contentType = NSStringFromClass(type(of: content))
        guard contentType.contains("Home_EvoPageImpl"), contentType.contains("HomeStructure") else { return nil }

        // Shelves and shortcuts share the same outer cell. Keep the plain grid used for shortcuts.
        if let collection = root as? UICollectionView {
            if collection.accessibilityIdentifier == "ActionCardCarouselElement" {
                if hidden.contains(.episodeCarousels) { return .episodeCarousels }
            } else if collection.accessibilityIdentifier?.isEmpty != false,
                      !NSStringFromClass(type(of: collection)).contains("Home_CarouselKit") {
                return nil
            }
        }

        guard hidden.contains(.episodeCarousels), !(root is UICollectionView) else { return nil }

        // A standalone episode preview can be rendered as a card or as a stack with its heading.
        return root.eeveeFirst(UIView.self) { view in
            NSStringFromClass(type(of: view)).contains("EpisodeStatusOverMediaPillElementUI")
                || text(of: view, matches: "Preview episode")
                || text(of: view, matches: videoShelfTitle)
        } != nil ? .episodeCarousels : nil
    }

    static func hidesHeading(in view: UIView) -> Bool {
        guard let heading = PageLookup.find("Components.UI.SectionHeadingHome", in: view) else { return false }
        return heading.eeveeFirst(UIView.self) { text(of: $0, matches: videoShelfTitle) } != nil
    }

    private static func text(of view: UIView, matches title: String) -> Bool {
        let text = (view as? UILabel)?.text ?? view.accessibilityLabel
        return text?.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(title) == .orderedSame
    }

    private static func classify(_ cell: UICollectionViewCell) -> (part: HomePart?, final: Bool) {
        var ancestor = cell.superview
        while let view = ancestor {
            if view is UICollectionViewCell { return (nil, true) }
            ancestor = view.superview
        }
        var names = [String]()
        var queue: [UIView] = [cell]
        var index = 0
        while index < queue.count {
            let view = queue[index]
            index += 1
            if view !== cell, view is UICollectionView { view.layoutIfNeeded() }
            names.append(NSStringFromClass(type(of: view)))
            queue += view.subviews
        }
        let all = names.joined()
        guard all.contains("Home_EvoPageImpl") else { return (nil, true) }
        let part = HomePart.allCases.first { hidden.contains($0) && $0.marker.map(all.contains) == true }
        if let part, logged.insert(part).inserted { eeveeLog("[EeveeSpotify][Home] Collapsed %@", part.rawValue) }
        // Sections fill in after their first pass, so a visible verdict is only final once content has settled.
        return (part, part != nil || queue.count > 40)
    }
}

class HomeSectionCellHook: ClassHook<UICollectionViewCell> {
    typealias Group = HomeSectionsGroup
    static let targetName = "_TtC12Element_List18CollectionViewCell"

    func preferredLayoutAttributesFittingAttributes(_ attributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes {
        let result = orig.preferredLayoutAttributesFittingAttributes(attributes)
        let part = HomeDeclutter.meter.measure { HomeDeclutter.hiddenSection(for: target) }
        let hidden = part != nil
        if target.clipsToBounds != hidden { target.clipsToBounds = hidden }
        if hidden { result.size.height = 0 }
        if part == .episodeCarousels { result.isHidden = true }
        return result
    }

}

class HomeSectionHeadingHook: ClassHook<UICollectionReusableView> {
    typealias Group = HomeSectionHeadingsGroup
    static let targetName = "_TtC12Element_List21SupplementaryItemView"

    func preferredLayoutAttributesFittingAttributes(_ attributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes {
        let result = orig.preferredLayoutAttributesFittingAttributes(attributes)
        if HomeDeclutter.hidesHeading(in: target) {
            result.size.height = 0
            result.isHidden = true
        }
        return result
    }
}

class HomePillsHook: ClassHook<UIView> {
    typealias Group = HomePillsGroup
    static let targetName = "_TtC14Home_PillUIKit14PillScrollView"

    func didMoveToWindow() {
        orig.didMoveToWindow()
        target.isHidden = true
    }
}

func activateHomeDeclutter() {
    let hidden = HomeDeclutter.hidden
    guard !hidden.isEmpty else { return }
    let start = CFAbsoluteTimeGetCurrent()
    var active = [String]()
    if hidden.contains(.pills), NSClassFromString(HomePillsHook.targetName) != nil {
        HomePillsGroup().activate()
        active.append("pills")
    }
    if !hidden.subtracting([.pills]).isEmpty, NSClassFromString(HomeSectionCellHook.targetName) != nil {
        HomeSectionsGroup().activate()
        active.append("sections")
        if hidden.contains(.episodeCarousels),
           NSClassFromString(HomeSectionHeadingHook.targetName) != nil {
            HomeSectionHeadingsGroup().activate()
            active.append("headings")
        }
    }
    eeveeLog("[EeveeSpotify][Home] Declutter: hiding %@, hooks %@ (%.2f ms)", hidden.map(\.rawValue).sorted().joined(separator: ", "),
             active.isEmpty ? "MISSING" : active.joined(separator: "+"), (CFAbsoluteTimeGetCurrent() - start) * 1000)
}
