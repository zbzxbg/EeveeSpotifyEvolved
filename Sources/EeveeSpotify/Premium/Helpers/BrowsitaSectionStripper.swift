import Foundation

// Strips ad and upsell sections from home/browse/Now Playing feed protobufs.

enum BrowsitaSectionStripper {

    private static let hardAdMarkers: [[UInt8]] = [
        "spotify:ad:", "ad-formats", "advertisement", "brand-ad",
        "sponsored", "marquee", "promoted", "home-ads", "adsproduct",
        "leavebehind", "leave-behind", "premium-upsell", "premium_upsell",
        "premiumupsell", "referralsupsellcard",
        // ★ 2026-10-13：从上游补的两条（`aet` = Spotify 的广告事件追踪域名）。
        //
        // 为什么需要它：滚动页（scrollsita）的广告段里，"Advertisement" 那个标签是
        // **客户端画**的，wire 上不会出现 `sponsored`/`advertisement` 这类字样 ⇒ 上面
        // 那串标记一条都命中不了，整段原样放行。上游在 9.1.84 上实测过一条真广告段：
        // 每个事件带约 20 条 `aet.spotify.com` 追踪 URL（viewability / clicked /
        // quartiles）；而正常内容的段**从不**带广告追踪 URL，所以这个 host 是那类
        // 载荷唯一可靠的 wire 标记。
        //
        // 我们这边的旁证（`C:\dsh\readlog` 2026-09-30 ~ 10-05 的 80 份真机日志）：
        // 385 条 `[STRIP] KEEP /scrollsita/...`、`dropped=` 一条都没有、`bail` 零命中
        // ⇒ 容器解析本身没问题，是**标记表**没命中；其中日志 49 那条 25881B 响应里
        // 还夹着一个 24279B 的元素被原样放行（形状与上游描述的广告段吻合）。
        //
        // ⚠️ 代价：这两条是**硬标记**，命中即整段丢弃（`keepMarkers` 也压不住）。
        // 若真机上发现误删，先看那行 `[STRIP] DROP ... hits=` 的日志，再删掉本行即可。
        "aet.spotify.com", "open.spotify.com/ad/",
    ].map { Array($0.utf8) }

    // Generic "upsell" metadata is not enough to delete a whole section. It
    // must describe a visible promotional surface too.
    private static let promotionalIntentMarkers: [[UInt8]] = [
        "upsell", "upgrade", "subscribe", "premium", "promo", "promotion",
        "marketing", "offer",
    ].map { Array($0.utf8) }

    private static let promotionalSurfaceMarkers: [[UInt8]] = [
        "banner", "card", "popup", "pop-up", "sheet", "interstitial",
        "promotion", "promo",
    ].map { Array($0.utf8) }

    private static let keepMarkers: [[UInt8]] = [
        "filter", "chip", "pillar", "browse:chips",
    ].map { Array($0.utf8) }

    static var verboseLog: Bool = false

    /// 这一条 URL 要不要打详细日志。
    ///
    /// ⚠️ 与 `verboseLog` 的区别：browsita/casita 的 section 数量很大，全局打开会把日志刷爆；
    /// 而排查"正在播放页多出一张预热卡"恰恰需要知道 stripper 对 **scrollsita 的每个元素**
    /// 是 KEEP 还是 DROP。所以规则是"全局开关 **或** 这条 URL 是 scrollsita"。
    private static func isVerbose(_ path: String) -> Bool {
        verboseLog || path.lowercased().contains("/scrollsita/")
    }

    static func shouldHandle(_ url: URL) -> Bool {
        let p = url.path.lowercased()
        // /casita/v1/feeds is flat tab-chip list, parser would mis-walk it.
        if p.hasSuffix("/casita/v1/feeds") || p.contains("/casita/v1/feeds/") { return false }
        return p.contains("/browsita/") || p.contains("/casita/")
            || p.contains("/scrollsita/")
    }

    static func strip(_ data: Data, url: URL? = nil) -> Data? {
        let path = url?.path ?? "?"

        var cursor = 0
        guard data.count >= 2, data[cursor] == 0x0a else { return bail(path, "no-outer-tag") }
        cursor += 1
        guard let (outerLen, outerLenBytes) = readVarint(data, at: cursor) else { return bail(path, "bad-outer-varint") }
        cursor += outerLenBytes
        let containerStart = cursor
        let containerEnd = cursor + Int(outerLen)
        guard containerEnd <= data.count else { return bail(path, "outer-len-overflow") }

        var newContainer = Data()
        var dropped = 0, kept = 0, idx = 0
        var c = containerStart

        while c < containerEnd {
            guard c < data.count, data[c] == 0x0a else { return bail(path, "section-tag-mismatch idx=\(idx)") }
            let sectionTagStart = c
            c += 1
            guard let (secLen, secLenBytes) = readVarint(data, at: c) else { return bail(path, "bad-section-varint idx=\(idx)") }
            c += secLenBytes
            let contentStart = c
            let contentEnd = c + Int(secLen)
            guard contentEnd <= containerEnd else { return bail(path, "section-len-overflow idx=\(idx)") }

            if let markers = adHits(data, start: contentStart, end: contentEnd) {
                if isVerbose(path) { writeDebugLog("[STRIP] DROP \(path) idx=\(idx) size=\(secLen) hits=\(markers.joined(separator: ","))") }
                dropped += 1
            } else {
                if isVerbose(path) { writeDebugLog("[STRIP] KEEP \(path) idx=\(idx) size=\(secLen)") }
                newContainer.append(data.subdata(in: sectionTagStart..<contentEnd))
                kept += 1
            }
            c = contentEnd
            idx += 1
        }

        guard dropped > 0 else { return nil }

        var result = Data()
        result.append(0x0a)
        result.append(encodeVarint(UInt64(newContainer.count)))
        result.append(newContainer)
        if containerEnd < data.count {
            result.append(data.subdata(in: containerEnd..<data.count))
        }
        writeDebugLog("[STRIP] \(path) dropped=\(dropped) kept=\(kept) \(data.count)->\(result.count)")
        return result
    }

    private static func adHits(_ data: Data, start: Int, end: Int) -> [String]? {
        guard end > start, end <= data.count else { return nil }
        let slice = data[start..<end]
        let hardHits = hardAdMarkers.compactMap {
            containsASCIIInsensitive(slice, needle: $0) ? String(decoding: $0, as: UTF8.self) : nil
        }
        if !hardHits.isEmpty { return hardHits }

        for keep in keepMarkers where containsASCIIInsensitive(slice, needle: keep) { return nil }

        let intentHits = promotionalIntentMarkers.compactMap {
            containsASCIIInsensitive(slice, needle: $0) ? String(decoding: $0, as: UTF8.self) : nil
        }
        guard !intentHits.isEmpty else { return nil }

        let surfaceHits = promotionalSurfaceMarkers.compactMap {
            containsASCIIInsensitive(slice, needle: $0) ? String(decoding: $0, as: UTF8.self) : nil
        }
        return surfaceHits.isEmpty ? nil : intentHits + surfaceHits
    }

    private static func bail(_ path: String, _ reason: String) -> Data? {
        if isVerbose(path) { writeDebugLog("[STRIP] bail \(path) reason=\(reason)") }
        return nil
    }

    private static func containsASCIIInsensitive(_ haystack: Data.SubSequence, needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }
        let last = haystack.endIndex - needle.count
        var i = haystack.startIndex
        while i <= last {
            var match = true
            for k in 0..<needle.count {
                if asciiLower(haystack[i + k]) != asciiLower(needle[k]) {
                    match = false
                    break
                }
            }
            if match { return true }
            i += 1
        }
        return false
    }

    private static func asciiLower(_ byte: UInt8) -> UInt8 {
        (0x41...0x5a).contains(byte) ? byte + 0x20 : byte
    }

    private static func readVarint(_ data: Data, at: Int) -> (UInt64, Int)? {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        var bytesRead = 0
        var idx = at
        while idx < data.count && bytesRead < 10 {
            let b = data[idx]
            value |= UInt64(b & 0x7f) << shift
            shift += 7
            bytesRead += 1
            idx += 1
            if (b & 0x80) == 0 { return (value, bytesRead) }
        }
        return nil
    }

    private static func encodeVarint(_ v: UInt64) -> Data {
        var value = v
        var result = Data()
        while value >= 0x80 {
            result.append(UInt8((value & 0x7f) | 0x80))
            value >>= 7
        }
        result.append(UInt8(value))
        return result
    }
}
