import Foundation
import Orion
import UIKit
import ObjectiveC.runtime

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
        /// 遍历途中看到了**新设计才有的视图**（SwiftUI Platter / 系统滚动边缘效果）。
        /// 正信号 —— 旧设计里一个都不会出现（日志 8 全程 0 处，日志 9 大量）。
        var newDesignMarker = false

        var summary: String {
            "scrim=\(scrim) blur=\(blur) bar=\(bar) barBg=\(barBackground) gradient=\(gradient)"
                + (newDesignMarker ? " newDesign=1" : "")
        }
    }

    private static var reportedClasses: Set<String> = []

    /// AMOLED 是给**旧设计**打的补丁，新设计下要**主动让位**（判定与两个信号见
    /// `NewDesignLanguage`；让位时的说明日志也由它打，只打一次）。
    ///
    /// 一句话：旧导航栏有灰 scrim + 一层模糊、旧标签栏完全没底色，所以我们才需要动手；
    /// 新设计里 Spotify 自己已经有玻璃 —— 导航栏那两层**已经不存在**（日志 9：`scrim=0 blur=0`），
    /// 标签栏自带 `UIVisualEffectView`。再按旧方案插材质，只会把系统玻璃压成一块不透的深色
    /// （用户 2026-10-01 的反馈正是这个："标签栏看起来正常不透"）。
    ///
    /// 只在**这份构建真的进入了新设计语言**时让位；跑兼容模式的构建一切照旧。

    /// 扫一遍 bar 的子树（加上贴顶的同级兄弟），做两件事（仿 Apple Music）：
    ///   1. 藏掉 `_UIBarBackground` 里的灰色渐变遮罩 `UIImageView`；
    ///   2. 把 `UIVisualEffectView` 的模糊换成深色材质。
    ///
    /// `alwaysOpaqueBlack = true` 时另加三件事：给 bar 自己铺黑底、涂黑
    /// `_UIBarBackground`、隐藏 `*Gradient*` —— 代价是封面不再从标题下透出，
    /// 见那个常量上的说明。
    static func strip(_ view: UIView, isNavBar: Bool = false) {
        guard isEnabled else { return }

        // 新设计下让位（见 `NewDesignLanguage`）：**只在"构建意图"或"已观察到"任一成立时**跳过遍历。
        // 之所以不在这里直接 `return` 而是先判一次：兼容模式下我们要照常走完，顺手在导航栏那次
        // 遍历里找新设计的正信号（将来键被系统忽略时靠它兜底）。
        if NewDesignLanguage.isActive {
            NewDesignLanguage.reportYieldingOnce(by: "AMOLED")
            return
        }

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

        // 只在**导航栏**那次遍历里认新设计标志：导航栏子树里出现 SwiftUI Platter /
        // 系统滚动边缘效果 = 这份构建其实跑在新设计下（哪怕 plist 那个键还写着兼容）。
        // 认到之后 `NewDesignLanguage.isActive` 变真，从下一次起我们就让位。
        if isNavBar, hits.newDesignMarker {
            NewDesignLanguage.noteObservedNewDesign()
        }
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

        // 新设计的**正信号**（旧设计里一个都不会出现，见 `NewDesignLanguage` 的说明）：
        //   `NavigationBarPlatterContainer_v2` / `PlatterContainerHostingView<…>` —— 导航栏那层
        //   SwiftUI Platter；`ScrollEdgeEffectView` —— 系统接管"内容滚到栏下"的边缘效果。
        if name.contains("Platter") || name.contains("ScrollEdgeEffect") {
            hits.newDesignMarker = true
        }

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
            // ⚠️ `UIBlurEffect` **没有**公开的 `style` 读取器（只有 `init(style:)`），
            // 所以"回读比较"这条路本身不成立 —— 上一版就是在这里编译失败的
            // （`value of type 'UIBlurEffect' has no member 'style'`）。
            //
            // 改成用关联对象记住"这一层已经换过了"：既避免每次 `layoutSubviews` 都重建
            // effect（滚动时白白触发重配置），也不需要自己维护一张会随视图回收而失效的表。
            // 键与写法照 `UpsellPopupBlocker.x.swift` 的既有做法。
            if !isBlurRetargeted(effectView) {
                effectView.effect = UIBlurEffect(style: .systemThinMaterialDark)
                markBlurRetargeted(effectView)
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
        // 标签栏自己没有任何底色（日志 6 实证），所以 AM 那层材质得我们插。
        AmoledTheme.ensureTabBarMaterial(in: self.target)
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
        // `isNavBar: true` —— 只有这次遍历会去认"新设计"的正信号（SwiftUI Platter）。
        AmoledTheme.strip(self.target, isNavBar: true)
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

// MARK: - 关联对象：记录"这层模糊已经换成深色材质"

/// file-scope 的 `var` 地址是稳定的，这是本仓库既有的关联对象键写法
/// （见 `UpsellPopupBlocker.x.swift` 的 `upsellPopupAssociationKey`）。
private var amoledBlurRetargetedKey: UInt8 = 0

private func isBlurRetargeted(_ view: UIVisualEffectView) -> Bool {
    (objc_getAssociatedObject(view, &amoledBlurRetargetedKey) as? NSNumber)?.boolValue == true
}

private func markBlurRetargeted(_ view: UIVisualEffectView) {
    objc_setAssociatedObject(
        view,
        &amoledBlurRetargetedKey,
        NSNumber(value: true),
        .OBJC_ASSOCIATION_RETAIN_NONATOMIC
    )
}

// MARK: - 标签栏：自己插一层 AM 式深色材质

/// 标签栏材质层的关联对象键（存的是那个 `UIVisualEffectView` 本身）。
private var amoledTabBarMaterialKey: UInt8 = 0

extension AmoledTheme {

    /// 给标签栏补一层 Apple Music 式的深色材质。
    ///
    /// 为什么是"插一层"而不是"改底色"：日志 6 的真机树证明标签栏那一整支**没有任何
    /// 底色或材质** —— `TabBarContainer.overlayView`、`stackView`、`TabBarView`、
    /// `TabBarCompactView` 的 `backgroundColor` 全是空，子树里也没有 `_UIBarBackground`
    /// 或 `UIVisualEffectView`。Spotify 的"栏"观感完全来自它上方那层渐变遮罩
    /// （`TabBarGradientView`，由「隐藏标签栏渐隐」开关管着）。所以要让标签栏有 AM 那种
    /// 材质，只剩自己插一层这条路。
    ///
    /// 三条自我约束：
    ///   · 插在**最底层**（index 0）且 `isUserInteractionEnabled = false` —— 不挡 tab 点击；
    ///   · 尺寸跟随（`autoresizingMask`），被 `Encore` 重排挤走就放回最底；
    ///   · 只在 `amoledEnabled` 打开时插；关掉开关不再管它（下次启动就不带了）。
    static func ensureTabBarMaterial(in tabBar: UIView) {
        guard isEnabled else { return }

        // ⚠️ 新设计下**不要插**：这一层的作用是补上旧设计里"标签栏完全没底色"的空缺，
        // 而新设计的标签栏已经有系统玻璃 —— 我们的 `systemThinMaterialDark` 叠在下面、
        // 玻璃罩在上面，合起来就是一块不透的深色（用户反馈的"正常的不透底栏"）。
        // 如果之前（让位信号还没出现时）已经插过，这里顺手拔掉。
        if NewDesignLanguage.isActive {
            NewDesignLanguage.reportYieldingOnce(by: "AMOLED tab bar")
            removeTabBarMaterialIfAny(from: tabBar)
            return
        }

        if let material = objc_getAssociatedObject(tabBar, &amoledTabBarMaterialKey) as? UIView {
            if material.superview !== tabBar {
                tabBar.insertSubview(material, at: 0)
                writeDebugLog("[AMOLED] tab bar material re-inserted (Encore moved it out)")
            } else if tabBar.subviews.first !== material {
                tabBar.insertSubview(material, at: 0)
            }

            if material.frame != tabBar.bounds {
                material.frame = tabBar.bounds
            }
            return
        }

        let material = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
        material.isUserInteractionEnabled = false
        material.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        material.frame = tabBar.bounds
        tabBar.insertSubview(material, at: 0)

        objc_setAssociatedObject(
            tabBar,
            &amoledTabBarMaterialKey,
            material,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )

        writeDebugLog("[AMOLED] tab bar material inserted (systemThinMaterialDark)")
    }

    /// 拔掉我们插过的那层标签栏材质（让位时用；只认我们自己的关联对象，不碰别人的视图）。
    private static func removeTabBarMaterialIfAny(from tabBar: UIView) {
        guard let material = objc_getAssociatedObject(tabBar, &amoledTabBarMaterialKey) as? UIView else {
            return
        }

        material.removeFromSuperview()
        objc_setAssociatedObject(tabBar, &amoledTabBarMaterialKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        writeDebugLog("[AMOLED] removed the tab bar material we had inserted — handing the bar back to the system glass")
    }
}
