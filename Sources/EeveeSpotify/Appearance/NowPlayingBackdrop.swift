import Foundation
import UIKit
import ObjectiveC.runtime

/// 听歌页（NPV）的**整页底色**：换成"封面取色"的三层渐变 —— 也就是 Apple Music 那种
/// "整页都是这首歌的颜色"的观感。
///
/// ## 借鉴来源（许可与"借了什么"都写清）
///
/// 配方来自 **kumone**（独立网易云客户端，`LICENSE` = LGPL-3.0、`COPYING` = GPL-3.0；
/// 与本仓库 GPL-3.0 **兼容**）。它的 `NowPlayingView.backdrop`
/// （`Features/Player/NowPlayingView.swift:185-202`）是三层：
///
/// ```swift
/// ZStack {
///     LinearGradient(colors: [colors.primary, colors.secondary],
///                    startPoint: .topLeading, endPoint: .bottomTrailing)
///     RadialGradient(colors: [.white.opacity(0.12), .clear],
///                    center: .topLeading, startRadius: 0, endRadius: 700)
///     LinearGradient(colors: [.clear, .black.opacity(0.35)],
///                    startPoint: .top, endPoint: .bottom)
/// }
/// .animation(.easeInOut(duration: 0.8), value: colors)
/// ```
///
/// ⚠️ **关键：那层底是"取色渐变"，不是模糊封面**。本仓库 2026-10-02 那次"自绘壳"把整页
/// 糊掉（`Tweak.x.swift:384-387` 记着 bug 清单），根因是**加了一层模糊盖在内容上**。
/// 取色渐变是**在底层铺颜色**，机理相反，所以这次不会糊内容。
///
/// ## ★ 本轮（2026-10-03 夜，读完日志 38 之后）：换掉"看不见"的那套做法
///
/// **旧做法**（`a2360c0` → `b14d6b9`）：找到那层 → **清空它的 `backgroundColor`** →
/// 把渐变 `insertSublayer(at: 0)` + `zPosition = -1` 塞进**它自己的 layer 栈**。
///
/// **日志 38 的真机结论**（19:52–19:54，构建 = `b14d6b9`）：
/// ```
/// 11:52:59  [NPVStyle] no full-page coloured sibling found under UIView — backdrop skipped
/// 11:52:59  [NPVStyle] backdrop (414x896) ← 封面取色 e84838，接管 1 层（…）   ← 自报成功
/// 11:53:01  [Tree] #7 7.UIView@0,0,414,896,bg=#E84838                        ← 但它还在！
/// 11:53:03  [Tree] #8 7.UIView@0,0,414,896,bg=#E84838
/// 11:53:09  [Tree] #9 7.UIView@0,0,414,1682,bg=#584860                       ← 还自己换了色/长高
/// ```
/// `ViewTreeDumper.swift:159` 只在 `backgroundColor != nil && != .clear` 时才打 `bg=` ⇒
/// **我们"清空底色"这件事在树上没有留下任何痕迹**，页面上零变化。三个可能的机理：
///   1. 我们的层被插在人家的**最下面**（`at: 0` + `zPosition = -1`），那层若自己还有
///      子层/渐变（`dump-9.1.88.txt:3127` 就有 `NowPlaying_ScrollImpl.NPVGradientView`），
///      我们永远被压住；
///   2. 候选判据**没有可见性闸门**（旧代码不看 `isHidden` / `alpha`），可能垫了一层
///      看不见的满页视图 —— 同一页的 dump 里就有 `15.UIView@0,0,414,896,hidden,alpha=0.00`；
///   3. 就算接对了，Spotify 的 binder 会把底色**写回**（`MiniBarGlass.swift:244-285`
///      为同一个坑写过"清了又写回"），而旧代码 `lastHex` 相同就早退 ⇒ 永远修不回来。
///
/// **新做法**（本版，三条一起改）：
///   · **我们自己的一个整页 `UIView`**（三层 `CAGradientLayer` 作它的子层），
///     `insertSubview(at: 0)` 插进那层的**子视图**栈 —— 不碰人家的 `backgroundColor`，
///     也不跟人家的 layer 栈抢位置：
///       - 那层自己的底色在我们下面（我们铺的是**不透明**底 ⇒ 观感上就是"换掉了底色"）；
///       - 那层自己的**子视图**（真有内容的话）仍然在我们上面 ⇒ **最坏只是"没效果"，
///         不会是"盖掉内容"**；
///       - 全程零破坏性写入 ⇒ 关开关 = 把我们的视图拿走，**天然完全还原**。
///   · **可见性闸门**：`isHidden` / 祖先链 `alpha` / `window != nil` 三关都过才算候选，
///     被闸门挡掉的会**计数上报**（不然"没垫上"和"垫错层"在日志里长得一样）。
///   · **自愈**：`reconcile()` 蹭 `DeclutterChrome` 既有的复查节拍（**不新开定时器**），
///     颜色直接读**那一层自己的 `backgroundColor`**（Spotify 每首歌写一次，一次属性读），
///     变了才去问 `metadata()["extracted_color"]` 要权威值；尺寸每拍同步。
///
/// ## 纪律
///
/// * **幂等**：每次调用都先比对"当前是不是我们要的状态"，是就只更新颜色/尺寸，不重建；
/// * **零破坏**：不动 Spotify 任何属性（只加自己的子视图）⇒ `remove()` 一定是完全还原；
/// * **有上限**：走查最多 `maxNodes` 个视图；重找有 1s 节流（不变成变相轮询）；
/// * **自报**：垫上谁、被谁挡掉、跟到换色、重挂，各打一行 `[NPVStyle]`；
/// * 换色的交叉淡入时长取 `NowPlayingMetrics.backdropCrossfadeDuration`（kumone 的 0.8s）。
enum NowPlayingBackdrop {

    static let logTag = "NPVStyle"

    // MARK: - 常量

    /// 走查上限（本仓库纪律：2000 节点，见 `EeveeSettingsViewController` 那处）。
    private static let maxNodes = 2000
    /// "满页"的下限：真机里那层是**满宽**的，但未必满高（`7.UIView@0,0,414,896` 满高，
    /// 滚动后同一层会变成 `414x1682`）。只卡"满宽 + 足够高"。
    private static let minHeight: CGFloat = 150
    /// 径向白光晕的半径：kumone 是 `endRadius: 700`（**点**，不是比例）。
    private static let haloEndRadius: CGFloat = 700
    /// 重找节流：我们那层不见了的时候，别每 0.3s 走一遍页面树。
    private static let researchInterval: CFAbsoluteTime = 1.0

    /// 我们那层在真机树里的 id（排查时一眼认出）。
    private static let backdropIdentifier = "eevee-npv-backdrop"

    // MARK: - 状态

    /// 强引用挂在**被垫的那一层**上：那层随页面一起销毁，我们跟着走，不留悬挂引用。
    private static var backdropKey: UInt8 = 0
    /// 三个渐变子层挂在**我们自己的视图**上。
    private static var layersKey: UInt8 = 0

    private static weak var lastPage: UIView?
    private static weak var lastVictim: UIView?
    private static weak var lastBackdrop: UIView?

    /// 上一次用的封面色（**大写**十六进制）。比较一律走 `normaliseHex`。
    private static var lastHex: String?
    private static var lastSearchAt: CFAbsoluteTime = 0
    private static var colorUpdates = 0
    private static var reattaches = 0
    private static var didLogGiveUp = false
    private static var didLogAttach = false

    /// 我们那层里的三个渐变子层（顺序 = kumone 的 ZStack：取色底 → 白光晕 → 压黑）。
    private final class Layers {
        let base: CAGradientLayer
        let halo: CAGradientLayer
        let scrim: CAGradientLayer

        init(base: CAGradientLayer, halo: CAGradientLayer, scrim: CAGradientLayer) {
            self.base = base
            self.halo = halo
            self.scrim = scrim
        }
    }

    // MARK: - 对外入口

    /// 每次进入 / 切开关时调一次。`hex` 为 `nil` 表示"还没拿到封面色"。
    ///
    /// - Parameter hex: 封面取色，形如 `FFE84838`（8 位 ARGB）或 `E84838`（6 位 RGB）。
    ///   来源与歌词配色同一个：`track.metadata()["extracted_color"]`。
    static func apply(hex: String?, in pageView: UIView) {
        lastPage = pageView

        guard UserDefaults.nowPlayingBackdrop else {
            remove(reason: "switch off")
            return
        }

        let pageBounds = pageView.bounds
        guard pageBounds.width > 1, pageBounds.height > 1 else {
            writeDebugLog(
                "[\(logTag)] 页面视图还没有尺寸（\(Int(pageBounds.width))x\(Int(pageBounds.height))）— 本次不施加"
            )
            return
        }

        guard let hexText = normaliseHex(hex), let color = UIColor(hexString: hexText) else {
            // 没取色就不动别人的视图（宁可什么都不做，也不要铺一块灰）。
            logOnce("no extracted color yet — leaving Spotify's own background alone")
            return
        }

        // 已经垫过同一层 ⇒ 只"确保还挂着 + 跟上尺寸/颜色"，**不早退**。
        //
        // ⚠️ 旧实现在这里 `lastHex == hex` 就 return。那个早退是致命的自愈缺口：
        // 一旦我们的层被摘掉、或者 Spotify 把那一层换了实例，这个函数从此什么都不做。
        if let victim = lastVictim, victim.window != nil,
           let backdrop = lastBackdrop, backdrop.superview === victim,
           let layers = gradientLayers(of: backdrop) {
            lastSearchAt = CFAbsoluteTimeGetCurrent()
            refresh(victim: victim, backdrop: backdrop, layers: layers, hex: hexText, color: color)
            return
        }

        lastSearchAt = CFAbsoluteTimeGetCurrent()
        let found = candidates(in: pageView)
        guard let victim = found.first else {
            logOnce("no visible full-page coloured view under \(type(of: pageView)) — backdrop skipped")
            return
        }

        let backdrop = attach(to: victim)
        guard let layers = gradientLayers(of: backdrop) else { return }
        refresh(victim: victim, backdrop: backdrop, layers: layers, hex: hexText, color: color)
    }

    /// 设置页切开关时没有 VC：用"最近一次垫过的那一页"兜底。
    /// 那一页已经不在窗口里就什么都不做（等下次进听歌页）。
    static func refreshLastPage() {
        guard let page = lastPage, page.window != nil else { return }
        apply(hex: currentHex() ?? lastHex, in: page)
    }

    /// 关掉开关时把一切拿走。
    ///
    /// ★ 新做法**只加了自己的一个子视图**、没改 Spotify 任何属性 ⇒ 这里就是"拿掉它"，
    /// 不需要还原任何东西（旧版要写回 `backgroundColor`，那是个会漏的账）。
    static func remove(reason: String) {
        var backdrop: UIView? = lastBackdrop
        if backdrop == nil, let victim = lastVictim {
            backdrop = objc_getAssociatedObject(victim, &backdropKey) as? UIView
        }
        guard let backdrop else { return }

        if let victim = lastVictim {
            objc_setAssociatedObject(victim, &backdropKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        backdrop.removeFromSuperview()

        lastVictim = nil
        lastBackdrop = nil
        lastHex = nil
        didLogAttach = false
        writeDebugLog("[\(logTag)] backdrop removed（1 层已拿走，reason=\(reason)）")
    }

    // MARK: - 自愈（蹭既有节拍，不新开定时器）

    /// 由 `DeclutterChrome` 既有的复查节拍调用（0.3s、非前台不跑、`MainWindow` 布局才跑）。
    ///
    /// **为什么必须有它**（日志 38 的 #7→#9）：
    /// 用户**一直待在听歌页**时，Spotify 那层封面底色自己从 `bg=#E84838` 变成 `bg=#584860`、
    /// 高度从 896 变成 1682 —— 而这段时间里**没有第三次 `[NPVStyle]`**
    /// （`apply` 只在 `viewWillAppear` / `viewDidAppear` 跑）。
    /// 也就是说：换歌、滚动之后我们的层必然失配。这一支把那个窗口压到 ≤0.3s。
    ///
    /// 成本：没在听歌页时 = 两次 weak 读 + 一次 `window` 读；
    /// 在听歌页时 = 再加**一次 `backgroundColor` 读**（换色那一刻才问 metadata）。
    ///
    /// - Returns: 这一拍**真的动了**吗（给排查用）。
    @discardableResult
    static func reconcile() -> Bool {
        guard UserDefaults.nowPlayingBackdrop else { return false }
        guard let page = lastPage, page.window != nil else { return false }

        guard let victim = lastVictim, victim.window != nil,
              let backdrop = lastBackdrop, backdrop.superview === victim,
              let layers = gradientLayers(of: backdrop) else {
            // 页面还在、我们那层却没了（Spotify 换了实例 / 谁把我们的视图摘了）⇒ 重挂一次。
            // ⚠️ 有节流：不然每一拍都是一遍满树走查，那就成了变相轮询。
            let now = CFAbsoluteTimeGetCurrent()
            guard now - lastSearchAt >= researchInterval else { return false }
            lastSearchAt = now
            lastVictim = nil
            lastBackdrop = nil
            reattaches += 1
            writeDebugLog("[\(logTag)] 我们那层不在了 — 重挂（第 \(reattaches) 次）")
            apply(hex: currentHex() ?? lastHex, in: page)
            return true
        }

        var didSomething = false

        // ① 换歌：先读**那一层自己的底色**（Spotify 每首歌写一次，一次属性读）。
        //    真机依据：日志 38 里 `bg=#E84838` 与该曲 `extracted_color=e84838` **逐字相同**，
        //    而且 #9 那次它自己变成了 `#584860` —— 它就是我们的"换歌信号"，不用轮询接口。
        //    变了才去问 metadata 要权威值（那一句会走 Spotify 的接口，能省则省）。
        if let spotifyHex = victimHex(victim), spotifyHex != lastHex {
            let authoritative = currentHex() ?? spotifyHex
            if let color = UIColor(hexString: authoritative) {
                applyColors(layers, from: color, animated: true)
                lastHex = authoritative
                colorUpdates += 1
                didSomething = true
                writeDebugLog(
                    "[\(logTag)] 跟到换色 → \(authoritative)（第 \(colorUpdates) 次；"
                        + "那一层底色 \(spotifyHex)）"
                )
            }
        }

        // ② 尺寸：滚动时那层会长（896 → 1682），我们得跟上。
        if syncFrames(backdrop: backdrop, victim: victim, layers: layers) { didSomething = true }
        return didSomething
    }

    // MARK: - 垫上 / 刷新

    /// 把我们的整页底挂到 `victim` 的**子视图**栈最下面（幂等：已经有了就复用）。
    ///
    /// ⚠️ 为什么是 `insertSubview(at: 0)` 而不是 `insertSublayer`：
    /// 子视图只在**它自己的子视图**之下（而它自己的底色又在所有子视图之下）⇒
    /// 我们替掉的是"那一层的底色"，它自己的内容仍然压在我们上面。
    /// 旧版往人家的 **layer 栈**里插，那个位置既可能被它自己的子层压住，又不是视图层级的对手。
    private static func attach(to victim: UIView) -> UIView {
        if let existing = objc_getAssociatedObject(victim, &backdropKey) as? UIView {
            if existing.superview !== victim {
                victim.insertSubview(existing, at: 0)
            }
            return existing
        }

        let backdrop = UIView(frame: CGRect(origin: .zero, size: victim.bounds.size))
        backdrop.backgroundColor = .clear
        backdrop.isUserInteractionEnabled = false
        backdrop.isAccessibilityElement = false
        backdrop.clipsToBounds = true
        backdrop.accessibilityIdentifier = backdropIdentifier

        let layers = Layers(
            base: makeBase(in: backdrop.bounds),
            halo: makeHalo(in: backdrop.bounds),
            scrim: makeScrim(in: backdrop.bounds)
        )
        backdrop.layer.addSublayer(layers.base)
        backdrop.layer.addSublayer(layers.halo)
        backdrop.layer.addSublayer(layers.scrim)
        objc_setAssociatedObject(backdrop, &layersKey, layers, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        victim.insertSubview(backdrop, at: 0)
        objc_setAssociatedObject(victim, &backdropKey, backdrop, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return backdrop
    }

    /// 把 `backdrop` 上挂着的三个子层取回来（没有 / 不是我们挂的就返回 nil）。
    /// ⚠️ 名字刻意跟局部变量 `layers` 区分开 —— 同名会让 `let layers = layers(of:)`
    /// 这种写法踩 Swift 的名字查找（本机没有 Swift 工具链，不冒这个险）。
    private static func gradientLayers(of backdrop: UIView) -> Layers? {
        objc_getAssociatedObject(backdrop, &layersKey) as? Layers
    }

    /// 这一拍要做的事：对齐尺寸 + 必要时换色 + 第一次上报。
    private static func refresh(
        victim: UIView,
        backdrop: UIView,
        layers: Layers,
        hex: String,
        color: UIColor
    ) {
        lastVictim = victim
        lastBackdrop = backdrop

        syncFrames(backdrop: backdrop, victim: victim, layers: layers)

        let changed = (lastHex != hex)
        if changed {
            // 第一次铺不淡入（那是"进页面就有底色"）；换歌才 0.8s 交叉淡入（kumone 同值）。
            let animated = (lastHex != nil)
            applyColors(layers, from: color, animated: animated)
            lastHex = hex
            colorUpdates += 1
            if animated {
                writeDebugLog("[\(logTag)] 跟到换色 → \(hex)（第 \(colorUpdates) 次；来源 metadata）")
            }
        }

        reportAttachIfNeeded(victim: victim, backdrop: backdrop, hex: hex)
    }

    /// 对齐我们那层 / 三个子层的 frame。**返回这一拍有没有真的改东西**。
    @discardableResult
    private static func syncFrames(backdrop: UIView, victim: UIView, layers: Layers) -> Bool {
        var changed = false
        let wanted = CGRect(origin: .zero, size: victim.bounds.size)
        if backdrop.frame != wanted {
            backdrop.frame = wanted
            changed = true
        }
        let bounds = backdrop.bounds
        if layers.base.frame != bounds {
            layers.base.frame = bounds
            changed = true
        }
        if layers.scrim.frame != bounds {
            layers.scrim.frame = bounds
            changed = true
        }
        if layers.halo.frame != bounds {
            layers.halo.frame = bounds
            // kumone 的 `endRadius: 700` 是**点**；`CAGradientLayer` 的径向用单位坐标，
            // 所以每次尺寸变了都要按当前宽度换算，不然 700pt 会随屏幕宽窄漂掉。
            layers.halo.endPoint = haloEndPoint(for: bounds.size)
            changed = true
        }
        return changed
    }

    // MARK: - 三层（与 kumone 的 ZStack 一一对应）

    /// ① 取色对角渐变（**不透明** —— 它才是"把底色换掉"的那一层）。
    private static func makeBase(in bounds: CGRect) -> CAGradientLayer {
        let layer = CAGradientLayer()
        layer.startPoint = CGPoint(x: 0, y: 0)      // topLeading
        layer.endPoint = CGPoint(x: 1, y: 1)        // bottomTrailing
        layer.locations = [0.0, 1.0]
        layer.frame = bounds
        return layer
    }

    /// ② 左上白光晕（kumone 的 `RadialGradient(.white 12% → clear, 圆心左上, endRadius 700)`）。
    /// UIKit 里就是一个 `CAGradientLayer` 换成 `.radial`。
    private static func makeHalo(in bounds: CGRect) -> CAGradientLayer {
        let layer = CAGradientLayer()
        layer.type = .radial
        layer.startPoint = CGPoint(x: 0, y: 0)      // 圆心 = 左上
        layer.endPoint = haloEndPoint(for: bounds.size)
        layer.locations = [0.0, 1.0]
        layer.colors = [
            UIColor.white.withAlphaComponent(0.12).cgColor,
            UIColor.clear.cgColor,
        ]
        layer.frame = bounds
        return layer
    }

    /// ③ 底部压黑 35%（kumone 的 `LinearGradient(.clear → .black 35%, top → bottom)`）。
    private static func makeScrim(in bounds: CGRect) -> CAGradientLayer {
        let layer = CAGradientLayer()
        layer.startPoint = CGPoint(x: 0.5, y: 0)    // top
        layer.endPoint = CGPoint(x: 0.5, y: 1)      // bottom
        layer.locations = [0.0, 1.0]
        layer.colors = [
            UIColor.clear.cgColor,
            UIColor.black.withAlphaComponent(0.35).cgColor,
        ]
        layer.frame = bounds
        return layer
    }

    /// 把 kumone 的 700pt 半径换算成 `CAGradientLayer` 的单位坐标。
    private static func haloEndPoint(for size: CGSize) -> CGPoint {
        guard size.width > 1, size.height > 1 else { return CGPoint(x: 1, y: 1) }
        return CGPoint(x: haloEndRadius / size.width, y: haloEndRadius / size.height)
    }

    /// 换色。`animated` 走 `CATransaction`（**不是** `UIView.animate` —— 这里动的是
    /// `CAGradientLayer.colors`，是 CALayer 的隐式动画，kumone 的 `.easeInOut(0.8)` 同义）。
    private static func applyColors(_ layers: Layers, from base: UIColor, animated: Bool) {
        let colors: [CGColor] = [
            base.cgColor,
            base.darkened(by: 0.35).cgColor,
        ]

        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(NowPlayingMetrics.backdropCrossfadeDuration)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        } else {
            CATransaction.setDisableActions(true)
        }
        layers.base.colors = colors
        CATransaction.commit()
    }

    // MARK: - 找"那一层"

    /// 在 `root` 的子树里找"**看得见的**、满页、有自己底色"的视图，按面积从大到小。
    ///
    /// 判据（比旧版多一道可见性闸门，其余刻意保守）：
    ///   · 尺寸：满宽（容差 1pt）+ 高度 ≥ `minHeight`；
    ///   · `backgroundColor` 非空且非透明（纯色才值得垫；渐变/图案色读不出分量）；
    ///   · ★ 可见：自己与**祖先链**都不 `hidden` / `alpha > 0.01`，且在窗口里。
    ///     —— 旧版没有这一关，而 9.1.88 的听歌页里就躺着
    ///     `15.UIView@0,0,414,896,hidden,alpha=0.00` 这种满页不可见视图（日志 38 的 #7）。
    private static func candidates(in root: UIView) -> [UIView] {
        var accepted: [UIView] = []
        var invisible = 0
        var visited = 0
        var queue: [UIView] = root.subviews

        while !queue.isEmpty, visited < maxNodes {
            let view = queue.removeFirst()
            visited += 1
            queue.append(contentsOf: view.subviews)

            let wideEnough: Bool = view.bounds.width >= root.bounds.width - 1
            let tallEnough: Bool = view.bounds.height >= minHeight
            guard wideEnough, tallEnough else { continue }

            guard let color = view.backgroundColor, color != .clear else { continue }

            // 纯色才垫：动态色 / 图案色读不出分量，硬写会变成一块黑。
            // ⚠️ 条件拆开写 —— 合成一个长表达式会喂给类型检查器一个难题
            // （2026-10-03 已经在 `EeveeReduceInterventionsView` 上栽过一次
            // `unable to type-check this expression in reasonable time`）。
            let isPlainColour: Bool = color.cgColor.numberOfComponents >= 3
            var white: CGFloat = 0
            var alpha: CGFloat = 0
            let isGrayscale: Bool = color.getWhite(&white, alpha: &alpha)
            guard isPlainColour || isGrayscale else { continue }

            guard isEffectivelyVisible(view, upTo: root) else {
                invisible += 1
                continue
            }
            accepted.append(view)
        }

        if visited >= maxNodes {
            writeDebugLog("[\(logTag)] 走查到上限 \(maxNodes) 节点就停了（只接管已找到的 \(accepted.count) 层）")
        }
        if invisible > 0 {
            writeDebugLog(
                "[\(logTag)] 有 \(invisible) 个满页着色层是 hidden / 透明 / 不在窗口里 — 已排除"
            )
        }
        return accepted.sorted { area($0) > area($1) }
    }

    private static func area(_ view: UIView) -> CGFloat {
        view.bounds.width * view.bounds.height
    }

    /// 自己 + **祖先链**（到 `root` 为止）都不 hidden、alpha > 0，且真的挂在窗口里。
    private static func isEffectivelyVisible(_ view: UIView, upTo root: UIView) -> Bool {
        var node: UIView? = view
        while let current = node {
            if current.isHidden { return false }
            if current.alpha <= 0.01 { return false }
            if current === root { break }
            node = current.superview
        }
        return view.window != nil
    }

    /// 取那一层自己的底色（Spotify 每首歌写一次 = 我们的"换歌信号"）。
    private static func victimHex(_ view: UIView) -> String? {
        guard let color = view.backgroundColor, color != .clear else { return nil }
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
        guard alpha > 0.01 else { return nil }
        return String(
            format: "%02X%02X%02X",
            Int(red * 255), Int(green * 255), Int(blue * 255)
        )
    }

    /// 与 `refreshNowPlayingBackdrop` 同一处口径（`track.metadata()["extracted_color"]`）。
    /// **只在换色那一刻调一次** —— 0.3s 的节拍上不碰它。
    private static func currentHex() -> String? {
        let track = statefulPlayer?.currentTrack() ?? nowPlayingScrollViewController?.loadedTrack
        return normaliseHex(track?.metadata()["extracted_color"])
    }

    // MARK: - 日志

    /// 第一次垫上时上报**我们垫在谁身上**。
    ///
    /// 旧版那句"接管 1 层"只报了个数量 —— 日志 38 之后为了搞清"到底垫了哪一层"，
    /// 只能回头去翻 `[Tree]` 的 BFS 层级反推。这一版把身份、尺寸、那层自己的
    /// 底色/子视图/子层数全部记上，**下一次日志自己就能结案**。
    private static func reportAttachIfNeeded(victim: UIView, backdrop: UIView, hex: String) {
        guard !didLogAttach else { return }
        didLogAttach = true

        let sublayers = victim.layer.sublayers?.count ?? 0
        let manualLayers = max(0, sublayers - victim.subviews.count)

        writeDebugLog(
            "[\(logTag)] backdrop \(Int(backdrop.bounds.width))x\(Int(backdrop.bounds.height)) ← 封面取色 \(hex)"
                + "，垫在 \(type(of: victim)) \(frameText(victim.frame)) 之下"
                + "（那层底色 \(victimHex(victim) ?? "nil")，subviews=\(victim.subviews.count)，"
                + "layer.sublayers=\(sublayers)，手插子层=\(manualLayers)）"
                + "；三层：取色对角渐变、左上 12% 白光（r=700pt）、底部 35% 压黑，"
                + "\(NowPlayingMetrics.backdropCrossfadeDuration)s 交叉淡入"
        )

        if manualLayers > 0 {
            writeDebugLog(
                "[\(logTag)] ⚠️ 那层自己还挂着 \(manualLayers) 个手插子层 — 万一截图仍无变化，"
                    + "就是它们压着我们（下一版把 backdrop 提到最上面）"
            )
        }
    }

    private static func frameText(_ frame: CGRect) -> String {
        "\(Int(frame.origin.x)),\(Int(frame.origin.y)),\(Int(frame.width)),\(Int(frame.height))"
    }

    private static func logOnce(_ message: String) {
        guard !didLogGiveUp else { return }
        didLogGiveUp = true
        writeDebugLog("[\(logTag)] \(message)")
    }

    /// 十六进制统一成**大写无 `#`**：`normaliseHex("e84838") == normaliseHex("#E84838")`。
    /// 为什么必须统一：换歌比较是字符串比较，而 Spotify 那边给的是小写、view 底色读出来是大写。
    private static func normaliseHex(_ raw: String?) -> String? {
        guard var hex = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !hex.isEmpty else {
            return nil
        }
        if hex.hasPrefix("#") { hex.removeFirst() }
        let upper = hex.uppercased()
        guard upper.count == 6 || upper.count == 8 else { return nil }
        guard UInt64(upper, radix: 16) != nil else { return nil }
        return upper
    }
}

// MARK: - 颜色工具（本文件私有，避免污染全局）

private extension UIColor {
    /// 解析 `#RRGGBB` / `RRGGBB` / `AARRGGBB` / `FFRRGGBB`。
    /// 与仓库里 `Color(hex:)` 的口径一致（8 位时前两位是 alpha）。
    convenience init?(hexString: String?) {
        guard var hex = hexString?.trimmingCharacters(in: .whitespacesAndNewlines), !hex.isEmpty else {
            return nil
        }
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6 || hex.count == 8,
              let value = UInt64(hex, radix: 16) else { return nil }

        let r, g, b, a: CGFloat
        if hex.count == 8 {
            a = CGFloat((value >> 24) & 0xFF) / 255
            r = CGFloat((value >> 16) & 0xFF) / 255
            g = CGFloat((value >> 8) & 0xFF) / 255
            b = CGFloat(value & 0xFF) / 255
        } else {
            a = 1
            r = CGFloat((value >> 16) & 0xFF) / 255
            g = CGFloat((value >> 8) & 0xFF) / 255
            b = CGFloat(value & 0xFF) / 255
        }
        self.init(red: r, green: g, blue: b, alpha: a)
    }

    /// 降低明度（保持色相）：用作渐变的"暗角"那一端。
    func darkened(by amount: CGFloat) -> UIColor {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard getHue(&h, saturation: &s, brightness: &b, alpha: &a) else { return self }
        return UIColor(hue: h, saturation: s, brightness: max(0, b - amount), alpha: a)
    }
}
