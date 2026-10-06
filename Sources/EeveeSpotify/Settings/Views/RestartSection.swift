import SwiftUI

/// 设置页的「立即重启」行：改完**只在启动时读一次**的开关之后，让用户不必自己去杀 App。
///
/// 为什么要有它：本仓库有一批开关背后是"启动时按开关决定 hook 装不装"
/// （评分提示拦截、触感、播放器手势、AMOLED 那一类），这些改完**必须重启**才生效。
/// 在那之前只能在 footer 里写一句 `restart_is_required_description`，用户得自己
/// 上滑杀掉 Spotify —— 这一行把"重启"变成一个动作。
///
/// `visible` **由调用方算**：拿当前值和**启动时的快照**比（例如
/// `UserDefaults.blockRatingPrompts != RatingPromptBlock.launchEnabled`），一样就不显示。
/// ⚠️ 别写成"只要开关是开的状态就显示"—— 那样每次进页面都会看到一个没用的按钮。
struct RestartSection: View {

    /// 当前值 ≠ 启动时的值 ⇒ 显示。
    let visible: Bool

    var body: some View {
        if visible {
            Section {
                Button(action: exitApplication) {
                    Label("restart_now".localized, systemImage: "arrow.clockwise")
                }
            }
        }
    }
}
