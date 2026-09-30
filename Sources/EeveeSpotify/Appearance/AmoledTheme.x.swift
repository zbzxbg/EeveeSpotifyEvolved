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
    /// 取值取向（用户拍板：**仿 Apple Music**）。
    ///
    ///   false（当前）= 仿 AM：顶部保持透明，封面/内容从标题下面透出来；Spotify 自己
    ///     要画底色时，把那层灰色渐变遮罩藏掉、把它旁边的模糊换成**深色材质**。
    ///   true = 不管 Spotify 画不画，导航栏/标签栏一律纯黑（会失去封面透出效果，
    ///     但 LCD 上"黑得最实"）。
    ///
    /// 两种都在这里，只是为了让这个选择在代码里看得见 —— 改一个字就能切。
    private static let alwaysOpaqueBlack = false

    /// 一趟遍历里改动了几处 —— 让"到底改到没改到"变成**日志能回答的问题**。
    ///
    /// 为什么必须这样：iPhone 11 是 **LCD**，纯黑在 LCD 上只是深灰；靠肉眼验收既不可靠、
    /// 也分不清"没生效"和"屏幕就这样"。这几行日志才是判据。
    private struct Hits {
        /// 藏掉了几个灰色渐变遮罩（`_UIBarBackground` 里的 `UIImageView`）。
        var scrim = 0
        /// 几个模糊层换成了深色材质。
        var blur = 0
        /// 只在 `alwaysOpaqueBlack` 下用：给 bar 自己铺黑底的次数。
        var bar = 0
        /// 只在 `alwaysOpaqueBlack` 下用：涂黑 `_UIBarBackground` 的次数。
        var barBackground = 0
        /// 只在 `alwaysOpaqueBlack` 下用：隐藏 `*Gradient*` 的次数。
        var gradient = 0

        var summary: String {
            "scrim=\(scrim) blur=\(blur) bar=\(bar) barBg=\(barBackground) gradient=\(gradient)"
        }
    }

    private static var reportedClasses: Set<String> = []

    /// 扫一遍 bar 的子树（加上贴顶的同级兄弟），做两件事（仿 Apple Music）：
    ///   1. 藏掉 `_UIBarBackground` 里的灰色渐变遮罩 `UIImageView`；
    ///   2. 把 `UIVisualEffectView` 的模糊换成深色材质。
    ///
    /// `alwaysOpaqueBlack = true` 时另加三件事：给 bar 自己铺黑底、涂黑
    /// `_UIBarBackground`、隐藏 `*Gradient*` —— 代价是封面不再从标题下透出，
    /// 见那个常量上的说明。
    static func strip(_ view: UIView) {
        guard isEnabled else { return }

        var hits = Hits()

        // 只有 `alwaysOpaqueBlack` 才给 bar 自己铺底 —— 这是**唯一**会破坏"封面透出"
        // 的一步，所以默认不做。
        if alwaysOpaqueBlack, view.backgroundColor != .black {
            view.backgroundColor = .black
            hits.bar += 1

            // `SPNavigationBar` 是 UINavigationBar 子类：`barTintColor` 会盖在
            // `backgroundColor` 上，一起钉死。
            if let bar = view as? UINavigationBar, bar.barTintColor != .black {
                bar.barTintColor = .black
            }
        }

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

        if alwaysOpaqueBlack {
            // 标签栏的两种 bar 视图**自己就是底色**（真机：`TabBarView > TabBarCompactView`，
            // 里面没有 `_UIBarBackground`），只涂外层不够 —— CompactView 会盖在上面。
            if name.contains("TabBarView") || name.contains("TabBarCompactView"),
               view.backgroundColor != .black {
                view.backgroundColor = .black
                hits.bar += 1
            }

            if name.contains("_UIBarBackground"), view.backgroundColor != .black {
                view.backgroundColor = .black
                hits.barBackground += 1
            }

            if name.contains("Gradient"), !view.isHidden {
                view.isHidden = true
                hits.gradient += 1
            }
        }

        // 仿 AM 第一步：藏掉那层灰色渐变遮罩。
        //
        // 真机证据：`SPNavigationBar > _UIBarBackground@0,-48,414,92 > UIImageView@0,0,414,92`
        // —— 滚动时"浮出来那层灰"就是它。注意**只藏这个 image，不动 `_UIBarBackground`
        // 自己的 backgroundColor**：动它就等于顶部也不透明，"封面从标题下透出"就没了
        // （上一版正是这么把透明弄丢的）。
        if name.contains("_UIBarBackground") {
            for child in view.subviews where child is UIImageView {
                if !child.isHidden {
                    child.isHidden = true
                    hits.scrim += 1
                }
            }
        }

        // 仿 AM 第二步：模糊层换成**深色材质**。
        //
        // 上一版我是 `effect = nil`（等于把模糊整个撤掉），滚动时内容会直接糊在标题下面；
        // Apple Music 那边是一层深色材质。是否显示由 Spotify 控制（真机树里那个
        // `UIView@0,0,414,0,hidden,alpha=0.00` 就是它藏起来的状态），我们只换材质本身，
        // 所以顶部依然透明。
        if let effectView = view as? UIVisualEffectView {
            let currentStyle = (effectView.effect as? UIBlurEffect)?.style

            if currentStyle != .systemThinMaterialDark {
                effectView.effect = UIBlurEffect(style: .systemThinMaterialDark)
                hits.blur += 1
            }
            if effectView.backgroundColor != .clear {
                effectView.backgroundColor = .clear
            }
        }

        for child in view.subviews {
            apply(to: child, depth: depth + 1, limit: limit, hits: &hits)
        }
    }

    // MARK: - 导航栏的兜底

    private static var didScanForNavBar = false

    /// 导航栏那条 hook 到底装上没有（由 `activateAmoledTheme` 按 `NSClassFromString`
    /// 的结果写）。只有它为 false 时，`scanForNavBarOnce` 才有存在的意义。
    static var navBarHookInstalled = false

    /// 一次性兜底：`SPNavigationBar` **不在** Swift 类转储里，所以无法从转储确定它是
    /// ObjC 类还是"住在没被扫描的 image 里的 Swift 类"。前者 `NSClassFromString`
    /// 能找到、上面那条 hook 自然生效；后者找不到、hook 不会装 —— 那时从**活着的
    /// 视图树**里按短名找一次，找到就直接处理。
    ///
    /// ⚠️ 只在**直接 hook 没装上**时才扫（`navBarHookInstalled`）。第三轮日志里
    /// 这条和 `SPNavigationBar first layout` 同时出现，说明它当时是**冗余**跑的，
    /// 那条日志也就没法再拿来判断"类到底解析到没有"——修掉这个歧义。
    static func scanForNavBarOnce(in window: UIWindow?) {
        guard isEnabled, !navBarHookInstalled, !didScanForNavBar else { return }
        didScanForNavBar = true

        guard let root = window, let navBar = firstView(in: root, named: "SPNavigationBar") else {
            writeDebugLog("[AMOLED] navBar not found by scan — only the tab bar was stripped")
            return
        }

        strip(navBar)
        writeDebugLog("[AMOLED] navBar found by scan — stripped (direct hook was not installed)")
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
        AmoledTheme.navBarHookInstalled = true
    } else {
        writeDebugLog("[AMOLED] missing \(SPNavigationBarAmoledHook.targetName) — nav bar hook inactive")
    }

    writeDebugLog("[AMOLED] installed (enabled=\(AmoledTheme.isEnabled ? "ON" : "OFF"))")
}
