import Foundation

// MARK: - AMLL 整行罗马字 → 逐词分组
//
// AMLL 的 `x-roman` 是**整行**一条（不是逐词组），所以「官方罗马字」那一行以前只能静态
// 显示；KRC 的 `[language:]` 才有逐词组。这里把整行罗马字按**原文分词**切成逐词组：
//
// 1. 分词用 `String.japaneseRomajiChunks()`（与本地罗马化同一条 CFStringTokenizer 路径），
//    每个 chunk 有原文区间与自己的罗马字；
// 2. 本地 chunk 拼出的字母序列与官方整行（忽略空白/大小写）一致时，说明两者只是空格切分
//    不同 —— 按 chunk 的字母数从官方串里切出对应片段，**文本仍用官方那份**；
// 3. 每个 chunk 的文本挂到它覆盖的**第一个词**上（`words` 是 AMLL 的音节时间轴），
//    其余词留空。渲染层按词的时间点亮，效果就是「整词跟唱」；组文本拼起来仍等于官方整行。
//
// 非日语没有日文分词：退化成"按空格切词，词数 == `words` 数才用"。都不成立时返回 nil，
// 调用方保持原来的静态画法。
//
// ⚠️ 输出数组的长度恒等于 `words.count`，组文本可以为空（只在该词不在任何 chunk 起点时）。
// 渲染层（`LyricLinesAdapter.romanizationSyllables`）会跳过空组，但要求组数 == 词数。
enum AmllRomanizationWords {

    /// 一个原文分词：`range` 是原文（`words` 拼起来的那行）的 UTF-16 区间。
    struct Chunk {
        var range: NSRange
        var romaji: String
    }

    /// 返回每个词一组罗马字；`nil` = 这一行无法可靠切分，保持静态。
    static func groups(
        officialLine: String,
        words: [LyricsWordDto],
        chunks: [Chunk]
    ) -> [String]? {
        let official = officialLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !official.isEmpty, !words.isEmpty else { return nil }

        // 这一行原文里每个词占的 UTF-16 区间（`words` 拼起来 == 原文）。
        var wordRanges: [NSRange] = []
        var wordOffset = 0
        for word in words {
            let length = (word.text as NSString).length
            wordRanges.append(NSRange(location: wordOffset, length: length))
            wordOffset += length
        }

        if let chunked = chunkGroupsByLetters(
            official: official,
            words: words,
            wordRanges: wordRanges,
            chunks: chunks
        ) {
            return chunked
        }
        if let chunked = chunkGroupsByMora(
            official: official,
            words: words,
            wordRanges: wordRanges,
            chunks: chunks
        ) {
            return chunked
        }
        return tokenGroups(official: official, words: words)
    }

    // MARK: - 日文分词路：字母对得上

    private static func chunkGroupsByLetters(
        official: String,
        words: [LyricsWordDto],
        wordRanges: [NSRange],
        chunks: [Chunk]
    ) -> [String]? {
        let officialLetters = Array(official).filter { !$0.isWhitespace }
        guard !officialLetters.isEmpty else { return nil }

        // 只有带字母的 chunk 参与（空白 gap 的 romaji 是空白）。
        var lettersByChunk: [(chunkIndex: Int, text: [Character])] = []
        for (index, chunk) in chunks.enumerated() {
            let letters = Array(chunk.romaji).filter { !$0.isWhitespace }
            guard !letters.isEmpty else { continue }
            lettersByChunk.append((index, letters))
        }
        guard !lettersByChunk.isEmpty else { return nil }

        let localLetters = lettersByChunk.flatMap { $0.text }
        guard String(officialLetters).lowercased() == String(localLetters).lowercased() else {
            return nil
        }

        // 每个 chunk 在"字母序列"里的起止（gap 不占字母）。
        var letterRanges: [(chunkIndex: Int, start: Int, end: Int)] = []
        var cursor = 0
        for item in lettersByChunk {
            letterRanges.append((item.chunkIndex, cursor, cursor + item.text.count))
            cursor += item.text.count
        }

        // 字母下标 → 官方字符串下标（跳过空白，空白留在切片里）。
        var letterIndices: [String.Index] = []
        var index = official.startIndex
        while index < official.endIndex {
            if !official[index].isWhitespace { letterIndices.append(index) }
            index = official.index(after: index)
        }
        guard letterIndices.count == officialLetters.count else { return nil }

        var groups = Array(repeating: "", count: words.count)
        var lastWordIndex = 0
        for (number, item) in letterRanges.enumerated() {
            let chunk = chunks[item.chunkIndex]
            let wordIndex = firstWordIndex(for: chunk.range, in: wordRanges) ?? lastWordIndex
            guard wordIndex >= 0, wordIndex < groups.count else { return nil }

            let start = letterIndices[item.start]
            let end = number + 1 < letterRanges.count
                ? letterIndices[letterRanges[number + 1].start]
                : official.endIndex
            let text = String(official[start..<end])
            groups[wordIndex] += text
            lastWordIndex = wordIndex
        }

        guard groups.contains(where: { !$0.isEmpty }) else { return nil }
        return groups
    }

    // MARK: - 日文分词路：字母对不上时按"音拍数"切

    /// 本地分词与官方拼写不一致（读音选择/促音写法不同）时，仍然按**音拍数**切：
    /// 两边的音拍数加起来应该等于官方的空格 token 数。这只决定"哪几个 token 属于哪个
    /// 分词"，文本仍从官方串里切，所以不会把本地读音混进显示。
    private static func chunkGroupsByMora(
        official: String,
        words: [LyricsWordDto],
        wordRanges: [NSRange],
        chunks: [Chunk]
    ) -> [String]? {
        let tokens = tokenRanges(in: official)
        guard !tokens.isEmpty else { return nil }

        var chunksWithMora: [(chunkIndex: Int, mora: Int)] = []
        for (index, chunk) in chunks.enumerated() {
            let mora = moraCount(chunk.romaji)
            guard mora > 0 else { continue }
            chunksWithMora.append((index, mora))
        }
        guard !chunksWithMora.isEmpty,
              chunksWithMora.reduce(0, { $0 + $1.mora }) == tokens.count else {
            return nil
        }

        var groups = Array(repeating: "", count: words.count)
        var tokenCursor = 0
        var lastWordIndex = 0
        for (number, item) in chunksWithMora.enumerated() {
            let chunk = chunks[item.chunkIndex]
            let wordIndex = firstWordIndex(for: chunk.range, in: wordRanges) ?? lastWordIndex
            guard wordIndex >= 0, wordIndex < groups.count else { return nil }

            guard tokenCursor < tokens.count else { return nil }
            let start = tokens[tokenCursor].lowerBound
            tokenCursor += item.mora
            guard tokenCursor <= tokens.count else { return nil }
            let end = number + 1 < chunksWithMora.count && tokenCursor < tokens.count
                ? tokens[tokenCursor].lowerBound
                : official.endIndex
            groups[wordIndex] += String(official[start..<end])
            lastWordIndex = wordIndex
        }

        guard tokenCursor == tokens.count,
              groups.contains(where: { !$0.isEmpty }) else { return nil }
        return groups
    }

    /// 日文罗马字的音拍数（近似）：元音各一拍；拨音 `n` 一拍；促音（同一个辅音连写）一拍。
    /// 长音符（ā/ī/ū/ē/ō）按元音算；标点/空格不算。
    static func moraCount(_ romaji: String) -> Int {
        let vowels = Set("aeiouāīūēō")
        let letters = Array(romaji.lowercased()).filter { $0.isLetter }
        var count = 0
        for index in letters.indices {
            let character = letters[index]
            let next = index + 1 < letters.count ? letters[index + 1] : nil
            let previous = index > 0 ? letters[index - 1] : nil

            if vowels.contains(character) {
                count += 1
                continue
            }
            if character == "n" {
                // 拨音：后面不是元音/ya 行，或者后面紧跟另一个 n（onna 的第一颗 n）。
                if next == "n" {
                    count += 1
                } else if next == nil || (!vowels.contains(next!) && next != "y") {
                    count += 1
                }
                continue
            }
            if let previous, previous == character, character != "n" {
                // 促音：同一个辅音连写（kitte / gakkou）。n 已在上面的拨音分支处理。
                count += 1
            }
        }
        return count
    }

    /// 某个原文区间覆盖到的第一个词；区间落在词间空白/标点上时返回 nil。
    private static func firstWordIndex(for range: NSRange, in wordRanges: [NSRange]) -> Int? {
        guard range.length > 0 else { return nil }
        for (index, wordRange) in wordRanges.enumerated()
        where NSIntersectionRange(range, wordRange).length > 0 {
            return index
        }
        return nil
    }

    // MARK: - 通用退路：按空格切词

    private static func tokenRanges(in official: String) -> [Range<String.Index>] {
        var tokens: [Range<String.Index>] = []
        var index = official.startIndex
        while index < official.endIndex {
            while index < official.endIndex, official[index].isWhitespace {
                index = official.index(after: index)
            }
            let start = index
            while index < official.endIndex, !official[index].isWhitespace {
                index = official.index(after: index)
            }
            if start < index { tokens.append(start..<index) }
        }
        return tokens
    }

    private static func tokenGroups(official: String, words: [LyricsWordDto]) -> [String]? {
        let tokens = tokenRanges(in: official)
        guard tokens.count == words.count else { return nil }

        var groups = Array(repeating: "", count: words.count)
        for tokenIndex in tokens.indices {
            let start = tokens[tokenIndex].lowerBound
            let end = tokenIndex + 1 < tokens.count
                ? tokens[tokenIndex + 1].lowerBound
                : official.endIndex
            groups[tokenIndex] = String(official[start..<end])
        }
        return groups
    }
}
