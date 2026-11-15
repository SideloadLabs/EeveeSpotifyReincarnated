import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError("FAIL: \(message)") }
}

private func repoRootURL() -> URL {
    var directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    while true {
        let candidate = directory.appendingPathComponent("Sources/EeveeSpotify")
        if FileManager.default.fileExists(atPath: candidate.path) {
            return directory
        }
        let parent = directory.deletingLastPathComponent()
        if parent.path == directory.path { break }
        directory = parent
    }
    fatalError("FAIL: could not locate Sources/EeveeSpotify from current directory")
}

private func readSource(_ relativePath: String) -> String {
    let url = repoRootURL().appendingPathComponent(relativePath)
    guard let text = try? String(contentsOf: url, encoding: .utf8) else {
        fatalError("FAIL: could not read \(relativePath)")
    }
    return text
}

private func allSwiftFiles() -> [URL] {
    let sourcesRoot = repoRootURL().appendingPathComponent("Sources/EeveeSpotify")
    guard let enumerator = FileManager.default.enumerator(
        at: sourcesRoot,
        includingPropertiesForKeys: nil
    ) else {
        fatalError("FAIL: could not enumerate \(sourcesRoot.path)")
    }
    var files: [URL] = []
    for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
        files.append(fileURL)
    }
    return files.sorted { $0.path < $1.path }
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

private func classHookNames(in source: String) -> [String] {
    let pattern = try! NSRegularExpression(pattern: #"class\s+([A-Za-z0-9_]+)\s*:\s*ClassHook<"#)
    let nsRange = NSRange(source.startIndex..<source.endIndex, in: source)
    return pattern.matches(in: source, range: nsRange).compactMap { match in
        guard let range = Range(match.range(at: 1), in: source) else { return nil }
        return String(source[range])
    }
}

private func checkUnifiedAdURLPredicates() {
    let adBlockerSource = readSource("Sources/EeveeSpotify/EeveeAdBlockerExtended.x.swift")
    let sessionSource = readSource("Sources/EeveeSpotify/SessionProtection.x.swift")

    let coreAdsBody = body(in: adBlockerSource, after: "class CoreURLSessionAdsKill")
    require(coreAdsBody.contains("url.isAdRelated"),
            "CoreURLSessionAdsKill must use url.isAdRelated")
    require(!adBlockerSource.contains("isCoreAdRequest"),
            "EeveeAdBlockerExtended.x.swift must not define a separate isCoreAdRequest predicate")

    let resumeHookBody = body(in: sessionSource, after: "class URLSessionTaskResumeHook")
    require(resumeHookBody.contains("url.isAdRelated"),
            "URLSessionTaskResumeHook must use url.isAdRelated")
    require(resumeHookBody.contains("[ORACLE][NET_BLOCK]"),
            "URLSessionTaskResumeHook must log [ORACLE][NET_BLOCK] when cancelling ad requests")

    for fileURL in allSwiftFiles() {
        let contents = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        require(!contents.contains("func isCoreAdRequest"),
                "split ad-URL predicate isCoreAdRequest found in \(fileURL.lastPathComponent)")
    }
}

private func checkPremiumForceFlags() {
    let premiumForceSource = readSource("Sources/EeveeSpotify/EeveePremiumForce.x.swift")
    require(premiumForceSource.contains("enableAdsHook = true"),
            "EeveePremiumForce.x.swift must have enableAdsHook = true")
    require(premiumForceSource.contains("enableDirectGetters = true"),
            "EeveePremiumForce.x.swift must have enableDirectGetters = true")
    require(!premiumForceSource.contains("enableAdsHook = false"),
            "EeveePremiumForce.x.swift must not leave enableAdsHook = false")
    require(!premiumForceSource.contains("enableDirectGetters = false"),
            "EeveePremiumForce.x.swift must not leave enableDirectGetters = false")

    let requiredCoreAdKeys = [
        "ads",
        "audio-ad-frequency",
        "video-ad-frequency",
        "ad-formats",
        "player-license",
        "player-license-v2",
        "type",
        "product",
        "catalogue",
    ]
    for key in requiredCoreAdKeys {
        require(premiumForceSource.contains("\"\(key)\""),
                "EeveePremiumForce.x.swift must include core ad entitlement key \"\(key)\"")
    }
}

private func checkHookActivationRegistration() {
    let auditedFiles: [(String, String)] = [
        ("Sources/EeveeSpotify/EeveeAdBlockerExtended.x.swift", "func activateEeveeAdBlockerExtended()"),
        ("Sources/EeveeSpotify/UpsellServiceBlocker.x.swift", "func activateUpsellServiceBlocker()"),
        ("Sources/EeveeSpotify/ClientMessagingPlatformBlocker.x.swift", "func activateClientMessagingPlatformBlocker()"),
        ("Sources/EeveeSpotify/UpsellPopupBlocker.x.swift", "func activateUpsellPopupBlocker()"),
    ]

    for (relativePath, activateDecl) in auditedFiles {
        let source = readSource(relativePath)
        let hooks = classHookNames(in: source)
        require(!hooks.isEmpty, "expected at least one ClassHook in \(relativePath)")

        let activateBody = body(in: source, after: activateDecl)
        for hook in hooks {
            require(activateBody.contains("\(hook).targetName"),
                    "\(hook) in \(relativePath) is missing from \(activateDecl) registration")
        }
    }

    let adBlockerSource = readSource("Sources/EeveeSpotify/EeveeAdBlockerExtended.x.swift")
    let required9188AdServices = [
        "_TtC36AdsPlatform_RealTimeAdControllerImpl31RealTimeAdControllerServiceImpl",
        "_TtC28AdsPlatform_AdsBaseSwiftImpl23AdsBaseSwiftServiceImpl",
        "_TtC46Betamax_AudioAdPictureInPictureCoordinatorImpl41AudioAdPictureInPictureCoordinatorService",
        "_TtC34AdsPlatform_AdsInstrumentationImpl29AdsInstrumentationServiceImpl",
        "_TtC23AdsPlatform_ElementImpl18ElementServiceImpl",
        "_TtC28AdsStandalone_RewardedAdImpl32RewardedAdFetchControllerService",
        "_TtC29AdsStandalone_AdOnAppOpenImpl22AdOnAppOpenServiceImpl",
        "_TtC32AdsEmbedded_EmbeddedCTACardsImpl23EmbeddedCTACardsService",
        "_TtC32AdsEmbedded_EmbeddedPlaylistImpl27EmbeddedPlaylistServiceImpl",
        "_TtC21NativeAds_ElementImpl27NativeAdsElementServiceImpl",
        "_TtC28AdsStandalone_RewardedAdImpl28OnDemandAdEventLoggerService",
    ]
    for service in required9188AdServices {
        require(adBlockerSource.contains("\"\(service)\""),
                "EeveeAdBlockerExtended.x.swift must hook 9.1.88 ad service \(service)")
    }

    let required920AdServices = [
        "_TtC23AdsPlatform_AdsBaseImpl18AdsBaseServiceImpl",
    ]
    for service in required920AdServices {
        require(adBlockerSource.contains("\"\(service)\""),
                "EeveeAdBlockerExtended.x.swift must hook 9.2.0 ad service \(service)")
    }

    let upsellBlockerSource = readSource("Sources/EeveeSpotify/UpsellServiceBlocker.x.swift")
    let requiredUpsellServices = [
        "_TtC28ContextualShuffle_UpsellImpl40ShuffleToggleUpsellServiceImplementation",
        "_TtC35ReinventFree_PlayFullSongUpsellImpl29PlayFullSongUpsellServiceImpl",
    ]
    for service in requiredUpsellServices {
        require(upsellBlockerSource.contains("\"\(service)\""),
                "UpsellServiceBlocker.x.swift must hook upsell service \(service)")
    }
}

private func checkOracleTelemetryAndCohortSweep() {
    let premiumForceSource = readSource("Sources/EeveeSpotify/EeveePremiumForce.x.swift")
    require(premiumForceSource.contains("[ORACLE][ENTITLEMENT_DRIFT]"),
            "EeveePremiumForce.x.swift must log [ORACLE][ENTITLEMENT_DRIFT] when ads=1")

    let karaokeSource = readSource("Sources/EeveeSpotify/Karaoke/KaraokePlaybackTracker.swift")
    require(karaokeSource.contains("[ORACLE][AD_LEAK]"),
            "KaraokePlaybackTracker.swift must log [ORACLE][AD_LEAK] when an ad track plays")

    let dynamicPremiumSource = readSource("Sources/EeveeSpotify/Premium/DynamicPremium+ModifyingFunctions.swift")
    require(dynamicPremiumSource.contains("func isCohortAdOrUpsellFlag(scope: String, name: String) -> Bool"),
            "DynamicPremium+ModifyingFunctions.swift must define isCohortAdOrUpsellFlag")
    require(dynamicPremiumSource.contains("[ORACLE][COHORT_FLAG_KILLED]"),
            "DynamicPremium+ModifyingFunctions.swift must log [ORACLE][COHORT_FLAG_KILLED]")
}

checkUnifiedAdURLPredicates()
checkPremiumForceFlags()
checkHookActivationRegistration()
checkOracleTelemetryAndCohortSweep()
print("Hook source audit regression tests passed")
