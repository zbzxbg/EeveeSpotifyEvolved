// 逐字歌词层的挂载管理：把 `AppleMusicLyricsOverlayHost` 的层挂到「内嵌预览卡片」或
// 「全屏歌词页」这两个宿主上，并在切歌 / 数据到达 / 全屏关闭时把它挪到正确的位置。
//
// 关键约束：
// · 一个 overlay 视图同时只能挂在一个宿主上，所以关闭全屏时先用静态替身顶住画面；
// · 挂载标记（`isAttached` / `attachedShowsProviderFooter`）是纯布尔，必须配
// `clearStaleAttachmentIfNeeded` 自愈，否则标记残留会让预览层再也挂不回来；
// · 预览只许挂在卡片上，挂到整页就是「预览变全屏」—— 判不准时宁可这一轮不挂。
import Orion
import UIKit
import ObjectiveC
import SwiftUI

// MARK: - 挂载管理
//
// `@MainActor`：整个挂载链路只碰 UIKit（往 VC 的视图上挂 overlay），而调用点
// （VC 的 viewDidAppear / SwiftUI 手势）本来都在主线程。标出来是为了让
// `AppleMusicLyricsOverlayHost` 这个同样 main-actor 隔离的单例能被合法调用 ——
// 否则就是"在非隔离同步上下文调用 MainActor 隔离的方法"。
@MainActor
final class WordByWordHost {
    static let shared = WordByWordHost()

    private var overlay: LyricsWordByWordOverlayView?
    private weak var hostView: UIView?
    private var isAttached = false
    /// 已经渲染进 overlay 的歌词版本号。
    /// 切歌时 `currentLyricsVersion` 会递增，用它区分「宿主没变但内容换了」——
    /// 否则会被下面的提前返回挡住，画面停在上一次的歌词（症状：第二首显示第一首）。
    private var renderedLyricsVersion: Int = -1
    /// 当前这次挂载是不是"全屏页"（showsProviderFooter == true）。
    /// `refreshForCurrentLyrics` 据此避免在全屏时抢走宿主。
    private var attachedShowsProviderFooter = false
    /// 记住内嵌预览的宿主（VC + 命中的歌词视图），供歌词到达后重挂。
    private weak var lastPreviewController: UIViewController?
    private weak var lastPreviewContentView: UIView?
    /// 最近出现的内嵌歌词 VC（弱引用），全屏关闭后据此重新挂载。
    private weak var lastInlineController: UIViewController?
    /// 最近一次"全屏页"挂载用的 VC 与左边距（弱引用 + 参数）。
    ///
    /// 全屏页在整段停留期间宿主不会重建，所以这个引用一直有效。它的用途是补一种
    /// 罕见的断档：新层会因为"当前这首歌没有逐词数据"而把自己摘掉
    /// （`AppleMusicLyricsOverlayHost.update` 在行模型为空时 `detach`），
    /// 而全屏页的 appear 回调**不会再来第二次** —— 没有这个锚点，下一首有逐词数据时
    /// 就没人能把层挂回去，页面会一直停在 Spotify 原生歌词上。
    private weak var fullscreenController: UIViewController?
    private var fullscreenSideInset: CGFloat = 24
    /// 关闭全屏时留在原宿主上的静态替身（见 `handOffToInlineKeepingStandIn`）。
    private var transitionStandInView: UIView?

    func rememberInlineController(_ controller: UIViewController) {
        lastInlineController = controller
    }

    /// 内嵌（预览）层是否**已经挂上、而且还在窗口里**。
    ///
    /// 给 `InlineLyricsHostLocator` 的看门狗用：预览歌词卡片是自适应表格 cell
    /// （`Lyrics_TextElementImpl.LyricsCell` + `SelfSizingTableView`），滚动、换行、
    /// 换歌时都会被复用重建 —— 我们的层挂在卡片上，卡片一被销毁层就跟着没了，
    /// 看门狗据此重新查找宿主。
    var inlineOverlayIsLive: Bool {
        guard isAttached, !attachedShowsProviderFooter else { return false }
        if #available(iOS 26.0, *), let view = AppleMusicLyricsOverlayHost.shared.overlayView {
            return view.superview != nil && view.window != nil
        }
        guard let overlay else { return false }
        return overlay.superview != nil && overlay.window != nil
    }

    /// 全屏层是否正挂在屏上。
    ///
    /// 同上看门狗：全屏页是盖在内嵌页之上的 sheet，内嵌页的 `viewWillAppear`
    /// 不会重来，看门狗一直在跑；**没有这道闸门它会把全屏的层拽回卡片**。
    ///
    /// 这是**纯布尔**判据，所以必须配 `clearStaleAttachmentIfNeeded` 一起用：
    /// 标记只有在**我们自己**调 `detach` 时才会清，全屏页被系统 / Spotify 拆掉而
    /// 那条 `viewWillDisappear` 没走到时，标记会残留成「全屏还挂着」→ 闸门永久挡住
    /// 预览层的重挂。自愈那一半见下面那个方法。
    var fullscreenOverlayIsAttached: Bool {
        isAttached && attachedShowsProviderFooter
    }

    /// 我们这层**真的在窗口里**吗。
    ///
    /// **两处必须共用这一个属性**：`clearStaleAttachmentIfNeeded`（残留自愈）
    /// 与 `attach` 里那条「已经挂好了」的短路。拆成两份实现就会各说各话 ——
    /// 一边判「同宿主同版本、跳过挂载」，另一边判「层不在任何窗口里、清掉标记」，
    /// 两边互相打架，结果一轮都没挂上。
    var overlayIsLive: Bool {
        // 新旧两层都要看：`detach` 是**两层一起清**（AM host + 旧 overlay），
        // 所以这里也必须是"任一层还活着就算活着"，否则一方残留会让判据永远为假。
        if #available(iOS 26.0, *),
           let view = AppleMusicLyricsOverlayHost.shared.overlayView,
           view.superview != nil, view.window != nil {
            return true
        }
        if let overlay, overlay.superview != nil, overlay.window != nil {
            return true
        }
        return false
    }

    /// 挂载标记自愈：**标记说挂着、但那一层其实已经不在任何窗口里**时清掉它。
    ///
    /// 为什么必须有：全屏里点几下歌词行再退出，之后**预览一直退化成逐行、切到别的歌
    /// 也一样**，只有重启才恢复。机制就是这里的标记残留 —— `isAttached` /
    /// `attachedShowsProviderFooter` 是纯布尔，`detach` 没被调用（全屏 VC 被拆掉 /
    /// `viewWillDisappear` 没赶上 / 层被系统收走）就永远为真，而看门狗第一道闸门正是
    /// `guard !fullscreenOverlayIsAttached else { return }`，于是预览层再也挂不回来。
    ///
    /// 判据与 `inlineOverlayIsLive` **完全同源**（视图必须还在窗口里），所以不会误伤
    /// 「真的全屏中」的情况；实现走 `overlayIsLive`，别再抄一份。
    func clearStaleAttachmentIfNeeded() {
        guard isAttached else { return }
        guard !overlayIsLive else { return }

        writeDebugLog(
            "[WordByWord] stale attachment cleared — the layer is not in any window"
                + " (wasFullscreen=\(attachedShowsProviderFooter))"
        )
        // `clearForUnavailableLyrics` = detach + 作废 `renderedLyricsVersion`，
        // 正是"层没了、下次重挂一定要成立"需要的那两件事。
        clearForUnavailableLyrics()
    }

    /// 这一首**没有**我们的歌词了（取词失败 / 用户选了原生歌词）时调用：
    /// 把已经挂上的层摘掉，并把"宿主已经渲染到哪个版本"也一并作废。
    ///
    /// 为什么不只是 `detach`：`renderedLyricsVersion` 留着的话，下次
    /// `attach` 会以为"这个宿主上已经是当前版本了"而提前返回 —— 而实际上
    /// 层已经被摘掉，屏幕上是空的（原生歌词）。作废之后重新挂就一定成立。
    func clearForUnavailableLyrics() {
        detach()
        renderedLyricsVersion = -1
    }

    /// 关闭全屏后把 overlay 交还内嵌（预览）。
    func reattachToInline() {
        // 必须用**上次预览的挂载点**（卡片里的歌词视图），不能用
        // `lastInlineController.view` —— 那是正在播放页的根视图：`cardContainer(for:)`
        // 在它身上找不到卡片，于是退回「整页」，我们的卡片背景铺满整个正在播放页。
        // 这就是「退出全屏后预览变全屏」。
        if let controller = lastPreviewController,
           let contentView = lastPreviewContentView,
           attach(to: controller, contentView: contentView, showsTranslation: false) {
            return
        }
        if let controller = lastInlineController,
           attach(to: controller, showsTranslation: false) {
            return
        }
        // 两个宿主都没挂上（记的是整页大小 / 卡片还没建 / 已经被重建）→
        // 让看门狗重新查找宿主（它会避开整页、只认卡片）。
        InlineLyricsHostLocator.retryLookupIfNeeded()
    }

    /// 当前 dto 是不是**别的**曲目的（切歌但没来歌词请求时会发生）。
    ///
    /// 与旧层 `LyricsWordByWordOverlayView.belongsToAnotherTrack` 同一判据，
    /// 详见文件顶部 `currentLyricsDtoTrackId` 的说明。
    var lineModelIsForeign: Bool {
        let model = currentLyricsDtoTrackId
        let live = statefulPlayer?.currentTrack()?.trackIdentifier ?? ""
        guard !model.isEmpty, !live.isEmpty else { return false }
        return model != live
    }

    /// 歌词数据到达后调用一次：把 overlay 重挂到**当前这首歌**的数据上。
    ///
    /// 为什么需要它：`attach` 只由宿主出现触发（`viewWillAppear` 等），而内嵌宿主是 NPV ——
    /// **NPV 只在「进入正在播放页」时出现一次，切歌不会再来**，所以「挂载早于数据到达」
    /// 和「切歌后不刷新」这两件事都没有第二次机会。
    ///
    /// 全屏页不抢它的宿主：只在**同一个**全屏 VC 上刷新行模型（必要时补挂一次），
    /// 绝不把全屏的层挪回卡片。
    func refreshForCurrentLyrics() {
        guard renderEnabled else { return }

        // 全屏层自己会跟着版本号刷新（Apple Music 层是"就地更新行模型"，
        // 见 `AppleMusicLyricsOverlayHost.update`），但**必须有人去叫它** ——
        // 切歌时它挂在同一个宿主上、`attach` 的提前返回不会放行，
        // 不主动刷就会一直显示上一首的歌词。
        if isAttached && attachedShowsProviderFooter {
            if #available(iOS 26.0, *) {
                // 新层可能已经因为"当前这首歌没有逐词数据"而自己摘掉了
                // （`AppleMusicLyricsOverlayHost.update` 在行模型为空时 `detach`）。
                // 那时 `refreshLinesIfNeeded` 的 guard 会直接返回，而全屏页的
                // appear 回调不会再来 —— 新歌词就永远推不进去。所以这里要能补挂一次。
                if NgzhwmSettingsViewModel.isBetterWordByWordLyricsEnabled,
                   hasUsableWordLevelData(currentLyricsDto),
                   AppleMusicLyricsOverlayHost.shared.overlayView == nil,
                   let controller = fullscreenController {
                    writeDebugLog("[WordByWord] fullscreen layer was dropped — reattaching")
                    attach(
                        to: controller,
                        sideInset: fullscreenSideInset,
                        showsProviderFooter: true
                    )
                    return
                }
                AppleMusicLyricsOverlayHost.shared.refreshLinesIfNeeded()
            }
            return
        }

        // 行模型属于**别的**曲目（切歌但没来歌词请求，见 `currentLyricsDtoTrackId`）
        // → 一个挂载点都别试：挂上去画的就是上一首的歌词。
        // 真正的歌词到达时版本号会变，这条判据自然为假，届时会重挂。
        guard !lineModelIsForeign else {
            Self.logRejectionThrottled(
                "[WordByWord] line model belongs to another track — not attaching"
                    + " (model=\(currentLyricsDtoTrackId))"
            )
            if isAttached { detach() }
            return
        }

        // 只有逐词的歌才由我们渲染（产品规则写在 `attach` 那道 guard 上）——
        // 没有逐词就整首交还 Spotify 原生，这里直接收工：省掉下面两次注定被拒的挂载尝试，
        // 也顺手把"从有逐词切到只有逐行"时还挂在屏上的旧层摘掉。
        //
        // 必须放在上面 AM 分支**之后**：那一段是全屏层「被丢掉后补挂 / 就地更新行模型」
        // 的必经路，提前返回会让 AM 层在切到只有逐行的歌时留在屏上。
        //
        // 这里仍然打一条日志（节流 10s）：这一层「什么都不做」是最容易被误判成
        // 「歌词模块挂了」的状态，
        guard hasUsableWordLevelData(currentLyricsDto) else {
            Self.logRejectionThrottled(
                "[WordByWord] handing back to Spotify's native lyrics page/card"
                    + " — no word-level timing (line-level usable="
                    + "\(hasUsableLineLevelData(currentLyricsDto)))"
            )
            if isAttached { detach() }
            return
        }

        // 全屏页**开着**、但我们的层没挂上 —— 必须挂回**全屏**，不能按预览处理。
        //
        // 成因（小概率出现「全屏是逐行 + 专辑色背景」）：全屏页出现时歌词还在路上
        // （PL 这种两次请求的源更容易撞上），`viewWillAppear` / `viewDidAppear` 两次
        // `attach` 都因为「行级数据都还没有」落空；等歌词到达时，上面的
        // `isAttached && attachedShowsProviderFooter` 判据为假 → 代码会掉进下面的
        // **预览**分支，把层挂到全屏底下的卡片上 —— 于是全屏整场都停在原生逐行。
        //
        // 判据不用新增状态：`fullscreenController` 是弱引用，且**在函数开头就记好了**
        // （那时还没有数据判据），所以「它还在窗口里、且不在消失中」就等于「全屏开着」。
        if !isAttached,
           let controller = fullscreenController,
           controller.isViewLoaded,
           controller.view.window != nil,
           !controller.isBeingDismissed,
           !controller.isMovingFromParent {
            writeDebugLog("[WordByWord] fullscreen is open but our layer is missing — attaching there")
            if attach(
                to: controller,
                sideInset: fullscreenSideInset,
                showsProviderFooter: true
            ) {
                return
            }
        }

        // 预览层：歌词比卡片先到是常态（卡片要等数据才建），所以这里**不能**
        // 因为"还没记住宿主"就放弃 —— 那正是"预览逐词几乎不挂载"的原因。
        if let controller = lastPreviewController,
           let contentView = lastPreviewContentView {
            writeDebugLog("[WordByWord] refresh for current lyrics (version \(currentLyricsVersion))")
            if attach(to: controller, contentView: contentView, showsTranslation: false) {
                return
            }
        }

        // 没挂上（没记住宿主 / 记的宿主被拒 —— 例如它落在封面容器里）→
        // 让看门狗立刻重新查找宿主，别等下一个 1.5s 心跳。
        InlineLyricsHostLocator.retryLookupIfNeeded()
    }

    private var renderEnabled: Bool {
        NgzhwmSettingsViewModel.isWordByWordLyricsEnabled
    }

    /// contentView: overlay 挂到哪个视图（默认 VC 的 view）。
    /// sideInset: 覆盖层歌词行的左右边距（全屏可用更大值，默认用 overlay 自己的）。
    /// showsProviderFooter: 是否在底部显示「歌词提供者」（全屏显示，内嵌不显示）。
    /// showsTranslation: 是否显示行级译文（全屏显示；内嵌「预览歌词」不显示）。
    ///
    /// 这里曾经还有一个 `keepAboveView`（把原生 header 抬到 overlay 之上）。
    /// 已删除：它依赖"原生控件是本视图的直接子视图"这个**不成立**的假设，
    /// 而且取 header 用的 `Ivars` 在 Modern 全屏页上会命中不存在的 ivar（崩）。
    /// 旧 overlay 的显隐现在完全由"有没有逐词数据"决定，不需要它。
    ///
    /// - Returns: 这一层现在是不是**挂着的**。调用方（`refreshForCurrentLyrics` /
    /// `reattachToInline`）据此决定要不要让看门狗立刻重找宿主 ——
    /// 预览场景里有几条"宁可不挂"的判据（没有卡片证据 / 整页大小），
    /// 那几种情况下"再挂一次"是白费力气，必须换宿主。
    @discardableResult
    func attach(
        to controller: UIViewController,
        contentView: UIView? = nil,
        sideInset: CGFloat? = nil,
        showsProviderFooter: Bool = false,
        showsTranslation: Bool = true
    ) -> Bool {
        // 这次 attach 为什么没挂上。
        //
        // 用 `defer` **兜底**，而不是在每个 `return false` 前面各写一行日志：
        // 这个函数有六七处放弃出口（含以后新加的），靠「记得每处都补一行」必然会漏。
        // 这里一次性保证「任何 return false 都带原因」，新加出口最差只会显示
        // 「（未记录原因）」，不会又变成静默。成功返回时 `didAttach` 被置 true，不打印。
        var exitReason = "(reason not recorded)"
        var didAttach = false
        defer {
            if !didAttach {
                Self.logAttachRejection(exitReason, controller: controller)
            }
        }

        guard renderEnabled else {
            exitReason = "word-by-word lyrics disabled (renderEnabled=false)"
            return false
        }
        let view = contentView ?? controller.view
        guard let view else {
            exitReason = "controller.view is nil"
            return false
        }

        // ── 先把「内嵌预览的宿主」记下来，**早于任何数据判据**
        //
        // 这一步是「预览逐词几乎不挂载」的关键。内嵌宿主只在进入正在播放页时
        // 出现一次（NPV 的 `viewWillAppear`），而那一刻歌词往往还在路上 ——
        // 于是 `usable == false`，函数直接返回。这两条记忆以前写在函数末尾的
        // AppleMusic 分支里，结果就是「数据没到 → 什么都没记住」，
        // 等歌词到达时 `refreshForCurrentLyrics` 找不到宿主，只能放弃。
        //
        // 现在无论数据到没到、走新层还是旧层，宿主都先记下来。
        // 只记「不是整页大小」的内容视图：整页根本不是卡片里的歌词视图，
        // 记下来只会在下次 `attach` 时把层铺满整页（预览变全屏）。
        if !showsProviderFooter {
            lastInlineController = controller
            if !Self.isPageSized(view) {
                lastPreviewController = controller
                lastPreviewContentView = view
            }
        } else {
            // 全屏页：记住锚点与参数，供"层被摘掉之后的下一次刷新"重新挂载。
            fullscreenController = controller
            fullscreenSideInset = sideInset ?? 24
        }

        // 已挂在同一视图上、**且渲染的就是当前这首的歌词**时才算完成；
        // 宿主没变但歌词换了（切歌）也要重新走一遍 —— 下面紧接着就是 detach + 重挂。
        //
        // 这条版本判据补的是一个隐含前提：内嵌触发点是 NPV 宿主，而 NPV 只在进入页面时
        // 出现一次，切歌不会再来，于是必须靠这里显式判断版本。
        // 判据里**必须**带 `overlayIsLive` —— 只有「标记说挂着」**且**「层真的还在窗口里」
        // 才算已经挂好。否则一层被系统收走 / 被复用 cell 带走之后，这条短路会把重挂
        // 永久挡掉，而自愈逻辑同时又把标记清掉，两边互相打架。
        if isAttached, hostView === view, renderedLyricsVersion == currentLyricsVersion,
           overlayIsLive {
            // 这条是**成功**的提前返回（层已经挂对地方、渲染的就是当前这首），
            // 不是放弃。所以也记一笔 ——
            // 排查"切歌了但层没重建"时，这行能直接证明是它挡的。
            Self.logRejectionThrottled(
                "[WordByWord] attach skipped — already mounted on the same host at the same version"
                    + " (version \(currentLyricsVersion))"
                    + " | host=\(NSStringFromClass(type(of: view)))"
            )
            didAttach = true
            return true
        }
        detach()

        let sideInset = sideInset ?? 16
        // 这两个值的作用是**分开**的，别再合回去：
        // · `usable`（逐词）—— 决定**要不要挂我们这一层**（见下面那道 guard）；
        // · `lineLevelUsable`（逐行）—— 只用来记账：说明「这份数据为什么没有逐词」，
        let usable = hasUsableWordLevelData(currentLyricsDto)
        let lineLevelUsable = hasUsableLineLevelData(currentLyricsDto)

        // 系统版本够、开关打开、数据可用 → 走 Apple Music 渲染层。
        //
        // 这里**必须**保留「更好的逐词歌词」这一条判据：
        // 两条路是**两套歌词渲染**（高亮/闪烁/译文处理都不同），用户要的只是
        // 「壳的观感一致」，不是「把歌词也换掉」。
        //
        // 判据是**逐词**（`usable`），不是「只要有行级就行」 —— 这是**产品规则**：
        // · 「更好的逐词歌词」开 **且** 来源给了逐词数据 → AM 渲染 + 透明化专辑底；
        // · 逐词 + AM 关 → 旧层 + **Spotify 自己的默认颜色**；
        // · 只有逐行 → 两条路都不走，整首交还 Spotify 原生（见下面那道 guard）。
        // 放宽成 `lineLevelUsable` 会让逐行歌词也套上 AM 的底。**别再放宽。**
        if #available(iOS 26.0, *),
           usable,
           NgzhwmSettingsViewModel.isBetterWordByWordLyricsEnabled {
            // 这里**不碰任何原生视图**：不隐藏、不清底色、不动 z 序。
            //
            // 全屏页曾经被这么「接管」过，结果是整页空白：
            // · 隐藏 `Lyrics_FullscreenElementPageImpl.LyricsView` →
            // 全屏页根视图里**一个子视图都没有**，
            // Spotify 那一页的 header / 歌词 / 控件栏都不在根视图这一层，
            // 所以「藏歌词容器」等于把整页内容一起藏了；
            // · 清根视图的 `backgroundColor` / layer → 摘掉的是这一页唯一的背景层，
            // 页面连底都没了。
            //
            // 现在的策略：原生 UI 全部原样保留，我们只负责把自己那块背景做够暗，
            // 让它盖住底下的东西（`LyricsBackdropView.solidStageScrimAlpha`）。
            // 这个判据用的是 showsProviderFooter —— 它只在全屏页为 true。
            // ── 挂载点：预览挂到**卡片容器**上，自己出壳
            //
            // 预览卡片的「壳」（顶部 `歌词` + 分享/展开那一行、四周留白）是 Spotify 的
            // Element 框架画的，而我们的层原来是挂在**歌词视图**（卡片里的一块内容）上。
            // 子视图盖不住父视图自己的背景，所以那一行 39pt 永远是专辑纯色 ——
            // 塞背景层 / 清容器底色 / 每帧重清 / 画出 bounds 之外 / 改注入的背景色
            // 这五种办法全部无效，原因就在这。
            //
            // 现在换思路：把我们的层挂到**卡片容器**上、铺满整张卡片。
            // 壳这一层从此由我们画（`previewHeader` 就是那一行）。
            //
            // 全屏不受影响：它本来就挂 vc.view，并且自己画了整套壳。
            //
            // ── 预览的宿主判据（严格）
            // 必须**先找到卡片容器**（见 `cardContainer` 的四条证据）。找不到卡片时，
            // 只有当内容视图本身是「已知的卡片歌词视图类」、或者是个**不自称歌词**的
            // 普通视图（老版本的 `LyricsOnlyViewController.view` 就是这种）才允许退化挂载。
            //
            // 要拒的正是这一种：`Lyrics_TextComponentImpl.LyricsView`（366x120，实际待在
            // **歌曲封面容器** 366x432 里）—— 名字里带 Lyrics、却不在「卡片歌词视图」名单里，
            // 卡片那一刻也还没建出来。退化挂载的后果是整层跑到封面上
            // （`[PreviewShell] card container=UIView 366x432`）。
            // 拒绝之后什么都不挂，看门狗会在卡片建好时自己挂上来。
            let className = NSStringFromClass(type(of: view))
            let isKnownLyricsContent = inlineLyricsContentClassNames.contains(className)
            let claimsToBeLyrics = className.contains("Lyrics")
            let card: UIView? = showsProviderFooter ? nil : Self.cardContainer(for: view)
            if !showsProviderFooter,
               card == nil,
               claimsToBeLyrics,
               !isKnownLyricsContent {
                Self.logRejectionThrottled(
                    "[WordByWord] ⚠️ preview host rejected — no card and foreign lyrics view"
                        + " (\(className)) — will retry"
                )
                exitReason = "preview host rejected: no card container and this is a foreign"
                    + " Lyrics-named view not in the whitelist (\(className))"
                return false
            }
            // 预览宿主还必须**真的显示在屏幕上**。
            //
            // 歌词视图有可能是**离屏的复用视图**（`at(-293,887)`，屏幕外）。挂上去就是
            // 「歌词挂错地方」：我们那一层跑到别的界面上去了。看不见就不挂，
            // 交给看门狗下一轮再找。
            //
            // 判据是「**实际挂载点**可见」而不是「内容视图可见」
            // （有卡片就是卡片本身，与下面 `mountView` 的算法完全一致）。
            //
            // 为什么必须这样：自适应 cell 会复用出**离屏的歌词视图实例**，而卡片本身在
            // 屏幕上；判内容视图等于把这首歌的逐词层永久拒掉。
            //
            // 诊断行里带出**每个条件**的实测值（window / hidden / alpha / frame / 可见比例）：
            // 判据一共六个条件，只写一句 off-screen 时根本分不出是哪一条不过。
            let mountTarget = showsProviderFooter ? view : (card ?? view)
            if !showsProviderFooter, !Self.isVisibleOnScreen(mountTarget) {
                let mountClass = NSStringFromClass(type(of: mountTarget))
                let diagnostics = Self.visibilityDiagnostics(mountTarget)
                Self.logRejectionThrottled(
                    "[WordByWord] ⚠️ preview host off-screen (\(className)) — will retry"
                        + " | mount=\(mountClass) \(diagnostics)"
                )
                exitReason = "preview host off-screen (likely a recycled cell view) (\(className))"
                    + " [mount=\(mountClass) \(diagnostics)]"
                return false
            }
            var mountView = mountTarget
            if !showsProviderFooter, Self.isPageSized(mountView) {
                // 卡片判据把"整页"当成了卡片（`cardContainer` 的尺寸启发式在
                // 宿主根视图上必然如此）。照挂就是"预览变全屏"：一块卡片背景
                // 铺满整个正在播放页，把原生界面全盖住。
                guard !Self.isPageSized(view) else {
                    writeDebugLog(
                        "[WordByWord] ⚠️ no safe preview mount point"
                            + " (\(NSStringFromClass(type(of: mountView))) is page-sized) — skipped"
                    )
                    exitReason = "no safe preview mount point: both the card container and the"
                        + " content view are page-sized (\(NSStringFromClass(type(of: mountView))))"
                    return false
                }
                writeDebugLog(
                    "[WordByWord] preview mount view is page-sized"
                        + " (\(NSStringFromClass(type(of: mountView)))) — falling back to lyrics view"
                )
                mountView = view
            }
            // 卡片比歌词视图高出来的那段（实测 39～64pt）= 我们自绘标题栏要占的高度。
            // 全屏传 62（曲名 + 歌手两行，与页面默认值一致）。
            //
            // 预览要做范围检查：量出来的差值可能是**错的**（内容视图与卡片不等高，
            // 或者某一方还没布局完）。离谱的值会让标题栏占掉半张卡片、把歌词推下去 ——
            // 这时宁可传 0，让页面退回实测默认值（预览标题栏一行 ≈ 39pt）。
            let measuredInset = mountView.bounds.height - view.bounds.height
            let headerInset: CGFloat
            if showsProviderFooter {
                headerInset = 62
            } else if measuredInset >= Self.previewMinCardExtraHeight,
                      measuredInset <= Self.previewCardMaxExtraHeight {
                headerInset = measuredInset
            } else {
                headerInset = 0
            }
            AppleMusicLyricsOverlayHost.shared.update(
                in: mountView,
                sideInset: sideInset,
                showsProviderFooter: showsProviderFooter,
                solidBackdrop: showsProviderFooter,
                previewHeaderInset: headerInset
            )
            // `update` **内部可能拒绝挂**（行模型属于别的曲目 / 没有行 /
            // 宿主还没进窗口），那时它自己把 hosting view 摘掉、什么都不挂。
            // 这里若照旧往下写 `isAttached = true`，就变成「标记说挂着、层其实不在」：
            // 看门狗下一轮只能把它当残留清掉，于是 `overlay detached` /
            // `stale attachment cleared` 每 1~2 秒刷一次。
            // 真实挂载与否以 hosting view 为准（`overlayView` 就是它）。
            guard AppleMusicLyricsOverlayHost.shared.overlayView != nil else {
                exitReason = "Apple Music host refused to mount (no overlay view after update)"
                return false
            }
            // 预览：把「展开 / 分享」的全部候选控件（标签 + frame）打一次日志。
            //
            // 为什么要这个：出现过「点我们画的小方框没反应、点 `歌词` 两个字反而能进全屏」。
            // 那说明 `expandToFullscreenLyrics` 找到的控件**不是**卡片上那一颗
            // （很可能是页面别处的同名按钮，位置完全不同）。有了候选清单，
            // 就能按「在卡片范围内」来挑，不必再猜。
            if !showsProviderFooter {
                WordByWordPlaybackControl.dumpPreviewActionCandidates()
            }
            // 新层由主时钟驱动，旧 overlay 的回调必须清掉，否则两边同时渲染。
            WordByWordPlaybackClock.shared.onChange = nil
            WordByWordPlaybackClock.shared.tickHandler = { @MainActor ms in
                AppleMusicLyricsOverlayHost.shared.tick(ms: ms)
            }
            WordByWordPlaybackClock.shared.start()
            attachedShowsProviderFooter = showsProviderFooter
            // 预览挂载点在函数开头就记好了（那时还没有数据判据）；
            // 这里**不要**再记一次 `view` —— 它可能是整页大小的宿主根视图，
            // 覆盖掉正确的记录就又把"预览变全屏"放回来了。
            hostView = view
            isAttached = true
            renderedLyricsVersion = currentLyricsVersion
            didAttach = true
            return true
        }

        // 用不上新层就把它摘掉（例如从有逐字的歌切到纯 LRC 的歌）。
        if #available(iOS 26.0, *) {
            AppleMusicLyricsOverlayHost.shared.detach()
        }

        // ── 产品规则
        // **只有拿到逐词数据，我们才挂这一层；只有逐行的歌整首交还 Spotify 原生。**
        //
        // 以前这里是「行级可用就挂」（降级档：当前行整行点亮），那是错的：
        // 网易云一大批歌没有 yrc（`yrc absent → falling back to line-synced (lrc)`），
        // 整首只有行级时间轴，这一层照样挂上 —— 表现就是「逐行的歌套着逐词的壳」：
        // · 全屏变成我们自绘的壳：标题贴自己顶部、自己的进度条+三键偏低、没有原生关闭键，
        // 原生那页（⌄ + 居中歌名/歌手 + 底部 文A/分享/…）被压在下面；
        // · 行下还会多出我们画的译文行。
        //
        // 而行级数据**没有一行是我们非画不可的**：Spotify 原生那页/那张卡本来就会照
        // payload 里的 `offsetMs` 做逐行高亮 + 自动滚动（官方歌词就是它渲染的），
        // 罗马字也在 payload 里（网易官方 romaji 直接替换主页词行，见
        // `NeteaseLyricsRepository` 的 `Applied official romaji`）。交还之后预览卡片与
        // 全屏都会是原生那张样子。
        //
        // 三种数据 × 渲染器：
        // · 逐词 + AM 开 + iOS 26+ → AM 页（上面那个分支，不变）
        // · 逐词 + 其它情况 → 本层逐字高亮（不变）
        // · 只有逐行 / 无时间轴 → 我们一层都不挂（本 guard），全部交还原生
        guard usable else {
            // 这里**自己把判据打一行**。
            //
            // 以前那行只在我们的层跑起来之后（`setCurrentTime` 的版本变化处）才打，
            // 于是「从没挂上」的歌 —— 也正是最需要这一行的歌 —— 反而看不到它，
            // 而下面这句文案却写着 "see the `[WordByWord] word-level judge` line above"。
            //
            // 必须用**文件级**的 `wordLevelJudgeLine`：这里是 `WordByWordHost`，
            // overlay 里那个私有方法跨类型调不到。去重不重要 —— 这条路径只在
            // 「这首歌挂不上」时才会走到。
            if let judgeLine = wordLevelJudgeLine(
                dto: currentLyricsDto,
                version: currentLyricsVersion
            ) {
                writeDebugLog(judgeLine)
            }
            exitReason = "no word-level timing — handing the page back to Spotify's native"
                + " renderer (line-level usable=\(lineLevelUsable));"
                + " see the `[WordByWord] word-level judge` line above"
            return false
        }

        // 旧层同样不许挂到「整页大小」的视图上。
        //
        // 旧实现没有「卡片容器」这个概念，挂哪儿就铺满哪儿，而且底色是**不透明**的 ——
        // 一旦挂到正在播放页的根视图上，整页原生界面（含那两颗按钮）会被盖光，
        // 表现与「预览变全屏」完全一样。触发路径就是 `reattachToInline` 的兜底分支
        // （只记住了整页 VC、没记住卡片里的歌词视图时）。宁可不出层，交还原生。
        if !showsProviderFooter, Self.isPageSized(view) {
            writeDebugLog(
                "[WordByWord] ⚠️ preview host is page-sized"
                    + " (\(NSStringFromClass(type(of: view)))) — skipped"
            )
            exitReason = "preview host is page-sized (\(NSStringFromClass(type(of: view)))) — mounting it would cover the whole native UI"
            return false
        }

        let overlayView = LyricsWordByWordOverlayView(frame: view.bounds)
        overlayView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlayView.showsProviderFooter = showsProviderFooter
        overlayView.showsTranslation = showsTranslation
        // 全屏时这一层会把整页盖住（旧实现用的是**不透明**底色），原生的标题栏、
        // 进度条、播放键、收起键全在它下面 —— 不自己出按键就等于"全屏一个按键都没有"。
        // 预览不进这条路：卡片上那颗原生的展开/分享键就在我们层之上，够用。
        overlayView.showsPlaybackControls = showsProviderFooter
        // 全屏时背景改成"舞台式"：溢出到容器之外铺满整屏、均匀暗化。
        // 目的是让 Spotify 原有的 header / 控件栏和歌词落在同一块背景上，
        // 消除"品红壳 / 暗色肉"的割裂。内嵌预览保持卡片式。
        overlayView.setBackdropStyle(showsProviderFooter ? .stage : .card)
        overlayView.setSideInset(sideInset)
        view.addSubview(overlayView)
        // 挂到最前。
        //
        // 这个 `bringSubviewToFront` 与「会不会盖住 Spotify 原生界面」**无关** ——
        // 原生那一页（`ElementView`）不在这条视图链上，抬谁的层级都影响不到它。
        // 会不会盖住，只取决于这一层自己画不画东西：
        // · 有逐词数据 → 画歌词 + 背景，此时理应盖住原生歌词（我们替换了它）；
        // · 没有 → `configureBackdropIfNeeded` 与 `setCurrentTime` 的 guard 会把
        // 整层变透明并让触摸穿透，原生界面与控件原样可用。
        view.bringSubviewToFront(overlayView)

        overlay = overlayView
        hostView = view
        isAttached = true
        // 这两条以前只在 Apple Music 分支里写。旧层漏掉之后有两个后果：
        // · `attachedShowsProviderFooter` 残留上一次的值 → 全屏时
        // `refreshForCurrentLyrics` 以为「现在是预览」，于是把全屏的层拽掉重挂；
        // · `renderedLyricsVersion` 不更新 → 每次歌词版本变化都重挂一次（闪一下），
        // 而旧层本来就会在 `setCurrentTime` 里自己按版本号 rebuild。
        attachedShowsProviderFooter = showsProviderFooter
        renderedLyricsVersion = currentLyricsVersion

        // 旧 overlay 的时间回调（新层走 `tickHandler`，两者互斥）。
        //
        // 两个闭包都显式标 `@MainActor`：它们的目标
        // （`AppleMusicLyricsOverlayHost.tick`、`LyricsWordByWordOverlayView.setCurrentTime`）
        // 都是 main-actor 隔离的，而在 `attach`（已隔离）里创建的闭包**不会自动继承**
        // 隔离 —— 不标就是「在非隔离同步上下文调用 MainActor 隔离方法」。
        // 运行时无变化：时钟是 `CADisplayLink` 挂在 `.main` run loop 上的，本来就在主线程。
        WordByWordPlaybackClock.shared.onChange = { @MainActor [weak overlayView] ms in
            overlayView?.setCurrentTime(ms)
        }
        WordByWordPlaybackClock.shared.tickHandler = nil
        WordByWordPlaybackClock.shared.start()
        writeDebugLog(
            "[WordByWord] legacy overlay attached — host=\(NSStringFromClass(type(of: view)))"
                + " \(Int(view.bounds.width))x\(Int(view.bounds.height))"
                + " shell=\(showsProviderFooter)"
                + " sideInset=\(Int(sideInset))"
                // 这一档现在只可能是 `word`：`attach` 已经不允许没有逐词数据时挂上来
                // （只有逐行的歌整首交还原生）。留着这个字段是为了万一有旧日志/旧构建
                // 混进来时能一眼看出档位，别删。
                + " level=\(usable ? "word" : "line")"
        )
        didAttach = true
        return true
    }

    func detach() {
        guard isAttached else { return }
        WordByWordPlaybackClock.shared.stop()
        WordByWordPlaybackClock.shared.onChange = nil
        WordByWordPlaybackClock.shared.tickHandler = nil
        if #available(iOS 26.0, *) {
            AppleMusicLyricsOverlayHost.shared.detach()
        }
        overlay?.removeFromSuperview()
        overlay = nil
        hostView = nil
        isAttached = false
        writeDebugLog("[WordByWord] overlay detached")
    }

    // MARK: 关闭全屏的「静态替身」交接
    //
    // 关闭全屏时用：先给当前层拍一张**静态替身**留在原宿主（全屏页）上，
    // 再把真正的 overlay 搬回内嵌卡片。
    //
    // 为什么必须这样：一个 overlay 视图没法同时挂在两个宿主上。直接在
    // `viewWillDisappear` 里 `detach` 的话，整段下滑动画期间全屏页露出的都是
    // **Spotify 原生歌词 + 纯专辑色背景** —— 这就是"关闭时一闪"的成因。
    // 留一张 `snapshotView` 顶替它在原位置的画面之后：
    // · 全屏页在整段关闭动画里仍是"我们的样子"（静态，但页面本来就在往下滑，看不出来）；
    // · 真正的层已经挂回内嵌卡片，卡片被露出来时也已经是我们的渲染。
    func handOffToInlineKeepingStandIn() {
        installStandIn()
        detach()
        reattachToInline()
    }

    /// 全屏页彻底消失后清掉替身。
    func removeStandIn() {
        guard let standIn = transitionStandInView else { return }
        standIn.removeFromSuperview()
        transitionStandInView = nil
        writeDebugLog("[Shell] stand-in removed")
    }

    /// 当前正在显示的那一层（Apple Music 层优先）。
    private var currentOverlayView: UIView? {
        if #available(iOS 26.0, *),
           let view = AppleMusicLyricsOverlayHost.shared.overlayView {
            return view
        }
        return overlay
    }

    // MARK: 预览卡片容器
    //
    // 预览卡片的容器。
    //
    // 最初按「从歌词视图往上找第一个**比它高**的祖先」来判
    // （`Lyrics_NPVCommunicatorImpl.CardView(374x300)` ← 歌词视图 `(374x261)`，
    // 差 39pt 正好是卡片标题栏那一行，「更高」比写死类名稳）。
    //
    // 这条判据太松，会把**歌曲封面容器**当成卡片：
    // `[PreviewShell] card container=UIView 366x432 lyrics=366x120`（差 312pt），
    // 于是预览逐词层被挂到封面上，而真正的卡片是
    // `Lyrics_CardElementImpl.CardView 374x320` ← `342x256`（差 64）。
    //
    // 所以现在按**证据强弱**排四条判据（见下），全不成立就返回 nil：
    // 调用方据此**宁可不挂**，由看门狗在卡片建好之后再挂一次。
    //
    // 四条的顺序：
    // ① `…CardView` 类名 —— 最硬；② 含标题栏按钮、且**尺寸仍像卡片**的最外层祖先
    // （只取最近一层会挂到卡片内部的内容列上，比卡片小一圈）；
    // ③ 收紧的尺寸判据；④ 容器白名单。②③④ 都是「Spotify 改了名字」时的退路。
    static func cardContainer(for view: UIView) -> UIView? {
        // ① 类名：卡片本体。这是最硬的证据（名字就叫 CardView），而且它正是「整张卡片」
        // 那一层 —— 我们要盖住的就是它（含它自己的标题栏与四周留白）。
        //
        // 必须排在「含标题栏按钮」那条**前面**：那条判据最近的命中是卡片内部的
        // **内容列**（`UIStackView 342x304` = 标题行 + 歌词两行），挂上去比真卡片
        // 小一圈（真卡片 374x320）—— 表现就是「挂是挂上了，大小不对」：
        // 左右各留 16pt 粉边、上方还露出 Spotify 自己的「歌词」标题栏。
        if let card = ancestor(in: view, matching: Self.preferredCardClassNames) {
            return logAndReturnCardContainer(card, lyrics: view, label: "card")
        }

        // ② 语义：含歌词标题栏按钮、且尺寸仍然"像卡片"的**最外层**祖先。
        // 只在类名认不出来（Spotify 改名）时才会走到这里。
        if let card = ancestorCardSizedWithLyricsHeaderButtons(of: view) {
            return logAndReturnCardContainer(card, lyrics: view, label: "header buttons")
        }

        // ③ 尺寸（**收紧**）：卡片只比歌词内容高出一个标题栏的量级。
        // 只往上找 4 层：再往上就是滚动容器（cell / collection view），挂那儿就出界了。
        var current: UIView? = view.superview
        var depth = 0
        while let node = current, depth < 4 {
            let extra = node.bounds.height - view.bounds.height
            if extra >= Self.previewMinCardExtraHeight,
               extra <= Self.previewCardMaxExtraHeight,
               node.bounds.width >= view.bounds.width - 0.5 {
                return logAndReturnCardContainer(node, lyrics: view, label: "by size")
            }
            current = node.superview
            depth += 1
        }

        // ④ 既有白名单兜底：找不到卡片本体时退到通用容器，并且**取最外层**那一个
        // （最接近整张卡片），而不是自下往上第一个命中的。同样要过高度上限 ——
        // 否则会把整页容器抓进来（那就是"预览变全屏"）。
        //
        // 光查「高度 ≤ 500」不够：`Lyrics_NPVContainerKit.LyricsContainerView 366x120`
        // （与单行歌词视图**同尺寸**）就这样被当成了卡片，我们的层挂到封面下那一行
        // 单行歌词上。现在改走 `looksLikeCardContainer`：必须真的比歌词内容高出一个
        // 标题栏的量级。
        var outermost: UIView?
        var fallback: UIView? = view.superview
        var fallbackDepth = 0
        while let node = fallback, fallbackDepth < 12 {
            if Self.knownCardContainerClassNames.contains(NSStringFromClass(type(of: node))),
               Self.looksLikeCardContainer(node, lyrics: view) {
                outermost = node
            }
            fallback = node.superview
            fallbackDepth += 1
        }
        if let outermost {
            return logAndReturnCardContainer(outermost, lyrics: view, label: "by class")
        }

        writeDebugLog(
            "[PreviewShell] ⚠️ no card container found — caller falls back to the content view"
        )
        dumpAncestorChain(from: view)
        return nil
    }

    /// 通用容器是否"**像卡片**"（④ 的判据）。
    ///
    /// 真卡片的实测特征：`Lyrics_CardElementImpl.CardView 374x320` ← 歌词 `342x256`，
    /// 高 64pt（标题栏 + 留白）、宽 32pt（左右各 16pt）。
    ///
    /// 不能只查 `height <= previewCardMaxHeight`：`Lyrics_NPVContainerKit.LyricsContainerView
    /// 366x120`（与单行歌词视图**同尺寸**、根本没有标题栏）也会被当成卡片 —— 层挂到了
    /// 单行歌词那一行上，而且一旦挂上（`isAttached` + 层存活），「已挂载」短路会挡住
    /// 随后出现的真卡片，直到下一次切换才可能纠正。宁可判 nil（等真卡片），也不要挂错地方。
    private static func looksLikeCardContainer(_ node: UIView, lyrics: UIView) -> Bool {
        let extraHeight = node.bounds.height - lyrics.bounds.height
        guard extraHeight >= previewMinCardExtraHeight,
              extraHeight <= previewCardMaxExtraHeight,
              node.bounds.height <= previewCardMaxHeight else {
            return false
        }
        let extraWidth = node.bounds.width - lyrics.bounds.width
        guard extraWidth >= -0.5, extraWidth <= previewCardMaxExtraWidth else {
            return false
        }
        return true
    }

    /// 卡片相对歌词内容允许高出的范围：只比内容高一点（标题栏），不能是一个大容器。
    private static let previewMinCardExtraHeight: CGFloat = 4
    private static let previewCardMaxExtraHeight: CGFloat = 140
    /// 卡片相对歌词内容允许宽出的范围（左右各一点内边距，实测 16pt/侧）。
    private static let previewCardMaxExtraWidth: CGFloat = 60
    /// 卡片本体的合理高度上限：超过它就不是卡片，而是整页 / 滚动容器。
    private static let previewCardMaxHeight: CGFloat = 500

    /// 从 `view` 往上，取"含歌词标题栏按钮、且尺寸仍然像卡片"的**最外层**祖先。
    ///
    /// 为什么强调「最外层」：这类容器是**一层套一层**的 —— 最近的那层是卡片内部的
    /// 「内容列」（`UIStackView 342x304` = 标题行 48 + 歌词 256），外面才是真正的卡片
    /// （`Lyrics_CardElementImpl.CardView 374x320`）。只取最近一层，挂出来的层就比卡片
    /// 小一圈（左右各留 16pt、上方露出原生「歌词」标题栏）。
    ///
    /// 两个闸门都是「相对歌词内容」的（宽度 + 高度），一超就**停**：祖先只会越来越大，
    /// 一旦某一层超了（包住卡片的 cell / 滚动容器 / 整页），再往上没有意义。
    /// 高度另有一个绝对值上限（`previewCardMaxHeight`）兜底。
    private static func ancestorCardSizedWithLyricsHeaderButtons(of view: UIView) -> UIView? {
        var node: UIView? = view.superview
        var depth = 0
        var result: UIView?
        while let current = node, depth < 12 {
            let extraHeight = current.bounds.height - view.bounds.height
            let extraWidth = current.bounds.width - view.bounds.width
            guard current.bounds.height <= Self.previewCardMaxHeight,
                  extraHeight <= Self.previewCardMaxExtraHeight,
                  extraWidth <= Self.previewCardMaxExtraWidth else {
                break
            }
            // 等高/等宽的包装层不算候选，但要继续往上找（真卡片在它们外面）。
            if extraHeight >= Self.previewMinCardExtraHeight,
               containsLyricsHeaderButton(current) {
                result = current
            }
            node = current.superview
            depth += 1
        }
        return result
    }

    /// 子树里有没有歌词标题栏那一行（展开 / 分享）的按钮。
    ///
    /// 按**无障碍 id** 找：那是 Spotify 为 VoiceOver 维护的稳定标识
    /// （`lyrics-expand-button`「将歌词界面扩展至全屏」、`lyrics-share-button`「分享歌词」）。
    /// 不按标签找 —— 标签会随语言变。
    private static func containsLyricsHeaderButton(_ root: UIView) -> Bool {
        var queue: [UIView] = [root]
        var visited = 0
        while !queue.isEmpty, visited < 400 {
            let view = queue.removeFirst()
            visited += 1
            if let control = view as? UIControl,
               let identifier = control.accessibilityIdentifier,
               Self.lyricsHeaderButtonIdentifiers.contains(identifier) {
                return true
            }
            queue.append(contentsOf: view.subviews)
        }
        return false
    }

    private static let lyricsHeaderButtonIdentifiers: Set<String> = [
        "lyrics-expand-button",
        "lyrics-share-button",
    ]

    /// 兜底诊断：把从歌词视图往上 12 层的「类名 + 尺寸」全部打出来。
    ///
    /// 就能**一次性看出**真正的卡片容器是哪个类（以及它离
    /// 歌词视图有几层），不必再去翻 IPA 猜类名。正常命中白名单时不会打这条，
    /// 所以它出现即代表白名单仍需扩充。
    ///
    /// 带节流：宿主看门狗每 1.5s 就会重走一次这条路，而「卡片还没建出来」期间
    /// 这条 dump 会**一模一样地反复出现**（一次 13 行，`writeDebugLog` 是写文件的）。
    /// 同一条链 10s 内只记一次；链变了立刻记（那才是有用的信息）。
    private static func dumpAncestorChain(from view: UIView) {
        var lines: [String] = []
        var node: UIView? = view
        var depth = 0
        while let current = node, depth <= 12 {
            let frame = current.frame
            lines.append(
                "[PreviewShell] chain[\(depth)] "
                    + "\(NSStringFromClass(type(of: current))) "
                    + "\(Int(frame.width))x\(Int(frame.height))"
                    + (current === view ? "   ← lyrics view" : "")
            )
            node = current.superview
            depth += 1
        }

        let signature = lines.joined(separator: "|")
        let now = Date()
        if signature == lastChainDumpSignature,
           now.timeIntervalSince(lastChainDumpTime) < 10 {
            return   // 同一条链刚打过（看门狗每 1.5s 走一次这条路）—— 静默跳过
        }
        lastChainDumpSignature = signature
        lastChainDumpTime = now
        for line in lines { writeDebugLog(line) }
    }

    private static var lastChainDumpSignature: String = ""
    private static var lastChainDumpTime: Date = .distantPast

    /// 单槽诊断节流：同一条消息 `interval` 秒内只记一次。
    /// 让 `attach` 的**每一条放弃路径**都留下原因。
    ///
    /// 起因：`attach` 里有多个 `return false`，其中几处曾经是**静默**的。
    /// 「只有 `refresh for current lyrics (version N)` 然后什么都没有」，和「这个函数
    /// 压根没被调用过」完全无法区分 —— 排查「为什么没挂上」时全靠猜。
    ///
    /// 全部走 `logRejectionThrottled`：看门狗每 1.5s 会重试一次 `attach`，
    /// 不加节流的话「挂不上」的场景会每 1.5s 刷一行。
    private static func logAttachRejection(_ reason: String, controller: UIViewController) {
        let view = controller.view
        let hostClass = view.map { NSStringFromClass(type(of: $0)) } ?? "<no view>"
        let hostSize = view.map { "\(Int($0.bounds.width))x\(Int($0.bounds.height))" } ?? "-"
        logRejectionThrottled(
            "[WordByWord] attach declined — \(reason)"
                + " | host=\(hostClass) \(hostSize)"
                + " | provider=\(currentLyricsProvider.isEmpty ? "<none>" : currentLyricsProvider)"
        )
    }

    /// 与链 dump 各用一套槽位，互不干扰：两者会被同一段重试循环交替触发，
    /// 共用一个槽位等于谁都没被节流。
    private static var lastRejectionMessage: String = ""
    private static var lastRejectionTime: Date = .distantPast

    private static func logRejectionThrottled(_ message: String, interval: TimeInterval = 10) {
        let now = Date()
        if message == lastRejectionMessage,
           now.timeIntervalSince(lastRejectionTime) < interval {
            return
        }
        lastRejectionMessage = message
        lastRejectionTime = now
        writeDebugLog(message)
    }

    /// **卡片本体**：优先级高于其它所有容器。9.1.76 上是
    /// `Lyrics_CardElementImpl.CardView`（含标题栏 `CardHeaderView` + 内容区
    /// `CardContentView`）。必须挂在这一层，才能让自绘的壳盖住 Spotify 的标题栏。
    private static let preferredCardClassNames: Set<String> = [
        "Lyrics_CardElementImpl.CardView",
        "Lyrics_NPVCommunicatorImpl.CardView",
    ]

    /// 这个视图是不是"整页大小"（正在播放页 / 全屏页的根视图）。
    ///
    /// 预览层只允许挂在**卡片**上。一旦挂到整页，表现就是「预览变成了全屏」：
    /// 一块卡片背景铺满整个正在播放页，把原生界面（含卡片上那两颗按钮）全盖住 ——
    /// 这正是「退出全屏后预览变全屏」的机制（`reattachToInline` 若拿
    /// `lastInlineController.view` 当内容视图，那就是整页的根视图）。
    ///
    /// 判据要求宽和高**同时**接近窗口：iPhone 上卡片约 374x300，
    /// iPad 上卡片只占一列 —— 两个方向都不会贴满窗口。
    /// 尺寸还来不及布局（bounds 为 0）或拿不到窗口时返回 false（不判断，保持旧行为）。
    static func isPageSized(_ view: UIView) -> Bool {
        let bounds = view.bounds
        guard bounds.width > 1, bounds.height > 1 else { return false }
        guard let reference = referenceWindowSize(for: view) else { return false }
        return bounds.width >= reference.width * 0.75
            && bounds.height >= reference.height * 0.75
    }

    /// 这个视图现在**真的显示在屏幕上**吗。
    ///
    /// 用来否掉两类宿主：
    /// · 离屏的复用视图（自适应表格 cell 回收后再没上屏，例如 `at(-293,887)`）；
    /// · 尺寸还没收敛 / 被折叠的容器。
    ///
    /// 判据：在窗口里、没被隐藏、尺寸像个歌词区（宽 > 120、高 > 60）、
    /// 中心点在窗口内、且至少一半面积可见。
    ///
    /// `nonisolated`：它是个**纯几何判据**（只读 `window`/`isHidden`/`alpha`/frame），
    /// 而 `InlineLyricsHostLocator`（非 MainActor 隔离的 enum）在找宿主时也要用它 ——
    /// 见那里 `viewHost(in:)` 的说明。加隔离标注会让那次调用变成编译错误。
    nonisolated static func isVisibleOnScreen(_ view: UIView) -> Bool {
        guard let window = view.window,
              window.bounds.width > 1,
              window.bounds.height > 1 else { return false }
        guard !view.isHidden, view.alpha > 0.01 else { return false }

        let frame = view.convert(view.bounds, to: window)
        guard frame.width > 120, frame.height > 60 else { return false }
        guard window.bounds.contains(CGPoint(x: frame.midX, y: frame.midY)) else { return false }

        let visible = frame.intersection(window.bounds)
        guard !visible.isNull, !visible.isEmpty else { return false }
        return visible.width * visible.height >= frame.width * frame.height * 0.5
    }

    /// `isVisibleOnScreen` 的**逐条件实测值**，只为日志。
    ///
    /// 为什么需要：拒绝日志只有一句「off-screen」，而那个判据有六个条件
    /// （window / 窗口尺寸 / hidden / alpha / 尺寸下限 / 中心点在窗口内 / 至少一半面积可见）。
    /// 卡片尺寸完全正常（374x320，歌词区 342x256）却仍被判 off-screen 时，
    /// 不把每个条件打出来就只能猜是哪一条。
    ///
    /// 格式固定、可 grep：`window=WxH hidden=B alpha=N.NN frame=(x,y) WxH visible=P%`。
    nonisolated static func visibilityDiagnostics(_ view: UIView) -> String {
        let windowDesc = view.window.map {
            "\(Int($0.bounds.width))x\(Int($0.bounds.height))"
        } ?? "nil"

        var frameDesc = "frame=<no window>"
        if let window = view.window {
            let frame = view.convert(view.bounds, to: window)
            let area = frame.width * frame.height
            let visible = frame.intersection(window.bounds)
            let visibleArea = (visible.isNull || visible.isEmpty)
                ? 0
                : visible.width * visible.height
            let percent = area > 0 ? Int(visibleArea / area * 100) : 0
            frameDesc = "frame=(\(Int(frame.minX)),\(Int(frame.minY)))"
                + " \(Int(frame.width))x\(Int(frame.height)) visible=\(percent)%"
        }

        return "window=\(windowDesc) hidden=\(view.isHidden)"
            + " alpha=\(String(format: "%.2f", Double(view.alpha))) \(frameDesc)"
    }

    /// 判断尺寸用的参照（优先该视图自己所在的窗口，其次当前 key window）。
    private static func referenceWindowSize(for view: UIView) -> CGSize? {
        if let size = view.window?.bounds.size, size.width > 1, size.height > 1 {
            return size
        }
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        let window = windows.first { $0.isKeyWindow } ?? windows.first
        guard let size = window?.bounds.size, size.width > 1, size.height > 1 else { return nil }
        return size
    }

    /// 从 `view` 往上找第一个（也是最近的）匹配 `names` 的祖先。
    private static func ancestor(in view: UIView, matching names: Set<String>) -> UIView? {
        var node: UIView? = view.superview
        var depth = 0
        while let current = node, depth < 12 {
            if names.contains(NSStringFromClass(type(of: current))) { return current }
            node = current.superview
            depth += 1
        }
        return nil
    }

    private static func logAndReturnCardContainer(
        _ container: UIView,
        lyrics: UIView,
        label: String
    ) -> UIView {
        writeDebugLog(
            "[PreviewShell] card container (\(label))="
                + "\(NSStringFromClass(type(of: container)))"
                + " \(Int(container.bounds.width))x\(Int(container.bounds.height))"
                + " lyrics=\(Int(lyrics.bounds.width))x\(Int(lyrics.bounds.height))"
        )
        return container
    }

    /// 通用容器兜底（只在找不到卡片本体时使用；调用方取**最外层**命中者）。
    ///
    /// 只列歌词自己的容器；**不要**把滚动容器、`NPVScrollViewController` 一类加进来，
    /// 那会重新变成铺满整页。
    private static let knownCardContainerClassNames: Set<String> = [
        // 元素框架的包装层
        "Lyrics_NPVElementsKitImpl.LyricsElementContainerView",
        "Lyrics_NPVElementsKitImpl.LyricsElementWrapperView",
        "Lyrics_NPVContainerKit.LyricsContainerView",
        // 自适应表格 cell（预览歌词所在的 cell）
        "Lyrics_TextElementImpl.LyricsCell",
        "Lyrics_TextComponentImpl.LyricsCell",
        "Lyrics_TextElementSingalongImpl.LyricsCell",
        // 卡片内容区：比卡片本体小（不含标题栏），仅作最后备选
        "Lyrics_CardElementImpl.CardContentView",
    ]

    private func installStandIn() {
        removeStandIn()

        guard let host = hostView,
              let current = currentOverlayView,
              let snapshot = current.snapshotView(afterScreenUpdates: false) else {
            writeDebugLog("[Shell] ⚠️ stand-in unavailable (no host / view / snapshot)")
            return
        }

        // 与原层同位置、同层级：插在它上面，就等于接替了它原来占的那一层
        // （原生控件在我们之上，替身也在我们之上，层级关系不变）。
        snapshot.frame = current.frame
        snapshot.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        snapshot.isUserInteractionEnabled = false
        host.insertSubview(snapshot, aboveSubview: current)
        transitionStandInView = snapshot
        writeDebugLog("[Shell] stand-in installed for dismissal")
    }
}
