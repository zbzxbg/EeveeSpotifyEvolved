import Foundation
import Orion
import UIKit
import ObjectiveC.runtime

/// 标签栏：**把 Spotify 那条栏的内容藏起来，在它上面叠一条系统 `UITabBar`** ——
/// iOS 26 会把它画成**真·液态玻璃**（选中气泡、折射、明暗自适应），**一行玻璃 API 都不用我们写**。
///
/// ## 做法照 pw（`Redesigned/Navbar/TabBar.x`，GPL-3.0；**思路复用、代码自己写**）四步
///
///   ① Spotify 的栏**留着**（frame / 交互 / inset 都不碰），但它的**内容不可见**；
///   ② 叠一条**系统栏**，item 从 Spotify 那几颗同步（顺序跟着；标题与图标同源 ⇒ 开关跟着）；
///   ③ **选中态**：系统栏的选中项跟着"Spotify 把哪一颗标成选中"走 —— 气泡因此会**滑过去/形变**；
///   ④ **让高度**：系统栏比 Spotify 的栏高时，把差额写进 `TabBarImpl` 的
///      `additionalSafeAreaInsets.bottom` ⇒ Spotify 自己把栏 / 迷你播放器 / 页面**一起让开**。
///
/// ## ★ 2026-10-12 第一次真机（日志 63 + 照片 82）——三处已修
///
/// | 现场 | 根因 | 现在的做法 |
/// |---|---|---|
/// | **整条栏点不动**（"划不动"） | 我把**整颗 item 视图**按成 `alpha = 0`，而 UIKit 命中测试**跳过 alpha < 0.01 的视图** ⇒ 点击再也落不到 Spotify 那几颗上 | 只藏**图标与文字**这两个子视图，**item 视图本身的 alpha 一个字不动** ⇒ 看不见但照样收触摸 |
/// | **图标不见了** | 系统栏的 item 只拿到标题（`glyphImage` 没找到），而原图标又被藏了 ⇒ 那行只剩文字 | 先同步、后隐藏：**拿不到图标的那一颗，原图标就不藏**（安全网：绝不留下空行）；并把每颗的 `icon=Y/N` 打进日志 |
/// | 「隐藏标签栏文字」**不生效** | 文字是**系统栏**画的，而我没读那颗开关 | `tabBarHideLabels` 开着时**不给系统栏标题**（原文字本来就被我们藏了） |
///
/// ## ★★ 2026-10-12 第二片（用户第二轮反馈，两件事一起做）
///
/// **① 尺寸与自绘的对齐。** 用户原话：「这个系统的液态玻璃和原本自己做的尺寸不一样……
/// **你和自绘的对齐就行**」。做法：给系统栏加一个**宿主视图**（下面那个 class），
/// 把宿主摆成 `TabBarGlassPlate.targetCapsuleRect(in:)` 算出来的**那一块**（360×60、
/// 贴图标行、左右各 24pt）—— 几何判据只有那一份，两条路不可能再漂。
/// ⚠️ 宿主**必须**把底部安全区报成 0：UIKit 的浮岛玻璃是"按所在视图的安全区"量高度的
/// （Face ID 机型 `max(83, 49 + inset)`），不这么做的话它会留 34pt 给 Home Indicator，
/// 内容区只剩 26pt。这是 pw 的 `SGRTabBarHost` 那一招。
/// **我们给的框 ≠ 玻璃画出来的框**（UIKit 自己还有内边距）⇒ 每次布局把
/// **宿主框 / 系统栏框 / 玻璃自己那几块（platter / liquid lens / selection）的框**
/// 打进同一行日志（`glass geometry — …`），下一份日志就能算出常量差、一次收敛。
///
/// **② 触摸交给系统栏（"果冻"与"可划动"的前提）。** 用户原话：「液态玻璃不是胶囊套胶囊吗，
/// 里面那个胶囊**不可用手划动**」。第一片里系统栏 `isUserInteractionEnabled = false`
/// ⇒ 手指落到 Spotify 那条栏上，玻璃只是张画。现在：
///   · 系统栏**接管触摸**（`isUserInteractionEnabled = true` + `delegate` 中继）；
///   · 选中的那一颗**转发成对 Spotify 那一颗的点击** —— 五条路，**从最公开到最私有**：
///     ① **`UITabBarController.selectedIndex`**（容器是 `UITabBarController` 的子类，公开 API）
///     ② 那颗 item 子树里 **tap 手势识别器自己的 target/action**（pw 的做法）
///     ③ `-handleTap`（pw 点名的 `TabBarItemElementUI`；只找"响应它的对象"，不猜签名）
///     ④ `accessibilityActivate()`　⑤ `UIControl.sendActions`
///   · **五条全不通 ⇒ 把触摸还给 Spotify 那条栏**（`handTouchesBack`）：只有第一次点击失效，
///     之后点得动，只是没有"按下回弹" —— 绝不留下"看得见、点不动"。
///   · 用了哪条路**打进日志**；全不通时把子树里的识别器与 UIControl 全列出来。
///   · 转发完成后 0.25s 再 `reapply()` 一次：Spotify 会晚一点重画标签颜色（选中态信号）。
///   · 宿主只有那一块 ⇒ **玻璃以外的区域照旧落到 Spotify 的栏上**，行为不变。
///
/// ⚠️ **2026-10-12 真机日志 64 + 用户第三轮反馈的三条教训**（都已改进代码，别回退）：
///   1. 旧的三条转发路**一条都没通**（`⚠️ tap on #N found nothing to forward to`）⇒ 点标签栏没反应；
///   2. 玻璃比我们给的框**小一圈** ⇒ `place` 按实测差自校准（见那里的注释）；
///   3. **"只能动一次 + 没有实际的按键效果"**：上一版是"先接管触摸、转发失败再把触摸还回去"，
///      于是**第一下点空**；而且"还回去"时**漏了宿主** —— 宿主自己开着交互又盖在胶囊那块上，
///      触摸被它吃掉 ⇒ 页面既不切、也没有回弹。现在改成：
///        · **建栏时先问"有没有可用的转发路"**（当时叫 `canForwardTaps`，**第四片已换成**
///          `probeForwardRoute`：能把链读出来才算有）——有才接管触摸，没有就从头让触摸穿透
///          （与第一片一致：点得动，只是没有回弹）；
///        · 运行时万一仍然全不通，`handTouchesBack` **栏与宿主一起关**，并且**交还过就不再收回**
///          （避免"点一下空一下"）。
///   4. **"玻璃大小一直变"**：`place` 的内边距**量一次就冻结**，而且只认**栏自己那块**
///      `UITabBarPlatterView`（不能按面积挑 —— `_UITabBarItemPlatterView` 是选中气泡，尺寸随选中态变）。
///
/// ## ★★ 第四片（2026-10-12 深夜；照片 86/87 + 日志 **70**）—— 用户第四轮反馈，两条一起改
///
/// 用户原话：「**标题栏液态玻璃不跟手**，在划动过程中，**可能有胶囊回弹 / 替用户按按键**的情况，
/// 而且**胶囊也没有反射**。你可以去看一下 spoti.pw 看一下他们的标题栏液态玻璃是怎么做的」
/// （= 底部那条玻璃栏；pw 那边整块功能就叫 `Navbar`，机制在 `Redesigned/Navbar/TabBar.x`）。
///
/// **日志 70 第一行就是全部答案**（它和同一秒后面那行 `installed — … taking touches` **自相矛盾**）：
///
/// ```
/// [TabBarSystem] system bar added 0,0,414,83 on NavigationUI_TabBarImpl.TabBarView
///     — in a host that reports no bottom safe area;
///       leaving the touches to Spotify's own bar (no forwarding route found, so tapping behaves exactly as before)
/// ```
///
/// ⇒ 前几版的 `canForwardTaps` **只认第 ① 条公开路**（容器是 `UITabBarController`），
///    而真机上容器是 `TabBarContainerImpl`、`children: 1`（日志 67）⇒ 判定**永远是 false**
///    ⇒ **系统栏一次都没接过触摸**。于是三件事同时成立，正好就是用户报的三件：
///
/// | 用户看到 | 机制（代码实证） |
/// |---|---|
/// | **不跟手 / 胶囊没有反射** | 手指落在 **Spotify 那条栏**上（系统栏 `isUserInteractionEnabled = false`）⇒ UIKit 的玻璃永远收不到 `touchesBegan`，它只是一张**画**（`_UILiquidLensView` 在树上、但没有任何交互态） |
/// | **替用户按按键** | 第三片装的那只 `UIPanGestureRecognizer`（`cancelsTouchesInView = true`）"滑过哪格切哪格"，每次 `.changed` 都 `commitSelection` ⇒ 用户只是划一下，页面被**我们**换掉了 |
/// | **胶囊回弹** | 同上；提交路没学到时 `dragCrossed` 会把气泡**拨回真实那一颗**（日志 70：`⚠️ the drag could not switch the page yet`） |
///
/// **两条改法（照 pw 的机制，代码自己写）：**
///
/// 1. **转发路"读得出来"才接管触摸**（`probeForwardRoute`）。pw 那条路本来就可以**在点之前读出来**：
///    item 子树里那颗 `UITapGestureRecognizer` 的 `_targets` 里有一对**目标真的响应**的 target/action
///    （`TabBarItemElementUI` 的 `-handleTap`）。读得到 ⇒ `isUserInteractionEnabled = true`
///    ⇒ 玻璃接得住手指（"跟手"与折射就是从这里来的）；读不到 ⇒ 照旧让触摸穿透，
///    并把那条链**逐环**写进日志（`chainDescription`：`_targets` 在不在 / 有几对 / 每对解出来什么）。
///    ⚠️ 这一版**不再**"先接管、失败再还回去"（那会白丢第一下，见第三片的教训）。
/// 2. **删掉那只 pan**（"按住划"）及其整套机械（`dragCrossed` / `commitSelection` /
///    `refreshCommitRoute` / `learnSelection` / `TabBarContainerSelectionHook`）。
///    pw 那条栏上**一只手势都没有**（只有"长按主页进设置"，`TabBar.x:228-239`）——
///    "能划动/果冻"是**系统玻璃自己**的交互，不是我们模拟出来的。
///
/// 顺带修掉一处**自相矛盾的日志**：`installed — …` 原来写死 `taking touches…`（见 `logLayoutOnce`）。
///
/// 顺带记两条**实测**（都写进日志了，别再猜）：
///   · `accessibilityTraits` 在 Spotify 9.1.88 上**没有** `.selected` 标记（`traits=0x0`）
///     ⇒ 选中态**实际靠"谁的文字是白色那颗"**：`主页` 的 label 是 `#FFFFFF`、其余 `#B3B3B3`；
///   · 这台机器上 `made room` 那一行**没出现**是**对的**：`83 - 49 - 34 = 0`，本来就不需要让
///     （pw 的注释也这么说：Face ID 机型两条栏本来就对得上）。
///
/// ## 开关
///
/// 设置 → 扩展功能 → 标签栏 → 「**标签栏改用系统玻璃**」，**默认关**。
/// 关掉 = 系统栏与宿主移除 + 被藏的内容**各自恢复原 alpha** + `additionalSafeAreaInsets` **写回原值**。
/// 日志 tag：`[TabBarSystem]`。
///
/// ⚠️ **整个 enum 标 `@MainActor`**（与 `NowPlayingControlsPlate` 同一个写法）：
///    它要调 `TabBarGlassPlate.findTabsStack(in:)`，而那个函数是 `@MainActor` 的
///    ⇒ 我们不在主 actor 上就会被 Swift 6 并发检查直接判错（CI 2026-10-12 就是这么红的）。
///    两个调用点本来就都在主 actor 上：
///      · `TabBarPlateHook.layoutSubviews` 里那句 —— 包在 `onMainThreadSync` 里，
///        而它的闭包类型就是 `@escaping @MainActor () -> Void`（`LyricsChromeVisibility.swift:25`）；
///      · 设置页 `persist:` 闭包 —— 与既有那些 `NowPlayingControlsPlate.reapply()` 同一个上下文。
@MainActor
enum TabBarSystemGlass {

    static let logTag = "TabBarSystem"

    /// Spotify 自己那一行的高度（真机树里 `UIStackView(0,0 414x49)`）。
    private static let stockRowHeight: CGFloat = 49
    /// `TabBarContainerImpl` 的类名（pw 也是按名字找它：它是 Spotify 那条栏的容器 VC）。
    private static let containerClassName = "_TtC23NavigationUI_TabBarImpl19TabBarContainerImpl"

    static var isEnabled: Bool { UserDefaults.tabBarSystemGlass }

    // MARK: - 状态（全部挂在**别人的对象**上：关联对象 / 弱注册表）

    private static var systemBarKey: UInt8 = 0
    private static var hostKey: UInt8 = 0
    private static var relayKey: UInt8 = 0
    private static var roomKey: UInt8 = 0

    /// 被我们按成透明的**内容**视图（图标 / 文字；**弱引用**）+ 各自的原 alpha。
    ///
    /// ⚠️ 两条纪律：
    ///   · **只藏内容，不藏 item 视图本身** —— 藏了它，触摸就再也到不了 Spotify 那几颗
    ///     （日志 63 的"整条栏点不动"就是这个）；
    ///   · 每个视图记**它自己的**原 alpha，不能一律写 1（仓库在封面那条路上踩过"统一写回 = 永久错"）。
    private static let hiddenContent = NSHashTable<UIView>.weakObjects()
    private static var hiddenContentAlphas: [ObjectIdentifier: CGFloat] = [:]

    /// 系统栏量出来的高度**只量一次**：让出高度之后 `sizeThatFits` 会要得更多（pw 的注释点了这件事）。
    private static var measuredGlassHeight: CGFloat = 0

    /// UIKit 自己留的那圈内边距（**玻璃 = 宿主 − 它**）：**量一次就冻结**，见 `place`。
    private static var glassInsets: UIEdgeInsets?
    private static weak var measuredInsetsBar: UIView?
    /// 我们是否已经把触摸交还给 Spotify（交还过就**不再收回**，避免"点一下空一下"）。
    private static var handedBackTouches = false
    /// 从"图标视图"快照出来的图标（按视图缓存：每拍生成新图会让 `syncItems` 永远判成"形状变了"）。
    private static var iconSnapshots: [ObjectIdentifier: UIImage] = [:]
    /// 我们装在 **Spotify 自己那条栏**上的那只"点一下"手势（**不抢触摸**，只让气泡立刻对过去）。
    ///
    /// ⚠️ 2026-10-12 第四片：这里本来还有**第二只** `UIPanGestureRecognizer`（"按住划 = 滑过哪格切哪格"），
    /// **已删除** —— 见文件头"第四片"：它 `cancelsTouchesInView = true`（吃掉系统玻璃要的那次触摸）、
    /// 而且会**替用户换页**、切不动时还把气泡拨回原位。用户原话：
    /// 「**不跟手**……**可能有胶囊回弹 / 替用户按按键**的情况」。pw 那条栏上**一只手势都没有**
    /// （除了"长按主页进设置"），"跟手"是系统玻璃自己接住手指之后才有的东西。
    private static var stockTapKey: UInt8 = 0
    private static var mirroredSelections = 0
    /// 上一次"探转发路"的时刻（`ProcessInfo.systemUptime`）—— 节流用，见 `probeForwardRouteThrottled`。
    private static var lastProbeAt: TimeInterval = 0
    /// 手势诊断（各只报一次）：见 `reportTapWithoutIndex` / `noteFirstTapSeen`。
    private static var didReportTapWithoutIndex = false
    private static var didNoteFirstTap = false

    private static var lastBar: UIView?
    private static var lastSkipReason = ""
    private static var lastSelectionIndex = -1
    private static var lastSelectionSignal = ""
    private static var didLogLayout = false

    /// 上一次打出去的"玻璃几何"那一行（只在变了的时候打，别刷屏）。
    private static var lastGeometryLine = ""
    /// 转发成功的次数：**只报前几次**（证明这条路通就够了，别把日志刷满）。
    private static var forwardedTaps = 0

    // MARK: - 对外入口

    /// 幂等。由 `TabBarPlateHook.layoutSubviews`（栏自己每次布局）与复查节拍调用。
    static func apply(to bar: UIView) {
        lastBar = bar

        guard isEnabled else {
            remove(reason: "switch off", in: bar)
            return
        }
        guard bar.bounds.width > 1, bar.bounds.height > 1 else { return }
        guard let stack = TabBarGlassPlate.findTabsStack(in: bar) else {
            noteSkipOnce("no tabs stack yet")
            return
        }

        let items = stack.subviews
        guard !items.isEmpty else { return }

        // ② 先同步系统栏 —— **顺序要紧**：下面"藏什么"取决于"镜像到了什么"
        //   （拿不到图标的那一颗，原图标要留着当安全网）。
        let systemBar = ensureBar(in: bar)
        let mirrored = syncItems(on: systemBar, from: items)

        // ① 藏内容（**不是整颗 item**）：只藏那些已经镜像过去的图标，以及文字。
        hideStockContent(items: items, mirroredIcons: mirrored.icons)

        // ③ 选中态：气泡跟着 Spotify 走。
        syncSelection(on: systemBar, items: items)

        // ★ 第三片留下的那半：把"点一下"装到 **Spotify 自己那条栏**上（不抢它的触摸，只让气泡立刻对过去）。
        //   ⚠️ 第四片删掉了它的兄弟（"按住划"）—— 见文件头。
        installStockGestures(on: bar)

        // ★★ 第四片：**系统栏该不该接管触摸**？—— 判据改成"能不能在**点之前**把转发路读出来"
        //   （见 `probeForwardRoute`）。能读出来 ⇒ 玻璃才接得住手指（"跟手"与折射就是从这里来的）；
        //   读不出来 ⇒ 照旧把触摸留给 Spotify 那条栏，并把那条链**逐环**写进日志。
        //   ⚠️ **一旦交还过触摸就不再收回**（否则会"点一下空一下"地来回抖）。
        if !handedBackTouches, !systemBar.isUserInteractionEnabled,
           let route = probeForwardRouteThrottled(in: bar) {
            systemBar.isUserInteractionEnabled = true
            hostView(for: bar)?.isUserInteractionEnabled = true
            writeDebugLog(
                "[\(logTag)] a forward route showed up — \(describe(route));"
                    + " the system bar takes the touches now (the glass answers the finger, taps are forwarded)"
            )
        }

        // ★ 摆位（第二片）：把宿主/系统栏摆成"自绘胶囊那一块"。
        place(systemBar, in: bar)

        // ④ 让高度（放在最后：量高度要用**还没让过高度**的那次结果）。
        makeRoom(for: bar, systemBar: systemBar)

        // ★ 把"我们给的框"与"UIKit 真画出来的玻璃"放进同一行（用户要求两条胶囊对齐，
        //   而只有实测数字能收敛 —— 见文件头第二片 ①）。
        reportGlassGeometry(systemBar, in: bar)

        logLayoutOnce(bar: bar, items: items, systemBar: systemBar, mirrored: mirrored)
    }

    /// 设置页切开关 / 复查节拍用：手里那次记下的栏还在窗口里就当场重来一次。
    static func reapply() {
        guard let bar = lastBar, bar.window != nil else { return }
        apply(to: bar)
    }

    /// 拿走（关开关 / 页面走了）。**精确还原三件事**：系统栏与宿主、内容 alpha、`additionalSafeAreaInsets`。
    static func remove(reason: String, in bar: UIView? = nil) {
        let target = bar ?? lastBar
        if let target {
            if let systemBar = objc_getAssociatedObject(target, &systemBarKey) as? UITabBar {
                systemBar.delegate = nil
                systemBar.removeFromSuperview()
                objc_setAssociatedObject(target, &systemBarKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
                writeDebugLog("[\(logTag)] system bar removed (reason=\(reason))")
            }
            if let host = objc_getAssociatedObject(target, &hostKey) as? UIView {
                host.removeFromSuperview()
                objc_setAssociatedObject(target, &hostKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            }
            objc_setAssociatedObject(target, &relayKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            // ★ 装在 Spotify 那条栏上的那只"点一下"手势也要摘掉 —— 不然关掉开关之后它还挂着。
            if let tap = objc_getAssociatedObject(target, &stockTapKey) as? UIGestureRecognizer {
                target.removeGestureRecognizer(tap)
                objc_setAssociatedObject(target, &stockTapKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            }
            restoreRoom(in: target)
        }
        restoreStockContent()
        measuredGlassHeight = 0
        glassInsets = nil
        measuredInsetsBar = nil
        handedBackTouches = false
        iconSnapshots.removeAll()
        mirroredSelections = 0
        lastProbeAt = 0
        didReportTapWithoutIndex = false
        didNoteFirstTap = false
        didLogLayout = false
        lastSelectionIndex = -1
        lastSelectionSignal = ""
        lastGeometryLine = ""
        forwardedTaps = 0
    }

    // MARK: - ① 藏 Spotify 自己的内容（**不藏 item 本身**）

    /// 藏**图标与文字**：图标只藏"已经镜像到系统栏"的那些（安全网），文字一律藏
    /// （文字要么由系统栏画标题，要么本来就该没有 —— 见 `tabBarHideLabels`）。
    ///
    /// ★★ 2026-10-12（真机日志 67 + 用户："**底部 spotify 自带的那一层按钮还在**"）：
    /// 上一版这里只藏 `glyphViews`（= `UIImageView`），而**这一版的图标是 `SPTEncoreIconView`**
    /// （日志 67：`icon taken from SPTEncoreIconView at 0,0,24,24`）⇒ 一颗都没藏住，
    /// 我们镜像出来的图标和原图标**叠在一起**。
    /// ⇒ **镜像到了什么就藏什么**：`findIconView`（我们取快照的那颗）与 `glyphViews` 一起藏。
    private static func hideStockContent(items: [UIView], mirroredIcons: [Bool]) {
        for (index, item) in items.enumerated() {
            if index < mirroredIcons.count, mirroredIcons[index] {
                var glyphs: [UIView] = glyphViews(in: item)
                if let iconView = findIconView(in: item) { glyphs.append(iconView) }
                for glyph in glyphs { hide(glyph) }
            }
            for label in labelViews(in: item) { hide(label) }
        }
    }

    private static func hide(_ view: UIView) {
        guard view.alpha != 0 else { return }
        if hiddenContentAlphas[ObjectIdentifier(view)] == nil {
            hiddenContentAlphas[ObjectIdentifier(view)] = view.alpha
            hiddenContent.add(view)
        }
        view.alpha = 0
    }

    /// 还原成**每一个自己的**原 alpha（没记过的不碰）。
    private static func restoreStockContent() {
        for view in hiddenContent.allObjects {
            if let original = hiddenContentAlphas[ObjectIdentifier(view)] {
                view.alpha = original
            }
        }
        hiddenContent.removeAllObjects()
        hiddenContentAlphas.removeAll()
    }

    // MARK: - ② 系统栏、它的宿主与它的 item

    private struct Mirror {
        var icons: [Bool]
        var titles: [String?]
    }

    private static func ensureBar(in bar: UIView) -> UITabBar {
        if let existing = objc_getAssociatedObject(bar, &systemBarKey) as? TabBarSystemGlassBar {
            if existing.superview !== hostView(for: bar) { hostView(for: bar)?.addSubview(existing) }
            return existing
        }

        // ★ 宿主：**只负责把底部安全区让掉**（见 `TabBarSystemGlassHost` 的说明）。
        //   pw 也是这么做的（`SGRTabBarHost`）：UIKit 按"所在视图的安全区"量玻璃条的高度。
        let host = TabBarSystemGlassHost()
        host.backgroundColor = .clear
        host.accessibilityIdentifier = "eevee-tabbar-system-glass-host"

        // ★★ 2026-10-12 第四版：**"要不要接管触摸" = "能不能在点之前把转发路读出来"**
        //    （见 `probeForwardRoute`）。用户第四轮原话：
        //    「**标题栏液态玻璃不跟手**……**可能有胶囊回弹 / 替用户按按键**……**而且胶囊也没有反射**」。
        //    日志 70 的第一行就是答案：`leaving the touches to Spotify's own bar (no forwarding route found…)`
        //    ⇒ 前几版只认第 ① 条公开路（容器是 `UITabBarController`），而真机上容器**不是**
        //    ⇒ 判定永远 false ⇒ **系统栏从来没接过一次触摸** ⇒ 玻璃只是一张画
        //    （没有按下回弹、没有折射响应，也没有 UIKit 自己的跟手），而手指全落在 Spotify 那条栏上、
        //    由第三片装的两只手势代劳 ⇒ 那三条症状一个不少。
        //    pw 的做法正相反：**触摸全给系统栏**（`TabBar.x:360-364` 把 Spotify 那几个子视图
        //    `alpha = 0` + `userInteractionEnabled = NO`），点击在 `didSelectItem` 里转发。
        let route = probeForwardRoute(in: bar)
        let takesTouches = route != nil
        host.isUserInteractionEnabled = takesTouches

        let systemBar = TabBarSystemGlassBar(frame: host.bounds)
        systemBar.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        // UIKit 按"这条栏继承到的外观"画玻璃，而这条栏在 Spotify 自己的深色导航栈之外
        // ⇒ 浅色模式的手机上会出现"亮玻璃压在纯黑上"。Spotify 永远是深色，这条栏也是。
        systemBar.overrideUserInterfaceStyle = .dark
        systemBar.accessibilityIdentifier = "eevee-tabbar-system-glass"
        systemBar.isUserInteractionEnabled = takesTouches
        // 自己的背景不要画：我们要的是系统玻璃本身。
        systemBar.backgroundImage = UIImage()
        systemBar.shadowImage = UIImage()
        systemBar.isTranslucent = true

        let relay = TabBarSystemGlassRelay()
        systemBar.delegate = relay
        objc_setAssociatedObject(bar, &relayKey, relay, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        host.addSubview(systemBar)
        bar.addSubview(host)
        bar.bringSubviewToFront(host)
        objc_setAssociatedObject(bar, &systemBarKey, systemBar, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        objc_setAssociatedObject(bar, &hostKey, host, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        writeDebugLog(
            "[\(logTag)] system bar added \(frameText(bar.bounds)) on \(NSStringFromClass(type(of: bar)))"
                + " — in a host that reports no bottom safe area"
                + "; forward route probe: \(describe(route))"
                + (takesTouches
                    ? "; the system bar takes the touches (that is what makes the glass answer a finger)"
                    : "; leaving the touches to Spotify's own bar (nothing readable to forward a tap to,"
                        + " so tapping behaves exactly as before) — chain: \(chainDescription(in: bar))")
        )
        return systemBar
    }

    // MARK: - ★★ 第四片：转发路**读得出来**才接管触摸

    /// "点了某颗之后谁来接"——**在建栏时就能读出来的那几条路**。
    ///
    /// 为什么必须"读得出来"才算数：系统栏一旦接管触摸，Spotify 那几颗就再也收不到点击
    /// ⇒ 转发要是落空，标签栏立刻变成"看得见、点不动"（仓库红线）。所以判据从
    /// "先接管、失败了再还回去"（会白丢第一下）改成"**先证明有人接**"。
    private enum ForwardRoute {
        /// ① 公开 API：容器是 `UITabBarController`，`selectedIndex` 就能换页。
        case container(controllers: Int)
        /// ② pw 那条路：item 子树里那颗 tap 识别器的 `_targets` 里有一对**目标真的响应**的
        ///    target/action（`TabBarItemElementUI` 的 `-handleTap` 就是它）。
        case tapRecognizer(index: Int, target: String, action: String)
        /// ③ 子树里（响应链或 ivar 上）有对象响应 `-handleTap`。
        case handleTap(index: Int, holder: String)
        /// ⑤ 子树里有 `UIControl`（`sendActions` 能点）。
        case control(index: Int, name: String)
    }

    /// 一行说清"是**哪条**路、在哪一颗上"。日志里必须带这个，否则"接管了又点不动"没法复盘。
    private static func describe(_ route: ForwardRoute?) -> String {
        guard let route = route else { return "none — no route can be read before a tap" }
        switch route {
        case .container(let controllers):
            return "route ① (public) the container is a UITabBarController with \(controllers) view controllers"
        case .tapRecognizer(let index, let target, let action):
            return "route ② (pw's) the tap recogniser on #\(index) fires \(target):\(action)"
        case .handleTap(let index, let holder):
            return "route ③ handleTap answers on #\(index) (found on \(holder))"
        case .control(let index, let name):
            return "route ⑤ a UIControl on #\(index) (\(name)) answers sendActions"
        }
    }

    /// 一条都读不出来时，把**那条链逐环**写出来（`_targets` 在不在 / 有几对 / 每对解出来什么）。
    /// 这正是 pw 依赖的那一环，也是"为什么 pw 的写法在我们这版不通"的唯一判据。
    private static func chainDescription(in bar: UIView) -> String {
        guard let stack = TabBarGlassPlate.findTabsStack(in: bar) else { return "no tabs stack yet" }
        return stack.subviews.enumerated().map { index, item -> String in
            let name = shortName(NSStringFromClass(type(of: item)))
            let pieces = subtree(of: item, maxDepth: 6).flatMap { view -> [String] in
                (view.gestureRecognizers ?? []).map { recognizer in
                    "\(describe(recognizer)) on \(shortName(NSStringFromClass(type(of: view))))"
                }
            }
            return "#\(index) \(name)[\(pieces.isEmpty ? "no recognisers at all" : pieces.joined(separator: " | "))]"
        }.joined(separator: "; ")
    }

    /// 探一次：**能读出来的**第一条路（顺序与 `forwardTap` 一致，从最公开到最私有）。
    ///
    /// ⚠️ 只探"点得动"这件事；`accessibilityActivate()` 那条**探不出来**（要真调一次才知道），
    ///    所以它只能留在 `forwardTap` 的兜底里，不能当接管触摸的判据。
    private static func probeForwardRoute(in bar: UIView) -> ForwardRoute? {
        if let container = container(of: bar), let tabs = container as? UITabBarController,
           let controllers = tabs.viewControllers, controllers.count >= 2 {
            return .container(controllers: controllers.count)
        }
        guard let stack = TabBarGlassPlate.findTabsStack(in: bar) else { return nil }
        for (index, item) in stack.subviews.enumerated() {
            if let recognizer = firstFireableTapRecognizer(in: item, index: index) { return recognizer }
        }
        for (index, item) in stack.subviews.enumerated() {
            if let holder = handleTapHolder(in: item) {
                return .handleTap(index: index, holder: holder.via)
            }
        }
        for (index, item) in stack.subviews.enumerated() {
            if let control = subtree(of: item, maxDepth: 6).first(where: { $0 is UIControl }) {
                return .control(index: index, name: shortName(NSStringFromClass(type(of: control))))
            }
        }
        return nil
    }

    /// 子树里第一颗"**真的点得动**"的 tap 识别器：`_targets` 里至少有一对 target/action 能解出来，
    /// 且那个 target **响应**那个 action。读不出来就返回 nil（= 这条路不能算数）。
    private static func firstFireableTapRecognizer(in item: UIView, index: Int) -> ForwardRoute? {
        for view in subtree(of: item, maxDepth: 6) {
            for recognizer in view.gestureRecognizers ?? [] {
                guard recognizer is UITapGestureRecognizer, recognizer.isEnabled else { continue }
                for pair in pairs(of: recognizer) {
                    guard let target = target(of: pair), let action = action(of: pair),
                          target.responds(to: action) else { continue }
                    return .tapRecognizer(
                        index: index,
                        target: shortName(NSStringFromClass(type(of: target))),
                        action: NSStringFromSelector(action)
                    )
                }
            }
        }
        return nil
    }

    /// 探一次要**走一遍四颗的子树**，而 `apply` 每次布局 + 每 0.5s 复查都会进来
    /// ⇒ 只在"系统栏还没接管触摸"这一档里探，并且**最多 1s 一次**（第一次立刻探）。
    /// 一旦接管了触摸就不再探（`apply` 那条 `if` 直接短路）。
    private static func probeForwardRouteThrottled(in bar: UIView) -> ForwardRoute? {
        let now = ProcessInfo.processInfo.systemUptime
        guard lastProbeAt == 0 || now - lastProbeAt >= 1 else { return nil }
        lastProbeAt = now
        return probeForwardRoute(in: bar)
    }

    private static func hostView(for bar: UIView) -> TabBarSystemGlassHost? {
        objc_getAssociatedObject(bar, &hostKey) as? TabBarSystemGlassHost
    }

    /// ★ 第二片 ①：**把宿主摆成"自绘胶囊那一块"**（几何判据只有 `TabBarGlassPlate` 那一份）。
    ///
    /// ★★ 2026-10-12 第二版（**真机日志 64 纠正**）：**UIKit 画的玻璃比我们给的框小一圈** ——
    /// 日志逐字：`host 27,-3,360,60` → 它画出来的 `_UITabBarItemPlatterView` 是 `48,-3,318,39`
    /// ⇒ 它自己留了 **左右各 21、底 21**（顶 0）。所以：
    ///   ① 我们给的框 ≠ 屏幕上的玻璃（用户原话："这做的也太矮了吧，**高度长度都不对**"）；
    ///   ② 修法**不写死 21**，而是按**实测差**把宿主往外扩 —— 关系是"玻璃 = 宿主 − 常量"
    ///      ⇒ 一次收敛、幂等；
    ///   ③ 拿不到可信几何（首次布局 / 栏还没进窗口 / 玻璃还没排完）时退回"整条栏"，下一拍再对齐 ——
    ///      绝不因为量不到就把玻璃藏起来（那是"看得见、点不动"那条红线的近亲）。
    ///
    /// ★★ 2026-10-12 第三版（用户报："**这个玻璃的大小会一直变**"）：内边距**量一次就冻结**
    /// （`glassInsets`），而且只认**栏自己那块 platter**（见 `drawnGlassFrame`）。
    /// 上一版每一拍都重量 ⇒ 量到的地方一变（选中动画期间那几块 platter 的尺寸会动）宿主就跟着变
    /// ⇒ 玻璃肉眼可见地忽大忽小。冻结之后：**量一次 → 之后每拍只按它摆位**，稳。
    private static func place(_ systemBar: UITabBar, in bar: UIView) {
        guard let host = hostView(for: bar) else { return }
        let target = TabBarGlassPlate.targetCapsuleRect(in: bar) ?? bar.bounds

        // 换了栏（页面重建）就重新量一次。
        if measuredInsetsBar !== bar {
            measuredInsetsBar = bar
            glassInsets = nil
        }
        if glassInsets == nil, let drawn = drawnGlassFrame(in: systemBar, in: bar) {
            let insets = UIEdgeInsets(
                top: drawn.minY - host.frame.minY,
                left: drawn.minX - host.frame.minX,
                bottom: host.frame.maxY - drawn.maxY,
                right: host.frame.maxX - drawn.maxX
            )
            glassInsets = insets
            writeDebugLog(
                "[\(logTag)] glass insets measured once — left \(Int(insets.left)) right \(Int(insets.right))"
                    + " top \(Int(insets.top)) bottom \(Int(insets.bottom))"
                    + " (UIKit keeps them to itself; the host is expanded by them so the glass lands on our capsule;"
                    + " measured once on purpose, so the glass cannot drift)"
            )
        }
        let insets = glassInsets ?? .zero
        let frame = CGRect(
            x: target.minX - insets.left,
            y: target.minY - insets.top,
            width: target.width + insets.left + insets.right,
            height: target.height + insets.top + insets.bottom
        )
        if !host.frame.equalTo(frame) { host.frame = frame }
        if !systemBar.frame.equalTo(host.bounds) { systemBar.frame = host.bounds }
    }

    /// UIKit 自己画的那块玻璃 —— **只认 `UITabBarPlatterView` 那条线**（栏自己的 platter）。
    ///
    /// ⚠️ 不能按"面积最大"挑：同一族里还有 `_UITabBarItemPlatterView`（**选中那颗的气泡**，
    /// 日志 64 的 `drawn` 列表里两者同名不同命）与 `_UILiquidLensView`（选中透镜）——
    /// 它们的尺寸**随选中态变**，按面积挑会在点标签时挑到它们 ⇒ 宿主跟着变 ⇒ 玻璃忽大忽小。
    /// 另外要求宽度至少是栏宽的四成（排到一半的 0×0 一律不要）。
    private static func drawnGlassFrame(in systemBar: UITabBar, in bar: UIView) -> CGRect? {
        let widest = max(bar.bounds.width, 1)
        return platterViews(in: systemBar)
            .filter { shortName(NSStringFromClass(type(of: $0.1))).contains("UITabBarPlatterView") }
            .map { $0.1.convert($0.1.bounds, to: bar) }
            .filter { $0.width > widest * 0.4 && $0.height > 1 }
            .max { $0.width * $0.height < $1.width * $1.height }
    }

    /// 从 Spotify 那几颗同步 item（**顺序一致**，索引就是选中态与转发的对齐依据）。
    ///
    /// ★ 两条来自日志 63 的实测：
    ///   · 「隐藏标签栏文字」开着时**不给标题** —— 文字以前由我们自己那盘胶囊负责藏，
    ///     这一条开着时那盘让位了 ⇒ 得由这里负责（用户报的"隐藏标签栏文字对它不生效"）；
    ///   · 图标拿不到就**照实记 `false`**（`glyphImage` 没找到）—— 调用方据此**不藏**原来那颗图标。
    ///   · `tag` = 索引：第二片的转发要用它（`didSelectItem` 只给 item，不给序号）。
    private static func syncItems(on systemBar: UITabBar, from items: [UIView]) -> Mirror {
        let hidesLabels = UserDefaults.tabBarHideLabels

        var wanted: [UITabBarItem] = []
        var icons: [Bool] = []
        var titles: [String?] = []
        wanted.reserveCapacity(items.count)

        for (index, item) in items.enumerated() {
            let title = hidesLabels ? nil : labelText(of: item)
            let image = glyphImage(of: item)?.withRenderingMode(.alwaysTemplate)
            wanted.append(UITabBarItem(title: title, image: image, tag: index))
            icons.append(image != nil)
            titles.append(title)
        }

        let mirror = Mirror(icons: icons, titles: titles)
        let current = systemBar.items ?? []
        let sameShape = current.count == wanted.count && zip(current, wanted).allSatisfy { pair in
            pair.0.title == pair.1.title && pair.0.image === pair.1.image
        }
        guard !sameShape else { return mirror }

        systemBar.items = wanted
        lastSelectionIndex = -1
        writeDebugLog(
            "[\(logTag)] items synced — \(wanted.count) item(s); titles \(titles.map { $0 ?? "-" })"
                + "; icons \(icons.map { $0 ? "Y" : "N" })"
                + (hidesLabels ? " (the hide-labels switch is on, so no titles)" : "")
        )
        return mirror
    }

    // MARK: - ★★ 第二片 ②：把系统栏上的选择**转发**成 Spotify 那一颗的点击

    /// 系统栏选中了某一颗（`delegate` 中继叫到这里）。**只在主 actor 上跑**。
    ///
    /// 为什么必须转发：从第二片起系统栏**接管了触摸** ⇒ 手指再也落不到 Spotify 那几颗上。
    /// 不转发就是仓库那条红线（"看得见、点不动"）。
    static func forwardSelection(from systemBar: UITabBar, item: UITabBarItem) {
        guard let bar = lastBar, let stack = TabBarGlassPlate.findTabsStack(in: bar) else {
            writeDebugLog("[\(logTag)] ⚠️ a tab was picked but the stock row is gone — nothing to forward to")
            return
        }
        let items = stack.subviews
        let index = item.tag
        guard index >= 0, index < items.count else {
            writeDebugLog("[\(logTag)] ⚠️ picked item tag \(index) is out of range (\(items.count) item(s))")
            return
        }

        forwardTap(to: items[index], index: index, systemBar: systemBar)

        // Spotify 会在 ~0.25s 后重画标签颜色（那是我们唯一的选中态信号）⇒ 那一刻再对一次气泡。
        // pw 也是这么收尾的（`didSelectItem` 里那个 dispatch_after）。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { reapply() }
    }

    /// 四条路依次试。**顺序是"从最公开到最私有"**，而且第 ① 条来自真机日志 64 的教训：
    ///
    /// ★★ 2026-10-12（真机日志 64）：四颗全是
    /// `⚠️ tap on #N found nothing to forward to … inside [UILongPressGestureRecognizer … |
    /// UITapGestureRecognizer on TabBarItemElementView | …]` ⇒ **旧的三条路一条都没通**
    /// （识别器**在**，但读它的 `_targets` 拿不到可触发的 target/action）⇒ 点标签栏完全没反应
    /// （用户原话："**这些功能并没有实际效果**"）。所以第 ① 条换成**公开 API**：
    ///
    ///   ① **`UITabBarController.selectedIndex`** —— Spotify 那条栏的容器
    ///      （`NavigationUI_TabBarImpl.TabBarContainerImpl`）**是 `UITabBarController` 的子类**
    ///      （pw 在它身上 hook 的正是 `setSelectedViewController:`，那是 `UITabBarController` 的公开方法）
    ///      ⇒ `selectedIndex` 就是"用户点了那一颗"的等价物，**一行签名都不用猜**。
    ///   ② pw 那条路（读 tap 识别器的 target/action）—— 留着，它在 pw 的机器上是通的；
    ///   ③ `-handleTap`（照 pw 注释里点名的 `TabBarItemElementUI`）：不猜签名、只找"响应它的对象"；
    ///   ④ `accessibilityActivate()` → ⑤ `UIControl.sendActions`。
    /// 五条全不通就**把触摸还给 Spotify 那条栏**（见 `handTouchesBack`）——
    /// 宁可不要"按下回弹"，也绝不能留下"看得见、点不动"。
    private static func forwardTap(to item: UIView, index: Int, systemBar: UITabBar) {
        if selectThroughContainer(index: index) {
            reportForward(index: index, route: "UITabBarController.selectedIndex on Spotify's own container")
            return
        }
        if fireTapRecognizers(in: item) {
            reportForward(index: index, route: "the item's own tap recognizer")
            return
        }
        if callHandleTap(in: item) {
            reportForward(index: index, route: "handleTap on the item's element")
            return
        }
        if activateAccessibility(in: item) {
            reportForward(index: index, route: "accessibilityActivate")
            return
        }
        if sendControlActions(in: item) {
            reportForward(index: index, route: "UIControl.sendActions")
            return
        }
        reportForwardFailure(index: index, item: item)
        handTouchesBack(to: systemBar, reason: "every route failed on #\(index)")
    }

    /// ① 公开 API：让 Spotify 自己的容器换页（= 那条栏的 `selectedIndex`）。
    ///
    /// 判据：容器是 `UITabBarController` 的子类、并且它的 `viewControllers` 里有第 index 个。
    /// 对不上就**什么都不做**（返回 false，交给下一路）—— 绝不瞎改别人的选中态。
    private static func selectThroughContainer(index: Int) -> Bool {
        guard let bar = lastBar, let container = container(of: bar),
              let tabs = container as? UITabBarController,
              let controllers = tabs.viewControllers,
              index >= 0, index < controllers.count else { return false }
        guard tabs.selectedIndex != index else { return true }
        tabs.selectedIndex = index
        return true
    }

    // MARK: - ★ 第三片：点一下（装在 **Spotify 自己那条栏**上，不抢触摸）

    /// 用户 2026-10-12（照片 86/87 + 日志 65）：「**液态玻璃不可以用手划动**，而且**反应时间有点慢**」。
    ///
    /// 日志 65 第一行就是答案：`… leaving the touches to Spotify's own bar (no forwarding route found …)`
    /// ⇒ 那一版**根本没接管触摸**（那是对的：接管了又转发不出去 = 点不动），代价是两件事：
    ///   · **慢**：气泡只能靠 0.5s 复查节拍追上去（日志里 `selection → #N` 都是半秒一跳）；
    ///   · **划不动**：手势压根没到我们手里。
    ///
    /// 留下的这一只：`UITapGestureRecognizer`（**`cancelsTouchesInView = false`**）——
    /// 点击照旧由 Spotify 完成（唯一被真机证明能换页的路），我们**同时**知道点了哪一颗
    /// ⇒ **气泡立刻对过去**（不再等半秒）。
    ///
    /// ★★ 第四片（2026-10-12 深夜）：**它的兄弟 `UIPanGestureRecognizer` 已删除**。
    /// 那只 pan 是"按住划 = 滑过哪格切哪格"，用户这一轮报的三件事全是它：
    ///   · `cancelsTouchesInView = true` ⇒ **吃掉那次触摸**，系统玻璃永远接不到手指（"不跟手 / 没有反射"）；
    ///   · 每次 `.changed` 都 `mirrorSelection` + `commitSelection` ⇒ **替用户换页**；
    ///   · 提交不了时把气泡**拨回真实那一颗** ⇒ 看到的"胶囊回弹"。
    /// pw 那条栏上**一只手势都没有**（只有"长按主页进设置"），所以这三个症状它一个都没有。
    private static func installStockGestures(on stockBar: UIView) {
        if objc_getAssociatedObject(stockBar, &stockTapKey) == nil {
            let tap = UITapGestureRecognizer(
                target: TabBarSystemGlassGestureRelay.shared,
                action: #selector(TabBarSystemGlassGestureRelay.stockTapped(_:))
            )
            tap.cancelsTouchesInView = false
            stockBar.addGestureRecognizer(tap)
            objc_setAssociatedObject(stockBar, &stockTapKey, tap, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            // ★ 这一行是"点一下到底有没有被我们看见"的**判据**：
            //   日志 68 里用户点了标签，却只有 0.5s 节拍那几行 `selection → #N`（说明气泡是靠节拍追上的）
            //   ⇒ 要么手势没装、要么装了没收到触摸、要么收到了但算不出第几颗。
            //   有这一行 + `first tap seen` 一行，下一份日志就能把三者分开。
            writeDebugLog(
                "[\(logTag)] tap recogniser installed on Spotify's own bar — it does not cancel touches,"
                    + " so Spotify still switches the page; we only mirror the bubble at once. Waiting for the first tap."
            )
        }
    }

    /// 点击/划动时算"手指在哪一格"（按四颗的 frame 判；落缝里就按 x 等分兜底）。
    static func itemIndex(at point: CGPoint, in bar: UIView) -> Int? {
        guard let stack = TabBarGlassPlate.findTabsStack(in: bar) else { return nil }
        let items = stack.subviews
        if let hit = items.firstIndex(where: { $0.convert($0.bounds, to: bar).contains(point) }) { return hit }
        guard bar.bounds.width > 1, !items.isEmpty else { return nil }
        let ratio = max(0, min(0.999, point.x / bar.bounds.width))
        return Int(ratio * CGFloat(items.count))
    }

    /// **立刻**把气泡对到第 index 颗 —— 这就是"反应慢"那一半的修法（不再等 0.5s 节拍）。
    static func mirrorSelection(index: Int, reason: String) {
        guard isEnabled else { return }
        guard let bar = lastBar,
              let systemBar = objc_getAssociatedObject(bar, &systemBarKey) as? UITabBar,
              let items = systemBar.items, index >= 0, index < items.count else { return }
        lastSelectionIndex = index
        if systemBar.selectedItem !== items[index] { systemBar.selectedItem = items[index] }
        mirroredSelections += 1
        guard mirroredSelections <= 3 else { return }
        writeDebugLog("[\(logTag)] bubble mirrored straight away — #\(index) (\(reason); no waiting for the 0.5s tick)")
    }

    /// 手势**收到了触摸**，但算不出第几颗（= 手势没问题，是"哪一个"的判据不成立）—— 只报一次。
    static func reportTapWithoutIndex() {
        guard !didReportTapWithoutIndex else { return }
        didReportTapWithoutIndex = true
        writeDebugLog(
            "[\(logTag)] ⚠️ the tap recogniser fired but no tab index could be worked out"
                + " — either the tabs stack is not where we think, or the point is outside all four frames"
        )
    }

    /// 第一次真的收到点击（与上面那行"Waiting for the first tap"配对读：有前者没后者 = 触摸没到我们手里）。
    static func noteFirstTapSeen() {
        guard !didNoteFirstTap else { return }
        didNoteFirstTap = true
        writeDebugLog("[\(logTag)] first tap seen on Spotify's own bar — the bubble now moves at once")
    }

    /// ★ 兜底：五条路全不通 ⇒ **把触摸还给 Spotify 自己那条栏**。    ///
    /// 代价：**只有第一次点击失效**，之后每一次都落到 Spotify 那条栏上（= 第一片的行为：点得动、
    /// 但没有"按下回弹"）。收益：绝不留下"看得见、点不动"。
    /// 之所以能做到"只失效一次"：系统栏一旦不吃触摸，我们的 `delegate` 就不会再被叫到，
    /// 而 `apply` 只在**建栏那一刻**设过 `isUserInteractionEnabled`（之后每拍都不碰它）。
    private static func handTouchesBack(to systemBar: UITabBar, reason: String) {
        guard systemBar.isUserInteractionEnabled else { return }
        handedBackTouches = true
        systemBar.isUserInteractionEnabled = false
        // ⚠️ **宿主必须一起关**：它开着交互、又盖在胶囊那一块上 ⇒ 只关栏的话触摸会被宿主吃掉，
        //   页面既切不动、也没有回弹（用户 2026-10-12 报的"没有实际的按键效果"）。
        systemBar.superview?.isUserInteractionEnabled = false
        writeDebugLog(
            "[\(logTag)] ⚠️ \(reason) — handing the touches back to Spotify's own bar so taps keep working from now on;"
                + " the system glass stays as a picture (no press bounce) until the switch is toggled"
        )
    }

    /// 照 pw 的做法：**读那颗 item 子树里 tap 识别器自己的 target/action 并触发它**
    /// （`NavigationUI_TabBarImpl.TabBarItemElementUI` 就是用 `-handleTap` 答这个识别器的）。
    ///
    /// ⚠️ `_targets` / `_target` / `_action` 都是私有 ivar —— 这正是 pw 的做法
    /// （`TabBar.x:139-158`），它靠的就是"真机那一颗没有公开的点击入口"。
    private static func fireTapRecognizers(in item: UIView) -> Bool {
        for view in subtree(of: item, maxDepth: 6) {
            for recognizer in view.gestureRecognizers ?? [] {
                guard recognizer is UITapGestureRecognizer, recognizer.isEnabled else { continue }
                if fire(recognizer) { return true }
            }
        }
        return false
    }

    private static func fire(_ recognizer: UIGestureRecognizer) -> Bool {
        var fired = false
        for pair in pairs(of: recognizer) {
            guard let target = target(of: pair), let action = action(of: pair) else { continue }
            guard target.responds(to: action) else { continue }
            _ = target.perform(action, with: recognizer)
            writeDebugLog(
                "[\(logTag)] tap → \(NSStringFromClass(type(of: target))) \(NSStringFromSelector(action))"
            )
            fired = true
        }
        return fired
    }

    /// 读一条手势的 `_targets`（**私有 ivar**）。读不出来就是空数组 = 这条路不能算数。
    ///
    /// ★ 第四片把它抽出来给两处共用：`fire`（真的触发）与 `probeForwardRoute`
    /// （**点之前**先读一遍，判断"点了有没有人接"）。
    private static func pairs(of recognizer: UIGestureRecognizer) -> [AnyObject] {
        guard let targetsIvar = class_getInstanceVariable(UIGestureRecognizer.self, "_targets"),
              let raw = object_getIvar(recognizer, targetsIvar) as? [AnyObject] else {
            return []
        }
        return raw
    }

    private static func target(of pair: AnyObject) -> NSObject? {
        guard let ivar = class_getInstanceVariable(type(of: pair), "_target") else { return nil }
        return object_getIvar(pair, ivar) as? NSObject
    }

    /// `_action` 是 SEL ivar，KVC 读不了（不是对象）⇒ 按 ivar 偏移把指针读出来再转回 `Selector`。
    private static func action(of pair: AnyObject) -> Selector? {
        guard let ivar = class_getInstanceVariable(type(of: pair), "_action") else { return nil }
        let base = Unmanaged.passUnretained(pair).toOpaque()
        let raw = base.advanced(by: ivar_getOffset(ivar))
            .assumingMemoryBound(to: UnsafeRawPointer?.self).pointee
        guard let raw else { return nil }
        return unsafeBitCast(raw, to: Selector.self)
    }

    /// ③ 私有退路：`-handleTap`。
    ///
    /// 名字来自 pw 的注释（`TabBar.x:137-138`："`NavigationUI_TabBarImpl`'s `TabBarItemElementUI`
    /// answers a tap recognizer (`-handleTap`)"），但**这里不猜参数/返回值** ——
    /// 只在"响应这个 selector 的对象"上调用它，找不到就返回 false：
    ///   · 先看那颗 item 子树里每个视图的 **`next`（响应链）**；
    ///   · 再**有界扫它们的 ivar**（Element 的 UI 对象一般挂在某个视图的 ivar 上，不在响应链里）。
    ///
    /// ⚠️ **2026-10-12 复核 pw 源码之后的结论**：pw 自己**从来不是直接调 `handleTap`** 的 ——
    /// 他走的是 `fireTapRecognizers`（即上面的 ②），只是那个识别器的 action 恰好叫 `-handleTap`。
    /// 我这一条是"那一步读不出来时的补网"，**不是 pw 的做法**；命中与否都会打一行日志，别把它当成主路。
    private static func callHandleTap(in item: UIView) -> Bool {
        guard let found = handleTapHolder(in: item) else { return false }
        _ = found.holder.perform(NSSelectorFromString("handleTap"))
        writeDebugLog(
            "[\(logTag)] tap → \(shortName(NSStringFromClass(type(of: found.holder)))) handleTap (\(found.via))"
        )
        return true
    }

    /// 谁响应 `-handleTap`（③ 那条路）。**读得出来**就说明"点了有人接" ——
    /// 所以 `probeForwardRoute` 与 `callHandleTap` 共用这一处。
    private static func handleTapHolder(in item: UIView) -> (holder: NSObject, via: String)? {
        let selector = NSSelectorFromString("handleTap")
        for view in subtree(of: item, maxDepth: 6) {
            if let responder = view.next as? NSObject, responder.responds(to: selector) {
                return (responder, "responder chain")
            }
            if let holder = ivarHolding(selector: selector, in: view) {
                let owner = shortName(NSStringFromClass(type(of: view)))
                return (holder, "an ivar of \(owner)")
            }
        }
        return nil
    }

    /// 有界扫一个对象的 ivar（含父类，最多 4 层），找**第一个**响应 `selector` 的对象。
    private static func ivarHolding(selector: Selector, in object: NSObject) -> NSObject? {
        var cls: AnyClass? = type(of: object)
        var hops = 0
        while let current = cls, hops < 4 {
            var count: UInt32 = 0
            if let ivars = class_copyIvarList(current, &count) {
                defer { free(ivars) }
                for index in 0 ..< Int(count) {
                    let ivar = ivars[index]
                    // 只看对象类型的 ivar（编码首字符 '@'）——SEL/int/结构体一律跳过。
                    guard let encoding = ivar_getTypeEncoding(ivar), encoding.pointee == 0x40 else { continue }
                    if let value = object_getIvar(object, ivar) as? NSObject, value.responds(to: selector) {
                        return value
                    }
                }
            }
            cls = class_getSuperclass(current)
            hops += 1
        }
        return nil
    }

    /// 第四路：无障碍激活（最深的那一层先试 —— 真正响应点击的往往是里层那颗）。
    private static func activateAccessibility(in item: UIView) -> Bool {
        for view in subtree(of: item, maxDepth: 6).reversed() {
            if view.accessibilityActivate() { return true }
        }
        return false
    }

    /// 第五路：`UIControl` 的 target-action。
    private static func sendControlActions(in item: UIView) -> Bool {
        for view in subtree(of: item, maxDepth: 6) {
            guard let control = view as? UIControl else { continue }
            control.sendActions(for: .touchUpInside)
            return true
        }
        return false
    }

    private static func reportForward(index: Int, route: String) {
        forwardedTaps += 1
        guard forwardedTaps <= 3 else { return }
        writeDebugLog(
            "[\(logTag)] tap on #\(index) forwarded to Spotify — route \(route) (forward #\(forwardedTaps))"
        )
    }

    /// 三条路全不通时的现场：**把子树里的识别器与 UIControl 全列出来**，下一份日志直接给答案。
    ///
    /// ★ 2026-10-12 加细：**tap 识别器要把 pw 那条转发链逐环写清楚**
    /// （`_targets` 在不在 → 有几对 → 每对的 `_target`/`_action` 解出来没有）。
    /// 这是"为什么 pw 的写法在我们这版不通"的**唯一**判据 —— 上一版只报类名，等于什么都没说。
    private static func reportForwardFailure(index: Int, item: UIView) {
        var pieces: [String] = []
        for view in subtree(of: item, maxDepth: 6) {
            let viewName = shortName(NSStringFromClass(type(of: view)))
            if view is UIControl { pieces.append("UIControl \(viewName)") }
            for recognizer in view.gestureRecognizers ?? [] {
                if recognizer is UITapGestureRecognizer {
                    pieces.append("\(describe(recognizer)) on \(viewName)")
                } else {
                    pieces.append("\(shortName(NSStringFromClass(type(of: recognizer)))) on \(viewName)")
                }
            }
        }
        writeDebugLog(
            "[\(logTag)] ⚠️ tap on #\(index) found nothing to forward to — \(shortName(NSStringFromClass(type(of: item))))"
                + "; inside [\(pieces.isEmpty ? "nothing at all" : pieces.joined(separator: " | "))]"
        )
    }

    /// 把一条 tap 识别器的**转发链**逐环写清楚（pw 的链：`_targets` → 每对 `_target`/`_action`）。
    private static func describe(_ recognizer: UIGestureRecognizer) -> String {
        let name = shortName(NSStringFromClass(type(of: recognizer)))
        guard let ivar = class_getInstanceVariable(UIGestureRecognizer.self, "_targets") else {
            return "\(name)[_targets ivar is gone in this build]"
        }
        guard let raw = object_getIvar(recognizer, ivar) else {
            return "\(name)[_targets is nil]"
        }
        guard let pairs = raw as? [AnyObject] else {
            return "\(name)[_targets is not a walkable array]"
        }
        guard !pairs.isEmpty else { return "\(name)[no target/action pairs at all]" }
        let described = pairs.map { pair -> String in
            let targetName = target(of: pair).map { shortName(NSStringFromClass(type(of: $0))) } ?? "nil-target"
            let actionName = action(of: pair).map { NSStringFromSelector($0) } ?? "nil-action"
            return "\(targetName):\(actionName)"
        }
        return "\(name)[\(described.joined(separator: " "))]"
    }

    private static func subtree(of node: UIView, maxDepth: Int, depth: Int = 0) -> [UIView] {
        guard depth <= maxDepth else { return [] }
        var found: [UIView] = [node]
        for sub in node.subviews { found.append(contentsOf: subtree(of: sub, maxDepth: maxDepth, depth: depth + 1)) }
        return found
    }

    // MARK: - ③ 选中态

    /// 选中态：**先看文字亮度**（Spotify 选中那颗画白色、其余 `#B3B3B3`），
    /// 再看 `accessibilityTraits.contains(.selected)`。
    ///
    /// ⚠️ 顺序**与第一版相反**，依据是日志 63：这台机器上四颗的 `traits` **全是 `0x0`**
    /// （`[TabBarSel] item=TabBar.Item.主页 traits=0x0 … label text=#FFFFFF`，其余 `#B3B3B3`）
    /// ⇒ 无障碍那条判据在 9.1.88 上**根本不成立**，只有亮度是真的。
    /// 判据只有一处（这里），而且**用了哪条会打进日志**，下一份日志能核对。
    private static func syncSelection(on systemBar: UITabBar, items: [UIView]) {
        guard let picked = selectedIndex(items: items),
              picked.index < (systemBar.items?.count ?? 0) else { return }
        if lastSelectionSignal != picked.signal {
            lastSelectionSignal = picked.signal
            writeDebugLog("[\(logTag)] selection signal in use: \(picked.signal)")
        }
        guard picked.index != lastSelectionIndex else { return }
        lastSelectionIndex = picked.index
        systemBar.selectedItem = systemBar.items?[picked.index]
        writeDebugLog("[\(logTag)] selection → #\(picked.index)")
    }

    private static func selectedIndex(items: [UIView]) -> (index: Int, signal: String)? {
        if let index = items.firstIndex(where: { isBrightLabel($0) }) {
            return (index, "bright label")
        }
        if let index = items.firstIndex(where: { $0.accessibilityTraits.contains(.selected) }) {
            return (index, "accessibility selected trait")
        }
        return nil
    }

    private static func isBrightLabel(_ node: UIView) -> Bool {
        guard let color = firstLabelColor(node) else { return false }
        var white: CGFloat = 0, alpha: CGFloat = 0
        if color.getWhite(&white, alpha: &alpha) { return white > 0.85 }
        return false
    }

    /// 有界找第一段文字的颜色（深度 ≤ 4，与探针同一套读法）。
    private static func firstLabelColor(_ node: UIView, depth: Int = 0) -> UIColor? {
        guard depth <= 4 else { return nil }
        if let label = node as? UILabel, let text = label.text, !text.isEmpty {
            return label.textColor
        }
        for sub in node.subviews {
            if let found = firstLabelColor(sub, depth: depth + 1) { return found }
        }
        return nil
    }

    /// 那一颗里所有的图标视图（**最深 6 层**：日志 63 证明原来只找 `UIImageView.image`、
    /// 深度 ≤ 4 时是**找不到**的 —— 所以放宽，并且调用方会按"找没找到"决定藏不藏）。
    /// 一颗 item 的图标：**先找现成的 `UIImage`；拿不到就把那个"图标视图"整个渲染成一张图**。
    ///
    /// ★★ 2026-10-12（真机日志 65：`items synced — … icons ["N", "N", "N", "N"]`，照片 86）：
    /// 这一版的图标**不是** `UIImageView` —— 真机树里是
    /// `16.OBJC_ONLY_IconView@40,5,24,24,id=Encore.IconView`（Encore 自己画的图标视图）
    /// ⇒ 只找 `UIImageView.image` **永远拿不到**（前两版都栽在这），于是原图标留在玻璃底下：
    /// 又暗（隔着一层玻璃）又偏（位置由 Spotify 那条栏决定），而那几颗 item 只剩文字。
    /// 照 pw 补一条（`TabBar.x:76-133` 的 `renderLayer`）：**把那个视图的 layer 渲染成 UIImage**，
    /// 当模板图交给 UIKit（`.alwaysTemplate` 会自己上色）。
    ///
    /// ⚠️ 快照**必须在藏原图标之前**做（`apply` 里顺序是先 `syncItems` 再 `hideStockContent`）；
    ///    而且要**按视图缓存**，否则每拍都会生成一张"新"图，`syncItems` 的"形状没变就不重建"永远不成立。
    private static func glyphImage(of node: UIView) -> UIImage? {
        if let ready = glyphViews(in: node).first?.image { return ready }
        guard let icon = findIconView(in: node), icon.bounds.width >= 8, icon.bounds.height >= 8 else { return nil }
        let key = ObjectIdentifier(icon)
        if let cached = iconSnapshots[key] { return cached }

        let renderer = UIGraphicsImageRenderer(bounds: icon.bounds)
        let shot = renderer.image { context in
            icon.layer.render(in: context.cgContext)
        }.withRenderingMode(.alwaysTemplate)
        iconSnapshots[key] = shot
        writeDebugLog(
            "[\(logTag)] icon taken from \(shortName(NSStringFromClass(type(of: icon))))"
                + " at \(frameText(icon.bounds)) — read as a snapshot of its layer, because this build draws icons itself"
        )
        return shot
    }

    /// 类名含 `IconView`、尺寸像个图标的那颗视图（深度 ≤ 6）。
    private static func findIconView(in node: UIView, depth: Int = 0) -> UIView? {
        guard depth <= 6 else { return nil }
        if className(node).contains("IconView"), node.bounds.width >= 8, node.bounds.height >= 8 { return node }
        for sub in node.subviews {
            if let found = findIconView(in: sub, depth: depth + 1) { return found }
        }
        return nil
    }

    private static func className(_ view: UIView) -> String {
        NSStringFromClass(type(of: view))
    }

    private static func glyphViews(in node: UIView, depth: Int = 0) -> [UIImageView] {
        guard depth <= 6 else { return [] }
        var found: [UIImageView] = []
        if let imageView = node as? UIImageView, imageView.image != nil { found.append(imageView) }
        for sub in node.subviews { found.append(contentsOf: glyphViews(in: sub, depth: depth + 1)) }
        return found
    }

    /// 那一颗里所有的文字视图（同上，深度 ≤ 6）。
    private static func labelViews(in node: UIView, depth: Int = 0) -> [UILabel] {
        guard depth <= 6 else { return [] }
        var found: [UILabel] = []
        if let label = node as? UILabel, !(label.text ?? "").isEmpty { found.append(label) }
        for sub in node.subviews { found.append(contentsOf: labelViews(in: sub, depth: depth + 1)) }
        return found
    }

    /// 那一颗的文字。
    ///
    /// ⚠️ **不看 alpha**：那些文字是**我们自己**在上一拍藏掉的（`hideStockContent`），
    /// 按 alpha 过滤的话第二轮就会读成 nil ⇒ 系统栏的标题会在第二拍凭空消失。
    /// "要不要标题"只由「隐藏标签栏文字」那颗开关决定（`syncItems` 里）。
    private static func labelText(of node: UIView) -> String? {
        labelViews(in: node).first?.text
    }

    // MARK: - ④ 让高度

    /// 把系统栏**比 Spotify 那条栏多出来的高度**写成容器的 `additionalSafeAreaInsets.bottom`。
    ///
    /// 为什么是这里（pw 的注释写得很清楚）：Spotify 那条栏的高度由"安全区往上 49pt"决定，
    /// 迷你播放器站在同一条基准上，页面拿 49 + inset ⇒ **只要容器多让出多少，那一整套自己就跟着让**。
    /// `additionalSafeAreaInsets` 是**我们写的**，关开关时能**精确写回**。
    ///
    /// ⚠️ 日志 63 里**没有** `made room` 那一行是**正确结果**：Face ID 机型 `83 - 49 - 34 = 0`。
    /// ⚠️ 第二片之后宿主已经把底部安全区报成 0 ⇒ 这里量出来的高度只会更小（差额仍为 0），
    ///    也就是说"让高度"这条在 Face ID 机型上依旧不生效 —— 与我们自绘胶囊那一版**完全一致**。
    private static func makeRoom(for bar: UIView, systemBar: UITabBar) {
        guard let container = container(of: bar), container.isViewLoaded,
              let view = container.view else {
            noteSkipOnce("no TabBarContainerImpl above the bar - not making room")
            return
        }

        let extra = container.additionalSafeAreaInsets
        let inset = view.safeAreaInsets.bottom - extra.bottom
        let height = glassHeight(systemBar, width: bar.bounds.width)
        // Spotify 的常规宽度栏是固定 76pt、不吃 inset；窄宽度时它的栏就是 49 + inset。
        let compact = container.traitCollection.horizontalSizeClass == .compact
        let room = compact ? max(0, ceil(height - stockRowHeight - inset)) : 0
        guard abs(extra.bottom - room) > 0.5 else { return }

        rememberOriginalRoom(for: container, current: extra.bottom)

        var updated = extra
        updated.bottom = room
        container.additionalSafeAreaInsets = updated
        writeDebugLog(
            "[\(logTag)] made room under Spotify's bar: \(Int(room))pt"
                + " (glass \(Int(height)) - row \(Int(stockRowHeight)) - inset \(Int(inset)))"
        )
    }

    private static func glassHeight(_ systemBar: UITabBar, width: CGFloat) -> CGFloat {
        if measuredGlassHeight > 0 { return measuredGlassHeight }
        measuredGlassHeight = systemBar
            .sizeThatFits(CGSize(width: max(width, 1), height: stockRowHeight))
            .height
        return measuredGlassHeight
    }

    private static func restoreRoom(in bar: UIView) {
        guard let container = container(of: bar) else { return }
        guard let state = objc_getAssociatedObject(container, &roomKey) as? RoomState else { return }
        var insets = container.additionalSafeAreaInsets
        guard abs(insets.bottom - state.written) < 0.5 else { return }
        insets.bottom = state.original
        container.additionalSafeAreaInsets = insets
        objc_setAssociatedObject(container, &roomKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        writeDebugLog("[\(logTag)] room restored to \(Int(state.original))pt")
    }

    private final class RoomState: NSObject {
        let original: CGFloat
        let written: CGFloat
        init(original: CGFloat, written: CGFloat) {
            self.original = original
            self.written = written
        }
    }

    /// 第一次写之前记下**原来那个值**（我们只许改自己改过的那一档；别人写过的值不动）。
    private static func rememberOriginalRoom(for container: UIViewController, current: CGFloat) {
        guard objc_getAssociatedObject(container, &roomKey) == nil else { return }
        objc_setAssociatedObject(
            container,
            &roomKey,
            RoomState(original: current, written: current),
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }

    /// 从栏往上找 `TabBarContainerImpl`（pw 也是这么找的：它是这条栏的容器 VC）。
    private static func container(of bar: UIView) -> UIViewController? {
        guard let containerClass = NSClassFromString(containerClassName) else { return nil }
        var responder: UIResponder? = bar.next
        var hops = 0
        while let current = responder, hops < 30 {
            if let controller = current as? UIViewController, type(of: controller) == containerClass {
                return controller
            }
            responder = current.next
            hops += 1
        }
        return nil
    }

    // MARK: - 日志与小工具

    private static func noteSkipOnce(_ reason: String) {
        guard lastSkipReason != reason else { return }
        lastSkipReason = reason
        writeDebugLog("[\(logTag)] standing by (\(reason))")
    }

    /// ★ 第二片 ①：**把"我们给的框"和"UIKit 真画出来的玻璃"放进同一行**。
    ///
    /// 用户要求"系统的液态玻璃与自绘的对齐"，而 UIKit 的浮岛玻璃**按自己的内边距画**
    /// （我们给的宿主框 ≠ 玻璃框）⇒ 只有实测数字能收敛：这一行里
    /// `host` 是我们摆的、`system bar` 是系统栏自己的、`drawn` 里那几块（platter /
    /// liquid lens / selection）**才是屏幕上真正的那条胶囊**。下一份日志就能算出常量差。
    private static func reportGlassGeometry(_ systemBar: UITabBar, in bar: UIView) {
        let host = hostView(for: bar)
        let pieces = platterViews(in: systemBar).map { name, view in
            "\(name)=\(frameText(view.convert(view.bounds, to: bar)))"
        }
        let line = "[\(logTag)] glass geometry — host \(frameText(host?.frame ?? .null))"
            + "; system bar \(frameText(systemBar.frame))"
            + "; drawn [\(pieces.isEmpty ? "not laid out yet" : pieces.joined(separator: " "))]"
        guard line != lastGeometryLine else { return }
        lastGeometryLine = line
        writeDebugLog(line)
    }

    /// 系统栏里"玻璃自己那几块"（按类名认：`Platter` / `LiquidLens` / `SelectionView`）。
    private static func platterViews(in node: UIView, depth: Int = 0) -> [(String, UIView)] {
        guard depth <= 6 else { return [] }
        var found: [(String, UIView)] = []
        let name = NSStringFromClass(type(of: node))
        if name.contains("Platter") || name.contains("LiquidLens") || name.contains("SelectionView") {
            found.append((shortName(name), node))
        }
        for sub in node.subviews { found.append(contentsOf: platterViews(in: sub, depth: depth + 1)) }
        return found
    }

    /// 类名去掉模块前缀（日志里短一点、读起来也稳）。
    private static func shortName(_ name: String) -> String {
        name.split(separator: ".").last.map(String.init) ?? name
    }

    private static func logLayoutOnce(
        bar: UIView,
        items: [UIView],
        systemBar: UITabBar,
        mirrored: Mirror
    ) {
        guard !didLogLayout else { return }
        didLogLayout = true
        // ⚠️ 日志 63 里我打的是 `stack.frame`，那时它是 `0,0,0,0`（还没排）⇒ 现在改打**每颗的 frame**。
        let frames = items.map { frameText($0.convert($0.bounds, to: bar)) }.joined(separator: " ")
        // ⚠️ 这一行原来**写死**了 `taking touches, taps forwarded to Spotify's own items` ——
        //   日志 70 里它和上面那行 `leaving the touches to Spotify's own bar` **自相矛盾**（第四片才发现）。
        //   现在照实报：`isUserInteractionEnabled` 是什么就写什么。
        let touchState = systemBar.isUserInteractionEnabled
            ? "; taking the touches, taps forwarded to Spotify's own items"
            : "; not taking the touches (nothing readable to forward a tap to), so Spotify's own bar still gets them"
        writeDebugLog(
            "[\(logTag)] installed — \(items.count) item(s); icons \(mirrored.icons.map { $0 ? "Y" : "N" })"
                + "; item frames [\(frames)]; system bar \(frameText(systemBar.frame))"
                + "; class \(NSStringFromClass(type(of: systemBar)))"
                + touchState
        )
    }

    private static func frameText(_ frame: CGRect) -> String {
        "\(Int(frame.origin.x)),\(Int(frame.origin.y)),\(Int(frame.width)),\(Int(frame.height))"
    }
}

/// 系统栏本体。
///
/// 第一片它只负责"长得对"；**第二片起它接管触摸**，选中的那一颗由 `TabBarSystemGlassRelay`
/// 转发成对 Spotify 那一颗的点击（见文件头第二片 ②）。
final class TabBarSystemGlassBar: UITabBar {
}

/// 系统栏的宿主：**只做一件事 —— 把底部安全区让掉**。
///
/// 为什么必须有它：UIKit 的浮岛玻璃条**按"所在视图的安全区"**量自己的高度
/// （pw 的注释：Face ID 机型 `max(83, 49 + inset)`、Home 键机型 `62 + max(21, inset)`）。
/// 直接把系统栏塞进一个 60pt 的框里、而它的宿主还报着 34pt 底部安全区的话，
/// 那 34pt 会被留给 Home Indicator ⇒ 内容区只剩 26pt，玻璃画不对。
/// 宿主把 bottom 报成 0 ⇒ 它老老实实按我们给的框画（pw 的 `SGRTabBarHost` 同款做法，
/// 区别是 pw 让掉的是"他们让出去的高度"，我们让掉的是整条底部安全区）。
final class TabBarSystemGlassHost: UIView {
    override var safeAreaInsets: UIEdgeInsets {
        var insets = super.safeAreaInsets
        insets.top = 0
        insets.bottom = 0
        return insets
    }
}

/// 点击中继：系统栏 `delegate` 是 **weak** 的 ⇒ 这个对象由关联对象持有（见 `ensureBar`）。
///
/// ⚠️ 这个类**故意不标 `@MainActor`**（与 `SponsorBlockOverlay` 同一个写法）：
///    UIKit 的 delegate 回调按这个写就不用碰隔离判据；真正的活全部在
///    `onMainThreadSync` 的闭包里干（那个闭包本身就是 `@MainActor`）。
final class TabBarSystemGlassRelay: NSObject, UITabBarDelegate {
    /// ⚠️ Swift 里这个名字是 **`tabBar(_:didSelect:)`**（ObjC 的 `tabBar:didSelectItem:`
    /// 从 Swift 3 起就被导入成这个短名）。写成 `didSelectItem` 编译器直接报
    /// "'tabBar(_:didSelectItem:)' has been renamed to 'tabBar(_:didSelect:)'"（2026-10-12 踩过）。
    func tabBar(_ tabBar: UITabBar, didSelect item: UITabBarItem) {
        onMainThreadSync {
            TabBarSystemGlass.forwardSelection(from: tabBar, item: item)
        }
    }
}

/// **手势中继**：装在 **Spotify 自己那条栏**上的那只"点一下"（**不抢触摸**）。
///
/// 与点击中继同一套写法：这个类**故意不标 `@MainActor`**（`@objc` 的手势 action 从
/// UIKit 那侧调进来），真正的活全部在 `onMainThreadSync` 的闭包里干。
///
/// ⚠️ 第四片删掉了它的第二只手势（`UIPanGestureRecognizer` "按住划"）—— 见文件头；
///    系统栏接管触摸时这一只根本收不到触摸（手指落在我们的宿主上），只在
///    "把触摸交还 Spotify" 那一档里起作用。
final class TabBarSystemGlassGestureRelay: NSObject {

    static let shared = TabBarSystemGlassGestureRelay()

    /// 点一下：Spotify 自己去换页（触摸没被我们取消），我们**同时**把气泡对过去。
    @objc func stockTapped(_ recognizer: UITapGestureRecognizer) {
        onMainThreadSync {
            guard let bar = recognizer.view else { return }
            guard let index = TabBarSystemGlass.itemIndex(at: recognizer.location(in: bar), in: bar) else {
                TabBarSystemGlass.reportTapWithoutIndex()
                return
            }
            TabBarSystemGlass.noteFirstTapSeen()
            TabBarSystemGlass.mirrorSelection(index: index, reason: "a tap on Spotify's own bar")
        }
    }
}
