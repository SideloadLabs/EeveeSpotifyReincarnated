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

print("BrowsitaSectionStripper regression tests passed")
