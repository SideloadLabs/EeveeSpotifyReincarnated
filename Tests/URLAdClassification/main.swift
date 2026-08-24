import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError("FAIL: \(message)") }
}

private func url(_ value: String) -> URL {
    URL(string: value)!
}

require(url("https://spclient.wg.spotify.com/premium-upsell/banner").isAdRelated,
        "Premium upsell banner endpoint must be blocked")
require(url("https://spclient.wg.spotify.com/referrals/upsell/card").isAdRelated,
        "referral upsell card endpoint must be blocked")
require(url("https://spclient.wg.spotify.com/leavebehind").isAdRelated,
        "leave-behind endpoint without a trailing slash must be blocked")
require(url("https://doubleclick.net/v1/content").isAdRelated,
        "known ad hosts must be blocked")
require(!url("https://spclient.wg.spotify.com/collection/v1/library/items").isAdRelated,
        "ordinary library endpoint must not be blocked")

print("URL ad classification regression tests passed")
