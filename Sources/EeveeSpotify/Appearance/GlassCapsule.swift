import Foundation
import UIKit

/// 底部那两条玻璃胶囊的**公共尺寸与做法**（标签栏 / 迷你播放条共用）。
///
/// 为什么单开一个文件：用户 2026-10-02 要求「迷你播放条也做成液态玻璃，高度、宽度
/// 和下面的导航栏一样」。两条要是各算各的高度，迟早会漂（v4.6 之前就漂过 40 ↔ 56）——
/// 所以**高度、圆角、材质、那圈描边高光只留这一份定义**。
///
/// **宽度不共用**：标签栏那条贴它四颗图标（真机 312），迷你条那条贴它自己的内容（真机 398）——
/// 这是用户 2026-10-02 选的 A 方案（「等高同款式，宽度贴迷你条自己」）。
enum GlassCapsule {

    /// 胶囊高度。**真机实测值**：标签栏那条按"有文字"版式量出来就是 `60`
    /// （图标 ∪ 文字 = 44 + 上下各 8；日志 26 自报 `胶囊 (51,-3 312x60)`）。
    /// 迷你条的内容是 56，比它矮 4 → 上下各让 2pt 就同高。
    static let height: CGFloat = 60

    /// 圆角 = 半高（胶囊形状）。
    static var cornerRadius: CGFloat { height / 2 }

    /// 边缘高光：借 **MeloX** 的手法 —— 他们旧系统兜底那一支画的是
    /// `Capsule().stroke(.white.opacity(0.32), lineWidth: 0.75)`。
    /// 我们这条是深色玻璃，取比他们更淡一点，只负责把边缘"立"起来。
    private static let edgeHighlightWidth: CGFloat = 0.75
    private static let edgeHighlightAlpha: CGFloat = 0.22

    /// 这版系统有没有真玻璃（两处日志都要用）。
    static var hasSystemGlass: Bool { NSClassFromString("UIGlassEffect") != nil }

    /// 造一块玻璃视图。
    ///
    /// ⚠️ **探测式**：iOS 26+ 上 `UIGlassEffect` 是真的（系统液态玻璃，带折射与边缘高光），
    /// 拿不到就退 `.systemUltraThinMaterialDark`（iOS 13+ 就有）。
    /// **不写 `#available`** —— 与本仓库既有做法一致。
    ///
    /// - Parameter wantsInteractive: 要不要"按下回弹"（`UIGlassEffect.isInteractive`）。
    ///   ⚠️ 写 KVC 之前**必须先探 getter/setter** —— KVC 碰未知 key 会抛异常（崩）。
    /// - Returns: 视图 + 「interactive 真的打开了没有」（调用方拿它决定自己收不收触摸）。
    @MainActor
    static func makeGlassView(
        wantsInteractive: Bool
    ) -> (view: UIVisualEffectView, isInteractive: Bool) {
        let view = UIVisualEffectView(effect: nil)
        var isInteractive = false

        if let glassType = NSClassFromString("UIGlassEffect") as? UIVisualEffect.Type {
            let effect = glassType.init()
            let object = effect as? NSObject
            let hasGetter = object?.responds(to: NSSelectorFromString("isInteractive")) ?? false
            let hasSetter = object?.responds(to: NSSelectorFromString("setInteractive:")) ?? false
            if wantsInteractive, hasGetter, hasSetter {
                object?.setValue(true, forKey: "interactive")
                isInteractive = true
            }
            view.effect = effect
        } else {
            view.effect = UIBlurEffect(style: .systemUltraThinMaterialDark)
        }

        view.layer.borderWidth = edgeHighlightWidth
        view.layer.borderColor = UIColor.white.withAlphaComponent(edgeHighlightAlpha).cgColor
        view.autoresizingMask = []
        view.clipsToBounds = true
        view.layer.cornerCurve = .continuous

        return (view, isInteractive)
    }
}
