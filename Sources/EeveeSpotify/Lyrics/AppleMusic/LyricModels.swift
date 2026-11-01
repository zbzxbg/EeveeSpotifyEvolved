import Foundation

// MARK: - 来源说明
//
// 本文件移植自 MeloX（https://github.com/youshen2/MeloX）的
// `MeloX/Core/Lyrics/LyricModels.swift`，遵循 GPL-3.0（与本项目同协议）。
// 改动仅限：去掉对 App 内 `L10n` 的依赖（`accessibilityText` 里改为直接拼接）。
//
// 这一层是纯 Foundation 数据类型，不含任何 SwiftUI / UIKit 依赖，
// 因此**不需要 @available(iOS 18, *) 门禁**，老系统上也能安全加载。

struct LyricSyllable: Identifiable, Hashable, Sendable {
    let text: String
    let startTime: TimeInterval
    let endTime: TimeInterval

    var id: String {
        "\(startTime)-\(endTime)-\(text)"
    }
}

enum LyricLineTimingKind: Hashable, Sendable {
    /// The line carries an authored content duration, usually from YRC.
    case precise

    /// LRC only tells us when this line is replaced by the next one. Its
    /// inferred display duration must not be treated as sung-content timing.
    case lineSynchronized
}

enum LyricAgentAlignment: Hashable, Sendable {
    case normal
    case flipped
}

enum LyricAgentKind: Hashable, Sendable {
    case person
    case group
}

struct LyricAgent: Hashable, Sendable {
    let identifier: String
    let displayName: String
    let kind: LyricAgentKind
    let alignment: LyricAgentAlignment
}

enum LyricVocalistsType: Hashable, Sendable {
    case single
    case duet
    case group

    static func resolve(in lines: [LyricLine]) -> LyricVocalistsType {
        let agents = lines.compactMap(\.agent)
        let personIdentifiers = Set(
            agents
                .filter { $0.kind == .person }
                .map(\.identifier)
        )
        if agents.contains(where: { $0.kind == .group })
            || personIdentifiers.count > 2 {
            return .group
        }
        return personIdentifiers.count == 2 ? .duet : .single
    }
}

enum LyricBackgroundVocalsPosition: Hashable, Sendable {
    case beforePrimary
    case afterPrimary
}

struct LyricBackgroundVocal: Hashable, Sendable {
    let time: TimeInterval
    let duration: TimeInterval?
    let text: String
    let syllables: [LyricSyllable]
    let translation: String?
    let position: LyricBackgroundVocalsPosition

    func lyricLine(
        parentID: LyricLine.ID,
        agent: LyricAgent?
    ) -> LyricLine {
        LyricLine(
            id: "\(parentID):background-vocal",
            time: time,
            duration: duration,
            text: text,
            syllables: syllables,
            translation: translation,
            agent: agent
        )
    }
}

struct LyricLine: Identifiable, Hashable, Sendable {
    let id: String
    let time: TimeInterval
    let duration: TimeInterval?
    let timingKind: LyricLineTimingKind
    let text: String
    let syllables: [LyricSyllable]
    let romanization: String?
    let romanizationSyllables: [LyricSyllable]
    let translation: String?
    let agent: LyricAgent?
    let backgroundVocal: LyricBackgroundVocal?

    init(
        id: String? = nil,
        time: TimeInterval,
        duration: TimeInterval? = nil,
        timingKind: LyricLineTimingKind = .precise,
        text: String,
        syllables: [LyricSyllable] = [],
        romanization: String? = nil,
        romanizationSyllables: [LyricSyllable] = [],
        translation: String? = nil,
        agent: LyricAgent? = nil,
        backgroundVocal: LyricBackgroundVocal? = nil
    ) {
        self.id = id ?? Self.fallbackID(
            time: time,
            text: text
        )
        self.time = time
        self.duration = duration
        self.timingKind = timingKind
        self.text = text
        self.syllables = syllables
        self.romanization = romanization
        self.romanizationSyllables = romanizationSyllables
        self.translation = translation
        self.agent = agent
        self.backgroundVocal = backgroundVocal
    }

    init(
        id: String,
        copying line: LyricLine
    ) {
        self.init(
            id: id,
            time: line.time,
            duration: line.duration,
            timingKind: line.timingKind,
            text: line.text,
            syllables: line.syllables,
            romanization: line.romanization,
            romanizationSyllables: line.romanizationSyllables,
            translation: line.translation,
            agent: line.agent,
            backgroundVocal: line.backgroundVocal
        )
    }

    var isSyllableSynced: Bool {
        !syllables.isEmpty
    }

    static func fallbackID(
        time: TimeInterval,
        text: String
    ) -> String {
        "line:\(time.bitPattern):\(Self.stableTextHash(text))"
    }

    static func stableTextHash(_ text: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    var hasTranslation: Bool {
        guard let translation else { return false }
        return !translation
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
    }

    var hasRomanization: Bool {
        guard let romanization else { return false }
        return !romanization
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
    }

    // `makePseudoSyllables()` 已删除：它（从 MeloX 原样带过来的死代码，全仓零调用）
    // 把整行**显示时长**均分给每一个字符，连句尾那段静音也填了 —— 于是填充前沿会
    // 一直推进到下一句开口，且与间奏判定（`contentEndTime` 用的是**估算演唱时长**）
    // 对不上。要做伪逐字请用 `PseudoWordTiming.pieces(for:startTime:nextStartTime:)`：
    // 它按估算演唱时长铺、夹到下一行、空格不占时间，且只产渲染用的数据。

    func attachingTranslation(_ translation: String?) -> LyricLine {
        LyricLine(
            id: id,
            time: time,
            duration: duration,
            timingKind: timingKind,
            text: text,
            syllables: syllables,
            romanization: romanization,
            romanizationSyllables: romanizationSyllables,
            translation: translation,
            agent: agent,
            backgroundVocal: backgroundVocal
        )
    }

    func attachingRomanization(
        _ romanization: String?,
        romanizationSyllables: [LyricSyllable] = []
    ) -> LyricLine {
        LyricLine(
            id: id,
            time: time,
            duration: duration,
            timingKind: timingKind,
            text: text,
            syllables: syllables,
            romanization: romanization,
            romanizationSyllables: romanizationSyllables,
            translation: translation,
            agent: agent,
            backgroundVocal: backgroundVocal
        )
    }

    func attachingAgent(
        _ agent: LyricAgent?,
        text: String? = nil,
        syllables: [LyricSyllable]? = nil
    ) -> LyricLine {
        LyricLine(
            id: id,
            time: time,
            duration: duration,
            timingKind: timingKind,
            text: text ?? self.text,
            syllables: syllables ?? self.syllables,
            romanization: romanization,
            romanizationSyllables: romanizationSyllables,
            translation: translation,
            agent: agent,
            backgroundVocal: backgroundVocal
        )
    }

    /// 无障碍朗读文本。MeloX 原版用 App 内 `L10n` 做本地化，这里改为直接拼接。
    func accessibilityText(
        includingTranslation: Bool,
        includingRomanization: Bool = false
    ) -> String {
        var components = [text]
        if includingRomanization, hasRomanization, let romanization {
            components.append(romanization)
        }
        if includingTranslation, hasTranslation, let translation {
            components.append(translation)
        }
        if let backgroundVocal {
            components.append(backgroundVocal.text)
            if includingTranslation, let translation = backgroundVocal.translation {
                components.append(translation)
            }
        }
        return components.joined(separator: "，")
    }
}
