import Foundation

extension UserDefaults {
    /// 歌词那一组选项。
    ///
    /// 「Genius功能默认改成开启」⇒ `geniusFallback` 的默认值
    /// 由 `false` 改成 **`true`**。
    /// ⚠️ **光改这里不够**：这一份是**整块 JSON 落盘**的（见 `UserDefault` 属性包装器）——
    /// 只要动过其中任何一项，盘上那份里 `geniusFallback` 就已经是一个具体值，
    /// `defaultValue` 再也追不到它 ⇒ 配套的一次性迁移见文件末尾
    /// `LyricsOptions.applyGeniusFallbackDefaultIfNeeded`。
    @UserDefault(
        key: "lyricsOptions",
        defaultValue: LyricsOptions(
            musixmatchLanguage: Locale.current.languageCode ?? "",
            lrclibUrl: LrclibLyricsRepository.originalApiUrl,
            geniusFallback: true,
            hideOnError: false
        )
    )
    static var lyricsOptions
}

// MARK: - AMLL 译文语言
//
// 「AMLL 的译文能不能像 Musixmatch 一样指定语言」—— mxm 那条是**向服务端要**
// （`selected_language` + `part=subtitle_translated`，服务端有各语言译本）；
// AMLL 是**社区 TTML 文件里带什么就有什么**，一份文件可能同时挂 zh-Hans / en / ja
// 几轨 `<translation xml:lang="…">`，也可能只有一轨。
// 所以这个设置只能做到「**在文件提供的那几门语言里挑**」：
// · 填了语言码 → 优先取它；
// · 文件里没有这门语言 → 退回解析层原来那套优先级（zh-Hans → 中文 → 英文 → 其他），
//   显示别的语言好过显示空白。
//
// ⚠️ 键单独存（不进 `lyricsOptions` 那个整块 JSON）：那个 key 加字段会让旧数据解码失败
// （见 `AmllTtmlLyricsRepository` 文件头对 `apiUrl` 的同一段说明）。
extension UserDefaults {
    private static let amllTranslationLanguageKey = "ngzhwm_amllTranslationLanguage"

    /// 空串 = 自动（沿用解析层的语言优先级）。
    static var amllTranslationLanguage: String {
        get {
            (container.string(forKey: amllTranslationLanguageKey) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        set {
            container.set(
                newValue.trimmingCharacters(in: .whitespacesAndNewlines),
                forKey: amllTranslationLanguageKey
            )
        }
    }

    /// **实际**拿去挑译文的那门语言：设置里填了就用它，留空则用**设备语言**。
    ///
    /// 为什么自动档跟设备语言（与 Musixmatch 一致：它那个默认值就是 `Locale.current.languageCode`）：
    /// 中文设备用户本来就命中中文轨；非中文设备用户至少不比"永远中文"更差。
    ///
    /// ⚠️ **不再单独加"英文"这一步**。解析层的兜底顺序本来就是
    /// `zh-Hans → zh → en → 其他`，英文已经在链里（第 3 位）。28 个 AMLL 文件里
    /// 17 个带译文：16 个只有 `zh-CN`、1 个是 `zh-Hans` + `en`、**0 个只有 `en`** ⇒
    /// 把英文提到中文前面，唯一的效果是在那 1 个文件上把"英文系统的中文用户"
    /// 从中文改成英文 —— 那是一次**退化**，不是改进。
    static var amllEffectiveTranslationLanguage: String {
        let configured = amllTranslationLanguage
        guard configured.isEmpty else { return configured }
        // 只要语言码（`zh` / `en` / `ja`），不要 region：挑选是**前缀式**的，
        // `zh` 已经能命中 `zh-CN` / `zh-Hans` / `zh-Hant`，具体哪一轨交给解析层的优先级。
        return Locale.current.language.languageCode?.identifier ?? ""
    }
}

extension LyricsOptions {

    /// 迁移标记（只认它一次，之后永远尊重用户在设置里的选择）。
    private static let geniusDefaultMigratedKey = "lyricsOptionsGeniusDefaultOn"

    /// **一次性**把盘上那份 `geniusFallback` 打开 —— 为"默认值从关改成开"补一刀。
    ///
    /// 为什么需要它（而不是只改 `defaultValue` 就行）：`lyricsOptions` 是**整块 JSON**
    /// 落盘的。用户只要动过其中任何一项（mxm 语言 / lrclib 地址 / 隐藏错误），
    /// 盘上那份里 `geniusFallback` 就已经被写成了具体的 `false`，
    /// 改 `defaultValue` 对他**完全无效** —— 他会以为"你没改"。
    ///
    /// 只发生**一次**（标记键），并且照实打一行日志：
    /// 这是"默认值变更"的补偿，不是每次启动都覆盖。
    static func applyGeniusFallbackDefaultIfNeeded() {
        let container = UserDefaults.standard
        guard container.object(forKey: geniusDefaultMigratedKey) == nil else { return }
        container.set(true, forKey: geniusDefaultMigratedKey)

        var options = UserDefaults.lyricsOptions
        guard !options.geniusFallback else { return }
        options.geniusFallback = true
        UserDefaults.lyricsOptions = options
        writeDebugLog(
            "[Lyrics] genius fallback default turned on once (the stored options said off)"
                + " — from here on the switch in the lyrics settings decides"
        )
    }
}
