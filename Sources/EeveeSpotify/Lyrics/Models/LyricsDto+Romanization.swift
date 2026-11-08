// 罗马音那一族 `String` 扩展（切分 / 拼接 / 假名表）。从 `LyricsDto.swift` 原样拆出。
import Foundation
import NaturalLanguage

extension String {
    /// 优先用整首歌占比检测出的语言（songLanguage，所有源统一），
    /// 否则回退到逐行识别（hint 前缀 → 含假名 → dominantLanguage）。
    func romanizedIfEnabled(languageHint: String? = nil, songLanguage: NLLanguage? = nil) -> String {
        if let songLanguage {
            return romanizeLine(self, as: songLanguage)
        }

        let normalizedHint = languageHint?.lowercased()
        let language: NLLanguage?

        if normalizedHint?.hasPrefix("ja") == true {
            language = .japanese
        } else if normalizedHint?.hasPrefix("ko") == true {
            language = .korean
        } else if normalizedHint?.hasPrefix("zh") == true {
            language = .simplifiedChinese
        } else if unicodeScalars.contains(where: { scalar in
            switch scalar.value {
            case 0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9D:
                return true
            default:
                return false
            }
        }) {
            language = .japanese
        } else {
            language = NLLanguageRecognizer.dominantLanguage(for: self)
        }

        guard let language else {
            return self
        }

        return romanizeLine(self, as: language)
    }
}

// MARK: - Japanese Romanization
//
// 假名那一段的实现在 `JapaneseKanaRomanization.swift`（全仓唯一一份）：
// 平/片假名归一、促音、拗音、外来音（`ティ` `ファ` `ヴァ` …）、`ん` 的隔音符都在那里。
// 本文件只管**分词**：什么时候查假名表、什么时候问 CFStringTokenizer 要汉字读音、空格加在哪。
extension String {
    /// 把日语（假名+汉字）转为罗马字：
    /// - 假名部分走 `japaneseKanaRomaji`（促音/拗音/外来音/长音/拨音，无怪符号）；
    /// - 汉字部分用 CFStringTokenizer 取读音，遇到拼音回退时保留原文；
    /// - 分写按语法：助词前加空格，活用后缀黏连。
    func toJapaneseRomaji() -> String {
        guard !isEmpty else { return self }

        let cfText = self as CFString
        let length = CFStringGetLength(cfText)
        let locale = NSLocale(localeIdentifier: "ja") as CFLocale

        let options: CFOptionFlags = kCFStringTokenizerUnitWordBoundary
            | kCFStringTokenizerAttributeLatinTranscription

        let tokenizer = CFStringTokenizerCreate(
            kCFAllocatorDefault, cfText, CFRangeMake(0, length), options, locale
        )

        func substring(_ range: CFRange) -> String {
            guard range.length > 0,
                  let cf = CFStringCreateWithSubstring(kCFAllocatorDefault, cfText, range)
            else { return "" }
            return cf as String
        }

        var result = ""
        var cursor: CFIndex = 0
        var pendingGeminate = false
        var hasToken = false
        /// 上一颗是「お / ご」⇒ 下一个词黏住（`おいで`）。
        var lastWasPrefix = false

        func appendGap(upTo location: CFIndex) {
            guard location > cursor else { return }
            let gap = japaneseNormalizedGap(substring(CFRangeMake(cursor, location - cursor)))
            result += gap
            cursor = location
            // 中间真有字符（空格 / 标点）时，"前缀"关系就断了。
            if !gap.isEmpty { lastWasPrefix = false }
        }

        func needsSpaceBeforeToken(_ original: String) -> Bool {
            guard hasToken, let last = result.last else { return false }
            if last.isWhitespace || last.isNewline { return false }
            if japaneseSpaceSeparators.contains(last) { return false }
            // 收尾标点 / 连字符 / 撇号前面不加空格（`(Hey uh)`、`Nah-nah`、`ain't`）。
            if let first = original.first, japaneseNoSpaceBefore.contains(first) { return false }
            // 敬语前缀后面黏住（`おいで` → oide）。
            if lastWasPrefix { return false }
            // 单假名 / 促音·小假名开头 ⇒ 是上一个词的尾巴（`ひとつ`、`だって`）。
            if japaneseGluesToPrevious(original) { return false }
            return true
        }

        func appendToken(_ romaji: String, original: String) {
            guard !romaji.isEmpty else { return }
            let glue = japaneseInflectionSuffixes.contains(original)
            if !glue, needsSpaceBeforeToken(original) {
                result += " "
            }
            result += romaji
            hasToken = true
            lastWasPrefix = japanesePrefixes.contains(original)
        }

        var tokenType = CFStringTokenizerAdvanceToNextToken(tokenizer)
        while !tokenType.isEmpty {
            let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            appendGap(upTo: range.location)

            let original = substring(range)

            // CFStringTokenizer 会把全角空格（U+3000）等空白当成独立 token 返回；
            // 空白本身无需罗马化，直接跳过，词间空格统一交给 appendToken 的语法分写。
            if original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                cursor = range.location + range.length
                tokenType = CFStringTokenizerAdvanceToNextToken(tokenizer)
                continue
            }

            // 取转写只在"含日文字符"时才做：纯拉丁 token（`around`、`'t`）ICU 也会给一个
            // 片假名读音（`araundo`、`ton`），那条路现在由 `japaneseTokenRomaji` 原样透传。
            var transcription: String?
            if japaneseTokenKind(original) == .japanese {
                transcription = CFStringTokenizerCopyCurrentTokenAttribute(
                    tokenizer, kCFStringTokenizerAttributeLatinTranscription
                ) as? String
            }

            // 假名 / 汉字 / 拉丁三条路 + 汉字读音修正 + 跨 token 促音，全在 `japaneseTokenRomaji` 里。
            var romaji = japaneseTokenRomaji(
                original, transcription: transcription, pendingGeminate: &pendingGeminate
            )

            // 助词 は/へ 的特殊读音
            if japaneseParticles.contains(original) {
                romaji = japaneseParticleOverrides[original] ?? romaji
            }

            appendToken(romaji, original: original)

            cursor = range.location + range.length
            tokenType = CFStringTokenizerAdvanceToNextToken(tokenizer)
        }
        appendGap(upTo: length)

        return result
    }

    /// 把行首第一个字母大写；「xxx」这类以开括号/引号/空白/零宽字符开头的行会跳过
    /// 这些装饰/隐形前缀，大写其后的第一个字母，其余字母保持原样。
    /// 其它非字母开头（省略号、数字、♪ 等）整行原样返回，避免误大写续行。
    func capitalizingFirstLetterIfAlphabetic() -> String {
        let leadingDecorations: Set<Character> = [
            // 开括号 / 引号 / 装饰符号
            "「", "『", "（", "(", "【", "[", "《", "〈", "〖", "〔", "〘", "«", "‹", "｢",
            "\"", "'", "`", "・", "･",
            // 空白与零宽/隐形字符
            " ", "\u{3000}", "\u{00A0}", "\u{2007}", "\u{202F}",
            "\u{200B}", "\u{FEFF}", "\u{200C}", "\u{200D}", "\u{2060}"
        ]
        var index = startIndex
        while index < endIndex, leadingDecorations.contains(self[index]) {
            index = self.index(after: index)
        }
        guard index < endIndex, self[index].isLetter else { return self }
        let afterLetter = self.index(after: index)
        return String(self[..<index])
            + String(self[index]).uppercased()
            + String(self[afterLetter...])
    }
}

// MARK: - DTO 落地时的显示规范化（空白行 + 大小写）
//
// 这个 extension 里是两个**落地**动作 —— 丢掉空白行、行首字母大写。
// `capitalizingFirstLettersForDisplay` 是 `CustomLyrics.storeLyricsDto` 唯一的落地调用点
// （拿到的 dto 就在那一刻进 `currentLyricsDto`），所以两个动作都挂在它身上：
// 七个仓库不可能各写一遍"筛空行"。

extension String {
    /// 把整行日文按 CFStringTokenizer 分词，返回每个 token/间隙的（原文、罗马字、区间、前导空格）。
    /// 与 toJapaneseRomaji 共用同一套分词与助词逻辑，但保留逐 token 数据，供逐字对齐。
    func japaneseRomajiChunks() -> [JapaneseRomajiChunk] {
        guard !isEmpty else { return [] }
        let cfText = self as CFString
        let length = CFStringGetLength(cfText)
        let locale = NSLocale(localeIdentifier: "ja") as CFLocale
        let options: CFOptionFlags = kCFStringTokenizerUnitWordBoundary
            | kCFStringTokenizerAttributeLatinTranscription
        let tokenizer = CFStringTokenizerCreate(
            kCFAllocatorDefault, cfText, CFRangeMake(0, length), options, locale
        )

        func substring(_ range: CFRange) -> String {
            guard range.length > 0,
                  let cf = CFStringCreateWithSubstring(kCFAllocatorDefault, cfText, range)
            else { return "" }
            return cf as String
        }

        var chunks: [JapaneseRomajiChunk] = []
        var cursor: CFIndex = 0
        var pendingGeminate = false
        var hasToken = false
        var lastOutputChar: Character?
        /// 上一颗是「お / ご」⇒ 下一个词黏住（与 `toJapaneseRomaji` 同一套规则）。
        var lastWasPrefix = false

        func addGap(_ range: CFRange) {
            guard range.length > 0 else { return }
            let gap = substring(range)
            let normalized = japaneseNormalizedGap(gap)
            chunks.append(JapaneseRomajiChunk(original: gap, romaji: normalized, range: range, leadingSpace: false))
            lastOutputChar = normalized.last
            if !normalized.isEmpty { lastWasPrefix = false }
        }

        var tokenType = CFStringTokenizerAdvanceToNextToken(tokenizer)
        while !tokenType.isEmpty {
            let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)

            addGap(CFRangeMake(cursor, range.location - cursor))

            let original = substring(range)

            // 同上：跳过 CFStringTokenizer 返回的纯空白 token（如全角空格 U+3000），
            // 避免空白以 token 形式进入 chunk 后被逐字对齐拼成多余空格。
            if original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                cursor = range.location + range.length
                tokenType = CFStringTokenizerAdvanceToNextToken(tokenizer)
                continue
            }

            // 与 `toJapaneseRomaji` 同一条路：纯拉丁 token 不取转写，汉字读音修正与
            // 跨 token 促音都由 `japaneseTokenRomaji` 统一处理。
            var transcription: String?
            if japaneseTokenKind(original) == .japanese {
                transcription = CFStringTokenizerCopyCurrentTokenAttribute(
                    tokenizer, kCFStringTokenizerAttributeLatinTranscription
                ) as? String
            }

            var romaji = japaneseTokenRomaji(
                original, transcription: transcription, pendingGeminate: &pendingGeminate
            )

            if japaneseParticles.contains(original) {
                romaji = japaneseParticleOverrides[original] ?? romaji
            }

            var leadingSpace = false
            if hasToken, let last = lastOutputChar,
               !last.isWhitespace, !last.isNewline,
               !japaneseSpaceSeparators.contains(last),
               !(original.first.map { japaneseNoSpaceBefore.contains($0) } ?? false),
               !lastWasPrefix,
               !japaneseGluesToPrevious(original),
               !japaneseInflectionSuffixes.contains(original) {
                leadingSpace = true
            }

            if !romaji.isEmpty {
                chunks.append(JapaneseRomajiChunk(
                    original: original, romaji: romaji, range: range, leadingSpace: leadingSpace
                ))
                hasToken = true
                lastOutputChar = romaji.last
                lastWasPrefix = japanesePrefixes.contains(original)
            }

            cursor = range.location + range.length
            tokenType = CFStringTokenizerAdvanceToNextToken(tokenizer)
        }
        addGap(CFRangeMake(cursor, length - cursor))

        return chunks
    }
}

// MARK: - Chinese & Korean Romanization

extension String {
    /// 使用系统 ICU 转写引擎（Han-Latin）把中文（简/繁）转为带声调拼音。
    /// 中文不存在日语汉字那种多音字歧义问题（每行已经过 NLLanguageRecognizer
    /// 确认是中文），所以可以直接用系统的 .toLatin，不需要像日语那样自己分词。
    func toChinesePinyin() -> String {
        guard !isEmpty else { return self }
        return self.applyingTransform(.toLatin, reverse: false) ?? self
    }

    /// 使用系统 ICU 转写引擎把韩文谚文转为罗马字（Revised Romanization）。
    /// 谚文是表音文字，一个字符对应固定读音，没有多音字问题，
    /// 同样可以直接用系统的 .toLatin。
    func toKoreanRomaja() -> String {
        guard !isEmpty else { return self }
        return self.applyingTransform(.toLatin, reverse: false) ?? self
    }
}

// MARK: - 逐字 overlay 的罗马化
