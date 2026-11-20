import Foundation

/// 一个候选导入文件（文件名 + 从元信息里读到的东西）。
struct ImportedLyricsCandidate: Equatable {
    var fileName: String
    var title: String?
    var artist: String?
    var durationMs: Int?
}

/// 文件名 `A - B` 的两种解释：谁是标题、谁是歌手。
struct ImportedLyricsFileNameGuess: Equatable {
    var title: String
    var artist: String?
}

/// 把当前曲目与导入文件对上号。
///
/// 只做比较、不碰文件系统：候选由调用方读出来（文件名 + 解析出的元信息），这里决定
/// "哪一个属于这首歌"。判据从强到弱，**任何一档不确定就不选**——选错一份歌词比没有更糟：
/// 同一首歌的翻唱、不同版本（Live / Remix）标题与时长都接近。
///
/// 顺序：
/// 1. 标题与艺人都对得上；
/// 2. 只有标题对得上、且候选根本没写歌手（很多文件没有 `[ar:]`）；
/// 3. 标题对得上 + 时长差 ≤ 3 s；
/// 4. 以上都不成立 ⇒ nil（交给用户手动指定）。
enum ImportedLyricsMatcher {

    /// 文件名 → 候选的 (title, artist) 解释。`A - B` 两序都返回，由打分决定谁对。
    /// 没有分隔符时只当标题，歌手 nil。
    static func fileNameGuesses(_ fileName: String) -> [ImportedLyricsFileNameGuess] {
        let base = (fileName as NSString).deletingPathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return [] }

        for separator in [" - ", " – ", " — "] {
            let parts = base.components(separatedBy: separator)
            guard parts.count >= 2 else { continue }
            let first = parts[0].trimmingCharacters(in: .whitespaces)
            let second = parts.dropFirst().joined(separator: separator)
                .trimmingCharacters(in: .whitespaces)
            guard !first.isEmpty, !second.isEmpty else { continue }
            return [
                ImportedLyricsFileNameGuess(title: second, artist: first),
                ImportedLyricsFileNameGuess(title: first, artist: second),
            ]
        }
        // 只有连字符（`A - B` 之外的 `A-B`）：按最后一个连字符拆，同样两序。
        if let range = base.range(of: "-", options: .backwards) {
            let first = String(base[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            let second = String(base[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !first.isEmpty, !second.isEmpty {
                return [
                    ImportedLyricsFileNameGuess(title: second, artist: first),
                    ImportedLyricsFileNameGuess(title: first, artist: second),
                ]
            }
        }
        return [ImportedLyricsFileNameGuess(title: base, artist: nil)]
    }

    /// 归一化：大小写、全角空格、括号里的版本注记（`(Live)` / `【Remix】`）、`feat.` 尾巴。
    static func normalize(_ raw: String) -> String {
        var text = raw.replacingOccurrences(of: "\u{3000}", with: " ")
        text = text.replacingOccurrences(of: "\u{FF08}", with: "(")
        text = text.replacingOccurrences(of: "\u{FF09}", with: ")")
        text = text.replacingOccurrences(of: "\u{3010}", with: "(")
        text = text.replacingOccurrences(of: "\u{3011}", with: ")")
        text = stripBracketed(text)
        for marker in [" feat.", " ft."] {
            if let range = text.range(of: marker, options: [.caseInsensitive]) {
                text = String(text[..<range.lowerBound])
            }
        }
        return text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    /// 去掉所有成对括号（含内容）。不成对的括号原样保留 —— 宁可少删，不可错删。
    private static func stripBracketed(_ text: String) -> String {
        var result = ""
        var depth = 0
        for character in text {
            switch character {
            case "(", "[", "{":
                depth += 1
            case ")", "]", "}":
                if depth > 0 { depth -= 1 }
            default:
                if depth == 0 { result.append(character) }
            }
        }
        return result
    }

    /// 返回最佳候选的下标；没有把握时返回 nil。
    static func bestMatch(
        candidates: [ImportedLyricsCandidate],
        title: String,
        artists: [String],
        durationMs: Int?
    ) -> Int? {
        let wantedTitle = normalize(title)
        guard !wantedTitle.isEmpty else { return nil }
        let wantedArtists = Set(artists.map(normalize).filter { !$0.isEmpty })

        var best: (index: Int, score: Int)?
        for (index, candidate) in candidates.enumerated() {
            let guesses = fileNameGuesses(candidate.fileName)
            let candidateTitles = ([candidate.title].compactMap { $0 } + guesses.map(\.title))
                .map(normalize)
                .filter { !$0.isEmpty }
            let candidateArtists = ([candidate.artist].compactMap { $0 } + guesses.compactMap(\.artist))
                .map(normalize)
                .filter { !$0.isEmpty }

            let titleExact = candidateTitles.contains(wantedTitle)
            let titleContains = candidateTitles.contains {
                $0.contains(wantedTitle) || wantedTitle.contains($0)
            }
            guard titleExact || titleContains else { continue }

            let artistMatches = !wantedArtists.isEmpty
                && !Set(candidateArtists).isDisjoint(with: wantedArtists)
            let durationClose: Bool = {
                guard let durationMs, let candidateDuration = candidate.durationMs else { return false }
                return abs(candidateDuration - durationMs) <= 3_000
            }()

            // 歌手对不上、且时长也不接近：这一份不是同一首歌。
            if !artistMatches, !candidateArtists.isEmpty, !durationClose { continue }
            // 只靠"标题包含"、没有歌手也没有时长证据：不选，宁可手动指定。
            if !titleExact, !artistMatches, !durationClose { continue }

            var score = titleExact ? 4 : 1
            if artistMatches {
                score += 4
            } else if candidateArtists.isEmpty {
                score += 1
            }
            if durationClose { score += 2 }

            if best == nil || score > best!.score {
                best = (index, score)
            }
        }
        return best?.index
    }
}
