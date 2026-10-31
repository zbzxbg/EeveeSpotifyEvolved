// 「歌词进播放器」——量几何（Geometry / measure / 找封面与各锚点）。
// 从 `NowPlayingLyricsPlate.swift` 原样拆出（`NowPlayingLyricsPlate` 的 extension）；
// 形状、动画与硬约束见那个文件的头注。
import Foundation
import SwiftUI
import UIKit
import Orion
import ObjectiveC.runtime

@MainActor
extension NowPlayingLyricsPlate {
    // MARK: - 量几何（pw 的 `layoutIn`）

    struct Geometry {
        var cover: CGRect       // Spotify 现在把封面画在哪
        var thumb: CGRect       // 缩略图该在哪
        var stage: CGRect       // 歌词区
        var lift: CGFloat       // 标题行上移多少（负数）
        var shift: CGFloat      // 标题右移多少
        var titleRow: UIView?   // 标题所在的那一行（要位移的）
        var titleElement: UIView?
    }

    /// `measure` 的两种结局（见 `layoutAndMount` 里那段说明）。
    enum MeasureOutcome {
        case ok(Geometry)
        case failed(String)
    }

    static func measure(in page: UIView) -> MeasureOutcome {
        guard page.bounds.height >= livingHeight else {
            return .failed(
                "the page is too short to hold lyrics (\(Int(page.bounds.height))pt < \(Int(livingHeight))pt)"
            )
        }
        guard let list = findByIdentifier(listIdentifier, in: page) else {
            return .failed("cannot find the player list (\(listIdentifier)) inside the page")
        }

        // 封面：列表子树里第一个**看得见**的 `Encore.ImageView`，且宽度像封面（>=200）。
        // ⚠️ 这一条**必须**在列表里找：封面是列表里那些格子的内容。
        guard let coverView = visibleCover(in: list, page: page) else {
            return .failed("cannot find a visible artwork wide enough (>=200pt) inside the player list")
        }
        let cover = coverView.convert(coverView.bounds, to: page)

        // 标题行：`now-playing-title-label` 所在的那个 element 视图 + 它的父行。
        //
        // ⚠️ 顺序**必须"先 `list`，再 `page` 兜底"**：这一行本来就在列表子树里（子树小得多），
        // 而 `findByIdentifier` 有 `maxNodes = 800`、BFS 是**先宽后深** —— 从 `page` 起走要
        // 先趟过整页的宽度（那些卡片）才轮到这一行的深度，预算有可能在到那儿之前就用完
        // ⇒ 反过来写会比只搜 `list` 更差。
        let titleLabel = findByIdentifier(titleLabelIdentifier, in: list)
            ?? findByIdentifier(titleLabelIdentifier, in: page)
        let titleElement = titleLabel?.superview
        let titleRow = titleElement?.superview

        // 缩略图：贴"封面区"左上 —— 我们用封面自己的左上 + `thumbTop`（pw 用 `SGRPlayerArtworkAreaIn`，
        // 我们量不到那个 band，就用封面的顶；差别只是几 pt，且换歌会重算）。
        // ⚠️ **`leading` 必须夹住**：`titleElement` 可能是个 marquee（`transform.tx` 是**模型值**、
        // `UIView.animate` 会立刻写上去）或者右对齐的行 ⇒ 量出来的 `minX` 可能是负的、或每拍都在跳。
        // 它直接喂给 `thumbTransform`，后果有两条：① 缩略图飞到画面外；② `applyCoverState` 的收敛
        // 判据是**精确比较**，每拍一个新 `target` 就会每 0.5s 重启一次 0.45s 的动画（封面永不停）。
        let rawLeading = titleElement.map { untransformed($0, in: page).minX } ?? (cover.minX + 20)
        let leading = min(
            max(rawLeading, page.bounds.minX + stageSideInset),
            page.bounds.maxX - thumbSide - stageSideInset
        )
        // 缩略图**不再跟着原生封面**，改成**贴导航条下沿**。
        //
        // 也就是把 96（导航条下沿）到 161 那 **65pt 白扔**；而 kumone 的 header 是贴着自己那根
        // 横条下面的（67–133）。我们上面有 Spotify 的 96pt 导航条躲不开 ⇒ 目标 = 96 + 8 = 104
        // （能达到的最近位置）。导航条用 **id** 量（`now-playing-minimize-button`），
        // 量不到就退回旧算法（宁可回到旧行为，也不要一张都摆不出来）。
        let navBottom = navBarBottom(in: page)
        let thumbY = navBottom.map { $0 + thumbTop } ?? (cover.minY + thumbTop)
        let thumb = CGRect(
            x: leading,
            y: thumbY,
            width: thumbSide,
            height: thumbSide
        )

        // 标题行：缩略图右侧垂直居中（找不到标题就贴在缩略图下面）。
        let rowFrame = titleRow.map { untransformed($0, in: page) }
        let top = rowFrame.map { thumb.midY - $0.height / 2 } ?? (thumb.maxY + 12)
        let lift = top - (rowFrame?.minY ?? top)
        // （当歌曲名字过长时…右侧的晃动区超过屏幕的右侧了）：
        // 右移给缩略图让位的量**不许把那一行的右边缘推出屏幕**。
        // 算术（真机：页面 414pt、那一行 308pt、原来 72+16）：28+72+16+308 = **424 > 414**
        // ⇒ 长标题的 marquee 有 10pt 在屏幕右边之外（这就是用户报的那一条）。
        // 常量已经收到 64+12（= 412，正好进得去），这里再夹一道**上限**兜别的机型/更宽的行：
        // 右边缘最多到页面右沿 − 4pt —— 宁可挤掉几 pt 的 gap，也不许晃动区出屏。
        let wantedShift = thumbSide + thumbGap
        let shiftLimit = (page.bounds.maxX - 4) - (rowFrame?.maxX ?? page.bounds.maxX)
        let shift = rowFrame == nil ? 0 : max(0, min(wantedShift, shiftLimit))

        // 歌词区：缩略图/标题之下 → **进度条之上**。
        //
        // 原来锚在 `npv.bottomStackView` 的**顶边**（≈593）⇒ 歌词 261–584，
        // 而进度条在 ≈680 ⇒ 中段白空 80–100pt；kumone 是"歌词一直排到进度条上方 19pt"
        // （623 / 642）。改成锚**进度条单元**的顶边（id），量不到才退回旧锚点。
        let stageBottom: CGFloat
        let progressTop = progressUnitTop(in: list, page: page)
        // 这一次走查**同时**服务"退路"与日志（别为了打日志再走一遍）。
        let stackTop = bottomStackTop(in: list, page: page)
        if let progressTop {
            stageBottom = progressTop - lyricGapAboveProgress
        } else {
            stageBottom = (stackTop ?? (page.bounds.height - 240)) - lyricsBottom
        }
        // 三个锚点的实测值（只给 `[NPVLyrics] expanded — …` 那一行用；**不编造**：量不到就打 not found）。
        lastAnchorText = "(anchors: navBottom=\(anchorText(navBottom)),"
            + " progressTop=\(anchorText(progressTop)),"
            + " bottomStackTop=\(anchorText(stackTop)))"
        let stageTop = max(thumb.maxY, top + (rowFrame?.height ?? 0)) + lyricsTop
        let stage = CGRect(
            x: stageSideInset,
            y: stageTop,
            width: page.bounds.width - stageSideInset * 2,
            height: stageBottom - stageTop
        )

        guard stage.height > livingHeight / 2 else {
            return .failed("the lyrics area would be too short (\(Int(stage.height))pt)")
        }
        // ⚠️`lift` **只有量到标题行时**才配当判据：量不到时上面那句
        // `let lift = top - (rowFrame?.minY ?? top)` 恒等于 **0** —— 一个 nil 合并表达式会悄悄变成
        // 一条"永远失败"的判据。量不到标题行 = 这一页没有要上移的东西 ⇒ **照常展开**，只是不做位移。
        //
        // ⚠️ `rowFrame != nil && lift >= 0` 这条**必须留着、不能放宽**：标题行已在树里但还没落位时
        // （frame 还在 (0,0)）`lift` 假性 > 0 ⇒ 拒绝。把一个还没落位的标题行"上移"到错的地方比不展开
        // 更糟；要治的是"下一秒再试一次"—— 那正是 `openAndMount` 的窗口。
        if rowFrame != nil, lift >= 0 {
            return .failed("the title row has not settled yet (lift=\(Int(lift))pt) - will retry next tick")
        }

        return .ok(Geometry(
            cover: cover,
            thumb: thumb,
            stage: stage,
            lift: lift,
            shift: shift,
            titleRow: titleRow,
            titleElement: titleElement
        ))
    }

    /// 列表里那个"看得见的封面"。**三趟**，一趟比一趟宽：
    /// · **第一趟（最硬）**：必须**在 `SPTNowPlayingView` 里面**，且祖先里没有被折成 0 的；
    /// · **第二趟**：只要"祖先里没有被折成 0 的"；
    /// · **第三趟**：旧判据（**宁可回到老行为，也不要一张都挑不出来**）。
    ///
    /// `id=SPTNowPlayingView` 是**结构性身份**，不是几何猜的：真机 `[NPVTree]` 里播放器的每一件
    /// 都在它里面（底部那一坨 / 进度条 / 三颗按钮 / 标题行），而**卡片自己的封面**与它**平级**、
    /// 不在里面 ⇒ 三趟的顺序就是"从硬到软"。
    static func visibleCover(in list: UIView, page: UIView) -> UIView? {
        if let owner = findByIdentifier(nowPlayingViewIdentifier, in: page),
           let inside = firstVisibleCover(in: list, skippingCollapsedAncestors: true, inside: owner) {
            noteChosenCover(inside, tier: "inside SPTNowPlayingView")
            return inside
        }
        if let strict = firstVisibleCover(in: list, skippingCollapsedAncestors: true) {
            noteChosenCover(strict, tier: "no collapsed ancestor")
            return strict
        }
        guard let fallback = firstVisibleCover(in: list, skippingCollapsedAncestors: false) else {
            return nil
        }
        noteChosenCover(fallback, tier: "legacy predicate")
        return fallback
    }

    /// 一趟有界 BFS。`skippingCollapsedAncestors = true` 时跳过"祖先里被折成 0 的"那些；
    /// `inside` 非空时只认它的后代。
    ///
    /// **优先挑"真的落在页面范围内"的那一张**：页面里会同时存在两个同尺寸的 `Encore.ImageView`，
    /// 另一个可能 `window != nil`（老判据认它）却**整张在屏幕外** —— 把 `alpha = 0` 写在它身上屏幕
    /// 上那张一点没变，而 `measure` 还会拿它的 frame 当地理。
    /// ⚠️ 只用来**挑**，不做硬门禁：只剩离屏那一张 ⇒ 照旧用它（转场中途真封面也可能暂时在页面外）。
    static func firstVisibleCover(
        in list: UIView,
        skippingCollapsedAncestors: Bool,
        inside owner: UIView? = nil
    ) -> UIView? {
        var visited = 0
        var queue: [UIView] = [list]
        var firstCandidate: UIView?

        while !queue.isEmpty, visited < maxNodes {
            let view = queue.removeFirst()
            visited += 1

            if view.accessibilityIdentifier == coverImageIdentifier,
               !view.isHidden,
               view.alpha > 0.01 || isHiddenByUs(view),
               view.window != nil,
               view.bounds.width >= 200,
               isInsideOwner(owner, view),
               !(skippingCollapsedAncestors && hasCollapsedAncestor(view, root: list)) {
                if isWithinReach(view, host: list) { return view }
                if firstCandidate == nil { firstCandidate = view }
            }
            // hidden 的子树不往下走（离屏的那些封面一格一个，不必要）。
            if view.isHidden { continue }
            queue.append(contentsOf: view.subviews)
        }
        return firstCandidate
    }

    /// 这个视图**是不是落在宿主画得出的范围里**（给 80pt 的容差：转场中途的位移不算"跑飞了"）。
    ///
    /// 与 `isOnScreen(_:in:)` 同一套想法，区别是宿主可以是列表（走查那一层手里只有列表），
    /// 而且**带容差** —— 这一条只用来排序候选，不该把"正在飞进来的封面"判死。
    static func isWithinReach(_ view: UIView, host: UIView) -> Bool {
        let frame = untransformed(view, in: host)
        guard frame.width >= 1, frame.height >= 1 else { return false }
        return frame.intersects(host.bounds.insetBy(dx: -80, dy: -80))
    }

    /// `owner` 为空 ⇒ 不设限；否则要求 `view` 是它的后代（`isDescendant(of:)` 含"就是自己"）。
    static func isInsideOwner(_ owner: UIView?, _ view: UIView) -> Bool {
        guard let owner else { return true }
        return view.isDescendant(of: owner)
    }

    /// 这个视图**在祖先里有没有被"折没"**：任一祖先 `hidden`，或者 `bounds` 退化到 0。
    ///
    /// ⚠️ **不看 `alpha`**：`hideSpotifyCover` 会把**已经被我们藏起来的那张**写成 `alpha = 0`，
    /// 而下一拍 `measure` 还得能再认出它来（隐藏名册在 `hiddenCovers` 里）。
    /// 这里只判"几何上被折没了"，那是「一屏」留下的唯一痕迹。
    ///
    /// 走查有界（32 跳，本仓库纪律），到 `root` 为止。
    static func hasCollapsedAncestor(_ view: UIView, root: UIView) -> Bool {
        var node: UIView? = view
        var hops = 0
        while let current = node, hops < 32 {
            if current !== root {
                if current.isHidden { return true }
                if current.bounds.height < 1 || current.bounds.width < 1 { return true }
            }
            if current === root { break }
            node = current.superview
            hops += 1
        }
        return false
    }

    /// **被我们自己藏起来的那张也算合格** —— 这是上面那条判据能活过第二拍的**前置条件**。
    ///
    /// `ensureCover` 在展开的那一刻就把 Spotify 那张主封面的 `alpha` 写成 0
    /// （`hideSpotifyCover`，同图所以看不出"换"），而 **`layoutAndMount` 每一拍都要重跑**
    /// ⇒ 下一拍 `visibleCover` 必须还能再认出它来。不认它的话：
    /// 严格那一趟一张都挑不到 → 退回旧判据 → 又去挑那张**卡的**封面 → `lift` 又变正数
    /// ⇒ **展开撑不过半秒**。（独立只读复核点出来的，本轮修法的前置条件。）
    static func isHiddenByUs(_ view: UIView) -> Bool {
        // 问**静态名册**（`hiddenCovers`），不再问页面 ——
        // `lastPage` 是 weak，页面一没这里就会答"不是我们藏的"，于是展开撑不过半秒；
        // 名册本身也不该依赖"哪一页"（见名册那段的两条理由）。
        hiddenCovers.contains(view)
    }

    /// 挑中的封面**换了就报一行**（上限 `chosenCoverLogLimit` 行）。
    ///
    /// 为什么不是"整个会话只报一次"：`visibleCover` 有两个调用时机 ——
    /// 页面开着时 `rememberArtworkIfNeeded` 顺手认一次、点的那一刻 `measure` 再量一次。
    /// **这两次挑中的可能不是同一个**，
    /// 必须看得见"换了"。有限次，不会刷屏。
    static weak var lastLoggedCover: UIView?
    static var chosenCoverLogs = 0
    static let chosenCoverLogLimit = 12

    static func noteChosenCover(_ view: UIView, tier: String) {
        guard lastLoggedCover !== view else { return }
        lastLoggedCover = view
        guard chosenCoverLogs < chosenCoverLogLimit else { return }
        chosenCoverLogs += 1
        // ⚠️ 不要写 `rect.map(frameText)`：那是把一个 `@MainActor` 静态方法当函数值传，
        // 本仓库的编译器版本只保证"最多一个警告"，没必要冒这个险（独立复核指出）。
        let where_: String
        if let page = lastPage {
            where_ = frameText(view.convert(view.bounds, to: page))
        } else {
            where_ = "?"
        }
        writeDebugLog(
            "[\(logTag)] artwork picked \(NSStringFromClass(type(of: view)))"
                + " \(Int(view.bounds.width))×\(Int(view.bounds.height))"
                + " at \(where_)"
                + " (tier=\(tier))"
        )
    }

    /// 底部那一坨的顶边（页面坐标系）。
    ///
    /// **先认"从 `page` 直接量"**（`convert` 出来就是页面坐标，最准），找不到才退回老那套
    /// "列表 + `layer.position`"的算法。
    ///
    /// ⚠️ 这不是"修 bug"，是**加固**：问题只在**找不到时的退路** —— `page.bounds.height - 240`
    /// 是个硬编码猜值，比真值**低约 97pt** ⇒ 歌词区会一路画到标题行 / 进度条 / 控件上。
    /// 两个消费者（`toggleFrame` / 底部音量条）都是用 `page` 那一跳才稳的，这里跟它们对齐。
    static func bottomStackTop(in list: UIView, page: UIView) -> CGFloat? {        if let stack = findByIdentifier(bottomStackIdentifier, in: page) {
            let top = stack.convert(stack.bounds, to: page).minY
            if top > 0, top < page.bounds.height { return top }
        }
        guard let stack = findByIdentifier(bottomStackIdentifier, in: list) else { return nil }
        let listPosition = list.layer.position
        let listOriginY = listPosition.y - list.bounds.height / 2
        return listOriginY + (stack.layer.position.y - stack.bounds.height / 2)
    }

    /// 去掉我们自己写上去的位移之后的 frame（pw 的 `untransformed`）。
    static func untransformed(_ view: UIView, in host: UIView) -> CGRect {
        let frame = view.convert(view.bounds, to: host)
        let t = view.transform
        return frame.offsetBy(dx: -t.tx, dy: -t.ty)
    }

    // MARK: - 两个新锚点
    //
    // 导航条的下沿（pt，页面坐标系）。
    //
    // 判据是 **id**：`now-playing-minimize-button`（真机每一份 `[NPVTree]` 里都有
    // `Tertiary@0,0,48,48,id=now-playing-minimize-button`）——
    // 不按类名（`Tertiary` 全页好几颗）、不按几何猜。
    static func navBarBottom(in page: UIView) -> CGFloat? {
        guard let button = findByIdentifier(minimizeButtonIdentifier, in: page) else { return nil }
        let frame = untransformed(button, in: page)
        guard frame.maxY > 0, frame.maxY < page.bounds.height / 2 else { return nil }
        return frame.maxY
    }

    /// 进度条单元的顶边（pt，页面坐标系）。
    ///
    /// 判据同样是 **id**：`Components.UI.ProgressBarUnitNowPlaying`
    /// （真机树里 `AutoLayoutStackView@0,0,358,41,id=…`）。
    /// 先在这一页的列表里找，再在整页找 —— 它在不在列表子树里，不同构建不一样
    /// （`bottomStackTop` 的注释里记过同一类问题）。
    static func progressUnitTop(in list: UIView, page: UIView) -> CGFloat? {
        for root in [list, page] {
            guard let unit = findByIdentifier(progressUnitIdentifier, in: root) else { continue }
            let frame = untransformed(unit, in: page)
            guard frame.minY > 0, frame.minY < page.bounds.height else { continue }
            return frame.minY
        }
        return nil
    }

    // MARK: - 封面与标题
    //
    // 我们自己那份封面：**建/复用容器 + 里面的 imageView**，并**把 Spotify 那条藏起来**。
    //
    // 动画的关键（照 pw `PlayerLyrics.x` 的 `place` / `thumbTransform`，GPL-3.0）：容器永远
    // 按"**Spotify 画封面的大小与位置**"布局，位移只写在 `transform` 上（*bounds + center, not a frame*）。
    //
    // ⚠️ **不能动画 `frame`**：`layoutAndMount` **每 0.3s 重跑一次**要重写封面布局，画在 `frame` 上
    // 会被那一拍**打断/拽回**；改 `bounds`/`center` **完全不打扰动画**（本仓库纪律：`frame` 在 transform
    // 非恒等时不可信）。阴影同理挂在**容器**上（跟着 transform 走、不用每帧重画）⇒ 容器**不裁剪**，
    // 裁剪与圆角放在里面那层 imageView 上。
    // MARK: - 收起态的大封面尺寸（把现在的大封面做小，不需要那么大）
    //
    // 收起态那张大封面的目标宽度（pt）：Spotify 给的是 **366pt**，这里收到 **242pt**（kumone 的量）。
    //
    // 为什么只动 `transform`：收起态那张是 **Spotify 自己的**（我们那份只在展开时存在）⇒ 尺寸只能
    // 这么收 —— 仓库规矩：改别人的视图**只做 transform / 透明度**，动完要能**完全还原**
    // （原值记在 `scaledCoverBase`，离开页面 / 关开关时写回）。
    //
    // 附带：`measure` 用 `convert`（**含 transform**）⇒ `geometry.cover` 自动变成 242pt，缩略图的
    // 缩放比与动画起点跟着对；封面顶边落到 ≈208pt ⇒ 收起态标题行离它 59pt，不再压住歌手名字。
    // ⚠️ **展开 / 收起两个状态都要摆**：换歌会换一个新的封面对象。
    static let restingCoverSide: CGFloat = 242
}
