import Foundation

// MARK: - LyricsMarkerConfiguration
//
// 「删除歌曲标注术语」的共享配置：Genius 与网易云两个歌词源共用同一份
// 术语清单，避免两处各自维护导致漂移。
//
// sectionMarkers 匹配前会做「去音调 + 大写」归一化，所以 REFRÃO /
// refrao / Pré-Refrão 都会归一到同一 token；因此这里一律写大写。

struct LyricsMarkerConfiguration {
    let sectionMarkers: [String]
    let metadataPrefixes: [String]
    let titlePrefixPatterns: [String]
    let titleHeaderPatterns: [String]

    static let shared = LyricsMarkerConfiguration(
        sectionMarkers: [
            "INTRO(DUCAO)?",
            "VERSE", "VERSO",
            "CHORUS", "REFRAO", "ПРИПЕВ",
            "PRE[- ]?CHORUS", "PRE[- ]?REFRAO",
            "POST?[- ]?CHORUS", "POS[- ]?REFRAO",
            "BRIDGE", "PONTE",
            "HOOK", "GANCHO",
            "INTERLUDE", "INTERLUDIO",
            "SOLO", "INSTRUMENTAL", "INSTRUMENTAL\\?", "\\?INSTRUMENTAL\\?",
            "FX", "SFX",
            "OUTRO", "ENCERRAMENTO",
            "DROP",
            "BREAK(DOWN)?",
            "FADE[ ]?OUT",
            "LOOP",
            "PRE[- ]?OUTRO",
            "PRE[- ]?SAIDA",
            "SAIDA",
            "RANN", "SEIST",
            "PRE[- ]?CORO", "CORO"
        ],
        metadataPrefixes: [
            "PRODUCED BY",
            "WRITTEN BY",
            "COMPOSED BY",
            "TRANSLATED BY",
            "注释"
        ],
        titlePrefixPatterns: [
            "TEKISUTO\\s+O\\s+LETRA DE",
            "LETRA DE",
            "TEXT OF"
        ],
        titleHeaderPatterns: [
            ".+[「『].+[」』]\\s*(?:KASHI|歌詞)"
        ]
    )
}

// MARK: - LyricsMarkerFilter
//
// 判定某一行是否属于「结构标注」而非歌词正文，供 Genius / 网易云复用。
// 匹配全部基于归一化文本（trim + 去音调 + 大写），因此大小写、重音不敏感。

enum LyricsMarkerFilter {

    private static let markerConfiguration = LyricsMarkerConfiguration.shared

    /// 章节标记模式：由 sectionMarkers 拼出的 alternation。
    private static let sectionMarkerPattern: String = {
        "(?:\(markerConfiguration.sectionMarkers.joined(separator: "|")))"
    }()

    /// 制作信息头（PRODUCED BY / WRITTEN BY / 注释 等），按字面转义。
    private static let metadataMarkerPattern: String = {
        let markers = markerConfiguration.metadataPrefixes.map {
            NSRegularExpression.escapedPattern(for: $0)
        }
        return "(?:\(markers.joined(separator: "|")))"
    }()

    private static let titlePrefixPattern: String = {
        "(?:\(markerConfiguration.titlePrefixPatterns.joined(separator: "|")))"
    }()

    private static let titleHeaderPattern: String = {
        "(?:\(markerConfiguration.titleHeaderPatterns.joined(separator: "|")))"
    }()

    private static let markerNumberSuffix = "(?:\\s+(?:N[. ]?)?\\d+(?:[.]\\d+)?)?"
    private static let repeatCountSuffix = "(?:\\s+X\\d+)?"

    /// 方括号内只有符号/标点（无字母、无数字）的行：[♪] [?] [□] [—] …
    private static let bracketedSymbolLinePattern =
        "^\\[\\s*[^\\p{L}\\p{N}]+\\s*\\]$"

    /// 无括号、整行只有符号的占位行：□ ? … — 等。
    /// 排除音乐符号（♪/♫/♬/♩/♭/♯）：那类行归**两个仓库各自的间奏判据**管
    /// （`NeteaseLyricsRepository.isInterludeRow` / `MusixmatchLyricsRepository.isMxmInterludeRow`，
    /// 起无条件整行丢弃），这里不再插一手 —— 两条规则同时删同一行只会让人看不懂是谁删的。
    private static let bareSymbolLinePattern =
        "^[^\\p{L}\\p{N}♪♫♬♩♭♯]+$"

    /// 尖括号占位行：**`<Music>`** / `<music>` / `<Instrumental>` 等。
    ///
    /// 为什么单列一条：网易云用 `<Music>` 当**间奏标记**，
    /// 而它既不是 `[方括号]` 也不是 `♪`，前面八条规则全都盖不住 ⇒ 我们把它当正文渲染，
    /// 的就是"歌词里混进一行 `<Music>`，跟着屏幕走"。
    /// 限长 24 个字符：真歌词里出现 `<...>` 包裹的长句子的可能性极低，而占位标记都很短。
    private static let angleBracketPlaceholderPattern =
        "^<\\s*[^<>]{1,24}\\s*>$"

    /// 归一化：trim + 去音调 + 大写，用于大小写/重音不敏感匹配。
    static func normalizedForMarkerMatch(_ line: String) -> String {
        return line
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: .diacriticInsensitive, locale: nil)
            .uppercased()
    }

    /// 该行是否为结构元数据（章节标记、制作信息、标题头、占位符号等）。
    static func isNonLyricLine(_ line: String) -> Bool {
        let normalized = normalizedForMarkerMatch(line)
        guard !normalized.isEmpty else { return false }

        // 1) 方括号章节标记：[Interlude] / [Verse 1] / [Fx] / [Instrumental?] …
        if normalized ~= "^\\[\\s*\(sectionMarkerPattern)\(markerNumberSuffix)(?:\\s*[:|\\-].*)?\\s*\\]\(repeatCountSuffix)$" {
            return true
        }

        // 2) 方括号制作信息头：[Produced by X] / [Written by X] / [注释 …]
        if normalized ~= "^\\[\\s*\(metadataMarkerPattern)(?:\\s+.*)?\\s*\\]$" {
            return true
        }

        // 3) 动态标题头：[Letra de “Song”] / [Text of “Song”]
        if normalized ~= "^\\[\\s*\(titlePrefixPattern)\\s*[\"'“‘].*[\"'”’]\\s*\\]$" {
            return true
        }

        // 4) 日语/罗马音标题头：[…「…」kashi]
        if normalized ~= "^\\[\\s*\(titleHeaderPattern)\\s*\\]$" {
            return true
        }

        // 5) 圆括号章节标记：(INTRO) / (OUTRO) / (PRE-OUTRO) …（不删任意括号旁白）
        if normalized ~= "^\\(\\s*\(sectionMarkerPattern)\(markerNumberSuffix)\\s*\\)$" {
            return true
        }

        // 6) 无括号的裸章节标记：VERSO / INTERLUDE / FX …
        if normalized ~= "^\(sectionMarkerPattern)\(markerNumberSuffix)\\s*:?\\s*$" {
            return true
        }

        // 7) 标题头行：LETRA DE "…" / TEXT OF "…"
        if normalized ~= "^\(titlePrefixPattern)\\s*[\"'“‘]" {
            return true
        }

        // 8) 方括号内纯符号行：[♪] [?] [□] [—] …（保留 [I love you] 这类真歌词）
        if normalized ~= bracketedSymbolLinePattern {
            return true
        }

        // 9) 无括号、整行只有符号的占位行（方框 / 问号 / 破折号等）
        if normalized ~= bareSymbolLinePattern {
            return true
        }

        // 10) 尖括号占位行：`<Music>` / `<Instrumental>` …（网易云的间奏标记）
        if normalized ~= angleBracketPlaceholderPattern {
            return true
        }

        // 11) 制作信息行：`作词 : 方文山` / `词：周杰伦` / `作词/作曲 : xxx`。
        // 判据与"顺手取出作词者"共用一份（见 `LyricsCreditLine`）。
        if LyricsCreditLine.isCreditLine(line) {
            return true
        }

        return false
    }

    /// 去除结构标注行并清理首尾空行。
    static func mapLyricsLines(_ rawLines: [String]) -> [String] {
        var lines = rawLines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        lines.removeAll { isNonLyricLine($0) }

        lines = Array(lines.drop(while: { $0.isEmpty }))
        while lines.last?.isEmpty == true {
            lines.removeLast()
        }

        return lines
    }
}

// MARK: - LyricsCreditLine
//
// 「作词 : 方文山」「词：周杰伦」这类**歌曲制作信息行**的共用判据 + 作词者提取。
//
// 三处必须用同一份：
// · `LyricsMarkerFilter.isNonLyricLine` —— Genius / 网易云 / AMLL TTML 的标注过滤；
// · QQ 音乐的 LRC / QRC 解析器、酷狗的 LRC / KRC 解析器 —— 这两条路**不**走
//   `LyricsMarkerFilter`，制作信息行会被当成正文歌词放到屏幕上（QQ 的官方词就是
//   `[00:02.25]词：周杰伦` 这样带时间戳下发的）；
// · 取词时的署名 —— 同一行顺带给出「作词 X」。
//
// 为什么不再用「关键字**紧邻**冒号」那条正则：QQ 的合并式写法（`作词/作曲 : xxx`）
// 冒号前是一串角色，紧邻式永远匹配不到 —— 网易云那边原本为此单独补了一段判据。
// 这里统一成"冒号前的每一段都得是已知角色关键字"。
enum LyricsCreditLine {

    /// 角色关键字（英文一律大写比较；中文不受大小写影响）。
    ///
    /// 匹配是**前缀**式的：`录音助理` / `混音工程` / `合声编写` 这类带后缀的行靠词根就能
    /// 认出来，不必把 QQ / 网易云真实出现过的后缀全枚举一遍（实测一份《晴天》里就有
    /// `录音助理：` `录音工程：` `混音工程：` `合声编写：` 四种）。
    /// 单字词根（词 / 詞 / 曲 / 鼓）例外 —— 它们只认**整段相等**，否则
    /// 「词不达意：…」这种真歌词会被误删。
    ///
    /// 这份清单原来长在 `NeteaseLyricsRepository` 里（只服务网易云），现在四方共用。
    private static let roleKeywords: Set<String> = [
        "作词", "作詞", "词", "詞", "曲", "作曲",
        "编曲", "編曲", "制作", "製作", "出品", "发行", "發行",
        "混音", "母带", "母帶", "录音", "錄音", "监制", "監製",
        "和声", "和聲", "合声", "合聲", "和音", "配唱",
        "吉他", "贝斯", "貝斯", "鼓", "键盘", "鍵盤", "钢琴", "鋼琴",
        "小提琴", "大提琴", "弦乐", "弦樂", "口琴", "打击乐", "打擊樂",
        "统筹", "統籌", "企划", "企劃", "策划", "策劃", "宣传", "宣傳",
        "推广", "推廣", "文案", "摄影", "攝影", "封面",
        "导演", "導演", "经纪人", "經紀人", "剪辑", "剪輯",
        "字幕", "翻译", "翻譯", "校对", "校對", "排版", "制谱", "製譜",
        "PROGRAM", "VOCAL", "LYRICS", "COMPOSER", "COMPOSED", "ARRANGER", "ARRANGED",
        "PRODUCER", "PRODUCED", "RECORD", "MIX", "MASTER", "REMIX", "WRITTEN"
    ]

    /// 「作词者」的角色名。合并式（`作词/作曲 : …`）**不取** —— 分不清名字对应哪个角色。
    private static let lyricistKeywords: Set<String> = [
        "作词", "作詞", "词", "詞", "LYRICIST", "WRITTEN BY", "LYRICS BY"
    ]

    /// 冒号前是角色（可能多个），冒号后是名字。
    struct Parsed {
        let roles: [String]
        let value: String
    }

    /// 这一段是不是已知角色（短词根按前缀匹配，单字词根按整段相等）。
    private static func isRole(_ segment: String, in keywords: Set<String>) -> Bool {
        let upper = segment.uppercased()
        return keywords.contains { keyword in
            keyword.count >= 2 ? upper.hasPrefix(keyword) : upper == keyword
        }
    }

    /// 这一行是制作信息吗；是就把"角色 + 名字"拆出来。
    ///
    /// 判据：冒号（半角/全角）前的每一段，用 `/ 、 · & ,` 切开后都得是已知角色关键字。
    /// 值可以为空（`作词：` 这种残行照样算制作信息，照样丢）。
    static func parse(_ text: String) -> Parsed? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let colon = trimmed.firstIndex(where: { $0 == ":" || $0 == "：" }) else {
            return nil
        }

        let roleText = trimmed[trimmed.startIndex..<colon]
        guard !roleText.isEmpty else { return nil }

        let roles = roleText
            .split(whereSeparator: { "/、·&,，".contains($0) })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !roles.isEmpty,
              roles.allSatisfy({ isRole($0, in: roleKeywords) }) else {
            return nil
        }

        let value = String(trimmed[trimmed.index(after: colon)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Parsed(roles: roles, value: value)
    }

    static func isCreditLine(_ text: String) -> Bool {
        parse(text) != nil
    }

    /// 这一行的作词者。以下情况一律 nil（宁可少一条署名，不要写错人）：
    /// · 不是制作信息行；
    /// · 合并式（`作词/作曲 : A`）—— 不知道 A 是哪一个角色；
    /// · 值里还有第二个冒号（`作词：A 作曲：B`）—— 同一行塞了两个角色。
    static func lyricist(in text: String) -> String? {
        guard let parsed = parse(text),
              parsed.roles.count == 1,
              let role = parsed.roles.first,
              isRole(role, in: lyricistKeywords),
              !parsed.value.isEmpty,
              !parsed.value.contains(":"),
              !parsed.value.contains("：") else {
            return nil
        }
        return parsed.value
    }

    /// 一整份歌词里第一个作词者（制作信息块通常在开头几行）。
    ///
    /// 行首的 LRC 标签要先剥掉：网易云给的是 `[00:00.00] 作词 : 方文山`，
    /// 直接解析会先把时间戳里的那个冒号当成冒号（角色变成 `[00`，永远匹配不上）。
    static func lyricist(inLyrics text: String) -> String? {
        for rawLine in text.components(separatedBy: .newlines) {
            if let name = lyricist(in: strippingLeadingTags(rawLine)) { return name }
        }
        return nil
    }

    /// 去掉行首连续的 `[…]` 标签（`[00:00.00]` / `[ti:…]` / `[ar:…]`）。
    private static func strippingLeadingTags(_ text: String) -> String {
        var line = text.trimmingCharacters(in: .whitespaces)
        while line.hasPrefix("["), let close = line.firstIndex(of: "]") {
            line = String(line[line.index(after: close)...]).trimmingCharacters(in: .whitespaces)
        }
        return line
    }
}
