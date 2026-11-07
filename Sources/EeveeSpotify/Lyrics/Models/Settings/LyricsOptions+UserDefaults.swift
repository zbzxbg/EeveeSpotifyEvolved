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
// AMLL 是**社区 TTML 文件里带什么就有什么**：一份文件可能同时挂 zh-Hans / en / ja
// 几轨 `<translation xml:lang="…">`，也可能只有一轨。挑哪一轨由**设备语言**决定，
// 文件里没有那门语言时退回解析层的优先级（zh-Hans → 中文 → 英文 → 其他）。
//
// 以前这里还有一个"手动指定语言码"的设置，已删除：74 份抽样里只有 1 份带多语言轨，
// 而设备语言那条自动路径已经覆盖了它（英文设备在 `zh-Hans` + `en` 那份上会自动选 en）。
extension UserDefaults {
    /// 拿去挑 AMLL 译文的那门语言 —— 就是**设备语言**。
    ///
    /// 只要语言码（`zh` / `en` / `ja`），不要 region：挑选是**前缀式**的，
    /// `zh` 已经能命中 `zh-CN` / `zh-Hans` / `zh-Hant`，具体哪一轨交给解析层的优先级。
    static var amllEffectiveTranslationLanguage: String {
        Locale.current.language.languageCode?.identifier ?? ""
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
