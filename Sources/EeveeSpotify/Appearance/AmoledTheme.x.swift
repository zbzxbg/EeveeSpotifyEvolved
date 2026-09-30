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

    /// 从 bar 自身向下最多看几层。这些 bar 的结构很浅（真机树：`SPNavigationBar` →
    /// `_UIBarBackground` → `UIImageView` 三层；`TabBarView` → `TabBarCompactView` →
    /// `TabBarGradientView` 三层），6 层足够，也不会误伤到 bar 之外的东西。
    private static let subtreeDepth = 6

    /// 一趟遍历里改动了几处 —— 让"到底改到没改到"变成**日志能回答的问题**。
    ///
    /// 为什么必须这样：iPhone 11 是 **LCD**，纯黑在 LCD 上只是深灰，AMOLED 那套
    /// 省电理由也不成立 —— 靠肉眼验收既不可靠、又看不出"是没生效还是屏幕就这样"。
    /// 这两行日志（每个类各一条）才是真正的判据：`barBg=1 gradient=1 image=1 blur=1`
    /// 说明四个目标全改到了；全是 0 说明这一趟什么都没匹配到，那才是真问题。
    private struct Hits {
        var barBackground = 0
        var image = 0
        var gradient = 0
        var blur = 0

        var summary: String {
            "barBg=\(barBackground) gradient=\(gradient) image=\(image) blur=\(blur)"
        }
    }

    private static var reportedClasses: Set<String> = []

    /// 扫一遍并处理三类目标：
    ///   · `_UIBarBackground` → 纯黑底 + 隐藏它的 `UIImageView` 渐变遮罩；
    ///   · 类名含 `Gradient` → 隐藏（标签栏那层渐变）；
    ///   · `UIVisualEffectView` → 去掉模糊（`effect = nil`）并清空底色。
    static func strip(_ view: UIView) {
        guard isEnabled else { return }

        var hits = Hits()
        apply(to: view, depth: 0, limit: subtreeDepth, hits: &hits)

        // 导航栏的模糊层与它**同级**（真机树：`10.UIVisualEffectView@0,0,414,92` 与
        // `10.SPNavigationBar` 同层），所以同级也要扫。
        //
        // ⚠️ 但同级的兄弟里还有**整页内容**（页面视图就是同级）。所以同级只往下看
        // 2 层，并且只认"贴在顶部、矮条状"的兄弟 —— 否则会把页面里的模糊卡片、
        // `*Gradient*` 视图一起当成 bar 处理掉（第二轮真机树抓出来的）。
        if let siblings = view.superview?.subviews {
            for sibling in siblings where sibling !== view {
                let frame = sibling.frame
                guard frame.minY <= 120, frame.height <= 160 else { continue }
                apply(to: sibling, depth: 0, limit: 2, hits: &hits)
            }
        }

        reportOnce(hits, source: String(describing: type(of: view)))
    }

    /// 每个类只报第一趟：既证明 hook 真的跑到了，也说明那一趟改了几处。
    private static func reportOnce(_ hits: Hits, source: String) {
        guard !reportedClasses.contains(source) else { return }
        reportedClasses.insert(source)

        writeDebugLog("[AMOLED] \(source) first layout — \(hits.summary)")
    }

    private static func apply(to view: UIView, depth: Int, limit: Int, hits: inout Hits) {
        guard depth <= limit else { return }

        let name = String(describing: type(of: view))

        if name.contains("_UIBarBackground") {
            if view.backgroundColor != .black {
                view.backgroundColor = .black
                hits.barBackground += 1
            }

            for child in view.subviews where child is UIImageView {
                if !child.isHidden {
                    child.isHidden = true
                    hits.image += 1
                }
            }
        }

        if name.contains("Gradient"), !view.isHidden {
            view.isHidden = true
            hits.gradient += 1
        }

        if let effectView = view as? UIVisualEffectView {
            var changed = false

            if effectView.effect != nil {
                effectView.effect = nil
                changed = true
            }
            if effectView.backgroundColor != .clear {
                effectView.backgroundColor = .clear
                changed = true
            }
            if changed {
                hits.blur += 1
            }
        }

        for child in view.subviews {
            apply(to: child, depth: depth + 1, limit: limit, hits: &hits)
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
