import Foundation
import NaturalLanguage
import Translation

/// 歌词的**系统翻译** —— Apple 的 `Translation` 框架，整首歌在手机上翻完，一个字都不出设备。
///
/// ## 为什么单开这一份（而不是接第三方）
///
/// 用户 2026-10-31 拍板：「只做系统翻译，其他的先不要做」。也就是：
///   · 不要 Gemini（要用户自己的 key、歌词要上传）；
///   · 不新增歌词源。
/// 系统翻译的两个前提都是用户自己在「设置 → App → 翻译 → 语言」里满足的（下好两种语言），
/// 我们只负责把行文本递过去、把译文按行收回来。
///
/// ## 和 taurus 的关系（PolyForm Strict 1.0.0，**只读思路、不抄代码**）
///
/// 它的 `OnDeviceTranslation.swift` 给了两条关键信息，这里按同样的路子自己写：
///   1. `TranslationSession(installedSource:target:)` 是**公开初始化器** —— 不必为了拿一个
///      会话去挂 SwiftUI 的 `.translationTask`（那本来是这个框架唯一的用法）；
///      ⚠️ 但它**从 iOS 26.0 才有**（2026-10-31 编译现场：`only available in iOS 26.0 or newer`），
///      iOS 18~25 上这个框架没有公开的构造入口 —— 所以整条路在那些系统上直接不可用；
///   2. `translations(from:)` 一次可以递**一批** `Request`，每条的 `clientIdentifier`
///      带着行号回来 ⇒ 按行号填回去，不必依赖返回顺序。
///
/// ## 几条自我约束
///
///   · **只翻有字的行**：空行 / 纯音乐记号 `♪` / 本来就已经是目标语言的行，一律不递过去
///     （递过去只会得到一句废话，还多占一次往返）；
///   · **源语言靠猜**：`NLLanguageRecognizer` 逐行判、置信度 ≥ 0.8 才算数，
///     取"与目标语言不同的那些行"里占比最大的那门语言；猜不出就不翻（宁可没有，不要乱翻）；
///   · **失败要能说人话**：语言没装 / 不支持这一对 / 模型没就绪，各给一句能照着做的提示；
///   · **不碰主线程**：整段在后台跑，结果回主线程再写进 `currentLyricsDto`。
enum OnDeviceLyricsTranslation {

    /// 这台设备 / 这个系统版本上能不能用。
    ///
    /// ⚠️ 门槛是 **iOS 26**，不是 18：`TranslationSession(installedSource:target:)`
    /// 这个公开初始化器从 26.0 才有。iOS 18~25 上框架的会话只能由 SwiftUI 的
    /// `.translationTask` 给，那是另一套写法 —— 在把它做出来之前，这里就是"不可用"。
    static var isAvailable: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }

    /// 翻成哪种语言：手机的首选语言，砍成 `language[-Script]`
    /// （`zh-Hans-CN` → `zh-Hans`：`Translation` 要的是这个粒度，带地区码会判成不支持）。
    static func targetLanguageTag() -> String {
        minimalTag(Locale.preferredLanguages.first ?? "en")
    }

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

    /// 一行的语言 —— **认不准就当没有**（"yeah" / "oh" 这种短句会被乱猜）。
    ///
    /// ⚠️ 名字带 `detected` 前缀不是为了好看：叫 `language(of:)` 时它是个
    ///   `private` 的**极通用名**，而 `swift_member_check` 的规则 ③ 会把"仓库里有人
    ///   用 private 声明过的名字"当成跨文件裸引用的嫌疑 —— 于是
    ///   `EeveeLyricsSettingsViewModel+setupBindings.swift` 里那个闭包参数 `language`
    ///   被误报成"裸引用别的文件的 private 成员"（逻辑测试会红）。
    ///   私有辅助函数取个不会跟局部变量撞的名字，比让那条规则去理解闭包参数容易得多。
    private static func detectedLanguage(of line: String) -> Locale.Language? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(line)
        guard let (found, chance) = recognizer.languageHypotheses(withMaximum: 1).first,
              chance >= 0.8 else { return nil }
        return Locale.Language(identifier: found.rawValue)
    }

    private static func same(_ a: Locale.Language, _ b: Locale.Language) -> Bool {
        a.languageCode == b.languageCode
    }

    /// 整首歌是哪种语言：**与目标语言不同**的那些行里，按"去重后的行"投票，票多的那门。
    ///
    /// 为什么要去重：副歌重复四遍，不该比主歌更有话语权。
    private static func sourceLanguage(of lines: [String], target: Locale.Language) -> Locale.Language? {
        var votes: [String: (language: Locale.Language, count: Int)] = [:]
        for line in Set(lines.map { $0.lowercased() }) where !line.isEmpty {
            guard let detected = detectedLanguage(of: line),
                  !same(detected, target),
                  let code = detected.languageCode?.identifier else { continue }
            votes[code] = (votes[code]?.language ?? detected, (votes[code]?.count ?? 0) + 1)
        }
        if let winner = votes.values.max(by: { $0.count < $1.count }) { return winner.language }
        // 逐行都认不准（整首很短 / 全是语气词）⇒ 退成"整首一起判"。
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(Set(lines).joined(separator: "\n"))
        guard let whole = recognizer.dominantLanguage, whole != .undetermined else { return nil }
        return Locale.Language(identifier: whole.rawValue)
    }

    /// 这一行要不要递过去翻：没字、纯音乐记号、或者本来就是目标语言 ⇒ 不递。
    private static func needsTranslation(_ line: String, target: Locale.Language) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "♪" else { return false }
        if let detected = detectedLanguage(of: trimmed), same(detected, target) { return false }
        return true
    }

    /// 整首翻一遍。`lines` 与返回的数组**同长同序**（不需要翻的行返回 `""`）。
    ///
    /// 失败时返回 `(nil, 一句人话)`：调用方只负责把它写进日志 / 提示，不做重试判断。
    static func translate(_ lines: [String], to languageTag: String) async -> (lines: [String]?, message: String?) {
        // ⚠️ 26.0（不是 18.0）：会话的公开初始化器只在这里有，见 `isAvailable` 的说明。
        //   低于 26 时 `LanguageAvailability` 之类其实也有，但没有会话可建，走到后面也是白跑。
        guard #available(iOS 26.0, *) else {
            return (nil, "System translation needs iOS 26 or later.")
        }
        let target = Locale.Language(identifier: languageTag)
        let targetName = displayName(target)
        guard let source = sourceLanguage(of: lines, target: target) else {
            return (nil, "The song's language could not be told from its words.")
        }
        if same(source, target) {
            return (nil, "The lyrics are already in \(targetName).")
        }
        let sourceName = displayName(source)

        switch await LanguageAvailability().status(from: source, to: target) {
        case .unsupported:
            return (nil, "Apple's Translate does not translate \(sourceName) into \(targetName).")
        case .supported:
            return (nil, "Download \(sourceName) and \(targetName) in Settings → Apps → Translate → Languages, then try again.")
        case .installed:
            break
        @unknown default:
            break
        }

        let requests = lines.enumerated().compactMap { index, line -> TranslationSession.Request? in
            guard needsTranslation(line, target: target) else { return nil }
            return TranslationSession.Request(
                sourceText: line,
                clientIdentifier: String(index)
            )
        }
        guard !requests.isEmpty else { return (nil, "Every line is already in \(targetName).") }

        // 第一次请求常常撞上"翻译框架正在加载语言包"，隔一秒再来一次基本就过了。
        for attempt in 1...2 {
            do {
                let session = TranslationSession(installedSource: source, target: target)
                var out = [String](repeating: "", count: lines.count)
                for response in try await session.translations(from: requests) {
                    guard let identifier = response.clientIdentifier,
                          let index = Int(identifier),
                          out.indices.contains(index) else { continue }
                    out[index] = response.targetText
                }
                let translated = out.filter { !$0.isEmpty }.count
                writeDebugLog(
                    "[Lyrics] system translation — \(translated)/\(requests.count) line(s)"
                        + " \(source.minimalIdentifier) → \(target.minimalIdentifier)"
                )
                return (out, nil)
            } catch {
                writeDebugLog(
                    "[Lyrics] system translation attempt \(attempt) failed — \(error.localizedDescription)"
                )
                if attempt == 2 {
                    return (nil, "Apple's Translate could not translate the song (\(error.localizedDescription)).")
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        return (nil, "Apple's Translate could not translate the song.")
    }

    private static func displayName(_ language: Locale.Language) -> String {
        Locale.current.localizedString(forIdentifier: language.minimalIdentifier)
            ?? language.minimalIdentifier
    }
}
