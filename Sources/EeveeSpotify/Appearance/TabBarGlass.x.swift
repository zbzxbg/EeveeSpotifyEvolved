import Foundation
import Orion
import UIKit
import ObjectiveC.runtime

/// 底部标签栏的**真液态玻璃**（主页 / 搜索 / 音乐库 / 创建 那四个）。
///
/// ── 为什么选这里做玻璃 ──────────────────────────────────────────────────────
/// 液态玻璃的设计意图就是"浮在内容之上的小控件"：标签栏的每一颗正好是这个尺寸
/// （真机 dump：`TabBarItemElementView@0,0,103,49`）。而且它**不是内容面**，
/// 上玻璃不会像听歌页那样把封面和按钮糊掉 —— 这正是照片 20 那个教训的反面。
///
/// ── 真类名（解密 IPA `dump-9.1.86.txt` ↔ 真机日志 17 双向核对）────────────────
/// ```
/// NavigationUI_TabBarImpl.TabBarView                 _TtC23NavigationUI_TabBarImpl10TabBarView
/// NavigationUI_TabBarImpl.TabBarItemElementView      _TtC23NavigationUI_TabBarImpl21TabBarItemElementView
/// CreateMenu_TabBarItemImpl.CreateMenuTabBarItemView _TtC25CreateMenu_TabBarItemImpl24CreateMenuTabBarItemView
/// ```
/// （真机 dump 里显示成 `TabBarView@0,0,414,83,id=elements-tabs-view-identifier` 与
///  `TabBarItemElementView@0,0,103,49,id=TabBar.Item.主页`／`.搜索`／`.音乐库`／
///  `CreateMenuTabBarItemView id=TabBar.Item.创建`。）
///
/// ── ⚠️ 三条来自真机教训的纪律 ───────────────────────────────────────────────
///   1. **玻璃插在图标下面，绝不盖在它上面。** 全屏歌词壳的 harness README 记着
///      这事的反例：玻璃会把放在它里面的字形"吸进"自己的背景，变成没边缘的软影子
///      （spoti.pw 的 issue #39）。所以我们把 `UIVisualEffectView` 插到
///      **索引 0**（图标之下），图标照旧清楚。
///   2. **只在目标自己布局时改，且幂等。** 听歌页上一版在壳的每帧布局里清别人的底色，
///      把滚动搞停了 —— 这里每个 hook 只碰**自己那个 target**，并且先判断再写。
///   3. **绝不动别人的底色/滚动效果。** 标签栏下面有没有系统自己的玻璃不是我们的事，
///      我们只往每一颗上面加一层，关掉即移除。
struct TabBarGlassGroup: HookGroup {}

enum TabBarGlass {

    static var isEnabled: Bool { UserDefaults.tabBarGlass }

    /// 玻璃层的关联键（挂在每一颗 tab 视图上，避免重复插）。
    private static var glassKey: UInt8 = 0

    /// 玻璃**内缩**多少（每边）。
    ///
    /// ── 为什么要内缩（真机照片 21 换来的）────────────────────────────────────
    /// iOS 27 的新设计**自己就有一条通栏玻璃筋**（那条"胶囊玻璃"），选中态还有
    /// Spotify 自己的 `TabBarSelectionController` 在滑动。我们原来铺满整块 103×49，
    /// 等于**给系统那条筋糊了一层膜** —— 现象就是"四个各自独立的玻璃方块"，
    /// 而用户要的恰恰是系统那条会滑动、有反射的筋。
    ///
    /// 所以改成：只在**图标那一小块**垫一层（每边缩 10pt），
    /// 系统的筋、滑块、图标全部露出来 —— 我们只做"别挡它"。
    private static let inset: CGFloat = 10

    /// 圆角：按玻璃自己的尺寸算胶囊。
    private static func cornerRadius(for size: CGSize) -> CGFloat {
        min(size.height, size.width) / 2
    }

    /// 给一颗 tab 上玻璃。幂等：已经插过就只更新 frame。
    @MainActor
    static func apply(to item: UIView) {
        guard isEnabled else {
            removeGlass(from: item)
            return
        }
        guard item.bounds.width > 1, item.bounds.height > 1 else { return }

        let glass: UIVisualEffectView
        if let existing = objc_getAssociatedObject(item, &glassKey) as? UIVisualEffectView {
            glass = existing
        } else {
            glass = makeGlassView()
            // ★ 插到**索引 0**：图标是 item 的子视图，插在最底下就永远不会盖住它。
            item.insertSubview(glass, at: 0)
            objc_setAssociatedObject(item, &glassKey, glass, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            writeDebugLog("[TabBarGlass] 玻璃已加在 \(className(item)) 上（内缩 \(Int(inset))pt，不盖系统的筋）")
        }

        // 内缩一圈：把系统那条玻璃筋与本地的选中滑块让出来。
        let size = CGSize(
            width: max(8, item.bounds.width - inset * 2),
            height: max(8, item.bounds.height - inset * 2)
        )
        glass.frame = CGRect(
            x: (item.bounds.width - size.width) / 2,
            y: (item.bounds.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
        glass.layer.cornerRadius = cornerRadius(for: size)
        glass.layer.cornerCurve = .continuous
        glass.clipsToBounds = true
        // 玻璃自己不吃触摸 —— 点击必须落到 tab 自己的手势上。
        glass.isUserInteractionEnabled = false
        // ⚠️ 内缩之后**不能**再用 autoresizingMask 跟尺寸：那会把 inset 吃掉，
        // 所以每次布局都由这里重算 frame（hook 在 target 自己的 `layoutSubviews` 上，
        // 只在它自己布局时跑，滚动中不会去动它）。
        glass.autoresizingMask = []
    }

    /// 造玻璃视图。
    ///
    /// ⚠️ **探测式**：iOS 26+ 上 `UIGlassEffect` 是真的（系统液态玻璃，带折射与边缘高光），
    /// 拿不到就退 `.systemUltraThinMaterialDark`（iOS 13+ 就有）。
    /// **不写 `#available`** —— 本工程 deployment target 是 iOS 14，静态版本判断过不了编译，
    /// 而且与本仓库既有做法（`AmoledTheme.x.swift` / `NowPlayingShell.x.swift`）一致。
    @MainActor
    private static func makeGlassView() -> UIVisualEffectView {
        let view = UIVisualEffectView(effect: nil)
        if let glassType = NSClassFromString("UIGlassEffect") as? UIVisualEffect.Type {
            view.effect = glassType.init()
            writeDebugLog("[TabBarGlass] 用的是系统真玻璃 UIGlassEffect")
        } else {
            view.effect = UIBlurEffect(style: .systemUltraThinMaterialDark)
            writeDebugLog("[TabBarGlass] 系统没有 UIGlassEffect — 退回材质")
        }
        return view
    }

    /// 关掉开关时拆掉（只拆我们自己插的那一层）。
    @MainActor
    static func removeGlass(from item: UIView) {
        guard let glass = objc_getAssociatedObject(item, &glassKey) as? UIVisualEffectView else { return }
        glass.removeFromSuperview()
        objc_setAssociatedObject(item, &glassKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    private static func className(_ view: UIView) -> String {
        NSStringFromClass(type(of: view))
    }
}

// MARK: - Hooks

/// 三颗普通标签：主页 / 搜索 / 音乐库。
///
/// 用 `layoutSubviews`：只在**这一颗自己**重新布局时跑，且只在插过一次之后更新 frame。
class TabBarItemGlassHook: ClassHook<UIView> {
    typealias Group = TabBarGlassGroup
    static let targetName = "NavigationUI_TabBarImpl.TabBarItemElementView"

    func layoutSubviews() {
        orig.layoutSubviews()
        let item = self.target
        onMainThreadSync {
            TabBarGlass.apply(to: item)
        }
    }
}

/// "创建"那颗。它是另一个模块的实现（`CreateMenu_TabBarItemImpl`），所以要单独挂。
class CreateTabBarItemGlassHook: ClassHook<UIView> {
    typealias Group = TabBarGlassGroup
    static let targetName = "CreateMenu_TabBarItemImpl.CreateMenuTabBarItemView"

    func layoutSubviews() {
        orig.layoutSubviews()
        let item = self.target
        onMainThreadSync {
            TabBarGlass.apply(to: item)
        }
    }
}

func activateTabBarGlass() {
    var installed: [String] = []

    if NSClassFromString(TabBarItemGlassHook.targetName) != nil {
        installed.append("TabBarItem")
    } else {
        writeDebugLog("[TabBarGlass] missing \(TabBarItemGlassHook.targetName)")
    }

    if NSClassFromString(CreateTabBarItemGlassHook.targetName) != nil {
        installed.append("CreateMenu")
    } else {
        writeDebugLog("[TabBarGlass] missing \(CreateTabBarItemGlassHook.targetName)（创建那颗先不做）")
    }

    guard !installed.isEmpty else {
        writeDebugLog("[TabBarGlass] 两个目标都没有 — 整组不装")
        return
    }

    TabBarGlassGroup().activate()
    writeDebugLog(
        "[TabBarGlass] installed (\(installed.joined(separator: " + ")))"
            + " enabled=\(UserDefaults.tabBarGlass ? "ON" : "OFF")"
    )
}
