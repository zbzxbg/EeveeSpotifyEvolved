import Foundation
import UIKit
import ObjectiveC.runtime

/// 迷你播放条的**液态玻璃胶囊** —— 与标签栏那条同高、同圆角、同材质；
/// 宽度**贴它自己的内容**（用户 2026-10-02 选的 A 方案）。
///
/// ── 真机形状（照片 33 逐像素 + 日志 25/26 的视图树）────────────────────────────
/// ```
/// TouchPassthroughView@0,749,414,64                     ← host（我们在它的 layout 回调里干活）
///   └ … UIView@0,0,398,56 id=SPTNowPlayingBar            ← ★内容视图（裸 UIView，只能认 id）
///        ├ UIView@8,8,40,40                              （封面）
///        ├ UIStackView@48,8,342,40                       （歌名/歌手 + 连接键 + 播放键）
///        └ UIView@8,54,382,2 id=now-playing-bar-duration （底部那条进度线）
/// ```
/// 实测：内容 **398x56**、左右各留 8pt；标签栏那条胶囊 **312x60**（屏幕 y 810…870）；
/// 迷你条内容底边（y≈805）到胶囊顶边之间**有 6.5pt 间隙**（用户特别点出这一点，别粘上）。
///
/// 新胶囊 = **398x60、r=30**（宽度贴内容、高度与标签栏同）→ 比内容上下各多 2pt，
/// 于是间隙 6.5 → **4.5pt**：两条仍然分得开。
///
/// ── 三件必须一起做的事（少一件就翻车）────────────────────────────────────────
///   ① 玻璃插在**内容视图自己的 `subviews[0]`**：那样它在"内容视图自己的背景色之上、
///      内容子视图之下"，与标签栏那条层序一致（封面/文字浮在玻璃上）；
///   ② 内容视图自己的 `backgroundColor` 是**封面色**（真机 `#3F3F3F` / `#2C2430`，随封面变），
///      不清掉的话玻璃会被染成一块实心红 —— 所以**先记住原色再清空**，关开关时还原；
///   ③ 内容视图要**不裁剪**：60pt 的胶囊比 56pt 的内容高，会被它的 bounds 切掉上下各 2pt
///      （UIView 默认就不裁剪，这里显式确认并记住原值，关开关时还原）。
///
/// 开关：设置 → EeveeSpotify → 扩展功能 → **迷你播放条** →「迷你播放条用液态玻璃」，默认**开**。
///
/// ⚠️ **为什么不做成新的 Orion hook**：`TouchPassthroughView` 已经被 `DeclutterChrome` 的
/// `MiniPlayerBarHideHook` 钩住了（同一个类、同一个 `layoutSubviews`）。在同一个类上再挂一个
/// `ClassHook` 是没有验证过的行为 —— 所以这里**蹭它现成的布局回调**（那里只加一行调用），
/// 本文件只负责"画"与"撤"。这也是本文件**不是** `.x.swift` 的原因。
///
/// ⚠️ **不吃触摸**：玻璃 `isUserInteractionEnabled = false`。它在 `subviews[0]`（最底层），
/// 又主动让开命中测试 —— 于是"点迷你条开播放页"这件事一点都没被我们碰到。
enum MiniBarGlassPlate {

    static var isEnabled: Bool { UserDefaults.miniBarGlass }

    /// 内容视图在真机树里的 id（它的**类名只是裸 `UIView`**，认不了类，只能认 id）。
    private static let contentIdentifier = "SPTNowPlayingBar"

    private static var plateKey: UInt8 = 0
    private static var originalColorKey: UInt8 = 0
    private static var originalClipKey: UInt8 = 0

    /// 最近一次布局见过的 host —— 开关被切换时当场落地用
    /// （与 `DeclutterChrome.reconcileNow()` 同一招：不用等下一次布局、更不用重启）。
    private static weak var lastHost: UIView?

    private static var didReportInstall = false
    private static var didLogClipRelease = false
    private static var lastReportedFrame: CGRect = .null
    private static var reportCount = 0

    /// 给迷你条铺/撤玻璃。**幂等**：位置没变就一个字节都不碰。
    @MainActor
    static func apply(to host: UIView) {
        lastHost = host

        guard isEnabled else {
            if let content = findContent(in: host) { removePlate(from: content) }
            return
        }
        guard let content = findContent(in: host) else { return }
        guard content.bounds.width > 1, content.bounds.height > 1 else { return }

        // ── 玻璃：复用标签栏那套材质（同高、同圆角、同一圈描边高光）──────────────
        // interactive 传 false：迷你条整条就是个"打开播放页"的大按钮，
        // 按下回弹那点手感不值得冒"吃掉点击"的险（见文件头 ⚠️）。
        let plate: UIVisualEffectView
        if let existing = objc_getAssociatedObject(content, &plateKey) as? UIVisualEffectView {
            plate = existing
        } else {
            plate = GlassCapsule.makeGlassView(wantsInteractive: false).view
            plate.isUserInteractionEnabled = false
            objc_setAssociatedObject(content, &plateKey, plate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            content.insertSubview(plate, at: 0)     // 背景色之上、内容子视图之下
            if !didReportInstall {
                didReportInstall = true
                writeDebugLog(
                    "[MiniBarGlass] installed (enabled=ON) — 迷你播放条铺一层"
                        + (GlassCapsule.hasSystemGlass ? "系统真玻璃" : "材质（这版没有 UIGlassEffect）")
                        + "，与标签栏同高 \(Int(GlassCapsule.height))、无按下回弹（不吃点击）"
                )
            }
        }
        if plate.superview !== content || content.subviews.first !== plate {
            content.insertSubview(plate, at: 0)
        }

        // ── 底色：内容视图自己是"封面色"实心块，不清掉玻璃就被染红 ──────────────
        if objc_getAssociatedObject(content, &originalColorKey) == nil {
            objc_setAssociatedObject(
                content,
                &originalColorKey,
                content.backgroundColor as Any,
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
            content.backgroundColor = .clear
            writeDebugLog("[MiniBarGlass] 已清掉迷你条的封面色底（关掉开关会原样还原）")
        }

        // ── 不裁剪：胶囊比内容高 4pt，否则上下各 2pt 会被 bounds 切掉 ────────────
        if content.clipsToBounds {
            if objc_getAssociatedObject(content, &originalClipKey) == nil {
                objc_setAssociatedObject(
                    content,
                    &originalClipKey,
                    NSNumber(value: true),
                    .OBJC_ASSOCIATION_RETAIN_NONATOMIC
                )
            }
            content.clipsToBounds = false
            if !didLogClipRelease {
                didLogClipRelease = true
                writeDebugLog("[MiniBarGlass] 内容视图原本会裁剪 — 已放开（关掉开关会还原）")
            }
        }

        // ── 摆位：宽度贴内容（含它自带的左右留白）、高度与标签栏同高、中心对齐 ────
        let width = content.bounds.width
        let target = CGRect(
            x: content.bounds.midX - width / 2,
            y: content.bounds.midY - GlassCapsule.height / 2,
            width: width,
            height: GlassCapsule.height
        )
        if !plate.frame.equalTo(target) { plate.frame = target }
        if abs(plate.layer.cornerRadius - GlassCapsule.cornerRadius) > 0.01 {
            plate.layer.cornerRadius = GlassCapsule.cornerRadius
        }

        report(target: target, content: content, plate: plate)
    }

    /// 关掉开关时：**撤玻璃 + 还原底色与裁剪**（只还原我们自己改过的那两处）。
    @MainActor
    static func removePlate(from content: UIView) {
        if let plate = objc_getAssociatedObject(content, &plateKey) as? UIVisualEffectView {
            plate.removeFromSuperview()
            objc_setAssociatedObject(content, &plateKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            writeDebugLog("[MiniBarGlass] 玻璃已撤（开关关掉，底色/裁剪已还原）")
        }
        if let stored = objc_getAssociatedObject(content, &originalColorKey) {
            content.backgroundColor = (stored as? UIColor)
            objc_setAssociatedObject(content, &originalColorKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        if objc_getAssociatedObject(content, &originalClipKey) != nil {
            content.clipsToBounds = true
            objc_setAssociatedObject(content, &originalClipKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }

    /// 开关被手动切换时**当场落地**（与 `DeclutterChrome.reconcileNow()` 同一套）。
    ///
    /// ⚠️ **不加 `@MainActor`**：设置页那个绑定闭包是 non-isolated 的（仓库既有写法），
    /// 所以主线程这件事在方法体里用 `onMainThreadSync` 显式表达
    /// （理由见 `LyricsChromeVisibility.swift` 顶上那段）。
    static func reconcileNow() {
        onMainThreadSync {
            guard let host = lastHost else { return }
            apply(to: host)
        }
    }

    // MARK: - 找内容视图 / 记账

    /// 从 host 里找 `id=SPTNowPlayingBar` 那个内容视图。
    ///
    /// ⚠️ **认 id 不认类**：真机树里它是一个裸 `UIView`（`9.UIView@0,0,398,56,id=SPTNowPlayingBar`），
    /// 认类会认到半个 App 的 `UIView` 上去。走查深度 6、找不到就什么都不做（宁可漏，不可误伤）。
    @MainActor
    private static func findContent(in host: UIView) -> UIView? {
        var found: UIView?

        func walk(_ node: UIView, _ depth: Int) {
            guard found == nil, depth <= 6 else { return }
            if node.accessibilityIdentifier == contentIdentifier {
                found = node
                return
            }
            for sub in node.subviews { walk(sub, depth + 1) }
        }

        walk(host, 0)
        return found
    }

    /// 报一次账：胶囊摆在哪、迷你条内容多大 —— 下次日志不用看图就能验这条改动。
    /// 只在位置变化时报，且最多 6 条。
    ///
    /// ★ 顺带把**窗口坐标**也打出来：验收时要看的"两条胶囊之间的间隙"
    /// （迷你条胶囊底边 ↔ 标签栏胶囊顶边，真机标签栏那条在窗口 y 810…870）
    /// 只靠这一行 + `[Tree]` 里标签栏的 frame 就能算出来，不用再截图量像素。
    @MainActor
    private static func report(target: CGRect, content: UIView, plate: UIVisualEffectView) {
        guard !target.equalTo(lastReportedFrame) else { return }
        lastReportedFrame = target
        guard reportCount < 6 else { return }
        reportCount += 1

        let inWindow = plate.window.map { plate.convert(plate.bounds, to: $0) }
        let windowText = inWindow.map {
            String(format: "；窗口里 (%.0f,%.0f %.0fx%.0f)",
                   $0.origin.x, $0.origin.y, $0.size.width, $0.size.height)
        } ?? "；还没进窗口"

        writeDebugLog(String(
            format: "[MiniBarGlass] 胶囊 (%.0f,%.0f %.0fx%.0f) r=%.1f ← 迷你条内容 %.0fx%.0f"
                + "（与标签栏胶囊同高 %.0f）%@",
            target.origin.x, target.origin.y, target.size.width, target.size.height,
            target.size.height / 2,
            content.bounds.width, content.bounds.height,
            GlassCapsule.height,
            windowText
        ))
    }
}
