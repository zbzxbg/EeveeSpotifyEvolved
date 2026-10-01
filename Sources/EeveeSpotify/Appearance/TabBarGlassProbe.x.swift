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

    /// 从任意一颗标签往上找到标签栏容器（`TabBarView`）。
    ///
    /// 用类名而不是"往上走几层"：层级会随版本变（dump 里是 容器 → CompactView →
    /// StackView → ElementContentView → ElementView → 标签），走类名稳。
    @MainActor
    static func enclosingTabBar(from item: UIView) -> UIView? {
        var node: UIView? = item
        var depth = 0
        while let current = node, depth < 12 {
            let name = NSStringFromClass(type(of: current))
            if name.contains("NavigationUI_TabBarImpl") && name.hasSuffix(".TabBarView") {
                return current
            }
            node = current.superview
            depth += 1
        }
        return nil
    }

    /// 顺便把**容器自己的 frame**（相对屏幕）也记下来 —— 决定我们的玻璃要摆在哪。
    @MainActor
    static func dumpWindowFrame(of bar: UIView) {
        guard let window = bar.window else { return }
        let frame = bar.convert(bar.bounds, to: window)
        writeDebugLog(String(
            format: "[TabBarDump] bar 在窗口里的位置 = (%.0f,%.0f %.0fx%.0f)  [窗口 %.0fx%.0f]",
            frame.origin.x, frame.origin.y, frame.size.width, frame.size.height,
            window.bounds.width, window.bounds.height
        ))
    }

    /// 把这条栏的**内部结构**摊进日志（每个节点：类名/子树序号/frame/底色/圆角/alpha）。
    ///
    /// 只跑一次（`didDump` 挡住重复），且只在同一个 runloop 里读属性 —— 不遍历整窗、
    /// 不碰别人的视图，所以不会像听歌页那版一样把滚动搞停。
    @MainActor
    static func dumpOnce(_ bar: UIView) {
        guard !didDump else { return }
        didDump = true

        writeDebugLog("[TabBarDump] ---- 标签栏内部结构 begin（bar \(Int(bar.bounds.width))x\(Int(bar.bounds.height))）----")
        dumpWindowFrame(of: bar)
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
/// ⚠️ **不能在 `TabBarView` 第一次 `layoutSubviews` 里 dump** —— 日志 19 实证：
/// 那次所有内部节点都是 `frame=(0,0 0x0)`（内容还没排），测出来等于没测。
/// 改成挂在**每一颗标签自己**的布局上，并且**等它真的有尺寸**（>1pt）再 dump，
/// 这样拿到的才是排好之后的真 frame。
///
/// 真类名：
///   `NavigationUI_TabBarImpl.TabBarItemElementView`
///   `CreateMenu_TabBarItemImpl.CreateMenuTabBarItemView`
class TabBarProbeItemHook: ClassHook<UIView> {
    typealias Group = TabBarGlassProbeGroup
    static let targetName = "NavigationUI_TabBarImpl.TabBarItemElementView"

    func layoutSubviews() {
        orig.layoutSubviews()
        let item = self.target
        onMainThreadSync {
            guard item.bounds.width > 1, item.bounds.height > 1 else { return }
            // 从这一颗往上走到标签栏容器，再整棵 dump —— 此时尺寸已经是真的了。
            guard let bar = TabBarGlassProbe.enclosingTabBar(from: item) else { return }
            TabBarGlassProbe.dumpOnce(bar)
        }
    }
}

/// 「创建」那颗（另一个模块）也挂一下：万一用户先进的是它那一页，也能触发 dump。
class TabBarProbeCreateItemHook: ClassHook<UIView> {
    typealias Group = TabBarGlassProbeGroup
    static let targetName = "CreateMenu_TabBarItemImpl.CreateMenuTabBarItemView"

    func layoutSubviews() {
        orig.layoutSubviews()
        let item = self.target
        onMainThreadSync {
            guard item.bounds.width > 1, item.bounds.height > 1 else { return }
            guard let bar = TabBarGlassProbe.enclosingTabBar(from: item) else { return }
            TabBarGlassProbe.dumpOnce(bar)
        }
    }
}

func activateTabBarGlassProbe() {
    var targets: [String] = []
    for name in [TabBarProbeItemHook.targetName, TabBarProbeCreateItemHook.targetName] {
        if NSClassFromString(name) != nil {
            targets.append(name)
        } else {
            writeDebugLog("[TabBarDump] missing \(name)")
        }
    }
    guard !targets.isEmpty else {
        writeDebugLog("[TabBarDump] 两个目标都没有 — 探针未装")
        return
    }
    TabBarGlassProbeGroup().activate()
    writeDebugLog("[TabBarDump] 探针已装（等标签排好再 dump）：\(targets.joined(separator: " + "))")
}
