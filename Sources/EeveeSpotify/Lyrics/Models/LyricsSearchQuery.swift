import Foundation

struct LyricsSearchQuery: Hashable {
    var title: String
    var primaryArtist: String
    var spotifyTrackId: String

    /// Spotify 侧歌曲时长（毫秒）。从 track 的 metadata 字典提取；
    /// 本地文件等拿不到时为 nil，调用方应跳过时长校验。
    var durationMs: Int? = nil

    /// **全部**艺人名（第一位 + `artist_name:1` 那些合作艺人）。
    ///
    /// 为什么要它：`primaryArtist` 只够**搜索**，不够**判定**。真机日志 45 的现场是
    /// 「`[NetEase] Chosen[11]` → `yrc absent` → `No usable lyrics`」与
    /// 「`Chosen[0]` → 时长差 42 秒」交替出现 —— 选歌只看时长，**完全不比对歌手**，
    /// 同一时长里的翻唱 / 伴奏 / 同曲异名版本会被选中 ⇒ 用户看到的词全是错的。
    /// 有了这份名单就能要求"候选的歌手与我们对得上"，把翻唱挡在外面。
    var artistNames: [String] = []

    /// 参与匹配的歌手集合（主艺人 + 全部合作艺人，去重、去空白）。
    var allArtistNames: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for name in ([primaryArtist] + artistNames) {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            out.append(trimmed)
        }
        return out
    }
}

