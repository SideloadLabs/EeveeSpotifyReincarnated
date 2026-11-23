import Orion
import UIKit

struct PlayerButtonsDeclutterGroup: HookGroup {}
struct PlayerAddToDeclutterGroup: HookGroup {}
struct PlayerLyricsPreviewDeclutterGroup: HookGroup {}
struct PlayerCardsDeclutterGroup: HookGroup {}
struct PlayerCardHeadersDeclutterGroup: HookGroup {}

enum PlayerPart: String, CaseIterable, Codable {
    case lyricsPreview, shuffle, `repeat`, addTo, queue, share, connect
    case allCards, lyricsCard, aboutArtist, relatedVideos, songDNA, liveEvents, exploreArtist, releaseCountdown, credits, merch, recommendations

    static let buttons: [PlayerPart] = [.lyricsPreview, .shuffle, .repeat, .addTo, .queue, .share, .connect]
    static let cards: [PlayerPart] = [.allCards, .lyricsCard, .aboutArtist, .relatedVideos, .songDNA, .liveEvents, .exploreArtist, .releaseCountdown, .credits, .merch, .recommendations]

    var buttonIds: [String] {
        switch self {
        case .shuffle: return ["Components.UI.ShuffleButton"]
        case .repeat: return ["Nowplaying-RepeatButton"]
        case .share: return ["ShareButtonNowPlayingView"]
        case .queue: return ["QueueButtonNowPlaying"]
        case .connect: return ["Components.ConnectButtonOutputSwitcher"]
        default: return []
        }
    }

    var cardMarkers: [String] {
        switch self {
        case .lyricsCard: return ["Lyrics_CardElementImpl"]
        case .aboutArtist: return ["ArtistAbout", "CreatorBiography"]
        case .relatedVideos: return ["VideoRecommendations"]
        case .songDNA: return ["SongDNA"]
        case .liveEvents: return ["LiveEvents_", "OnTourEventCard"]
        case .exploreArtist: return ["WatchFeed"]
        case .releaseCountdown: return ["Prerelease"]
        case .credits: return ["Creator_Credits"]
        case .merch: return ["Merch_"]
        case .recommendations: return ["RelatedContentRecommendations"]
        default: return []
        }
    }
}

enum PlayerDeclutter {
    static let hidden = Set(UserDefaults.playerOptions.hiddenParts)
    static let cardsMeter = PerfMeter("Player][Cards")
    static let buttonsMeter = PerfMeter("Player][Buttons")
    private static var loggedCards = Set<PlayerPart>()
    private static var cacheKey: UInt8 = 0
    private static let retryWindow: CFTimeInterval = 5

    private final class Verdict {
        weak var content: UIView?
        let part: PlayerPart?
        let settled: Bool
        let born: CFTimeInterval
        let time = CACurrentMediaTime()
        init(content: UIView?, part: PlayerPart?, settled: Bool, born: CFTimeInterval) {
            self.content = content
            self.part = part
            self.settled = settled
            self.born = born
        }
    }

    static let hiddenIds: Set<String> = Set(hidden.flatMap(\.buttonIds))

    static func hideButtons(in unit: UIViewController) {
        for item in row(in: unit) where item.alpha != 0 {
            let id = item.accessibilityIdentifier ?? item.eeveeFirst(UIView.self) { $0.accessibilityIdentifier != nil }?.accessibilityIdentifier
            if let id, hiddenIds.contains(id) { vanish(item) }
        }
    }

    static func row(in unit: UIViewController) -> [UIView] {
        unit.viewIfLoaded?.eeveeFirst(UIStackView.self)?.arrangedSubviews ?? []
    }

    // Arranged views vanish by alpha: some Spotify stacks trap when an arranged view is hidden.
    static func vanish(_ view: UIView) {
        guard view.alpha != 0 else { return }
        view.alpha = 0
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
    }

    static func hiddenCard(for cell: UIView) -> PlayerPart? {
        let content = (cell as? UICollectionViewCell)?.contentView.subviews.first
        let now = CACurrentMediaTime()
        var born = now
        if let verdict = objc_getAssociatedObject(cell, &cacheKey) as? Verdict, verdict.content === content, content != nil {
            // A card's inner content can arrive after its first check, so unsettled misses expire.
            if verdict.part != nil || verdict.settled || now - verdict.time < 1 { return verdict.part }
            born = verdict.born
        }
        let (part, known) = classify(cell)
        let settled = content != nil && (known || now - born >= retryWindow)
        objc_setAssociatedObject(cell, &cacheKey, Verdict(content: content, part: part, settled: settled, born: born), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return part
    }

    private static func classify(_ cell: UIView) -> (part: PlayerPart?, known: Bool) {
        var ancestor = cell.superview
        while let view = ancestor {
            if type(of: view) == type(of: cell) { return (nil, true) }
            ancestor = view.superview
        }
        var names = ""
        var queue = [cell]
        while !queue.isEmpty {
            let view = queue.removeFirst()
            if view !== cell, view is UICollectionView { view.layoutIfNeeded() }
            names += NSStringFromClass(type(of: view))
            if let id = view.accessibilityIdentifier { names += id }
            queue += view.subviews
        }
        guard names.contains("NowPlaying_ScrollAPI") else { return (nil, false) }
        let matched = PlayerPart.cards.first { part in part.cardMarkers.contains { names.contains($0) } }
        let part: PlayerPart?
        if let matched, hidden.contains(matched) || hidden.contains(.allCards) {
            // A known card wins over the generic mode-wrapper exclusion below. Spotify nests
            // some cards inside a NowPlaying_ModesImpl view, which used to make them survive
            // "Hide all cards" even after they were recognized.
            part = matched
        } else if hidden.contains(.allCards), !names.contains("NowPlaying_ModesImpl") {
            part = .allCards
        } else {
            part = nil
        }
        if let part, loggedCards.insert(matched ?? part).inserted {
            eeveeLog("[EeveeSpotify][Player] Collapsed card %@", (matched ?? part).rawValue)
        }
        return (part, matched != nil || names.contains("NowPlaying_ModesImpl"))
    }

    /// Section headers/footers are separate from Element_List cells, so the cell hook alone
    /// cannot remove the newer artist teaser section when all cards are hidden.
    static func hideSupplementaryItemIfNeeded(_ view: UIView) {
        guard hidden.contains(.allCards), isInNowPlayingScroll(view) else { return }
        guard !containsClassNames(["SliderNowPlaying", "PlaybackControlsGridView"], in: view) else { return }
        vanish(view)
    }

    static func isInNowPlayingScroll(_ view: UIView) -> Bool {
        var current: UIView? = view
        while let candidate = current {
            let name = NSStringFromClass(type(of: candidate))
            if name.contains("NowPlaying_Scroll") || name.contains("NPVScroll") { return true }
            if let collection = candidate as? UICollectionView {
                if let source = collection.dataSource,
                   NSStringFromClass(type(of: source)).contains("NowPlaying_Scroll") { return true }
                if let delegate = collection.delegate,
                   NSStringFromClass(type(of: delegate)).contains("NowPlaying_Scroll") { return true }
            }
            current = candidate.superview
        }
        return false
    }

    static func containsClassNames(_ fragments: [String], in view: UIView) -> Bool {
        var queue = [view]
        while !queue.isEmpty {
            let current = queue.removeFirst()
            let name = NSStringFromClass(type(of: current))
            if fragments.contains(where: name.contains) { return true }
            queue += current.subviews
        }
        return false
    }
}

extension UIView {
    func eeveeContainsClass(_ fragment: String) -> Bool {
        eeveeFirst(UIView.self) { NSStringFromClass(type(of: $0)).contains(fragment) } != nil
    }
}

class PlayerCardCellHook: ClassHook<UICollectionViewCell> {
    typealias Group = PlayerCardsDeclutterGroup
    static let targetName = "_TtC12Element_List18CollectionViewCell"

    func preferredLayoutAttributesFittingAttributes(_ attributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes {
        let result = orig.preferredLayoutAttributesFittingAttributes(attributes)
        let part = PlayerDeclutter.cardsMeter.measure { PlayerDeclutter.hiddenCard(for: target) }
        guard part != nil else { return result }
        result.size = CGSize(width: result.size.width, height: 0)
        target.clipsToBounds = true
        return result
    }
}

class PlayerSupplementaryItemHook: ClassHook<UICollectionReusableView> {
    typealias Group = PlayerCardHeadersDeclutterGroup
    static let targetName = "_TtC12Element_List21SupplementaryItemView"

    func layoutSubviews() {
        orig.layoutSubviews()
        PlayerDeclutter.cardsMeter.measure { PlayerDeclutter.hideSupplementaryItemIfNeeded(target) }
    }
}

class PlayerControlsDeclutterHook: ClassHook<UIViewController> {
    typealias Group = PlayerButtonsDeclutterGroup
    static let targetName = "_TtC20NowPlaying_ModesImpl28PlaybackControlsElementsUnit"

    func viewDidLayoutSubviews() {
        orig.viewDidLayoutSubviews()
        PlayerDeclutter.buttonsMeter.measure { PlayerDeclutter.hideButtons(in: target) }
    }
}

class PlayerFooterDeclutterHook: ClassHook<UIViewController> {
    typealias Group = PlayerButtonsDeclutterGroup
    static let targetName = "_TtC20NowPlaying_ModesImpl18FooterElementsUnit"

    func viewDidLayoutSubviews() {
        orig.viewDidLayoutSubviews()
        PlayerDeclutter.buttonsMeter.measure { PlayerDeclutter.hideButtons(in: target) }
    }
}

class PlayerInfoDeclutterHook: ClassHook<UIViewController> {
    typealias Group = PlayerAddToDeclutterGroup
    static let targetName = "_TtC20NowPlaying_ModesImpl23InformationElementsUnit"

    func viewDidLayoutSubviews() {
        orig.viewDidLayoutSubviews()
        for item in PlayerDeclutter.row(in: target) where item.alpha != 0 && item.eeveeContainsClass("AddToButton") {
            PlayerDeclutter.vanish(item)
        }
    }
}

class PlayerLyricsPreviewHook: ClassHook<UIView> {
    typealias Group = PlayerLyricsPreviewDeclutterGroup
    static let targetName = "_TtC17Canvas_CommonImpl26CanvasNowPlayingLyricsView"

    func layoutSubviews() {
        orig.layoutSubviews()
        PlayerDeclutter.vanish(target)
    }
}

func activatePlayerDeclutter() {
    let hidden = PlayerDeclutter.hidden
    guard !hidden.isEmpty else { return }
    let start = CFAbsoluteTimeGetCurrent()
    var active = [String]()
    func activate(_ name: String, _ wanted: Bool, _ group: HookGroup, _ classes: String...) {
        guard wanted else { return }
        let missing = classes.filter { NSClassFromString($0) == nil }
        guard missing.isEmpty else {
            eeveeLog("[EeveeSpotify][Player] Skipped %@: missing %@", name, missing.joined(separator: ", "))
            return
        }
        group.activate()
        active.append(name)
    }

    activate("buttons", !PlayerDeclutter.hiddenIds.isEmpty, PlayerButtonsDeclutterGroup(),
             PlayerControlsDeclutterHook.targetName, PlayerFooterDeclutterHook.targetName)
    activate("add to", hidden.contains(.addTo), PlayerAddToDeclutterGroup(), PlayerInfoDeclutterHook.targetName)
    activate("lyrics preview", hidden.contains(.lyricsPreview), PlayerLyricsPreviewDeclutterGroup(), PlayerLyricsPreviewHook.targetName)
    activate("cards", !hidden.isDisjoint(with: PlayerPart.cards), PlayerCardsDeclutterGroup(), PlayerCardCellHook.targetName)
    activate("card headers", hidden.contains(.allCards), PlayerCardHeadersDeclutterGroup(), PlayerSupplementaryItemHook.targetName)
    eeveeLog("[EeveeSpotify][Player] Declutter: hiding %@; active %@ (%.2f ms)",
             hidden.map(\.rawValue).sorted().joined(separator: ", "), active.joined(separator: ", "),
             (CFAbsoluteTimeGetCurrent() - start) * 1000)
}
