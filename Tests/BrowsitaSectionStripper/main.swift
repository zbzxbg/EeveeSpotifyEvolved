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

// ── 2026-10-13：`aet.spotify.com`（上游实测的滚动页广告段唯一可靠 wire 标记）──
//
// 背景：滚动页广告段的 "Advertisement" 标签是客户端画的，wire 上不出现
// `sponsored` / `advertisement` 字样，所以这里必须靠广告事件追踪域名命中。
let adTrackingURL = message(["ordinary section", "https://aet.spotify.com/event/viewability"])
require(BrowsitaSectionStripper.strip(adTrackingURL, url: scrollURL) != nil,
        "ad-event tracking host must be removed (the label itself is client-side)")

let adSlashURL = message(["ordinary section", "open.spotify.com/ad/1234"])
require(BrowsitaSectionStripper.strip(adSlashURL, url: scrollURL) != nil,
        "open.spotify.com/ad/ links must be removed")

let adTrackingWithKeepWord = message(["filter metadata", "https://aet.spotify.com/clicked"])
require(BrowsitaSectionStripper.strip(adTrackingWithKeepWord, url: scrollURL) != nil,
        "the ad-tracking host must win over generic keep markers")

// 反向守卫：新标记不许变成"见 aet 就删" —— 普通单词里也有这三个字母。
let notAnAdHost = message(["ordinary section", "palette of colors", "aet"])
require(BrowsitaSectionStripper.strip(notAnAdHost, url: scrollURL) == nil,
        "the bare substring 'aet' must not drop a section — only the full host does")

print("BrowsitaSectionStripper regression tests passed")
