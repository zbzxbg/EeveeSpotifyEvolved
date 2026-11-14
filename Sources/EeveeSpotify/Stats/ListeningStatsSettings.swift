import Foundation

/// 「听歌统计」的开关与它占用的 `UserDefaults` 键。
///
/// 键由功能自己拥有（与 `LyricsTimingOffset` / `LyricsSourceOrder` 同一条做法）：加在这里，
/// 再由 `UserDefaults.ownedKeys` 之类的地方拼接上去，「备份与重置」才认识它。
///
/// 默认**开**：这条功能纯本地、不联网、不产生额外请求，开着没有副作用；不想要的人拨一下
/// 就停，已有数据不会被清掉。
enum ListeningStatsSettings {

    /// 「记录听歌统计」的开关键（键名照仓库其它功能自持键的写法用 camelCase）。
    static let enabledKey = "listeningStatsEnabled"

    /// 本功能占用的全部 `UserDefaults` 键（给「备份与重置」的白名单用）。
    static var ownedKeys: [String] { [enabledKey] }

    static var isEnabled: Bool {
        get {
            UserDefaults.container.object(forKey: enabledKey) as? Bool ?? true
        }
        set {
            UserDefaults.container.set(newValue, forKey: enabledKey)
        }
    }
}

extension UserDefaults {

    /// 「记录听歌统计」。**实时读**：录音器每一拍都会看它，所以拨开关不需要重启 Spotify。
    static var listeningStatsEnabled: Bool {
        get { ListeningStatsSettings.isEnabled }
        set { ListeningStatsSettings.isEnabled = newValue }
    }
}
