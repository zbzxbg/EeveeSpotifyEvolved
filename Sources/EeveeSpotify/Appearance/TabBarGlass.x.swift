import Foundation
import Orion
import UIKit
import ObjectiveC.runtime

/// 底部标签栏玻璃 —— 第 4 版：**一条玻璃胶囊，锚在"图标那一行"上**。
///
/// ── v3 错在哪（日志 20 第一次拿到真 frame，坐实的）────────────────────────────
/// 真机结构（`[TabBarDump]` 日志 20 ↔ `[Tree]` 两条来源逐字对上）：
/// ```
/// TabBarView(414x83 @ 窗口 (0,813)；窗口 414x896，底部安全区 34)   ← hook 挂这里
/// └ TabBarCompactView(414x83) ★自带一层 CAGradientLayer            ← 这条栏的"底"
///   ├ TabBarGradientView(0,-112 414x195)      ← 已被 NewDesignYield 藏掉
///   └ UIStackView(0,0 414x49, id=tabs-container-view-identifier)   ← 四颗是这条 stack 里的兄弟
///     └ …TabBarItemElementView(103x49)
///        ├ Encore.IconView (40,5  24x24)
///        └ Encore.Label    (41,33 22x15)
/// ```
/// **v3 的错在锚点**：它按"整条栏"（83pt）居中 → 胶囊 `(8,6 398x71)`、中心 41.5；
/// 而图标那一行的内容只占 `5..48`、中心 26.5 —— **中心差了 15pt**。
/// 照片 22 上就是这三个现象：图标顶(5) 比胶囊顶(6) 还高 1pt；文字底(48) 下面挂了
/// **29pt 空玻璃**；胶囊底(77) 离屏幕底只剩 6pt —— 整条"沉"在下面，浮不起来。
///
/// **v4 的规矩**：以"图标内容带"为心（不是整条栏）。
///
/// ── v4.2（2026-10-02，用户反馈两条）────────────────────────────────────────
///   ① **"四颗离得太开"** → `tightenRow` 用 **transform** 把四颗往中心收 20%
///      （外两颗各向内 ~31pt，间距 103.5 → 82.7pt）。用 transform 是因为它
///      **不参与布局**，不会和 Spotify 的布局回合打架（详细纪律见 `tightenRow`）。
///   ② **"玻璃太扁（宽高比不对）"** → 胶囊改成**贴着图标那一行**：
///      宽 = 内容带宽 + 左右各 20（上限仍是"栏宽 − 16"），高 = 内容带高 + 上下各 8。
///      按日志 20 的真数据推算（内容带 `(40,4 342x44)`，收紧后约 271 宽）：
///      **`(51,-4 311x60)` r=30** —— 从 398×71（5.6:1）变成 311×60（5.2:1）；
///      底边离屏幕 29pt，顶部最多越出栏 8pt（栏不裁剪，依据见 `maxOverhang`）。
///
/// ── 为什么"每颗一块"注定不像（v1/v2 的错，别再犯）───────────────────────────
/// 四颗是**同一条 stack 里的兄弟视图** → "每颗一块玻璃"永远**不会融合**。
/// MeloX 那种"靠近就融合"要求把它们搬进同一个玻璃容器（`UIGlassContainerEffect`），
/// 那会打断 Spotify 自己的布局与手势 —— **不做**。
/// 用户要的是照片 21 那种**一条通栏的胶囊玻璃筋**，图标浮在上面。
///
/// ── v4.1（2026-10-02，照片 24 + 日志 21）：首次进入时那条"小棍" ──────────────
/// 现象：冷启动第一次进主页，胶囊是**一条贴在栏底的 16pt 小棍**；点一下别的标签、
/// 或划掉 Spotify 再进来就正常。
/// 真机那一行：
/// ```
/// [TabBarPlate] 胶囊 (8,67 398x16) r=8.0 ← 图标内容带 (inf,inf 0x0) [栏 414x83]
/// ```
/// 根因：**第一次布局时这条栏还没进窗口** → `convert(_:to:)` 全返回 `CGRectNull`
/// → 内容带 `(inf,inf 0x0)` → `height = max(16, 0+10) = 16`、`midY = inf` 被夹到底边
/// → `(8,67 398x16)`。之后要等**下一次布局**（用户点一下）才自愈 —— 日志 21 里
/// 那一次隔了 22 秒。
/// 现在：**几何不可信就先不画**（`isUsable`），并在 ~1.2s 内自己重试到摆对为止。
///
/// ── 层序（v4 改）────────────────────────────────────────────────────────────
/// v3 插在 `TabBarView.subviews[0]` —— 正好在 `TabBarCompactView` **之下**，
/// 而那层 CompactView 自带一条 `CAGradientLayer`，是画在我们玻璃**之上**的
/// （`SESSION_2026-10-02_APPEARANCE.md` §3.5 预写的判断，真机 dump 坐实）。
/// v4 插到**图标 stack 的正下方**：原生渐变在玻璃下面、图标在玻璃上面，两个条件同时成立。
///
/// ⚠️ 顺带记一笔：全树 dump（日志 20）里 `UIVisualEffectView` **只有我们这一块**
/// → 标签栏**没有**系统玻璃，"自绘"这条路线是对的，不存在"让位"的对象。
struct TabBarGlassGroup: HookGroup {}

enum TabBarGlassPlate {

    static var isEnabled: Bool { UserDefaults.tabBarGlass }

    /// 玻璃层挂在宿主上的关联键。
    private static var plateKey: UInt8 = 0

    /// 图标那一行的容器（真机 dump 里的 id，四颗标签是它的子视图）。
    private static let tabsStackIdentifier = "tabs-container-view-identifier"

    /// 左右留边。照片 21 里那条胶囊**不是**贴边的，两侧有明显留白。
    private static let sideInset: CGFloat = 8

    /// 上下留边：胶囊高 = 图标内容带高 + 上下各这么多。
    /// **这一项就是"胖瘦"旋钮**：5 → 53pt 高；8 → 60pt（2026-10-02 用户反馈
    /// "玻璃太扁（宽高比不对）"，从 5 调到 8）。
    private static let verticalPadding: CGFloat = 8

    /// 左右留边：胶囊 = **图标内容带** + 左右各这么多。
    /// ⚠️ 不再是"栏宽 − 固定值"：四颗被收紧之后，胶囊要贴着那一行走，不然又变成一条长条。
    private static let horizontalPadding: CGFloat = 20

    /// 四颗往中心收的比例（0 = 不动，1 = 全收到中心）。
    /// 用户反馈"四个图标之间距离太大" → 0.20：外两颗各向内 ~31pt，间距 103.5 → 82.7pt。
    /// **只在 `stack.subviews.count == 4` 这个已知形状上生效**。
    private static let tightenFactor: CGFloat = 0.20

    /// 允许胶囊最多越出栏顶多少。
    /// 依据（真机，日志 20）：这条栏**不裁剪** —— 它自己的
    /// `TabBarGradientView(0,-112 414x195)` 就画在栏顶以上 112pt 处。
    private static let maxOverhang: CGFloat = 8

    /// 上一次报出去的胶囊 frame（只在变化时打日志，不在布局回调里刷屏）。
    private static var lastReportedFrame: CGRect = .null
    private static var reportCount = 0

    /// 已经成功摆过一次"可信几何"的胶囊了吗。
    ///
    /// 首次布局时这条栏**可能还没进窗口**（日志 21 的真机故障）：那时所有
    /// `convert(_:to:)` 都返回 `CGRectNull`，内容带就是 `(inf,inf 0x0)` ——
    /// v4.0 会把它当成"高 0"，算出 `(8,67 398x16)` 那条贴在栏底的小棍（照片 24）。
    /// 现在：**没摆过就不画**（宁可不画，也不画错的），并且自己重试。
    private static var hasGoodFrame = false

    /// 重试计数（有上限，到点收手并打一行日志，不做常驻轮询）。
    private static var retryCount = 0
    private static var didReportGiveUp = false

    /// 给**栏**铺一条玻璃胶囊。幂等：位置没变就一个字节都不碰。
    @MainActor
    static func apply(to bar: UIView) {
        guard isEnabled else {
            removePlate(from: bar)
            return
        }
        guard bar.bounds.width > 1, bar.bounds.height > 1 else { return }

        // 图标那一行（`tabs-container-view-identifier`）：既决定尺寸，也决定层序。
        let stack = findTabsStack(in: bar)

        let plate: UIVisualEffectView
        if let existing = objc_getAssociatedObject(bar, &plateKey) as? UIVisualEffectView {
            plate = existing
        } else {
            plate = makeGlassView()
            objc_setAssociatedObject(bar, &plateKey, plate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            writeDebugLog("[TabBarPlate] 玻璃胶囊已铺在 \(className(bar)) 上")
        }
        layering(plate: plate, stack: stack, bar: bar)

        // ★ 先把四颗往中间收（用 transform，**不改布局**），**再**量内容带 ——
        //   这样量到的就是收紧后的真实位置，胶囊自然贴着它们走。
        if let stack { tightenRow(stack, in: bar) }

        // ── 摆位：以"图标内容带"为心（不是整条栏；v3 就是死在这里）─────────────
        let band = contentBand(in: bar, stack: stack)

        // ⚠️ 几何不可信就**什么都不画**（v4.0 在这里画出了一条 16pt 的小棍）。
        // 真机证据（日志 21）：
        //   `[TabBarPlate] 胶囊 (8,67 398x16) r=8.0 ← 图标内容带 (inf,inf 0x0) [栏 414x83]`
        //   —— `CGRectNull` 的 `midY` 是 `inf`，被夹到底边，于是那条"小棍"贴在栏底，
        //   直到你点一下别的标签 / 划掉再进，触发下一次布局才变正常。
        guard isUsable(band: band, bar: bar) else {
            if !hasGoodFrame { plate.isHidden = true }
            scheduleRetry(for: bar)
            return
        }
        if plate.isHidden { plate.isHidden = false }
        hasGoodFrame = true
        retryCount = 0

        // 宽：**贴着图标那一行**（+ 左右留边），上限是"栏宽 − sideInset×2"。
        let width = min(
            max(16, bar.bounds.width - sideInset * 2),
            max(16, band.width + horizontalPadding * 2)
        )
        // 高：内容带 + 上下留边；允许最多越出栏顶 `maxOverhang`（栏不裁剪，见常量说明）。
        let height = min(
            bar.bounds.height + maxOverhang,
            max(16, band.height + verticalPadding * 2)
        )
        let centeredY = band.midY - height / 2
        let y = min(max(-maxOverhang, centeredY), max(0, bar.bounds.height - height))
        let target = CGRect(
            x: band.midX - width / 2,
            y: y,
            width: width,
            height: height
        )

        // frame 是相对**父视图**的：v4 起玻璃住在 CompactView 里，坐标系与栏一致，
        // 但仍然显式换算一次 —— 免得将来层序再变就摆错地方。
        let frame = (plate.superview ?? bar).convert(target, from: bar)

        if !plate.frame.equalTo(frame) {
            plate.frame = frame
        }
        let radius = height / 2
        if abs(plate.layer.cornerRadius - radius) > 0.01 {
            plate.layer.cornerRadius = radius
        }

        report(frame: frame, band: band, bar: bar, host: plate.superview)
    }

    @MainActor
    static func removePlate(from bar: UIView) {
        guard let plate = objc_getAssociatedObject(bar, &plateKey) as? UIVisualEffectView else { return }
        plate.removeFromSuperview()
        objc_setAssociatedObject(bar, &plateKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    // MARK: - 层序

    /// 把玻璃放到**图标 stack 的正下方**：原生那层渐变在玻璃下面、图标在玻璃上面。
    ///
    /// 幂等：已经在正确位置就什么都不做（这是 `layoutSubviews` 里的铁律）。
    /// 兜底：找不到 stack 时退回栏的索引 0 —— 那正是 v3 的行为，至少不是新的错误。
    @MainActor
    private static func layering(plate: UIVisualEffectView, stack: UIView?, bar: UIView) {
        if let stack, let host = stack.superview {
            let plateIndex = host.subviews.firstIndex { $0 === plate }
            let stackIndex = host.subviews.firstIndex { $0 === stack }
            if plate.superview !== host || (plateIndex ?? 0) > (stackIndex ?? 0) {
                host.insertSubview(plate, belowSubview: stack)
            }
        } else if plate.superview !== bar {
            bar.insertSubview(plate, at: 0)
        }

        // 下面四条只写自己身上，且值没变就不写（写值会安排布局，白写等于自找活干）。
        if plate.isUserInteractionEnabled { plate.isUserInteractionEnabled = false }
        if plate.autoresizingMask != [] { plate.autoresizingMask = [] }
        if !plate.clipsToBounds { plate.clipsToBounds = true }
        if plate.layer.cornerCurve != .continuous { plate.layer.cornerCurve = .continuous }
    }

    // MARK: - 收紧四颗（用户反馈"图标之间距离太大"）

    /// 把四颗标签往中间收一点。
    ///
    /// ⚠️ **为什么用 `transform` 而不是改 frame/约束**：
    /// transform 是"渲染期"的位移，**不参与布局** —— 于是
    ///   ① Spotify 的布局回合不会把它算掉（不需要每帧重写，那正是文档里禁止的事）；
    ///   ② 不会触发它们的约束/`layoutSubviews` 级联，也就不会像"挪别人的视图"那样
    ///      把布局与手势打断。
    ///
    /// 代价与两条纪律：
    ///   · 这几颗的"视觉位置"与"布局位置"分开了 → **凡是反过来量它们位置的地方一律用
    ///     `convert(_:to:)`**（UIKit 会算上 transform）；本文件里所有取值都已经这么做了；
    ///   · 算"往中心收多少"时**必须用 `item.frame.midX`**（布局位置，不受 transform 影响），
    ///     不能用 `convert(item.center)` —— 那会把自己上一轮收进去的量再算一遍，越收越拢。
    ///
    /// 幂等 + 可撤销：值没变不写；`tightenFactor = 0` 时恢复 `.identity`。
    /// 只在"四颗"这个已知形状上动：数量一变就什么都不做（宁可不动，也别乱动）。
    @MainActor
    private static func tightenRow(_ stack: UIView, in bar: UIView) {
        let items = stack.subviews
        guard items.count == 4 else { return }

        let centerX = bar.bounds.midX
        for item in items {
            let layoutMidX = stack.convert(CGPoint(x: item.frame.midX, y: 0), to: bar).x
            let dx = (centerX - layoutMidX) * tightenFactor
            let wanted: CGAffineTransform = abs(dx) < 0.5
                ? .identity
                : CGAffineTransform(translationX: dx, y: 0)
            if item.transform != wanted { item.transform = wanted }
        }
    }

    // MARK: - 找图标那一行 / 量它的内容带

    /// 从栏里找 `tabs-container-view-identifier` 那条 stack（四颗标签的父视图）。
    ///
    /// 认 id 不认层级：真机 dump 里它就是这个名字，而层级将来可能变。
    @MainActor
    static func findTabsStack(in bar: UIView) -> UIView? {
        var found: UIView?

        func walk(_ node: UIView, _ depth: Int) {
            guard found == nil, depth <= 6 else { return }
            if node !== bar, node.accessibilityIdentifier == tabsStackIdentifier {
                found = node
                return
            }
            for sub in node.subviews { walk(sub, depth + 1) }
        }

        walk(bar, 0)
        return found
    }

    /// 图标那一行**真正看得见的内容**的范围（栏坐标系）。
    ///
    /// 为什么不用 stack 自己的框：真机树里 stack 是 `0..49`，但里面的
    /// `Encore.IconView` 在 `5..29`、`Encore.Label` 在 `33..48` —— 那 5pt 的顶部留白
    /// 不该算进"图标那一行"，否则胶囊又会偏下去（v3 的错就是这么来的）。
    ///
    /// 兜底两档（都来自真机观察，不是猜的）：
    ///   1. 找不到 stack → 认定图标带在栏顶、高 = 栏高 − 底部安全区（真机是 49）；
    ///   2. 四颗都还没排（dump 里三颗的中间层当时就是 `0x0`）→ 用 stack 框内缩 4pt。
    @MainActor
    private static func contentBand(in bar: UIView, stack: UIView?) -> CGRect {
        guard let stack else {
            let bottom = bar.safeAreaInsets.bottom
            return CGRect(
                x: 0, y: 0,
                width: bar.bounds.width,
                height: max(16, bar.bounds.height - bottom)
            )
        }

        var union: CGRect?
        collectContent(stack, into: &union, in: bar, depth: 0)
        if let union, union.height > 1 { return union }

        return stack.convert(stack.bounds, to: bar).insetBy(dx: 0, dy: 4)
    }

    /// 内容带到底可不可信？—— v4.1 的护栏。
    ///
    /// 四条判据都来自日志 21 那次真机故障：`CGRectNull`、无穷原点、高度离谱、
    /// **栏还没进窗口**（`window == nil` 时 `convert(_:to:)` 全废，算出来就是 null）。
    /// 真机正常值是内容带 `(40,4 342x44)` —— 高 43~44pt。
    @MainActor
    private static func isUsable(band: CGRect, bar: UIView) -> Bool {
        guard bar.window != nil else { return false }
        guard !band.isNull, !band.isInfinite else { return false }
        guard band.width > 1, band.height >= 20 else { return false }
        return true
    }

    /// 布局时机不等人：首次那几帧拿不到几何时，自己在一小段时间内重试。
    ///
    /// 上限 12 次 × 0.1s ≈ 1.2s；到点还不行就打一行日志收手。
    /// ⚠️ **刻意不做常驻轮询** —— 那就变成"在布局回调里反复写"那个老毛病了。
    @MainActor
    private static func scheduleRetry(for bar: UIView) {
        guard retryCount < 12 else {
            if !didReportGiveUp {
                didReportGiveUp = true
                writeDebugLog(
                    "[TabBarPlate] ⚠️ 拿不到图标内容带的几何（栏还没进窗口？）— 这一轮先不画，等下一次布局"
                )
            }
            return
        }
        retryCount += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            onMainThreadSync {
                guard isEnabled else { return }
                apply(to: bar)
            }
        }
    }

    /// 收集"看得见的内容"的并集（坐标换算到 `space` 里）。返回"这一支有没有贡献内容"。
    ///
    /// 判据全部来自真机 dump：
    ///   · `hidden`（那颗 `6x6` 的蓝色小点）与 `alpha=0.00`（「创建」那颗的白色圆底）**都不算内容**；
    ///   · `Encore.Label` 底下还挂着一个 `0x0` 的 `UILabel` —— 所以"叶子"不能只看有没有子视图，
    ///     要**子节点都没成形时才算自己**，否则那个 `22x15` 的 frame 会被 0x0 的孩子吃掉。
    @MainActor
    @discardableResult
    private static func collectContent(
        _ node: UIView,
        into union: inout CGRect?,
        in space: UIView,
        depth: Int
    ) -> Bool {
        guard depth <= 8, !node.isHidden, node.alpha > 0.01 else { return false }

        var contributed = false
        for sub in node.subviews where !sub.isHidden && sub.alpha > 0.01 {
            if collectContent(sub, into: &union, in: space, depth: depth + 1) {
                contributed = true
            }
        }
        if contributed { return true }

        let rect = node.convert(node.bounds, to: space)
        guard rect.width > 0.5, rect.height > 0.5 else { return false }
        union = union.map { $0.union(rect) } ?? rect
        return true
    }

    /// 报一次账：插在哪、摆在哪、内容带是多少。
    /// 只在 frame 变化时报，且最多 6 条 —— 下次日志不用看图就能验这条改动。
    @MainActor
    private static func report(frame: CGRect, band: CGRect, bar: UIView, host: UIView?) {
        guard !frame.equalTo(lastReportedFrame) else { return }
        lastReportedFrame = frame
        guard reportCount < 6 else { return }
        reportCount += 1

        writeDebugLog(String(
            format: "[TabBarPlate] 胶囊 (%.0f,%.0f %.0fx%.0f) r=%.1f ← 图标内容带 (%.0f,%.0f %.0fx%.0f)"
                + " [栏 %.0fx%.0f] 插在 %@ 里",
            frame.origin.x, frame.origin.y, frame.size.width, frame.size.height,
            frame.size.height / 2,
            band.origin.x, band.origin.y, band.size.width, band.size.height,
            bar.bounds.width, bar.bounds.height,
            host.map { className($0) } ?? "—"
        ))
    }

    /// 造玻璃视图。
    ///
    /// ⚠️ **探测式**：iOS 26+ 上 `UIGlassEffect` 是真的（系统液态玻璃，带折射与边缘高光），
    /// 拿不到就退 `.systemUltraThinMaterialDark`（iOS 13+ 就有）。
    /// **不写 `#available`** —— 与本仓库既有做法一致（`AmoledTheme.x.swift`）。
    @MainActor
    private static func makeGlassView() -> UIVisualEffectView {
        let view = UIVisualEffectView(effect: nil)
        if let glassType = NSClassFromString("UIGlassEffect") as? UIVisualEffect.Type {
            view.effect = glassType.init()
            writeDebugLog("[TabBarPlate] 用的是系统真玻璃 UIGlassEffect")
        } else {
            view.effect = UIBlurEffect(style: .systemUltraThinMaterialDark)
            writeDebugLog("[TabBarPlate] 系统没有 UIGlassEffect — 退回材质")
        }
        return view
    }

    private static func className(_ view: UIView) -> String {
        NSStringFromClass(type(of: view))
    }
}

// MARK: - Hook

/// 挂在**标签栏容器**上：这条栏的布局一变，就重算那条玻璃胶囊的 frame。
///
/// 真类名：`NavigationUI_TabBarImpl.TabBarView`
/// （IPA `_TtC23NavigationUI_TabBarImpl10TabBarView` ↔ 真机 dump
///  `#1 NavigationUI_TabBarImpl.TabBarView frame=(0,0 414x83) id=elements-tabs-view-identifier`）。
///
/// ⚠️ 只碰**这一个目标**（栏自己）：不像听歌页那版"遍历整窗 + 每帧清别人底色"，
/// 所以不会影响滚动或别处。
class TabBarPlateHook: ClassHook<UIView> {
    typealias Group = TabBarGlassGroup
    static let targetName = "NavigationUI_TabBarImpl.TabBarView"

    func layoutSubviews() {
        orig.layoutSubviews()
        let bar = self.target
        onMainThreadSync {
            TabBarGlassPlate.apply(to: bar)
        }
    }
}

func activateTabBarGlass() {
    guard NSClassFromString(TabBarPlateHook.targetName) != nil else {
        writeDebugLog("[TabBarPlate] missing \(TabBarPlateHook.targetName) — 未装")
        return
    }
    TabBarGlassGroup().activate()
    writeDebugLog(
        "[TabBarPlate] installed (enabled=\(UserDefaults.tabBarGlass ? "ON" : "OFF"))"
            + " — 一条玻璃胶囊，锚在图标那一行上，图标浮在它上面"
    )
}
