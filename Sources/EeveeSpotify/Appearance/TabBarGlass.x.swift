import Foundation
import Orion
import UIKit
import ObjectiveC.runtime

/// 底部标签栏玻璃 —— 第 3 版：**一条玻璃胶囊**，不是四块。
///
/// ── 前两版错在哪（真机实证，别再犯）─────────────────────────────────────────
///   1. **第一版**：给每一颗标签各铺一块 `103×49` 的玻璃 → 既不融合、还盖住了
///      Spotify 自己的选中滑块；用户反馈"更难看了"；
///   2. **第二版**：同样每颗一块，只是内缩 10pt → 还是四块，方向没变。
///   用户要的是**照片 21 那种一条通栏的胶囊玻璃筋**。
///
/// ── 为什么"每颗一块"注定不像（这次终于拿到的结构）────────────────────────────
/// 真机 dump（日志 19）：
/// ```
/// TabBarView(414x83, id=elements-tabs-view-identifier)
/// └ TabBarCompactView(414x83) ★有渐变层                ← 这条栏的"底"
///   └ UIStackView(id=tabs-container-view-identifier)   ← 四颗在这条 stack 里**并排成兄弟**
///     ├ TabBarItemElementView(id=TabBar.Item.主页)  → Icon + Label
///     ├ …搜索 / 音乐库
///     └ CreateMenuTabBarItemView(id=TabBar.Item.创建) → 自带一个 corner=20 的圆底
/// ```
/// 四颗是 **stack 里的兄弟视图**。MeloX 那种"靠近就融合"靠的是把它们包进**同一个
/// 玻璃容器**（`GlassEffectContainer`）——那要求把 Spotify 的四颗视图搬进我们的容器，
/// **会打断它们的布局与手势**，得不偿失。
///
/// 所以这一版改走"**一条**"这条路：
///   · 在**栏这一层**（`TabBarCompatView` 之上、图标 stack 之下）铺**一条**玻璃胶囊；
///   · 左右各留 `sideInset`、上下各留 `verticalInset`，圆角 = 胶囊；
///   · Spotify 的图标、标签、选中滑块**全部不动**，浮在这条玻璃上；
///   · 这就是照片 21 的形状。
///
/// ⚠️ 尺寸依据（都来自 dump，不是猜的）：
///   · 栏 `414×83`  —— 日志 19 的 `TabBarView(414x83)`
///   · 「创建」那颗自带圆底 `corner=20.0` —— 说明 Spotify 自己用的半径是 20
///     （我们的胶囊半径更大没关系：胶囊 = 半高，那才是照片里那条的形状）
struct TabBarGlassGroup: HookGroup {}

enum TabBarGlassPlate {

    static var isEnabled: Bool { UserDefaults.tabBarGlass }

    /// 玻璃层挂在栏上的关联键。
    private static var plateKey: UInt8 = 0

    /// 左右留边。照片 21 里那条胶囊**不是**贴边的，两侧有明显留白。
    /// 先取 8pt（Spotify 自己的图标容器也有 8pt 的边距惯例，见各屏 dump 里的 `@8,...`）。
    private static let sideInset: CGFloat = 8
    /// 上下留边。栏高 83，胶囊高度取 83 - 上下各 6 = 71（更接近照片里那种"厚胶囊"）。
    private static let verticalInset: CGFloat = 6

    /// 给**栏**铺一条玻璃胶囊。幂等：已经铺过就只更新 frame。
    @MainActor
    static func apply(to bar: UIView) {
        guard isEnabled else {
            removePlate(from: bar)
            return
        }
        guard bar.bounds.width > 1, bar.bounds.height > 1 else { return }

        let plate: UIVisualEffectView
        if let existing = objc_getAssociatedObject(bar, &plateKey) as? UIVisualEffectView {
            plate = existing
        } else {
            plate = makeGlassView()
            // ★ 插到**索引 0**：图标 stack 是栏的子视图，插在最底下就不会盖住它们，
            //   也不会吃到触摸。Spotify 自己的渐变层也在栏里，同样在它下面动不了。
            bar.insertSubview(plate, at: 0)
            objc_setAssociatedObject(bar, &plateKey, plate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            writeDebugLog("[TabBarPlate] 玻璃胶囊已铺在 \(className(bar)) 上")
        }

        let width = max(16, bar.bounds.width - sideInset * 2)
        let height = max(16, bar.bounds.height - verticalInset * 2)
        plate.frame = CGRect(
            x: (bar.bounds.width - width) / 2,
            y: (bar.bounds.height - height) / 2,
            width: width,
            height: height
        )
        // 胶囊：半径取半高。
        plate.layer.cornerRadius = height / 2
        plate.layer.cornerCurve = .continuous
        plate.clipsToBounds = true
        plate.isUserInteractionEnabled = false
        // 不用 autoresizingMask：那会把留边吃掉；frame 由每次布局重算
        // （hook 挂在栏自己的 `layoutSubviews`，只在它自己布局时跑）。
        plate.autoresizingMask = []
    }

    @MainActor
    static func removePlate(from bar: UIView) {
        guard let plate = objc_getAssociatedObject(bar, &plateKey) as? UIVisualEffectView else { return }
        plate.removeFromSuperview()
        objc_setAssociatedObject(bar, &plateKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    /// 造玻璃视图。
    ///
    /// ⚠️ **探测式**：iOS 26+ 上 `UIGlassEffect` 是真的（系统液态玻璃，带折射与边缘高光），
    /// 拿不到就退 `.systemUltraThinMaterialDark`（iOS 13+ 就有）。
    /// **不写 `#available`** —— 与本仓库既有做法一致（`AmoledTheme.x.swift`）。
    @MainActor
    private static func makeGlassView() -> UIVisualEffectView {
        let view = UIVisualEffectView(effect: nil)
        if let glassType = NSClassFromString("UIGlassEffect") as? UIVisualEffect.Type {
            view.effect = glassType.init()
            writeDebugLog("[TabBarPlate] 用的是系统真玻璃 UIGlassEffect")
        } else {
            view.effect = UIBlurEffect(style: .systemUltraThinMaterialDark)
            writeDebugLog("[TabBarPlate] 系统没有 UIGlassEffect — 退回材质")
        }
        return view
    }

    private static func className(_ view: UIView) -> String {
        NSStringFromClass(type(of: view))
    }
}

// MARK: - Hook

/// 挂在**标签栏容器**上：这条栏的布局一变，就重算那条玻璃胶囊的 frame。
///
/// 真类名：`NavigationUI_TabBarImpl.TabBarView`
/// （IPA `_TtC23NavigationUI_TabBarImpl10TabBarView` ↔ 真机 dump
///  `#1 NavigationUI_TabBarImpl.TabBarView frame=(0,0 414x83) id=elements-tabs-view-identifier`）。
///
/// ⚠️ 只碰**这一个目标**（栏自己）：不听歌页那版"遍历整窗 + 每帧清别人底色"，
/// 所以不会影响滚动或别处。
class TabBarPlateHook: ClassHook<UIView> {
    typealias Group = TabBarGlassGroup
    static let targetName = "NavigationUI_TabBarImpl.TabBarView"

    func layoutSubviews() {
        orig.layoutSubviews()
        let bar = self.target
        onMainThreadSync {
            TabBarGlassPlate.apply(to: bar)
        }
    }
}

func activateTabBarGlass() {
    guard NSClassFromString(TabBarPlateHook.targetName) != nil else {
        writeDebugLog("[TabBarPlate] missing \(TabBarPlateHook.targetName) — 未装")
        return
    }
    TabBarGlassGroup().activate()
    writeDebugLog(
        "[TabBarPlate] installed (enabled=\(UserDefaults.tabBarGlass ? "ON" : "OFF"))"
            + " — 一条玻璃胶囊，四颗标签浮在它上面"
    )
}
