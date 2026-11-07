import Foundation

/// 酷狗 KRC `[language:]` type 0（官方罗马字）的假名 / 汉字残留修复。
///
/// 那一条是逐词罗马字，正常只该有拉丁字母；酷狗没转全的部分原样留着原文：
/// 促音 っ/ッ 与长音 ー 各自占一个词（`ずっと` → `["zu ", "っ", "to  "]`，拼成 `zu っto`），
/// 汉字整组留着（`["ai ", "no ", "kalada ", "温", "to "]`）。
///
/// 必须在**组**这一层修：显示层要求 `groups.count == words.count`
/// （见 `KrcText.romanizedWordGroups`），只改行级字符串会让它整份退回整行罗马字。
///
/// 规则：纯促音组把双写辅音放进本组、清掉上一组尾随空白（`zu っto` → `zutto`）；
/// 纯长音组把元音并到上一组末尾、本组留空（`e ko ー ha` → `e koo ha`）；其余组假名按
/// 假名表转写、**汉字直接丢掉**、拉丁与标点原样保留；转不出的假名同样丢掉。
///
/// 契约：返回串里不出现假名也不出现汉字（`repairedWordGroups` 最后再查一遍，查出即整份
/// 返回 nil，让显示层退回本地转换）。
///
/// ⚠️ 汉字丢而不读音：读音要 CFStringTokenizer（含 NaturalLanguage），本文件是纯
/// Foundation、跑在取词解析层，没有分词上下文，硬读会把多音字读错（`温` 在 `体温` 里是
/// `on`）。加上"组数必须等于词数"不能删组，清空是唯一选择。
///
/// ⚠️ 假名表**不再有第二份**：2026-11-08 起统一在 `JapaneseKanaRomanization.swift`
/// （`japaneseKanaMap` / `japaneseKanaCombos` / `japaneseKanaRomaji`）。本文件只传一个
/// `unmapped: .drop` 的策略 —— 以前这里抄了一份表、注释写着"两处必须同步"，
/// 那正是"官方那行对、本地那行错"的来源。`Tests/KuGouRomaji` 现在连同那个文件一起编。
enum JapaneseRomajiRepair {

    // MARK: - 对外

    /// 修一整批行（每行一组词）。
    ///
    /// 返回 nil 表示修完仍有假名 / 汉字残留（按构造不该发生）—— 调用方据此当作
    /// "没有官方罗马字"，让显示层退回本地转换，而不是把原文画到罗马字那一行。
    static func repairedWordGroups(_ rows: [[String]]) -> [[String]]? {
        var out: [[String]] = []
        out.reserveCapacity(rows.count)
        for row in rows {
            let repaired = repairedRow(row)
            guard !repaired.contains(where: { containsKana($0) || containsHan($0) }) else {
                return nil
            }
            out.append(repaired)
        }
        return out
    }

    /// 这段文本里有假名吗。
    ///
    /// 范围刻意**剔掉** U+30A0（゠）与 U+30FB（・）：它们在 Unicode 区块里与假名相邻，
    /// 但是标点 —— 当假名处理会把 `・` 从罗马字那一行里删掉（酷狗用 `・` 做分隔确实出现过）。
    static func containsKana(_ text: String) -> Bool {
        text.unicodeScalars.contains { isKanaScalar($0.value) }
    }

    /// 这段文本里有汉字（Han ideograph）吗。
    ///
    /// 范围与 `KrcText.hanRatio` 同一套（扩展 A / 基本区 / 兼容区 / 扩展 B 及以后）：
    /// 那个比例闸用来挡韩文谐音轨，判据必须口径一致。
    /// 刻意**不含** U+3005（々）这类 CJK 符号：Unicode 类别不同（Lm），不是汉字。
    static func containsHan(_ text: String) -> Bool {
        text.unicodeScalars.contains { isHanScalar($0.value) }
    }

    // MARK: - 逐行修复

    private static func repairedRow(_ groups: [String]) -> [String] {
        guard !groups.isEmpty else { return groups }

        var leading: [String] = []
        var core: [String] = []
        var trailing: [String] = []
        leading.reserveCapacity(groups.count)
        core.reserveCapacity(groups.count)
        trailing.reserveCapacity(groups.count)
        for group in groups {
            let edges = splitEdgeWhitespace(group)
            leading.append(edges.leading)
            core.append(edges.core)
            trailing.append(edges.trailing)
        }

        // 促音有两种出现方式：自成一"组"（酷狗的常规写法），或挂在组尾（`かっ`）。
        // 两种都先记成"待定"：下一组的读音算出来之后才知道该双写哪个辅音。
        var pendingGeminate = false
        var geminateGroup: Int? = nil

        for index in core.indices {
            let text = core[index]
            guard !text.isEmpty else { continue }

            if isOnlyGeminate(text) {
                geminateGroup = index
                pendingGeminate = true
                core[index] = ""
                continue
            }

            if isOnlyLongVowelMark(text) {
                // 长音是**上一个音节**的延长：元音接在上一组的读音后面（在它的尾随空白之前），
                // 本组留空。元音接到了上一组，所以本组两侧的空白要么已被上一组带着、
                // 要么挪给上一组，否则两个词会粘在一起。
                if let previous = previousNonEmptyCore(before: index, in: core) {
                    let vowel = lastVowel(of: core[previous])
                    if !vowel.isEmpty {
                        core[previous] += String(repeating: vowel, count: text.count)
                    }
                    if trailing[previous].isEmpty {
                        trailing[previous] = trailing[index].isEmpty ? leading[index] : trailing[index]
                    }
                }
                leading[index] = ""
                trailing[index] = ""
                core[index] = ""
                continue
            }

            let romanized = romanizeMixedKana(text)
            var newCore = romanized.text
            var glued = false

            if pendingGeminate {
                let prefix = geminationPrefix(newCore)
                if !prefix.isEmpty {
                    if let carrier = geminateGroup {
                        // 促音自成一组的常规形状：辅音落在促音那一组（它有自己的时长），
                        // 上一组的尾随空白与下一组的前导空白都清掉，三个组拼成 `zutto`。
                        core[carrier] = prefix
                        if let previous = previousNonEmptyCore(before: carrier, in: core) {
                            trailing[previous] = ""
                        }
                        leading[carrier] = ""
                        trailing[carrier] = ""
                    } else {
                        newCore = prefix + newCore
                        if let previous = previousNonEmptyCore(before: index, in: core) {
                            trailing[previous] = ""
                        }
                    }
                    glued = true
                }
                // 下一组以元音开头（促音后面没有可双写的辅音）时 prefix 为空：
                // 促音不发音，但**不动空白** —— 否则 `zu っ a` 会粘成 `zua`。
                pendingGeminate = false
                geminateGroup = nil
            }

            if glued {
                leading[index] = ""
            }
            core[index] = newCore

            // 组尾的 っ（`かっ` 这种）把双写状态传给下一组。
            if romanized.pendingGeminate {
                pendingGeminate = true
            }
        }

        var out: [String] = []
        out.reserveCapacity(groups.count)
        for index in groups.indices {
            out.append(leading[index] + core[index] + trailing[index])
        }
        return out
    }

    /// 把一组里混着的假名段转写掉，非假名部分原样保留。
    private static func romanizeMixedKana(_ text: String) -> (text: String, pendingGeminate: Bool) {
        var result = ""
        var buffer = ""
        var pending = false

        func flushBuffer() {
            guard !buffer.isEmpty else { return }
            let converted = romanizeKanaRun(buffer, prior: result, pendingGeminate: pending)
            result += converted.romanized
            pending = converted.pendingGeminate
            buffer = ""
        }

        for scalar in text.unicodeScalars {
            let piece = String(scalar)
            if isKanaScalar(scalar.value) {
                buffer += piece
                continue
            }
            if isHanScalar(scalar.value) {
                // 汉字转不出来（见文件头那段取舍）：直接丢，罗马字行里不能留汉字。
                // 不 flush 假名缓冲 —— 被丢的字两侧的假名仍是同一段读音。
                continue
            }
            // 叠字符 々 / 〆 不是汉字（Unicode 类别 Lm / Lo，不在 Han 区块里），但它们是
            // 日语书写符号 —— 留在罗马字行里和留下汉字是同一种观感。它们表示"重复前一个字"，
            // 而前一个（汉）字在上一行分支里已经被丢掉、没有读音可重复 ⇒ 只能一起丢。
            if scalar.value == 0x3005 || scalar.value == 0x3006 {
                continue
            }
            flushBuffer()
            if pending {
                result += geminationPrefix(piece)
                pending = false
            }
            result += piece
        }
        flushBuffer()

        return (result, pending)
    }

    /// 纯假名段的逐字转写 —— **实现只有一份**（`JapaneseKanaRomanization.swift`）。
    ///
    /// 这里只负责两件本文件特有的事：
    /// · 表里没有的假名**丢掉**（`unmapped: .drop`）—— 本文件的契约是"结果里不许留假名"；
    /// · 把 `prior`（上一组已经产出的罗马字）带进去，让段首的长音 ー 能接上那个元音。
    ///
    /// ⚠️ 外来音（`ティ` `ファ`）在这条路上**修不了**：酷狗的逐字档会把它们拆成两个组
    /// （`テ` / `ィ`），而组数必须等于词数、不能合并 ⇒ 每组各转各的。这是格式限制，
    /// 不是表的限制；显示层那条路（整 token 转）没有这个问题。
    private static func romanizeKanaRun(
        _ text: String,
        prior: String,
        pendingGeminate: Bool
    ) -> (romanized: String, pendingGeminate: Bool) {
        var pending = pendingGeminate
        let romaji = japaneseKanaRomaji(
            text,
            pendingGeminate: &pending,
            prior: prior,
            unmapped: .drop
        )
        return (romaji, pending)
    }

    // MARK: - 假名判定与表

    private static func isKanaScalar(_ value: UInt32) -> Bool {
        switch value {
        case 0x3041...0x3096,        // 平假名
             0x3099...0x309C,        // 浊点 / 半浊点（结合用）
             0x309D...0x309F,        // ゝ ゞ ゟ
             0x30A1...0x30FA,        // 片假名
             0x30FC...0x30FF,        // ー ヽ ヾ ヿ
             0x31F0...0x31FF,        // 片假名扩展
             0xFF66...0xFF9F:        // 半角片假名（含半角浊点）
            return true
        default:
            return false
        }
    }

    /// 汉字（Han ideograph）的码点范围 —— 与 `KrcText.hanRatio` 逐段一致。
    private static func isHanScalar(_ value: UInt32) -> Bool {
        switch value {
        case 0x3400...0x4DBF,        // 扩展 A
             0x4E00...0x9FFF,        // 基本区
             0xF900...0xFAFF,        // 兼容汉字
             0x20000...0x2FA1F:      // 扩展 B 及以后（含兼容补充）
            return true
        default:
            return false
        }
    }

    private static func isOnlyGeminate(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        return text.allSatisfy { $0 == "っ" || $0 == "ッ" }
    }

    private static func isOnlyLongVowelMark(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        return text.allSatisfy { $0 == "ー" }
    }

    private static func lastVowel(of text: String) -> String {
        guard let last = text.last, "aeiou".contains(last) else { return "" }
        return String(last)
    }

    /// 促音双写时**放进促音那一组**的前缀：下一音节的第一个辅音（`ch`/`sh`/`ts` 取 `t`/`s`/`t`）。
    /// 与 `japaneseGeminated` 同一条规则，只是那个函数给的是"整段双写后的读音"，这里只要前缀。
    private static func geminationPrefix(_ romaji: String) -> String {
        if romaji.hasPrefix("ch") { return "t" }
        if romaji.hasPrefix("sh") { return "s" }
        if romaji.hasPrefix("ts") { return "t" }
        guard let first = romaji.first, first.isLetter, !"aeiou".contains(first) else { return "" }
        return String(first)
    }

    // MARK: - 空白与相邻组

    private static func splitEdgeWhitespace(
        _ text: String
    ) -> (leading: String, core: String, trailing: String) {
        let leadingCount = text.prefix(while: { isWhitespace($0) }).count
        guard leadingCount < text.count else { return (text, "", "") }
        let trailingCount = text.reversed().prefix(while: { isWhitespace($0) }).count
        let start = text.index(text.startIndex, offsetBy: leadingCount)
        let end = text.index(text.endIndex, offsetBy: -trailingCount)
        return (String(text[..<start]), String(text[start..<end]), String(text[end...]))
    }

    private static func isWhitespace(_ character: Character) -> Bool {
        String(character).unicodeScalars.allSatisfy {
            CharacterSet.whitespacesAndNewlines.contains($0)
        }
    }

    private static func previousNonEmptyCore(before index: Int, in core: [String]) -> Int? {
        var candidate = index - 1
        while candidate >= 0 {
            if !core[candidate].isEmpty { return candidate }
            candidate -= 1
        }
        return nil
    }
}
