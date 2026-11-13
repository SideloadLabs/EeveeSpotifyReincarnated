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

// Player-core ad URLs routed through SPTCoreURLSessionDataDelegate / NSURLSessionTask
require(url("https://spclient.wg.spotify.com/ads/v3/ads").isAdRelated,
        "player-core /ads/v3/ads endpoint must be blocked")
require(url("https://spclient.wg.spotify.com/ad-logic/prefetch").isAdRelated,
        "player-core /ad-logic/prefetch endpoint must be blocked")
require(url("https://spclient.wg.spotify.com/ad-logic/v3/config").isAdRelated,
        "player-core /ad-logic/v3/config endpoint must be blocked")
require(url("https://spclient.wg.spotify.com/esperanto/spotify.ads.esperanto.proto.InStream/Slot").isAdRelated,
        "Esperanto InStream/Slot endpoint must be blocked")
require(url("https://spclient.wg.spotify.com/esperanto/spotify.ads.esperanto.proto.Ads/GetSlot").isAdRelated,
        "Esperanto spotify.ads endpoint must be blocked")
require(url("https://aet.spotify.com/v2/t").isAdRelated,
        "aet.spotify.com/v2/t ad telemetry endpoint must be blocked")
require(url("https://aet.spotify.com/v1/events").isAdRelated,
        "aet.spotify.com ad telemetry host must be blocked")

// ClientMessagingPlatform message fetches (9.1.84 win-back fullscreen, Home
// Premium banner). The RPC set was renamed from FetchMessageList to
// FetchMessage / FetchMessageForPreview; all must stay blocked.
require(url("https://spclient.wg.spotify.com/pendragon/v1/FetchMessageList").isPendragonFetchMessageList,
        "legacy pendragon FetchMessageList must be blocked")
require(url("https://spclient.wg.spotify.com/pendragon/v1/FetchMessage").isPendragonFetchMessageList,
        "9.1.84 pendragon FetchMessage must be blocked")
require(url("https://spclient.wg.spotify.com/pendragon/v1/FetchMessageForPreview").isPendragonFetchMessageList,
        "pendragon FetchMessageForPreview must be blocked")
require(!url("https://spclient.wg.spotify.com/pendragon/v1/AcknowledgeMessage").isPendragonFetchMessageList,
        "non-fetch pendragon RPCs must not be blocked")
require(!url("https://spclient.wg.spotify.com/decipher/agent/v1/FetchMessage").isPendragonFetchMessageList,
        "non-pendragon FetchMessage paths must not be blocked")

print("URL ad classification regression tests passed")
