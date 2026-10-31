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
    /// 为什么要它：`primaryArtist` 只够**搜索**，不够**判定**。
    /// 「`[NetEase] Chosen[11]` → `yrc absent` → `No usable lyrics`」与
    /// 「`Chosen[0]` → 时长差 42 秒」交替出现 —— 选歌只看时长，**完全不比对歌手**，
    /// 同一时长里的翻唱 / 伴奏 / 同曲异名版本会被选中 ⇒ 的词全是错的。
    /// 有了这份名单就能要求"候选的歌手与我们对得上"，把翻唱挡在外面。
    var artistNames: [String] = []

    /// 同一首歌在 Spotify 侧可能有多份标题（player track 的 `trackTitle` 与
    /// metadata 里的本地化 `title`）。
    ///
    /// 为什么需要：NetEase 的搜索**对文字敏感** —— 日文名能搜到，罗马字名常常只搜到
    /// 翻唱/同曲异名实测：`Himitsu MIMI` 前 30 条里没有 MIMI 的
    /// 《ヒミツ》，`MIMI ヒミツ` 第 2 条就是）。搜索时逐个试，命中高置信度就停。
    var titleVariants: [String] = []

    /// 专辑名（metadata `album_title`）。**只用于候选打分**，不进搜索串 ——
    /// 带着专辑名搜会明显缩小结果集，反而搜不到同曲异名的条目。
    var albumTitle: String? = nil

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

