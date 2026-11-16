import Foundation

// GlassTabBar.x.swift is an Orion hook, so its cold-launch wiring is checked at the
// source level instead of importing the tweak. The bug this guards against: sync()
// returned early when Spotify had not laid its tab row out yet, leaving the glass bar
// hidden until some later layout pass (historically, switching apps and back).
private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError("FAIL: \(message)") }
}

private func glassTabBarSource() -> String {
    var directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let relative = "Sources/EeveeSpotify/LiquidGlass/GlassTabBar.x.swift"
    while true {
        let candidate = directory.appendingPathComponent(relative)
        if FileManager.default.fileExists(atPath: candidate.path),
           let text = try? String(contentsOf: candidate, encoding: .utf8) {
            return text
        }
        let parent = directory.deletingLastPathComponent()
        if parent.path == directory.path { break }
        directory = parent
    }
    fatalError("FAIL: could not read \(relative)")
}

private func braceBody(in text: String, opening open: String.Index) -> String {
    var depth = 0
    var index = open
    while index < text.endIndex {
        let character = text[index]
        if character == "{" { depth += 1 }
        if character == "}" {
            depth -= 1
            if depth == 0 { return String(text[open...index]) }
        }
        index = text.index(after: index)
    }
    fatalError("FAIL: unmatched brace")
}

private func body(in text: String, after marker: String) -> String {
    guard let markerRange = text.range(of: marker) else {
        fatalError("FAIL: \(marker) not found")
    }
    guard let open = text[markerRange.upperBound...].firstIndex(of: "{") else {
        fatalError("FAIL: \(marker) has no body")
    }
    return braceBody(in: text, opening: open)
}

private func checkColdLaunchWaitsForTabs() {
    let source = glassTabBarSource()
    let sync = body(in: source, after: "static func sync(_ stock: UIView)")

    let rowGuard = body(in: sync, after: "guard let row = tabRow(in: stock) else")
    require(rowGuard.contains("waitForTabs(stock)"),
            "a missing tab row must arm a retry instead of leaving the glass bar hidden")

    let tabsGuard = body(in: sync, after: "guard !tabs.isEmpty else")
    require(tabsGuard.contains("waitForTabs(stock)"),
            "an empty tab row must arm a retry instead of leaving the glass bar hidden")

    let wait = body(in: source, after: "private static func waitForTabs(_ stock: UIView)")
    require(wait.contains("bar.isHidden"),
            "retries must stop once the glass bar is visible")
    require(wait.contains("waitRetries <"),
            "retries must be bounded so a missing stock bar cannot poll forever")
}

private func checkForegroundResync() {
    let source = glassTabBarSource()

    let observer = body(in: source, after: ".didBecomeActiveNotification")
    require(observer.contains("sync(stock)"),
            "becoming active must resync the glass bar")
    require(observer.contains("rebuild(bar)"),
            "a bar revealed before the scene was active must be rebuilt when the app activates")

    let reveal = body(in: source, after: "private static func reveal(")
    require(reveal.contains("activationState != .foregroundActive")
            && reveal.contains("revealedWhileInactive = true"),
            "reveal must remember that it ran before the scene was active")
    require(!reveal.contains("guard bar.isHidden else { return }"),
            "a repeat reveal must not skip the activation bookkeeping")
}

checkColdLaunchWaitsForTabs()
checkForegroundResync()
print("Glass tab bar launch regression tests passed")
