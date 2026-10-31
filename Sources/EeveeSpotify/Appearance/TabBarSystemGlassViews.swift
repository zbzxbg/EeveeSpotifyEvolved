// 系统标签栏那几个视图子类。从 `TabBarSystemGlass.x.swift` 原样拆出。
import Foundation
import Orion
import UIKit
import QuartzCore
import ObjectiveC.runtime

final class TabBarSystemGlassBar: UITabBar {
}

/// 系统栏的宿主：**只做一件事 —— 把底部安全区让掉**。
///
/// 为什么必须有它：UIKit 的浮岛玻璃条**按"所在视图的安全区"**量自己的高度
/// （pw 的注释：Face ID 机型 `max(83, 49 + inset)`、Home 键机型 `62 + max(21, inset)`）。
/// 直接把系统栏塞进一个 60pt 的框里、而它的宿主还报着 34pt 底部安全区的话，
/// 那 34pt 会被留给 Home Indicator ⇒ 内容区只剩 26pt，玻璃画不对。
/// 宿主把 bottom 报成 0 ⇒ 它老老实实按我们给的框画（pw 的 `SGRTabBarHost` 同款做法，
/// 区别是 pw 让掉的是"他们让出去的高度"，我们让掉的是整条底部安全区）。
final class TabBarSystemGlassHost: UIView {
    override var safeAreaInsets: UIEdgeInsets {
        var insets = super.safeAreaInsets
        insets.top = 0
        insets.bottom = 0
        return insets
    }
}

/// 点击中继：系统栏 `delegate` 是 **weak** 的 ⇒ 这个对象由关联对象持有（见 `ensureBar`）。
///
/// ⚠️ 这个类**故意不标 `@MainActor`**（与 `SponsorBlockOverlay` 同一个写法）：
/// UIKit 的 delegate 回调按这个写就不用碰隔离判据；真正的活全部在
/// `onMainThreadSync` 的闭包里干（那个闭包本身就是 `@MainActor`）。
final class TabBarSystemGlassRelay: NSObject, UITabBarDelegate {
    /// ⚠️ Swift 里这个名字是 **`tabBar(_:didSelect:)`**（ObjC 的 `tabBar:didSelectItem:`
    /// 从 Swift 3 起就被导入成这个短名）。写成 `didSelectItem` 编译器直接报
    /// "'tabBar(_:didSelectItem:)' has been renamed to 'tabBar(_:didSelect:)'"踩过）。
    func tabBar(_ tabBar: UITabBar, didSelect item: UITabBarItem) {
        onMainThreadSync {
            TabBarSystemGlass.forwardSelection(from: tabBar, item: item)
        }
    }
}

/// **手势中继**：装在 **Spotify 自己那条栏**上的那只"点一下"（**不抢触摸**）。
///
/// 与点击中继同一套写法：这个类**故意不标 `@MainActor`**（`@objc` 的手势 action 从
/// UIKit 那侧调进来），真正的活全部在 `onMainThreadSync` 的闭包里干。
///
/// ⚠️ 第四片删掉了它的第二只手势（`UIPanGestureRecognizer` "按住划"）—— 见文件头；
/// 系统栏接管触摸时这一只根本收不到触摸（手指落在我们的宿主上），只在
/// "把触摸交还 Spotify" 那一档里起作用。
final class TabBarSystemGlassGestureRelay: NSObject {

    static let shared = TabBarSystemGlassGestureRelay()

    /// 点一下：Spotify 自己去换页（触摸没被我们取消），我们**同时**把气泡对过去。
    @objc func stockTapped(_ recognizer: UITapGestureRecognizer) {
        onMainThreadSync {
            guard let bar = recognizer.view else { return }
            guard let index = TabBarSystemGlass.itemIndex(at: recognizer.location(in: bar), in: bar) else {
                TabBarSystemGlass.reportTapWithoutIndex()
                return
            }
            TabBarSystemGlass.noteFirstTapSeen()
            TabBarSystemGlass.mirrorSelection(index: index, reason: "a tap on Spotify's own bar")
        }
    }
}
