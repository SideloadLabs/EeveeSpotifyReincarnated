import UIKit

@objc(EeveeOfflineLyricsDownloader)
final class LyricsFixtureBridge: NSObject {
    static var scan = true
    static var batch: [String: Any] = [:]
    static var cancels = 0
    @objc static func settingsSnapshot() -> NSDictionary {
        ["enabled": true, "available": true, "source": "SpicyLyrics",
         "scan_active": scan, "scan_completed": 40, "scan_total": 155,
         "batch": batch, "tracks": 22, "bytes": 120000, "statistics_loading": false,
         "library_known": true, "library_missing": 133, "library_total": 155] as NSDictionary
    }
    @objc static func cancelDownloads() {
        cancels += 1; scan = false; batch = [:]; changed()
    }
    static func changed() { NotificationCenter.default.post(name: .init("EeveeOfflineLyricsSettingsChanged"), object: nil) }
}

@main final class LyricsFixtureApp: UIResponder, UIApplicationDelegate {}
@objc(SAPLyricsFixtureScene)
final class LyricsFixtureScene: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene); self.window = window
        let nav = UINavigationController(rootViewController: UIViewController())
        window.rootViewController = nav; window.overrideUserInterfaceStyle = .dark; window.makeKeyAndVisible()
        let page = SAPCreateLyricsSettings() as! UITableViewController
        nav.pushViewController(page, animated: false)
        DispatchQueue.main.asyncAfter(deadline: .now()+0.7) {
            self.checkActive(page); self.capture("lyrics-scan")
            LyricsFixtureBridge.scan = false
            LyricsFixtureBridge.batch = ["active": true, "completed": 22, "total": 155, "saved": 17, "skipped": 2, "failed": 1, "not_found": 2]
            LyricsFixtureBridge.changed(); self.checkActive(page)
            let detail = page.value(forKey: "progressDetail") as! UILabel
            precondition(detail.text == "Saved 17 · already saved 2 · failed 1 · not found 2")
            let bar = page.value(forKey: "progressBar") as! UIProgressView
            precondition(abs(bar.progress-22.0/155)<0.001)
            self.capture("lyrics-download")
            LyricsFixtureBridge.batch = [:]; LyricsFixtureBridge.changed()
            precondition(page.tableView.tableHeaderView == nil, "finished lyrics retained a progress panel")
            self.capture("lyrics-finished")
            LyricsFixtureBridge.batch = ["active": true, "kind": "refresh", "completed": 83, "total": 155, "saved": 80, "skipped": 2, "failed": 1]
            LyricsFixtureBridge.changed()
            nav.popViewController(animated: false)
            let reopened = SAPCreateLyricsSettings() as! UITableViewController
            nav.pushViewController(reopened, animated: false)
            DispatchQueue.main.asyncAfter(deadline: .now()+0.4) {
                self.checkActive(reopened)
                let title = reopened.value(forKey: "progressTitle") as! UILabel
                precondition(title.text?.contains("83 / 155") == true, "reopening reset progress")
                precondition(title.text?.hasPrefix("Updating lyrics") == true, "automatic refresh did not use its own title")
                let bar = reopened.value(forKey: "progressBar") as! UIProgressView
                precondition(abs(bar.progress-83.0/155)<0.001)
                self.capture("lyrics-reopened")
                let cancel = reopened.value(forKey: "progressAction") as! UIButton
                cancel.sendActions(for: .touchUpInside)
                precondition(LyricsFixtureBridge.cancels == 1 && reopened.tableView.tableHeaderView == nil, "Cancel did not stop and hide lyrics progress")
                self.write("PASS: lyrics header, sole Cancel action, scan/download transition, completion dismissal and reopen progress")
            }
        }
    }
    func checkActive(_ page: UITableViewController) {
        page.view.layoutIfNeeded()
        guard let header = page.tableView.tableHeaderView else { preconditionFailure("active lyrics missing top panel") }
        precondition(page.tableView.numberOfRows(inSection: 0) == 2, "separate Stop row remains")
        let views = descendants(header)
        let buttons = views.compactMap { $0 as? UIButton }
        precondition(buttons.count == 1 && buttons[0].title(for: .normal) == "Cancel", "lyrics panel has Done/Share or no Cancel")
        precondition(!header.hasAmbiguousLayout)
        let panel = page.value(forKey: "progressPanel") as! UIView
        let title = page.value(forKey: "progressTitle") as! UILabel
        let detail = page.value(forKey: "progressDetail") as! UILabel
        precondition(panel.layer.cornerRadius == 24 && title.numberOfLines == 1)
        precondition(detail.numberOfLines == 1, "lyrics progress counts wrapped")
        let minimumFont = detail.font.withSize(detail.font.pointSize * detail.minimumScaleFactor)
        let minimumWidth = (detail.text ?? "").size(withAttributes: [.font: minimumFont]).width
        precondition(detail.bounds.width >= ceil(minimumWidth), "lyrics progress counts were clipped")
        precondition(title.frame.maxX <= buttons[0].frame.minX-11 && detail.frame.maxY < panel.bounds.maxY)
    }
    func descendants(_ view: UIView) -> [UIView] { [view]+view.subviews.flatMap(descendants) }
    func capture(_ name: String) {
        guard let window else { return }
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        try? image.pngData()?.write(to: documents.appendingPathComponent(name+".png"))
    }
    var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    func write(_ text: String) { try? text.write(to: documents.appendingPathComponent("result.log"), atomically: true, encoding: .utf8) }
}
