import Foundation

extension UserDefaults {
    /// 歌词那一组选项。
    ///
    /// ★ 2026-10-13（用户要求）：「Genius功能默认改成开启」⇒ `geniusFallback` 的默认值
    /// 由 `false` 改成 **`true`**。
    /// ⚠️ **光改这里不够**：这一份是**整块 JSON 落盘**的（见 `UserDefault` 属性包装器）——
    /// 用户只要动过其中任何一项，盘上那份里 `geniusFallback` 就已经是一个具体值，
    /// `defaultValue` 再也追不到它 ⇒ 配套的一次性迁移见文件末尾
    /// `LyricsOptions.applyGeniusFallbackDefaultIfNeeded()`。
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
    /// 这是"默认值变更"的补偿，不是每次启动都覆盖用户的选择。
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
