import Foundation

// GlassTabBar.x.swift is an Orion hook, so the lifecycle below is applied to that
// file's activation wiring instead of importing the tweak.
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

private struct Session {
    var available = false
    var hooks = 0
    var refreshedWhileAvailable = false
    let armsOnOptionsChange: Bool
    let activatesBeforeRefresh: Bool
    let returnsOnceAvailable: Bool
    let skipsEmptyList: Bool

    mutating func launch(customTabs: Int) {
        consider(customTabs: customTabs)
    }

    mutating func optionsChanged(customTabs: Int) {
        guard armsOnOptionsChange else { return }
        if activatesBeforeRefresh {
            consider(customTabs: customTabs)
            if available { refreshedWhileAvailable = true }
        } else {
            consider(customTabs: customTabs)
        }
    }

    mutating func consider(customTabs: Int) {
        if available && returnsOnceAvailable { return }
        if skipsEmptyList && customTabs == 0 { return }
        hooks += 1
        available = true
    }
}

private func checkZeroTabsThenAddLater() {
    let source = glassTabBarSource()
    let observer = body(in: source, after: ".eeveeTabBarOptionsChanged")
    let activate = body(in: source, after: "func activateGlassCustomTabs()")
    let hook = activate.range(of: "CustomTabsGroup().activate()")
    let head = hook.map { String(activate[..<$0.lowerBound]) } ?? ""
    let activateCall = observer.range(of: "activateGlassCustomTabs()")
    let syncCall = observer.range(of: "sync(")

    var session = Session(
        armsOnOptionsChange: activateCall != nil,
        activatesBeforeRefresh: activateCall != nil && syncCall != nil && activateCall!.upperBound <= syncCall!.lowerBound,
        returnsOnceAvailable: head.contains("!CustomTabs.available"),
        skipsEmptyList: activate.contains("count > 0")
    )

    session.launch(customTabs: 0)
    require(!session.available && session.hooks == 0,
            "zero custom tabs at launch must leave the link dispatcher inactive")

    session.optionsChanged(customTabs: 1)
    require(session.available && session.hooks == 1,
            "adding a tab while Spotify is running must activate the link dispatcher")
    require(session.refreshedWhileAvailable,
            "the tab bar must refresh after activation so the new tab can open")

    session.optionsChanged(customTabs: 2)
    require(session.hooks == 1 && session.available,
            "editing the tab list again must not activate the dispatcher twice")
}

checkZeroTabsThenAddLater()
print("Custom tabs activation regression tests passed")
