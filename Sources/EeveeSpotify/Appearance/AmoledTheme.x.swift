import Foundation
import Orion
import UIKit

/// AMOLED 纯黑：把 Spotify 自己画的导航栏 / 标签栏底色换成纯黑。
///
/// 类名**不是猜的**，来自 2026-09-30 的真机视图树转储（`[Tree]` 行）与 9.1.86
/// 符号转储（`dump-9.1.86.txt`）交叉验证 —— 树给短名，转储给运行期名：
///
///   树里看到（短名）            运行期名（`targetName`，来自符号转储）
///   TabBarView              → `_TtC23NavigationUI_TabBarImpl10TabBarView`
///   TabBarCompactView       → `_TtC23NavigationUI_TabBarImpl17TabBarCompactView`
///   TabBarGradientView      → `_TtC23NavigationUI_TabBarImpl18TabBarGradientView`
///   SPNavigationBar         → ObjC 类（**不在** Swift 类转储里，名字就是它本身）
///
/// "不是纯黑"的三个来源，全部有真机证据：
///   · `SPNavigationBar` 里的 `_UIBarBackground` → 它的 `UIImageView` 子视图就是那层
///     渐变遮罩（转储里看到 `_UIBarBackground@0,-48,414,92 | UIImageView@0,0,414,92`）；
///   · 与导航栏**同级**的 `UIVisualEffectView@0,0,414,92`（模糊层）；
///   · 标签栏里的 `TabBarGradientView`。
///
/// 三条纪律：
///   1. 所有改动**幂等**（先判断再写）—— 在 `layoutSubviews` 里改视图，不幂等会
///      引发反复布局；
///   2. 开关**实时读**，打开即生效，不必重启；
///   3. 类找不到只打一行日志（本仓库既有做法），不拖垮启动。
struct AmoledTabBarGroup: HookGroup {}
struct AmoledNavBarGroup: HookGroup {}

enum AmoledTheme {

    static var isEnabled: Bool { UserDefaults.amoledEnabled }

    /// 一条视图链向下最多看几层。这些 bar 的结构很浅（3–4 层），6 层足够，
    /// 也不会误伤到页面内容。
    private static let maxDepth = 6

    /// 扫一遍并处理三类目标：
    ///   · `_UIBarBackground` → 纯黑底 + 隐藏它的 `UIImageView` 渐变遮罩；
    ///   · 类名含 `Gradient` → 隐藏（标签栏那层渐变）；
    ///   · `UIVisualEffectView` → 去掉模糊（`effect = nil`）并清空底色。
    static func strip(_ view: UIView) {
        guard isEnabled else { return }

        apply(to: view, depth: 0)

        // 导航栏的模糊层与它**同级**，不在它内部 —— 同级也扫一层。
        if let siblings = view.superview?.subviews {
            for sibling in siblings where sibling !== view {
                apply(to: sibling, depth: 0)
            }
        }
    }

    private static func apply(to view: UIView, depth: Int) {
        guard depth <= maxDepth else { return }

        let name = String(describing: type(of: view))

        if name.contains("_UIBarBackground") {
            if view.backgroundColor != .black { view.backgroundColor = .black }
            for child in view.subviews where child is UIImageView {
                if !child.isHidden { child.isHidden = true }
            }
        }

        if name.contains("Gradient"), !view.isHidden {
            view.isHidden = true
        }

        if let effectView = view as? UIVisualEffectView {
            if effectView.effect != nil { effectView.effect = nil }
            if effectView.backgroundColor != .clear { effectView.backgroundColor = .clear }
        }

        for child in view.subviews {
            apply(to: child, depth: depth + 1)
        }
    }

    // MARK: - 导航栏的兜底

    private static var didScanForNavBar = false

    /// 一次性兜底：`SPNavigationBar` **不在** Swift 类转储里，所以无法确定它是
    /// ObjC 类还是"住在没被扫描的 image 里的 Swift 类"。前者 `NSClassFromString`
    /// 能找到、上面那条 hook 自然生效；后者找不到、hook 不会装 —— 那时从**活着的
    /// 视图树**里按短名找一次，找到就直接处理。
    ///
    /// 只做一次，代价可忽略。读类名是安全的：本仓库两次启动崩溃都来自运行期
    /// **类枚举**（`objc_getClassList` 那条路），不是走活视图树。
    static func scanForNavBarOnce(in window: UIWindow?) {
        guard isEnabled, !didScanForNavBar else { return }
        didScanForNavBar = true

        guard let root = window, let navBar = firstView(in: root, named: "SPNavigationBar") else {
            writeDebugLog("[AMOLED] navBar not found by scan — only the tab bar was stripped")
            return
        }

        strip(navBar)
        writeDebugLog("[AMOLED] navBar found by scan — stripped")
    }

    private static func firstView(in root: UIView, named name: String) -> UIView? {
        var queue: [UIView] = [root]
        var visited = 0

        while !queue.isEmpty, visited < 200 {
            let view = queue.removeFirst()
            visited += 1

            if String(describing: type(of: view)) == name { return view }
            queue.append(contentsOf: view.subviews)
        }

        return nil
    }
}

/// 标签栏：`TabBarView` 是最外层，`TabBarCompactView` 与 `TabBarGradientView` 都在
/// 它下面，所以只挂这一处就够（`apply` 自己会往下走）。
class TabBarViewAmoledHook: ClassHook<UIView> {
    typealias Group = AmoledTabBarGroup
    static let targetName = "_TtC23NavigationUI_TabBarImpl10TabBarView"

    func layoutSubviews() {
        orig.layoutSubviews()
        AmoledTheme.strip(self.target)
        // 标签栏一定会布局，所以顺带在这里做导航栏的一次性兜底扫描。
        AmoledTheme.scanForNavBarOnce(in: self.target.window)
    }
}

/// 导航栏：底色在它的 `_UIBarBackground` 里，模糊层是它同级的 `UIVisualEffectView`。
class SPNavigationBarAmoledHook: ClassHook<UIView> {
    typealias Group = AmoledNavBarGroup
    static let targetName = "SPNavigationBar"

    func layoutSubviews() {
        orig.layoutSubviews()
        AmoledTheme.strip(self.target)
    }
}

func activateAmoledTheme() {
    // 两个 group 各自按"类在不在"决定装不装：目标类缺失时 Orion 会报一条
    // （非致命）错误，不如自己先判掉，日志也更干净。
    if NSClassFromString(TabBarViewAmoledHook.targetName) != nil {
        AmoledTabBarGroup().activate()
    } else {
        writeDebugLog("[AMOLED] missing \(TabBarViewAmoledHook.targetName) — tab bar hook inactive")
    }

    if NSClassFromString(SPNavigationBarAmoledHook.targetName) != nil {
        AmoledNavBarGroup().activate()
    } else {
        writeDebugLog("[AMOLED] missing \(SPNavigationBarAmoledHook.targetName) — nav bar hook inactive")
    }

    writeDebugLog("[AMOLED] installed (enabled=\(AmoledTheme.isEnabled ? "ON" : "OFF"))")
}
