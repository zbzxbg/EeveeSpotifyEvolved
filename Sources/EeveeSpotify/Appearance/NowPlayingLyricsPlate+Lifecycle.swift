// 「歌词进播放器」——生命周期（对外入口 / reconcile / 收起 / 展开）。
// 从 `NowPlayingLyricsPlate.swift` 原样拆出（`NowPlayingLyricsPlate` 的 extension）；
// 形状、动画与硬约束见那个文件的头注。
import Foundation
import SwiftUI
import UIKit
import Orion
import ObjectiveC.runtime

@MainActor
extension NowPlayingLyricsPlate {
    // MARK: - 对外入口

    static func apply(in pageView: UIView) {
        // 换页面 ⇒ 这一棵树里的元素全变了，`findByIdentifier` 那份缓存整块作废。
        if lastPage !== pageView { invalidateNodeLookups() }
        // 换歌同理（元素会被重建，同一个 id 可能新旧两份同时在树上）。
        noteTrackForLookups()
        lastPage = pageView
        // 进页面 = 这一程开始（上一次的"要走了"作废）。
        door.pageDidAppear()

        guard isEnabled else {
            // 关掉功能 = **页面回到 Spotify 原样**：一次回滚（见 `restoreAll`）。
            restoreAll(reason: "switch off", animated: false)
            // 一次一页只报一行（`lastEnabledSkipReason`）。
            noteDisabledReason()
            return
        }
        guard pageView.bounds.width > 1, pageView.bounds.height > 1 else { return }

        // 进页面先收拾**上一程的残留**。
        //
        // 为什么会有残留：退出时我们把收尾**推迟**到"页面真的不在窗口里"那一刻。
        // 万一那一拍没赶上（比如 Spotify 把这一页留在窗口里、只是不再显示），残留就会跟着进来：
        // 我们的缩略图 + 被按住的封面 —— 而这一次**没有**要求展开（用户上次是收起的）
        // ⇒ 屏幕上是一个"大封面没了、歌词也没有"的半成品。
        if !door.isOpen, doorPhase != .closed {
            closeEverything(reason: "left over from the previous visit", animated: false)
        }

        // ⚠️ 顺序要紧：先铺歌词（封面 / 标题 / 容器都会 `bringSubviewToFront`），
        // **再**摆那枚键 —— 后写的赢，否则键会被我们自己的容器压住。
        // 铺不上（拿不到封面图等）就**不认"已展开"**，别留半成品 —— 但会由 `openAndMount`
        // 开一个 2.5s 的重试窗口，下一拍接着试。
        if door.isOpen {
            openAndMount(in: pageView)
        } else if UserDefaults.nowPlayingLyricsExpanded {
            // **页面记忆** —— 上次离开这一页时是"展开"状态，这次进来就还铺上。
            // 见 `reopenIfRemembered`。顺序同样要在 `ensureToggleZone` 之前（后写的赢）。
            reopenIfRemembered(in: pageView)
        }
        applyControlBand(in: pageView)
        // 大封面的尺寸也要在**这一拍就位**，否则下面 `applyClosedTitleTransform`
        // 量到的还是 366pt 的封面（顶边 146）⇒ 标题行会被那道"别压封面"的夹子多抬 9pt，
        // 下一拍再弹回来。顺序：先摆封面，再摆跟着封面走的那一行。
        applyCoverRestingScale(in: pageView)
        if !door.isOpen {
            applyClosedTitleTransform(in: pageView)
            // 收起态也要有 `歌手（提供商）`（见 `reconcile` 里同一处）。
            applyProviderToArtistLine(in: pageView)
        }
        // 被移走的标题行**还能点**（点歌名/歌手跳专辑/歌手页）。
        applyTitleRelay(in: pageView)
        ensureToggleZone(in: pageView)
    }

    /// 页面**要**走了 —— 只记一笔，**什么都不收**。
    ///
    /// 收尾（撤销几何、把原生封面写回、摘掉我们的层与那枚键）交给 `reconcile` 在
    /// **"页面真的不在窗口里"**那一刻做 —— 这样整个退出转场里页面都是我们的样子。
    static func pageWillLeave() {
        door.pageWillLeave()
    }

    /// 页面记忆：进页面时若记得"上次是展开的"，就把它铺回去 —— 展开状态只活在 `isOpen` 里，
    /// 而 `viewWillDisappear` 会走 `closeEverything` 清掉它，不另记一笔重进必然是大封面。
    ///
    /// 门禁（缺一不可）：开关开着（`apply` 已判过，这里再判是为了 `reapply`）；记的是"展开"；
    /// **这一首有能画的东西**（`canShow`）—— 没词就保持大封面，别浪费 `openAndMount` 的重试窗口
    /// （与 `toggle` 同一条纪律）。
    static func reopenIfRemembered(in page: UIView) {
        guard isEnabled, UserDefaults.nowPlayingLyricsExpanded else { return }
        guard canShow(for: page) else {
            guard !didLogRememberedWithoutLyrics else { return }
            didLogRememberedWithoutLyrics = true
            writeDebugLog(
                "[\(logTag)] re-entering the player while the remembered state is"
                    + " \"expanded\", but this track has nothing to draw - staying on the cover"
            )
            return
        }
        writeDebugLog("[\(logTag)] re-entering the player expanded (remembered choice)")
        // 意图立刻立起来：这样从**这一帧**起，`coverDidLayOut` / `reconcile` 就会按住原生封面
        // 连带**寿命**一起立（见 `LyricsDoor.intentLifetime`）—— 意图不许再永久挂着。
        door.openIntent(at: CFAbsoluteTimeGetCurrent())
        openAndMount(in: page)
    }

    static var didLogRememberedWithoutLyrics = false

    /// 记下"用户上一次选的展开状态"。**只有用户点那枚键时才会调它** ——
    /// 离开页面 / 切歌 / 收起动画都不许动它（那正是"记忆"的含义）。
    static func rememberExpanded(_ expanded: Bool) {
        guard UserDefaults.nowPlayingLyricsExpanded != expanded else { return }
        UserDefaults.nowPlayingLyricsExpanded = expanded
        writeDebugLog(
            "[\(logTag)] remembering the player's lyrics state: "
                + (expanded ? "expanded (re-entering comes back here)" : "collapsed (re-entering starts from the cover)")
        )
    }

    /// 设置页切开关时叫一次。
    static func reapply() {
        guard let page = lastPage, page.window != nil else { return }
        apply(in: page)
    }

    /// 蹭 `DeclutterChrome` 的 0.3s 复查节拍：**展开期间**每拍把几何重新施加一遍
    /// （pw：`The geometry is re-applied on every layout pass of the units` —— 换歌会重建元素）。
    @discardableResult
    static func reconcile() -> Bool {
        guard isEnabled else { return false }
        // 这条节拍就是"每拍一次"的那个位置：查表缓存要跟着"哪一首歌"作废，
        // 放在这里比放在 `findByIdentifier` 里省 —— 那一拍能问它二十来次。
        noteTrackForLookups()

        // **收尾推迟到这一刻** —— 页面真的不在窗口里了。
        //
        // 顺序要紧：这一段必须在下面那个 `guard let page, page.window != nil` **之前**，
        // 否则页面一走那条 guard 就直接 return，我们永远等不到收尾（我们的层、被按住的封面、
        // 标题行的位移就全留在那一页上了）。
        guard let leavingPage = lastPage else { return false }
        if leavingPage.window == nil {
            // ⚠️ **这一段的条件必须把"我们写过的每一处"都算上** —— 包括写在**别人的视图或页面上**
            // 的那几处（封面缩放、歌手行的提供商、标题替身）。
            // 漏掉它们的后果很具体：页面走掉时该跑的那次收尾**整段被跳过** ⇒ 封面缩着不回、
            // 歌手行永远挂着「（NetEase）」、我们的替身留在那一页上。
            // 判据的**等价**写法见 `LyricsDoorRules.needsPageTeardown`
            // （`.closing` 覆盖 `pageLeaving`，`.open` / `.opening` 覆盖 `isLive || wantsOpen`）。
            let hasPendingEdits = bandShareButton != nil || closedTitleRow != nil
                || !scaledCoverBase.isEmpty || lastArtistSuffix != nil
                || titleRelay != nil
            guard LyricsDoorRules.needsPageTeardown(
                phase: doorPhase,
                isOpen: door.isOpen,
                hasPendingEdits: hasPendingEdits
            ) else { return false }
            // 页面已经不在屏幕上了 ⇒ 一次回滚（写回封面 / 撤销几何 / 摘掉我们的层与那枚键），
            // 而且什么都看不见。
            restoreAll(reason: "page disappeared", animated: false)
            return false
        }

        guard let page = lastPage else { return false }
        guard #available(iOS 26.0, *) else { return false }

        // 转场里（`viewWillDisappear` 已记一笔，但页面还在窗口里）⇒ **保持现状**：
        // 不写回封面、不撤销几何 —— 整个退出动画里页面都是我们的样子。
        if door.pageLeaving {
            ensureToggleZone(in: page)
            return door.isOpen
        }

        applyControlBand(in: page)
        // 大封面收成 242pt。**两个状态都摆**：
        // 换歌会换一个新的封面对象，旧的缩放跟着对象一起作废。
        applyCoverRestingScale(in: page)

        if door.isOpen {
            // 可能因为"封面还没布局好"铺不上 —— 那时退回去，并由 `openAndMount` 开重试窗口。
            openAndMount(in: page)
            // 不管上面成没成：只要我们的层还在，就**每拍**把当前那张主封面按掉
            // （换歌会换一个新的封面对象，见 `keepNativeCoverHidden`）。
            keepNativeCoverHidden(in: page)
            ensureToggleZone(in: page)
            // 展开态那一行也被移走了（缩略图右边）⇒ 同样点不到，替身一样要摆。
            applyTitleRelay(in: page)
            return door.isOpen
        }

        applyClosedTitleTransform(in: page)
        // （歌词提供商并没有在歌手的后面展示+"两个状态都显示"）：
        // 收起态也要把 `歌手（提供商）` 摆上 —— 以前只有"展开"那条路会贴，
        // 而用户平时看的就是收起这一屏。
        applyProviderToArtistLine(in: page)

        // 被移走的标题行**还能点**（点歌名/歌手跳专辑/歌手页）。
        applyTitleRelay(in: page)

        // **"打算铺但还没铺上"**的那段窗口里也要按住原生封面 ——
        // 否则进入播放器的转场里就是原生大封面在动（这一拍 `isOpen` 还是 false）。
        // 但这段窗口**必须过期** —— 按键换歌漏大封面就是它没过期
        // （见 `wantsOpenUntil` 的来龙去脉）。过期而这一路什么都没铺上 ⇒
        // **当场撤意图 + 把 Spotify 那张封面写回去**，绝不留"封面被按着、我们又没画"的永久空白。
        if wantsOpenNow() {
            keepNativeCoverHidden(in: page)
        } else if door.wantsOpen {
            door.expireIntent()
            restoreSpotifyCover()
            noteSkip("the open intent expired with nothing drawn - Spotify's cover is back")
        }

        // 顺手把那两颗胶囊认下来。**从这一页的子树里找**（按 id）——
        // 而页面自己这棵树只有几百个节点，一定够用）。认下来之后 `DeclutterChrome` 会一直盯着。
        DeclutterChrome.adoptNowPlayingPills(from: page)
        // 「**点开了但没铺上**」的重试（见 `pendingOpenUntil` 的说明）。
        // 没有这一段，
        // ⚠️ 重试**也要过门禁**：`openAndMount` 里没有 `canShow`，而换歌之后
        // "这一首有没有词"是会变的 —— 没词了就把窗口清掉，别拿一首没词的歌空转五拍。
        if door.retryWindowOpen(now: CFAbsoluteTimeGetCurrent()) {
            // `noticeText` 也算"有东西可画"（用户要的是键随时能按）——
            // 否则一首没词的歌在"第一拍量不到封面"之后就再也没人重试了。
            // ⚠️ 同一天又加了"没有时间轴 ⇒ 静态歌词"那一档 ⇒ 判据换成 `hasSomethingToShow`
            // （它把三档都算进来：有时间轴 / 静态歌词 / 一句说明）。
            if hasSomethingToShow() {
                openAndMount(in: page)
                // 按住原生封面这件事**跟着意图的寿命**走（见 `wantsOpenNow`）——
                // 意图过期 ⇒ 这一程本来就铺不上，那就别再把封面按着
                // （否则正是"我们自己制造一片空白"，用户报的漏封面就是这个味道）。
                // ⚠️ 铺成功那一拍 `coverHost` 已经在 ⇒ `wantsOpenNow` 仍为真，不受影响。
                if wantsOpenNow() { keepNativeCoverHidden(in: page) }
            } else {
                door.clearRetryWindow()
            }
            ensureToggleZone(in: page)
            return door.isOpen
        }
        // 半成品护栏：`isOpen` 是 `false`、但我们的封面/容器**还挂在屏上**
        // （某拍失败留下的）⇒ 也要继续按着原生封面，并接着试着铺回来。
        // 这一条正是那种"大封面回来了、我们的东西还压在上面"的兜底。
        if isAnythingLive {
            keepNativeCoverHidden(in: page)
            ensureToggleZone(in: page)
            return false
        }
        // 关着的时候只保证那枚键还在、还画得对（Spotify 换帧会重排 subviews），
        // 并**顺手把这一首的封面认下来**：点的时候就不用"现抓"，而现抓经常抓不到
        // （树里那张图可能是 `UIImageView(alpha=0.00)`）。幂等 —— 这一首已经认下就只查一次字典。
        rememberArtworkIfNeeded(in: page)
        ensureToggleZone(in: page)
        return false
    }

    /// **一次回滚**：把我们写在这个页面上的每一处都撤干净（别人的视图 + 我们自己的层）。
    ///
    /// 为什么要有它：那三条"当场收尾"的路（关开关 / 页面走掉 / 设置页关功能）若各抄一份收尾，
    /// 迟早只修一份（曾漏掉 `removeCreditLabel` ⇒ 署名留在树上）；合成一处后"我们写过什么"与
    /// "怎么还"只有一张账要对。⚠️ 顺序要紧：先收层（`closeEverything` 管封面 morph / 容器 /
    /// 标题 mask），再把写在**别人**视图上的位移逐个还回去。
    static func restoreAll(reason: String, animated: Bool) {
        closeEverything(reason: reason, animated: animated)
        // 我们自己的层与控件
        removeToggle()
        // 写在别人的视图 / 控件上的位移（撤销）
        clearControlBand()
        clearClosedTitleTransform()
        restoreCoverScale()
        // 我们自己的层与控件（续）
        removeTitleRelay()
        removeCreditLabel()
    }

    /// 立刻收掉：只服务两类"当场"的场合 —— 设置页把「歌词进播放器」**关掉**、以及 `reconcile`
    /// 判到"页面真的不在窗口里了"之后的收尾。退出转场那条路**不用它**（页面还在屏幕上，
    /// 当场收尾会闪出原生大封面，见 `pageWillLeave`）。
    ///
    /// ⚠️ **必须无条件走 `closeEverything`**（哪怕看起来"没展开"）：标题行的位移是我们用
    /// `transform` 写上去的，**不撤销就会留在 Spotify 的元素上**（那一行此后永远偏上一截）；
    /// 那枚键也要一起拿走 —— 否则下次进来会叠一枚在上面。
    static func remove(reason: String) {
        // 页面要走了 ⇒ **不动画**：拖着 0.45s 才把 Spotify 那条封面写回去，会在转场里露一个空档。
        restoreAll(reason: reason, animated: false)
    }

    /// 那枚"歌词键"被点了。
    static func toggle() {
        guard let page = lastPage, page.window != nil else { return }

        // ⚠️ 折叠的条件**不能只看 `isOpen`**：如果某一拍 `measure` 失败而屏幕上还挂着
        // 我们的封面（`isOpen` 已被回退），只看 `isOpen` 会让这一下变成"**再展开一次**"
        // ⇒ 用户**关不掉**（独立只读复核点出来的死角）。
        // "屏幕上有我们的东西"与 `closeEverything` 的守卫用的是同一组判据。
        if door.isOpen || isAnythingLive {
            // 自己点收起 ⇒ **放动画**（封面"飞回原位"）。
            closeEverything(reason: "tapped", animated: true)
            // **用户这一下就是"记忆"** —— 下次进播放器还是大封面。
            rememberExpanded(false)
            // 图标当场换回"歌词"，不等 0.5s 的复查节拍。
            ensureToggleZone(in: page)
            return
        }
        guard canShow(for: page) else {
            // ⚠️ 这里**不许**说成"这首歌没有可用的歌词"：`canShow` 自己已经把**真正的原因**
            // 写进日志了（关着的开关 / 没有可画的东西），再补一句笼统的会把原因盖掉。
            // （歌词按钮点不动那条）：以前这里写的就是那句笼统的话，
            // 而真正的原因往往在上面一行 —— 两条一起看才不误导。
            noteSkip("the lyrics button was tapped but our layer cannot open (see the reason above)")
            // ⚠️ 用户刚被告知"这首没词" ⇒ 把可能还挂着的重试窗口**清掉**，
            // 别让下一拍拿同一首歌再空转五回。
            door.clearRetryWindow()
            ensureToggleZone(in: page)
            return
        }
        // 铺不上就当场认输（`noteSkip` 已经写清了原因），别把开关停在"展开但什么都没变"上。
        // ⚠️ 但**不认死** —— `openAndMount` 会顺手开一个 2.5s 的重试窗口。
        // **先记"用户要展开"**，再铺。这样即便第一拍量不到（2.5s 重试窗口接手），
        // 下次进页面也还是"记得要展开"——记忆跟的是**用户的意图**，不是这一拍的成功与否。
        // `wantsOpen` 同时把"按住原生封面"提前到这一帧。
        rememberExpanded(true)
        // 意图带寿命（见 `LyricsDoor.intentLifetime`）—— 铺不上就让它过期，
        // 别让"大封面被永久按住"变成的那件事。
        door.openIntent(at: CFAbsoluteTimeGetCurrent())
        openAndMount(in: page)
        // ⚠️ 必须在铺完之后再摆一次：容器会 `bringSubviewToFront`，键会被压到它下面。
        ensureToggleZone(in: page)
    }

    /// 「屏幕上真的有我们的东西」——**这一条判据只留一份**。
    ///
    /// 它原来在七八处各写一遍（`apply` 的残留守卫 / `reconcile` 的收尾守卫与半成品护栏 /
    /// `coverDidLayOut` 的门禁 / `openAndMount` 的 `wasLive` / `closeEverything` 的
    /// `hadSomethingVisible` / `toggle` 的折叠判据），每修一次回归就多 OR 一个旗标。
    static var isAnythingLive: Bool { coverHost != nil || lastContainer != nil }

    /// 这一拍处在哪一相（关 / 展开中 / 开 / 收起中）。
    ///
    /// 规则全在 `LyricsDoorRules` 里（**纯逻辑、有单测、CI 每次 push 都跑**，见
    /// `Appearance/LyricsDoorPhase.swift` 与 `Tests/LyricsDoorPhase`）；本文件只负责把 UI 事实喂进去。
    static var doorPhase: LyricsDoorPhase {
        door.phase(isLive: isAnythingLive)
    }

    /// 「我们打算铺着」这个意图**现在还作数吗**（见 `wantsOpenUntil`）。
    ///
    /// 过了窗口又什么都没铺上 ⇒ `false`，**调用方负责撤意图并把封面写回去**（别在这里写状态，
    /// 因为 `coverDidLayOut` 也会问它，而那个回调是别人的 `layoutSubviews`）。
    static func wantsOpenNow() -> Bool {
        door.intentStillValid(now: CFAbsoluteTimeGetCurrent(), isLive: isAnythingLive)
    }

    /// 只要我们的层还在屏幕上，就**每一拍**把 Spotify 当前那张主封面按掉。
    ///
    /// 为什么必须独立、而且**无条件**（不能挂在任何门后面）：换歌时 Spotify 会换成**新的那一个
    /// 对象**，我们藏过的是**旧对象** ⇒ 新封面整张露出来，而我们的缩略图 / 上移的标题 / 歌词还
    /// 挂着；一旦这一步排在"这一首有没有词"那道门**后面**，门一失败就 return，**再没有人藏封面**。
    @discardableResult
    static func keepNativeCoverHidden(in page: UIView) -> Bool {
        guard let list = findByIdentifier(listIdentifier, in: page),
              let source = visibleCover(in: list, page: page) else { return false }
        hideSpotifyCover(source)
        return true
    }

    // ⛔ **不许再对 Spotify 那几个"歌词入口"下手**（`lyrics-expand-button` / `lyrics-share-button` /
    // `lyrics-translations-button`）。屏幕上的「歌词 · 分享 · 全屏」那一行是**我们自己画的**
    // （`AppleMusicLyricsOverlayView.previewHeader`），藏原生那批屏幕上什么都不会变；而原生那三颗
    // 所在的卡被「一屏」折成 0 高、本来就不在屏上。更糟的是从那儿往上找"够宽的祖先"会落到
    // **整张歌词卡的根**，那一层正是我们自己预览歌词的宿主 ⇒ 会把我们自己的东西一起藏掉。
    // 真正要消失的那一行，去改**我们自己**的画法（`AppleMusicLyricsOverlayView.showsPreviewHeader`）。
    //
    // **封面自己布局的那一刻**：展开时按住它，收起时**当场缩到 242pt**。
    //
    // 为什么不复用 `keepNativeCoverHidden`：那条要在整棵树里**再找一遍**哪张是当前封面，而换歌那一
    // 瞬间**必然失手**（新封面 `alpha` 还是 0 ⇒ 挑中的是**上一张**，按掉旧对象、新封面整张露着）。
    // pw 的办法是**不搜索**：门禁一过就按掉"**和 tilt 等大的那个直接子视图**" —— 局部、无竞态，
    // 也不依赖"哪一张现在可见"。
    // ⇒ 门禁：开关开 + **我们确实铺着** + tilt 在窗口里且够大 + 祖先里有 `CoverArtCellImpl`
    // （最后这条把迷你条 / 卡片里那些 tilt 一次滤掉）。**不做节流**：动作是局部的（比走查便宜
    // 一个量级），而节流正是"闪一下"的来源。
    //
    // （听歌的时候，会有 Spotify 大封面闪过）：原来这条只在**展开**时
    // 动作；**收起态**（默认那一档）的 242pt 缩放只由 0.3s 复查节拍做 —— 换歌时新封面先是
    // 366pt，下一拍才变小 ⇒ 那 0~0.3s 就是"大封面闪一下"。现在收起态也走这条事件：
    // 封面自己一布局就缩（与节拍共用 `applyRestingScale` 的记账与还原）。
    static func coverDidLayOut(from tilt: UIView) {
        guard isEnabled, #available(iOS 26.0, *) else { return }
        let shouldHold = LyricsDoorRules.shouldHoldNativeCover(
            isOpen: door.isOpen,
            isLive: isAnythingLive,
            intentValid: wantsOpenNow()
        )
        guard !door.pageLeaving else { return }
        // 门禁没过时只有"该按住"那一档才计数：收起态的封面常常还没进树（`alpha=0` /
        // 大图还没挂上），那不是"守卫失效"，别把排查计数污染成假报警。
        func reject() {
            if shouldHold { noteCoverGuardReject() }
        }
        guard tilt.window != nil, tilt.bounds.width >= 200 else { return reject() }
        guard isInsideCoverCell(tilt) else { return reject() }
        guard lastPage?.window != nil else { return reject() }

        if shouldHold {
            // （播放页**还是**闪 Spotify 原生封面）：
            // 旧门禁要求 `cover.alpha > 0.01`，可换歌那一瞬新封面对象**常常先以 alpha = 0
            // 出现**，等 Spotify 把它淡入时**没有新的 layout 回调** ⇒ 这一帧被放过去，
            // 要等 0.3s 节拍才按掉 = 一次"大封面闪一下"。
            // 现在两件事一起做：
            // ① 不再要求 alpha（`hideCoverView` 按对象记账，还原时写回它自己的原值，
            // 所以对 alpha=0 的对象动手也不会把别人的值改坏）；
            // ② **连 `tilt` 本身也按下去** —— 之后 Spotify 在同一份 tilt 里换图 / 加层
            // 都不会再露出来。我们那张宿主盖在同一块位置上，画面上不会出现空洞。
            if let cover = sameSizeChild(of: tilt) { hideSpotifyCover(cover) }
            // 封面 tilt 的"正常可见"就是 1：换歌转场里它可能先以 0 出现，还原时写 1（不是 0），
            // 否则离开播放页之后那张原生封面会永久停在透明。
            hideCoverView(tilt, restoringTo: 1)

            coverLocalHides += 1
            guard coverLocalHides == 1 || coverLocalHides % 20 == 0 else { return }
            writeDebugLog(
                "[\(logTag)] hid the native cover from its own tilt (local path) — hide #\(coverLocalHides),"
                    + " \(coverLocalRejects) gate rejection(s) so far"
            )
            return
        }

        // 收起态：和节拍那条**缩同一张对象**（`Encore.ImageView`，不是外面那层壳），
        // 否则会双重缩放（242/366 叠两次）。
        //
        // （切歌过程中会有 Spotify 原生封面闪过）：
        // 上一版要求"`sameSizeChild` 是第一层、且里面那张已经是 ≥200pt"，可换歌那一瞬间
        // 新封面常常**还没布局完**
        // ⇒ 条件一挡就什么都不做，要等 0.3s 的节拍才缩成 242pt，的就是一张大封面。
        // 现在从 **tilt 自己**往下找那张图（不要求等大小的直接子视图），也不要求它已经够宽；
        // `applyRestingScale` 会按对象记账，等它真的有尺寸了节拍那条也会接着用同一份底值。
        guard let imageView = findByIdentifier(coverImageIdentifier, in: tilt) else { return }
        applyRestingScale(to: imageView)
    }

    /// 门禁没过的计数 + 一次总结。
    ///
    /// `[CoverGuard] armed on …`（装没装），却分不清"tilt 从来没布局过"与"布局了但门禁一直不过"。
    /// 后面那条正是复发时最需要知道的事。
    static var coverLocalHides = 0
    static var coverLocalRejects = 0
    static var reportedCoverGuardReject = false
    static let coverGuardRejectReportAfter = 60

    static func noteCoverGuardReject() {
        coverLocalRejects += 1
        guard !reportedCoverGuardReject, coverLocalRejects >= coverGuardRejectReportAfter else { return }
        reportedCoverGuardReject = true
        writeDebugLog(
            "[\(logTag)] the cover-tilt guard rejected \(coverLocalRejects) layout(s) and never hid anything"
                + " — check the gates (window / width / CoverArtCellImpl ancestor / same-size child)"
        )
    }

    /// pw 的 `inCoverCell(tilt)`：祖先里有 `NowPlaying_ContentLayersImpl.CoverArtCellImpl`。
    ///
    /// 为什么认这个类：contentlayer 里**真正的封面**住在 `CoverArtCellImpl` 这个 cell 里，而迷你条、
    /// 列表卡片里那些 tilt 不在其内 ⇒ 一条判据同时解决"是哪张"与"要不要管"。
    ///
    /// ⚠️ 用 **`isKind(of:)`（= pw 的 `isKindOfClass:`）而不是比较类名字符串**：字符串比较只在**恰好**
    /// 是那个类时成立，Spotify 一旦派生子类就静默失效。走查有界（8 跳），拿不到就放弃（宁可漏，不可误伤）。
    static func isInsideCoverCell(_ tilt: UIView) -> Bool {
        var node: UIView? = tilt.superview
        var hops = 0
        while let current = node, hops < 8 {
            if let cls = coverCellClass, current.isKind(of: cls) { return true }
            // 类名兜底（覆盖 Swift 改版 / 名字长度变了的情况）。
            // 只在 `isKind(of:)` 没命中时走，而且有界（8 跳以内）。
            if NSStringFromClass(type(of: current)).contains("CoverArtCellImpl") { return true }
            node = current.superview
            hops += 1
        }
        return false
    }

    /// 只查**一个**类（不是运行时类枚举，本仓库纪律 1）。
    ///
    /// **一次都没有**）：Swift 类在 ObjC 运行时里的名字是 **mangled** 的
    /// （`_TtC28NowPlaying_ContentLayersImpl16CoverArtCellImpl`），`NSClassFromString` 用
    /// `Module.Class` 那种写法取不到 ⇒ `coverCellClass` 为 nil ⇒ `isInsideCoverCell` 恒假
    /// ⇒ 事件驱动那条路**每次都拒绝**，只剩 0.3s 节拍兜底 = 换歌时"原生封面闪一下"。
    /// 先按 Swift 名试（将来若支持），再按 dump 里的 mangled 名取。
    static let coverCellClass: AnyClass? = {
        if let cls = NSClassFromString("NowPlaying_ContentLayersImpl.CoverArtCellImpl") {
            return cls
        }
        return NSClassFromString("_TtC28NowPlaying_ContentLayersImpl16CoverArtCellImpl")
    }()

    /// pw 的 `coverIn(tilt)`：**和 tilt 等大的那个直接子视图**就是封面
    /// （`CoverArtTiltView 354x354 > 一个同样大小的 ElementView > ImageViewProxy >
    /// `Encore.ImageView` > 真正画图的 `UIImageView`，见 pw 那份 `PlayerArtwork.x` 的树注）。
    ///
    /// ⚠️ 用 `bounds` 比大小，不用 `frame`：tilt 被 inspect 手势转过时 `frame` 会变、`bounds` 不变
    /// （pw 同款注释，也是本仓库规矩 8）。
    static func sameSizeChild(of tilt: UIView) -> UIView? {
        for sub in tilt.subviews where CGSizeEqualToSize(sub.bounds.size, tilt.bounds.size) {
            return sub
        }
        return nil
    }

    /// 铺一次；失败就退回"未展开"并**开重试窗口**。
    ///
    /// 所有"要展开"的入口都走这里（`apply` / `reconcile` / `toggle`）—— 免得像旧代码那样，
    /// 只有 `toggle` 那一条路会因为**一次**失败而永久认死。
    @discardableResult
    static func openAndMount(in page: UIView) -> Bool {
        // 「屏幕上已经有我们的东西」时，这次量不到**不许改意图**。
        // 否则会出现独立只读复核点出来的那个死角：歌词明明还开着、而 `isOpen` 已经是
        // `false` ⇒ 用户再点走的是"展开"那一支 ⇒ **关不掉**。
        // 这种情况下保持 `isOpen = true`，让 `reconcile` 的 `isOpen` 那一支每拍接着试。
        let wasLive = isAnythingLive

        door.isOpen = true
        if layoutAndMount(in: page) {
            door.clearRetryWindow()
            return true
        }
        if wasLive {
            door.clearRetryWindow()
            return false
        }
        door.isOpen = false

        // ⚠️ **只武装一次**，不往后推（`armRetryWindowIfNeeded` 自己就是这条纪律）。
        //
        // 第一版这里是无条件 `retryUntil = now + window`，而 `reconcile` 每 ~0.5s 就会再进来一次
        // ⇒ 每次失败都把 deadline 推远 ⇒ 这个"2.5s 窗口"**永远不会到期**，等于在听歌页上无限轮询。
        // 真正想要的是"**从第一次失败起** 2.5s ≈ 5 拍"。
        door.armRetryWindowIfNeeded(at: CFAbsoluteTimeGetCurrent())
        return false
    }
}
