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
/// ── v4.6（2026-10-02，用户反馈两条）────────────────────────────────────────
///   ① **"点『创建』之后玻璃被拉高"** → 病根：胶囊是按"**看得见**的内容"量出来的，
///      而「创建」那颗**被选中时会显示一个 40×40 的白色圆底**
///      （dump：`UIView frame=(32,4 40x40) bg=#FFFFFF alpha=0.00`）。文字藏着时
///      内容带只剩图标 24pt → 那颗圆底一出现就把带子撑到 40pt → 胶囊 40 → 56pt 且
///      **图标落在胶囊中心上方 8pt**（照片 29 逐像素实测：胶囊 110px=55pt、图标中心偏上 8pt）。
///      **规矩（用户拍板）**：胶囊高度**永远按"有文字"的版式**算 ——
///      与「隐藏标签文字」开关、与「创建」选中与否都无关。
///   ② **文字藏起来时，四个图标要在这一行里垂直居中** → 量算改成**只读布局几何**
///      （`layer.position` / `bounds`，**不含我们写进去的 transform**），于是
///      `dy = 有文字带.midY − 图标带.midY` 是个**常量**（真机 ≈ +10pt）：
///      一次算准、不自我反馈；关掉开关时它自己回到 0。
///   ③ **删掉拖动**（v4.3 那一套）：用户报「本该不可滑动的导航栏在某个页面里能被拖着走」
///      （日志 25 的 `[Tree]` 里能看到胶囊与四颗一起被拖到 y=-27）。按下回弹
///      （`UIGlassEffect.isInteractive`）**保留**，折射本来就是系统玻璃自带的；
///      pan / dragOffset / dragLimit / `TabBarDragTarget` 全部删除。
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

    /// 上下留边：胶囊高 = **"有文字"版式那条带子**的高 + 上下各这么多。
    /// **这一项就是"胖瘦"旋钮**：5 → 53pt 高；8 → 61pt（2026-10-02 用户反馈
    /// "玻璃太扁（宽高比不对）"，从 5 调到 8）。
    /// ⚠️ v4.6 起这里的"带子"**永远按有文字的版式算**（见 `contentBands`），
    /// 所以高度与「隐藏标签文字」开关无关 —— 用户拍板的就是这一条。
    private static let verticalPadding: CGFloat = 8

    /// 左右留边：胶囊 = **有文字版式那条带子** + 左右各这么多。
    /// ⚠️ 不再是"栏宽 − 固定值"：四颗被收紧之后，胶囊要贴着那一行走，不然又变成一条长条。
    private static let horizontalPadding: CGFloat = 20

    /// 四颗往中心收的比例（0 = 不动，1 = 全收到中心）。
    /// 用户反馈"四个图标之间距离太大" → 0.20：外两颗各向内 ~31pt，间距 103.5 → 82.7pt。
    /// **只在 `stack.subviews.count == 4` 这个已知形状上生效**。
    private static let tightenFactor: CGFloat = 0.20

    /// 纵向居中的位移上限。真机算出来是 ≈ +10pt；给它 24 是"万一量歪了，
    /// 也不至于把图标推到栏外去"的保险丝。
    private static let rowShiftLimit: CGFloat = 24

    /// 允许胶囊最多越出栏顶多少（v4.6 起基本用不到：有文字版式算出来是 `y = -3`）。
    /// 依据（真机，日志 20）：这条栏**不裁剪** —— 它自己的
    /// `TabBarGradientView(0,-112 414x195)` 就画在栏顶以上 112pt 处。
    private static let maxOverhang: CGFloat = 8

    /// 边缘高光：借 **MeloX** 的手法 —— 他们旧系统兜底那一支画的是
    /// `Capsule().stroke(.white.opacity(0.32), lineWidth: 0.75)`。
    /// 我们这条是深色玻璃，取比他们更淡一点，只负责把边缘"立"起来。
    private static let edgeHighlightWidth: CGFloat = 0.75
    private static let edgeHighlightAlpha: CGFloat = 0.22

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

    /// 系统玻璃是否支持 `isInteractive`（按下弹性反馈）。造玻璃时探一次，之后只用结果。
    private static var interactiveOn = false

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

        // ★ 按开关处理"标签文字"（默认藏）。**量算不再依赖这件事** ——
        //   `contentBands` 走的是"布局几何 + **有文字的版式**"（v4.6）：
        //   文字藏没藏、「创建」那颗的白色圆底露没露出，量出来的带子都一样。
        applyLabelVisibility(in: stack)

        // ★ 四颗的横向收紧量：**只看布局**（v4.4 起就是这么算的），不看 transform。
        let dx = tightenOffsets(in: bar, stack: stack)

        // ── 摆位：以"有文字的那条带子"为心 ──────────────────────────────────────
        //   ⚠️ 这里的带子**含横向收紧量、不含纵向位移** ——
        //   胶囊的位置与大小因此与"我们给四颗挪了多少"完全无关（不会自我反馈）。
        let bands = contentBands(in: bar, stack: stack, dx: dx, dy: 0)
        // 兜底：图标/文字一个都没认出来（类名换了）→ 退回 v4.5 的老量法（看得见的内容）。
        let band = bands.full ?? bands.icons ?? contentBand(in: bar, stack: stack)

        // ── 纵向：文字藏起来时，把四个图标挪到这条带子的**中心** ────────────────
        //   有文字时不动（那是 Spotify 自己的"图标 + 文字"版式，本来就填满这条带子）。
        let dy = rowShiftForIcons(bands: bands)

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
        // 高：**"有文字"版式的那条带子** + 上下留边（用户 2026-10-02 拍板：
        //     无论「隐藏标签文字」开还是关，高度都按有文字时算 —— 高度因此恒定）。
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

        // ★ 最后才写四颗的 transform：横向收紧 + （文字藏起来时）纵向居中。
        //   幂等（值没变不写）且**不动布局** —— 与 v4.2 起定的纪律一致。
        if let stack { tightenRow(stack, in: bar, dx: dx, dy: dy) }

        // frame 是相对**父视图**的：v4 起玻璃住在 CompactView 里，坐标系与栏一致，
        // 但仍然显式换算一次 —— 免得将来层序再变就摆错地方。
        // ⚠️ v4.6 起**没有**拖动位移这一项了（拖动已删，见文件头 ③）。
        let frame = (plate.superview ?? bar).convert(target, from: bar)

        if !plate.frame.equalTo(frame) {
            plate.frame = frame
        }
        let radius = height / 2
        if abs(plate.layer.cornerRadius - radius) > 0.01 {
            plate.layer.cornerRadius = radius
        }

        report(frame: frame, band: band, icons: bands.icons, shift: dy, bar: bar, host: plate.superview)
    }

    @MainActor
    static func removePlate(from bar: UIView) {
        guard let plate = objc_getAssociatedObject(bar, &plateKey) as? UIVisualEffectView else { return }
        plate.removeFromSuperview()
        objc_setAssociatedObject(bar, &plateKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    // MARK: - 量算：四颗的布局几何（v4.6 起不再读 frame，也不 convert 到栏）

    /// 四颗的**横向收紧量**（只看布局，不看 transform —— v4.4 的教训）。
    ///
    /// ⚠️ 首次布局时 `stack.bounds.width == 0`（内容还没排），那时按它推算会得到
    /// "四颗全被推 +41"（照片 28 / 日志 24 的真凶）。所以宽度没过闸就**一律返回空**：
    /// 这一轮不收紧（量出来的就是没收紧的布局），`apply` 那边的有界重试会把我们叫回来。
    /// 形状不是"四颗"时同样不动（宁可不动，也别乱动）。
    @MainActor
    private static func tightenOffsets(in bar: UIView, stack: UIView?) -> [CGFloat] {
        guard let stack, stack.subviews.count == 4, stack.bounds.width > 100 else { return [] }
        let count = CGFloat(stack.subviews.count)
        let centerX = bar.bounds.midX

        return (0..<stack.subviews.count).map { index in
            // ★ 用**等分布局推算**中心，而不是读 `item.frame.midX`：
            //   Apple 对 `frame` 的说明是"transform 非恒等时该值未定义"，实测它会把我们
            //   上一轮写进去的位移算进去 → 每轮又按"已经被挪过的位置"再收一次 →
            //   收敛点整体偏移，**两端最明显**（第 4 颗「创建」偏得最多）。
            let localMidX = stack.bounds.width * (CGFloat(index) + 0.5) / count
            let layoutMidX = stack.convert(CGPoint(x: localMidX, y: 0), to: bar).x
            return (centerX - layoutMidX) * tightenFactor
        }
    }

    /// 四颗的**内容带**：`icons` 只算图标，`full` 是"图标 ∪ 文字"（= **有文字的版式**）。
    ///
    /// ── 为什么另起一套，不用下面的 `contentBand`（"看得见的内容"并集）──────────
    /// v4.5 那条"点『创建』玻璃就被拉高"正是它造成的：「创建」那颗**选中时会显示一个
    /// 40×40 的白色圆底**（dump：`UIView frame=(32,4 40x40) bg=#FFFFFF alpha=0.00`）——
    /// 它既不是图标也不是文字，却会被"并集"算成内容 → 文字藏着时带子 24 → 40pt →
    /// 胶囊 40 → 56pt（照片 29 实测 55pt，且图标落在中心上方 8pt）。
    /// 现在只认两类节点（图标 / 文字）：白色圆底天然不算内容；文字**藏没藏都算**
    /// （藏起来时它的 frame 仍然有效，真机 dump：`SPTEncoreLabel frame=(41,34 22x16) hidden`）
    /// → 量出来的**永远是有文字的版式**，与「隐藏标签文字」这个开关无关。
    ///
    /// ── 为什么读 `layer.position` / `bounds`，不读 `frame` / `convert(...)` ──
    /// 后两者**包含我们上一轮写进去的 transform**；v4.6 起 transform 里还有纵向位移，
    /// 一漂就变成"胶囊跟着一起往下走"。CALayer 的 `position` 是"布局把这一颗放在哪儿"
    /// （transform 是绕 anchorPoint 施加的，不动 position），`bounds` 是布局尺寸，两个都干净。
    /// 子树内部用 `node.convert(node.bounds, to: item)` —— 这一段不经过 item 自己的 transform。
    ///
    /// - Parameters:
    ///   - dx: 每颗的横向收紧量（**要算进**带子，胶囊才贴着收紧后的那一行走）。
    ///   - dy: 纵向位移。**量胶囊时传 0**：胶囊的位置绝不能随我们给四颗的位移走
    ///     （否则纵向位移会把胶囊一起搬下去 —— 看着像"没居中"，其实是整体在漂）。
    @MainActor
    private static func contentBands(
        in bar: UIView,
        stack: UIView?,
        dx: [CGFloat],
        dy: CGFloat
    ) -> (icons: CGRect?, full: CGRect?) {
        guard let stack else { return (icons: nil, full: nil) }

        var icons: CGRect?
        var full: CGRect?

        for (index, item) in stack.subviews.enumerated() {
            let size = item.bounds.size
            // ⚠️ **有一颗还没排（size 0）就整条都不量**：宁可退回老量法（`contentBand`）
            //    并等下一次布局，也不要拿"四颗里只有一颗有几何"去算胶囊 ——
            //    那会画出一条只裹着那一颗的小胶囊（v4.0 的"16pt 小棍"就是同一类事故）。
            guard size.width > 1, size.height > 1 else { return (icons: nil, full: nil) }

            // ① 布局原点（`layer.position` 不受 transform 影响，见上面的说明）。
            let position = item.layer.position
            let originX = position.x - size.width / 2 + (index < dx.count ? dx[index] : 0)
            let originY = position.y - size.height / 2 + dy

            var iconUnion: CGRect?
            var labelUnion: CGRect?
            collectBandNodes(
                in: item, node: item, depth: 0,
                iconInto: &iconUnion, labelInto: &labelUnion
            )

            // ② 子树里的矩形是**相对 item** 的；加上布局原点与位移，再整体换算到栏坐标系。
            func inBar(_ rect: CGRect) -> CGRect {
                stack.convert(rect.offsetBy(dx: originX, dy: originY), to: bar)
            }

            if let iconUnion {
                let rect = inBar(iconUnion)
                icons = icons.map { $0.union(rect) } ?? rect
                full = full.map { $0.union(rect) } ?? rect
            }
            if let labelUnion {
                let rect = inBar(labelUnion)
                full = full.map { $0.union(rect) } ?? rect
            }
        }

        return (icons: icons, full: full)
    }

    /// 一棵子树里的**图标**与**文字**（并集成相对 `root` 的矩形）。
    ///
    /// 认类名（`EncoreIconView` / `EncoreLabel`），**不做运行时类枚举** —— 那条路崩过两次。
    /// ⚠️ 这里**故意不看 `isHidden` / `alpha`**：要的就是"有文字的版式"（文字是我们自己藏的），
    /// 而「创建」那颗白色圆底那种装饰，靠"不是图标也不是文字"被排除掉。
    @MainActor
    private static func collectBandNodes(
        in root: UIView,
        node: UIView,
        depth: Int,
        iconInto: inout CGRect?,
        labelInto: inout CGRect?
    ) {
        guard depth <= 8 else { return }

        let name = NSStringFromClass(type(of: node))
        let isIcon = name.contains("EncoreIconView")
        let isLabel = name.contains("EncoreLabel")
        if isIcon || isLabel {
            let rect = node.convert(node.bounds, to: root)
            if rect.width > 0.5, rect.height > 0.5 {
                if isIcon {
                    iconInto = iconInto.map { $0.union(rect) } ?? rect
                } else {
                    labelInto = labelInto.map { $0.union(rect) } ?? rect
                }
            }
            // 图标/文字底下不再往下找（里层的 `UILabel` 类名是 `UILabel`，本来也不会命中）。
            return
        }

        for sub in node.subviews {
            collectBandNodes(
                in: root, node: sub, depth: depth + 1,
                iconInto: &iconInto, labelInto: &labelInto
            )
        }
    }

    /// 文字藏起来时，四个图标要**往下挪多少**才落在这一行的中心上。
    ///
    /// `dy = 有文字带.midY − 图标带.midY`（真机 ≈ +10pt）。两个带子都是"布局几何"量的，
    /// 而且 dy 同时作用于两者 → 相减之后 **dy 自己消掉**：这是**常量**，一次算准、不自我反馈。
    /// 有文字时返回 0：那是 Spotify 自己的"图标 + 文字"版式，本来就填满这条带子。
    @MainActor
    private static func rowShiftForIcons(bands: (icons: CGRect?, full: CGRect?)) -> CGFloat {
        guard UserDefaults.tabBarHideLabels else { return 0 }
        guard let icons = bands.icons, let full = bands.full else { return 0 }
        let delta = full.midY - icons.midY
        guard abs(delta) >= 0.5 else { return 0 }
        return max(-rowShiftLimit, min(rowShiftLimit, delta))
    }

    // MARK: - 拖动：**已删除**（v4.6）

    /// v4.3 那套"推一下、玻璃像液体一样折、松手弹回"**整段删掉了**。
    ///
    /// 用户 2026-10-02 反馈：「本该不可滑动的导航栏，在某个页面里能被拖着走」
    /// —— 日志 25 的 `[Tree]` 就是现场：`UIVisualEffectView@39,0,312,40` /
    /// `ElementContentView@19,3,103,49`，胶囊与四颗一起被拖到 y=-27。
    ///
    /// 保留的是**按下回弹**（造玻璃时的 `UIGlassEffect.isInteractive`，见 `makeGlassView`）——
    /// 那才是"液态"的手感来源；拖动是 v4.3 额外加的一层，现在按用户要求撤掉。
    /// （要恢复的话：git 历史里的 v4.3 那一段 + `tightenRow` 的 `dx/dy` 上加一份 dragOffset。）

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

        // 下面几条只写自己身上，且值没变就不写（写值会安排布局，白写等于自找活干）。
        // 玻璃要能"按下回弹"就得收触摸：它在图标**之下**，标签点击不受影响，
        // 只有胶囊四角的空白会落到它身上（那里本来也没东西可点）。
        if plate.isUserInteractionEnabled != interactiveOn {
            plate.isUserInteractionEnabled = interactiveOn
        }
        if plate.autoresizingMask != [] { plate.autoresizingMask = [] }
        if !plate.clipsToBounds { plate.clipsToBounds = true }
        if plate.layer.cornerCurve != .continuous { plate.layer.cornerCurve = .continuous }
    }

    // MARK: - 四颗的位移（横向收紧 + 纵向居中）

    /// 把四颗标签挪到位：**横向往中间收** + **纵向落到这一行的中心**（v4.6）。
    ///
    /// ⚠️ **为什么用 `transform` 而不是改 frame/约束**：
    /// transform 是"渲染期"的位移，**不参与布局** —— 于是
    ///   ① Spotify 的布局回合不会把它算掉（不需要每帧重写，那正是文档里禁止的事）；
    ///   ② 不会触发它们的约束/`layoutSubviews` 级联，也就不会像"挪别人的视图"那样
    ///      把布局与手势打断。
    ///
    /// 代价与两条纪律：
    ///   · 这几颗的"视觉位置"与"布局位置"分开了 → **凡是反过来量它们位置的地方，
    ///     一律不能读 `frame` / `center`**（那里带着我们的位移）；v4.6 起量算全部改走
    ///     `layer.position` / `bounds`（见 `contentBands`），理由都写在那儿；
    ///   · `dx` / `dy` **由调用方算好**（`tightenOffsets` / `rowShiftForIcons`），
    ///     这个函数只负责"写进 transform、幂等"。
    ///
    /// 幂等 + 可撤销：值没变不写；`tightenFactor = 0` 且 `dy = 0` 时恢复 `.identity`。
    /// - Parameters:
    ///   - dx: 每颗的横向收紧量；数量对不上（不是四颗 / 布局还没排好）时传空数组 = 不动。
    ///   - dy: 纵向位移（文字藏起来时的"落到中心"，见 `rowShiftForIcons`）。
    @MainActor
    private static func tightenRow(_ stack: UIView, in bar: UIView, dx: [CGFloat], dy: CGFloat) {
        let items = stack.subviews
        guard items.count == 4, dx.count == items.count else { return }

        for (index, item) in items.enumerated() {
            let offset = CGPoint(x: dx[index], y: dy)
            let wanted: CGAffineTransform = (abs(offset.x) < 0.5 && abs(offset.y) < 0.5)
                ? .identity
                : CGAffineTransform(translationX: offset.x, y: offset.y)
            if item.transform != wanted { item.transform = wanted }
        }
    }

    // MARK: - 标签文字（默认藏）

    /// 藏掉四颗标签的文字（照片 21/23/25 里那条栏**没有文字**）。**默认开**。
    ///
    /// ── 为什么这件事值得做 ────────────────────────────────────────────────────
    /// ① 观感：照片里那条栏只有图标，文字一去掉整条就"干净"了；
    /// ② 藏掉之后**图标那一行更干净、也更矮**，但要按什么高度画由 `contentBands` 说了算 ——
    ///    v4.6 起"带子"永远按**有文字的版式**量，所以这条开关**只影响文字与图标的纵向居中，
    ///    不影响胶囊的高度**（用户 2026-10-02 拍板）。
    ///
    /// ⚠️ 会不会被 Spotify 的 binder 写回来？—— 每次栏布局我们都会再走一遍，并且**计数**；
    /// 写回超过 `labelWriteBackLimit` 次就停手并打日志（宁可保持原生，也不跟它抢 —— 文档铁律）。
    ///
    /// 思路借自 **spoti.pw** 的「Hide labels」（`docs/tweaks.md`）；**只借思路，代码自己写**。
    private static var labelMarkKey: UInt8 = 0
    private static var labelWriteBacks = 0
    private static let labelWriteBackLimit = 12
    private static var didGiveUpLabels = false
    private static var didLogLabelState = false

    @MainActor
    private static func applyLabelVisibility(in stack: UIView?) {
        guard let stack else { return }

        let shouldHide = UserDefaults.tabBarHideLabels
        guard !(shouldHide && didGiveUpLabels) else { return }

        var hid = 0
        var restored = 0
        var writeBacks = 0

        for label in encoreLabels(in: stack) {
            let isOurs = objc_getAssociatedObject(label, &labelMarkKey) != nil

            if shouldHide {
                guard !label.isHidden else { continue }
                if isOurs {
                    writeBacks += 1                       // 我们藏过，它又被显示回来了
                } else {
                    objc_setAssociatedObject(
                        label, &labelMarkKey, true, .OBJC_ASSOCIATION_RETAIN_NONATOMIC
                    )
                }
                label.isHidden = true
                hid += 1
            } else if isOurs, label.isHidden {
                label.isHidden = false                    // 只还原**我们自己藏过的**
                restored += 1
            }
        }

        if writeBacks > 0 {
            labelWriteBacks += writeBacks
            if labelWriteBacks > labelWriteBackLimit, !didGiveUpLabels {
                didGiveUpLabels = true
                writeDebugLog(
                    "[TabBarPlate] ⚠️ 标签文字被反复写回 \(labelWriteBacks) 次 — 不再与它抢（保持原生）"
                )
            }
        }

        guard !didLogLabelState, hid > 0 || restored > 0 else { return }
        didLogLabelState = true
        writeDebugLog(
            "[TabBarPlate] 标签文字\(shouldHide ? "已隐藏" : "已恢复")（\(shouldHide ? hid : restored) 个）"
        )
    }

    /// 收集四颗里的 `SPTEncoreLabel`（**只认类名，不做运行时类枚举** —— 那条路崩过两次）。
    ///
    /// ⚠️ 认的是外层 `SPTEncoreLabel`，不是它里面那个 `UILabel`（`Encore.Label-internal`）——
    /// 藏外层就够了，里层跟着一起不可见。
    @MainActor
    private static func encoreLabels(in stack: UIView) -> [UIView] {
        var found: [UIView] = []
        collectEncoreLabels(in: stack, depth: 0, into: &found)
        return found
    }

    @MainActor
    private static func collectEncoreLabels(in node: UIView, depth: Int, into found: inout [UIView]) {
        guard depth <= 8 else { return }
        if NSStringFromClass(type(of: node)).contains("EncoreLabel") { found.append(node) }
        for sub in node.subviews { collectEncoreLabels(in: sub, depth: depth + 1, into: &found) }
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
    /// ⚠️ **v4.6 起这个只当兜底**：正常路径走 `contentBands`（布局几何 + 有文字的版式）。
    /// 只有"图标 / 文字一个都没认出来"（类名换了）或"四颗还没排"时才落到这里，
    /// 好处是**行为跟 v4.5 一致**（宁可保持原样，也不画错）。
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
                    "[TabBarPlate] ⚠️ 拿不到四颗的几何（栏还没进窗口？）— 这一轮先不画，等下一次布局"
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

    /// 报一次账：插在哪、摆在哪、**有文字版式那条带子**是多少、图标被下移了多少。
    /// 只在 frame 变化时报，且最多 10 条 —— 下次日志不用看图就能验这条改动。
    ///
    /// v4.6 起这一行是**验收证据**：高度应当是"有文字"的 `~61`（`…x61`），
    /// 而且**点不点「创建」都是这个数**；`dy=+10` 表示图标已经被挪到这一行的中心。
    @MainActor
    private static func report(
        frame: CGRect,
        band: CGRect,
        icons: CGRect?,
        shift: CGFloat,
        bar: UIView,
        host: UIView?
    ) {
        guard !frame.equalTo(lastReportedFrame) else { return }
        lastReportedFrame = frame
        guard reportCount < 10 else { return }
        reportCount += 1

        let iconText = icons.map {
            String(format: "(%.0f,%.0f %.0fx%.0f)",
                   $0.origin.x, $0.origin.y, $0.size.width, $0.size.height)
        } ?? "—"

        writeDebugLog(String(
            format: "[TabBarPlate] 胶囊 (%.0f,%.0f %.0fx%.0f) r=%.1f ← 有文字带 (%.0f,%.0f %.0fx%.0f)"
                + " 图标带 %@ dy=%+.1f [栏 %.0fx%.0f] 插在 %@ 里",
            frame.origin.x, frame.origin.y, frame.size.width, frame.size.height,
            frame.size.height / 2,
            band.origin.x, band.origin.y, band.size.width, band.size.height,
            iconText, shift,
            bar.bounds.width, bar.bounds.height,
            host.map { className($0) } ?? "—"
        ))
    }

    /// 造玻璃视图。
    ///
    /// ⚠️ **探测式**：iOS 26+ 上 `UIGlassEffect` 是真的（系统液态玻璃，带折射与边缘高光），
    /// 拿不到就退 `.systemUltraThinMaterialDark`（iOS 13+ 就有）。
    /// **不写 `#available`** —— 与本仓库既有做法一致（探测式取系统类，见 `TabBarGlassProbe`）。
    @MainActor
    private static func makeGlassView() -> UIVisualEffectView {
        let view = UIVisualEffectView(effect: nil)
        if let glassType = NSClassFromString("UIGlassEffect") as? UIVisualEffect.Type {
            let effect = glassType.init()
            // ★ 按下时的弹性反馈（`UIGlassEffect.isInteractive`，iOS 26+）。
            // **探测式**：getter/setter 都在才写 KVC —— 否则 KVC 碰到未知 key 会抛异常（崩）。
            let object = effect as? NSObject
            let hasGetter = object?.responds(to: NSSelectorFromString("isInteractive")) ?? false
            let hasSetter = object?.responds(to: NSSelectorFromString("setInteractive:")) ?? false
            if hasGetter, hasSetter {
                object?.setValue(true, forKey: "interactive")
                interactiveOn = true
                writeDebugLog("[TabBarPlate] UIGlassEffect.isInteractive = true（按下会回弹）")
            } else {
                writeDebugLog("[TabBarPlate] 这版没有 isInteractive — 跳过按下回弹")
            }
            view.effect = effect
            writeDebugLog("[TabBarPlate] 用的是系统真玻璃 UIGlassEffect")
        } else {
            view.effect = UIBlurEffect(style: .systemUltraThinMaterialDark)
            writeDebugLog("[TabBarPlate] 系统没有 UIGlassEffect — 退回材质")
        }

        // 一圈极淡的白色描边高光（照片 21/23/25 那条胶囊的边缘就是这么"立"起来的）。
        // 借的是 MeloX 的写法 —— 他们旧系统兜底那一支画的是
        // `Capsule().stroke(.white.opacity(0.32), lineWidth: 0.75)`。
        // `UIGlassEffect` 自带边缘高光，但在深色内容上不够，补这一圈把"廉价感"压下去
        // （文档 §3.5 早就预判了这条：形状对了但廉价 → 加淡描边高光，不改结构）。
        view.layer.borderWidth = edgeHighlightWidth
        view.layer.borderColor = UIColor.white.withAlphaComponent(edgeHighlightAlpha).cgColor

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
/// 所以不会影响滚动或别处。v4.6 起**也不再往这条栏上装任何手势**（拖动已删）。
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
            + "（v4.6：高度按「有文字」版式恒定、无拖动）"
    )
}
