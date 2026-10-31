import Foundation
import UIKit
import ObjectiveC.runtime
import EeveeSpotifyC

/// 迷你播放条的液态玻璃胶囊：与标签栏那条等宽（360pt）、等高（60pt）、同圆角、同材质。
/// 两条等宽的唯一办法是把迷你条内容等比缩进胶囊（只动 transform，不动 Spotify 的布局）。
///
/// 视图层级（真机）：
/// ```
/// TouchPassthroughView@0,749,414,64
///   └ … UIView@0,0,398,56 id=SPTNowPlayingBar            ← 内容视图（裸 UIView，只能认 id）
///        ├ UIView@8,8,40,40                              （封面）
///        ├ UIStackView@48,8,342,40                       （歌名/歌手 + 连接键 + 播放键）
///        └ UIView@8,54,382,2 id=now-playing-bar-duration （底部那条 2pt 进度线）
/// ```
/// 坑：内容视图是"封面色"实心块且 Spotify 会写回 → 用 `EeveeInterceptBackground` 在层上断根；
/// 玻璃必须住宿主且不能进内容视图（内容要被缩放），宿主与内容都不能裁剪（胶囊比内容高 4pt）。
/// 不新开 Orion hook：`TouchPassthroughView` 已被 `DeclutterChrome` 的 `MiniPlayerBarHideHook` 钩住，
/// 同一个类上重复挂 `ClassHook` 行为未验证，所以蹭它现成的布局回调。玻璃不吃触摸。
enum MiniBarGlassPlate {

    /// 开关：设置 → EeveeSpotify → 扩展功能 → 迷你播放条 →「迷你播放条用液态玻璃」，默认开。
    static var isEnabled: Bool { UserDefaults.miniBarGlass }

    /// 内容视图在真机树里的 id（它的类名只是裸 `UIView`，认不了类，只能认 id）。
    private static let contentIdentifier = "SPTNowPlayingBar"

    /// 内容缩到胶囊里时左右各留多少（与标签栏那条的 `sideInset` 同一个数）。
    private static let sideInset: CGFloat = 8

    /// 拿不到标签栏那条的宽度比例时的兜底（真机实测 360 / 414）。
    private static let fallbackWidthRatio: CGFloat = 360.0 / 414.0

    private static var plateKey: UInt8 = 0
    private static var hostClipKey: UInt8 = 0
    private static var originalColorKey: UInt8 = 0
    private static var originalClipKey: UInt8 = 0
    /// 这一层已经装了底色拦截（`EeveeInterceptBackground`）。
    /// 装了之后写回在层上就被吃掉，不再需要清 / 补清 / 复查三件套。
    private static var colorInterceptKey: UInt8 = 0

    /// 最近一次布局见过的 host / 内容 —— 开关被切换时当场落地用
    /// （与 `DeclutterChrome.reconcileNow` 同一招：不用等下一次布局、更不用重启）。
    private static weak var lastHost: UIView?
    private static weak var lastContent: UIView?

    /// 兜底守卫盯的那一个内容视图（`reconcileCoverColor` 用；weak，视图换掉自动失效）。
    private static weak var colorGuardTarget: UIView?
    /// 一轮"短促重试"的占位截止时间：每次布局不重复排队。
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

        // 封面圆角独立于这条玻璃开关（由 `miniBarRoundArtwork` 自己管），
        // 所以放在 `isEnabled` 早退之前 —— 关掉玻璃照样是圆的。
        // 传的是 content（`id=SPTNowPlayingBar` 那个），不是外层 host：
        // 圆封面的"贴左"判据要相对它算（见 `MiniBarArtwork`）。
        MiniBarArtwork.apply(to: content ?? host)

        guard isEnabled else {
            removePlate(host: host, content: content ?? lastContent)
            return
        }
        guard let content, content.bounds.width > 1, content.bounds.height > 1 else { return }
        lastContent = content

        // ① 胶囊几何：与标签栏那条等宽（按栏宽比例）、等高（共用常量）。
        // 胶囊比内容高 4pt（上下各 2pt），与标签栏那条之间仍留出可见间隙，不粘连。
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

        // ② 内容等比缩进胶囊（两条等宽的唯一办法；只动 transform，不动布局）。
        let scale = contentScale(contentWidth: content.bounds.width, capsuleWidth: width)
        let wanted = CGAffineTransform(scaleX: scale, y: scale)
        if content.transform != wanted { content.transform = wanted }

        // ③ 底色：从源头吃掉 —— 给这一层的 CALayer 换一个实例子类，
        // `setBackgroundColor:` 永远不落盘（见 `Sources/EeveeSpotifyC/Tweak.m`）。
        // 装不上（层类是 Swift 类 / KVO 子类）才退回"每拍清一次 + 补清 + 复查"三件套。
        if armColorIntercept(for: content) {
            colorGuardTarget = nil
        } else {
            clearCoverColor(of: content)
            colorGuardTarget = content
            armColorGuard()
        }

        // ④ 不裁剪：胶囊比内容高 4pt，内容与宿主都不能裁。
        releaseClipping(of: content, rememberIn: &originalClipKey)
        releaseClipping(of: host, rememberIn: &hostClipKey)

        // ⑤ 摆位：中心对齐内容（缩放是绕中心做的，所以中心不会跑）。
        if !plate.frame.equalTo(target) { plate.frame = target }
        if abs(plate.layer.cornerRadius - GlassCapsule.cornerRadius) > 0.01 {
            plate.layer.cornerRadius = GlassCapsule.cornerRadius
        }

        report(target: target, content: content, plate: plate, scale: scale, width: width)
    }

    /// 关掉开关时：撤玻璃 + 还原（缩放 / 底色 / 裁剪，只还原我们自己改过的）。
    @MainActor
    static func removePlate(host: UIView?, content: UIView?) {
        // 守卫跟着一起撤 —— 关掉开关之后不该再有人去清别人的底色。
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
        // 先撤掉底色拦截（把 CALayer 的真实类写回去），
        // 下面那句 `backgroundColor = stored` 才会真的落盘。
        var interceptedColour: UIColor?
        if let sink = objc_getAssociatedObject(content, &colourSinkKey) as? ColourSink {
            interceptedColour = sink.last
        }
        if objc_getAssociatedObject(content, &colorInterceptKey) != nil {
            EeveeRestoreBackground(content)
            objc_setAssociatedObject(
                content, &colorInterceptKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
            writeDebugLog("[MiniBarGlass] background intercept removed — the layer paints again")
        }
        if let interceptedColour {
            // 拦截期间那一层的底色一直是空的 ⇒ 把最后见过的封面色还回去。
            content.backgroundColor = interceptedColour
            writeDebugLog("[MiniBarGlass] artwork-colour background restored from the intercept sink")
        } else if let stored = objc_getAssociatedObject(content, &originalColorKey) {
            content.backgroundColor = (stored as? UIColor)
            objc_setAssociatedObject(content, &originalColorKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            writeDebugLog("[MiniBarGlass] artwork-colour background restored")
        }
        if objc_getAssociatedObject(content, &originalClipKey) != nil {
            content.clipsToBounds = true
            objc_setAssociatedObject(content, &originalClipKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }

    /// 开关被手动切换时**当场落地**（与 `DeclutterChrome.reconcileNow` 同一套）。
    ///
    /// **不加 `@MainActor`**：设置页那个绑定闭包是 non-isolated 的（仓库既有写法），
    /// 所以主线程这件事在方法体里用 `onMainThreadSync` 显式表达。
    static func reconcileNow() {
        onMainThreadSync {
            guard let host = lastHost else { return }
            apply(to: host)
        }
    }

    // MARK: - 几何
    //
    // 胶囊宽度 = 标签栏那条胶囊的宽度（两条等宽）。
    //
    // 用"标签栏胶囊宽 ÷ 栏宽"这个比例 × 本宿主的宽来算 —— 换设备、换屏幕宽度都不会走样；
    // 标签栏还没摆过（冷启动第一帧）时退回兜底比例。上限是宿主自己的宽。
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
    //
    // 接住"被吃掉的那份颜色"的小盒子。
    //
    // 不用静态变量：层会**强持有**那个闭包，而闭包在非隔离上下文里被调用 ——
    // 直接写 `@MainActor` 的静态量会在 Swift 6 并发检查下判错。用一个 `@unchecked Sendable`
    // 的小对象承接，读写都只是一次属性赋值，跨线程也安全。
    private final class ColourSink: @unchecked Sendable {
        var last: UIColor?
    }
    private static var colourSinkKey: UInt8 = 0

    /// **从源头吃掉** Spotify 写给这一层的底色：给 `content.layer` 换一个"只有这个实例用"的
    /// CALayer 子类，`setBackgroundColor:` 只把颜色回报给我们、永远不落盘。
    /// 关开关时用 `EeveeRestoreBackground` 把类写回去，再把最后见过的原色还给它。
    ///
    /// - Returns: 装上了返回 true；装不上（Swift 层类 / KVO 子类 / 分配失败）返回 false
    /// ⇒ 调用方退回"每拍清一次"的老路。
    @MainActor
    private static func armColorIntercept(for content: UIView) -> Bool {
        if objc_getAssociatedObject(content, &colorInterceptKey) != nil { return true }
        let sink = ColourSink()
        objc_setAssociatedObject(content, &colourSinkKey, sink, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        let ok = EeveeInterceptBackground(content) { colour in
            sink.last = colour
        }
        guard ok else {
            if !didReportInterceptFailure {
                didReportInterceptFailure = true
                writeDebugLog(
                    "[MiniBarGlass] background intercept NOT installed (layer class is not hookable)"
                        + " — falling back to clearing the colour every layout"
                )
            }
            return false
        }
        objc_setAssociatedObject(
            content, &colorInterceptKey, NSNumber(value: true), .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
        writeDebugLog(
            "[MiniBarGlass] background intercepted at the layer — Spotify can no longer paint"
                + " over the glass (no clearing pass, no flash window)"
        )
        return true
    }

    private static var didReportInterceptFailure = false

    /// 清掉内容视图的"封面色底"，**每次布局都跑**、幂等。
    /// Spotify 会随封面换色、并在我们清完之后写回来，所以每次清都计数，并记下最后见到的原色用于还原。
    ///
    /// - Returns: 这一次**真的清掉了**东西吗（清到了就再排一轮短促重试）。
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

    /// 兜底守卫：**只看一眼**内容视图的底色，被写回来就当场清掉。
    ///
    /// 由 `DeclutterChrome` **既有的** 0.5s 复查节拍调用（那份节拍本来就带着
    /// "App 不在前台就不跑"的 guard）—— 不新开定时器。装上拦截后这里直接返回。
    /// 单次成本 = 一次 `backgroundColor` 读 + 一次 `window` 读。
    @MainActor
    static func reconcileCoverColor() {
        guard isEnabled else { return }
        guard let content = colorGuardTarget ?? lastContent else { return }
        guard content.window != nil else { return }
        // 装上了拦截就**没有事情可做**了（写回在层上被吃掉）。
        if objc_getAssociatedObject(content, &colorInterceptKey) != nil { return }
        if clearCoverColor(of: content) { armColorGuard() }
    }

    /// 写回之后的**短促重试**：排几次"看一眼 + 幂等清"，~1.2s 内自己收手。
    ///
    /// 写回通常紧随我们这一次清色（同一帧或下一帧），所以 50ms 级看几次就够；
    /// `reconcileCoverColor` 那 0.5s 的节拍负责漏网之鱼。**只排一轮，不叠加**（`guardBurstUntil` 占位），
    /// 否则每次布局都排一次就成了变相轮询。
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
    ///
    /// MARK: - 找内容视图 / 记账
    ///
    /// 从 host 里找 `id=SPTNowPlayingBar` 那个内容视图。
    ///
    /// **认 id 不认类**：真机树里它是一个裸 `UIView`，认类会认到半个 App 的 `UIView` 上去。
    /// 走查深度 6、找不到就什么都不做（宁可漏，不可误伤）。
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

    /// 报一次账：胶囊摆在哪、迷你条内容多大、缩到多少 —— 连窗口坐标一起打，
    /// 验收时"两条胶囊之间的间隙"只靠这一行加标签栏的 frame 就能算出来。
    /// 只在位置变化时报，且最多 6 条。
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
