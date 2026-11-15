import Foundation
import UIKit

/// 封面律动的落点。
///
/// 视图与层级全在 `NowPlayingIOS27` 里（那一页的几何靠 frame 比较维护），这里只把"这一拍的
/// 幅度"送过去 —— 自己找视图会绕过那一页的宿主判定，换歌转场时容易画在上一格 cell 上。
///
/// 只在 **iOS 27 听歌页** 有落点：那一版才有我们自己的 `artworkView` 与 field；其它布局下
/// 这里全部是空转（几处 weak 读）。
enum CoverPulse {

    /// - Parameters:
    ///   - scale: 封面缩放，1.0 = 静止。
    ///   - breath: 低频包络 0…1，用来给 field 的模糊底做同步的呼吸。
    static func apply(scale: CGFloat, breath: CGFloat) {
        onMainThreadSync {
            _ = NowPlayingIOS27.applyAudioPulse(scale: scale, breath: breath)
        }
    }

    /// 关开关 / ticker 停下时调：把缩放与透明度写回静止值。
    static func reset() {
        onMainThreadSync {
            _ = NowPlayingIOS27.applyAudioPulse(scale: 1, breath: 0)
        }
    }
}
