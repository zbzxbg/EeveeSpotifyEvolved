import Foundation
import Orion
import UIKit
import ObjectiveC.runtime

/// 标签栏的**共用几何与内容取舍**。
///
/// ## ★★ 2026-10-13：**自绘那条玻璃胶囊已整条删除**（用户："标签用液态玻璃这个功能可以删掉了"）
///
/// 这个文件现在只剩三件事，**两条玻璃路之外的东西都别再往这里放**：
///
///   ① **几何判据（唯一一处）**：`findTabsStack` 找到那一行（**四个槽位**；「创建」被藏掉时
///      它仍然占着第 4 个槽 —— 见 `applyCreateTabVisibility` 与 `visibleItems`），
///      `targetCapsuleRect` 算出"胶囊该在哪、多大"，`capsuleRect` 顺手把宽度报给
///      `MiniBarGlass`（两条胶囊等宽，用户 2026-10-02 拍的板）；
///      ⇒ **`TabBarSystemGlass` 摆它那条系统栏的宿主就用这一份**（第二片起就是如此）。
///   ② **标签内容的取舍**：`applyLabelVisibility`（藏文字）+ `applyCreateTabVisibility`（藏「创建」：
///      **保住槽位、只藏内容**）+ `visibleItems`（"占着槽位的那几颗"，所有按颗数算的地方都走它）。
///   ③ **钩子**：`TabBarPlateHook.layoutSubviews`（栏自己每次布局）把这些按顺序跑一遍。
///
/// 删掉的是**画**的那一半：`apply` / `removePlate` / `layering` / `makeGlassView` /
/// `plateKey` / `interactiveOn`，以及只为它服务的 **纵向位移**（`rowShifts` / `iconShifts` /
/// 那一套"暂时不齐"的复核）、`tightenRow`（真的去收四颗）与 `report`。
/// 开关 `tabBarGlass`（"标签用液态玻璃"）连同 `UserDefaults` 键、设置页那一行、
/// 两条文案一起删；系统玻璃那条路**一个字没动**。
///
/// ⚠️ 为什么几何里还留着 `tightenFactor`：胶囊的宽度 = "那一带宽 + 88"，而"那一带宽"
/// 是**按收紧后的版式**算出来的（`measure` 收 `tightenOffsets`）——
/// 也就是说 `0.20` 这个数现在的作用是"**胶囊比整条栏窄多少**"，而不是"图标真的被收过"。
/// 真机四颗时那条带子是 272 → 胶囊 `272 + 88 = 360`（屏宽 414 的 87%），
/// 正是用户要的那条宽度。**删了这一项，胶囊会变成贴边的一条（≈398）**。
///
/// ---
///
/// ## 历史（自绘胶囊 v3–v4.10 的调参记录；对应的**画**与**位移**代码已删，留作数字的来历）
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
/// ── v4.6.1（2026-10-02，照片 30/31/32 + 日志 26）────────────────────────────
///   **"点开『创建』之后另外三颗图标被顶高了"** —— v4.6 的 `dy` 是**四颗共用一个数**，
///   而「创建」那颗在菜单打开时它的 `SPTEncoreIconView` 会从 `24×24` 变成 **`33×33`**
///   （真机 tree #7：`IconView@35,7,33,33`）→ 图标带 `272x24` 变 `277x36`、中心 17→23
///   → `dy` 从 `+10.0` 缩到 `+3.8` → 另外三颗被顶高 6pt（照片 32 逐像素量 7pt）。
///   日志 26 两条自报就是现场：`312x60 / dy=+10.0` ↔ `317x60 / dy=+3.8`。
///   **修法**：①尺寸**按中位归一化**（每块矩形用中位宽高重建、只保留自己的中心）
///   —— 胶囊因此恒为 `312x60`，不再 312 ↔ 317；②纵向位移**一颗一个数**
///   （`rowShifts`，基准是每颗**自己看得见的内容**）——「创建」那颗由它的白圆底去对中心，
///   另外三颗仍由各自的 24pt 图标去对，谁也不会被对方拽偏。
///
/// ── v4.10（2026-10-02 第三轮，日志 30 + 照片 38）────────────────────────────
///   **v4.9 的"整行共用一个数"治好了上移，却带来了下偏** ——
///   用户："点击『创建』之后，那个按钮会**往下偏**（关闭展示标签栏文字才有这个问题）"。
///   照片 38 就是现场：菜单开着时那颗**白圈明显低于另外三颗**（约 7pt）。
///   原因：整行只按 `+10` 走，而那一颗的内容（33pt 图标 + 40pt 白圆底）中心在 24.5
///   → 圆心被摆到了胶囊中心下方。
///
///   **v4.10 的结论：回到"一颗一个数"（v4.8 的 `iconShifts`），上移那个老毛病交给
///   v4.9 的复核机制兜**（`rowIsTransient` + 短促重试 + `DeclutterChrome` 的 0.5s 节拍，
///   **不等布局回合** —— "等不到布局"正是 v4.8 卡死的根因）。
///   两根钉子各管一头：
///     · 菜单**开着** → 它按自己的内容居中（`dy` → `+2.5`），白圈正落胶囊中心；
///     · 菜单**关掉** → 复核在 ≤0.5s 内自己重算回 `+10`（日志 30 已证复核真的会跑：
///       `[TabBarPlate] 这一行暂时不齐…（v4.9）`）。
///
/// ── v4.9（2026-10-02 第二轮，**Spotify 9.1.88** + 日志 29）───────────────────
///   用户："还是有点击『创建』再取消，这个按钮看起来的高度还有文字时一样（上移）"。
///   **日志 29 的现场**（9.1.88）：
/// ```
/// 02:14:51  [TabBarPlate] … dy=[+10.0,+10.0,+10.0,+10.0] 基=图标      ← 正常
/// 02:14:53  [TabBarPlate] … dy=[+10.0,+10.0,+10.0,+2.5] 基=图标      ← 点开「创建」的瞬间
/// 02:14:53  [Tree] #1   ElementContentView@279,10                     ← 还没变
/// 02:14:54  [Tree] #2   ElementContentView@279,2                      ← 之后 7 份 dump 全是 2
/// …一直到 02:15:09（#8）还是 @279,2                                    ← 16 秒没回来
/// ```
///   v4.8 的“按图标当基准”**算对了**，但只解决了一半：**菜单关掉时这条栏不一定会再布局**
///   （`TabBarView.layoutSubviews` 不再来）→ 我们那个 `+2.5` 的 transform **没人去改**，
///   于是创建那颗永远比另外三颗高 8pt。两个修法叠起来：
///   ① **四颗共用一个位移**（不再是"一颗一个数"）：取每颗"按自己图标"算出来的期望值的
///      **中位数**。菜单开着时只有「创建」那一颗的期望值不同（它 33pt 的图标中心跑到
///      24.5）→ 中位数仍然是 `+10` → **那一颗的暂时态再也带不动自己**，卡死这条路直接断掉。
///      （这也是 v4.6.1 想解决的事的"正解"：共用一个数要**取中位数**，不能取被拉偏的那个。）
///   ② **安全网**：一旦这一行"明显不齐"（`hasDeviation`），置位 `rowIsTransient` 并
///      排一轮短促复核（0.2/0.5/1/2/3.5s）+ 蹭 `DeclutterChrome` 既有的 0.5s 节拍
///      （`reconcileRowIfTransient()`）—— **不等布局回合**，自己直接重算。
///      行一稳，两边都变成一次 bool 读（零开销）。
///
/// ── v4.8（2026-10-02，用户反馈两条 + 日志 28 / 照片 36/37）──────────────────
///   ① **"液态玻璃的宽度有点少"** → `horizontalPadding` `20 → 44`：
///      真机 272 + 44×2 = **360pt**（屏宽 414 的 87%；v4.2–v4.7 是 312）。
///      迷你条那条按比例跟着变长（两条永远等宽），副作用是**好事**：
///      它内容要缩的比例从 0.74 抬到 ~0.86，歌名/按钮看得更清楚。
///   ② **"隐藏标签文字时，点『创建』再取消，创建那颗变高（到了有文字时的高度）"**
///      —— 日志 28 的现场：`dy=[+10.0,+10.0,+10.0,+2.5]`，而且**取消之后不再回到 +10**
///      （dump #5→#13 里那一颗的 `ElementContentView` 一直渲染在 `y=2` 而不是 `y=10`）。
///      v4.6.1 的纵向基准是每颗**看得见的内容**（`visibleBand`），它对「创建」那颗会塌成
///      两个坏值：菜单开合时它**把整颗 item 的框（103×49，中心 24.5）当内容**
///      （子树那一刻整个不可见 → 兜底返回自己），于是 `dy = 27 − 24.5 = +2.5` —— 正好是
///      用户说的"有文字时的高度"（有文字时 `dy = 0`，图标就在 5…29，比居中位置高 7.5pt）。
///      **修法**：文字藏起来时**改用每颗自己的图标**（`EncoreIconView`）当纵向基准
///      —— 图标是最稳定的东西（菜单开着时它临时变 33pt、那一次跟着居中；**取消后一定
///      回到 24×24@y=5**），白圆底与 item 兜底框都不再参与定位。文字**显示**时仍走
///      `visibleBand`（那时必须让文字留在胶囊里，用图标当基准会把整颗往下推 10pt）。
///      验收行：点开「创建」再取消，日志里 `dy` 必须回到 `[+10.0,+10.0,+10.0,+10.0]`
///      （v4.8 起 `report` 在 **dy 变了**时也会打一行，见 `report`）。
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
/// ⚠️ 2026-10-13 更正：上面这句在 v4 时是对的（当时全树 dump 里只有我们那块
/// `UIVisualEffectView`），但**现在不对了** —— 系统玻璃那条路会叠一条真 `UITabBar`，
/// 它的浮岛玻璃（`_UITabBarPlatterView` / `_UILiquidLensView`）就是"系统玻璃"本身。
/// 我们自绘那块**已删除**（见文件头），所以这条栏的玻璃现在**只有系统那一条**。
struct TabBarGlassGroup: HookGroup {}

enum TabBarGlassPlate {

    /// 图标那一行的容器（真机 dump 里的 id，四颗标签是它的子视图）。
    private static let tabsStackIdentifier = "tabs-container-view-identifier"

    /// 左右留边。照片 21 里那条胶囊**不是**贴边的，两侧有明显留白。
    private static let sideInset: CGFloat = 8

    /// 上下留边**已经不在这里**了（v4.7）：高度改由 `GlassCapsule.height` 统一给，
    /// 因为用户要求迷你播放条那条胶囊**与这条等高**（见 `GlassCapsule` 的说明）。
    /// 历史：v4.2 时这里是个"胖瘦旋钮"（5 → 53pt；8 → 60pt），实测值就是 8。

    /// 左右留边：胶囊 = **有文字版式那条带子** + 左右各这么多。
    /// ⚠️ 不再是"栏宽 − 固定值"：四颗被收紧之后，胶囊要贴着那一行走，不然又变成一条长条。
    ///
    /// **v4.8 值 = 44**（用户 2026-10-02：「液态玻璃的宽度有点少，给它伸长一点」）：
    /// 真机带子是 272 → `272 + 44×2 = 360pt`（屏宽 414 的 87%），比 v4.2–v4.7 的 312 长 48。
    /// 改这一个数**两条胶囊一起变**（迷你条按 `capsuleWidthRatio` 等宽跟随），
    /// 并且迷你条的内容缩放会从 `(312−16)/398 ≈ 0.74` 抬到 `(360−16)/398 ≈ 0.86`
    /// （缩得越少，歌名/按钮越清楚）—— 见 `MiniBarGlass`。
    private static let horizontalPadding: CGFloat = 44

    /// 四颗往中心收的比例（0 = 不动，1 = 全收到中心）。
    /// 原来（v4.2）是"四颗离得太开"的修法：外两颗各向内 ~31pt；**真的去收四颗的
    /// `tightenRow` 已随自绘胶囊一起删除**（2026-10-13）—— 现在这个数只参与
    /// `tightenOffsets` → `measure`，也就是"**胶囊按收紧后的版式算多宽**"（见文件头）。
    /// **只在"占着槽位的颗数"是 2–4 这个已知形状上生效**（按 `visibleItems` 数）。
    /// ⚠️ 2026-10-13 第二条要求之后，藏掉「创建」**不再改变这个数**（四个槽位仍然是四个：
    /// 它保住槽位、只把内容藏掉）—— 这正是"玻璃宽度不变"的来源。
    private static let tightenFactor: CGFloat = 0.20

    /// 允许胶囊最多越出栏顶多少（v4.6 起基本用不到：有文字版式算出来是 `y = -3`）。
    /// 依据（真机，日志 20）：这条栏**不裁剪** —— 它自己的
    /// `TabBarGradientView(0,-112 414x195)` 就画在栏顶以上 112pt 处。
    private static let maxOverhang: CGFloat = 8

    // MARK: - 报给迷你播放条用的宽度（两条要等宽）

    /// 标签栏这条胶囊**当前的宽度**（pt，栏坐标系）。
    /// 迷你播放条那条要跟它**等宽**（用户 2026-10-02 拍的板），所以每次摆位都刷新一次。
    /// ⚠️ 只有本文件写它（约定只读；`swift_member_check.py` 认不了 `private(set)`，
    ///    所以这里没用那个修饰符 —— 与本仓库既有的 static 成员写法保持一致）。
    static var capsuleWidth: CGFloat = 0

    /// 上面那个宽度**相对栏宽的比例**（真机四颗时 360 / 414 ≈ 0.87）。
    ///
    /// 迷你条那边按"**自己的宿主宽 × 这个比例**"来算，于是换设备 / 换屏幕宽度时两条仍然等宽
    /// （直接传绝对值的话，iPad 上就不成对了）。拿不到时那边有兜底比例，见 `MiniBarGlass`。
    static var capsuleWidthRatio: CGFloat = 0

    // MARK: - 胶囊几何（**只此一份**）

    /// 胶囊的矩形 = 宽度 + 高度 + 它在栏里的位置。
    ///
    /// ★ 2026-10-12：**系统玻璃那条路也走这里**（`TabBarSystemGlass`）——
    /// 用户原话：「这个系统的液态玻璃和原本自己做的尺寸不一样 …… **你和自绘的对齐就行**」。
    /// 现在自绘那条**已经删除**（2026-10-13），所以这里就是"这条栏的胶囊该多大"的**唯一**判据：
    ///   · 宽：**贴着图标那一行**（+ 左右留边），上限是"栏宽 − sideInset×2"；
    ///   · 高：**与迷你播放条那条胶囊同一个数**（`GlassCapsule.height` = 真机实测 60）。
    ///     用户 2026-10-02 拍板：无论「隐藏标签文字」开关如何，高度都按"有文字"版式算；
    ///   · 纵向：以 `band.midY` 为心，越出栏顶/栏底都有上限（`maxOverhang`）。
    ///
    /// ⚠️ 副作用是**故意**的：顺手把宽度报给迷你播放条那条胶囊（用户要求两条等宽）。
    @MainActor
    static func capsuleRect(in bar: UIView, band: CGRect) -> CGRect {
        let width = min(
            max(16, bar.bounds.width - sideInset * 2),
            max(16, band.width + horizontalPadding * 2)
        )
        capsuleWidth = width
        capsuleWidthRatio = bar.bounds.width > 1 ? width / bar.bounds.width : 0

        let height = min(bar.bounds.height + maxOverhang, max(16, GlassCapsule.height))
        let centeredY = band.midY - height / 2
        let y = min(max(-maxOverhang, centeredY), max(0, bar.bounds.height - height))
        return CGRect(x: band.midX - width / 2, y: y, width: width, height: height)
    }

    /// 给**系统玻璃**那条路用：跑一遍同一套量算，返回"我们要对齐到的那个矩形"（**不画任何东西**）。
    ///
    /// 几何不可信（首次布局、栏还没进窗口）时返回 `nil` —— 调用方那一次按自己的兜底摆，
    /// 下一拍再来（`isUsable` 那条纪律：**宁可不动，也别摆歪**）。
    @MainActor
    static func targetCapsuleRect(in bar: UIView) -> CGRect? {
        guard bar.bounds.width > 1, bar.bounds.height > 1 else { return nil }
        let stack = findTabsStack(in: bar)
        let dx = tightenOffsets(in: bar, stack: stack)
        let measured = measure(in: bar, stack: stack, dx: dx)
        let band = measured?.full ?? measured?.icons ?? contentBand(in: bar, stack: stack)
        guard isUsable(band: band, bar: bar) else { return nil }
        return capsuleRect(in: bar, band: band)
    }

    // MARK: - 量算：四颗的布局几何（v4.6 起不再读 frame，也不 convert 到栏）

    /// 四颗的**横向收紧量**（只看布局，不看 transform —— v4.4 的教训）。
    ///
    /// ⚠️ 首次布局时 `stack.bounds.width == 0`（内容还没排），那时按它推算会得到
    /// "四颗全被推 +41"（照片 28 / 日志 24 的真凶）。所以宽度没过闸就**一律返回空**：
    /// 这一轮不收紧（量出来的就是没收紧的布局），`apply` 那边的有界重试会把我们叫回来。
    /// 形状不是"四颗"时同样不动（宁可不动，也别乱动）。
    ///
    /// ★ 2026-10-13：按 `visibleItems` 数算（**占着槽位的那几颗**）。藏掉「创建」之后它
    /// 仍然占着第 4 格 ⇒ 这里照旧按 4 算，收紧量与"创建还在"时**一模一样**
    /// （用户第二条要求："关掉创建之后玻璃宽度不变"）。
    @MainActor
    private static func tightenOffsets(in bar: UIView, stack: UIView?) -> [CGFloat] {
        guard let stack, stack.bounds.width > 100 else { return [] }
        let items = visibleItems(in: stack)
        guard items.count >= 2, items.count <= 4 else { return [] }
        let count = CGFloat(items.count)
        let centerX = bar.bounds.midX

        return (0..<items.count).map { index in
            // ★ 用**等分布局推算**中心，而不是读 `item.frame.midX`：
            //   Apple 对 `frame` 的说明是"transform 非恒等时该值未定义"，实测它会把我们
            //   上一轮写进去的位移算进去 → 每轮又按"已经被挪过的位置"再收一次 →
            //   收敛点整体偏移，**两端最明显**（第 4 颗「创建」偏得最多）。
            let localMidX = stack.bounds.width * (CGFloat(index) + 0.5) / count
            let layoutMidX = stack.convert(CGPoint(x: localMidX, y: 0), to: bar).x
            return (centerX - layoutMidX) * tightenFactor
        }
    }

    /// 一次量算的全部结果（都在**栏坐标系**里，而且**只走布局几何**）。
    ///
    /// ⚠️ 2026-10-13：`itemBands` / `itemIconBands`（每颗的纵向基准）**已随自绘胶囊删除** ——
    /// 它们只喂那套"把四颗摆到胶囊中心"的 `rowShifts` / `iconShifts`。现在只剩胶囊尺寸要的两个带子。
    private struct Measurements {
        /// 图标带（尺寸已归一化）。
        var icons: CGRect?
        /// "有文字的版式"：图标 ∪ 文字（尺寸已归一化）→ 胶囊的尺寸与位置都用它。
        var full: CGRect?
    }

    /// 量四颗的几何。
    ///
    /// ── 为什么只读布局几何（`layer.position` / `bounds`）──────────────────────
    /// `frame` / `convert(_:to: bar)` 都**包含我们上一轮写进去的 transform**，而 v4.6 起
    /// transform 里有纵向位移 —— 用它量就会"胶囊跟着一起漂"。CALayer 的 `position` 是
    /// "布局把这一颗放在哪儿"（transform 是绕 anchorPoint 施加的，不动 position），
    /// `bounds` 是布局尺寸，两个都干净。子树内部用 `node.convert(node.bounds, to: item)`
    /// —— 这一段不经过 item 自己的 transform。
    ///
    /// ── 为什么尺寸要**归一化到中位尺寸**（v4.6.1：照片 30/32 + 日志 26 的教训）──────
    /// 「创建」那颗在菜单打开时，它的 `SPTEncoreIconView` 会从 `24×24` 变成
    /// **`33×33`**（真机 tree #7 原文：`IconView@35,7,33,33`）→ 图标带从 `272x24`
    /// 变成 `277x36`、中心从 17 掉到 23 → 四颗共用的 `dy` 从 `+10.0` 缩到 `+3.8`
    /// → **另外三颗被顶高 6pt**（照片 32 一眼可见，逐像素量是 7pt；日志 26 的两条自报
    /// 就是现场：`312x60 / 272x24 / dy=+10.0` ↔ `317x60 / 277x36 / dy=+3.8`）。
    /// 现在每块矩形都**按中位尺寸重建、只保留自己的中心**：尺寸不再忽大忽小，
    /// 位置仍跟真实中心走。
    ///
    /// - Parameter dx: 每颗的横向收紧量（**要算进**带子，胶囊才贴着收紧后的那一行走）。
    @MainActor
    private static func measure(in bar: UIView, stack: UIView?, dx: [CGFloat]) -> Measurements? {
        guard let stack, !stack.subviews.isEmpty else { return nil }

        var result = Measurements()
        var iconRects: [CGRect] = []
        var labelRects: [CGRect] = []

        // ★ 2026-10-13：量**占着槽位的那几颗**（藏掉的「创建」仍然占着第 4 格 ⇒ 四颗，
        //   宽度因此不随那颗开关变 —— 见 `visibleItems` 与 `applyCreateTabVisibility`）。
        for (index, item) in visibleItems(in: stack).enumerated() {
            let size = item.bounds.size
            // ⚠️ **有一颗还没排（size 0）就整条都不量**：宁可退回老量法（`contentBand`）
            //    并等下一次布局，也不要拿"四颗里只有一颗有几何"去算胶囊 ——
            //    那会画出一条只裹着那一颗的小胶囊（v4.0 的"16pt 小棍"就是同一类事故）。
            guard size.width > 1, size.height > 1 else { return nil }

            // ① 布局原点：`layer.position` 不受 transform 影响（见上面的说明）。
            let position = item.layer.position
            let origin = CGPoint(
                x: position.x - size.width / 2 + (index < dx.count ? dx[index] : 0),
                y: position.y - size.height / 2
            )
            // ② 子树里的矩形是**相对 item** 的；加上布局原点与收紧位移，再换算到栏坐标系。
            func inBar(_ rect: CGRect) -> CGRect {
                stack.convert(rect.offsetBy(dx: origin.x, dy: origin.y), to: bar)
            }

            // ★ 这一颗**看得见的内容**以前要单独记一份（纵向基准），2026-10-13 随自绘胶囊删除。

            // ★ 图标 / 文字（只认这两类，**不受「隐藏标签文字」开关影响**）→ 胶囊的尺寸与位置。
            var iconNodes: [CGRect] = []
            var labelNodes: [CGRect] = []
            collectBandNodes(
                in: item, node: item, depth: 0,
                iconInto: &iconNodes, labelInto: &labelNodes
            )
            iconRects.append(contentsOf: iconNodes.map(inBar))
            labelRects.append(contentsOf: labelNodes.map(inBar))

            // ★ 2026-10-13（**真机日志 76** 实测）：藏掉的「创建」那一格**没有任何可量的内容**
            //   —— 它的图标不是 `EncoreIconView`（树里只有那三颗有：`15.UIImageView@35,12,24,24` ×3），
            //   于是"四格收紧后的那条带"只剩三颗的宽度 ⇒ 胶囊算成 **274**，而四颗时是 **360** ✗
            //   （用户要的就是"关掉创建之后宽度不变"）。
            //   补法：拿**它自己的槽位中心**补一个"图标大小"的矩形 —— 尺寸会被 `unionNormalized`
            //   归一化到中位数，真正起作用的是那个**中心**（加上四格那套收紧位移 `dx`）。
            if iconNodes.isEmpty, labelNodes.isEmpty {
                let synthetic = CGRect(
                    x: size.width / 2 - 12,
                    y: size.height / 2 - 12,
                    width: 24,
                    height: 24
                )
                iconRects.append(inBar(synthetic))
            }
        }

        result.icons = unionNormalized(iconRects)
        result.full = unionOf(result.icons, unionNormalized(labelRects))
        return result
    }

    /// 一棵子树里的**图标**与**文字**（相对 `root` 的矩形）。
    ///
    /// 认类名（`EncoreIconView` / `EncoreLabel`），**不做运行时类枚举** —— 那条路崩过两次。
    /// ⚠️ 这里**故意不看 `isHidden` / `alpha`**：要的就是"有文字的版式"（文字是我们自己藏的），
    /// 而「创建」那颗白色圆底那种装饰，靠"不是图标也不是文字"被排除掉。
    @MainActor
    private static func collectBandNodes(
        in root: UIView,
        node: UIView,
        depth: Int,
        iconInto: inout [CGRect],
        labelInto: inout [CGRect]
    ) {
        guard depth <= 8 else { return }

        let name = NSStringFromClass(type(of: node))
        let isIcon = name.contains("EncoreIconView")
        let isLabel = name.contains("EncoreLabel")
        if isIcon || isLabel {
            let rect = node.convert(node.bounds, to: root)
            if rect.width > 0.5, rect.height > 0.5 {
                if isIcon { iconInto.append(rect) } else { labelInto.append(rect) }
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

    /// 一组矩形的并集，**每块先按中位尺寸重建**（各自保留中心）。
    ///
    /// 见 `measure` 的说明：「创建」那颗的图标会在 24×24 ↔ 33×33 之间变，
    /// 直接用真实矩形量，胶囊与 `dy` 都会跟着跳。
    private static func unionNormalized(_ rects: [CGRect]) -> CGRect? {
        guard !rects.isEmpty else { return nil }
        let widths = rects.map { $0.width }.sorted()
        let heights = rects.map { $0.height }.sorted()
        let width = widths[widths.count / 2]
        let height = heights[heights.count / 2]
        guard width > 0.5, height > 0.5 else { return nil }

        return rects.reduce(CGRect?.none) { union, rect in
            let normalized = CGRect(
                x: rect.midX - width / 2,
                y: rect.midY - height / 2,
                width: width,
                height: height
            )
            return union.map { $0.union(normalized) } ?? normalized
        }
    }

    /// 两个可选矩形的并集。
    private static func unionOf(_ a: CGRect?, _ b: CGRect?) -> CGRect? {
        guard let a else { return b }
        guard let b else { return a }
        return a.union(b)
    }

    // MARK: - 标签文字（默认藏）

    /// 藏掉几颗标签的文字（照片 21/23/25 里那条栏**没有文字**）。**默认开**。
    ///
    /// ── 为什么这件事值得做 ────────────────────────────────────────────────────
    /// ① 观感：照片里那条栏只有图标，文字一去掉整条就"干净"了；
    /// ② 藏掉之后图标那一行更干净 —— 而胶囊的高度**不受它影响**：`measure` 永远按
    ///    **有文字的版式**量（用户 2026-10-02 拍板）。
    ///
    /// ★ 2026-10-13：它现在由**栏的布局钩子**直接调用（原来挂在自绘胶囊的 `apply` 里）——
    ///   自绘那条路删了，但"藏文字"与玻璃无关，两种开关状态下都得照常生效。
    ///
    /// ⚠️ 会不会被 Spotify 的 binder 写回来？—— 每次栏布局我们都会再走一遍，并且**计数**；
    /// 写回超过 `labelWriteBackLimit` 次就停手并打日志（宁可保持原生，也不跟它抢 —— 文档铁律）。
    ///
    /// 来自 **spoti.pw** 的「Hide labels」（`docs/tweaks.md`）；来源、许可与改动见「开源许可」页。
    private static var labelMarkKey: UInt8 = 0
    private static var labelWriteBacks = 0
    private static let labelWriteBackLimit = 12
    private static var didGiveUpLabels = false
    private static var didLogLabelState = false

    /// ⚠️ 参数是**那条栏**（不是 stack）：调用方是栏的布局钩子，它手里只有栏。
    @MainActor
    static func applyLabelVisibility(in bar: UIView) {
        guard let stack = findTabsStack(in: bar) else { return }

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
                    "[TabBarPlate] ⚠️ label text keeps being written back (\(labelWriteBacks) times) — no longer fighting it (keeping native)"
                )
            }
        }

        guard !didLogLabelState, hid > 0 || restored > 0 else { return }
        didLogLabelState = true
        writeDebugLog(
            "[TabBarPlate] label text \(shouldHide ? "hidden" : "restored") (\(shouldHide ? hid : restored) label(s))"
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

    // MARK: - ★ 「创建」那一颗（用户 2026-10-13：不要这个功能了）

    /// 我们藏「创建」时动过的两个值（按对象记：关掉开关要**精确还原**）。
    struct MutedTabState {
        var alpha: CGFloat
        var interaction: Bool
    }

    /// ⚠️ 与 `DeclutterChrome` 里那份"被我们藏过的视图"同一个教训：**每个视图记它自己的原值**，
    ///    不能一律写某个固定值（`ObjectIdentifier` 是地址、可能被复用 ⇒ 只在我们自己写入/还原时读它）。
    private static var mutedTabItemStates: [ObjectIdentifier: MutedTabState] = [:]
    private static var didReportCreateTab = false
    /// 藏过之后**又被显示回来**的次数（Spotify 的 binder 有可能这么干 —— 与标签文字那条同一个现象）。
    /// 它只是"我们是不是在和别人抢"的证据：**照样每拍再藏一次**（用户要的就是它不在），但会报一行。
    private static var createTabWriteBacks = 0
    private static var didReportCreateWriteBack = false
    /// 最近一次见到的那条栏（设置页拨开关时当场落地用；弱引用）。
    private static weak var lastTabBar: UIView?

    /// 藏掉「创建」那一颗 ⇒ **玻璃上只剩主页 / 搜索 / 音乐库三颗**。
    ///
    /// 用户原话（2026-10-13）：「有个按键在音乐库的右边，叫创建歌单。能不能不要这个功能了。
    /// 即液态玻璃只显示主页，搜索，音乐库三个按键」。
    ///
    /// ── ★ 2026-10-13（第二条要求）：**「关掉创建之后，液态玻璃的宽度不变」** ──────────
    /// 原来藏的是**整颗 arranged subview**（`isHidden = true`）：`UIStackView` 会把它的位置
    /// **让给另外三颗** ⇒ 两条宽度一起缩：
    ///   · UIKit 画的那块玻璃按 **3 颗**算 —— 日志 70/71 实测 **360×60 → 274×60**；
    ///   · 我们自己的几何（`tightenOffsets` / `measure` 都走 `visibleItems`）也跟着按 3 颗量，
    ///     而上面那条迷你播放条按 `capsuleWidthRatio` **等宽跟随** ⇒ 一起缩（用户报的就是这个）。
    ///
    /// 现在改成**保住槽位、只把那颗藏起来**：
    ///   · `alpha = 0` —— 看不见（UIKit 的命中测试本来就跳过 alpha < 0.01 的视图 ⇒ 也点不到）；
    ///   · `isUserInteractionEnabled = false` —— 显式写死，不依赖上面那条副作用。
    /// 于是第 4 个槽**仍然在**：`UIStackView` 照旧排四格、几何照旧按四颗量、系统栏照旧镜像四格
    /// （第四格无图无字、`isEnabled = false`）⇒ **两条胶囊的宽度与"创建还在"时一模一样**。
    ///
    /// ⚠️ 别再对**整条栏的每一颗**用这一招：文件头那张事故表里的"整条栏点不动"就是
    /// `alpha = 0` 按在 item 视图上、UIKit 跳过命中测试造成的。**只对要它消失的那一颗用**，
    /// 另外三颗的 `alpha` 一个字都不动。
    ///
    /// ── 判据为什么是类名 ────────────────────────────────────────────────────
    /// 真机树（日志 70）：第 4 颗是 `CreateMenu_TabBarItemImpl.CreateMenuTabBarItemView`，
    /// 另外三颗是 `NavigationUI_TabBarImpl.TabBarItemElementView`
    /// （id 依次 `TabBar.Item.主页` / `搜索` / `音乐库` / `创建`）。文字随语言变（`创建` / `Create`），
    /// 所以认类名 —— 与 pw hook 那颗用的也是同一个类名。
    ///
    /// 幂等；**每拍都跑**（Spotify 可能把它显示回来 —— 与 `applyLabelVisibility` 同一条纪律）。
    @MainActor
    static func applyCreateTabVisibility(in bar: UIView) {
        lastTabBar = bar
        guard let stack = findTabsStack(in: bar) else { return }
        let shouldHide = UserDefaults.tabBarHideCreate

        for item in stack.subviews where isCreateTab(item) {
            let identifier = ObjectIdentifier(item)
            if shouldHide {
                if mutedTabItemStates[identifier] == nil {
                    mutedTabItemStates[identifier] = MutedTabState(
                        alpha: item.alpha,
                        interaction: item.isUserInteractionEnabled
                    )
                } else if item.alpha > 0.01 {
                    createTabWriteBacks += 1          // 我们藏过，它又被显示回来了
                }
                // ★ 保住槽位：**不用 `isHidden`**（那会让 stack 把第 4 格让出去 ⇒ 玻璃变窄）。
                if item.alpha > 0.01 { item.alpha = 0 }
                if item.isUserInteractionEnabled { item.isUserInteractionEnabled = false }
                guard !didReportCreateTab else { continue }
                didReportCreateTab = true
                writeDebugLog(
                    "[TabBarPlate] hid the Create tab (\(className(item)))"
                        + " — its slot stays so the glass keeps its width,"
                        + " but that tab is invisible and cannot be tapped"
                )
            } else if let original = mutedTabItemStates[identifier] {
                // 只还原**我们自己动过的**那一颗（没记过的不碰 —— 宁可保持原生）。
                mutedTabItemStates.removeValue(forKey: identifier)
                if item.alpha != original.alpha { item.alpha = original.alpha }
                if item.isUserInteractionEnabled != original.interaction {
                    item.isUserInteractionEnabled = original.interaction
                }
                writeDebugLog("[TabBarPlate] the Create tab is back (\(className(item)))")
            }
        }

        guard createTabWriteBacks > 0, !didReportCreateWriteBack else { return }
        didReportCreateWriteBack = true
        writeDebugLog(
            "[TabBarPlate] the Create tab was shown again \(createTabWriteBacks) time(s) — hiding it again on every pass"
        )
    }

    /// 这一颗是不是**被我们"保住槽位、只藏内容"的那一颗**（「创建」）。
    /// 系统玻璃那边据此给它一个**空 item**（无图无字、点不动）——槽位照旧占着，玻璃的宽度才不变。
    /// 见 `applyCreateTabVisibility`。
    @MainActor
    static func isMutedTabItem(_ item: UIView) -> Bool {
        item.alpha < 0.01
    }

    /// 设置页拨开关时当场落地（栏不在了就等下一拍 —— 那条栏每次布局都会再走一遍）。
    @MainActor
    static func refreshCreateTabVisibility() {
        guard let bar = lastTabBar else { return }
        applyCreateTabVisibility(in: bar)
    }

    /// 这一颗是不是「创建」（按类名认，见 `applyCreateTabVisibility`）。
    @MainActor
    private static func isCreateTab(_ item: UIView) -> Bool {
        var found = false

        func walk(_ node: UIView, _ depth: Int) {
            guard !found, depth <= 6 else { return }
            let name = NSStringFromClass(type(of: node))
            if name.contains("CreateMenuTabBarItemView") || (name.contains("CreateMenu") && name.contains("TabBarItem")) {
                found = true
                return
            }
            for sub in node.subviews { walk(sub, depth + 1) }
        }

        walk(item, 0)
        return found
    }

    /// 标签栏上**占着槽位的那几颗**（`isHidden` 的不算）。
    ///
    /// ★ 2026-10-13（用户第二条要求："**关掉「创建」之后玻璃宽度不变**"）：藏「创建」的做法
    /// 从 `isHidden = true` 改成**保住槽位、只把内容藏掉**（`alpha = 0` + 点不到，见
    /// `applyCreateTabVisibility`）⇒ 它**仍然算在这里面**（四颗）：
    ///   · 我们自己的几何按四颗量（`tightenOffsets` / `measure`）；
    ///   · 系统栏也照旧镜像四格（第四格空着、点不动）。
    /// 两头都不再因为"少了一颗"而缩窄（日志 70/71 实测：四颗 `360×60` → 三颗 `274×60`）。
    ///
    /// 为什么需要它：`stack.subviews` 里可能有 Spotify 自己 `isHidden` 掉的颗
    /// ⇒ 凡是"按颗数几何 / 编号"的地方都必须走这里。
    /// 两条路共用这一处判据：系统玻璃镜像几格、几何量几颗，都以它为准。
    @MainActor
    static func visibleItems(in stack: UIView) -> [UIView] {
        stack.subviews.filter { !$0.isHidden }
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
    /// ⚠️ **v4.6 起这个只当兜底**：正常路径走 `measure`（布局几何 + 有文字的版式）。
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

    private static func className(_ view: UIView) -> String {
        NSStringFromClass(type(of: view))
    }
}

// MARK: - Hook

/// 挂在**标签栏自己**上：这条栏每布局一次，就把"这一栏该长什么样"重说一遍。
///
/// 真类名：`NavigationUI_TabBarImpl.TabBarView`
/// （IPA `_TtC23NavigationUI_TabBarImpl10TabBarView` ↔ 真机 dump
///  `#1 NavigationUI_TabBarImpl.TabBarView frame=(0,0 414x83) id=elements-tabs-view-identifier`）。
///
/// ⚠️ 只碰**这一个目标**（栏自己）：不像听歌页那版"遍历整窗 + 每帧清别人底色"，
/// 所以不会影响滚动或别处。v4.6 起**也不再往这条栏上装任何手势**（拖动已删）。
///
/// ★ 2026-10-13：自绘胶囊删掉之后，这个钩子只剩三件事，**顺序要紧**：
///   ① 藏「创建」（`applyCreateTabVisibility`）—— 后面所有"按颗数"的判断都取决于它；
///   ② 藏标签文字（`applyLabelVisibility`）—— 与玻璃无关，两种开关状态下都要生效；
///   ③ 系统玻璃（`TabBarSystemGlass.apply`）—— 它自己会来问几何判据。
class TabBarPlateHook: ClassHook<UIView> {
    typealias Group = TabBarGlassGroup
    static let targetName = "NavigationUI_TabBarImpl.TabBarView"

    func layoutSubviews() {
        orig.layoutSubviews()
        let bar = self.target
        onMainThreadSync {
            TabBarGlassPlate.applyCreateTabVisibility(in: bar)
            TabBarGlassPlate.applyLabelVisibility(in: bar)
            TabBarSystemGlass.apply(to: bar)
        }
    }
}

func activateTabBarGlass() {
    guard NSClassFromString(TabBarPlateHook.targetName) != nil else {
        writeDebugLog("[TabBarPlate] missing \(TabBarPlateHook.targetName) — not installed")
        return
    }
    TabBarGlassGroup().activate()
    writeDebugLog(
        "[TabBarPlate] installed — tab row policy (hide labels / hide Create) over"
            + " \(TabBarPlateHook.targetName); the glass itself comes from TabBarSystemGlass"
            + " (the self-drawn capsule was removed on 2026-10-13)"
    )
}
