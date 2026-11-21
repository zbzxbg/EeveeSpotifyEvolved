import Foundation
import UIKit

/// 两条玻璃（标签栏 / 迷你条）的**启动快照**与设备资格。
///
/// 这两个开关决定的不是"改个颜色"，而是**启动时要不要往 Spotify 的视图树里插一条系统栏**。
/// 中途插/拆会触发 Spotify 的重排，风险远大于收益 ⇒ 开关语义改成"下次启动生效"：
/// 运行时一律用**启动那一刻**的值，设置页写的是下一份值，由 `RestartSection` 提示重启。
///
/// iPad 上两条都不装：它们是照着 iPhone 那条标签栏量出来的（宽度比例、49pt 行高、
/// 底部安全区让位），iPad 是常规宽度 / 另一套布局，装上去只会多一条压住内容的栏。
enum GlassLayout {

    private static var launchTabBarSystemGlass: Bool?
    private static var launchMiniBarGlass: Bool?

    /// 必须在设置页打开之前调一次（`EeveeSpotify.init` 里）。
    static func captureLaunchSnapshot() {
        guard launchTabBarSystemGlass == nil else { return }
        launchTabBarSystemGlass = UserDefaults.tabBarSystemGlass
        launchMiniBarGlass = UserDefaults.miniBarGlass
    }

    /// 本会话是否装标签栏玻璃：只看启动快照与设备资格。
    static var tabBarSystemGlassEnabled: Bool {
        isEligible && (launchTabBarSystemGlass ?? UserDefaults.tabBarSystemGlass)
    }

    /// 本会话是否铺迷你条玻璃：同上。
    static var miniBarGlassEnabled: Bool {
        isEligible && (launchMiniBarGlass ?? UserDefaults.miniBarGlass)
    }

    /// 当前值和启动快照不一致 ⇒ 需要重启。
    static var needsRestart: Bool {
        guard let tabBar = launchTabBarSystemGlass, let miniBar = launchMiniBarGlass else { return false }
        return UserDefaults.tabBarSystemGlass != tabBar || UserDefaults.miniBarGlass != miniBar
    }

    /// iPhone 才装这两条玻璃。
    static var isEligible: Bool { !UIDevice.current.isIpad }
}
