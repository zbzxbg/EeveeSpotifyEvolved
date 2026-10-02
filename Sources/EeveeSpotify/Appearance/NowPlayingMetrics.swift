import UIKit

/// 听歌页（NPV）外观的**几何与曲线常量**。
///
/// ## 为什么单开一个文件放数字
///
/// 这一批外观改动的数值全部来自一份**可对照的实现**：`kumone`（独立网易云客户端，
/// LGPL-3.0 / GPL-3.0 —— 与本仓库 GPL-3.0 兼容）。它把"iPhone 播放页"的每个距离、
/// 每条动画曲线都写成了具名常量（`NowPlayingPresentationMetrics`），而不是散在视图里。
/// 那种写法的好处在这一页特别明显：**同一个数字会被好几处复用**（横条 → 歌名 → 控件行），
/// 散着写就一定会漂。
///
/// ⚠️ **这些是"抄来的手感"，不是"从我们真机量出来的"**：
/// * 凡是**我们真机 dump 里有**的（封面 374×320、歌词卡 342×256、导航条 48/54…），
///   一律以 `[Tree]` 为准，写在本文件的注释里；
/// * 凡是**借来的比例/曲线**（下拉阈值、spring 参数、间距 13pt…），标注来源并允许被真机覆盖。
///
/// 所以：**要改这里的数，先看真机日志或截图**，别凭感觉调。
enum NowPlayingMetrics {

    // MARK: - 借自 kumone 的交互阈值（跨技术栈可搬：纯数字）

    /// 顶部小横条（下拉关闭的那根）：宽 44 / 高 5 / 圆角胶囊。
    static let dragIndicatorWidth: CGFloat = 44
    static let dragIndicatorHeight: CGFloat = 5
    /// 横条到歌名之间留 13pt。
    static let indicatorToHeaderSpacing: CGFloat = 13
    /// 下拉关闭：位移 > 110pt 或预测 > 190pt 才算"要关"。
    static let dismissDistance: CGFloat = 110
    static let dismissPrediction: CGFloat = 190
    /// 迷你条上推展开：> 28pt（预测 > 72pt）。
    static let miniPlayerExpandDistance: CGFloat = 28
    static let miniPlayerExpandPrediction: CGFloat = 72

    // MARK: - 借自 kumone 的动画曲线（AM 那种"先快后缓"）

    /// `timingCurve(0.16, 1, 0.3, 1)` —— 开头冲出去、结尾收得很轻。
    /// 用法：`CABasicAnimation.timingFunction = NowPlayingMetrics.easeOutCurve`，
    /// 时长单独取 `controlsLayoutDuration` 那一组。
    static let easeOutCurve = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)

    /// 控制行显隐的时长（借：0.38 / 0.28 / 0.24 / 0.18）。
    static let controlsLayoutDuration: TimeInterval = 0.38
    static let controlsDismissDuration: TimeInterval = 0.28
    static let controlsFadeInDuration: TimeInterval = 0.24
    static let controlsFadeOutDuration: TimeInterval = 0.18

    /// 换歌时底色交叉淡入：kumone 用 `.easeInOut(0.8)`（SwiftUI 的 0.8s）。
    static let backdropCrossfadeDuration: TimeInterval = 0.8

    // MARK: - 借自 kumone 的歌词列观感（下一轮用）

    /// 歌词行距 26pt（我们的逐词层目前偏紧）。
    static let lyricLineSpacing: CGFloat = 26
    /// 歌词列上下渐隐的停点（0 / 0.12 / 0.85 / 1）。
    static let lyricFadeStops: [NSNumber] = [0, 0.12, 0.85, 1]
    /// 自动滚动跟随的 spring（0.8 / 0.85）—— UIKit 里对应
    /// `UIView.animate(withDuration:delay:usingSpringWithDamping:initialSpringVelocity:)`。
    static let lyricScrollFollowDuration: TimeInterval = 0.8
    static let lyricScrollFollowDamping: CGFloat = 0.85

    // MARK: - 我们自己的真机数字（来自 `[Tree]`，不是借的）

    /// 歌词卡：`CardView@0,0,374,320,id=lyrics-card-view`，内容区 `342×256`。
    static let lyricsCardSize = CGSize(width: 374, height: 320)
    static let lyricsCardContentSize = CGSize(width: 342, height: 256)
    /// 导航条：兼容设计下 48pt（`SPNavigationBar@0,48,414,44` 是旧版；新设计是 54pt）。
    static let navigationBarHeightCompat: CGFloat = 48
    static let navigationBarHeightNewDesign: CGFloat = 54
    /// 迷你播放条内容 398×56，两条玻璃胶囊 360×60（见 `MiniBarGlass` / `TabBarGlass`）。
    static let miniBarContentSize = CGSize(width: 398, height: 56)
}
