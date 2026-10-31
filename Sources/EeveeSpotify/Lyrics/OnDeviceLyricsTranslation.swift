import Foundation
import NaturalLanguage
import Translation

/// 歌词的**系统翻译** —— Apple 的 `Translation` 框架，整首歌在手机上翻完，一个字都不出设备。
///
/// ## 为什么只做系统翻译
///
/// 只做系统翻译，其他的先不要做。也就是：
/// · 不要 Gemini（要用户自己的 key、歌词要上传）；
/// · 不新增歌词源。
/// 两个前提都是设置 → App → 翻译 → 语言里满足的（下好两种语言），
/// 我们只负责把行文本递过去、把译文按行收回来。
///
/// ## 门槛是 iOS 26
///
/// `TranslationSession(installedSource:target:)` 这个**公开初始化器**从 26.0 才有
/// 编译现场：`only available in iOS 26.0 or newer`）。
/// iOS 18~25 上框架的会话只能由 SwiftUI 的 `.translationTask` 给，那是另一套写法；
/// 在把它做出来之前，这里就是"不可用"。
///
/// ## 几条自我约束
///
/// · **只翻有字的行**：空行 / 纯音乐记号 `♪` / 本来就已经是目标语言的行，一律不递过去
/// （递过去只会得到一句废话，还多占一次往返）；
/// · **源语言靠猜**：`NLLanguageRecognizer` 逐行判、置信度 ≥ 0.8 才算数，
/// 取"与目标语言不同的那些行"里占比最大的那门语言；猜不出就不翻（宁可没有，不要乱翻）；
/// · **失败要能说人话**：语言没装 / 不支持这一对 / 模型没就绪，各给一句能照着做的提示；
/// · **不碰主线程**：整段在后台跑，结果回主线程再写进 `currentLyricsDto`。
enum OnDeviceLyricsTranslation {

    /// 这台设备 / 这个系统版本上能不能用。
    ///
    /// ⚠️ 门槛是 **iOS 26**，不是 18：会话的公开初始化器从 26.0 才有。
    static var isAvailable: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }

    /// 翻成哪种语言：手机的首选语言，砍成 `language[-Script]`
    /// （`zh-Hans-CN` → `zh-Hans`：`Translation` 要的是这个粒度，带地区码会判成不支持）。
    static func targetLanguageTag() -> String {
        minimalTag(Locale.preferredLanguages.first ?? "en")
    }

    // MARK: - 主流程
    //
    // 整首翻一遍。`lines` 与返回的数组**同长同序**（不需要翻的行返回 `""`）。
    //
    // 失败时返回 `(nil, 一句人话)`：调用方只负责把它写进日志 / 提示，不做重试判断。
    static func translate(
        _ lines: [String],
        to languageTag: String
    ) async -> (lines: [String]?, message: String?) {
        guard #available(iOS 26.0, *) else {
            return (nil, "System translation is only available on iOS 26 and later.")
        }

        let target = Locale.Language(identifier: languageTag)
        let targetName = displayName(target)

        guard let source = sourceLanguage(of: lines, target: target) else {
            return (nil, "Couldn't tell what language these lyrics are in.")
        }
        if isSame(source, target) {
            return (nil, "These lyrics are already \(targetName).")
        }

        // 语言包没装 / 这一对不支持 —— 都是用户能自己解决的事，各给一句话。
        if let blocker = await readiness(from: source, to: target) {
            return (nil, blocker)
        }

        let requests = makeRequests(lines, target: target)
        guard !requests.isEmpty else {
            return (nil, "Every line is already \(targetName).")
        }

        // 语言包刚被叫醒时，第一次调用经常直接抛错；等一秒再试，通常就正常了。
        var attemptsLeft = 2
        var lastFailure = "unknown error"

        repeat {
            attemptsLeft -= 1
            do {
                let translated = try await runSession(
                    source: source,
                    target: target,
                    requests: requests,
                    lineCount: lines.count
                )
                let filled = translated.filter { !$0.isEmpty }.count
                writeDebugLog(
                    "[Lyrics] system translation — \(filled)/\(requests.count) line(s)"
                        + " \(source.minimalIdentifier) → \(target.minimalIdentifier)"
                )
                return (translated, nil)
            } catch {
                lastFailure = error.localizedDescription
                writeDebugLog("[Lyrics] system translation attempt failed — \(lastFailure)")
                if attemptsLeft > 0 {
                    // 1 秒是原来真机上调过的值：更短会撞上语言包还没加载完。
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
        } while attemptsLeft > 0

        return (nil, "The system translator stopped: \(lastFailure)")
    }

    // MARK: - 可用性
    //
    // 这一对语言现在能不能翻。能翻返回 nil，不能翻返回一句给用户看的话。
    @available(iOS 26.0, *)
    private static func readiness(from source: Locale.Language, to target: Locale.Language) async -> String? {
        let sourceName = displayName(source)
        let targetName = displayName(target)

        switch await LanguageAvailability().status(from: source, to: target) {
        case .unsupported:
            return "The system translator can't go from \(sourceName) to \(targetName)."
        case .supported:
            return "Add \(sourceName) and \(targetName) under Settings → Apps → Translate → Languages first."
        case .installed:
            return nil
        @unknown default:
            return nil
        }
    }

    // MARK: - 请求

    @available(iOS 26.0, *)
    private static func makeRequests(
        _ lines: [String],
        target: Locale.Language
    ) -> [TranslationSession.Request] {
        lines.enumerated().compactMap { index, line in
            guard needsTranslation(line, target: target) else { return nil }
            return TranslationSession.Request(sourceText: line, clientIdentifier: String(index))
        }
    }

    /// 跑一次会话。返回的数组与 `lineCount` 同长，没翻的行留空串。
    @available(iOS 26.0, *)
    private static func runSession(
        source: Locale.Language,
        target: Locale.Language,
        requests: [TranslationSession.Request],
        lineCount: Int
    ) async throws -> [String] {
        let session = TranslationSession(installedSource: source, target: target)
        var translated = [String](repeating: "", count: lineCount)

        for response in try await session.translations(from: requests) {
            guard let identifier = response.clientIdentifier,
                  let index = Int(identifier),
                  translated.indices.contains(index) else { continue }
            translated[index] = response.targetText
        }

        return translated
    }

    // MARK: - 语言判定
    //
    // 单行判语言只在识别器有把握时采信；"yeah" / "oh" 这类短句它会给出很随机的答案。
    private static func detect(_ line: String) -> Locale.Language? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(line)
        guard let (found, chance) = recognizer.languageHypotheses(withMaximum: 1).first,
              chance >= 0.8 else { return nil }
        return Locale.Language(identifier: found.rawValue)
    }

    private static func isSame(_ a: Locale.Language, _ b: Locale.Language) -> Bool {
        a.languageCode == b.languageCode
    }

    /// 整首歌是哪种语言：**与目标语言不同**的那些行里，按"去重后的行"投票，票多的那门。
    ///
    /// 按行投票之前先做去重 —— 否则一段循环八遍的副歌会替整首歌投票。
    private static func sourceLanguage(of lines: [String], target: Locale.Language) -> Locale.Language? {
        let distinct = Set(lines.map { $0.lowercased() }).filter { !$0.isEmpty }

        let votes = distinct.compactMap { line -> String? in
            guard let language = detect(line),
                  !isSame(language, target),
                  let code = language.languageCode?.identifier else { return nil }
            return code
        }

        if let winner = Dictionary(grouping: votes, by: { $0 })
            .max(by: { $0.value.count < $1.value.count })?.key {
            return Locale.Language(identifier: winner)
        }

        // 逐行都认不准（整首很短 / 全是语气词）⇒ 退成"整首一起判"。
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(distinct.joined(separator: "\n"))
        guard let whole = recognizer.dominantLanguage, whole != .undetermined else { return nil }
        return Locale.Language(identifier: whole.rawValue)
    }

    /// 这一行要不要递过去翻：没字、纯音乐记号、或者本来就是目标语言 ⇒ 不递。
    private static func needsTranslation(_ line: String, target: Locale.Language) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "♪" else { return false }
        if let language = detect(trimmed), isSame(language, target) { return false }
        return true
    }

    // MARK: - 其它

    private static func minimalTag(_ tag: String) -> String {
        let parts = tag.split(separator: "-")
        guard let language = parts.first else { return tag }
        // 第二段是四位的书写系统（`Hans` / `Hant` / `Latn`）才保留，`CN` 这种地区码丢掉。
        if parts.count >= 2 {
            let script = parts[1]
            if script.count == 4, script.first?.isUppercase == true {
                return "\(language)-\(script)"
            }
        }
        return String(language)
    }

    private static func displayName(_ language: Locale.Language) -> String {
        Locale.current.localizedString(forIdentifier: language.minimalIdentifier)
            ?? language.minimalIdentifier
    }
}
