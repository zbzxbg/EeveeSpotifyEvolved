import Foundation
import UIKit

/// 这一份构建跑的是不是**新设计语言**（Apple 的 Liquid Glass，iOS 26+；Spotify 内部叫 *Reprise*）。
///
/// 两个信号，**取或**：
///
/// 1. **构建意图**（我们可控）：Spotify 在原版 `Info.plist` 里写了
///
///        UIDesignRequiresCompatibility = true
///
///    等于"要求系统用兼容模式跑我"（2026-10-01 从解密 IPA 里读到的实际值）。
///    构建脚本（`build-ipa-local.sh` / CI 的 `liquid_glass` 开关）做的就是把这个键**删掉**。
///
/// 2. **运行期观察**（兜底）：导航栏子树里出现了新设计才有的视图 —— SwiftUI 托管的
///    `NavigationBarPlatterContainer_v2` / `PlatterContainerHostingView<…>`、
///    系统的 `ScrollEdgeEffectView`。这是**正信号**：旧设计里一个都不会出现
///    （2026-10-01 的日志 8 = 兼容构建，全程 0 处；日志 9 = 玻璃构建，大量）。
///
/// 为什么需要第 2 个：万一将来某个 iOS 开始**忽略** `UIDesignRequiresCompatibility`
/// （Apple 说这个键是过渡用的），只看第 1 个信号就会判错，我们那些"旧设计补丁"就会重新
/// 叠到玻璃上。有了第 2 个，即使键被忽略，我们也会在第一次导航栏布局后自动让位。
///
/// ⚠️ 刻意**不做运行时类枚举**（`objc_getClassList`）—— 本仓库为这个栽过两次启动崩溃
/// （见 `ViewTreeDumper` 顶部那三条纪律）。第 2 个信号是在**已经在走的视图子树**里顺手认类名，
/// 零额外风险。
enum NewDesignLanguage {

    /// 信号 1：构建时那个键还在不在。
    static let plistSaysNewDesign: Bool = {
        let value = Bundle.main.object(forInfoDictionaryKey: "UIDesignRequiresCompatibility")

        if let flag = value as? Bool { return !flag }
        if let number = value as? NSNumber { return !number.boolValue }

        // 键不在 = 我们的构建已经把它删了 = 新设计语言。
        return true
    }()

    private static var observedNewDesign = false
    private static var didReportObservation = false

    /// 由 `AmoledTheme` 在导航栏那次遍历里看到新设计标志时调用。
    static func noteObservedNewDesign() {
        guard !observedNewDesign else { return }
        observedNewDesign = true

        writeDebugLog("[NewDesign] observed the new design in the nav bar (SwiftUI platter) — yielding from now on")
    }

    /// 当前是不是新设计语言。**进程内只增不减**：一旦观察到过，就一直是。
    static var isActive: Bool { plistSaysNewDesign || observedNewDesign }

    /// 让位时打一行说明（只打一次），把"为什么我们什么都不做"写进日志。
    static func reportYieldingOnce(by source: String) {
        guard !didReportObservation else { return }
        didReportObservation = true

        writeDebugLog(
            "[NewDesign] \(source) yielding to the system's design"
                + " (plist=\(plistSaysNewDesign ? "new" : "compat")"
                + " observed=\(observedNewDesign ? "yes" : "no"))"
        )
    }
}
