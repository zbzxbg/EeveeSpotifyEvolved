import Foundation
import Orion
import UIKit

/// 新设计语言（iOS 26 / Spotify "Reprise"）下，**我们给旧设计打的补丁要主动让位**。
///
/// 为什么：新设计里 Spotify 已经自带玻璃 —— 导航栏是 SwiftUI 托管的 Platter
/// （`NavigationBarPlatterContainer_v2` / `PlatterContainerHostingView<NavigationBarPlatterContent>`），
/// 内容滚到其下时由系统的 `ScrollEdgeEffectView` 负责边缘模糊。我们那些补丁是为**旧设计**
/// （没有任何底色/材质）打的，叠上去只会把玻璃压成一块不透的深色。
///
/// ⚠️ **2026-10-02 更正**：这里原来说"**标签栏**自带 `UIVisualEffectView` +
/// `_UIVisualEffectBackdropView`" —— 那是**错的**。日志 20 的全树 dump 里
/// `UIVisualEffectView` **只有我们自己铺的那一块**（`(8,6 398x71)`），标签栏本身没有任何材质；
/// 系统玻璃只在**上面**那条（Platter / `ScrollEdgeEffectView`）。
///
/// ⚠️ **2026-10-13 再更正**：那句话的后半（"标签栏那条玻璃得我们自己做"）也**过期**了 ——
/// 我们现在是**叠一条系统 `UITabBar`**（`TabBarSystemGlass.x.swift`，照 spoti.pw 的做法），
/// 玻璃由 iOS 26 自己画；**自绘那块已经删除**（`TabBarGlass.x.swift` 只剩几何与标签内容取舍）。
///
/// 真机证据（日志 9，玻璃构建）：
///   · `[AMOLED] SPNavigationBar first layout — scrim=0 blur=0 bar=0 barBg=0 gradient=0`
///     —— 旧那两层（灰 scrim `UIImageView` + 同级 `UIVisualEffectView`）**已经不存在**；
///   · 用户反馈："标签栏看起来正常不透，不是毛玻璃也不是液态玻璃"
///     —— 正是 `TabBarGradientView`（黑→透明、正好盖住整条）与 AMOLED 插的那层
///     `systemThinMaterialDark` 叠在系统玻璃上的结果。
///
/// 判据见 `NewDesignLanguage`：只在**删掉了 `UIDesignRequiresCompatibility` 的构建**里生效；
/// 跑兼容模式的老构建一切照旧。
struct NewDesignYieldGroup: HookGroup {}

/// 旧设计的"标签栏渐隐"遮罩：一层黑→透明渐变，正好覆盖整条标签栏
/// （真机树：`TabBarGradientView@0,-112,414,195`）。
///
/// 新设计里这个角色由系统的 `ScrollEdgeEffectView` 承担，所以这层要藏掉 ——
/// 否则它会把玻璃压暗成一块实心条。**默认就藏**，不再做成开关
/// （原来那个「隐藏标签栏渐隐」开关在深色主题下看不出差别，已经删了）。
///
/// ⚠️ 只藏**我们判定为新设计**时的那一层；兼容模式的构建里这个 hook 根本不装。
class TabBarGradientYieldHook: ClassHook<UIView> {
    typealias Group = NewDesignYieldGroup
    static let targetName = "_TtC23NavigationUI_TabBarImpl18TabBarGradientView"

    func layoutSubviews() {
        orig.layoutSubviews()

        // ★ 运行期兜底信号（`NewDesignLanguage` 的信号 2）：兼容构建里才扫一次。
        // 原观察点在 AMOLED 的导航栏遍历里；2026-10-02 删 AMOLED 时搬到这里 ——
        // 它是"万一将来 iOS 忽略 `UIDesignRequiresCompatibility`"时唯一能救我们的东西。
        if let window = self.target.window {
            onMainThreadSync { observeNewDesignMarkersIfNeeded(in: window) }
        }

        // 判据放在**运行期**而不是装配期：`plistSaysNewDesign` 之外还有"运行期观察到 Platter"
        // 那个兜底信号（见 `NewDesignLanguage`），它是在第一次导航栏布局之后才可能变真的。
        // 兼容模式的构建里这个 hook 也会装，但这里会直接返回，标签栏渐隐照旧。
        guard NewDesignLanguage.isActive else { return }

        // 幂等：已经是隐藏状态就什么都不做（在 `layoutSubviews` 里改视图，必须幂等）。
        guard !self.target.isHidden else { return }
        self.target.isHidden = true

        guard !didReportGradientYield else { return }
        didReportGradientYield = true
        writeDebugLog("[NewDesign] hid TabBarGradientView — the system's scroll-edge effect does this now")
    }
}

private var didReportGradientYield = false

/// 运行期兜底信号的**唯一观察点**（`NewDesignLanguage` 的信号 2）。
///
/// 为什么要有它：万一将来某个 iOS 开始**忽略** `UIDesignRequiresCompatibility`，
/// 只看"构建意图"会判错 —— 我们那些给旧设计打的补丁就会重新叠到玻璃上。
///
/// 两条纪律（沿用 AMOLED 那版）：
///   · 只在"构建意图说这是兼容模式"时才扫（`isActive` 一真就零开销）；
///   · **只扫一次**（成不成都不再扫），而且是在**已经在走的视图子树**里认类名 ——
///     刻意不做运行时类枚举（本仓库为 `objc_getClassList` 崩过两次）。
@MainActor
private func observeNewDesignMarkersIfNeeded(in window: UIView) {
    guard !NewDesignLanguage.isActive, !didObserveNewDesignMarkers else { return }
    didObserveNewDesignMarkers = true

    var found = false
    func walk(_ node: UIView, _ depth: Int) {
        guard !found, depth <= 12 else { return }
        let name = NSStringFromClass(type(of: node))
        if name.contains("Platter") || name.contains("ScrollEdgeEffect") {
            found = true
            return
        }
        for sub in node.subviews { walk(sub, depth + 1) }
    }
    walk(window, 0)

    if found { NewDesignLanguage.noteObservedNewDesign() }
}

private var didObserveNewDesignMarkers = false

func activateNewDesignYield() {
    // ⚠️ 这里**不按 plist 键决定装不装**：那个键将来可能被系统忽略
    // （Apple 说它是过渡用的），而那时我们仍需要把渐隐遮罩藏掉。
    // 所以只要类在就装，判据留给 `layoutSubviews` 里的 `NewDesignLanguage.isActive`。
    guard NSClassFromString(TabBarGradientYieldHook.targetName) != nil else {
        writeDebugLog("[NewDesign] missing \(TabBarGradientYieldHook.targetName) — gradient yield inactive")
        return
    }

    NewDesignYieldGroup().activate()
    writeDebugLog(
        "[NewDesign] gradient-yield hook on"
            + " (plist=\(NewDesignLanguage.plistSaysNewDesign ? "new" : "compat")"
            + " active=\(NewDesignLanguage.isActive ? "yes" : "no"))"
    )
}
