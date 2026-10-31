import Foundation

struct ExperimentsOptions: Codable, Equatable {
    var liveContainerSharing: Bool
    /// 「显示 Instagram 分享位」——删过一次（它挂的 `SPTSharingSDK` /
    /// `SPTShare_FoundationImplProperties` 只在 Spotify 9.1.0 上存在），按
    /// **9.1.88 的真实形态**重做：不再 hook 类，改成强制三条服务端 flag（见
    /// `ExperimentFlagReplacements`，与Flag 覆盖走同一条管线）。
    var showInstagramDestination: Bool
    /// 「AMLL 模糊搜索」—— AMLL 的精确（spotifyId）查不到时，按歌名再搜一次
    /// （见 `AmllTtmlLyricsRepository.fuzzySearchItem`）。逐词质量闸门不受影响。
    var amllFuzzySearch: Bool
    /// 「SpicyLyrics 交叉验证」——（用户）：SpicyLyrics 的上游会把部分词和谐成
    /// 星号（`my **** line`）。打开后拿**同一首歌**在另一个源里的文本找回同一句，
    /// 只把星号那几段换掉（见 `LyricsCensorFill` / `LyricsUncensorFill`）。
    ///
    /// **默认关**（用户明确要求）：它会为每首"确实有星号"的歌多发 1~5 次请求。
    /// ⚠️ 历史：这个功能在之前是**无条件开着**的，但那时它的检测正则是
    /// `\b\*{3,}\b`，实测只命中 `f***k` 这种写法、`my **** line` 一个都不命中
    /// ⇒ 实际上等于没接线。所以"改成默认关"对绝大多数用户**不是行为倒退**，
    /// 而是把一个本来就没生效的东西改成显式可选。
    var spicyLyricsCrossValidation: Bool
    /// 「启用Apple Music官方TTML歌词」——（用户）：直接接 **Apple Music 官方**的
    /// TTML（不是 AMLL 那份社区库）。
    ///
    /// 语义是**总覆盖**：打开后这一首只问 Apple Music，忽略「歌词来源」「AMLL 优先」
    /// 「Genius 回退」「多级回退」以及各来源自己的设置，失败也**不兜底**
    /// （见 `CustomLyrics.loadCustomLyricsForCurrentTrack` 顶部那一段）。
    ///
    /// ⚠️ 它需要用户在同一个设置页里粘一个 `media-user-token`（Apple 没有公开歌词 API，
    /// 见 `AppleMusicTtml+UserDefaults.swift`）。没填令牌时这一源直接抛
    /// `.missingAppleMusicToken`，界面上表现为"未找到歌词" + 一次提示弹窗。
    var appleMusicOfficialTtml: Bool

    init(
        liveContainerSharing: Bool,
        showInstagramDestination: Bool = false,
        amllFuzzySearch: Bool = false,
        spicyLyricsCrossValidation: Bool = false,
        appleMusicOfficialTtml: Bool = false
    ) {
        self.liveContainerSharing = liveContainerSharing
        self.showInstagramDestination = showInstagramDestination
        self.amllFuzzySearch = amllFuzzySearch
        self.spicyLyricsCrossValidation = spicyLyricsCrossValidation
        self.appleMusicOfficialTtml = appleMusicOfficialTtml
    }

    /// 手写解码：`liveContainerSharing` 之外那些都是**后加的**字段，早期盘上根本没有它们。
    /// 合成解码器遇到缺字段会抛，而 `@UserDefault` 解失败会**整份回落到 defaultValue**
    /// —— 那等于一次升级把用户已经关掉的 `liveContainerSharing` 又打开。
    /// 口径与 `FlagOverride.init(from:)` 一致：缺的键取"默认值"。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        liveContainerSharing = try container.decodeIfPresent(Bool.self, forKey: .liveContainerSharing) ?? true
        showInstagramDestination = try container.decodeIfPresent(Bool.self, forKey: .showInstagramDestination) ?? false
        amllFuzzySearch = try container.decodeIfPresent(Bool.self, forKey: .amllFuzzySearch) ?? false
        spicyLyricsCrossValidation = try container.decodeIfPresent(Bool.self, forKey: .spicyLyricsCrossValidation)
            ?? false
        appleMusicOfficialTtml = try container.decodeIfPresent(Bool.self, forKey: .appleMusicOfficialTtml)
            ?? false
    }
}
