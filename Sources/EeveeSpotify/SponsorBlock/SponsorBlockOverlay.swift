import UIKit

private let overlayTag = "EeveeSBOverlay"
private let segmentBarTag = "EeveeSBBar"

final class SponsorBlockOverlayContainer: UIView {
    var segmentFrames: [(uuid: String, frame: CGRect)] = []

    // Visual only. Touches must reach the slider for pan-on-thumb to work
    // even with thumb sitting on a bar; tap/long-press handled by slider recognizers.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
}

final class SponsorBlockOverlay: NSObject, UIGestureRecognizerDelegate {
    static let shared = SponsorBlockOverlay()

    private var trackedSliders: NSHashTable<UIView> = NSHashTable.weakObjects()
    private var slidersWithLongPress: NSHashTable<UIView> = NSHashTable.weakObjects()
    private var slidersWithSegmentTap: NSHashTable<UIView> = NSHashTable.weakObjects()

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    // x-axis only: bar is ~3pt tall, finger center is far above it.
    private func segmentUUIDForTouch(_ touch: UITouch, on slider: UIView) -> String? {
        let p = touch.location(in: slider)
        for sv in slider.subviews where sv.accessibilityIdentifier == "EeveeSBOverlay" {
            guard let container = sv as? SponsorBlockOverlayContainer else { continue }
            let xInContainer = slider.convert(p, to: container).x
            for s in container.segmentFrames {
                let xPad = max(8, s.frame.width * 0.15)
                if xInContainer >= s.frame.minX - xPad && xInContainer <= s.frame.maxX + xPad {
                    return s.uuid
                }
            }
        }
        return nil
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldReceive touch: UITouch) -> Bool {
        guard let slider = gestureRecognizer.view else { return true }
        let onSegment = segmentUUIDForTouch(touch, on: slider) != nil
        // Long-press = submit anywhere except on a bar; tap = segment-action only on bar.
        if gestureRecognizer is UILongPressGestureRecognizer { return !onSegment }
        if gestureRecognizer is UITapGestureRecognizer { return onSegment }
        return true
    }

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refreshAll),
            name: SponsorBlockSkipper.segmentsChangedNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refreshAll),
            name: SponsorBlockHiddenStore.changedNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refreshAll),
            name: SponsorBlockPendingStore.changedNotification,
            object: nil
        )
    }

    func attach(to slider: UIView) {
        let before = trackedSliders.allObjects.count
        trackedSliders.add(slider)
        if trackedSliders.allObjects.count != before {
            writeDebugLog("[SB] tracked slider count=\(trackedSliders.allObjects.count) bounds=\(NSCoder.string(for: slider.bounds))")
            for (i, sv) in slider.subviews.enumerated() {
                writeDebugLog("[SB]   sv[\(i)] \(NSStringFromClass(type(of: sv))) frame=\(NSCoder.string(for: sv.frame))")
            }
        }

        installLongPressIfNeeded(on: slider)
        installSegmentTapIfNeeded(on: slider)

        let snap = SponsorBlockSkipper.shared.snapshot()
        let opts = UserDefaults.sponsorBlockOptions
        let wantDraw = opts.enabled && opts.showOverlay && snap.duration > 0 && !snap.segments.isEmpty
        let hasStale = slider.subviews.contains { $0.accessibilityIdentifier == overlayTag }
        if !wantDraw && !hasStale { return }

        update(slider: slider)
    }

    @objc private func refreshAll() {
        if Thread.isMainThread {
            doRefresh()
        } else {
            DispatchQueue.main.async { [weak self] in self?.doRefresh() }
        }
    }

    private func doRefresh() {
        for s in trackedSliders.allObjects { update(slider: s) }
    }

    func update(slider: UIView) {
        let opts = UserDefaults.sponsorBlockOptions
        slider.subviews
            .filter { $0.accessibilityIdentifier == overlayTag }
            .forEach { $0.removeFromSuperview() }

        guard opts.enabled, opts.showOverlay else { return }

        let snap = SponsorBlockSkipper.shared.snapshot()
        guard snap.duration > 0 else { return }

        let pendingMarker: SponsorBlockPendingSegment? = snap.episodeID.flatMap { id in
            SponsorBlockPendingStore.segments(for: id).first { $0.end == nil }
        }
        let hidden = Set(SponsorBlockHiddenStore.all())
        let visibleSegments = snap.segments.filter { seg in
            seg.isSkip && opts.action(for: seg.category) != .disabled && !hidden.contains(seg.uuid)
        }
        guard !visibleSegments.isEmpty || pendingMarker != nil else { return }

        let trackFrame = innerTrackFrame(in: slider)
        let container = SponsorBlockOverlayContainer(frame: trackFrame)
        container.accessibilityIdentifier = overlayTag
        container.isUserInteractionEnabled = true
        container.backgroundColor = .clear
        container.layer.zPosition = 1

        let w = trackFrame.width
        let h = trackFrame.height

        var frames: [(String, CGRect)] = []
        for seg in visibleSegments {
            let x = CGFloat(seg.start / snap.duration) * w
            let segW = max(2, CGFloat((seg.end - seg.start) / snap.duration) * w)
            let f = CGRect(x: x, y: 0, width: segW, height: h)
            let bar = UIView(frame: f)
            bar.backgroundColor = UIColor.fromHex(opts.color(for: seg.category)).withAlphaComponent(0.65)
            bar.layer.cornerRadius = min(1, h / 2)
            bar.isUserInteractionEnabled = false
            bar.accessibilityIdentifier = segmentBarTag
            container.addSubview(bar)
            frames.append((seg.uuid, f))
        }
        container.segmentFrames = frames

        if let pending = pendingMarker {
            let markerW: CGFloat = 3
            let xRaw = CGFloat(pending.start / snap.duration) * w
            let x = max(0, min(w - markerW, xRaw))
            let markerH = max(h, 12.0)
            let yOffset = (h - markerH) / 2
            let marker = UIView(frame: CGRect(x: x, y: yOffset, width: markerW, height: markerH))
            marker.backgroundColor = UIColor(red: 0.12, green: 0.84, blue: 0.38, alpha: 1)
            marker.layer.cornerRadius = 1
            marker.layer.shadowColor = UIColor.black.cgColor
            marker.layer.shadowOpacity = 0.5
            marker.layer.shadowRadius = 2
            marker.layer.shadowOffset = .zero
            marker.isUserInteractionEnabled = false
            container.addSubview(marker)
        }

        slider.clipsToBounds = false
        slider.addSubview(container)
        slider.bringSubviewToFront(container)
    }

    private func installSegmentTapIfNeeded(on slider: UIView) {
        guard !slidersWithSegmentTap.contains(slider) else { return }
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleSegmentTap(_:)))
        // Suppress Spotify's tap-to-seek under the bar. Drag still works (movement fails tap).
        tap.cancelsTouchesInView = true
        tap.delaysTouchesBegan = false
        tap.delaysTouchesEnded = false
        tap.delegate = self
        slider.addGestureRecognizer(tap)
        slidersWithSegmentTap.add(slider)
    }

    @objc private func handleSegmentTap(_ recog: UITapGestureRecognizer) {
        guard recog.state == .ended, let slider = recog.view else { return }
        let p = recog.location(in: slider)
        var bestUUID: String?
        var bestDist: CGFloat = .greatestFiniteMagnitude
        for sv in slider.subviews where sv.accessibilityIdentifier == overlayTag {
            guard let container = sv as? SponsorBlockOverlayContainer else { continue }
            let xInContainer = slider.convert(p, to: container).x
            for s in container.segmentFrames {
                let xPad = max(8, s.frame.width * 0.15)
                guard xInContainer >= s.frame.minX - xPad,
                      xInContainer <= s.frame.maxX + xPad else { continue }
                let dx = abs(xInContainer - s.frame.midX)
                if dx < bestDist { bestDist = dx; bestUUID = s.uuid }
            }
        }
        guard let uuid = bestUUID else { return }
        SponsorBlockReportingUI.presentSegmentActions(uuid: uuid, anchor: slider)
    }

    private func installLongPressIfNeeded(on slider: UIView) {
        guard !slidersWithLongPress.contains(slider) else { return }
        guard UserDefaults.sponsorBlockOptions.enabled else { return }
        let lp = UILongPressGestureRecognizer(target: self, action: #selector(handleSliderLongPress(_:)))
        lp.minimumPressDuration = 0.65
        lp.allowableMovement = 5
        lp.cancelsTouchesInView = false
        lp.delaysTouchesBegan = false
        // Critical: default true → slider's touchesEnded sits queued until the
        // recognizer fails, making taps feel frozen for ~0.6s. Releasing this lets
        // tap-to-seek dispatch immediately while the long-press can still fire.
        lp.delaysTouchesEnded = false
        lp.delegate = self
        slider.addGestureRecognizer(lp)
        slidersWithLongPress.add(slider)
        writeDebugLog("[SB] long-press installed on slider")
    }

    @objc private func handleSliderLongPress(_ recog: UILongPressGestureRecognizer) {
        guard recog.state == .began else { return }
        guard let view = recog.view else { return }
        let snap = SponsorBlockSkipper.shared.currentPlayhead()
        guard snap.episodeID != nil else {
            SponsorBlockToast.shared.show("SponsorBlock: only works on podcast episodes")
            return
        }
        // Toggle off→on to drop slider's stuck touch tracker (cancelsTouchesInView=false
        // leaves it thinking finger is still down after action sheet present).
        view.isUserInteractionEnabled = false
        DispatchQueue.main.async { view.isUserInteractionEnabled = true }
        SponsorBlockReportingUI.presentSubmissionActions(currentPlayheadSec: snap.position, anchor: view)
    }

    private func innerTrackFrame(in slider: UIView) -> CGRect {
        for sv in slider.subviews {
            let name = NSStringFromClass(type(of: sv))
            if name.contains("AudioView") || name.contains("ProgressTrack") {
                return sv.frame
            }
        }
        let h: CGFloat = max(2, min(4, slider.bounds.height))
        return CGRect(x: 0, y: (slider.bounds.height - h) / 2,
                      width: slider.bounds.width, height: h)
    }
}

extension UIColor {
    static func fromHex(_ hex: String) -> UIColor {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return .gray }
        let r = CGFloat((v & 0xFF0000) >> 16) / 255.0
        let g = CGFloat((v & 0x00FF00) >> 8) / 255.0
        let b = CGFloat(v & 0x0000FF) / 255.0
        return UIColor(red: r, green: g, blue: b, alpha: 1)
    }
}
