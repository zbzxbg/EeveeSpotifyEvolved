import Foundation
import UIKit
import ObjectiveC.runtime

/// 迷你播放条的**液态玻璃胶囊** —— 与标签栏那条**等宽（312）、等高（60）、同圆角、同材质**。
/// 用户 2026-10-02 拍的板：A 方案「两条要等宽」，代价是迷你条内容等比缩到 ~75%。
///
/// ── 真机形状（照片 33/34/35 逐像素 + 日志 26/27 的视图树）──────────────────────
/// ```
/// TouchPassthroughView@0,749,414,64                     ← host（414x64，后来又变成 414x98）
///   └ … UIView@0,0,398,56 id=SPTNowPlayingBar            ← ★内容视图（裸 UIView，只能认 id）
///        ├ UIView@8,8,40,40                              （封面）
///        ├ UIStackView@48,8,342,40                       （歌名/歌手 + 连接键 + 播放键）
///        └ UIView@8,54,382,2 id=now-playing-bar-duration （底部那条 2pt 进度线）
/// ```
/// 标签栏那条胶囊：**312x60**（屏幕 x 51…363、y 810…870）；迷你条内容底边到它顶边之间
/// **有 6.5pt 间隙**（用户特别点出：别粘上；本版做成 4.5pt，仍然分得开）。
///
/// ── 两条等宽是怎么做到的（v4.7.1）────────────────────────────────────────────
/// 迷你条内容真机 **398pt**，胶囊只有 **312pt** —— 唯一的办法是**把内容等比缩到里面**
/// （`contentScale`，真机 312−16 / 398 ≈ **0.74**）。缩的是**整条内容视图的 transform**：
///   · 不动 Spotify 的任何布局（与标签栏那四颗的收紧同一条纪律）；
///   · 关闭开关即回 `.identity`，一点痕迹不留。
/// 宽度取自**标签栏那条胶囊的宽度比例**（`TabBarGlassPlate.capsuleWidthRatio` × 本宿主宽），
/// 所以换设备/换屏幕宽度两条也还是等宽；拿不到比例时退回真机实测的 `312/414`。
///
/// ── 三件必须一起做的事（少一件就翻车）────────────────────────────────────────
///   ① **底色**：内容视图自己是"封面色"实心块（真机 `#64204C` / `#3F3F3F`，随封面变）。
///      ⚠️ Spotify 会在我们清完之后**再写回来**（日志 27：16:50:19 我们清掉，16:50:20
///      树上又是 `bg=#64204C` → 照片 34 那块紫的盖不住）。所以这里是**每次布局都清**、
///      幂等、并计数（值没变不写；写回了就再清）；记下"最后一次看见的原色"用于还原。
///   ② **不裁剪**：60pt 的胶囊比 56pt 的内容高，会被 bounds 切掉上下各 2pt。
///      v4.7.1 起玻璃住**宿主**里（不再住内容里），所以连宿主也要不裁剪。
///   ③ **玻璃不进内容视图**：因为内容要被缩放 —— 玻璃要是它的子视图就会跟着缩。
///      所以玻璃插在 `host.subviews[0]`（整条内容之下、宿主背景之上），自己不受缩放影响。
///   ④ ★ v4.8 **底色守卫**：Spotify 的写回**不一定**伴随宿主的布局回合，只靠"每次布局都清"
///      会留下照片 36 那块封面色（日志 28 的 `SPTNowPlayingBar bg=#041454`），一直到用户
///      碰巧触发了下一次布局才消失（照片 37 是点完「创建」/进过一次听歌页之后）。
///      现在多两个驱动：写回后 **50ms 级的短促重试**（`armColorGuard`，带节流、不叠加）
///      + `DeclutterChrome` **既有的 0.5s 复查节拍**（`reconcileCoverColor`）。
///      ⚠️ 两个都是"看一眼 + 幂等清"，**不是常驻轮询**（与本仓库的纪律一致）。
///
/// ── v4.8（2026-10-02）：用户「液态玻璃的宽度有点少」+ 照片 36/37 ────────────────
///   · 宽度**不写死**：跟着标签栏那条的比例走（v4.8 起标签栏那条真机是 **360pt**，
///     本机 414 宽就是 360）；拿不到时的兜底比例也跟着改成 `360/414`。
///   · 顺带的好处：内容要缩的比例从 `(312−16)/398 ≈ 0.74` 抬到 `(360−16)/398 ≈ 0.86`
///     —— 歌名、连接键、播放键都比以前大一圈。
///
/// 开关：设置 → EeveeSpotify → 扩展功能 → **迷你播放条** →「迷你播放条用液态玻璃」，默认**开**。
///
/// ⚠️ **为什么不做成新的 Orion hook**：`TouchPassthroughView` 已经被 `DeclutterChrome` 的
/// `MiniPlayerBarHideHook` 钩住了（同一个类、同一个 `layoutSubviews`）。在同一个类上再挂一个
/// `ClassHook` 是没有验证过的行为 —— 所以这里**蹭它现成的布局回调**（那里只加一行调用），
/// 本文件只负责"画"与"撤"。这也是本文件**不是** `.x.swift` 的原因。
///
/// ⚠️ **不吃触摸**：玻璃 `isUserInteractionEnabled = false`，又插在最底层 ——
/// "点迷你条开播放页"这件事一点都没被我们碰到。
enum MiniBarGlassPlate {

    static var isEnabled: Bool { UserDefaults.miniBarGlass }

    /// 内容视图在真机树里的 id（它的**类名只是裸 `UIView`**，认不了类，只能认 id）。
    private static let contentIdentifier = "SPTNowPlayingBar"

    /// 内容缩到胶囊里时左右各留多少（与标签栏那条的 `sideInset` 同一个数）。
    private static let sideInset: CGFloat = 8

    /// 拿不到标签栏那条的宽度比例时的兜底（真机实测 360 / 414；v4.8 起标签栏那条已加宽）。
    private static let fallbackWidthRatio: CGFloat = 360.0 / 414.0

    private static var plateKey: UInt8 = 0
    private static var hostClipKey: UInt8 = 0
    private static var originalColorKey: UInt8 = 0
    private static var originalClipKey: UInt8 = 0

    /// 最近一次布局见过的 host / 内容 —— 开关被切换时当场落地用
    /// （与 `DeclutterChrome.reconcileNow()` 同一招：不用等下一次布局、更不用重启）。
    private static weak var lastHost: UIView?
    private static weak var lastContent: UIView?

    /// ★ v4.8 底色守卫盯的那一个内容视图（`reconcileCoverColor()` 用；weak，视图换掉自动失效）。
    private static weak var colorGuardTarget: UIView?
    /// 一轮"短促重试"的占位截止时间。作用：**每次布局不重复排队** ——
    /// 布局回调一秒能来几十次，不节流就变成变相轮询了（仓库纪律不允许）。
    private static var guardBurstUntil: CFAbsoluteTime = 0
    /// 短促重试的节奏：写回通常发生在我们清完之后的一两帧内，5 次覆盖到 ~1.2s 就够。
    private static let guardBurstDelays: [Double] = [0.05, 0.15, 0.35, 0.7, 1.2]

    private static var didReportInstall = false
    private static var didLogClipRelease = false
    private static var colorWriteBacks = 0
    private static var lastReportedFrame: CGRect = .null
    private static var reportCount = 0

    /// 给迷你条铺/撤玻璃。**幂等**：位置没变就一个字节都不碰。
    @MainActor
    static func apply(to host: UIView) {
        lastHost = host
        let content = findContent(in: host)

        guard isEnabled else {
            removePlate(host: host, content: content ?? lastContent)
            return
        }
        guard let content, content.bounds.width > 1, content.bounds.height > 1 else { return }
        lastContent = content

        // ── ① 胶囊几何：与标签栏那条**等宽**（按栏宽比例）、**等高**（共用常量）────
        let width = capsuleWidth(in: host)
        let target = capsuleFrame(in: host, content: content, width: width)

        let plate: UIVisualEffectView
        if let existing = objc_getAssociatedObject(host, &plateKey) as? UIVisualEffectView {
            plate = existing
        } else {
            // interactive 传 false：迷你条整条就是个"打开播放页"的大按钮，
            // 按下回弹那点手感不值得冒"吃掉点击"的险。
            plate = GlassCapsule.makeGlassView(wantsInteractive: false).view
            plate.isUserInteractionEnabled = false
            objc_setAssociatedObject(host, &plateKey, plate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            host.insertSubview(plate, at: 0)     // 整条内容之下、宿主背景之上
            if !didReportInstall {
                didReportInstall = true
                writeDebugLog(
                    "[MiniBarGlass] installed (enabled=ON) — one layer on the mini player: "
                        + (GlassCapsule.hasSystemGlass ? "real system glass" : "material (no UIGlassEffect in this version)")
                        + "; **same width and height** as the tab bar (\(Int(width))x\(Int(GlassCapsule.height))), "
                        + "content scaled down to fit, no press bounce (does not eat taps)"
                )
            }
        }
        if plate.superview !== host || host.subviews.first !== plate {
            host.insertSubview(plate, at: 0)
        }

        // ── ② 内容等比缩进胶囊（两条等宽的唯一办法；只动 transform，不动布局）───
        let scale = contentScale(contentWidth: content.bounds.width, capsuleWidth: width)
        let wanted = CGAffineTransform(scaleX: scale, y: scale)
        if content.transform != wanted { content.transform = wanted }

        // ── ③ 底色：**每次布局都清**（Spotify 会写回来 —— 见文件头 ① / ④）────────────
        clearCoverColor(of: content)
        // ★ v4.8：把这次见过的那一个记下来，并排一轮"短促重试" —— 写回往往就发生在
        //   我们这次清完之后的一两帧内，而那一帧**不一定**还有宿主的布局回合。
        colorGuardTarget = content
        armColorGuard()

        // ── ④ 不裁剪：胶囊比内容高 4pt，内容与宿主都不能裁 ──────────────────────
        releaseClipping(of: content, rememberIn: &originalClipKey)
        releaseClipping(of: host, rememberIn: &hostClipKey)

        // ── ⑤ 摆位：中心对齐内容（缩放是绕中心做的，所以中心不会跑）────────────
        if !plate.frame.equalTo(target) { plate.frame = target }
        if abs(plate.layer.cornerRadius - GlassCapsule.cornerRadius) > 0.01 {
            plate.layer.cornerRadius = GlassCapsule.cornerRadius
        }

        report(target: target, content: content, plate: plate, scale: scale, width: width)
    }

    /// 关掉开关时：**撤玻璃 + 还原**（缩放 / 底色 / 裁剪，只还原我们自己改过的）。
    @MainActor
    static func removePlate(host: UIView?, content: UIView?) {
        // ★ v4.8：守卫跟着一起撤 —— 关掉开关之后不该再有人去清别人的底色。
        colorGuardTarget = nil
        if let host, let plate = objc_getAssociatedObject(host, &plateKey) as? UIVisualEffectView {
            plate.removeFromSuperview()
            objc_setAssociatedObject(host, &plateKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            writeDebugLog("[MiniBarGlass] glass removed (switch off)")
        }
        if let host, objc_getAssociatedObject(host, &hostClipKey) != nil {
            host.clipsToBounds = true
            objc_setAssociatedObject(host, &hostClipKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        guard let content else { return }
        if content.transform != .identity {
            content.transform = .identity
            writeDebugLog("[MiniBarGlass] content had been scaled — restored to its original size")
        }
        if let stored = objc_getAssociatedObject(content, &originalColorKey) {
            content.backgroundColor = (stored as? UIColor)
            objc_setAssociatedObject(content, &originalColorKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            writeDebugLog("[MiniBarGlass] artwork-colour background restored")
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

    // MARK: - 几何

    /// 胶囊宽度 = **标签栏那条的宽度**（用户要求两条等宽）。
    ///
    /// 用"标签栏胶囊宽 ÷ 栏宽"这个**比例** × 本宿主的宽来算 —— 换设备、换屏幕宽度都不会走样；
    /// 标签栏还没摆过（冷启动第一帧）时退回真机实测的 `312/414`。上限是宿主自己的宽。
    @MainActor
    private static func capsuleWidth(in host: UIView) -> CGFloat {
        let ratio = TabBarGlassPlate.capsuleWidthRatio
        let usable = (ratio > 0.4 && ratio < 1.0) ? ratio : fallbackWidthRatio
        return min(host.bounds.width, max(160, host.bounds.width * usable))
    }

    /// 内容要等比缩到多少：让它左右各留 `sideInset` 之后正好放进胶囊。
    /// 内容本来就比胶囊窄（大屏 / 将来 Spotify 改窄）时**不放大**（上限 1）。
    private static func contentScale(contentWidth: CGFloat, capsuleWidth: CGFloat) -> CGFloat {
        guard contentWidth > 1 else { return 1 }
        let usable = capsuleWidth - sideInset * 2
        guard usable > 1 else { return 1 }
        return min(1, usable / contentWidth)
    }

    /// 胶囊的 frame（**宿主坐标系**）：宽度给定、高度与标签栏同、中心对齐内容的中心。
    ///
    /// 内容的中心用 `convert(_:to:)` 取 —— 缩放是绕中心做的，所以先缩后取都一样。
    @MainActor
    private static func capsuleFrame(in host: UIView, content: UIView, width: CGFloat) -> CGRect {
        let center = content.convert(
            CGPoint(x: content.bounds.midX, y: content.bounds.midY),
            to: host
        )
        return CGRect(
            x: center.x - width / 2,
            y: center.y - GlassCapsule.height / 2,
            width: width,
            height: GlassCapsule.height
        )
    }

    // MARK: - 底色 / 裁剪

    /// 清掉内容视图的"封面色底"。**每次布局都跑**，幂等。
    ///
    /// 真机证据（日志 27）：
    /// ```
    /// 16:50:19  [MiniBarGlass] 已清掉迷你条的封面色底        ← 我们清了
    /// 16:50:20  #1 9.UIView@0,0,398,56,bg=#64204C,…          ← Spotify 又写回来（照片 34 那块紫的）
    /// 16:50:27  手动开关一次 → 再清一次 → 之后树上没有 bg 了   ← 照片 35 才干净
    /// ```
    /// 这正是仓库纪律里写过的"binder 写回"：值没变不写，值被写回就再清，并**计数**。
    ///
    /// - Returns: 这一次**真的清掉了**东西吗（v4.8 起返回值给守卫用：清到了就再排一轮短促重试）。
    @MainActor
    @discardableResult
    private static func clearCoverColor(of content: UIView) -> Bool {
        if let current = content.backgroundColor, current.cgColor.alpha > 0.01 {
            // 记"最后一次看见的原色"用于还原 —— Spotify 会随封面换色，第一次那个不算数。
            objc_setAssociatedObject(
                content, &originalColorKey, current, .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
            content.backgroundColor = .clear
            colorWriteBacks += 1
            if colorWriteBacks <= 5 {
                writeDebugLog(
                    "[MiniBarGlass] artwork-colour background written back (time \(colorWriteBacks)) — cleared again"
                        + (colorWriteBacks == 1 ? " (this is why the first frame is not covered)" : "")
                )
            } else if colorWriteBacks == 6 {
                writeDebugLog("[MiniBarGlass] ⚠️ artwork-colour background written back repeatedly (>5 times) — still clearing, no per-write log lines any more")
            }
            return true
        }

        if objc_getAssociatedObject(content, &originalColorKey) == nil {
            // 第一次见到时它就是透明的（Spotify 还没来得及上色）：先记一笔"当时是空的"，
            // 关开关时才不会还原成我们不认识的值；真正的原色会在上面那条分支里被补上。
            objc_setAssociatedObject(
                content, &originalColorKey, content.backgroundColor as Any,
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        }
        return false
    }

    /// 兜底守卫：**只看一眼**内容视图的底色，被写回来就当场清掉。★ v4.8 新增。
    ///
    /// 由 `DeclutterChrome` **既有的** 0.5s 复查节拍调用（那份节拍本来就带着
    /// "App 不在前台就不跑"的 guard）—— 不新开定时器。
    /// 单次成本 = 一次 `backgroundColor` 读 + 一次 `window` 读；开关关着 / 没有迷你条时
    /// 直接返回（`colorGuardTarget` 与 `lastContent` 都是 nil）。
    ///
    /// ★ 真机日志 28 的那个现场：切歌时 Spotify 在 00:47:46 写下 `bg=#10346C`，
    /// 而**下一次宿主的布局回合要等到 00:47:54** —— 中间 8 秒用户看到的就是照片 36 那块蓝。
    /// 这一支把这个窗口压到 ≤0.5s；而且**清掉之后顺手再排一轮短促重试**，
    /// 因为"刚清完又被写回"（首帧那种）就是靠那一轮兜住的。
    @MainActor
    static func reconcileCoverColor() {
        guard isEnabled else { return }
        guard let content = colorGuardTarget ?? lastContent else { return }
        guard content.window != nil else { return }
        if clearCoverColor(of: content) { armColorGuard() }
    }

    /// 写回之后的**短促重试**：排几次"看一眼 + 幂等清"，~1.2s 内自己收手。
    ///
    /// 为什么需要：照片 36 那块封面色（`bg=#041454`）就是"我们清完 → Spotify 又写回来 →
    /// 而那一帧没有宿主的布局回合"造成的。写回通常紧随我们这一次清色（同一帧或下一帧），
    /// 所以 50ms 级看几次就够；`reconcileCoverColor()` 那 0.5s 的节拍负责漏网之鱼。
    ///
    /// ⚠️ **只排一轮，不叠加**（`guardBurstUntil` 占位）—— 否则每次布局都排一次，
    /// 就成了变相轮询，正是仓库纪律里禁止的那种写法。
    @MainActor
    private static func armColorGuard() {
        let now = CFAbsoluteTimeGetCurrent()
        guard now >= guardBurstUntil else { return }
        guardBurstUntil = now + (guardBurstDelays.last ?? 1.2)

        for delay in guardBurstDelays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                onMainThreadSync { reconcileCoverColor() }
            }
        }
    }

    /// 不裁剪：UIView 默认就不裁剪，这里只把"确实裁着"的那种放开并记住，关开关时还原。
    @MainActor
    private static func releaseClipping(of view: UIView, rememberIn key: inout UInt8) {
        guard view.clipsToBounds else { return }
        if objc_getAssociatedObject(view, &key) == nil {
            objc_setAssociatedObject(view, &key, NSNumber(value: true), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        view.clipsToBounds = false
        if !didLogClipRelease {
            didLogClipRelease = true
            writeDebugLog("[MiniBarGlass] a view was clipping — released (turning the switch off restores it)")
        }
    }

    /// 内容视图的裁剪位单独记一份（`originalClipKey`），宿主那份记在 `hostClipKey`。

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

    /// 报一次账：胶囊摆在哪、迷你条内容多大、缩到多少 —— 下次日志不用看图就能验这条改动。
    /// 只在位置变化时报，且最多 6 条。
    ///
    /// ★ 顺带把**窗口坐标**也打出来：验收时要看的"两条胶囊之间的间隙"
    /// （真机标签栏那条在窗口 y 810…870）只靠这一行 + `[Tree]` 里标签栏的 frame 就能算出来。
    @MainActor
    private static func report(
        target: CGRect,
        content: UIView,
        plate: UIVisualEffectView,
        scale: CGFloat,
        width: CGFloat
    ) {
        guard !target.equalTo(lastReportedFrame) else { return }
        lastReportedFrame = target
        guard reportCount < 6 else { return }
        reportCount += 1

        let inWindow = plate.window.map { plate.convert(plate.bounds, to: $0) }
        let windowText = inWindow.map {
            String(format: "; in window (%.0f,%.0f %.0fx%.0f)",
                   $0.origin.x, $0.origin.y, $0.size.width, $0.size.height)
        } ?? "; not in a window yet"
        let source = TabBarGlassPlate.capsuleWidthRatio > 0.4
            ? String(format: "the tab bar capsule's ratio (its measured width %.0f)", TabBarGlassPlate.capsuleWidth)
            : "fallback ratio (tab bar not laid out yet)"

        writeDebugLog(String(
            format: "[MiniBarGlass] capsule (%.0f,%.0f %.0fx%.0f) r=%.1f ← mini bar content %.0fx%.0f scaled to %.2f"
                + " (**same width** as the tab bar %.0f, same height %.0f; width taken from %@)%@",
            target.origin.x, target.origin.y, target.size.width, target.size.height,
            target.size.height / 2,
            content.bounds.width, content.bounds.height, scale,
            width, GlassCapsule.height, source,
            windowText
        ))
    }
}
