import UIKit
import SwiftUI

enum SponsorBlockReportingUI {

    static func presentSegmentActions(uuid: String, anchor: UIView) {
        guard let seg = SponsorBlockSkipper.shared.segment(withUUID: uuid) else { return }
        let voted = SponsorBlockVotedStore.direction(for: uuid)
        let votedSuffix: String = {
            switch voted {
            case .up:   return "  ·  you upvoted ▲"
            case .down: return "  ·  you downvoted ▼"
            case .none: return ""
            }
        }()
        let title = "\(SponsorBlockFormatters.categoryName(seg.category)) · \(fmtRange(seg))\(votedSuffix)"
        let alert = UIAlertController(title: "SponsorBlock segment", message: title, preferredStyle: .actionSheet)

        alert.addAction(UIAlertAction(title: voted == .up ? "Upvote ✓" : "Upvote", style: .default) { _ in
            sendVote(uuid: uuid, type: .up)
        })
        alert.addAction(UIAlertAction(title: voted == .down ? "Downvote ✓" : "Downvote", style: .destructive) { _ in
            sendVote(uuid: uuid, type: .down)
        })
        if voted != nil {
            alert.addAction(UIAlertAction(title: "Remove my vote", style: .default) { _ in
                sendVote(uuid: uuid, type: .undo)
            })
        }
        alert.addAction(UIAlertAction(title: "Change category…", style: .default) { _ in
            presentCategoryVote(uuid: uuid, currentCategory: seg.category, anchor: anchor)
        })
        let isHidden = SponsorBlockHiddenStore.contains(uuid)
        alert.addAction(UIAlertAction(
            title: isHidden ? "Unhide (allow skipping again)" : "Hide locally (never skip)",
            style: .default
        ) { _ in
            if isHidden {
                SponsorBlockHiddenStore.remove(uuid)
                SponsorBlockToast.shared.show("Segment will skip again")
            } else {
                SponsorBlockHiddenStore.add(uuid)
                SponsorBlockToast.shared.show("Segment hidden on this device")
            }
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, sourceView: anchor)
    }

    static func presentSubmissionActions(currentPlayheadSec: Double, anchor: UIView) {
        let snap = SponsorBlockSkipper.shared.currentPlayhead()
        guard let episodeID = snap.episodeID else {
            SponsorBlockToast.shared.show("SponsorBlock: only works on podcast episodes")
            return
        }

        let pending = SponsorBlockPendingStore.segments(for: episodeID)
        let active = pending.first { $0.end == nil }

        let alert = UIAlertController(
            title: "Report podcast segment",
            message: "Now at \(SponsorBlockFormatters.time(currentPlayheadSec))",
            preferredStyle: .actionSheet
        )

        if let active {
            alert.addAction(UIAlertAction(title: "Set END at \(SponsorBlockFormatters.time(currentPlayheadSec))", style: .default) { _ in
                var copy = active
                copy.end = max(currentPlayheadSec, copy.start + 0.1)
                SponsorBlockPendingStore.upsert(copy)
                presentSubmitForm(pending: copy, duration: snap.duration)
            })
            alert.addAction(UIAlertAction(title: "Re-set START at \(SponsorBlockFormatters.time(currentPlayheadSec))", style: .default) { _ in
                var copy = active
                copy.start = currentPlayheadSec
                SponsorBlockPendingStore.upsert(copy)
                SponsorBlockToast.shared.show("Start moved to \(SponsorBlockFormatters.time(currentPlayheadSec))")
            })
            alert.addAction(UIAlertAction(title: "Discard draft", style: .destructive) { _ in
                SponsorBlockPendingStore.remove(id: active.id, episodeID: episodeID)
                SponsorBlockToast.shared.show("Draft discarded")
            })
        } else {
            alert.addAction(UIAlertAction(title: "Set START at \(SponsorBlockFormatters.time(currentPlayheadSec))", style: .default) { _ in
                let p = SponsorBlockPendingSegment(episodeID: episodeID, start: currentPlayheadSec)
                SponsorBlockPendingStore.upsert(p)
                SponsorBlockToast.shared.show("Start set · long-press again at end of segment")
            })
        }

        let readyDrafts = pending.filter { $0.isReadyToSubmit }
        if let last = readyDrafts.last {
            alert.addAction(UIAlertAction(title: "Open submission form…", style: .default) { _ in
                presentSubmitForm(pending: last, duration: snap.duration)
            })
        }

        let segCount = SponsorBlockSkipper.shared.snapshot().segments.count
        if segCount > 0 {
            alert.addAction(UIAlertAction(title: "Manage segments in this episode (\(segCount))…", style: .default) { _ in
                presentEpisodeSegments(episodeID: episodeID)
            })
        }

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, sourceView: anchor)
    }

    static func presentEpisodeSegments(episodeID: String) {
        guard let host = topVC() else { return }
        let view = SponsorBlockEpisodeSegmentsView(episodeID: episodeID)
        let hosting = UIHostingController(rootView: view)
        hosting.modalPresentationStyle = .formSheet
        hosting.overrideUserInterfaceStyle = .dark
        hosting.view.backgroundColor = .systemBackground
        if #available(iOS 15.0, *), let sheet = hosting.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        host.present(hosting, animated: true)
    }

    static func presentSkipFeedback(
        segment: SponsorBlockSegment,
        onUndo: @escaping () -> Void
    ) {
        let category = SponsorBlockFormatters.categoryShortName(segment.category)
        let msg = "Skipped \(category) (\(Int(segment.duration))s)"
        let opts = UserDefaults.sponsorBlockOptions

        guard opts.showSkipFeedbackButtons else {
            SponsorBlockToast.shared.show(msg)
            return
        }

        let uuid = segment.uuid
        SponsorBlockToast.shared.show(message: msg, actions: [
            .init(systemImage: "arrow.uturn.backward", style: .secondary) { onUndo() },
            .init(systemImage: "hand.thumbsup.fill",   style: .primary) { sendVote(uuid: uuid, type: .up) },
            .init(systemImage: "hand.thumbsdown.fill", style: .destructive) { presentDownvoteMenu(uuid: uuid, category: segment.category) },
            .init(systemImage: "ellipsis",             style: .secondary, tintOverride: UIColor.systemBlue) {
                if let anchor = SponsorBlockToast.shared.currentView {
                    presentSegmentActions(uuid: uuid, anchor: anchor)
                }
            },
        ], duration: 6.0)
    }

    static func presentSubmitForm(pending: SponsorBlockPendingSegment, duration: Double) {
        guard let host = topVC() else { return }
        let view = SponsorBlockSubmitView(pending: pending, duration: duration)
        let hosting = UIHostingController(rootView: view)
        hosting.modalPresentationStyle = .formSheet
        hosting.overrideUserInterfaceStyle = .dark
        hosting.view.backgroundColor = .systemBackground
        if #available(iOS 15.0, *), let sheet = hosting.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        host.present(hosting, animated: true)
    }

    private static func presentDownvoteMenu(uuid: String, category: String) {
        guard let top = topVC() else { return }
        let alert = UIAlertController(title: "Downvote segment", message: nil, preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "Downvote only", style: .destructive) { _ in
            sendVote(uuid: uuid, type: .down)
        })
        alert.addAction(UIAlertAction(title: "Downvote & hide locally (never skip again)", style: .destructive) { _ in
            SponsorBlockHiddenStore.add(uuid)
            sendVote(uuid: uuid, type: .down)
        })
        alert.addAction(UIAlertAction(title: "Change category…", style: .default) { _ in
            presentCategoryVote(uuid: uuid, currentCategory: category, anchor: top.view)
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let pop = alert.popoverPresentationController {
            pop.sourceView = top.view
            pop.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
            pop.permittedArrowDirections = []
        }
        top.present(alert, animated: true)
    }

    private static func presentCategoryVote(uuid: String, currentCategory: String, anchor: UIView) {
        let alert = UIAlertController(title: "Change category", message: nil, preferredStyle: .actionSheet)
        for key in SponsorBlockOptions.allCategoryOrder where key != currentCategory {
            alert.addAction(UIAlertAction(title: SponsorBlockFormatters.categoryName(key), style: .default) { _ in
                SponsorBlockReporter.categoryVote(uuid: uuid, category: key) { result in
                    DispatchQueue.main.async { presentResultToast(result, success: "Category vote sent") }
                }
            })
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, sourceView: anchor)
    }

    private static func sendVote(uuid: String, type: SponsorBlockVote) {
        SponsorBlockReporter.vote(uuid: uuid, type: type) { result in
            DispatchQueue.main.async {
                if case .success = result {
                    SponsorBlockVotedStore.record(uuid: uuid, vote: type)
                }
                let msg: String = {
                    switch type {
                    case .up:   return "Upvoted"
                    case .down: return "Downvoted"
                    case .undo: return "Vote cleared"
                    }
                }()
                presentResultToast(result, success: msg)
            }
        }
    }

    private static func presentResultToast(_ result: Result<Void, SponsorBlockReporterError>, success: String) {
        switch result {
        case .success: SponsorBlockToast.shared.show(success)
        case .failure(let err): SponsorBlockToast.shared.show("Failed: \(err.localizedDescription)")
        }
    }

    private static func present(_ alert: UIAlertController, sourceView: UIView) {
        if let pop = alert.popoverPresentationController {
            pop.sourceView = sourceView
            pop.sourceRect = sourceView.bounds
            pop.permittedArrowDirections = [.any]
        }
        topVC()?.present(alert, animated: true)
    }

    private static func topVC() -> UIViewController? {
        for scene in UIApplication.shared.connectedScenes {
            guard let ws = scene as? UIWindowScene,
                  ws.activationState == .foregroundActive else { continue }
            let win = ws.windows.first(where: { $0.isKeyWindow }) ?? ws.windows.first
            guard var top = win?.rootViewController else { continue }
            while let p = top.presentedViewController { top = p }
            return top
        }
        return nil
    }

    private static func fmtRange(_ s: SponsorBlockSegment) -> String {
        "\(SponsorBlockFormatters.time(s.start)) → \(SponsorBlockFormatters.time(s.end))"
    }
}
