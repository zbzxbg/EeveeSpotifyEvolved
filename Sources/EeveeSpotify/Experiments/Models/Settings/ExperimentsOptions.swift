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
    /// 「SpicyLyrics 交叉验证」—— SpicyLyrics 的上游会把部分词和谐成
    /// 星号（`my **** line`）。打开后拿**同一首歌**在另一个源里的文本找回同一句，
    /// 只把星号那几段换掉（见 `LyricsCensorFill` / `LyricsUncensorFill`）。
    ///
    /// **默认关**：它会为每首"确实有星号"的歌多发 1~5 次请求。
    /// 旧检测正则 `\b\*{3,}\b` 只命中 `f***k` 那种写法，`my **** line` 一个都不命中 ——
    /// 所以"默认关"对绝大多数用户**不是行为倒退**。
    var spicyLyricsCrossValidation: Bool
    /// 「启用Apple Music官方TTML歌词」—— 直接接 **Apple Music 官方**的
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
    /// 「伪逐字填充」—— 只有**行级**时间轴的来源（LRCLIB / PetitLyrics /
    /// 没有逐字档的网易云与 Musixmatch / QQ 与酷狗的 LRC 兜底），把整行按
    /// **估算演唱时长**逐字填亮，而不是一次亮起。
    ///
    /// 为什么放在「实验」里：它确实在编时间（行内分布是估的），估偏了前沿就会提前/滞后。
    /// 实现见 `PseudoWordTiming`；接线在 `LyricLinesAdapter.toAppleMusicLyricLines()`。
    /// ⚠️ 它**不改变** `timingKind`（仍是 `.lineSynchronized`）—— 改了会让间奏判定
    /// 把估算值当作者时间轴。
    var pseudoWordByWordLyrics: Bool
    /// 「更激进的删除歌词标注术语」—— 打开后**凡是整行被 `[]` 包住**的行都删掉，
    /// 不再要求括号里是已知的章节名（`[Verse 1]` / `[Chorus]` / `[Produced by …]`）。
    ///
    /// 为什么需要它：`LyricsMarkerFilter` 的清单是**白名单**，Genius 上还有一堆白名单外的
    /// 标注（`[Refrain]`、`[Verse 3: X & Y]`、各种语言的自造段落名）会被当正文画到屏幕上。
    /// 白名单永远追不完，所以给一条"整行方括号就删"的粗规则，由用户自己决定要不要。
    ///
    /// ⚠️ **只对 Genius 生效**：Genius 的正文是纯文本、`[]` 在它那儿
    /// 基本只作段落标注；而 QQ / 酷狗 / 网易的 `[]` 里是时间轴或转写标记，一刀切会删掉真歌词。
    ///
    /// ⚠️ 它会误删"整行被方括号包住的真歌词"（`[I love you]` 这种写法确实存在，但极少）；
    /// 默认关，就是这个原因。
    var aggressiveMarkerRemoval: Bool
    /// 「PetitLyrics 回退逐行」—— PetitLyrics 有一部分 `wordsSynced` 不是真点出来的：
    /// 每行每个词固定同一个 step，而 step 的大小（80 / 15 / 5 / 2 …）与这首歌的行间距无关 ⇒
    /// 整行词轴只占行间距的一小截（判据见 `PetitLyricsRepository.wordTimingCoverage`）。
    /// 后果是逐字高亮一两秒就扫完整句、剩下时间被间奏判定当成"没人唱"，
    /// 于是句与句之间几乎每一处都冒出呼吸点。
    ///
    /// **默认开**：开了只会少一层本就可疑的逐字高亮，不会让正确的时间轴变差 ——
    /// 覆盖率中位数在正常歌里是 65% 以上，编出来的那几首在 15% 上下，两端分得很开。
    var petitLyricsLineFallback: Bool

    init(
        liveContainerSharing: Bool,
        showInstagramDestination: Bool = false,
        amllFuzzySearch: Bool = false,
        spicyLyricsCrossValidation: Bool = false,
        appleMusicOfficialTtml: Bool = false,
        pseudoWordByWordLyrics: Bool = false,
        aggressiveMarkerRemoval: Bool = false,
        petitLyricsLineFallback: Bool = true
    ) {
        self.liveContainerSharing = liveContainerSharing
        self.showInstagramDestination = showInstagramDestination
        self.amllFuzzySearch = amllFuzzySearch
        self.spicyLyricsCrossValidation = spicyLyricsCrossValidation
        self.appleMusicOfficialTtml = appleMusicOfficialTtml
        self.pseudoWordByWordLyrics = pseudoWordByWordLyrics
        self.aggressiveMarkerRemoval = aggressiveMarkerRemoval
        self.petitLyricsLineFallback = petitLyricsLineFallback
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
        pseudoWordByWordLyrics = try container.decodeIfPresent(Bool.self, forKey: .pseudoWordByWordLyrics)
            ?? false
        aggressiveMarkerRemoval = try container.decodeIfPresent(Bool.self, forKey: .aggressiveMarkerRemoval)
            ?? false
        // 默认**开**：缺键时按"新功能已启用"处理，否则一次升级会把新功能关掉。
        petitLyricsLineFallback = try container.decodeIfPresent(
            Bool.self,
            forKey: .petitLyricsLineFallback
        ) ?? true
    }
}
