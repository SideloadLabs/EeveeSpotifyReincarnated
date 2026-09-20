import Foundation

func writeDebugLog(_ message: String) {}

private func varint(_ input: Int) -> Data {
    var value = input
    var result = Data()
    while value >= 0x80 {
        result.append(UInt8((value & 0x7f) | 0x80))
        value >>= 7
    }
    result.append(UInt8(value))
    return result
}

private func message(_ sections: [String]) -> Data {
    var container = Data()
    for section in sections {
        let bytes = Data(section.utf8)
        container.append(0x0a)
        container.append(varint(bytes.count))
        container.append(bytes)
    }

    var result = Data([0x0a])
    result.append(varint(container.count))
    result.append(container)
    return result
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fatalError("FAIL: \(message)")
    }
}

private let scrollURL = URL(string: "https://spclient.wg.spotify.com/scrollsita/v1/home")!
private let feedsURL = URL(string: "https://spclient.wg.spotify.com/casita/v1/feeds")!

require(BrowsitaSectionStripper.shouldHandle(scrollURL), "scrollsita must be inspected")
require(!BrowsitaSectionStripper.shouldHandle(feedsURL), "casita feeds must stay excluded")

let normal = message(["editorial-card", "upsell eligibility telemetry"])
require(BrowsitaSectionStripper.strip(normal, url: scrollURL) == nil,
        "generic upsell telemetry must not remove ordinary content")

let premiumBanner = message(["editorial-card", "UPSELL-BANNER premium offer"])
let premiumResult = BrowsitaSectionStripper.strip(premiumBanner, url: scrollURL)
require(premiumResult != nil && premiumResult!.count < premiumBanner.count,
        "localized-independent Premium banner marker must be removed")

let promotionalBanner = message(["ordinary section", "audiobook promotional-banner"])
require(BrowsitaSectionStripper.strip(promotionalBanner, url: scrollURL) != nil,
        "promotional banner marker must be removed")

let sponsoredWithKeepWord = message(["filter metadata sponsored display-ad"])
require(BrowsitaSectionStripper.strip(sponsoredWithKeepWord, url: scrollURL) != nil,
        "hard ad markers must win over generic keep markers")

let mixed = message(["ordinary section", "leaveBehind ad card", "another section"])
let mixedResult = BrowsitaSectionStripper.strip(mixed, url: scrollURL)
require(mixedResult != nil && mixedResult!.count < mixed.count,
        "leave-behind section must be removed case-insensitively")

// MARK: - Surgical wire walker (scrollsita NpvScrollResponse shapes)

private func lenDelimited(_ fieldNumber: Int, _ payload: Data) -> Data {
    var out = Data()
    out.append(varint((fieldNumber << 3) | 2))
    out.append(varint(payload.count))
    out.append(payload)
    return out
}

private func text(_ s: String) -> Data { Data(s.utf8) }

// 1) Repeated siblings (like scrollsita sections): only ad members are cut,
//    legit siblings' bytes are preserved verbatim.
let legitA = text("official merch store header")
let legitB = text("up next queue section")
let adA = text("montblanc legend elixir spotify:ad:montblanc tracking")
let adB = text("ADVERTISEMENT brand-ad spotify:ad:2")
let repeatedMembers = lenDelimited(1, legitA) + lenDelimited(1, adA)
    + lenDelimited(1, legitB) + lenDelimited(1, adB)
let repeatedResult = BrowsitaSectionStripper.strip(repeatedMembers, url: scrollURL)
require(repeatedResult == lenDelimited(1, legitA) + lenDelimited(1, legitB),
        "surgical walker must drop exactly the repeated ad members")

// 2) Singleton carrier: repeated ad group nested inside a singleton field.
let carrier = lenDelimited(1,
    lenDelimited(3, legitA) + lenDelimited(3, adA) + lenDelimited(3, legitB))
let carrierResult = BrowsitaSectionStripper.strip(carrier, url: scrollURL)
require(carrierResult == lenDelimited(1, lenDelimited(3, legitA) + lenDelimited(3, legitB)),
        "surgical walker must recurse into singleton carriers")

// 3) Ad-free payload passes through untouched.
let cleanPayload = lenDelimited(1, legitA) + lenDelimited(1, legitB)
require(BrowsitaSectionStripper.strip(cleanPayload, url: scrollURL) == nil,
        "surgical walker must not touch ad-free payloads")

// 4) Malformed bytes pass through untouched (no mis-slicing).
let garbage = Data([0x0a, 0xff, 0xff, 0xff]) // truncated varint length
require(BrowsitaSectionStripper.strip(garbage, url: scrollURL) == nil,
        "unparsable payload must pass through unmodified")

// 5) Real 9.1.84 shape (build-4 probe): sections repeat at the top level and
//    the ad section buries aet.spotify.com tracking deep inside nested
//    singletons alongside its display data — the "Advertisement" label is
//    rendered client-side and never appears on the wire. The whole section
//    must be dropped; the clean section's bytes must survive verbatim.
private func trackingEntry(_ event: String) -> Data {
    lenDelimited(4, text(event + " https://aet.spotify.com/v2/t?p=AAAB"))
}
let adSectionReal = lenDelimited(2,
    lenDelimited(1, text("spotify:section:0JQ5DBfI0TKgSZq9aKzJl0"))
    + lenDelimited(3, lenDelimited(7, text("uDiscover Hong Kong"))
        + trackingEntry("viewability") + trackingEntry("clicked")))
let aboutSectionReal = lenDelimited(2, lenDelimited(1, text("About the artist")))
let trackRefReal = lenDelimited(1, text("spotify:track:0ct6r3EGTcMLPtrXHDvVjc"))
let realShape = trackRefReal + aboutSectionReal + adSectionReal
let realResult = BrowsitaSectionStripper.strip(realShape, url: scrollURL)
require(realResult == trackRefReal + aboutSectionReal,
        "ad section with deeply nested aet tracking must be dropped whole")

print("BrowsitaSectionStripper regression tests passed")
