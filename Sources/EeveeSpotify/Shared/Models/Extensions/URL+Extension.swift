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
        // 9.1.x 的 UCS 路径（`spclient.wg.spotify.com/user-customization-service/v1/customize`）。
        // 9.2.0 的包里搜不到 `user-customization-service`，也搜不到 `UcsResponse` / `UcsRequest`：
        // 那条 customize 传输在 9.2.0 上不存在，所以这个判据在 9.2.0 上不命中。
        // ⚠️ 别顺手把 resolver 的 `.../configuration` 塞进来 —— 回放与改写用的都是
        // `CustomizeMessage` 的字节，喂给别的传输只会让 App 解析失败（配置空 = 歌单灰）。
        self.path.contains("v1/customize")
    }
    
    var isBootstrap: Bool {
        // 9.1.x 的 bootstrap 路径。9.2.0 里 `BootstrapResponse` 这个类型名也没了，
        // 就算命中，报文也可能解不开 —— 解不开就原样放行，见
        // `DynamicPremium+ModifyBootstrap` 的 catch 分支。
        self.path.contains("v1/bootstrap")
    }

    /// 9.2.0：登录态的功能分配表（一份裸的 `ResolveResponse`）。
    /// `unauth` 那条是未登录时的 bootstrap，别碰。
    var isRemoteConfiguration: Bool {
        self.path.contains("remote-config-resolver")
            && self.path.contains("configuration")
            && !self.path.contains("unauth")
    }

    /// 9.2.0：账号态（`type` / `catalogue` / `ads` / `on-demand` …）。
    /// 9.1.x 把它塞在 UCS 响应里，9.2.0 拆成了独立的一条。
    var isAccountAttributes: Bool {
        self.path.contains("nebula/v1/configuration/attributes")
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
        // 9.1.84 起 ClientMessagingPlatform 把 RPC 从 `FetchMessageList` 改成了
        // `FetchMessage` / `FetchMessageForPreview`（`com.spotify.pendragon.v1.ClientMessageService`）。
        // `FetchMessage` 是这三个名字的公共前缀 ⇒ 一条判断覆盖全部已知变体。
        // 只写 `FetchMessageList` 的话，新版本上一条都匹配不到，win-back 全屏广告会漏。
        self.path.contains("pendragon") && self.path.contains("FetchMessage")
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
        
        // Block all other spclient /ads/* endpoints（含只有 `/ads` 结尾的那种）。
        if path.contains("/ads/") || path.hasSuffix("/ads") {
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
