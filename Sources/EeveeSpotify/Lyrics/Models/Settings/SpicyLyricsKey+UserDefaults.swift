import Foundation

// MARK: - SpicyLyrics 官方 API 的客户端密钥
//
// ## 为什么**不内置**默认密钥（用户 2026-10-13 拍板）
//
// 上游（EeveeSpotifyReincarnated）是"内置一个公开 key 当默认、设置里可覆盖"。
// 我们**不**那么做，两个理由：
//   1. **条款**：SL 的服务条款 §3 明写 *"Do not share a key"*，而"内置在公开仓库/分发的
//      IPA 里的 key"就是被所有人共用；真被吊销，所有装机一起坏。
//   2. **它会掩盖配置**：内置 key 一失效，用户看到的是"歌词源坏了"，而不是"我该填自己的密钥"。
//
// 所以：**用户必须自己填**。没填时这一首改用 **Musixmatch**（见
// `CustomLyrics.loadCustomLyricsForCurrentTrack` 里那一段替换），而不是去走
// SpicyLyrics 那条内部接口 `POST /query` —— 那条路的响应外壳写着只授权官方客户端与其公开
// fork，第三方应用用它属于 §5 的"绕过 key 体系"，而且要先抓 Spotify 的 access token。
//
// ⚠️ 这里只放 **client / publishable key**（`sl_pk_` 前缀）。SL 的 secret key（`sl_sk_`）
// 是给服务端用的：官方文档明确"永远不要放进客户端代码"，而且它只存哈希、泄露后只能立刻轮换，
// 客户端轮换要等所有装机更新（"may take weeks"）⇒ 打进 IPA 等于废号。
extension UserDefaults {
    private static let spicyLyricsApiKeyKey = "spicyLyricsApiKey"

    /// 用户在设置里填的 key（**没有内置默认值**；空 = 没填）。
    ///
    /// 拿 key 的入口在设置页：「歌词 → 来源 = SpicyLyrics」那一栏下面的说明里，
    /// 「Spicy Lyrics 开发者面板」是可点链接（见 `EeveeLyricsSettingsView+lyricsSourceSection`）。
    static var spicyLyricsApiKey: String {
        get {
            (container.string(forKey: spicyLyricsApiKeyKey) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        set (key) {
            container.set(
                key.trimmingCharacters(in: .whitespacesAndNewlines),
                forKey: spicyLyricsApiKeyKey
            )
        }
    }

    /// 真正发出去的 key —— 就是用户填的那个，**没有兜底**。
    static var effectiveSpicyLyricsApiKey: String { spicyLyricsApiKey }

    /// 用户填过密钥没有。判据只此一处（别在调用点各写一份 `isEmpty`）。
    static var hasSpicyLyricsApiKey: Bool { !spicyLyricsApiKey.isEmpty }
}
