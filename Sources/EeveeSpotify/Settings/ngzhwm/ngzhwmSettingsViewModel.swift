import Foundation
import Combine

class NgzhwmSettingsViewModel: ObservableObject {
    static let removeMxmInterludeSymbolKey = "ngzhwm_removeMxmInterludeSymbol"
    static let disableLyricsFeatureKey = "ngzhwm_disableLyricsFeature"
    static let neteaseRomajiLocalKey = "ngzhwm_neteaseRomajiLocal"
    static let neteaseHideTranslationKey = "ngzhwm_neteaseHideTranslation"
    static let wordByWordLyricsKey = "ngzhwm_wordByWordLyrics"
    static let betterWordByWordLyricsKey = "ngzhwm_betterWordByWordLyrics"
    /// 「AMLL 优先」的 UserDefaults 键。
    ///
    /// ⚠️ 2026-10-02 **恢复**：2026-09-25 曾因用户一句"感觉没什么用"把整条链删掉
    /// （提交 `50528cd`，8 个文件），用户随后要求加回来。键名沿用旧名
    /// （`ngzhwm_amllPreferred`），设备上可能还留着上次的值。
    static let amllPreferredKey = "ngzhwm_amllPreferred"
    // 已删除一个 key（2026-09-27）：`ngzhwm_syntheticLineTiming` —— 「补全歌词时间轴」。
    //
    // 为什么删：真机 A/B（用户关掉它跑了一整场）结论是"差不多、或略好一点"，而**给本来就
    // 没有时间轴的源（Genius / Petit 纯文本）伪造一层时间轴本身就不合语义** ——
    // 估算出来的 offset 只会让整首都不准。现在：
    //   · **真实歌词源一律不再合成时间轴**（`LyricsDto.toSpotifyLyricsData` 里那段已删）；
    //   · 只有**占位文案**仍然补（`makeUnavailableLyrics` 里写死）——
    //     那是"未找到歌词"这一行能不能显示出来的前提，不是给某个源伪造时间轴。
    // 旧设备上残留的键不再被读、也不会被清（留着无害）。
    /// 「给没有歌词卡片的曲目补一个卡片元素」—— 见 `isLyricsCardElementInjectionEnabled`。
    ///
    /// ⚠️ 2026-09-26 **恢复为真开关**（曾一度写死启用）：2026-09-26 的真机日志（日志 3）
    /// 显示这个元素在部分曲目上渲染成了「即将发布 / 已预收藏」卡，需要 A/B 才能定性。
    /// 沿用旧 key 名，设备上残留的值会被重新读起来。
    static let injectLyricsCardElementKey = "ngzhwm_injectLyricsCardElement"
    /// 「把服务端那条 `lyrics_entry_point_enabled` 钉成 true」—— 见 `isLyricsEntryPointFlagForced`。
    ///
    /// ⚠️ 2026-09-26 由**写死**改为真开关：真机 A/B 已经排除了「补卡片元素」那一处
    /// （关掉它之后那张过期的「即将发布」卡**依然出现**），于是剩下的、唯一还能影响
    /// 正在播放页卡片渲染的我们自家改动就是这条 flag。留开关就是为了判定它。
    static let lyricsEntryPointFlagKey = "ngzhwm_lyricsEntryPointFlag"
    // 已移除一个 key（2026-09-25）：`ngzhwm_hideOfficialLyrics` ——
    // 它对应的行为已在下面**写死启用**，不再读 UserDefaults。
    // 旧设备上残留的键不再被读、也不会被清（留着无害）。
    static let blurredLyricsBackdropKey = "ngzhwm_blurredLyricsBackdrop"
    static let lyricsBackdropMaterialKey = "ngzhwm_lyricsBackdropMaterial"

    static var isLyricsFeatureDisabled: Bool {
        UserDefaults.standard.bool(forKey: disableLyricsFeatureKey)
    }

    /// 设备主语言是否为中文（简体/繁体）。
    static var isChineseDevice: Bool {
        Locale.preferredLanguages.first?.lowercased().hasPrefix("zh") == true
    }

    /// 读取带默认值的布尔开关：key 尚未写入时返回 defaultValue，否则返回已存值。
    private static func bool(forKey key: String, defaultValue: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) == nil
            ? defaultValue
            : UserDefaults.standard.bool(forKey: key)
    }

    static var isWordByWordLyricsEnabled: Bool {
        bool(forKey: wordByWordLyricsKey, defaultValue: true)
    }

    // MARK: - ★ 2026-10-12：扩展那页三颗"总开关"要读写的键

    /// 三颗**逐语言**罗马化开关（设置 → 歌词 那一页）—— 与 `LyricLinesAdapter
    /// .romanizationSwitchesFingerprint()`、`LyricsDto`、`AmllLyricsMapper`、
    /// `NeteaseLyricsRepository` / `MusixmatchLyricsRepository` 里读的**是同一批键**。
    ///
    /// ⚠️ 那几处目前仍是**字面量**（本轮没一起改，避免把一次"加开关"扩成一次全仓重构）；
    ///    集中在这里是为了给扩展页那颗总开关一个**单一实现**，将来收敛只改这一处。
    static let japaneseRomanizationKey = "ngzhwm_japaneseRomanization"
    static let chineseRomanizationKey = "ngzhwm_chineseRomanization"
    static let koreanRomanizationKey = "ngzhwm_koreanRomanization"

    /// 三颗逐语言罗马化开关里**有没有开着的**（扩展页那颗「展示罗马化歌词」读它）。
    static var anyRomanizationEnabled: Bool {
        UserDefaults.standard.bool(forKey: japaneseRomanizationKey)
            || UserDefaults.standard.bool(forKey: chineseRomanizationKey)
            || UserDefaults.standard.bool(forKey: koreanRomanizationKey)
    }

    /// 一次性把三颗逐语言罗马化开关设成同一个值（扩展页那颗总开关写它）。
    static func setAllRomanization(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: japaneseRomanizationKey)
        UserDefaults.standard.set(enabled, forKey: chineseRomanizationKey)
        UserDefaults.standard.set(enabled, forKey: koreanRomanizationKey)
    }

    static var isNeteaseHideTranslationEnabled: Bool {
        bool(forKey: neteaseHideTranslationKey, defaultValue: !isChineseDevice)
    }

    /// ★ 2026-10-12：扩展页那颗「展示歌词翻译」写它 —— 与上面**互为反相、键只有一个**
    /// （所以歌词页那颗「隐藏译文」与扩展页这颗永远同步，不存在两份真相）。
    static func setHideTranslation(_ hidden: Bool) {
        UserDefaults.standard.set(hidden, forKey: neteaseHideTranslationKey)
    }

    /// 「AMLL 优先」：开启后先向 AMLL 要逐词歌词，没正常返回再回退到用户在
    /// 来源选择器里设置的那个源（连同它的相关设置）。
    ///
    /// 之所以回退到「用户自己选的源」而不是硬编码一条回退链：哪个源适合兜底完全
    /// 取决于地区与语言 —— 日本用户设 PetitLyrics、大陆用户设网易云、其它地区设
    /// SpicyLyrics，各自回退到最合适的地方，不需要我们再维护地区判断。
    ///
    /// 默认关闭，已装用户的既有行为不变。
    ///
    /// ⚠️ 2026-10-02 **恢复**（2026-09-25 删过一次，来龙去脉见 `amllPreferredKey` 的说明）。
    static var isAmllPreferred: Bool {
        bool(forKey: amllPreferredKey, defaultValue: false)
    }

    /// 「隐藏 Spotify 官方歌词」：我方来源取不到词时，**不再把 Spotify 的原始响应放行**，
    /// 而是用我们自己的一小段「未找到歌词」占位顶上去。
    ///
    /// 为什么需要：钩子在取词失败时原本是 `customLyricsData ?? buffer`，于是界面上显示的是
    /// **Spotify 自己的歌词** —— 日区那批的来源写着「プチリリ」（Spotify 的日文歌词供应商，
    /// **不带 (EeveeSpotify) 后缀**），而且不会跟着我们的罗马化设置走，
    /// 看起来就像"来源设置没生效 / 罗马化设置失效"。
    ///
    /// ⚠️ **写死为 true**（2026-09-25）：这已经是修好的行为，不再是可选项 ——
    /// 用户选定了某个来源，预期就是"要么显示这个来源的词，要么什么都不显示"，
    /// 而不是"取不到就悄悄换成 Spotify 的"。
    /// 想明确看官方歌词的模式仍然在：来源里选「禁用歌词替换」（`.notReplaced`）。
    static var isOfficialLyricsHidden: Bool { true }

    /// 「模糊封面背景」是否生效。
    ///
    /// **不再是独立开关**：需求是"更好的逐词歌词启用时，这两个背景功能就跟着启用"，
    /// 所以它直接派生自 `isBetterWordByWordLyricsEnabled`。
    /// 既有的 `blurredLyricsBackdropKey` 不再参与判断（保留 key 常量与 VM 属性只是为了
    /// 不破坏旧数据、少一处无谓改动）。
    static var isLyricsBlurredBackdropEnabled: Bool {
        isBetterWordByWordLyricsEnabled
    }

    /// 「更好的逐词歌词」：Apple Music 风格的独立渲染层（需 iOS 26+）。
    ///
    /// ★ 2026-10-11：从「默认关闭」改成「**默认开启**」。
    ///
    /// 原话：「2 也默认打开吧」—— 因为它是「歌词进播放器」的**第一道门禁**
    /// （`NowPlayingLyricsPlate.canShow()` 里 `guard isBetterWordByWordLyricsEnabled`），
    /// 那个开关现在默认开了，这个若还默认关，全新安装上就是"键看得见、点了没反应"。
    /// 顺带把两个派生值也一起带开：`isLyricsBlurredBackdropEnabled`（模糊封面底）与
    /// `isLyricsBackdropMaterialEnabled`（系统材质压色带）—— 它们本来就写死跟随这一个开关。
    ///
    /// 当初默认关闭的理由（"这是整体重写，先让用户显式开启；出问题一键回到旧实现"）
    /// 现在的状态：用户在真机上已经用了几十轮、并逐步把这块指定成主界面（照片 67→75）。
    /// 想回到旧实现的人仍然可以在这里关掉它（关掉即回退旧 overlay）。
    ///
    /// ⚠️ 它需要 **iOS 26+**（`#available(iOS 26.0, *)`）—— 低版本设备上这个开关
    /// **开着也不会生效**，走的是旧实现那条路（见 `AppleMusicLyricsOverlay` 的可用性判断）。
    static var isBetterWordByWordLyricsEnabled: Bool {
        bool(forKey: betterWordByWordLyricsKey, defaultValue: true)
    }

    /// 是否在模糊封面之上再叠一层系统材质压色带。
    /// 与 `isLyricsBlurredBackdropEnabled` 同理，跟随「更好的逐词歌词」。
    static var isLyricsBackdropMaterialEnabled: Bool {
        isBetterWordByWordLyricsEnabled
    }

    /// 「给没有歌词卡片的曲目补一个卡片元素」。
    ///
    /// 背景：真机取证发现 `scrollsita/v1/scroll/spotify:track:<id>`（正在播放页的**元素列表**）
    /// 只在"Spotify 自己有官方歌词"的曲目上多下发一个元素（内层字段号 5，只引用曲目 URI）。
    /// 补上之后，缺这一项的响应会被写入这一项（byte 级，只在能完整解析时动手，
    /// 任何异常都原样放行）。见 `ScrollsitaLyricsElementInjector`。
    ///
    /// ⚠️ 2026-09-26 **恢复为真开关**（此前一度写死 `true`）。默认 **ON** ——
    /// 保持"404 曲目也有歌词卡片"的既有行为不变。
    ///
    /// 为什么要留开关：日志 3 解出的元素清单显示，在 404 曲目上我们补的这一个元素
    /// 是那份响应里**唯一**多出来的东西，而用户报告这些曲目上会间歇出现一张
    /// 「即将发布 / 已预收藏」卡（日期早已过期，甚至有 2021 年的）。
    /// 关掉它即可判定：那张卡到底是这个元素渲出来的，还是另一条路来的。
    static var isLyricsCardElementInjectionEnabled: Bool {
        bool(forKey: injectLyricsCardElementKey, defaultValue: true)
    }

    /// 是否把服务端下发的 `lyrics_entry_point_enabled`（scope `ios-feature-lyrics`）钉成 true。
    ///
    /// 默认 **ON** —— 保持"9.1.86 上歌词卡片能出现"的既有行为不变。
    ///
    /// 为什么要留开关（2026-09-26）：排查那张**日期早已过期**的「即将发布 / 已预收藏」卡。
    /// 三条路已经排掉了两条：
    ///   · **元素列表** —— 假卡出现在原生只有 `[2,3,4]`、连 `12`（正版预热卡）都没有的曲目上；
    ///   · **补卡片元素**（`isLyricsCardElementInjectionEnabled`）—— 真机关掉它，假卡**照样出现**；
    ///   · **HTTP 数据** —— 九份日志里没有任何一条响应带着预热 / 发行日期，
    ///     连 metadata / entity 类接口都不存在，那份数据 100% 在客户端本地。
    ///
    /// ⇒ 我们唯一还可能"让客户端多渲染一张卡"的就是这条 flag。关掉它即可判定：
    /// 假卡消失 = 是它；假卡还在 = 与我们无关，那是 Spotify 自己拿着过期的专辑
    /// prerelease 记录渲出来的。
    static var isLyricsEntryPointFlagForced: Bool {
        bool(forKey: lyricsEntryPointFlagKey, defaultValue: true)
    }
}
