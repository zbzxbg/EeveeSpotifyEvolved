// 「iOS 27 听歌页」—— 把听歌页做成 Apple Music（iOS 27）那一版的样子。
//
// 独立开关 `UserDefaults.nowPlayingIOS27`，默认关；与旧那套（`NowPlayingLyricsPlate` 的
// "歌词进播放器"）**互斥** —— 新的开着时旧的自动让位（`NowPlayingLyricsPlate.isEnabled`
// 里的 `!nowPlayingIOS27` 那道门）。
//
// 背景用 pw 的 field：字段色底（整图平均色，过饱和后压到两条上限）+ 封面的模糊延续
// （整张缩到 48pt 再模糊）+ 窗口 64% 起渐到 42% 黑的纱。封面是 `(0, 0, W, 0.58H)` 的
// 竖长裁切、从屏幕最顶上画起，下沿再用 mask 淡进模糊里 ⇒ 没有接缝。
//
// 纪律：**不移动**任何会被 Spotify 重排的行（移出去就点不到），要换位置用"藏字形 + 自绘 +
// 替身"（`NowPlayingIOS27RemoteRelayView`）；只对封面壳写 `alpha`（记原值、每拍补、收尾写回）；
// 自己的视图挂在封面所在的整页 cell 里（contentlayer 在 UI 栈下面），z-order 天然正确；
// 量位置一律用 `convert`（带 transform）；每 0.3s 蹭 `DeclutterChrome` 的节拍，不新开定时器。
// 日志 tag：`[iOS27]`。
import Foundation
import UIKit
import CoreImage
import ObjectiveC.runtime

@MainActor
enum NowPlayingIOS27 {

    static let logTag = "iOS27"

    // MARK: - 几何 / 配色
    //
    // 标题行左边距。**只改横向**。
    //
    // 取 28 是为了和进度条的左边距（`ProgressBarUnitNowPlaying` 的 x=28）对齐 ——
    // AM 里曲名与进度条共用同一条左边线。再往右就得连进度条一起挪，那是原生控件。
    static let titleLeadInset: CGFloat = 28
    /// 封面自己下沿从哪一档开始淡出（占封面高度）。
    ///
    /// 0.45 ⇒ 过渡带占整张封面的一半（约 230pt），到底边完全化成底色，
    /// 才有 AM 那种"没有明确边界"的感觉。
    static let artworkFadeStart: CGFloat = 0.45
    /// 取"字段色"时裁封面下沿多少（占封面边长）。
    static let stripFraction: CGFloat = 0.30
    /// 封面**高度**占页高的比例。
    ///
    /// AM 的封面是竖长裁切、铺到屏幕约 57% 高、标题压在它下沿。0.58 在 896 高的屏上
    /// 得到 ≈520pt；用方图会让封面与标题之间空出 186pt。
    static let artworkHeightRatio: CGFloat = 0.58
    /// 封面高宽比上限：方图裁成竖图最多裁到 1.30；再大会把封面两边裁掉太多。
    static let artworkMaxAspect: CGFloat = 1.30
    /// 顶部压暗带：**封面仍然满血到顶**，只在状态栏/灵动岛那一带再压一层黑。
    ///
    /// 封面不下移（AM 也是顶到最上沿），要解决的是亮度：浅色封面会让状态栏时间和
    /// 下拉把手糊掉。所以在最上层叠一层上重下无的黑色渐变，只压这一带、不碰封面构图。
    /// 高度 = 安全区顶 + 64（刘海/灵动岛 + 把手 + 状态栏文字），下限 96。
    static let topScrimExtraHeight: CGFloat = 64
    static let topScrimMinHeight: CGFloat = 96
    /// 底部那一坨（`npv.bottomStackView`：曲名 / 进度 / 时间 / 传输行 / 工具行）整体上移多少。
    ///
    /// 上移 55 后曲名从 600 落到 545，只比封面下沿（520）低 25pt，与 AM 一致；
    /// 再往上会压到封面上。
    /// ⚠️ 只有**这一层** transform；量位置的地方必须用 `convert`（带 transform），不能用
    /// `untransformed`，否则字形/音量行会留在原位。
    static let bottomStackYOffset: CGFloat = -55
    /// 压黑渐变：从页面 64% 起渐到纯黑（pw 的 `kBlackFrom` 是 0.55；这里推后一点，
    /// 让封面淡出来的那块颜色多留一会儿，过渡更长）。
    static let blackFromRatio: CGFloat = 0.64
    /// 压黑渐变终点的**不透明度**。
    ///
    /// 取 0.42 而不是纯黑：背景里铺了封面的模糊延续，这条纱只负责压暗。AM 那块是
    /// "暗下去"不是"灰掉"——它先把封面过饱和再压暗，所以我们这条纱要更淡，颜色才透得出来。
    static let blackScrimAlpha: CGFloat = 0.42
    /// 字段颜色的两条上限（pw 原值：饱和度 0.55、线性亮度 0.07 ⇒ sRGB ≈ 0.29）。
    ///
    /// pw 这两条是为整块纯色底定的；我们底下还铺了封面模糊图，颜色不需要压那么死，
    /// 放宽到 0.90 / 0.38，再叠一个 `fieldSaturationBoost`（见 `fieldColour`）。
    static let maxFieldSaturation: CGFloat = 0.90
    static let maxFieldBrightness: CGFloat = 0.38
    /// 平均色 → 字段色时的饱和度倍率（AM 的渐变会刻意过饱和专辑图）。
    static let fieldSaturationBoost: CGFloat = 1.45
    /// 顶部导航那三件的 id。
    ///
    /// · `now-playing-minimize-button` —— 左上那颗向下箭头（48×48，`Tertiary`）；
    /// · `now-playing-navigation-unit-title-label` —— 中间那个歌单名（30×48 的 stack）；
    /// · `Context menu` —— 右上那个 ⋯（48×48，`Tertiary`）。
    ///
    /// AM 的播放页顶部**只有一根小横条**（下拉把手）⇒ 前两件藏起来。
    static let navTitleIdentifier = "now-playing-navigation-unit-title-label"
    static let contextMenuIdentifier = "Context menu"
    /// 我们自己画的那根小横条。
    static let grabberIdentifier = "eevee-ios27-grabber"

    /// 这颗开关自己就是全部条件（旧的"歌词进播放器"在它那边让位，见文件头）。
    static var isEnabled: Bool { UserDefaults.nowPlayingIOS27 }

    // MARK: - 状态

    static weak var lastPage: UIView?

    /// Spotify 那张**真正画封面**的壳（`Encore.ImageView`，366×366）。
    static weak var artworkShell: UIView?
    /// 我们自己画的那张封面 + 它的宿主（整页 cell）。
    static weak var artworkHost: UIView?
    static weak var artworkView: UIImageView?
    static weak var artworkMask: CAGradientLayer?
    /// 上一次画上去的封面图（**跨换歌 / 跨 cell 复用都留着**）。
    ///
    /// 换歌时新图还没到，用它顶着，避免露出原生封面（与 `NowPlayingLyricsPlate+Cover` 同法）。
    /// 只有 `restore` / `clearState` 会清掉它 —— 不能放进 `teardownArtwork`，那是换 cell 时调的。
    static var lastArtworkImage: UIImage?

    /// 曲目元数据里的**专辑封面**（`image_url` → `i.scdn.co` 那张），按曲目 id 认。
    ///
    /// 播放页 contentlayer 里摆的不一定是专辑封面（Canvas 帧 / 艺人图），而
    /// `firstImage(in: shell)` 只认壳里第一张够大的图 ⇒ 会连 field 一起用错。
    /// 元数据的 `image_url` 永远是这首的专辑封面 ⇒ 异步取它、**优先于壳里的图**；
    /// 壳只负责元数据图还没到的那一两拍和加载失败时兜底。
    static var metadataArtworkTrackId = ""
    static var metadataArtworkImage: UIImage?
    static var metadataArtworkLoading = false
    static var metadataArtworkAttempts = 0
    static var metadataArtworkCache: [String: UIImage] = [:]
    static var metadataArtworkOrder: [String] = []
    static let metadataArtworkCacheLimit = 8
    /// 被我们按下 `alpha` 的原生壳（记原值，收尾按原值写回）。
    static let hiddenShells = NSHashTable<UIView>.weakObjects()
    static var shellAlphas: [ObjectIdentifier: CGFloat] = [:]

    /// 顶部压暗带（盖在封面之上、状态栏那一带；见 `topScrimExtraHeight`）。
    static weak var topScrim: UIView?
    static var didLogTopScrim = false

    /// 被我们藏掉的顶部 chrome（歌单名 / 向下箭头）。
    static let hiddenChrome = NSHashTable<UIView>.weakObjects()
    static var chromeAlphas: [ObjectIdentifier: CGFloat] = [:]
    static weak var grabber: UIView?


    /// 背景 field（挂在封面那个整页 cell 里、我们封面下面）。
    static weak var fieldHost: UIView?
    static weak var fieldSolid: UIView?
    /// 封面的**模糊延续**（下半屏那块）：AM 的背景不是纯黑，是同一张封面的模糊拷贝再压暗。
    static weak var fieldBackdrop: UIImageView?
    static weak var fieldBlack: UIView?
    /// 上一次做模糊底用的源图 + 结果（同一张只算一次）。
    static var lastBackdropSource: UIImage?
    static var lastBackdropImage: UIImage?

    /// 被我们改了左边距的标题行，以及它原来的 `transform` 与原生位置。
    static weak var titleRow: UIView?
    static var titleRowBase: (ObjectIdentifier, CGAffineTransform)?
    static var titleRowBaseRect: (ObjectIdentifier, CGRect)?

    /// 页内歌词模式下，盖在**原生歌名/艺人**上的透明点击区。
    ///
    /// Spotify 原生那两行只是 `UILabel`，不吃触摸。这里各盖一颗透明 `UIButton`：
    /// 点歌名开专辑、点艺人开艺人页，URI 取自当前曲目的 `album_uri` / `artist_uri`。
    static weak var titleTapButton: UIButton?
    static weak var artistTapButton: UIButton?
    /// 只报一次"点击区挂上了"。
    static var didLogTitleTapTargets = false
    /// 只报一次"找不到那两行"—— 与上一条一起区分"没挂上"和"点了没反应"。
    static var didLogMissingTapLabels = false

    /// 被我们**整体上移**的"底部那一坨"，以及它原来的 `transform`（收尾要写回）。
    static weak var bottomStack: UIView?
    static var bottomStackBase: (ObjectIdentifier, CGAffineTransform)?
    static var didLogBottomStack = false

    /// 上一次画上去的是哪一首。
    static var lastTrackId = ""
    /// 上一次给 field 上色的曲目（`lastTrackId` 在 `updateArtwork` 里先写了，这里要单独一笔）。
    static var lastFieldTrackId = ""
    /// 上一次给 field 上色用的**那张图** —— 真正的判据（见 `updateField` 顶部那段：
    /// 按曲目 id 判会在换歌时把上一首的颜色锁死一整首）。
    static var lastFieldImage: UIImage?

    static var didLogArtwork = false
    static var didLogArtworkFrame = false
    static var didLogField = false
    static var didLogTitle = false
    static var didLogFrames = false
    static var didLogMissingCover = false
    static var didLogRestore = false
    /// 换歌 / 收歌词那一两拍里封面壳与宿主会对不上。这时**不能把上一拍已经画上去的
    /// 那张图藏掉** —— 藏了就是一个洞（原生壳也被我们按着）。只报一次。
    static var didLogArtworkHold = false
    /// 宿主选错（某一层整页祖先里含 `npv.bottomStackView`）只报一次。
    ///
    /// `field` 是整页大的，一旦插到**控件上面那一层**，就会把整块 bottomStack 盖住。
    static var didLogCoverHostSkip = false
    /// 封面壳认不出来、靠"记下来的宿主"按模式摆好时只报一次 —— 它同时是
    /// `resolvedShell` 那几拍空转的证据（见 `syncArtworkFrameWithoutShell`）。
    static var didLogWithoutShell = false
    /// "一次藏了很多叶子"只报一次。
    static var didLogWideGlyphHide = false
    /// Connect（雷达）不能用 `sendActions` 转发 —— 那颗 `EncoreButton` 收到 sendActions
    /// 什么都不做。改成**把原生 Connect 按钮搬到中间那颗字形的位置**，让真触摸落在它身上。
    static weak var movedConnectHolder: UIView?
    static var movedConnectBase: (ObjectIdentifier, CGAffineTransform)?
    /// 原生 Connect 搬走后，在原 `UIStackView` 槽位留下的等宽占位（保证分享/队列不挪位）。
    static weak var connectPlaceholder: UIView?
    static var didLogConnectMoved = false
    /// 连续多少拍"记下的那一页不在窗口里"（见 `reconcile` 里那段：换歌转场会短暂摘掉旧页，
    /// 立刻收尾就等于把原生封面放回来 = 屏幕上就是那一闪）。
    static var pageMissingTicks = 0

    /// iOS 27 自己的**页内歌词模式** —— 只缩封面、移标题、在中间铺歌词，
    /// **进度条 / 传输行 / 音量 / 底排三颗一颗都不动**（不借用旧布局的
    /// `NowPlayingLyricsPlate` 整套版式）。
    static var lyricsModeActive = false
    /// 开合歌词时那一层「整幅封面慢慢化开」的过渡视图（让封面溶进我们自己的底子；只活 0.36s）。
    static weak var lyricsDissolveView: UIImageView?
    /// 开合动画令牌：连点两次时后一次作废前一次的回调。
    static var lyricsModeGeneration = 0

    /// 页内歌词模式下、**歌词区左下角**那块两行署名（第一行来源、第二行提供者/翻译者）。
    static weak var lyricsCreditView: NowPlayingIOS27LyricsCreditView?

    /// 歌词阶段是否已经"该露面了"。
    ///
    /// 开歌词时先让封面缩成缩略图，**过一段再挂歌词/署名**：两者同一帧出现的话，
    /// 歌词会压在还是一大张的封面上，宿主视图第一帧的深色底也会跟着淡入被看见。
    /// 延迟之后歌词只在缩略图旁边出现，黑底那一帧在容器还透明时就画完了。
    static var lyricsModeRevealed = false
    /// 开歌词时"封面先动、歌词后到"的延迟。
    ///
    /// 必须 ≥ 封面缩小的 0.36s 动画，否则那半秒里是"一张大封面 + 一块歌词卡片"叠着。
    static let lyricsRevealDelay: TimeInterval = 0.36
    /// 打开时"该露面"被推迟了，等 `layout` 量到标题已经在缩略图旁边再亮（见 `setLyricsMode`）。
    static var lyricsRevealPending = false
    /// 歌词容器底部为那两行「来源 / 提供者」让出的高度。
    ///
    /// 署名原来摆在容器**里面**的下沿，歌词滚到底时译文会落到同一块。容器缩短这么多
    /// 之后，署名落在容器**下面**、进度条上面。
    static let lyricsCreditReserve: CGFloat = 50

    /// 缩略图边长 / 圆角 / 左边距 / 离安全区顶的距离。
    static let lyricsThumbSide: CGFloat = 64
    static let lyricsThumbCorner: CGFloat = 8
    static let lyricsThumbLeading: CGFloat = 28
    static let lyricsThumbTopInset: CGFloat = 46
    /// 歌词区左右内边距 / 顶部与缩略图之间的空隙 / 底部与进度条之间的空隙。
    static let lyricsStageSideInset: CGFloat = 26
    static let lyricsStageTopGap: CGFloat = 16
    static let lyricsStageBottomGap: CGFloat = 18

    // MARK: - 对外入口
    //
    // 进听歌页时叫一次（蹭既有的两个 appear 点）。
    static func apply(in page: UIView) {
        // ⚠️ 别用一个**已经离开窗口**的页面覆盖记下来的好页面。
        //
        // 换歌转场里旧页会被摘下来，这时若还用它覆盖 `lastPage`，`reconcile` 会把状态收掉、
        // 下一次 `apply` 又重装，那一两拍原生封面就露着。
        if page.window == nil, let live = lastPage, live.window != nil {
            return
        }
        lastPage = page
        pageMissingTicks = 0

        guard isEnabled else {
            restore(reason: "switch off")
            return
        }
        guard page.bounds.width > 1, page.bounds.height > 1 else { return }

        _ = layout(in: page)
    }

    /// 设置页切开关时叫一次：还挂着就当场落地，否则等下次进听歌页。
    ///
    /// ⚠️ **关掉时不管页面在不在都要收尾**：壳与 cell 会被复用，留着 `alpha = 0` 的壳
    /// 就是下一次在别处显形的空封面。`restore` 不依赖页面对象。
    static func reapply() {
        guard isEnabled else {
            restore(reason: "switch off")
            return
        }
        guard let page = lastPage, page.window != nil else { return }
        _ = layout(in: page)
    }

    /// 蹭 `DeclutterChrome` 既有的 0.3s 复查节拍（**不新开定时器**，本仓库纪律）。
    @discardableResult
    static func reconcile() -> Bool {
        // 页面真的不在窗口里了 ⇒ 把写过的每一处还回去（cell 会被复用）。
        // ⚠️ 这一步**不能**放在 `isEnabled` 后面：可能"先离开播放器、再在设置里关掉"。
        if let page = lastPage, page.window == nil {
            // **别立刻收尾**：换歌 / 转场里旧页会被短暂摘出窗口，`restore` 会把原生封面、
            // 原生行、我们的字形统统放回去，下一拍 `apply` 又重装 —— 那一两拍就是那一闪。
            // 先数拍：连续 3 拍（≈0.9s，`DeclutterChrome` 是 0.3s 一拍）都还是"页面不在"，
            // 才认为真的离开了播放器（回收的 cell 不能留着 alpha = 0）。
            pageMissingTicks += 1
            if pageMissingTicks >= 3 {
                restore(reason: "page disappeared")
            }
        } else {
            pageMissingTicks = 0
        }

        // 页内歌词模式**不接管整页** —— 这一层照常每拍重铺，只是 `updateArtwork` /
        // `placeTitleRow` / `updateLyricsStage` 按模式换几何，所以没有"让位/恢复"的分支。

        guard isEnabled else { return false }
        guard let page = lastPage, page.window != nil else { return false }
        return layout(in: page)
    }

    /// 点底排那颗歌词气泡 = **开/关页内歌词**。
    ///
    /// 只做三件事：封面缩成 64pt 缩略图、标题行挪到缩略图右边、歌词铺在中间；
    /// 底部按钮（进度/传输/音量/三颗字形）全部保持 iOS 27 的样子。
    static func toggleLyricsMode(in page: UIView) {
        setLyricsMode(!lyricsModeActive, in: page)
    }

    static func setLyricsMode(_ on: Bool, in page: UIView) {
        guard on != lyricsModeActive else { return }
        // 转场里页面会被短暂摘出窗口。这里静默 return 的话，
        guard page.window != nil else {
            writeDebugLog(
                "[\(logTag)] lyrics mode \(on ? "on" : "off") ignored —"
                    + " the page is not in a window yet"
            )
            return
        }
        lyricsModeActive = on
        lyricsModeGeneration += 1
        let generation = lyricsModeGeneration
        if !on {
            // 上一向（开）的化开层如果还在，先撤掉：关的时候封面自己长回去，不再叠一张。
            lyricsDissolveView?.removeFromSuperview()
            lyricsDissolveView = nil
            lyricsModeRevealed = false
            lyricsRevealPending = false
            // 歌名/艺人的透明点击区也一起收（它们只在歌词模式里存在）。
            removeTitleTapTargets()
            // **不要在第一帧就把歌词抽走** —— 它和封面长回去同一段 0.30s 淡出，
            // 淡完再拆容器。快速重开时 `generation` 对不上，这次拆作废（歌词接着淡入）。
            NowPlayingLyricsPlate.fadeOutLyricsOnly(duration: 0.30) {
                guard generation == lyricsModeGeneration, !lyricsModeActive else { return }
                NowPlayingLyricsPlate.unmountLyricsOnly()
            }
        } else {
            // 每次打开都让歌词容器从透明淡进来 —— 宿主视图第一帧的深色底就不会被看成"闪一下黑底"。
            NowPlayingLyricsPlate.lyricsOnlyNeedsFadeIn = true
            // 宿主视图从挂上到真正画完内容还有一两帧；这段时间容器保持透明（见
            // `NowPlayingLyricsPlate.lyricsOnlyFadeInDelay`），别让那一帧深色跟着淡入。
            NowPlayingLyricsPlate.lyricsOnlyFadeInDelay = 0.10
            // 封面先缩、歌词后到：延迟这一段（≥ 封面的 0.36s 动画）再挂容器与署名。
            lyricsModeRevealed = false
            lyricsRevealPending = false
            DispatchQueue.main.asyncAfter(deadline: .now() + lyricsRevealDelay) {
                guard generation == lyricsModeGeneration, lyricsModeActive else { return }
                // 先跑一拍 `layout`：它负责把封面缩完、把标题挪到缩略图旁边。
                _ = layout(in: page)
                // 标题还没量到 / 还留在原生 y（换歌转场、页还没建完）时**先不亮歌词**，
                // 否则容器会把原位标题盖住。下一拍再试。
                guard lyricsSceneReady(in: page) else {
                    lyricsRevealPending = true
                    writeDebugLog(
                        "[\(logTag)] lyrics reveal deferred — the cover/title is not ready yet"
                    )
                    return
                }
                lyricsModeRevealed = true
                UIView.animate(
                    withDuration: 0.26,
                    delay: 0,
                    options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction]
                ) {
                    _ = layout(in: page)
                }
            }
        }
        writeDebugLog(
            "[\(logTag)] lyrics mode \(on ? "on" : "off") — "
                + "cover/title move, the bottom controls stay as they are"
        )
        // 开歌词时先铺一层**整幅封面**（同一张图），让它在这一段动画里慢慢化开
        // → 下面露出来的就是我们自己的 field（封面色 + 模糊封面 + 暗纱）。
        // ⚠️ **只在"开"这一向做**：关的那一向封面本来就会从 64pt 长回满屏，
        // 再叠一张整幅封面淡入就成了两层同图叠加。
        if on {
            beginLyricsDissolve(entering: true, in: page)
        }
        // 只在这一拍放动画；之后每拍的重铺都是幂等的。
        // 这一拍里 `layout` 会同时改：封面 frame、标题行 alpha、歌词署名 alpha，
        // 三个变化共用同一个 0.36s 缓动，看起来才是一段。
        UIView.animate(
            withDuration: 0.36,
            delay: 0,
            options: [.curveEaseInOut, .beginFromCurrentState, .allowUserInteraction]
        ) {
            _ = layout(in: page)
            // `layout` 里封面几何排在最后、而且要先认出封面壳；这一拍壳没认出来封面就不会缩，
            // 但歌词照样会在 0.36s 后挂上来，于是"封面又回溶底"。这里用记下来的宿主
            // 把模式几何**同一段动画**里落地，与壳无关（幂等，成功时只是一次比较）。
            _ = syncArtworkFrameWithoutShell(in: page)
        }
    }

    /// 「封面溶进底子」的那一层。
    ///
    /// 开：整幅封面从 alpha 1 淡到 0（下面的 field 逐渐显出来），同时 `artworkView` 缩成缩略图；
    /// 关：反向 —— 整幅封面从 0 淡到 1，`artworkView` 从缩略图长回满屏。
    ///
    /// 它插在 `artworkView` **下面**、field **上面**：缩略图永远在最前，化开的只是"原来那张大图"。
    private static func beginLyricsDissolve(entering: Bool, in page: UIView) {
        guard let host = artworkHost, let art = artworkView, let image = art.image else { return }
        lyricsDissolveView?.removeFromSuperview()
        lyricsDissolveView = nil

        // 「整幅那张」按**满幅几何**画（不是缩略图）：这一层只在开歌词的那一向出现，
        // 那时 `lyricsModeActive` 已经是 true，用 `artworkFrame` 会得到 64pt。
        let frame = fullBleedArtworkFrame(in: page, host: host)
        let dissolve = UIImageView(frame: frame)
        dissolve.image = image
        dissolve.contentMode = .scaleAspectFill
        dissolve.clipsToBounds = true
        dissolve.isUserInteractionEnabled = false
        dissolve.accessibilityIdentifier = "eevee-ios27-lyrics-dissolve"
        dissolve.alpha = entering ? 1 : 0
        host.insertSubview(dissolve, belowSubview: art)
        lyricsDissolveView = dissolve

        UIView.animate(
            withDuration: 0.36,
            delay: 0,
            options: [.curveEaseInOut, .beginFromCurrentState, .allowUserInteraction]
        ) {
            dissolve.alpha = entering ? 0 : 1
        } completion: { _ in
            // 连点两次时旧的那层不要误删新的：只清自己。
            if lyricsDissolveView === dissolve {
                dissolve.removeFromSuperview()
                lyricsDissolveView = nil
            }
        }
    }

    /// 封面自己被布局的那一刻（`CoverArtTiltLayoutHook` 转发进来）。
    static func coverDidLayOut(from tilt: UIView) {
        guard isEnabled,
              let page = lastPage, page.window != nil, tilt.window != nil else { return }
        // 照 `NowPlayingLyricsPlate.coverDidLayOut` 的做法，避免切歌时闪出原生大封面：
        // · **不要求** `tilt` 已经在这棵 `page` 底下 —— 换歌/翻页转场里新封面先挂在**新的**
        // contentlayer cell 上，等 `lastPage` 更新过来时它已经露了一两帧；
        // · **不要求** `alpha > 0.01` —— 新封面对象常常先以 `alpha = 0` 出现，等 Spotify
        // 把它淡入时不再有新的布局回调；
        // · 连 `tilt` 自己一起按下去（不只是它里面那张同尺寸的图），Spotify 之后在同一份
        // tilt 里换图 / 加层都不会再露出来。
        // 门禁改成"真的是听歌页封面 cell 里的 tilt"（`isInsideCoverCell`），不会误伤列表封面。
        guard tilt.bounds.width >= 200 else { return }
        guard NowPlayingLyricsPlate.isInsideCoverCell(tilt) else { return }
        // **先按下去，再判页面归属**。换歌那一拍新封面 cell 还在转场里（中线可能不在
        // 20%…80% / 还没进 `lastPage` 子树）⇒ 若先判归属就会直接 return、原生封面整张露出来，
        // 下一拍才按掉 = 那一闪。隐藏本身对离屏 cell 无害（它进页面时我们照样画自己的图）；
        // 只有"记壳 + 画图"才需要页面归属。
        guard isNowPlayingCoverCell(tilt) else { return }
        if let cover = NowPlayingLyricsPlate.sameSizeChild(of: tilt) {
            hideShell(cover)
        }
        hideShell(tilt)
        // 壳**这一拍就记下来**（哪怕新 cell 还在转场里、还没进 lastPage 子树）——
        // 下一拍 `resolvedShell` 会用它继续画；`updateArtwork` 自己有可见页闸门。
        let shell = shell(in: tilt) ?? tilt
        artworkShell = shell
        guard isControlOnPage(tilt, in: page, requireAlpha: false) else { return }

        // 换歌时新 cell 还没挂到 `lastPage` 底下。若用 `tilt.isDescendant(of: page)` 判，
        // 这一拍会直接返回 —— 而原生 tilt 刚被按成 alpha 0，`resolvedShell` 的 `visibleCover`
        // 又因 alpha 0 认不出它 ⇒ 接下来十几秒都"no on-screen artwork"。
        // 所以把壳**记下来**（`artworkShell`）并立即尝试画；`updateArtwork` 拿不到宿主也没关系，
        // 下一拍 `resolvedShell` 会直接用这个记录继续试。
        _ = updateArtwork(shell, in: page)
        _ = updateField(in: page)
    }

    /// 页内歌词模式里封面缩略图的框（页面坐标）。
    private static func lyricsThumbFrame(in page: UIView) -> CGRect {
        CGRect(
            x: Self.lyricsThumbLeading,
            y: page.safeAreaInsets.top + Self.lyricsThumbTopInset,
            width: Self.lyricsThumbSide,
            height: Self.lyricsThumbSide
        )
    }

    /// 这个 tilt 是不是**听歌页 contentlayer** 里的那一格（`nowplaying-contentlayer-cell-*`）。
    ///
    /// 换歌时新 cell 可能还没挂到 `lastPage` 底下，所以不能要求它在页面子树里；但也不能
    /// 只认 `CoverArtCellImpl`（专辑页页头也用 `ArtworkImage` 那一族）。这条按 id 走祖先链，
    /// 只命中听歌页。
    private static func isNowPlayingCoverCell(_ view: UIView) -> Bool {
        var node: UIView? = view
        var hops = 0
        while let current = node, hops < 10 {
            if let id = current.accessibilityIdentifier, id.contains("nowplaying-contentlayer-cell") {
                return true
            }
            node = current.superview
            hops += 1
        }
        return false
    }

    // MARK: - 布局

    @discardableResult
    private static func layout(in page: UIView) -> Bool {
        var changed = false
        // 封面壳还没认出来时也要让"元数据封面"开始加载（它不依赖壳）。
        if let trackId = NowPlayingLyricsPlate.currentTrackId() {
            refreshMetadataArtwork(trackId: trackId)
        }
        // **先摆不依赖封面壳的那几行**：换歌 / 关歌词的头一两拍，新的封面 cell 还没挂到
        // 页面上（`resolvedShell` 返回 nil），若"先 resolve 封面、拿不到就 return"，
        // 标题行根本不回来、底排也不重排。这几样只认控件自己的 id，与封面无关。
        //
        // ⚠️ 顺序不能动：`placeBottomStack` 的 -55pt 是 `placeTitleRow` 量自然位置的
        // 前提（标题行就长在这个 stack 里）。
        if placeBottomStack(in: page) { changed = true }
        if placeTitleRow(in: page) { changed = true }
        // `setLyricsMode` 那一拍标题可能还没量到（换歌转场/页面重建）⇒ 它把"亮歌词"挂起；
        // 这里每一拍重试，标题真到缩略图旁边了才铺歌词。
        if lyricsModeActive, !lyricsModeRevealed, lyricsRevealPending,
           lyricsSceneReady(in: page) {
            lyricsRevealPending = false
            lyricsModeRevealed = true
            changed = true
        }
        // 页内歌词时，歌名/艺人那两行只是原生 label，不吃触摸 ——
        // 在它们上面各盖一颗透明按钮（点歌名开专辑、点艺人开艺人页）。
        if placeTitleTapTargets(in: page) { changed = true }
        if placeNavChrome(in: page) { changed = true }
        // 进度条（4pt 轨 + 藏圆钮 + 等宽时间），见 `NowPlayingIOS27+Progress.swift`。
        // 它只换 UISlider 的三张图与两颗标签的字体，不碰几何、不碰手势。
        if placeProgress(in: page) { changed = true }
        // 工具行排成 AM 的三颗（歌词 / 隔空播放 / 队列），见 `NowPlayingIOS27+Footer.swift`。
        // ⚠️ 必须排在传输行前面：循环那颗圆钮是**按我们画的那颗队列字形**定位的。
        if placeFooter(in: page) { changed = true }
        // 页内歌词容器：缩略图下沿 + 16 → 进度条上沿 − 18。它也不依赖封面壳，
        // 封面晚到也要能看词。
        // 开歌词时**等封面缩完再挂**（`lyricsModeRevealed`），否则歌词和宿主第一帧的
        // 深色底会压在那张还没缩小的封面上。
        if lyricsModeActive, lyricsModeRevealed, updateLyricsStage(in: page) { changed = true }
        // 歌词区左下角那块「歌词来源 / 提供者/翻译者」。
        // 收起时保留视图、alpha 归 0（和歌词一起淡出），下一次打开直接淡入。
        if placeLyricsCredit(in: page) { changed = true }

        guard let shell = resolvedShell(in: page) else {
            // **别在没图的时候硬留一个洞**。兜底找一次原生封面：
            // · 我们自己已经有东西可画 ⇒ 把兜底那张按下去（避免两张同屏）；
            // · 我们自己什么都没画出来 ⇒ **让原生封面先露着**（宁可这一拍是原生封面，
            // 也不要一片空）。无条件 hideShell 会让原生和我们的都被藏掉。
            if let fallback = fallbackCoverShell(in: page) {
                if artworkView != nil || lastArtworkImage != nil {
                    hideShell(fallback)
                } else {
                    revealShell(fallback)
                }
            }
            // 这一拍没有壳 ⇒ `updateArtwork` 整条不跑。只处理"缩略图长回满屏"那一向的话，
            // **开**歌词那一向（缩成 64pt）就永远没人做 ⇒ 歌词、标题、署名都出来了，
            // 封面还停在整幅帧（"又回溶底"）。两向都走同一条：按当前模式摆好。
            if syncArtworkFrameWithoutShell(in: page) { changed = true }
            if !didLogMissingCover {
                didLogMissingCover = true
                writeDebugLog("[\(logTag)] no on-screen artwork yet — nothing new to draw this tick")
            }
            return changed
        }
        didLogMissingCover = false
        // 认出来了就先按下去（不等 `updateArtwork` 的图）—— 首次进页面时图往往比壳晚一拍，
        // 这一拍不按，屏幕上就是"Spotify 原生大封面闪一下"。
        hideShell(shell)
        artworkShell = shell

        if updateArtwork(shell, in: page) { changed = true }
        // 壳认出来了，`updateArtwork` 仍可能因为量不到整页宿主 / 还没图而提前返回。
        // 模式几何再兜一次 —— 幂等：已经是对的就只做一次比较。
        // ⚠️ 代价是"壳正常"那条路每拍多跑两次 `convert` + 一次 scrim 比较。故意的：
        // `updateArtwork` 的返回值语义是 "changed"，稳态下本来就是 false，拿它当
        // "几何有没有走到"的判据会反过来每拍都去兜底。宁可多两次换算。
        if syncArtworkFrameWithoutShell(in: page) { changed = true }
        if mountField(in: page) { changed = true }
        if !didLogFrames {
            didLogFrames = true
            logFrames(in: page)
        }
        return changed
    }

    /// 页内歌词容器的框（页面坐标）：**缩略图下沿 + 16 → 进度条上沿 − 18**。
    ///
    /// 抽出来是因为「歌词区左下角那行来源」也要贴同一个底边（`placeLyricsCredit`），
    /// 两处各算一份的话改一个数就会错位。
    private static func lyricsStageFrame(in page: UIView) -> CGRect? {
        // 进度条也必须找**当前可见页**那一份 —— pager 里相邻页的副本在 y≈-413，
        // 用它算出来的高度是负数 ⇒ `guard bottom - top > 80` 永远不过，歌词容器就永远不铺。
        // 见 `progressUnit(in:)`。
        guard let progress = progressUnit(in: page) else { return nil }
        let progressRect = progress.convert(progress.bounds, to: page)
        let thumb = lyricsThumbFrame(in: page)
        let top = thumb.maxY + Self.lyricsStageTopGap
        let bottom = progressRect.minY - Self.lyricsStageBottomGap
        guard bottom - top > 80 else { return nil }
        return CGRect(
            x: Self.lyricsStageSideInset,
            y: top,
            width: page.bounds.width - Self.lyricsStageSideInset * 2,
            height: bottom - top
        )
    }

    /// 页内歌词**内容容器**的框：完整 stage 再扣掉底部署名的 50pt。
    ///
    /// 署名在 stage 的下沿，而歌词滚到底时最后一行/译文也会落到那里。容器缩短后，
    /// 署名落在容器**下面**、进度条上面，两者不再共用一块区域
    /// （`placeLyricsCredit` 仍按完整 stage 定位）。
    private static func lyricsContainerFrame(in page: UIView) -> CGRect? {
        guard var frame = lyricsStageFrame(in: page) else { return nil }
        guard frame.height - Self.lyricsCreditReserve > 120 else { return frame }
        frame.size.height -= Self.lyricsCreditReserve
        return frame
    }

    /// 页内歌词的容器。只铺歌词（`mountLyricsOnly`），不碰控件条 / 底部按钮。
    @discardableResult
    private static func updateLyricsStage(in page: UIView) -> Bool {
        // 标题还没挪到缩略图旁边时**不要铺** —— 容器会盖住还留在原生 y=550 的歌名/艺人。
        // 把"已露面"退回去、下一拍标题到位后重新淡入；署名也跟着 alpha 0，不会单独飘着。
        guard titleRowPlaced(in: page) else {
            if lyricsModeRevealed {
                lyricsModeRevealed = false
                lyricsRevealPending = true
            }
            if NowPlayingLyricsPlate.lastContainer != nil {
                NowPlayingLyricsPlate.unmountLyricsOnly()
            }
            return false
        }
        guard let frame = lyricsContainerFrame(in: page) else {
            NowPlayingLyricsPlate.unmountLyricsOnly()
            return false
        }
        let mounted = NowPlayingLyricsPlate.mountLyricsOnly(in: page, frame: frame)
        // 歌词容器一直伸到进度条上沿（587），而收藏键（AddToButton）在 348,549,48×48
        // —— 它的上半截落在容器里，`NowPlayingLyricsContainerView` 又只在底部那一条放行
        // 触摸 ⇒ 点 ✓ 被容器吃掉。这里把收藏键的框登记成"放行区"。
        if mounted,
           let container = NowPlayingLyricsPlate.lastContainer as? NowPlayingLyricsContainerView {
            // 收藏键贴着右边缘（348…396），默认 20% 闸门会把它筛掉；
            // pager 里还有相邻页的副本 ⇒ 用 visibleView（margin 0）只认当前页那一颗。
            let like = visibleView(identifier: "Components.UI.AddToButton", in: page)
            if let like {
                let rect = like.convert(like.bounds, to: page).insetBy(dx: -6, dy: -6)
                container.passThroughRects = [container.convert(rect, from: page)]
            } else if !container.passThroughRects.isEmpty {
                container.passThroughRects = []
            }
        }
        return mounted
    }

    /// 兜底找原生封面壳：**不要求"在屏中间"、也不看 alpha**。
    ///
    /// 换歌转场里，新封面恰好是这两个判据都会把它筛掉的时刻（`visibleCover` 认 `alpha > 0.01`，
    /// 而 Spotify 的新封面对象先以 `alpha = 0` 出现）。这里只认 id + 尺寸够大。
    private static func fallbackCoverShell(in page: UIView) -> UIView? {
        var roots: [UIView] = [page]
        if let list = NowPlayingLyricsPlate.findByIdentifier(
            NowPlayingLyricsPlate.listIdentifier, in: page
        ) {
            roots.append(list)
        }
        for root in roots {
            var queue: [UIView] = [root]
            var visited = 0
            while !queue.isEmpty, visited < 2000 {
                let view = queue.removeFirst()
                visited += 1
                queue.append(contentsOf: view.subviews)
                guard view.accessibilityIdentifier == NowPlayingLyricsPlate.coverImageIdentifier
                else { continue }
                let rect = view.convert(view.bounds, to: page)
                guard rect.width >= 200, rect.height >= 200 else { continue }
                return view
            }
        }
        return nil
    }

    /// 这一拍该用哪张封面。
    ///
    /// 1. **先认自己画过的那张**：我们把原生壳 `alpha = 0` 之后，`visibleCover` 的判据
    /// （`alpha > 0.01 || isHiddenByUs`）不再认它 —— 只靠它每拍都会早退。
    /// 2. **挡住"挑到离屏那张"**：横向翻页转场中途会出现 `at 399,161` / `at -138252,161`
    /// 这种格子，画进去等于屏幕上什么都没有。
    private static func resolvedShell(in page: UIView) -> UIView? {
        if let shell = artworkShell, shell.window != nil,
           isControlOnPage(shell, in: page, requireAlpha: false),
           isNowPlayingCoverCell(shell) {
            return shell
        }
        guard let list = visibleList(in: page),
              let picked = NowPlayingLyricsPlate.visibleCover(in: list, page: page),
              isControlOnPage(picked, in: page, requireAlpha: false) else { return nil }
        return picked
    }

    /// 当前页的 `listIdentifier` 那一份（pager 里相邻页还有一份，不能拿错）。
    private static func visibleList(in page: UIView) -> UIView? {
        var queue: [UIView] = [page]
        var visited = 0
        while !queue.isEmpty, visited < 3000 {
            let view = queue.removeFirst()
            visited += 1
            if view.accessibilityIdentifier == NowPlayingLyricsPlate.listIdentifier,
               isControlOnPage(view, in: page, requireAlpha: false) {
                return view
            }
            queue.append(contentsOf: view.subviews)
        }
        return nil
    }

    /// 这个控件是不是**当前可见的那一页**上的。
    ///
    /// 听歌页的 pager 里会同时留着相邻页的 cell，`findByIdentifier` 的 BFS 经常先撞上
    /// **离屏**那一页的 `npv.bottomStackView`（`-413…-413`，而屏幕上那一份在 4,543）。
    /// 结果是我们搬了离屏的标题/底排，屏幕上的歌名/封面不动；`lyricsSceneReady`
    /// 又永远等不到，歌词一直 `deferred`。所有"按 id 找控件"的地方都必须过这一道。
    static func isControlOnPage(
        _ view: UIView,
        in page: UIView,
        requireAlpha: Bool = true,
        horizontalMargin: CGFloat = 0.2
    ) -> Bool {
        guard view.window != nil, !view.isHidden else { return false }
        if requireAlpha, view.alpha <= 0.01 { return false }
        let rect = view.convert(view.bounds, to: page)
        guard rect.width > 1, rect.height > 1 else { return false }
        let minX = page.bounds.width * horizontalMargin
        let maxX = page.bounds.width * (1 - horizontalMargin)
        return rect.midX > minX
            && rect.midX < maxX
            && rect.midY > 0
            && rect.midY < page.bounds.height
    }

    /// 全页 BFS，只返回**当前可见页**上的那一个（pager 里相邻页的副本会被跳过）。
    ///
    /// `horizontalMargin` 默认 0：只要求中线落在页面横向范围内。贴边的小控件
    /// （底排三颗、收藏 ✓）用默认的 20% 闸门会被全部筛掉 —— 见 `footerControl`。
    static func visibleView(
        identifier: String,
        in page: UIView,
        requireAlpha: Bool = false,
        horizontalMargin: CGFloat = 0,
        limit: Int = 3000
    ) -> UIView? {
        var queue: [UIView] = [page]
        var visited = 0
        while !queue.isEmpty, visited < limit {
            let view = queue.removeFirst()
            visited += 1
            if view.accessibilityIdentifier == identifier,
               isControlOnPage(
                   view,
                   in: page,
                   requireAlpha: requireAlpha,
                   horizontalMargin: horizontalMargin
               ) {
                return view
            }
            queue.append(contentsOf: view.subviews)
        }
        return nil
    }

    /// 把这一首**元数据里的专辑封面**取回来（异步、按曲目 id 缓存）。
    ///
    /// 为什么不能只信播放页 contentlayer 里的那张图：那里有时候是 Canvas / 艺人图，
    /// 不是专辑封面。
    /// `SPTPlayerTrack.metadata["image_url"]` 是这首曲目的专辑封面，
    /// `LyricsArtworkResolver` 已经把它翻译成 `i.scdn.co` 地址（歌词背景在用同一条链）。
    private static func refreshMetadataArtwork(trackId: String) {
        if trackId != metadataArtworkTrackId {
            metadataArtworkTrackId = trackId
            metadataArtworkImage = nil
            metadataArtworkLoading = false
            metadataArtworkAttempts = 0
        }
        guard !trackId.isEmpty,
              !metadataArtworkLoading,
              metadataArtworkImage == nil else { return }
        if let cached = metadataArtworkCache[trackId] {
            metadataArtworkImage = cached
            return
        }
        // 最多试 6 次（≈1.8s）：metadata 有时比播放器晚一两拍才就绪，失败也不无限刷。
        guard metadataArtworkAttempts < 6,
              let track = statefulPlayer?.currentTrack(),
              let url = LyricsArtworkResolver.artworkURL(for: track) else { return }
        metadataArtworkAttempts += 1
        metadataArtworkLoading = true
        URLSession.shared.dataTask(with: url) { data, _, _ in
            let image = data.flatMap { UIImage(data: $0) }
            DispatchQueue.main.async {
                guard metadataArtworkTrackId == trackId else { return }
                metadataArtworkLoading = false
                guard let image else { return }
                metadataArtworkImage = image
                metadataArtworkCache[trackId] = image
                metadataArtworkOrder.append(trackId)
                while metadataArtworkOrder.count > metadataArtworkCacheLimit {
                    metadataArtworkCache.removeValue(forKey: metadataArtworkOrder.removeFirst())
                }
                // 图到了：下一拍就把它画上去（壳里的图只当兜底）。
                if let page = lastPage, page.window != nil {
                    _ = layout(in: page)
                }
            }
        }.resume()
    }

    /// 把封面壳摆上去 —— 有图就画我们的、把原生的按下去；
    /// 没图就让原生那张先露着（**绝不空白**）。
    @discardableResult
    private static func updateArtwork(_ shell: UIView, in page: UIView) -> Bool {
        // 这颗壳可能正是我们为了藏原生封面而按成 alpha = 0 的那一颗；不能因为
        // “它透明”就拒绝它，否则封面永远画不上、歌词闸门永远不过。
        guard isControlOnPage(shell, in: page, requireAlpha: false) else { return false }
        artworkShell = shell
        let trackId = NowPlayingLyricsPlate.currentTrackId() ?? ""
        let trackChanged = trackId != lastTrackId
        // 先确保这一首的**元数据封面**在取（或已取到）。
        refreshMetadataArtwork(trackId: trackId)

        // **优先用元数据里的专辑封面**。播放页 contentlayer 里有时候摆的是 Canvas 帧 /
        // 艺人图（`firstImage(in: shell)` 会把它当成封面，field 也跟着错），而
        // `SPTPlayerTrack.metadata["image_url"]` 才是这首的专辑封面。
        // 壳里的图只负责"元数据图还没到的那一两拍"兜底。
        var image: UIImage? = metadataArtworkImage
        if image == nil {
            image = NowPlayingLyricsPlate.firstImage(in: shell)
        }
        if image == nil {
            image = lastArtworkImage
        }
        if image == nil {
            if trackChanged {
                // 不能 `revealShells` 把原生封面放出来等图 —— "等图"的那一两拍正是
                // 露出来的那张原生大封面。**保持按下去**，露我们自己的背景 field；
                // 图一到下一拍就画上来。
                return false
            }
            // 刚进页面的头几拍：允许缓存兜底（那时还没有"上一首"的问题）。
            image = NowPlayingLyricsPlate.rememberArtworkIfNeeded(in: page)
        }

        guard let image, let host = fullPageAncestor(of: shell, in: page),
              isControlOnPage(host, in: page) else {
            // **不要把上一拍画上去的那张藏起来**。
            //
            // 这里若 `artworkView?.isHidden = true`，换歌时新的 cell 还没量到宿主，
            // 我们的封面被藏掉、原生壳又早被 `coverDidLayOut` 按成 0 ⇒ 屏幕上没有专辑图。
            // 保留我们那张（旧图也是同一张专辑的图），只把原生壳按下去；等宿主出现再换新图。
            if artworkView == nil {
                // 我们自己**一张都没有**：让原生封面先露着，别留洞。
                revealShell(shell)
            } else {
                hideShell(shell)
                if !didLogArtworkHold {
                    didLogArtworkHold = true
                    writeDebugLog(
                        "[\(logTag)] cover host not ready — keeping the previous artwork"
                            + " instead of hiding it (no hole)"
                    )
                }
            }
            return false
        }

        let imageView: UIImageView
        if let existing = artworkView, let currentHost = artworkHost,
           existing.superview === host, currentHost === host {
            imageView = existing
        } else {
            teardownArtwork()
            let view = UIImageView(frame: .zero)
            view.contentMode = .scaleAspectFill
            view.clipsToBounds = true
            view.isUserInteractionEnabled = false
            view.accessibilityIdentifier = "eevee-ios27-artwork"
            host.addSubview(view)
            artworkHost = host
            artworkView = view
            imageView = view
        }

        var changed = false
        if imageView.isHidden {
            imageView.isHidden = false
            changed = true
        }
        if trackId != lastTrackId || imageView.image !== image {
            imageView.image = image
            // 缓存"上一次画上去的那张"：换歌时新图没到，就靠它顶着（见上面 `lastArtworkImage` 的说明）。
            lastArtworkImage = image
            lastTrackId = trackId
            changed = true
            if !didLogArtwork {
                didLogArtwork = true
                writeDebugLog(
                    "[\(logTag)] artwork up — \(Int(image.size.width))×\(Int(image.size.height))"
                        + " in \(NSStringFromClass(type(of: host)))"
                )
            }
        }

        // 封面画多大、什么形状：几何见 `artworkFrame(in:host:)`，形状见 `applyArtworkMode(to:)`。
        // ⚠️ 先改 frame 再换形状：下沿那条淡出 mask 的 frame 是照 `bounds` 算的，
        // 反过来会让 mask 慢一拍（收起/展开的那一段看得见）。
        let wanted = artworkFrame(in: page, host: host)
        if imageView.frame != wanted {
            imageView.frame = wanted
            changed = true
        }
        if applyArtworkMode(to: imageView) { changed = true }
        // 一次性诊断：封面到底被放在哪、宿主多大 —— 用来区分是宿主坐标还是帧子算错。
        if !didLogArtworkFrame {
            didLogArtworkFrame = true
            writeDebugLog(
                "[\(logTag)] artwork frame — \(Int(wanted.minX)),\(Int(wanted.minY))"
                    + " \(Int(wanted.width))×\(Int(wanted.height))"
                    + " · host \(Int(host.bounds.width))×\(Int(host.bounds.height))"
                    + " · page \(Int(page.bounds.width))×\(Int(page.bounds.height))"
            )
        }
        if updateTopScrim(in: host, page: page) { changed = true }
        // 我们的封面在原生那张**上面**（同一个 cell 里），原生那张必须按下去。
        hideShell(shell)
        return changed
    }

    /// **满幅**那张封面的 frame（页面坐标 → 宿主坐标）：宽 = 页宽、高 = 页高的 58%
    /// （AM 的竖长裁切，见 `artworkHeightRatio` / `artworkMaxAspect`）。
    ///
    /// 单独抽出来是给「化开层」（`beginLyricsDissolve`）用的：它要的永远是满幅，
    /// 而那时 `lyricsModeActive` 已是 true —— 直接调 `artworkFrame` 会拿到 64pt。
    private static func fullBleedArtworkFrame(in page: UIView, host: UIView) -> CGRect {
        let coverWidth = page.bounds.width
        let coverHeight = max(
            coverWidth,
            min(page.bounds.height * Self.artworkHeightRatio, coverWidth * Self.artworkMaxAspect)
        )
        return host.convert(CGRect(x: 0, y: 0, width: coverWidth, height: coverHeight), from: page)
    }

    /// 封面在**当前模式**下的 frame（宿主坐标）。
    ///
    /// · 普通：`fullBleedArtworkFrame`（**宽 = 页宽，高 = 页高的 58%**）；
    /// · 页内歌词模式：左上角 **64pt 缩略图**（只动封面/标题，底部按钮保持 iOS 27 的样子）。
    ///
    /// 抽出来的理由：`updateArtwork`（有壳）和 `syncArtworkFrameWithoutShell`（没壳）
    /// 必须**用同一份几何**，否则"有壳时缩、没壳时停在上一帧"这种半成品又会回来。
    private static func artworkFrame(in page: UIView, host: UIView) -> CGRect {
        if lyricsModeActive {
            return host.convert(lyricsThumbFrame(in: page), from: page)
        }
        return fullBleedArtworkFrame(in: page, host: host)
    }

    /// 让一张**已经画出来的**封面服从当前模式：满幅 ⇄ 64pt 缩略图，
    /// 连同圆角 / 裁剪 / 下沿淡出 mask 一起换（三样必须同进同退）。
    @discardableResult
    private static func applyArtworkMode(to imageView: UIImageView) -> Bool {
        var changed = false
        if lyricsModeActive {
            if imageView.layer.cornerRadius != Self.lyricsThumbCorner {
                imageView.layer.cornerRadius = Self.lyricsThumbCorner
                imageView.layer.cornerCurve = .continuous
                changed = true
            }
            if !imageView.clipsToBounds {
                imageView.clipsToBounds = true
                changed = true
            }
            if imageView.layer.mask != nil {
                imageView.layer.mask = nil
                // 只摘 `layer.mask` 的话，`artworkMask` 还指着那块 gradient ⇒
                // 收起时 `applyArtworkFadeMask` 以为"已经有 mask"，只改 frame、**不重新挂**，
                // 封面下沿就永远硬切。把账一起清掉。
                artworkMask = nil
                changed = true
            }
        } else {
            if imageView.layer.cornerRadius != 0 {
                imageView.layer.cornerRadius = 0
                changed = true
            }
            if imageView.clipsToBounds {
                imageView.clipsToBounds = false
                changed = true
            }
            // mask 可能在歌词模式里被摘掉，必须按身份重新挂。
            if applyArtworkFadeMask(to: imageView) { changed = true }
        }
        return changed
    }

    /// 把自己画的那张封面按**当前模式**摆好 —— 不依赖封面壳。
    ///
    /// 只处理"收起歌词时长回满屏"那一向的话，（打开时缩成 64pt）只有 `updateArtwork` 会做，
    /// 而它必须先认出封面壳（`resolvedShell`）再量到整页宿主 —— 那两道里只要有一道没过，
    /// 封面就**停在上一次的整幅帧**上：歌词、缩进过的标题、署名全出来了，缩略图位置空着。
    /// 两向合一：只要封面还挂在一个活着的宿主里，就按模式摆好；不碰任何原生视图。
    @discardableResult
    private static func syncArtworkFrameWithoutShell(in page: UIView) -> Bool {
        // 宿主就认**封面真正挂在的那一层**（`superview`）。不要写 `?? artworkHost` 兜底：
        // 下一行要 `view.superview === host`，兜底永远过不去。封面本来也只会被挂进 `host`，
        // 宿主没挂上时这一拍本来就无从摆位置。
        guard let view = artworkView,
              let host = view.superview,
              host.window != nil,
              host.isDescendant(of: page),
              view.image != nil else { return false }
        var changed = false
        if view.isHidden {
            view.isHidden = false
            changed = true
        }
        // ⚠️ 与 `updateArtwork` 同一条：先 frame、再形状（mask 的 frame 照 bounds 算）。
        let wanted = artworkFrame(in: page, host: host)
        if view.frame != wanted {
            view.frame = wanted
            changed = true
            // 说明 `updateArtwork` 那一拍没有走到几何（壳认不出来 / 宿主量不到）。
            if !didLogWithoutShell {
                didLogWithoutShell = true
                writeDebugLog(
                    "[\(logTag)] artwork: \(lyricsModeActive ? "thumbnail" : "full bleed")"
                        + " fixed from the remembered host — updateArtwork did not reach"
                        + " the geometry this tick"
                )
            }
        }
        if applyArtworkMode(to: view) { changed = true }
        // 压暗带跟着封面走（歌词模式里它只该盖住状态栏那一段，见 `updateTopScrim`）。
        if updateTopScrim(in: host, page: page) { changed = true }
        return changed
    }

    /// 状态栏那一带的压暗（封面**不下移**，只压亮度；见 `topScrimExtraHeight`）。
    ///
    /// 盖在封面之上、同一个 cell 里：0…(safeArea.top + 64)，黑 0.34 → 0.12 → 透明。
    /// 曲名在 545、离这一带很远，所以不会把标题压暗。
    @discardableResult
    private static func updateTopScrim(in host: UIView, page: UIView) -> Bool {
        // 页内歌词模式下封面缩略图就长在状态栏下面（`lyricsThumbTopInset` = 46），
        // 这条压暗带有 96…112pt 高、还插在封面**上面**，会横过缩略图上沿。
        // 那一档只保留状态栏那一段（顶层安全区量到 0 时也就 1pt：宁可没有这条压暗，
        // 也不让它压到缩略图）。
        let height = lyricsModeActive
            ? max(page.safeAreaInsets.top, 1)
            : max(page.safeAreaInsets.top + topScrimExtraHeight, topScrimMinHeight)
        let frame = host.convert(
            CGRect(x: 0, y: 0, width: page.bounds.width, height: height),
            from: page
        )

        var changed = false
        let scrim: UIView
        if let existing = topScrim, existing.superview === host {
            scrim = existing
        } else {
            teardownTopScrim()
            let fresh = UIView(frame: frame)
            fresh.isUserInteractionEnabled = false
            fresh.accessibilityIdentifier = "eevee-ios27-top-scrim"
            let gradient = CAGradientLayer()
            gradient.name = "eevee-ios27-top-scrim-gradient"
            gradient.colors = [
                UIColor.black.withAlphaComponent(0.34).cgColor,
                UIColor.black.withAlphaComponent(0.12).cgColor,
                UIColor.clear.cgColor,
            ]
            gradient.locations = [0, 0.55, 1]
            gradient.startPoint = CGPoint(x: 0.5, y: 0)
            gradient.endPoint = CGPoint(x: 0.5, y: 1)
            fresh.layer.addSublayer(gradient)
            if let art = artworkView, art.superview === host {
                host.insertSubview(fresh, aboveSubview: art)
            } else {
                host.addSubview(fresh)
            }
            topScrim = fresh
            scrim = fresh
            changed = true
        }
        if scrim.frame != frame {
            scrim.frame = frame
            changed = true
        }
        if let gradient = scrim.layer.sublayers?.first as? CAGradientLayer,
           gradient.frame != scrim.bounds {
            gradient.frame = scrim.bounds
            changed = true
        }
        if !didLogTopScrim {
            didLogTopScrim = true
            writeDebugLog(
                "[\(logTag)] top scrim — 0…\(Int(height))pt, black 0.34 → 0.12 → clear"
                    + (lyricsModeActive
                        ? " (lyrics mode: only the status-bar band, the thumbnail stays clear)"
                        : " (the artwork still runs full-bleed under the island)")
            )
        }
        return changed
    }

    /// 封面自己下沿的淡出：一条"白 → 白 → 透明"的渐变 mask（淡进下面的模糊拷贝，无硬边）。
    @discardableResult
    private static func applyArtworkFadeMask(to imageView: UIImageView) -> Bool {
        let mask: CAGradientLayer
        if let existing = artworkMask {
            mask = existing
        } else {
            let fresh = CAGradientLayer()
            fresh.colors = [
                UIColor.white.cgColor,
                UIColor.white.cgColor,
                UIColor.clear.cgColor,
            ]
            fresh.locations = [0, NSNumber(value: Double(artworkFadeStart)), 1]
            fresh.startPoint = CGPoint(x: 0.5, y: 0)
            fresh.endPoint = CGPoint(x: 0.5, y: 1)
            artworkMask = fresh
            mask = fresh
        }
        var changed = false
        // mask 可能**已经被摘掉**（歌词模式的缩略图那一向 `imageView.layer.mask = nil`），
        // 而 `artworkMask` 还是旧的。只在"新建"那一支挂 mask 的话，收起歌词后永远不重新挂、
        // 封面下沿硬切。每次都比一下身份。
        if imageView.layer.mask !== mask {
            imageView.layer.mask = mask
            changed = true
        }
        if mask.frame != imageView.bounds {
            mask.frame = imageView.bounds
            changed = true
        }
        return changed
    }

    // MARK: - 背景 field（pw 的配方）
    //
    // 字段色底 + 封面的模糊延续 + 压暗纱。
    //
    // 层次（从下往上）：
    // `solid`（字段色，整图均值）→ `backdrop`（整张封面缩到 48pt 再模糊，aspectFill）
    // → `black`（64% 起渐到 42% 黑）→ 我们那张锐利封面（`updateArtwork` 加的，下沿自己淡出）。
    //
    // ⚠️ 模糊层必须是**整张**封面缩到 48pt 再模糊。按"封面下沿裁一条 + 固定 28pt 半径"
    // 做的话半径相对小图过大，会糊成一块灰。
    @discardableResult
    private static func mountField(in page: UIView) -> Bool {
        guard let shell = artworkShell,
              let host = fullPageAncestor(of: shell, in: page) else { return false }
        // **最后一道闸** —— 只要宿主在绘制顺序上位于 `npv.bottomStackView` 之上
        // （或者把它包在里面），这块整页大的 field 就一定会盖住标题/进度/传输/收藏。
        // 宁可这一拍不铺底，也不能让控件消失；下一拍 Spotify 把层级调回来就会自动铺上。
        guard !hostWouldCoverControls(host), !hostIsAboveControls(host) else {
            if !didLogCoverHostSkip {
                didLogCoverHostSkip = true
                writeDebugLog(
                    "[\(logTag)] field: refused a host drawn above npv.bottomStackView"
                        + " — the field would cover the title/progress/transport"
                )
            }
            if fieldHost != nil { teardownField() }
            return false
        }

        // wrapper 的框必须用 `host.convert(page.bounds, from: page)`：`page.bounds` 是
        // **页面坐标**，而 wrapper 被加到 `host`（cell）里，host 的原点不一定在页面原点
        // （换歌转场 / 非页面高的 cell 时会偏）⇒ 彩色底与渐变线会跟着错位。
        let fieldFrame = host.convert(page.bounds, from: page)
        if let existing = fieldHost, existing.superview === host {
            var changed = false
            if existing.frame != fieldFrame {
                existing.frame = fieldFrame
                changed = true
            }
            if updateField(in: page) { changed = true }
            if layoutField(in: existing) { changed = true }
            return changed
        }

        teardownField()
        // ⚠️ 重建了 wrapper ⇒ 新的 `fieldSolid` / `fieldBackdrop` 都是空的，必须让
        // `updateField` **重算一遍**（否则它会因为"同一张图已经上过色"而提前返回，
        // 新建出来的那层就停在 `solid = .black`、糊底没有图）。
        lastFieldImage = nil

        let wrapper = UIView(frame: fieldFrame)
        wrapper.isUserInteractionEnabled = false
        wrapper.accessibilityIdentifier = "eevee-ios27-field"

        let solid = UIView(frame: wrapper.bounds)
        solid.isUserInteractionEnabled = false
        solid.backgroundColor = .black
        wrapper.addSubview(solid)

        // 封面下方那块不是纯黑，是**整页一张缩到 48pt 再模糊的封面**（`backdrop(from:)`）：
        // 它只是"颜色的延续"，没有可辨认的细节，所以不会糊成脏块。
        // 层级：solid（字段色，兜底）→ backdrop（模糊封面，aspectFill）→ black（渐变纱）
        // → 我们那张锐利封面（在 wrapper 之上）。
        let backdrop = UIImageView(frame: wrapper.bounds)
        backdrop.isUserInteractionEnabled = false
        backdrop.contentMode = .scaleAspectFill
        backdrop.clipsToBounds = true
        backdrop.accessibilityIdentifier = "eevee-ios27-field-backdrop"
        wrapper.addSubview(backdrop)

        let black = UIView(frame: wrapper.bounds)
        black.isUserInteractionEnabled = false
        black.accessibilityIdentifier = "eevee-ios27-black"
        let blackGradient = CAGradientLayer()
        blackGradient.name = "eevee-ios27-black-gradient"
        // ⚠️ 终点不再是不透明黑：模糊底要透出来（AM 那块是"暗下去"而不是"黑掉"）。
        blackGradient.colors = [
            UIColor.clear.cgColor,
            UIColor.black.withAlphaComponent(blackScrimAlpha).cgColor,
        ]
        black.layer.addSublayer(blackGradient)
        wrapper.addSubview(black)

        // 插在**我们那张封面下面**（cell 里其它原生视图仍在更下面）。
        if let art = artworkView, art.superview === host {
            host.insertSubview(wrapper, belowSubview: art)
        } else {
            host.insertSubview(wrapper, at: 0)
        }

        fieldHost = wrapper
        fieldSolid = solid
        fieldBackdrop = backdrop
        fieldBlack = black
        _ = layoutField(in: wrapper)
        _ = updateField(in: page)

        if !didLogField {
            didLogField = true
            writeDebugLog(
                "[\(logTag)] field mounted in \(NSStringFromClass(type(of: host)))"
                    + " — blurred-backdrop field: scrim \(Int(blackScrimAlpha * 100))% from"
                    + " \(Int(blackFromRatio * 100))% of the page"
            )
        }
        return true
    }

    /// 子层的框（wrapper 是整页坐标）。
    @discardableResult
    private static func layoutField(in wrapper: UIView) -> Bool {
        let bounds = wrapper.bounds
        var changed = false
        if let solid = fieldSolid, solid.frame != bounds {
            solid.frame = bounds
            changed = true
        }
        if let backdrop = fieldBackdrop, backdrop.frame != bounds {
            backdrop.frame = bounds
            changed = true
        }
        if let black = fieldBlack, black.frame != bounds {
            black.frame = bounds
            changed = true
        }
        if let black = fieldBlack,
           let gradient = black.layer.sublayers?.first as? CAGradientLayer {
            if gradient.frame != black.bounds {
                gradient.frame = black.bounds
                changed = true
            }
            let locations = [NSNumber(value: Double(blackFromRatio)), NSNumber(value: 1)]
            if (gradient.locations as? [NSNumber]) != locations {
                gradient.locations = locations
                changed = true
            }
        }

        return changed
    }

    /// 字段色：**按图的身份**重算（同一张图只算一次）；换歌交叉淡入。
    ///
    /// 不能按**曲目 id** 提前返回：换歌第一拍 `firstImage(shell)` 里还是**上一首**那张图，
    /// 拿它算了色、又记下**新**的 `trackId` ⇒ 之后每拍都在第一行提前返回，这一整首都顶着
    /// 上一首的底色（上一首偏黑或取色失败时就是"换了歌、渐变还是黑的"）。
    /// 判据用 `image !== lastFieldImage`：图换了才重算。
    @discardableResult
    private static func updateField(in page: UIView) -> Bool {
        // 图也可能是我们缓存的那张（换歌那一两拍壳里还没图）—— 用**屏幕上那张**算色，
        // 封面和底色才是同一首。元数据里的专辑封面优先（见 `refreshMetadataArtwork`）。
        guard let shell = artworkShell,
              let image = metadataArtworkImage
                ?? NowPlayingLyricsPlate.firstImage(in: shell)
                ?? lastArtworkImage
        else { return false }

        if lastFieldImage === image, fieldSolid != nil { return false }

        let colour = fieldColour(from: image)
        lastFieldImage = image
        lastFieldTrackId = NowPlayingLyricsPlate.currentTrackId() ?? ""
        // 模糊底：同一张源图只算一次（换歌才重做）。
        if lastBackdropSource !== image {
            lastBackdropSource = image
            lastBackdropImage = backdrop(from: image)
        }
        // ⚠️ 必须**显式**标成 ` -> Void`。
        //
        // `fieldSolid?.backgroundColor = colour` 是**可选链赋值**，值类型是 `Void?`
        // ⇒ 只有这一句的闭包会被推断成 ` -> ?`，而 `UIView.transition(animations:)`
        // 要 ` -> Void`，于是报：
        // cannot convert value of type ' -> ?' to expected argument type ' -> Void'
        // 闭包里加第二句 Void 语句也能躲过，但那样一改就复发 —— 把类型写死。
        let apply: () -> Void = {
            fieldSolid?.backgroundColor = colour
            fieldBackdrop?.image = lastBackdropImage
        }
        // 只对我们自己的 wrapper 做交叉淡入（对外层 cell 做 transition 会连 Spotify 的内容一起快照）。
        if let wrapper = fieldHost, wrapper.window != nil {
            UIView.transition(with: wrapper, duration: 0.35, options: .transitionCrossDissolve, animations: apply)
        } else {
            apply()
        }
        return true
    }

    /// 封面**下沿**那一块（与原图同一比例）—— 放在方图底边之下 1:1 接上，所以没有接缝。
    private static func bottomStrip(of image: UIImage) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }
        let height = CGFloat(cgImage.height)
        let width = CGFloat(cgImage.width)
        let cropHeight = max(1, height * stripFraction)
        let rect = CGRect(x: 0, y: height - cropHeight, width: width, height: cropHeight)
        guard let cropped = cgImage.cropping(to: rect) else { return nil }
        return UIImage(cgImage: cropped, scale: image.scale, orientation: image.imageOrientation)
    }

    /// 把封面做成"颜色的延续"：缩到 48pt 宽 → 高斯模糊 → 返回那张小图（屏幕上 `aspectFill` 铺满）。
    ///
    /// 为什么这么小：这块只负责"下半屏整片是同一种颜色"，任何可辨认的细节都会被读成"糊了"。
    /// 按"封面下沿裁一条 + 固定 28pt 半径"做的话，半径相对小图过大，会糊成灰块。
    private static func backdrop(from image: UIImage) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }
        let input = CIImage(cgImage: cgImage)
        let extent = input.extent
        guard extent.width > 1, extent.height > 1 else { return nil }

        let scale = min(1, 48 / extent.width)
        let small = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return nil }
        filter.setValue(small.clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(9, forKey: kCIInputRadiusKey)
        guard let blurred = filter.outputImage?.cropped(to: small.extent) else { return nil }

        // Apple Music 的渐变不是"平均色 + 黑纱"，而是把**专辑图本身**多层扭曲 + 模糊，
        // 并**刻意过饱和**（社区逆向：Mac/网页版会把封面 oversaturate 再叠 4 份）。
        // 我们没有 Metal shader，近似做法是：模糊之后再过一遍 `CIColorControls`
        // （饱和度 ×1.45 / 对比 ×1.05）⇒ 同一张模糊底，颜色更透、不再灰。
        let graded: CIImage
        if let controls = CIFilter(name: "CIColorControls") {
            controls.setValue(blurred, forKey: kCIInputImageKey)
            controls.setValue(1.45, forKey: kCIInputSaturationKey)
            controls.setValue(1.05, forKey: kCIInputContrastKey)
            controls.setValue(0.02, forKey: kCIInputBrightnessKey)
            graded = controls.outputImage?.cropped(to: small.extent) ?? blurred
        } else {
            graded = blurred
        }

        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let cg = context.createCGImage(graded, from: small.extent) else { return nil }
        return UIImage(cgImage: cg)
    }

    /// 从封面取"字段色"：**整张图的平均色**，再拉高饱和度、压到白字读得清的亮度。
    ///
    /// 取**整张图**的平均色而不是封面下沿 30%：很多封面下沿是白色/灰色（人物脚下、
    /// 唱片行、留白），算出来就是一块灰底，和上半张彩色的封面完全不搭。
    /// AM 的底色也来自整张图的平均/主色并刻意过饱和 ⇒ 整图平均 + ×1.45。
    private static func fieldColour(from image: UIImage) -> UIColor {
        guard let average = averageColour(of: image) else { return .black }
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0
        average.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)
        let boosted = min(maxFieldSaturation, saturation * fieldSaturationBoost)
        return UIColor(
            hue: hue,
            saturation: boosted,
            brightness: min(max(brightness, 0.10), maxFieldBrightness),
            alpha: 1
        )
    }

    /// 一张图的**平均色**（`CIAreaAverage` 渲染到 1×1 再读那一个像素）。
    ///
    /// ⚠️ 不要用 `UIImage.getRed(_:green:blue:alpha:)` —— 那是 `UIColor` 的方法；
    /// `UIImage` 只能经 `CGContext` 读像素（这里用 Core Image 一步到位）。
    private static func averageColour(of image: UIImage) -> UIColor? {
        guard let cgImage = image.cgImage else { return nil }
        let input = CIImage(cgImage: cgImage)
        guard let filter = CIFilter(name: "CIAreaAverage") else { return nil }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgRect: input.extent), forKey: kCIInputExtentKey)
        guard let output = filter.outputImage else { return nil }

        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CIContext(options: nil)
        context.render(
            output,
            toBitmap: &pixel,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: nil
        )
        return UIColor(
            red: CGFloat(pixel[0]) / 255,
            green: CGFloat(pixel[1]) / 255,
            blue: CGFloat(pixel[2]) / 255,
            alpha: 1
        )
    }

    // MARK: - 标题行
    //
    // 把 `npv.bottomStackView` 整体上移 `bottomStackYOffset`（逐拍幂等，只写一层 transform）。
    //
    // 为什么选它：曲名 / 进度 / 时间 / 传输行 / 工具行**都在这一个 stack 里**
    // （`npv.bottomStackView` ≈ 406×241），一次 transform 就能把"整块底部"提上去；
    // 逐个行去搬要写五份、还要各自记账，出错面大得多。
    //
    // ⚠️ 必须排在各"量位置"的函数之前（`placeTitleRow` / `placeFooter` / `placeTransport` /
    // 音量行），并且那些地方必须用 **`convert`**（带 transform）而不是 `untransformed`。
    @discardableResult
    private static func placeBottomStack(in page: UIView) -> Bool {
        guard let stack = bottomStackView(in: page) else { return false }
        // 换页/换歌时底排会换对象。旧对象的 transform 必须先还回去，
        // 否则它下次被复用时 base 会记成"已经抬过 55pt"的错值。
        if let previous = bottomStack, previous !== stack,
           let recorded = bottomStackBase, recorded.0 == ObjectIdentifier(previous) {
            previous.transform = recorded.1
            bottomStackBase = nil
        }
        bottomStack = stack

        let key = ObjectIdentifier(stack)
        let base: CGAffineTransform
        if let recorded = bottomStackBase, recorded.0 == key {
            base = recorded.1
        } else {
            base = stack.transform
            bottomStackBase = (key, base)
        }

        let wanted = base.concatenating(
            CGAffineTransform(translationX: 0, y: bottomStackYOffset)
        )
        guard stack.transform != wanted else { return false }
        stack.transform = wanted
        // 音量行是按「传输行下沿 + 工具行上沿」中点算的
        // （`NowPlayingPageOverlay.ios27VolumeY`）。这一坨上移 55pt 之后它必须跟着重算，
        // 否则会停在**上移前**的 785…813 —— 正压在工具行字形（790）上。
        // 只在 transform 变化那一拍调一次。
        NowPlayingPageOverlay.reapply()

        if !didLogBottomStack {
            didLogBottomStack = true
            let rect = stack.convert(stack.bounds, to: page)
            let title = titleRowView(in: page).map { $0.convert($0.bounds, to: page) }
            writeDebugLog(
                "[\(logTag)] bottom stack lifted \(Int(bottomStackYOffset))pt —"
                    + " \(Int(rect.minY))…\(Int(rect.maxY))"
                    + (title.map { ", title row y \(Int($0.minY))" } ?? "")
            )
        }
        return true
    }

    /// 当前页**可见**的底排（跳过 pager 里相邻页的离屏副本）。
    private static func bottomStackView(in page: UIView) -> UIView? {
        var queue: [UIView] = [page]
        var visited = 0
        while !queue.isEmpty, visited < 3000 {
            let view = queue.removeFirst()
            visited += 1
            if view.accessibilityIdentifier == NowPlayingLyricsPlate.bottomStackIdentifier,
               isControlOnPage(view, in: page) {
                return view
            }
            queue.append(contentsOf: view.subviews)
        }
        return nil
    }

    /// 只把标题行的**左边距**收到 28pt（纵向留在原生位置）。
    ///
    /// 为什么不抬上去：抬到 `W+56` 会和进度条之间空出一大块。不搬底部的前提下，
    /// 唯一自洽的做法是"纵向不动"。
    ///
    /// 页内歌词模式下仍把**歌名/艺人挪到缩略图旁边** —— 那一块保留正常信息；
    /// 「歌词来源/提供者」另放歌词区左下角（`placeLyricsCredit`），不再占用标题行。
    @discardableResult
    private static func placeTitleRow(in page: UIView) -> Bool {
        guard let row = titleRowView(in: page) else { return false }
        // 同上：换页时旧标题行先还原，避免复用后 base 记错、越挪越偏。
        if let previous = titleRow, previous !== row,
           let recorded = titleRowBase, recorded.0 == ObjectIdentifier(previous) {
            previous.transform = recorded.1
            titleRowBase = nil
            titleRowBaseRect = nil
        }
        titleRow = row

        let key = ObjectIdentifier(row)
        let base: CGAffineTransform
        let natural: CGRect
        if let recorded = titleRowBase, recorded.0 == key,
           let rect = titleRowBaseRect, rect.0 == key {
            base = recorded.1
            natural = rect.1
        } else {
            base = row.transform
            natural = NowPlayingLyricsPlate.untransformed(row, in: page)
            titleRowBase = (key, base)
            titleRowBaseRect = (key, natural)
        }
        guard natural.width > 1, natural.height > 1 else { return false }

        let dx: CGFloat
        let dy: CGFloat
        if lyricsModeActive {
            // 页内歌词：标题/艺人贴到缩略图右边、与缩略图**竖直居中**。
            // 不能按**顶边**对齐（`thumb.minY`）：缩略图 64pt、标题行 46pt，
            // 文字块会偏上，右边留白比下边多。按中线对齐。
            let thumb = lyricsThumbFrame(in: page)
            dx = (thumb.maxX + 12 - natural.minX).rounded()
            dy = (thumb.midY - natural.midY).rounded()
        } else {
            dx = (titleLeadInset - natural.minX).rounded()
            dy = 0
        }
        let wanted = base.concatenating(CGAffineTransform(translationX: dx, y: dy))
        guard row.transform != wanted else { return false }
        row.transform = wanted
        if !didLogTitle {
            didLogTitle = true
            writeDebugLog(
                "[\(logTag)] title row inset to \(Int(titleLeadInset))pt"
                    + " (kept at its native y \(Int(natural.minY)))"
            )
        }
        return true
    }

    // MARK: - 歌名 / 艺人点击（页内歌词）
    //
    // 在原生歌名 / 艺人两行上各盖一颗透明按钮。
    //
    // 只在**页内歌词已经亮出来**时挂：普通听歌页的标题行离封面很近，
    // 原生自己有一套长按/拖拽手势，没必要去抢。
    @discardableResult
    private static func placeTitleTapTargets(in page: UIView) -> Bool {
        guard lyricsModeActive, lyricsModeRevealed else {
            removeTitleTapTargets()
            return false
        }
        guard let title = labelOnPage(
            identifier: NowPlayingLyricsPlate.titleLabelIdentifier,
            in: page
        ), let artist = labelOnPage(
            identifier: NowPlayingLyricsPlate.subtitleLabelIdentifier,
            in: page
        ) else {
            if !didLogMissingTapLabels {
                didLogMissingTapLabels = true
                writeDebugLog("[\(logTag)] title/artist labels not found — no tap targets")
            }
            return false
        }

        var changed = false
        let titleFrame = tapFrame(for: title, in: page)
        let artistFrame = tapFrame(for: artist, in: page)

        if let button = makeTapTarget(
            existing: titleTapButton,
            in: page,
            frame: titleFrame,
            identifier: "eevee-ios27-title-tap",
            action: openCurrentAlbum
        ) {
            if titleTapButton !== button { titleTapButton = button; changed = true }
            if button.frame != titleFrame { button.frame = titleFrame; changed = true }
        }
        if let button = makeTapTarget(
            existing: artistTapButton,
            in: page,
            frame: artistFrame,
            identifier: "eevee-ios27-artist-tap",
            action: openCurrentArtist
        ) {
            if artistTapButton !== button { artistTapButton = button; changed = true }
            if button.frame != artistFrame { button.frame = artistFrame; changed = true }
        }

        // 「挂上了」这条日志放在**这一层**：两个尺寸（`titleFrame` / `artistFrame`）是这里的局部量，
        // `makeTapTarget` 里看不到它们（否则报 `cannot find 'titleFrame' in scope`）。
        if !didLogTitleTapTargets, titleTapButton != nil || artistTapButton != nil {
            didLogTitleTapTargets = true
            writeDebugLog(
                "[\(logTag)] title/artist tap targets mounted"
                    + " (title \(Int(titleFrame.width))×\(Int(titleFrame.height)),"
                    + " artist \(Int(artistFrame.width))×\(Int(artistFrame.height)))"
            )
        }
        return changed
    }

    /// 返回可复用的按钮；页面换了 / 旧的被摘了就新建一颗。
    private static func makeTapTarget(
        existing: UIButton?,
        in page: UIView,
        frame: CGRect,
        identifier: String,
        action: @escaping () -> Void
    ) -> UIButton? {
        guard frame.width > 1, frame.height > 1 else { return nil }
        let button: UIButton
        if let existing, existing.superview === page {
            button = existing
        } else {
            existing?.removeFromSuperview()
            button = UIButton(type: .custom)
            button.backgroundColor = .clear
            button.accessibilityIdentifier = identifier
            // 无障碍交给下面原生那两行 label；这颗只是透明命中区，别让读屏多读一条。
            button.isAccessibilityElement = false
            button.addAction(
                UIAction { _ in action() },
                for: .touchUpInside
            )
            page.addSubview(button)
        }
        if button.frame != frame { button.frame = frame }
        if page.subviews.last !== button {
            page.bringSubviewToFront(button)
        }
        return button
    }

    private static func tapFrame(for label: UILabel, in page: UIView) -> CGRect {
        let rect = label.convert(label.bounds, to: page).insetBy(dx: -6, dy: -6)
        return rect.intersection(page.bounds)
    }

    private static func labelOnPage(identifier: String, in page: UIView) -> UILabel? {
        var queue: [UIView] = [page]
        var visited = 0
        while !queue.isEmpty, visited < 3000 {
            let view = queue.removeFirst()
            visited += 1
            if let label = view as? UILabel,
               label.accessibilityIdentifier == identifier,
               isControlOnPage(label, in: page) {
                return label
            }
            queue.append(contentsOf: view.subviews)
        }
        return nil
    }

    private static func removeTitleTapTargets() {
        titleTapButton?.removeFromSuperview()
        titleTapButton = nil
        artistTapButton?.removeFromSuperview()
        artistTapButton = nil
    }

    /// 点歌名：打开**当前曲目的专辑**。
    ///
    /// 只用 `album_uri` + `SpotifyURIOpener` 的话两条都可能空转 ——
    /// ① 取不到 metadata（`statefulPlayer` / `loadedTrack` 都拿不到）⇒ 直接 return；
    /// ② 链接分发器没抓到 ⇒ `open` 退回 `UIApplication.open(spotify:…)`，对 App 自己
    /// 就是空操作。两种都表现为"点上去什么都不发生"。
    /// ⇒ 拿不到 URI / 分发器没就绪时，把这一下**转发给原生标题行**（`eeveeFire`）。
    private static func openCurrentAlbum() {
        let uri = currentTrackMetadata()["album_uri"]
        if SpotifyURIOpener.isReady, let uri, !uri.isEmpty {
            writeDebugLog("[\(logTag)] title tap → \(uri)")
            SpotifyURIOpener.open(uri)
            return
        }
        forwardTitleTap(
            reason: (uri?.isEmpty == false)
                ? "the link dispatcher is not ready"
                : "the track has no album_uri"
        )
    }

    /// 点艺人名：打开**当前曲目的艺人页**（同上，兜底转发原生标题行）。
    private static func openCurrentArtist() {
        let uri = currentTrackMetadata()["artist_uri"]
        if SpotifyURIOpener.isReady, let uri, !uri.isEmpty {
            writeDebugLog("[\(logTag)] artist tap → \(uri)")
            SpotifyURIOpener.open(uri)
            return
        }
        forwardTitleTap(
            reason: (uri?.isEmpty == false)
                ? "the link dispatcher is not ready"
                : "the track has no artist_uri"
        )
    }

    /// 兜底：把这一下转发给**原生标题行**（沉浸式里点它本来就有反应）。
    private static func forwardTitleTap(reason: String) {
        guard let page = lastPage, let row = titleRow ?? titleRowView(in: page) else {
            writeDebugLog("[\(logTag)] title tap — \(reason), and the native row is not on screen")
            return
        }
        // `eeveeFireWide`：先发控件/手势，再往上两层找"tap 挂在包装层上"的那种
        // （艺人页那颗 `i` 就是这么找到的，见 `eeveeFireWide` 的说明）。
        if let fired = eeveeFireWide(row) {
            writeDebugLog("[\(logTag)] title tap — \(reason), forwarded to the native row (\(fired))")
        } else {
            writeDebugLog("[\(logTag)] title tap — \(reason), and the native row fired nothing")
        }
    }

    private static func currentTrackMetadata() -> [String: String] {
        let track = statefulPlayer?.currentTrack() ?? nowPlayingScrollViewController?.loadedTrack
        return track?.metadata() ?? [:]
    }

    /// 歌词区**左下角**那块「歌词来源 / 上传者·制作者·翻译者」。
    ///
    /// 放在歌词块底沿、进度条上沿之上 —— 不占标题行（那里保持正常的歌名/艺人）。
    /// 只在歌词模式且已经"该露面"（`lyricsModeRevealed`）时可见；
    /// 收起时保留视图、alpha 归 0（下一次打开直接淡入，不用重建）。
    @discardableResult
    private static func placeLyricsCredit(in page: UIView) -> Bool {
        let view: NowPlayingIOS27LyricsCreditView
        if let existing = lyricsCreditView, existing.superview === page {
            view = existing
        } else {
            lyricsCreditView?.removeFromSuperview()
            let fresh = NowPlayingIOS27LyricsCreditView(frame: .zero)
            fresh.alpha = 0
            page.addSubview(fresh)
            lyricsCreditView = fresh
            view = fresh
        }

        // 位置：**歌词区左下角**、贴着歌词块的下沿（进度条上沿之上）。
        // 宽 300 是有意的：再往右就压到收藏键（348…396）。
        let stage = lyricsStageFrame(in: page) ?? lyricsStageFrameFallback(in: page)
        let height: CGFloat = 38
        let frame = CGRect(
            x: stage.minX + 2,
            y: stage.maxY - height - 4,
            width: min(max(0, stage.width - 4), 300),
            height: height
        )
        var changed = false
        if view.frame != frame {
            view.frame = frame
            changed = true
        }
        view.update(
            title: NowPlayingLyricsCreditInfo.sourceName,
            subtitle: NowPlayingLyricsCreditInfo.rolesText
        )
        let wanted: CGFloat = (lyricsModeActive && lyricsModeRevealed) ? 1 : 0
        if view.alpha != wanted {
            view.alpha = wanted
            changed = true
        }
        if lyricsModeActive, lyricsModeRevealed, page.subviews.last !== view {
            page.bringSubviewToFront(view)
        }
        return changed
    }

    /// 进度条还量不到时（进页面头一两拍）给这块署名一个兜底位置：缩略图下沿往下 80pt。
    private static func lyricsStageFrameFallback(in page: UIView) -> CGRect {
        let thumb = lyricsThumbFrame(in: page)
        return CGRect(
            x: Self.lyricsStageSideInset,
            y: thumb.maxY + Self.lyricsStageTopGap,
            width: page.bounds.width - Self.lyricsStageSideInset * 2,
            height: 120
        )
    }

    // MARK: - 顶部 chrome
    //
    // 顶部：藏掉 Spotify 的歌单名与向下箭头，画一根 AM 那种小横条，⋯ 搬到工具行正中。
    //
    // 为什么不画一个"假关闭键"：AM 那根横条**本来就不是按钮**，是下拉把手的视觉提示；
    // 这一页的下拉关闭挂在列表自己的 pan recogniser 上，藏了箭头照样能划掉。
    @discardableResult
    private static func placeNavChrome(in page: UIView) -> Bool {
        var changed = false
        for identifier in [NowPlayingLyricsPlate.minimizeButtonIdentifier, navTitleIdentifier] {
            // 左上那颗更小（x≈28…76，中线 52），必须 margin 0；
            // pager 里相邻页也有一份，按 id 直接 BFS 会藏错对象。
            guard let view = visibleView(identifier: identifier, in: page) else {
                continue
            }
            if hideChrome(view) { changed = true }
        }
        // ⋯ **不搬**。它住在导航条里（SwiftUI 托管的那一层），**每一帧都会重置 transform** ——
        // 我们 0.3s 一拍地搬回去就是"一直在闪"。要搬得换一种做法（自绘一颗 + 自己拉菜单）。
        if placeGrabber(in: page) { changed = true }
        return changed
    }

    @discardableResult
    private static func placeGrabber(in page: UIView) -> Bool {
        let width: CGFloat = 44
        let height: CGFloat = 5
        let frame = CGRect(
            x: (page.bounds.width - width) / 2,
            y: max(8, page.safeAreaInsets.top + 4),
            width: width,
            height: height
        )
        if let existing = grabber, existing.superview === page {
            guard existing.frame != frame else { return false }
            existing.frame = frame
            return true
        }
        let view = UIView(frame: frame)
        view.backgroundColor = UIColor.white.withAlphaComponent(0.45)
        view.layer.cornerRadius = height / 2
        view.isUserInteractionEnabled = false
        view.accessibilityIdentifier = grabberIdentifier
        page.addSubview(view)
        page.bringSubviewToFront(view)
        grabber = view
        return true
    }

    /// 把一颗原生视图按 `alpha = 0` 藏掉（记原值；`revealChrome` 统一写回）。
    ///
    /// ⚠️ 它是 internal 而不是 private：传输行那两颗也走这一条，于是"记原值 / 收尾写回"
    /// 只有一套实现，`hiddenChrome` / `chromeAlphas` 也只有一份。
    static func hideChrome(_ view: UIView) -> Bool {
        let key = ObjectIdentifier(view)
        if chromeAlphas[key] == nil {
            chromeAlphas[key] = view.alpha > 0.01 ? view.alpha : 1
            hiddenChrome.add(view)
        }
        guard view.alpha != 0 else { return false }
        view.alpha = 0
        return true
    }

    // MARK: - 原生壳的显隐

    private static func hideShell(_ shell: UIView) {
        let key = ObjectIdentifier(shell)
        if shellAlphas[key] == nil {
            let original = shell.alpha
            shellAlphas[key] = original > 0.01 ? original : 1
            hiddenShells.add(shell)
        }
        if shell.alpha != 0 { shell.alpha = 0 }
    }

    private static func revealShells() {
        for shell in hiddenShells.allObjects {
            guard let original = shellAlphas[ObjectIdentifier(shell)] else { continue }
            if shell.alpha != original { shell.alpha = original }
        }
    }

    /// 只把**这一张**原生壳按原值放回来（`revealShells` 是整批）。
    private static func revealShell(_ shell: UIView) {
        guard let original = shellAlphas[ObjectIdentifier(shell)] else { return }
        if shell.alpha != original { shell.alpha = original }
    }

    // MARK: - 收尾
    //
    // 关开关 / 离开页面：把写过的每一处写回去，拆掉我们自己的视图。
    static func restore(reason: String) {
        // 页内歌词先收（它不参与 `hadState` 的账，但必须先拆掉容器与化开层）。
        lyricsDissolveView?.removeFromSuperview()
        lyricsDissolveView = nil
        // 歌名/艺人的透明点击区也要一起收，别留在回收的 cell 上。
        removeTitleTapTargets()
        // 歌词署名视图也要一起收，别留在回收的 cell 上。
        lyricsCreditView?.removeFromSuperview()
        lyricsCreditView = nil
        lyricsModeRevealed = false
        lyricsRevealPending = false
        if lyricsModeActive {
            lyricsModeActive = false
            NowPlayingLyricsPlate.unmountLyricsOnly()
        }
        let hadState = fieldHost != nil || artworkView != nil || titleRowBase != nil
            || bottomStackBase != nil
            || grabber != nil || !shellAlphas.isEmpty || !chromeAlphas.isEmpty
            || progressStyledSlider != nil || progressTimeLabelViews.count > 0
            || repeatPill != nil || footerRelay != nil || !hiddenGlyphs.allObjects.isEmpty
        if didLogRestore || !hadState {
            clearState()
            return
        }
        didLogRestore = true

        revealShells()
        revealChrome()
        // 藏掉的原生字形（循环 / 工具行三颗）—— 与 `revealChrome` 同一套写法，只是目标另一组。
        revealHiddenGlyphs()
        // 底部那一坨的上移也要写回（否则离开页面后下次进页面看到的是被抬高的行）。
        if let stack = bottomStack, let recorded = bottomStackBase,
           recorded.0 == ObjectIdentifier(stack), stack.transform != recorded.1 {
            stack.transform = recorded.1
        }
        grabber?.removeFromSuperview()
        grabber = nil
        if let row = titleRow, let recorded = titleRowBase,
           recorded.0 == ObjectIdentifier(row), row.transform != recorded.1 {
            row.transform = recorded.1
        }
        teardownField()
        teardownArtwork()
        teardownProgress()
        teardownTransport()
        teardownFooter()

        writeDebugLog("[\(logTag)] restored (\(reason)) — native cover, title row and our views are back")
        clearState()
    }

    private static func clearState() {
        lyricsModeActive = false
        lyricsDissolveView?.removeFromSuperview()
        lyricsDissolveView = nil
        lyricsCreditView?.removeFromSuperview()
        lyricsCreditView = nil
        lyricsModeRevealed = false
        lyricsRevealPending = false
        metadataArtworkTrackId = ""
        metadataArtworkImage = nil
        metadataArtworkLoading = false
        metadataArtworkAttempts = 0
        artworkShell = nil
        artworkHost = nil
        artworkView = nil
        artworkMask = nil
        lastArtworkImage = nil
        titleRow = nil
        titleRowBase = nil
        titleRowBaseRect = nil
        removeTitleTapTargets()
        didLogTitleTapTargets = false
        didLogMissingTapLabels = false
        bottomStack = nil
        bottomStackBase = nil
        didLogBottomStack = false
        topScrim = nil
        didLogTopScrim = false
        grabber = nil
        fieldHost = nil
        fieldSolid = nil
        fieldBackdrop = nil
        fieldBlack = nil
        lastBackdropSource = nil
        lastBackdropImage = nil
        lastTrackId = ""
        lastFieldTrackId = ""
        lastFieldImage = nil
        hiddenShells.removeAllObjects()
        shellAlphas.removeAll()
        hiddenChrome.removeAllObjects()
        chromeAlphas.removeAll()
        didLogArtwork = false
        didLogArtworkFrame = false
        didLogField = false
        didLogTitle = false
        didLogFrames = false
        didLogMissingCover = false
        didLogRestore = false
        didLogArtworkHold = false
        didLogCoverHostSkip = false
        didLogWithoutShell = false
        didLogWideGlyphHide = false
        clearProgressState()
        clearTransportState()
        clearFooterState()
        clearHiddenGlyphs()
    }

    private static func revealChrome() {
        for view in hiddenChrome.allObjects {
            guard let original = chromeAlphas[ObjectIdentifier(view)] else { continue }
            if view.alpha != original { view.alpha = original }
        }
    }

    private static func teardownField() {
        fieldHost?.removeFromSuperview()
        fieldHost = nil
        fieldSolid = nil
        fieldBackdrop = nil
        fieldBlack = nil
    }

    private static func teardownArtwork() {
        teardownTopScrim()
        artworkView?.layer.mask = nil
        artworkView?.removeFromSuperview()
        artworkView = nil
        artworkHost = nil
        artworkMask = nil
    }

    private static func teardownTopScrim() {
        topScrim?.removeFromSuperview()
        topScrim = nil
    }

    // MARK: - 小工具
    //
    // 封面壳（tilt 里那张 `Encore.ImageView`）。
    private static func shell(in tilt: UIView) -> UIView? {
        var visited = 0
        var queue: [UIView] = [tilt]
        while !queue.isEmpty, visited < 128 {
            let view = queue.removeFirst()
            visited += 1
            if view.accessibilityIdentifier == NowPlayingLyricsPlate.coverImageIdentifier {
                return view
            }
            queue.append(contentsOf: view.subviews)
        }
        return nil
    }

    /// 标题行：`now-playing-title-label` 的祖父（与 `NowPlayingLyricsPlate.measure` 同一口径）。
    ///
    /// 不能先找 `listIdentifier` 的第一份 list 再在它里面找 label —— pager 里相邻页的 list
    /// 会先被撞上（标题 y = -443）。直接全页 BFS 所有 label，挑**祖父在当前页可见范围**的那一个。
    private static func titleRowView(in page: UIView) -> UIView? {
        var queue: [UIView] = [page]
        var visited = 0
        while !queue.isEmpty, visited < 3000 {
            let view = queue.removeFirst()
            visited += 1
            if view.accessibilityIdentifier == NowPlayingLyricsPlate.titleLabelIdentifier,
               let row = view.superview?.superview,
               isControlOnPage(row, in: page) {
                return row
            }
            queue.append(contentsOf: view.subviews)
        }
        return nil
    }

    /// 标题行是不是**已经**被我们挪到缩略图旁边（而且还在窗口里）。
    ///
    /// 换歌 / 页面重建的头一两拍 `titleRowView` 可能还找不到；标题留在原生 y=550，
    /// 而歌词容器正好盖住 174…569 ⇒ 名字被整块吃掉。用它当"能不能亮歌词"的闸门：
    /// 标题真到了缩略图中线附近再挂容器，下一拍再试。
    private static func titleRowPlaced(in page: UIView) -> Bool {
        guard let row = titleRow, row.window != nil else { return false }
        let rect = row.convert(row.bounds, to: page)
        guard rect.width > 1, rect.height > 1 else { return false }
        let thumb = lyricsThumbFrame(in: page)
        // 中线在缩略图上下各 16pt 以内，且**没有**还停在原生 y（两者差 300+pt 一眼能分开）。
        return abs(rect.midY - thumb.midY) < 16
    }

    /// 我们那张封面是不是**真的落在当前页面上**。
    ///
    /// 换歌时封面可能还挂在上一格 cell 上（`eevee-ios27-artwork@-386,94`，宿主偏了一整页），
    /// 屏幕上只剩模糊底。这时开歌词只会得到"一块歌词卡片 + 没有封面"的半成品。
    /// 等封面回到页面上再亮歌词（下一拍重试）。
    private static func artworkOnPage(in page: UIView) -> Bool {
        guard let view = artworkView, view.window != nil, view.superview != nil else { return false }
        let rect = view.convert(view.bounds, to: page)
        guard rect.width > 8, rect.height > 8 else { return false }
        return rect.midX > 0 && rect.midX < page.bounds.width
            && rect.midY > 0 && rect.midY < page.bounds.height
    }

    /// 页内歌词"可以亮出来"的完整条件：标题已经在缩略图旁边 + 封面真的在当前页上。
    private static func lyricsSceneReady(in page: UIView) -> Bool {
        titleRowPlaced(in: page) && artworkOnPage(in: page)
    }

    /// 工具行：分享键在 `npv.bottomStackView` 里的那一层祖先。
    private static func footerRowView(in page: UIView) -> UIView? {
        guard let stack = NowPlayingLyricsPlate.findByIdentifier(
            NowPlayingLyricsPlate.bottomStackIdentifier,
            in: page
        ), let share = NowPlayingLyricsPlate.findByIdentifier(
            NowPlayingLyricsPlate.shareButtonIdentifier,
            in: page
        ) else { return nil }
        var current: UIView? = share
        while let view = current, view !== stack {
            if view.superview === stack { return view }
            current = view.superview
        }
        return nil
    }

    /// 封面所在的**整页**祖先（contentlayer 的 cell，414×896）。
    ///
    /// 整页大的祖先**不止一个** —— 换歌 / cell 复用时，第一张 414×896 的祖先有可能
    /// 是**控件上面那一层**。我们的 field 是整页大的，插进那一层就会把
    /// `npv.bottomStackView` 整块盖住（缩略图还在，因为它在 field 上面）。
    /// 所以：整页祖先里**跳过任何包含 bottomStack 的**，只认封面自己那一格；
    /// 全都不合适时才退回老行为（至少封面还在）。
    private static func fullPageAncestor(of view: UIView, in page: UIView) -> UIView? {
        var current = view.superview
        var fallback: UIView?
        var visited = 0
        while let candidate = current, candidate !== page, visited < 12 {
            visited += 1
            if candidate.bounds.width >= page.bounds.width - 1,
               candidate.bounds.height >= page.bounds.height - 1,
               isControlOnPage(candidate, in: page, requireAlpha: false) {
                if !hostWouldCoverControls(candidate) {
                    return candidate
                }
                if fallback == nil {
                    fallback = candidate
                    if !didLogCoverHostSkip {
                        didLogCoverHostSkip = true
                        writeDebugLog(
                            "[\(logTag)] cover host: skipped a full-page ancestor that holds"
                                + " npv.bottomStackView (its field would cover the controls)"
                        )
                    }
                }
            }
            current = candidate.superview
        }
        return fallback
    }

    /// 这个祖先是不是**把原生控件也包在里面**（它就是控件上面那一层）。
    ///
    /// 用 `isDescendant(of:)` 而不是按 id 全树 BFS：每拍都要问，成本必须是一个深度读。
    private static func hostWouldCoverControls(_ host: UIView) -> Bool {
        guard let stack = controlsStackForComparison(), stack.window != nil else { return false }
        return stack.isDescendant(of: host)
    }

    /// 宿主的**绘制顺序**是不是在 `npv.bottomStackView` 之上。
    ///
    /// `hostWouldCoverControls` 只查"宿主是不是把控件包在里面"；还有一种更隐蔽的情况 ——
    /// 宿主与控件是**兄弟层级**，而宿主那一支被 Spotify 提到了前面（换歌 / 打开歌词时
    /// 重建 contentlayer 就会这样）。那时 `stack.isDescendant(of: host)` 是假，
    /// 但整页大的 field 照样盖住控件。这里按"从根到该视图的 subview 下标"比较绘制顺序。
    private static func hostIsAboveControls(_ host: UIView) -> Bool {
        guard let stack = controlsStackForComparison(), let window = stack.window,
              host.window === window else { return false }
        if stack.isDescendant(of: host) { return true }
        let hostPath = subviewPath(of: host)
        let stackPath = subviewPath(of: stack)
        guard !hostPath.isEmpty, !stackPath.isEmpty else { return false }
        let count = min(hostPath.count, stackPath.count)
        var i = 0
        while i < count, hostPath[i] == stackPath[i] { i += 1 }
        // 一条是另一条的前缀：`host` 是控件的祖先（控件在 host 里面）⇒ 盖住；
        // 反过来（host 在控件里面）不可能、也不该判成盖住。
        if i == count { return hostPath.count <= stackPath.count }
        return hostPath[i] > stackPath[i]
    }

    /// 从根到 `view` 每一层的 subview 下标。
    private static func subviewPath(of view: UIView) -> [Int] {
        var path: [Int] = []
        var node = view
        while let parent = node.superview {
            path.append(parent.subviews.firstIndex(of: node) ?? 0)
            node = parent
        }
        return Array(path.reversed())
    }

    /// `bottomStack`（可能还没被 `placeBottomStack` 记下来）。
    private static func controlsStackForComparison() -> UIView? {
        if let stack = bottomStack, let page = lastPage, isControlOnPage(stack, in: page) {
            return stack
        }
        guard let page = lastPage else { return nil }
        return bottomStackView(in: page)
    }

    /// 一次性把各行的真实坐标打出来（排查排版问题靠它）。
    private static func logFrames(in page: UIView) {
        func text(_ identifier: String) -> String {
            guard let view = NowPlayingLyricsPlate.findByIdentifier(identifier, in: page) else {
                return "\(identifier)=missing"
            }
            // ⚠️ 用 `convert`（带 transform）：底部那一坨被整体上移 55pt，
            // `untransformed` 打出来的是**上移之前**的坐标，排查时会误判成"没生效"。
            let rect = view.convert(view.bounds, to: page)
            return "\(identifier)=\(Int(rect.minX)),\(Int(rect.minY))"
                + " \(Int(rect.width))×\(Int(rect.height))"
        }
        var parts: [String] = [
            "page=\(Int(page.bounds.width))×\(Int(page.bounds.height))",
            text(NowPlayingLyricsPlate.progressUnitIdentifier),
            text(NowPlayingLyricsPlate.playButtonIdentifier),
            text(NowPlayingLyricsPlate.shareButtonIdentifier),
            text("Components.UI.AddToButton"),
            text(NowPlayingLyricsPlate.bottomStackIdentifier),
            text(NowPlayingLyricsPlate.minimizeButtonIdentifier),
            text(navTitleIdentifier),
            text(contextMenuIdentifier),
        ]
        if let row = titleRow {
            let rect = row.convert(row.bounds, to: page)
            parts.append(
                "titleRow=\(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))×\(Int(rect.height))"
            )
        }
        writeDebugLog("[\(logTag)] frames — " + parts.joined(separator: " · "))
    }
}
