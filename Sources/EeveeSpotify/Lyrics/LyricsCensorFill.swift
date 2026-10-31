import Foundation

// MARK: - 打码词回填（纯逻辑）
//
// 场景：SpicyLyrics 的上游会把**部分词和谐成星号**（`my **** line`）。回填的办法是
// 拿**同一首轨道**在另一个源里的文本找同一句，只把星号那几段换掉 —— 绝不按"常见脏词表"
// 硬塞（不同歌和谐的不是同一个词，硬塞会改坏本来没错的行）。
//
// 为什么比的是"同一句里的字面片段"，而不是整份文本的重合率：
// 这里身份是可靠的（同一 track id / 同一首歌查出来的），只是**局部**被涂掉了
// ⇒ 要判的只是"星号那一段该填什么"。所以用**行内字面锚点**，不是 n-gram 重合率。
//
// 上游那份（以及我们之前照搬的那份）检测正则是 `\b\*{3,}\b`，实测
// **只命中 `f***k` 这种"星号两侧都紧贴字母"的写法**：
// `\b` 要求星号两侧是"字词字符 ↔ 非字词字符"的过渡，而 `*` 本身不是字词字符
// ⇒ `my **** line` / `well **** me` / `**** you` **一个都匹配不上**，于是
// `guard lines.contains(where: containsFullCensor)` 直接提前返回 —— 整个功能等于没接线。
// 现在改成 `\*{3,}`（任意连续 3 个以上星号）。上游注释想排除的 `f**k` / `sh*t`
// 本来就只有 2 个和 1 个星号，仍被 3+ 这条规则挡住，所以语义没扩大。
//
// 本文件**只放纯逻辑**（无网络、无 DTO），`Tests/LyricsCensorFill` 能单独把它编进来跑。

enum LyricsCensorFill {

    /// 被和谐的星号段：**任意**连续 3 个以上星号。
    ///
    /// 不加 `\b`（理由见文件头）。也不管两侧是不是标点 —— `****,` / `****!` 都算。
    private static let censorPattern = try! NSRegularExpression(pattern: "\\*{3,}")

    /// 这一行里有没有被和谐的段。
    static func hasCensor(_ line: String) -> Bool {
        censorPattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }

    /// 把一行按星号段切成**字面片段**。
    ///
    /// `my **** line` ⇒ `["my ", " line"]`；`**** you` ⇒ `["", " you"]`；
    /// 行尾就是星号（`well ****`）⇒ `["well ", ""]`。
    ///
    /// 返回 `nil` 的两种情形（都表示"补不了，也别猜"）：
    /// · 这行没有星号段；
    /// · 字面片段加起来**不足 2 个字符**（`****`、`****!` 这种整行/近乎整行被打码的，
    /// 没有任何东西可以当锚点 —— 拿候选源的整行去填等于**凭空换掉一句歌词**）。
    static func literalSegments(of line: String) -> [String]? {
        let nsLine = line as NSString
        let matches = censorPattern.matches(
            in: line,
            range: NSRange(location: 0, length: nsLine.length)
        )
        guard !matches.isEmpty else { return nil }

        var segments: [String] = []
        var cursor = 0
        for match in matches {
            let length = match.range.location - cursor
            segments.append(nsLine.substring(with: NSRange(location: cursor, length: length)))
            cursor = match.range.location + match.range.length
        }
        segments.append(nsLine.substring(from: cursor))

        guard segments.joined().count >= 2 else { return nil }
        return segments
    }

    /// 在一行候选文本里，按"字面片段必须**依次**出现、星号段**非空**"取出被和谐的那几段。
    ///
    /// - 第一段必须是**前缀**，最后一段必须是**后缀**（行尾是星号时最后一段为空串）。
    /// - 中间的字面片段若为空串（两个星号段相邻）⇒ 无法定界 ⇒ 放弃。
    /// - 每段替换词至少 1 个字符。
    ///
    /// 用 `[Character]` 而不是 UTF-16 下标：中日韩歌词里一个字形可能由多个码位组成，
    /// 按下标切片容易把字切坏。
    static func middles(literalSegments: [String], in candidate: String) -> [String]? {
        let runs = literalSegments.count - 1
        guard runs >= 1 else { return nil }

        var rest = Array(candidate)
        let leading = Array(literalSegments[0])
        guard rest.count >= leading.count,
              Array(rest.prefix(leading.count)) == leading else { return nil }
        rest.removeFirst(leading.count)

        var middles: [String] = []
        for index in 1...runs {
            let literal = Array(literalSegments[index])
            if index == runs {
                // 最后一段：必须是后缀。行尾是星号时 `literal` 为空串，差集就是整段剩余。
                guard rest.count > literal.count,
                      Array(rest.suffix(literal.count)) == literal else { return nil }
                let middle = Array(rest.prefix(rest.count - literal.count))
                guard !middle.isEmpty else { return nil }
                middles.append(String(middle))
            } else {
                guard !literal.isEmpty else { return nil }
                guard let found = firstOccurrence(of: literal, in: rest, notBefore: 1) else { return nil }
                let middle = Array(rest[0..<found.lowerBound])
                guard !middle.isEmpty else { return nil }
                middles.append(String(middle))
                rest = Array(rest[found.upperBound...])
            }
        }
        return middles
    }

    /// 把取出的替换词填回字面片段之间。
    static func rebuild(literalSegments: [String], middles: [String]) -> String {
        guard !literalSegments.isEmpty else { return "" }
        var out = literalSegments[0]
        for (index, middle) in middles.enumerated() where index + 1 < literalSegments.count {
            out += middle
            out += literalSegments[index + 1]
        }
        return out
    }

    /// 用**同一首歌**在另一个源里的整份歌词，把 `lines` 里被打码的词补回来。
    ///
    /// 只回填"能唯一确定"的行，其余原样保留（宁留星号，不猜）。
    ///
    /// - Parameters:
    /// - lines: 打码的那份（SpicyLyrics）。
    /// - candidates: 候选源（未打码）的整份歌词行。
    /// - Returns: 新行文本 + 实际补回的行数。
    static func fill(lines: [String], withCandidates candidates: [String]) -> (lines: [String], resolved: Int) {
        guard !candidates.isEmpty else { return (lines, 0) }

        // 行数相同 ⇒ "同一行号"是最强信号（不同源的行切分多半一致）。
        let alignByIndex = candidates.count == lines.count
        var output = lines
        var resolved = 0

        for (index, line) in lines.enumerated() {
            guard let segments = literalSegments(of: line) else { continue }

            // ① 先试同一行号。
            if alignByIndex, index < candidates.count,
               let middles = middles(literalSegments: segments, in: candidates[index]) {
                output[index] = rebuild(literalSegments: segments, middles: middles)
                resolved += 1
                continue
            }

            // ② 否则在整份候选里找，且**替换词必须唯一** ——
            // 同一行可能出现在多处（副歌），若两个位置给出的替换词不同，
            // 说明锚点不够确定（例如 `**** you` 既能是 `I love you` 也能是 `thank you`），
            // 此时宁可留星号。
            var found = Set<[String]>()
            for candidate in candidates {
                guard let middles = middles(literalSegments: segments, in: candidate) else { continue }
                found.insert(middles)
                if found.count > 1 { break }
            }
            guard found.count == 1, let middles = found.first else { continue }
            output[index] = rebuild(literalSegments: segments, middles: middles)
            resolved += 1
        }

        return (output, resolved)
    }

    // MARK: - 私有
    //
    // 在 `haystack` 里找 `needle`，起点不早于 `notBefore`（保证前面至少留得出 1 个字符的替换词）。
    private static func firstOccurrence(
        of needle: [Character],
        in haystack: [Character],
        notBefore offset: Int
    ) -> Range<Int>? {
        guard !needle.isEmpty, haystack.count >= needle.count + offset else { return nil }
        var start = offset
        while start + needle.count <= haystack.count {
            if Array(haystack[start..<(start + needle.count)]) == needle {
                return start..<(start + needle.count)
            }
            start += 1
        }
        return nil
    }
}
