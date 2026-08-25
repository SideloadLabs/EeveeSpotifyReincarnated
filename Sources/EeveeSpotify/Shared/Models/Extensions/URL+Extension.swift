import Foundation

extension URL {
    var isLyrics: Bool {
        self.path.contains("color-lyrics/v2")
    }
    
    var isPlanOverview: Bool {
        self.path.contains("GetPlanOverview")
    }
    
    var isShuffle: Bool {
        self.path.contains("shuffle")
    }
    
    var isPremiumPlanRow: Bool {
        self.path.contains("v1/GetPremiumPlanRow")
    }
    
    var isPremiumBadge: Bool {
        self.path.contains("GetYourPremiumBadge")
    }

    var isOpenSpotifySafariExtension: Bool {
        self.host == "eevee"
    }
    
    var isCustomize: Bool {
        self.path.contains("v1/customize")
    }
    
    var isBootstrap: Bool {
        self.path.contains("v1/bootstrap")
    }

    // Blocked endpoint matchers (session protection)

    var isDeleteToken: Bool {
        self.path.contains("DeleteToken")
    }

    var isAccountValidate: Bool {
        self.path.contains("signup/public")
    }

    var isOndemandSelector: Bool {
        self.path.contains("select-ondemand-set")
    }

    var isTrialsFacade: Bool {
        self.path.contains("trials-facade/start-trial")
    }

    var isPremiumMarketing: Bool {
        self.path.contains("premium-marketing/upsellOffer")
    }

    var isPendragonFetchMessageList: Bool {
        self.path.contains("pendragon") && self.path.contains("FetchMessageList")
    }

    var isPushkaTokens: Bool {
        self.path.contains("pushka-tokens")
    }
    
    var isAdRelated: Bool {
        let path = self.path.lowercased()
        let host = (self.host ?? "").lowercased()
        
        // Block the "Ad on App Open" home-screen banner (Pepsi, etc.)
        if path.contains("/ad-on-app-open") || path.contains("/ads/ad-on-app-open") {
            return true
        }
        
        // Block all other spclient /ads/* endpoints
        if path.contains("/ads/") {
            return true
        }
        
        // Block ad-logic (Marquee, in-stream ads)
        if path.contains("/ad-logic/") {
            return true
        }
        
        // Block DAC (Display Ad Container) — delivers search-page and home-page display ads
        // (Cartier on Search, Ross on Home as shown in the screenshots)
        if path.contains("/dac/view/v1/") {
            return true
        }
        
        // Block Esperanto ad slot service (in-stream and overlay ads)
        if path.contains("/esperanto/") && (path.contains("ad") || path.contains("slot")) {
            return true
        }
        
        // Block other known ad paths
        if path.contains("/ad-slot/") ||
           path.contains("/ad-inventory/") ||
           path.contains("/ad-on-app-open") ||
           path.contains("/sponsored/") ||
           path.contains("/promoted/") ||
           path.contains("/upsell/") ||
           path.contains("/premium-upsell") ||
           path.contains("/upsell-banner") ||
           path.contains("/upsell-card") ||
           path.contains("/referrals/upsell") ||
           path.contains("/campaign/") ||
           path.contains("/billboard/") ||
           path.contains("/banner/") ||
           path.contains("/interstitial/") ||
           path.contains("/overlay/") ||
           path.contains("/popup/") ||
           path.contains("/pop-up/") ||
           path.contains("/search-ad/") ||
           path.contains("/home-ad/") ||
           path.contains("/marquee/") ||
           path.contains("/leavebehind") ||
           path.contains("/leave-behind") ||
           path.contains("/display-ad/") ||
           path.contains("/fullbleed/") ||
           path.contains("/leaderboard/") ||
           path.contains("/ad-card/") ||
           path.contains("/sponsored-content/") ||
           path.contains("/sponsored-ad/") ||
           path.contains("/native-ad/") ||
           path.contains("/sponsored-shelf/") ||
           path.contains("/sponsored-row/") ||
           path.contains("/ad-shelf/") ||
           path.contains("/ad-row/") ||
           path.contains("/sponsored-item/") ||
           path.contains("/ad-item/") ||
           path.contains("/merchandising/") ||
           path.contains("/upgrade-component/") ||
           path.contains("/marketing/") ||
           path.contains("/home-ads/") ||
           path.contains("/search-ads/") {
            return true
        }
        
        // Block known ad hostnames
        if host.contains("doubleclick") ||
           host.contains("googlesyndication") ||
           host == "ad.spotify.com" ||
           host == "ads.spotify.com" ||
           host == "aet.spotify.com" ||
           host.hasPrefix("aet.") {
            return true
        }
        
        return false
    }

    // Additional session protection endpoints
    var isSessionInvalidation: Bool {
        self.path.contains("logout") || self.path.contains("sign-out") ||
        self.path.contains("session/purge") || self.path.contains("token/revoke") ||
        self.path.contains("auth/expire") ||
        (self.path.contains("melody") && self.path.contains("check")) ||
        self.path.contains("product-state") ||
        (self.path.contains("license") && self.path.contains("check"))
    }
}
