// 逐词 / 逐行数据的**可用性判据**与取色背景色 —— 旧 UIKit overlay 与 Apple Music 渲染层共用的口径。
// ⚠️ 判据必须只有一份：两层挂载前都读这里，别各写一套。
import Orion
import UIKit
import ObjectiveC
import SwiftUI

// MARK: - 数据判据
//
// 逐字数据是否可用：至少一半的行有「多词」级时间轴（words.count >= 2）。
// 整行一个词 / 全退化 / 词级时间轴错位 等坏数据会低于阈值，回退原生行级。
//
// 抽成文件级函数是因为它有**两个**消费者：旧的 UIKit overlay（`setCurrentTime`）
// 和 Apple Music 渲染层（挂载前判定）。判定口径必须一致。
func hasUsableWordLevelData(_ dto: LyricsDto?) -> Bool {
    guard let dto, dto.timeSynced else { return false }
    let lines = dto.lines
    guard !lines.isEmpty else { return false }
    let wordLevelLines = lines.filter { ($0.words?.count ?? 0) >= 2 }.count
    return wordLevelLines * 10 >= lines.count * 5  // >= 50%
}

/// 逐**行**数据是否可用：时间同步 + 至少一半的行带 `offsetMs`。
///
/// ⚠️ **它现在不再是挂载判据**起）：挂不挂我们那层只看 `hasUsableWordLevelData`。
/// 只有逐行的歌整首交还 Spotify 原生那页/那张卡（产品规则见 `WordByWordHost.attach`
/// 里那道 guard 的注释）—— 原生本来就会照 payload 的 `offsetMs` 做逐行高亮 + 滚动，
/// 我们那套壳（自绘标题/进度条/三键、行下译文）反而对不上。
///
/// `line timing 32/32 -> line-level=Y`、以及 `attach` 被拒时那句 `line-level usable=…`，
/// 都是它 —— 排查"这首歌为什么没有逐词层"时，这两行能直接区分
/// "源只给了行级"和"源根本没给时间轴"。
///
/// ── 历史（留档，别再改回去）
/// 这一档曾经是"降级渲染"的判据：没有逐字、但有逐行时仍然由我们渲染（当前行整行点亮），
/// 理由是"否则网易云 `yrc absent` 那一批会让整层消失、露出 Spotify 官方供应商"。
/// 真机对照图推翻了它：官方供应商那一层早就由 payload 侧的
/// 「隐藏官方歌词」兜住了，而"逐行的歌套着逐词的壳"是实打实的观感错误。
///
/// 阈值与 `hasUsableWordLevelData` 一样取 50%：低于一半行有时间轴的数据
/// （坏 lrc、只有零星几行带时间）本来也不该由我们渲染。
func hasUsableLineLevelData(_ dto: LyricsDto?) -> Bool {
    guard let dto, dto.timeSynced else { return false }
    let lines = dto.lines
    guard !lines.isEmpty else { return false }
    let timedLines = lines.filter { $0.offsetMs != nil }.count
    return timedLines * 10 >= lines.count * 5  // >= 50%
}

/// 「这一首为什么走逐字档 / 交还原生」—— 把判定的**账**拼成一行日志文本。
///
/// ⚠️ 起因：`hasUsableWordLevelData` 是个 50% 阈值判据，但结果只以 `level=word|line`
/// 一个字母出现在 attached 那行里。**差多少条线**、行级是不是可用，
/// 排查"这首歌怎么没有逐词层"时无从下手。
///
/// ⚠️从 `LyricsWordByWordOverlayView` 的**私有方法**提成文件级函数。
/// 理由：这一行有**两个**消费者，其中一个在别的类型里 ——
/// · `LyricsWordByWordOverlayView.setCurrentTime`（层挂上之后，按版本去重）；
/// · `WordByWordHost.attach` 被拒那条路（**挂不上**的时候，也正最需要这一行）。
/// 私有方法跨类型调不到：真机编译直接报 `cannot find 'logWordLevelJudgeOnce' in scope`。
/// 现在只有"拼文本"这一份实现，两个调用点各自决定要不要写、要不要去重。
///
/// 返回 nil 只表示"没有数据可记账"；目前的实现两种情况都会给出可读的一行。
func wordLevelJudgeLine(dto: LyricsDto?, version: Int) -> String? {
    guard let dto else {
        return "[WordByWord] word-level judge: no dto (version \(version))"
    }

    let lines = dto.lines
    guard !lines.isEmpty else {
        return "[WordByWord] word-level judge: 0 lyric line (version \(version))"
    }

    let wordLines = lines.filter { ($0.words?.count ?? 0) >= 2 }.count
    let timedLines = lines.filter { $0.offsetMs != nil }.count
    let wordOK = hasUsableWordLevelData(dto)
    let lineOK = hasUsableLineLevelData(dto)
    // 阈值：wordLines * 10 >= lines.count * 5（即 >= 50%）；写成整数避免浮点。
    let needWord = (lines.count * 5 + 9) / 10

    // `LyricsRomanizationStatus` 没实现 `CustomStringConvertible`，直接 `\(enum)`
    // 也能编，但打出来是 `romanized` 这种反射形式、跨 Swift 版本不稳定。
    // 这里显式映射，日志格式稳定可 grep。
    let romanizationLabel: String
    switch dto.romanization {
    case .romanized: romanizationLabel = "romanized"
    case .canBeRomanized: romanizationLabel = "canBeRomanized"
    case .original: romanizationLabel = "original"
    }

    return "[WordByWord] word-level judge: \(wordLines)/\(lines.count) line(s) carry word timing"
        + " (need \(needWord) = 50%) -> word-level=\(wordOK ? "Y" : "N")"
        + "; line timing \(timedLines)/\(lines.count) -> line-level=\(lineOK ? "Y" : "N")"
        + " | timeSynced=\(dto.timeSynced)"
        + " romanization=\(romanizationLabel)"
        + " | render mode=\(wordOK ? "word" : "handback-to-native")"
}

/// 逐词歌词层的**纯色底色**（"只开逐词歌词、没开更好的逐词歌词"那条路用作背景）。
///
/// 优先级与旧 overlay 原来的取色完全一致：
/// 1. `CustomLyrics` 最终写回的原生歌词底色（与模块头同色，保证两者一致）；
/// 2. 「定制」里的显示原始颜色 → 正在播放背景色；
/// 3. 「定制」里的静态色；
/// 4. 专辑提取色（按归一化因子调整）；
/// 5. 兜底灰。
///
/// 抽成文件级函数是因为它有**两个**消费者：旧 UIKit 层（iOS 26 以下）与
/// 共用页面那条路的纯色背景 —— 取色逻辑必须只有一份。
func wordByWordSolidBackgroundColor() -> UIColor {
    if currentLyricsBackgroundColorARGB != 0 {
        let argb = currentLyricsBackgroundColorARGB
        let alphaByte = (argb >> 24) & 0xFF
        return UIColor(
            red: CGFloat((argb >> 16) & 0xFF) / 255,
            green: CGFloat((argb >> 8) & 0xFF) / 255,
            blue: CGFloat(argb & 0xFF) / 255,
            alpha: alphaByte == 0 ? 1 : CGFloat(alphaByte) / 255
        )
    }

    let settings = UserDefaults.lyricsColors

    if settings.displayOriginalColors,
       let original = backgroundViewModel?.color() {
        return original.withAlphaComponent(1)
    }

    if settings.useStaticColor, !settings.staticColor.isEmpty {
        return UIColor(Color(hex: settings.staticColor))
    }

    let track = statefulPlayer?.currentTrack() ?? nowPlayingScrollViewController?.loadedTrack
    let extractedHex: String? = {
        switch EeveeSpotify.hookTarget {
        case .lastAvailableiOS14: return track?.extractedColorHex()
        default: return track?.metadata()["extracted_color"]
        }
    }()
    if let hex = extractedHex {
        return UIColor(Color(hex: hex).normalized(settings.normalizationFactor))
    }

    if let background = backgroundViewModel?.color() {
        return UIColor(Color(background).normalized(settings.normalizationFactor))
            .withAlphaComponent(1)
    }

    return .gray
}
