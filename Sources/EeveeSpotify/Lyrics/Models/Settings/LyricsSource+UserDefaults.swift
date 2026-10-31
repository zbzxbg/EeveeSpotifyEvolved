import Foundation

extension LyricsSource {

    /// 这一项在**当前听歌页样式**下能不能选、会不会生效。
    ///
    /// 「如果听歌页样式那里选择的是 spotify 原生，该自动优选不可选择。
    /// 此选项只对选择沉浸式/am式生效」。
    ///
    /// 只挡 `.autoSelect` 一项：单源模式在三种样式下都照常工作（原生听歌页那一侧本来就是
    /// 靠我们注入 payload 换掉 Spotify 自己的歌词，单源一直这么跑）。
    var isAvailableInCurrentNowPlayingStyle: Bool {
        self != .autoSelect || UserDefaults.nowPlayingStyle != .spotify
    }

    /// 存的那一项如果当前样式下不能用，退回默认来源 —— **不改写盘上的值**。
    ///
    /// 为什么不直接改写存储：自动优选应当**自己回来**。
    /// 覆盖掉存储等于替用户做了选择，而他那次操作只是改了个页面样式。
    var effectiveForCurrentStyle: LyricsSource {
        guard !isAvailableInCurrentNowPlayingStyle else { return self }
        logStyleOverrideOnce()
        return LyricsSource.defaultSource
    }

    /// 这条日志每个（源 + 样式）组合只打一次：`UserDefaults.lyricsSource` 读得很频繁
    /// （每次取词、每次算缓存签名、每次画设置页），不去重会刷屏。
    private func logStyleOverrideOnce() {
        guard lastStyleOverrideLogged != rawValue else { return }
        lastStyleOverrideLogged = rawValue
        writeDebugLog(
            "[Lyrics] source \"\(description)\" needs the immersive / Apple Music now-playing style"
                + " — using \(LyricsSource.defaultSource.description) instead"
        )
    }
}

/// 上一次为「样式不支持这个源」打过日志的 rawValue（-1 = 还没打过）。
///
/// 用 `Int` 而不是字符串：`UserDefaults.lyricsSource` 会在后台线程被读，
/// 一个词大小的比较/赋值至少不会像字符串那样在半途被撕裂。
private var lastStyleOverrideLogged = -1

extension UserDefaults {
    private static let lyricsSourceKey = "lyricsSource"
    /// 旧版「歌词多级回退」独立开关的 key，仅用于一次性迁移。
    private static let legacyMultiLevelFallbackKey = "ngzhwm_multiLevelLyricsFallback"

    static var lyricsSource: LyricsSource {
        get {
            // 一次性迁移：旧的「歌词多级回退」独立开关已并入来源选择器。
            // 若用户此前开着该开关，则切换到 .autoSelect 并清掉旧 key。
            // （`.autoSelect` 就是之前那个 `.multiLevel`，rawValue 没变。）
            if container.bool(forKey: legacyMultiLevelFallbackKey) {
                container.set(false, forKey: legacyMultiLevelFallbackKey)
                container.set(LyricsSource.autoSelect.rawValue, forKey: lyricsSourceKey)
                return LyricsSource.autoSelect.effectiveForCurrentStyle
            }

            // ⚠️ 以前这里是 `LyricsSource(rawValue:)!` —— 盘上被写进一个越界的整数
            // （旧版本回滚、备份导入、手改 plist）就是**启动崩溃**。
            // 认不出当作没设过，退回默认来源。
            if let rawValue = container.object(forKey: lyricsSourceKey) as? Int,
               let stored = LyricsSource(rawValue: rawValue) {
                return stored.effectiveForCurrentStyle
            }

            return LyricsSource.defaultSource
        }
        set (newSource) {
            container.set(newSource.rawValue, forKey: lyricsSourceKey)
        }
    }
}
