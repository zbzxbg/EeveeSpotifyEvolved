import Foundation

/// 取词时的**候选匹配**判据（标题 / 歌手 / 时长）。
///
/// 为什么单独一个文件：QQ 音乐、酷狗、BiniLyrics、Unison 都是"按名字搜、自己在结果里挑一条"。
/// 挑错的代价是把**别人的词**配到这首歌上（翻唱、同曲异名、Live 版），而且用户很难察觉。
/// 判据必须只有一份 —— 否则四个源会各飘一套，同一首歌在四个源里配到四个不同的录音。
///
/// 本文件**只依赖 Foundation**，所以能进 `Tests/` 单独编译。
enum LyricsMatch {

    /// 归一化：小写 + 去掉空白 / 标点 / 符号。
    ///
    /// 为什么去标点：`Don't Stop Me Now` / `Dont Stop Me Now` / `Don’t Stop Me Now`
    /// （直引号 vs 弯引号）在中日韩与西文曲库里都是同一个名字，但字符串不相等。
    /// CJK 的全角标点（`、` `！` ``）也在 `punctuationCharacters` 里，一并去掉。
    static func key(_ text: String?) -> String {
        guard let text, !text.isEmpty else { return "" }
        var dropped = CharacterSet.whitespacesAndNewlines
        dropped.formUnion(.punctuationCharacters)
        // ⚠️ 是 `.symbols`，不是 `.symbolCharacters` —— 后者不存在编译现场）。
        dropped.formUnion(.symbols)
        return text.lowercased()
            .components(separatedBy: dropped)
            .joined()
    }

    /// 标题的**主名**：去掉成对的括号段（`(Live)`、`（人狂热症）`、`[Explicit]`、`【…】`）。
    ///
    /// 曲库给同一个录音的写法差别极大：QQ 会用「人マニア (人狂热症) (Explicit)」，酷狗的 KRC
    /// 条目同样带后缀。只比 `key` 的话这些条目全部对不上，链路上就表现为「搜到了、但没一条算命中」。
    ///
    /// 括号段是**成对**的：嵌套的括号会整体跳过（`(a (b))` 只留空），落单的右括号按普通字符处理。
    static func baseTitle(_ text: String?) -> String {
        guard let text, !text.isEmpty else { return "" }
        var depth = 0
        var out = ""
        for character in text {
            switch character {
            case "(", "（", "[", "【", "〔", "｛", "{":
                depth += 1
            case ")", "）", "]", "】", "〕", "｝", "}":
                if depth > 0 { depth -= 1 }
            default:
                if depth == 0 { out.append(character) }
            }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 候选标题与目标标题是否指**同一首**。
    ///
    /// 判据：`key` 相等，或去掉括号段之后相等。两条**都不含"包含"**：
    /// `晴天` 与 `晴天 (Live)` 靠括号剥掉之后相等（时长闸门再挡一次），
    /// 而 `ユリイカ` 与 `ユリイカ (English ver.)` 也走同一条 —— 这类翻唱/改版主要靠时长区分。
    static func titlesMatch(_ candidate: String?, _ wanted: String?) -> Bool {
        let candidateKey = key(candidate)
        let wantedKey = key(wanted)
        guard !candidateKey.isEmpty, !wantedKey.isEmpty else { return false }
        if candidateKey == wantedKey { return true }
        let candidateBase = key(baseTitle(candidate))
        let wantedBase = key(baseTitle(wanted))
        return !candidateBase.isEmpty && candidateBase == wantedBase
    }

    /// 候选标题是否命中**任意一个**目标标题（曲目名 / 本地化名 / 用户榜单上的写法）。
    static func titlesMatch(_ candidate: String?, anyOf wanted: [String]) -> Bool {
        wanted.contains { titlesMatch(candidate, $0) }
    }

    /// 两个时长的差值（毫秒）。任一未知 ⇒ nil（调用方按"不参与排序"处理）。
    static func lengthGap(_ candidateMs: Int?, _ trackMs: Int?) -> Int? {
        guard let candidateMs, candidateMs > 0, let trackMs, trackMs > 0 else { return nil }
        return abs(candidateMs - trackMs)
    }

    /// 主艺人：`A feat. B` / `A ft. B` / `A & B` 都取 `A`。
    ///
    /// 曲库那边的歌手字段常常把合作者全塞进来（`米津玄師 feat. 菅田将暉`），
    /// 而我们要匹配的是**主艺人** —— 用整串去比会把大部分合作曲都判成"不是同一首"。
    static func leadArtist(_ artist: String?) -> String {
        guard let artist else { return "" }
        for marker in [" feat", " ft.", " ft ", " featuring", " & "] {
            if let range = artist.range(of: marker, options: .caseInsensitive) {
                let head = String(artist[artist.startIndex..<range.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !head.isEmpty { return head }
            }
        }
        return artist
    }

    /// 名单里的署名与我们的艺人是否指同一个人。
    ///
    /// 判据是**互相包含**（去掉标点后），不是相等：曲库会写 `周杰伦`、`Jay Chou`、
    /// `Jay Chou (周杰倫)`，我们手上可能只有其中一个。
    static func sameArtist(_ credited: String?, _ artist: String?) -> Bool {
        let name = key(credited)
        let lead = key(leadArtist(artist))
        guard !name.isEmpty, !lead.isEmpty else { return false }
        return name.contains(lead) || lead.contains(name)
    }

    /// 时长是否在容差内。
    ///
    /// ⚠️ **任一方没有时长就视为通过**：本地文件、某些源的搜索响应不带时长，
    /// 因为"缺数据"就把整条候选否掉，会让这些场景一条都匹配不上。
    static func lengthMatches(_ candidateMs: Int?, _ trackMs: Int?, slackMs: Int) -> Bool {
        guard let candidateMs, candidateMs > 0, let trackMs, trackMs > 0 else { return true }
        return abs(candidateMs - trackMs) <= slackMs
    }
}
