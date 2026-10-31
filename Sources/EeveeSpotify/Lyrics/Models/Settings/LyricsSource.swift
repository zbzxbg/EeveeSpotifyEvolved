import Foundation

enum LyricsSource: Int, CaseIterable, CustomStringConvertible {
    case genius
    case lrclib
    case musixmatch
    case petit
    case notReplaced
    // 新增分支追加在末尾，避免改变既有 rawValue 导致已存设置错位。
    case spicy
    case netease
    /// 自动优选：不是单一来源，而是按地区与时间轴质量排好序的一条链路。
    /// 作为来源选择器里的一项，与具体来源互斥。
    ///
    /// 取代原来的「多级回退」（`.multiLevel`）。
    /// **rawValue 保持 7 不变** —— 用户盘上存的就是这个整数，改名会把他们
    /// 已选的「多级回退」重置成默认来源。行为差异见 `LyricsAutoSelect` 文件头。
    case autoSelect
    /// AMLL：提供高质量逐词歌词与丰富的歌词结构（amll.dev）。
    /// 追加在末尾，避免改变既有 rawValue。
    case amllTtml
    /// Apple Music **官方** TTML（实验）。追加在末尾，避免改变既有 rawValue。
    ///
    /// **刻意不出现在 `allCases` 里** —— 它不是用户在来源选择器里挑的一项，
    /// 而是由「设置 → 实验 → 启用Apple Music官方TTML歌词」这个总开关**强制**启用的
    /// （那个开关的语义就是"忽略当前所有有关于歌词的设置"）。
    /// 所以它只会在 `CustomLyrics.loadCustomLyricsForCurrentTrack` 的覆盖分支里出现，
    /// rawValue 也永远不会被写进 `lyricsSource` 这个 UserDefault。
    case appleMusicOfficialTtml
    // 补上 Taurus 有、我们缺的四个源。同样**追加在末尾**，不改既有 rawValue。
    // BiniLyrics：社区收的 Apple Music 逐字 TTML，按名字搜。
    case bini
    /// Unison：人工打轴的 TTML，曲库小、质量高。
    case unison
    /// QQ 音乐：中文曲库，**行级**（逐字是加密的 QRC，这一轮不做）。
    case qqMusic
    /// 酷狗：中文曲库，**逐字**（KRC）。
    case kugou
    
    static var allCases: [LyricsSource] {
        return [
            .genius, .lrclib, .amllTtml, .musixmatch, .petit,
            .bini, .unison, .spicy, .netease, .qqMusic, .kugou,
            .autoSelect
        ]
    }

    // swift 5.8 compatible
    var description: String {
    switch self {
    case .genius:
        return "Genius"
    case .lrclib:
        return "LRCLIB"
    case .musixmatch:
        return "Musixmatch"
    case .petit:
        return "PetitLyrics"
    case .notReplaced:
        return "Spotify"
    case .spicy:
        // 连写的那版 `SpicyLyrics` 全部改成官方写法 `Spicy Lyrics`。
        // 这一串有三个去处：来源选择器的标签、署名兜底（`toSpotifyLyricsData` 的
        // `providedBy`）、以及日志。SL 的站点 / 条款 / attribution 文档一律写两词；
        // API 里的 `spicy_lyrics` 是**字段值**（标识符），不是展示名。
        return "Spicy Lyrics"
    case .netease:
        return "NetEase"
    case .autoSelect:
        return "lyrics_source_auto".localized
    case .amllTtml:
        return "AMLL"
    case .bini:
        return "BiniLyrics"
    case .unison:
        return "Unison"
    case .qqMusic:
        return "QQ Music"
    case .kugou:
        return "KuGou"
    case .appleMusicOfficialTtml:
        // 这是**提供者署名**（注入 payload 的 `providedBy` / 页脚那一行），不是源选择器的标签。
        //
        // 「如果歌词来源是苹果官方，显示为 Apple Inc.」——
        // 刻意**不写** "Apple Music"：署名行要的是版权方（Apple Inc.），
        // 与服务/产品名（Apple Music）区分开。实验开关那一行的文案不受影响。
        return "Apple Inc."
    }
    }

    /// 歌词偏移的**存储键**（`LyricsTimingOffset` 用，起）。
    ///
    /// 为什么不直接用 `description`：那一串是**展示名**，`autoSelect` 那一项还是
    /// 本地化串（`lyrics_source_auto.localized`）—— 用户换一次语言，
    /// 已保存的偏移就会全部对不上号。这里给每个源一个写死的英文标识，只进存储、不进 UI。
    var offsetStorageKey: String {
        switch self {
        case .genius: return "genius"
        case .lrclib: return "lrclib"
        case .musixmatch: return "musixmatch"
        case .petit: return "petit"
        case .notReplaced: return "spotify"
        case .spicy: return "spicy"
        case .netease: return "netease"
        // ⚠️ 这个字符串**不许跟着枚举一起改名**：它是起写进
        // `ngzhwm_lyricsOffsetBySourceAndTrack` 的键，改了等于把用户已存的偏移全丢掉。
        // "multiLevel" 是旧名字，保留它就是保留那些数据。
        case .autoSelect: return "multiLevel"
        case .amllTtml: return "amll"
        case .appleMusicOfficialTtml: return "appleMusic"
        case .bini: return "bini"
        case .unison: return "unison"
        case .qqMusic: return "qqmusic"
        case .kugou: return "kugou"
        }
    }

    /// 从 `offsetStorageKey` 反查（读已保存的偏移时用）。认不出就是脏数据 ⇒ nil。
    init?(offsetStorageKey key: String) {
        switch key {
        case "genius": self = .genius
        case "lrclib": self = .lrclib
        case "musixmatch": self = .musixmatch
        case "petit": self = .petit
        case "spotify": self = .notReplaced
        case "spicy": self = .spicy
        case "netease": self = .netease
        case "multiLevel": self = .autoSelect
        case "amll": self = .amllTtml
        case "appleMusic": self = .appleMusicOfficialTtml
        case "bini": self = .bini
        case "unison": self = .unison
        case "qqmusic": self = .qqMusic
        case "kugou": self = .kugou
        default: return nil
        }
    }
    
    /// 自动优选**排序页**用的键 —— 与 `offsetStorageKey` 同值，但语义独立：
    /// 那个是"歌词偏移存在哪个桶里"，这个是"用户在排序页里排的是谁"。
    /// 两者都必须是**写死的英文标识**：展示名会随语言变，存进去就成了脏数据。
    ///
    /// 不是"一个能取词的源"的三项返回 nil：`Spotify`（不替换）、`自动优选`（链路本身）、
    /// Apple Music 官方 TTML（实验开关，不进链路）。
    var orderKey: String? {
        switch self {
        case .notReplaced, .autoSelect, .appleMusicOfficialTtml:
            return nil
        default:
            return offsetStorageKey
        }
    }

    var isReplacingLyrics: Bool { self != .notReplaced }
    
    static var defaultSource: LyricsSource {
        Locale.isInRegion("JP", orHasLanguage: "ja")
            ? .petit
            : .spicy
    }
}
