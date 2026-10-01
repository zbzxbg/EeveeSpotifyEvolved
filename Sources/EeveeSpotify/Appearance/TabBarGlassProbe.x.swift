import Foundation
import Orion
import UIKit
import ObjectiveC.runtime

/// 底部标签栏玻璃 —— 第 2 版（真机照片 21 的目标形状）。
///
/// ── 照片 21 要的是什么 ──────────────────────────────────────────────────────
/// 一条**通栏的胶囊玻璃筋**（左右留边、底边贴近 home indicator），图标浮在上面，
/// 选中态有自己那颗会滑的深色胶囊。而我们第一版做成了"**每颗标签一块独立方玻璃**" ——
/// 形状、观感都不是那个意思。
///
/// ── 为什么必须先看 dump 再动手（两条真机实证）──────────────────────────────
///   1. 我原以为"照片 21 那条筋是系统给的"，所以第一版是往系统玻璃上加一层 ——
///      用户实测：**关掉我们的开关，底栏就变成透明、没有任何玻璃**。
///      也就是说**系统没给**，那层玻璃得我们自己做，而且要做成**一个形状**（不是四块）；
///   2. 第一版还按"每颗 103×49"铺满，等于把整条栏糊了一层 —— 又难看又挡了
///      Spotify 自己的选中滑块。
///
/// 结论：**动手之前先用真机 dump 把这条栏的内部结构量出来**（哪个视图是底、谁是
/// 选中滑块、图标在什么位置、安全区多少）。这个探针就是干这个的：只读、只打日志、
/// 不建任何视图、不改任何东西。
struct TabBarGlassProbeGroup: HookGroup {}

enum TabBarGlassProbe {

    private static var didDump = false

    /// 把这条栏的**内部结构**摊进日志（每个节点：类名/子树序号/frame/底色/圆角/alpha）。
    ///
    /// 只跑一次（`didDump` 挡住重复），且只在同一个 runloop 里读属性 —— 不遍历整窗、
    /// 不碰别人的视图，所以不会像听歌页那版一样把滚动搞停。
    @MainActor
    static func dumpOnce(_ bar: UIView) {
        guard !didDump else { return }
        didDump = true

        writeDebugLog("[TabBarDump] ---- 标签栏内部结构 begin（bar \(Int(bar.bounds.width))x\(Int(bar.bounds.height))）----")
        var index = 0
        walk(bar, depth: 0, index: &index)
        writeDebugLog("[TabBarDump] ---- end ----")
    }

    private static func walk(_ view: UIView, depth: Int, index: inout Int) {
        guard depth <= 8 else { return }
        index += 1

        let frame = view.frame
        let name = NSStringFromClass(type(of: view))
        var parts: [String] = []
        parts.append("#\(index)")
        parts.append(String(repeating: "  ", count: depth) + name)
        parts.append(String(
            format: "frame=(%.0f,%.0f %.0fx%.0f)",
            frame.origin.x, frame.origin.y, frame.size.width, frame.size.height
        ))
        if let bg = view.backgroundColor, bg.cgColor.alpha > 0.01 {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            if bg.getRed(&r, green: &g, blue: &b, alpha: &a) {
                parts.append(String(format: "bg=#%02X%02X%02X a=%.2f",
                                    Int(r * 255), Int(g * 255), Int(b * 255), a))
            }
        }
        if view.layer.cornerRadius > 0.01 {
            parts.append(String(format: "corner=%.1f", view.layer.cornerRadius))
        }
        if view.alpha < 0.99 {
            parts.append(String(format: "alpha=%.2f", view.alpha))
        }
        if view.isHidden {
            parts.append("hidden")
        }
        if let id = view.accessibilityIdentifier, !id.isEmpty {
            parts.append("id=\(id)")
        }
        // 有自己图层的（玻璃/材质/形状层）特别标出来 —— 那就是"底"或"筋"
        if view is UIVisualEffectView {
            parts.append("★UIVisualEffectView")
        }
        if view.layer.sublayers?.contains(where: { $0 is CAGradientLayer }) == true {
            parts.append("★有渐变层")
        }

        writeDebugLog("[TabBarDump] " + parts.joined(separator: " "))

        for sub in view.subviews {
            walk(sub, depth: depth + 1, index: &index)
        }
    }
}

/// 挂在标签栏容器上，布局好了就 dump 一次。
///
/// 真类名：`NavigationUI_TabBarImpl.TabBarView`
/// （IPA `_TtC23NavigationUI_TabBarImpl10TabBarView` ↔ 真机 dump
///  `10.TabBarView@0,0,414,83,id=elements-tabs-view-identifier`）。
class TabBarProbeHook: ClassHook<UIView> {
    typealias Group = TabBarGlassProbeGroup
    static let targetName = "NavigationUI_TabBarImpl.TabBarView"

    func layoutSubviews() {
        orig.layoutSubviews()
        let bar = self.target
        onMainThreadSync {
            TabBarGlassProbe.dumpOnce(bar)
        }
    }
}

func activateTabBarGlassProbe() {
    guard NSClassFromString(TabBarProbeHook.targetName) != nil else {
        writeDebugLog("[TabBarDump] missing \(TabBarProbeHook.targetName) — 探针未装")
        return
    }
    TabBarGlassProbeGroup().activate()
    writeDebugLog("[TabBarDump] 探针已装 — 进任意页面后日志里会出现 ---- 标签栏内部结构 begin ----")
}
