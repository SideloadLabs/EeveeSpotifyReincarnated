import EeveeSpotifyC
import UIKit

// Glass header controls forwarding to Spotify, with a native horizontal action strip.
@available(iOS 26.0, *)
final class PlaylistActionRow: UIView {
    static weak var current: PlaylistActionRow?
    private(set) weak var download: UIView?
    weak var shuffle: UIView?
    weak var play: UIView?
    weak var add: UIView?
    weak var share: UIView?
    weak var explore: UIView?
    private(set) weak var sourceRoot: UIView?
    private var previewSize = CGSize.zero
    private var preservesPreviewLayout = false
    private weak var mountedDownload: UIView?
    private weak var mountedPreview: UIView?
    private var previewObservations = [NSKeyValueObservation]()
    private var previewUpdatePending = false
    weak var followControl: UIView?
    weak var anchor: UIView?
    // Spotify's single play button moves into the nav bar once its row collapses; ours steps aside and lets it show there.
    weak var playHolder: UIView?
    weak var controlsRow: UIView?
    private var scrollObservation: NSKeyValueObservation?
    private weak var followed: UIScrollView?
    private var faded = false
    private let actions = PlaylistActionsScrollView()

    // Resolve a cached native download control, including granular state IDs.
    static func downloadControl(in root: UIView) -> UIView? {
        PlaylistDownloadControl.resolve(in: root)
    }

    func hosts(_ source: UIView?) -> Bool { source?.superview === actions }

    // Mount each native control once per binding. Spotify keeps its original
    // button, icon subtree and action. The shared scroller owns row geometry.
    func bindNative(download: UIView?, preview: UIView?, root: UIView, preservePreviewLayout: Bool = false) {
        let previewChanged = sourceRoot !== root || explore !== preview || preservesPreviewLayout != preservePreviewLayout
        preservesPreviewLayout = preservePreviewLayout
        let changed = previewChanged || self.download !== download
        if previewChanged { previewObservations.removeAll() }
        if sourceRoot !== root { mountedDownload = nil; mountedPreview = nil }
        if self.download !== download, let old = self.download, hosts(old) { old.removeFromSuperview() }
        if explore !== preview, let old = explore, hosts(old) { old.removeFromSuperview() }
        sourceRoot = root
        self.download = download
        explore = preview
        if let download, mountedDownload !== download {
            PlaylistDownloadControl.style(download)
            PlaylistDownloadControl.hosted(download, from: root)
            download.translatesAutoresizingMaskIntoConstraints = true
            actions.addSubview(download)
            mountedDownload = download
            setNeedsLayout()
        }
        if previewChanged, let preview {
            // Spotify initially exposes a hidden, 8-point placeholder. Its
            // component fills and unhides it asynchronously, without another
            // controller layout. Watch only that pending component, then stop.
            previewObservations = [
                preview.observe(\.isHidden) { [weak self] _, _ in self?.previewBecameReady() },
                preview.observe(\.bounds) { [weak self] _, _ in self?.previewBecameReady() },
                preview.observe(\.center) { [weak self] _, _ in self?.previewBecameReady() }
            ]
        }
        mountPreviewIfReady()
        if changed { actions.contentOffset = .zero; setNeedsLayout() }
    }

    // Hosted outside Spotify's header (adding views there stalls its layout), so it follows the header's scroll itself.
    func follow(_ scrollView: UIScrollView?) {
        guard let scrollView, scrollView !== followed else { return }
        followed = scrollView
        scrollObservation = scrollView.observe(\.contentOffset) { [weak self] _, _ in self?.place() }
    }

    func place() {
        guard let host = superview, host.window != nil else { return }
        if let anchor, anchor.window != nil, anchor.bounds.height > 0 {
            let frame = anchor.convert(anchor.bounds, to: host)
            let target = CGRect(x: 0, y: frame.midY - 24, width: host.bounds.width, height: 48)
            if self.frame != target { self.frame = target }
        }
        let pinned = collapsed() || convert(bounds, to: nil).minY < (window?.safeAreaInsets.top ?? 0) + 50
        playHolder.map { holder in
            if holder.alpha != (pinned ? 1 : 0) { holder.alpha = pinned ? 1 : 0 }
            holder.isUserInteractionEnabled = pinned
        }
        guard pinned != faded else { return }
        faded = pinned
        UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.alpha = pinned ? 0 : 1
        }
    }

    private func collapsed() -> Bool {
        var view = controlsRow
        while let current = view, current !== superview {
            if current.isHidden || current.alpha < 0.5 { return true }
            view = current.superview
        }
        return false
    }

    private let shuffleButton = PlaylistActionRow.circle("shuffle")
    private let shuffleDot: UIView = {
        let dot = UIView(frame: CGRect(x: 0, y: 0, width: 4, height: 4))
        dot.layer.cornerRadius = 2
        dot.isUserInteractionEnabled = false
        dot.isHidden = true
        return dot
    }()
    private let artistDownloadButton = PlaylistActionRow.circle("arrow.down")
    private let addButton = PlaylistActionRow.circle("plus")
    private weak var artistHeader: UIView?
    private let followButton: UIButton = {
        let button = PlaylistActionRow.circle("person.badge.plus")
        button.isHidden = true
        return button
    }()
    private let shareButton = PlaylistActionRow.circle("square.and.arrow.up")
    private let playButton: UIButton = {
        var config = UIButton.Configuration.prominentGlass()
        config.cornerStyle = .capsule
        config.baseForegroundColor = .black
        config.imagePadding = 8
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
            var attributes = $0
            attributes.font = .systemFont(ofSize: 16, weight: .semibold)
            return attributes
        }
        let button = UIButton(configuration: config)
        button.tintColor = .white
        return button
    }()

    private static let playImage = UIImage(systemName: "play.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .bold))
    private static let pauseImage = UIImage(systemName: "pause.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .bold))
    private static let followImage = UIImage(systemName: "person.badge.plus", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold))
    private static let followedImage = UIImage(systemName: "person.fill.checkmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold))
    private static let plusImage = UIImage(systemName: "plus", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold))
    private static let checkImage = UIImage(systemName: "checkmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold))
    private static let playTitle = "playlist_play".localized
    private static let pauseTitle = "playlist_pause".localized

    private static func circle(_ symbol: String) -> UIButton {
        var config = UIButton.Configuration.glass()
        config.cornerStyle = .capsule
        config.baseForegroundColor = .white
        config.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold))
        return UIButton(configuration: config)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        overrideUserInterfaceStyle = .dark
        actions.accessibilityIdentifier = "Eevee.Playlist.Actions"
        actions.showsHorizontalScrollIndicator = false
        actions.alwaysBounceVertical = false
        actions.isDirectionalLockEnabled = true
        actions.delaysContentTouches = false
        actions.contentInsetAdjustmentBehavior = .never
        addSubview(actions)
        addSubview(playButton)
        artistDownloadButton.accessibilityIdentifier = "Eevee.Artist.Download"
        artistDownloadButton.accessibilityLabel = "Artist downloads"
        artistDownloadButton.isHidden = true
        actions.addSubview(artistDownloadButton)
        for (button, name) in [(shuffleButton,"Shuffle"),(addButton,"Add"),(shareButton,"Share"),(followButton,"Follow")] {
            button.accessibilityIdentifier = "Eevee.Playlist." + name
            actions.addSubview(button)
        }
        playButton.accessibilityIdentifier = "Eevee.Playlist.Play"
        shuffleButton.addSubview(shuffleDot)
        shuffleButton.addAction(UIAction { [weak self] _ in self?.forward(self?.shuffle, "shuffle") }, for: .primaryActionTriggered)
        playButton.addAction(UIAction { [weak self] _ in self?.forward(self?.play, "play") }, for: .primaryActionTriggered)
        addButton.addAction(UIAction { [weak self] _ in self?.forward(self?.add, "add") }, for: .primaryActionTriggered)
        followButton.addAction(UIAction { [weak self] _ in self?.forward(self?.followControl, "follow") }, for: .primaryActionTriggered)
        shareButton.addAction(UIAction { [weak self] _ in self?.forward(self?.share, "share") }, for: .primaryActionTriggered)
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let side: CGFloat = 48, gap: CGFloat = 12, edge: CGFloat = 16
        let y = (bounds.height - side) / 2
        let playWidth = min(max(140, playButton.sizeThatFits(CGSize(width: 220, height: side)).width), max(96, bounds.width * 0.45))
        let playFrame = CGRect(x: bounds.width - edge - playWidth, y: y, width: playWidth, height: side)
        if playButton.frame != playFrame { playButton.frame = playFrame }
        let start = preservesPreviewLayout ? nativePreviewEnd(in: self).map { max(edge, $0 + gap) } ?? edge : edge
        let stripFrame = CGRect(x: start, y: y, width: max(0, playFrame.minX - gap - start), height: side)
        if actions.frame != stripFrame { actions.frame = stripFrame }
        var x: CGFloat = 0
        for native in [explore, download].compactMap({ $0 }) where hosts(native) && !native.isHidden {
            let size = native === explore ? previewSize : CGSize(width: side, height: side)
            let frame = CGRect(x: x, y: (side-size.height)/2, width: size.width, height: size.height)
            if native.frame != frame { native.frame = frame }
            x += size.width + gap
        }
        for button in [shuffleButton, artistDownloadButton, addButton, shareButton, followButton] where !button.isHidden {
            let width = side
            let frame = CGRect(x: x, y: 0, width: width, height: side)
            if button.frame != frame { button.frame = frame }
            x += width + gap
        }
        shuffleDot.center = CGPoint(x: side / 2, y: side - 7)
        let size = CGSize(width: max(0, x - gap), height: side)
        if actions.contentSize != size { actions.contentSize = size }
        let offset = max(0, min(actions.contentOffset.x, size.width - actions.bounds.width))
        if actions.contentOffset.x != offset { actions.contentOffset.x = offset }
    }

    private func previewBecameReady() {
        guard !previewUpdatePending else { return }
        previewUpdatePending = true
        // Complete Spotify's current native component/layout update first.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.previewUpdatePending = false
            if self.preservesPreviewLayout {
                self.place()
                self.sync()
                self.setNeedsLayout()
            } else {
                self.mountPreviewIfReady()
            }
        }
    }

    // Artist previews belong to Spotify's asynchronous Element/OverflowStack
    // layout. Keep their hierarchy and geometry entirely under native ownership.
    private func nativePreviewEnd(in host: UIView) -> CGFloat? {
        guard let preview = explore, preview.window != nil else { return nil }
        var ancestor: UIView? = preview
        while let node = ancestor, node !== superview {
            if node.isHidden || node.alpha < 0.01 { return nil }
            ancestor = node.superview
        }
        var box = preview.convert(preview.bounds, to: host)
        // Native artwork/hit areas may extend outside their small layout shell.
        var queue = preview.subviews
        var index = 0
        while index < queue.count {
            let child = queue[index]; index += 1
            guard !child.isHidden, child.alpha > 0.01 else { continue }
            if child is UIControl || child is UIImageView {
                box = box.union(child.convert(child.bounds, to: host))
            }
            queue += child.subviews
        }
        return box.isEmpty ? nil : box.maxX
    }

    private func mountPreviewIfReady() {
        guard !preservesPreviewLayout, let preview = explore, mountedPreview !== preview,
              !preview.isHidden, preview.bounds.width > 1, preview.bounds.height > 1 else { return }
        previewSize = preview.bounds.size
        previewObservations.removeAll()
        preview.translatesAutoresizingMaskIntoConstraints = true
        actions.addSubview(preview)
        mountedPreview = preview
        setNeedsLayout()
        }

    private func forward(_ source: UIView?, _ name: String) {
        guard let source else { return }
        let fired = EeveeFireTap(source)
        if !fired { eeveeLog("[EeveeSpotify][Glass] Playlist %@ tap FAILED", name) }
        for delay in [0.4, 1.2, 2.5] { DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.sync() } }
    }

    func bindArtistDownloads(header: UIView?) {
        artistHeader = header
        guard let header else {
            if !artistDownloadButton.isHidden { artistDownloadButton.isHidden = true; setNeedsLayout() }
            return
        }
        let wasHidden = artistDownloadButton.isHidden
        EeveePixieUpdateArtistDownloads(header, artistDownloadButton)
        if wasHidden != artistDownloadButton.isHidden { setNeedsLayout() }
    }

    func sync() {
        if addButton.isHidden != (add == nil) {
            addButton.isHidden = add == nil
            setNeedsLayout()
        }
        let followVisible = followControl != nil
        var followConfig = followButton.configuration
        let state = artistHeader.map { header in
            EeveePixieArtistFollowing(header) { [weak self] in self?.sync() }
        } ?? -1
        followConfig?.image = state == 1 ? Self.followedImage : Self.followImage
        followConfig?.baseForegroundColor = state == 1 ? Theme.accent : .white
        followButton.accessibilityLabel = followControl?.accessibilityLabel ?? followControl?.eeveeFirst(UILabel.self)?.text
        if followButton.configuration != followConfig || followButton.isHidden == followVisible {
            followButton.configuration = followConfig
            followButton.isHidden = !followVisible
            setNeedsLayout()
        }
        if shareButton.isHidden != (share == nil) {
            shareButton.isHidden = share == nil
            setNeedsLayout()
        }
        let playing = (play?.accessibilityLabel ?? play?.eeveeFirst(UIControl.self)?.accessibilityLabel)?.lowercased().contains("pause") == true
        var config = playButton.configuration
        config?.image = playing ? Self.pauseImage : Self.playImage
        config?.title = playing ? Self.pauseTitle : Self.playTitle
        if playButton.configuration != config { playButton.configuration = config }

        let liked = add?.accessibilityLabel?.lowercased().contains("remove") == true
        var addConfig = addButton.configuration
        addConfig?.image = liked ? Self.checkImage : Self.plusImage
        addConfig?.baseForegroundColor = liked ? Theme.accent : .white
        if addButton.configuration != addConfig { addButton.configuration = addConfig }

        // Spotify marks shuffle with a small dot under its icon and swaps the icon for smart shuffle.
        let dot = shuffle?.eeveeFirst(UIView.self) { $0.bounds.width <= 8 && $0.bounds.width > 0 && $0.backgroundColor != nil && !$0.isHidden }
        let shuffled = (shuffle as? UIControl)?.isSelected == true || dot != nil
        var shuffleConfig = shuffleButton.configuration
        shuffleConfig?.baseForegroundColor = shuffled ? Theme.accent : .white
        if let icon = shuffle?.eeveeFirst(UIImageView.self, where: { $0.image != nil && $0.bounds.width >= 16 })?.image {
            shuffleConfig?.image = icon.withRenderingMode(.alwaysTemplate)
        }
        shuffleDot.isHidden = !shuffled
        shuffleDot.backgroundColor = Theme.accent
        if shuffleButton.configuration != shuffleConfig { shuffleButton.configuration = shuffleConfig }
    }
}

// The standard scroll-view cancellation policy lets a swipe starting on a
// button cancel its tap, while the Play button stays outside the scroll view.
@available(iOS 26.0, *)
private final class PlaylistActionsScrollView: UIScrollView {
    override func touchesShouldCancel(in view: UIView) -> Bool {
        view is UIControl || super.touchesShouldCancel(in: view)
    }
}
