import Foundation

/// 锁屏动效封面的"这张专辑是不是这一首"的判据。
///
/// 单独一个文件、只依赖 Foundation：`Tests/LockArtMatch` 会把它单独编进去跑断言
/// （本机没有 Swift 工具链，这类"匹配判据"只能靠 CI 编一次真跑一次）。
///
/// 现场（2026-11-27）：`REVIVE` / `NXRTHSTXR & MHMX` 的锁屏上放的是 IVE《REVIVE+》
/// 的动态封面。原因是当时只按专辑名搜、而且用"归一化后互相包含"比较 ——
/// `revive` 被 `revive+` 包含，于是同名专辑串了台，艺人一个字都没看。
enum LockArtworkMatch {

    /// 专辑名比较用的键：**保留 `+` 这类有意义的符号**，只剥掉发行形态后缀，最后要求**相等**。
    ///
    /// `REVIVE+` 是另一张专辑，不是 `REVIVE` 的另一版；`REVIVE - EP` 才是同一张。
    static func albumNameKey(_ text: String) -> String {
        var value = text.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ).lowercased()

        // 末尾带括号的版本修饰（"(Deluxe)" / "[Remastered]" …）：整段丢掉。
        while let closing = value.last, closing == ")" || closing == "]" {
            guard let opening = value.lastIndex(where: { $0 == "(" || $0 == "[" }) else { break }
            value = String(value[..<opening])
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // 发行形态后缀：`REVIVE - EP` 与 `REVIVE` 是同一张；`REVIVE+` 不是。
        let suffixPatterns = [
            "- single", "- ep", "- album", "- lp", "- ost", "- soundtrack",
            "- deluxe", "- deluxe edition", "- bonus track version",
            "(single)", "(ep)", "(album)", "[single]", "[ep]", "[album]",
        ]
        var stripped = true
        while stripped {
            stripped = false
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            for suffix in suffixPatterns where value.hasSuffix(suffix) {
                value = String(value.dropLast(suffix.count))
                value = value.trimmingCharacters(in: .whitespacesAndNewlines)
                stripped = true
            }
        }

        // 只留字母数字和 `+`：空格、破折号、`&` 这些不该参与比较。
        return String(value.filter { $0.isLetter || $0.isNumber || $0 == "+" })
    }

    static func sameAlbumName(_ lhs: String, _ rhs: String) -> Bool {
        let a = albumNameKey(lhs)
        let b = albumNameKey(rhs)
        guard !a.isEmpty, !b.isEmpty else { return false }
        return a == b
    }

    /// 艺人名拆成"有分辨力的词"。`NXRTHSTXR & MHMX` → {nxrthstxr, mhmx}；
    /// `feat.` / `ft.` / `with` / `and` 这类连接词没有分辨力，直接丢。
    static func artistTokens(_ text: String) -> Set<String> {
        let lowered = text.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ).lowercased()

        var separators = CharacterSet(charactersIn: "&,;/+×")
        separators.formUnion(.whitespacesAndNewlines)

        var tokens: Set<String> = []
        for piece in lowered.components(separatedBy: separators) {
            let token = String(piece.filter { $0.isLetter || $0.isNumber })
            // 单字符也要收：「A feat. B」里的两个人都是单字母。
            guard !token.isEmpty else { continue }
            guard !["feat", "ft", "with", "and", "the"].contains(token) else { continue }
            tokens.insert(token)
        }
        return tokens
    }

    /// 两位艺人**至少有一个词相同**。宽松匹配里用它挡住"同名不同人"：
    /// `NXRTHSTXR & MHMX` 与 `NXRTHSTXR` 通过，`IVE` 与 `NXRTHSTXR` 不通过。
    static func sharesArtistName(_ lhs: String, _ rhs: String) -> Bool {
        let a = artistTokens(lhs)
        let b = artistTokens(rhs)
        guard !a.isEmpty, !b.isEmpty else { return false }
        return !a.isDisjoint(with: b)
    }
}
