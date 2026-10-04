import Foundation
import Orion
import UIKit
import ObjectiveC.runtime

/// 音乐库里的**搜索页**（头部那颗放大镜打开的那一页）—— 照 pw 的 `Redesigned/Library/LibrarySearch.x`。
///
/// ── 只改形状，不画玻璃 ──────────────────────────────────────────────────────
/// pw 的原文：那两个形状**自己里面**已经画了 `Reprise_LiquidGlassKit.LiquidGlass.SearchBarView`
/// （= 系统玻璃），"**缺的只是形状**" ⇒ 我们把圆角改成**半高（胶囊）**就完事，
/// 一行玻璃代码都不写（这与仓库"两条路互斥、别叠玻璃"的纪律一致）。
///
/// ── 真机结构（pw 的树）──────────────────────────────────────────────────────
/// ```
/// YourLibrarySearchView                                     ← hook 目标
/// ├ 与音乐库页同一个 YourLibraryContentView + 列表（不动）
/// └ YourLibrarySearchHeaderView 402x142
///   ├ LiquidGlass.GradientView                              ← 顶部灰纱（收掉，复用头部那份判据）
///   └ {0, 94} SearchHeaderLibraryLayout，两个 32pt 高的形状：
///     ├ id=Components.Header.UI.Toolbar.SearchField 320x32 r=4      ← 变胶囊
///     └ id=Components.Header.UI.Toolbar.ButtonContainer 58x32 r=4   ← Cancel，也变胶囊
/// ```
///
/// ⚠️ 还原：两个形状的原半径/原圆角曲线记在**它们自己身上**（关联对象），开关关掉写回。
enum LibrarySearchMetrics {
    static let fieldIdentifier = "Components.Header.UI.Toolbar.SearchField"
    static let buttonIdentifier = "Components.Header.UI.Toolbar.ButtonContainer"
    /// 低于这个高度就不碰（布局第一拍上它们是 0 高，算出来的"半高"是 0 ⇒ 会把形状抹平）。
    static let minHeight: CGFloat = 24
}

enum LibrarySearchAppearance {

    /// 与头部/列表**共用同一个开关**（`UserDefaults.libraryLargeTitle`）。
    static var isEnabled: Bool { LibraryAppearance.isEnabled }

    private static var originalRadiusKey: UInt8 = 0
    private static var originalCurveKey: UInt8 = 0
    private static var didReport = false
    private static var didReportMissing = false

    /// 由 hook 在搜索页每次布局时调用。幂等。
    @MainActor
    static func apply(to searchView: UIView) {
        guard let header = LibraryAppearance.findView(in: searchView, where: {
            NSStringFromClass(type(of: $0)).contains("YourLibrarySearchHeaderView")
        }) else {
            // 没找到头部 ⇒ 自报一行（这一片是"静默不生效"最难受的那一类）。
            if !didReportMissing, searchView.bounds.width > 100 {
                didReportMissing = true
                writeDebugLog(
                    "[Library] ⚠️ the in-library search page has no YourLibrarySearchHeaderView"
                        + " — this build may name it differently, so the field is left as it is"
                )
            }
            return
        }

        if !isEnabled {
            restore(in: header)
            return
        }

        // 灰纱：与音乐库页**同一份判据**（`LibraryAppearance.clearTopEdgeScrim`），只是换了个头部。
        LibraryAppearance.clearTopEdgeScrim(in: header)

        var shaped = 0
        for identifier in [LibrarySearchMetrics.fieldIdentifier, LibrarySearchMetrics.buttonIdentifier] {
            guard let shape = LibraryAppearance.findView(in: header, where: {
                $0.accessibilityIdentifier == identifier
            }) else { continue }
            if capsule(shape) { shaped += 1 }
        }

        if !didReport, shaped > 0 {
            didReport = true
            writeDebugLog(
                "[Library] the in-library search field and Cancel are capsules now"
                    + " (\(shaped) shape(s); the glass inside them is Spotify's own, we only changed the shape)"
            )
        } else if !didReportMissing, shaped == 0, header.bounds.height > 1 {
            didReportMissing = true
            writeDebugLog(
                "[Library] ⚠️ the in-library search header has neither \(LibrarySearchMetrics.fieldIdentifier)"
                    + " nor \(LibrarySearchMetrics.buttonIdentifier) — this build may name them differently"
            )
        }
    }

    /// 换成胶囊（半高 + 连续圆角）。返回"这一次真的量到了尺寸"。
    @MainActor
    private static func capsule(_ shape: UIView) -> Bool {
        let height = shape.bounds.height
        guard height >= LibrarySearchMetrics.minHeight else { return false }
        let layer = shape.layer
        if objc_getAssociatedObject(shape, &originalRadiusKey) == nil {
            objc_setAssociatedObject(
                shape,
                &originalRadiusKey,
                NSNumber(value: Double(layer.cornerRadius)),
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
            objc_setAssociatedObject(
                shape,
                &originalCurveKey,
                NSNumber(value: layer.cornerCurve == .continuous),
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        }
        let radius = height / 2
        if layer.cornerRadius != radius { layer.cornerRadius = radius }
        if layer.cornerCurve != .continuous { layer.cornerCurve = .continuous }
        if !layer.masksToBounds { layer.masksToBounds = true }
        return true
    }

    @MainActor
    private static func restore(in header: UIView) {
        for identifier in [LibrarySearchMetrics.fieldIdentifier, LibrarySearchMetrics.buttonIdentifier] {
            guard let shape = LibraryAppearance.findView(in: header, where: {
                $0.accessibilityIdentifier == identifier
            }) else { continue }
            guard let radius = objc_getAssociatedObject(shape, &originalRadiusKey) as? NSNumber else { continue }
            let layer = shape.layer
            if layer.cornerRadius != CGFloat(radius.doubleValue) {
                layer.cornerRadius = CGFloat(radius.doubleValue)
            }
            let wasContinuous = (objc_getAssociatedObject(shape, &originalCurveKey) as? NSNumber)?.boolValue ?? false
            if layer.cornerCurve != (wasContinuous ? .continuous : .circular) {
                layer.cornerCurve = wasContinuous ? .continuous : .circular
            }
            objc_setAssociatedObject(shape, &originalRadiusKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            objc_setAssociatedObject(shape, &originalCurveKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        didReport = false
    }
}

// MARK: - Hook

/// 库内搜索页：`YourLibrary_YourLibraryXImpl.YourLibrarySearchView`
/// （9.1.88 的 IPA 里逐字在：`dump-9.1.88.txt`）。
///
/// 这一页**没有 0.5s 节拍**，所以挂在它自己的布局回合上（头部与形状都在这条链里）；
/// 开关关掉时同一个 hook 会把它写回。
class LibrarySearchStyleHook: ClassHook<UIView> {
    typealias Group = LibraryAppearanceGroup
    static let targetName = "YourLibrary_YourLibraryXImpl.YourLibrarySearchView"

    func layoutSubviews() {
        orig.layoutSubviews()
        let view = self.target
        onMainThreadSync {
            LibrarySearchAppearance.apply(to: view)
        }
    }
}
