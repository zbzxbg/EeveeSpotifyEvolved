import Foundation
import Orion
import UIKit

/// 新设计语言（iOS 26 / Spotify "Reprise"）下，**我们给旧设计打的补丁要主动让位**。
///
/// 为什么：新设计里 Spotify 已经自带玻璃 —— 导航栏是 SwiftUI 托管的 Platter
/// （`NavigationBarPlatterContainer_v2` / `PlatterContainerHostingView<NavigationBarPlatterContent>`），
/// 标签栏自带 `UIVisualEffectView` + `_UIVisualEffectBackdropView`，内容滚到其下时由系统的
/// `ScrollEdgeEffectView` 负责边缘模糊。我们那些补丁是为**旧设计**（没有任何底色/材质）打的，
/// 叠上去只会把玻璃压成一块不透的深色。
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
