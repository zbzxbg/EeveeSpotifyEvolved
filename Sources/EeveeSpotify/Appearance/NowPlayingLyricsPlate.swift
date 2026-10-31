import Foundation
import SwiftUI
import UIKit
import Orion
import ObjectiveC.runtime


// 「歌词进播放器」：点 footer 那枚歌词字形才展开，再点还原。
//
// 展开时封面让位（Spotify 那条 `alpha 0`，我们自己画同一张图并用 `transform` 缩到 72pt 缩略图），标题行上移右移贴到缩略图旁边，歌词填进"标题之下、进度条之上"让出来的那块。常量（pt）：缩略图 72 / 缩略图—标题 16 / 标题—控件 12 / 标题尾渐隐 20 / 缩略图离封面区顶 8。
//
// 动画：布局永远按"Spotify 封面那个大小与位置"，用 `bounds` + `center` 而不是 `frame`，位移只写在 `transform` 上 ⇒ 复查那趟 0.3s 不会打断动画（transform 非恒等时 `frame` 不可信）。位移 = `CGAffineTransformConcat(Scale, Move)`（先缩放后平移，关于自身中心）。缩放会把圆角一起缩放 ⇒ 想让缩略图"看起来"是 8pt，模型值要写 `8 / scale`。阴影挂在容器上（容器不裁剪）；动画 0.45s + damping 1 + velocity 0，options 带 `AllowUserInteraction` + `BeginFromCurrentState`（后者是连点两次不跳的关键）。Reduce Motion 打开时整段不做动画；换图要在我们那张接上去的那一刻把 Spotify 那条撤掉（早了露空档、晚了两张同屏）。拿不到图就封面留着、歌词等着，不展开。
//
// 两条"必须"（错了封面就卡住）：
// · 收尾（撤掉我们那张 + 把 Spotify 那条写回）必须挂在动画 completion 上，并带令牌 `coverGeneration`（动画没走完又被点开时这次收尾作废）；"已经在对的位置"与"Reduce Motion"这两条路上 completion 也必须被调用，否则 Spotify 那条永远停在 `alpha 0`；
// · 歌词绘制复用 `AppleMusicLyricsOverlayView`（透明档，只有歌词）。
//
// 那枚歌词键：44pt 圆角键 + 半透明白底 + `quote.bubble.fill` 字形（展开时换 `chevron.down`），贴在 `npv.bottomStackView` 的最后一行（footer）水平居中，与原生控件不重叠；找不到 footer 才退回"贴那一坨上面"，再退回"由播放键反推同一条空带"。⚠️ **只借 footer 的 frame，键挂在 `page` 上** —— 塞进 Spotify 的 stack 会变成 `stack.subviews.last`，把"认 footer"这件事本身弄坏。没词时 `alpha = 0.35`，点下去打一行说明为什么没反应。
//
// ⚠️ 顺序：先铺歌词、**再**摆键（封面 / 标题 / 容器都会 `bringSubviewToFront`，后写的赢）；关开关 / 离开页面时那枚键也要拿走（`closeEverything` 的守卫会早退，光靠它会把键留在屏上）。
// 日志 tag：`[NPVLyrics]`。开关：扩展功能 → 听歌页 →「歌词进播放器」。
@MainActor
enum NowPlayingLyricsPlate {

    static let logTag = "NPVLyrics"

    // pw 的常量（原样抄；单位 pt）。
    //
    // ⚠️ 缩略图与它的间距收成 **64 + 12**（pw 是 72 + 16）不是审美偏好，是**算术**：展开时标题行
    // （自己 **308pt 宽**）要右移 `thumbSide + thumbGap` 给缩略图让位 ⇒ 28 + 72 + 16 + 308 = **424 > 414**，
    // 长标题的 marquee 有 10pt 落在屏幕右边之外；28 + 64 + 12 + 308 = **412 ≤ 414** ✓ 全在屏内。
    static let thumbSide: CGFloat = 64
    static let thumbGap: CGFloat = 12
    /// 标题（长标题会滚动）**右侧渐隐起点**离"右边缘"的距离。pw 原值是 12。
    ///
    /// （右滚动的边界还是太靠右了，继续往左偏）：12 → **24**，
    /// 并且它同时用作"离页面右沿"的余量（`applyTitleMask` 里两处都用它）⇒ 长标题的
    /// 渐隐/滚动可见边界一起左移。想再左/再右只改这一个数。
    static let titleGap: CGFloat = 24
    static let titleFade: CGFloat = 20
    static let thumbTop: CGFloat = 8
    /// header 与歌词之间那段**空气**：`stageTop = header 下沿 + 这一条`。
    ///
    /// 取 **24**（缩略图收成 64pt 后 header 下沿 ≈168 ⇒ stageTop = 192）：歌词块整体上移，顶部那条
    /// 淡出带**跟着一起上移**（它就是这块区域的一个比例），一屏多看约 1–2 行。
    ///
    /// ⚠️ 它与 `lyricFadeStops` 是**一对**（这里收到 24 时那边也从 0.12 收到 0.10）：要保证"第一行"
    /// （块顶 + 48pt 内边距）仍落在淡出带**之外**，不会被新位置吃掉。
    static let lyricsTop: CGFloat = 24
    static let lyricsBottom: CGFloat = 8
    /// 歌词块底边与进度条之间的**让位**（kumone：歌词 623 / 进度条 642 ⇒ 19pt）。
    static let lyricGapAboveProgress: CGFloat = 19
    /// 导航条那一行的判据（id）：真机每一份 `[NPVTree]` 里都有
    /// `Tertiary@0,0,48,48,id=now-playing-minimize-button`。
    static let minimizeButtonIdentifier = "now-playing-minimize-button"
    /// 进度条单元的判据（id）：真机树里是
    /// `AutoLayoutStackView@0,0,358,41,id=Components.UI.ProgressBarUnitNowPlaying`。
    static let progressUnitIdentifier = "Components.UI.ProgressBarUnitNowPlaying"

    // MARK:控件条
    //
    // 控件条：进度条上方那条空带（绿色 ✓ 本来就在的那一条）——
    // 这一条放分享键 + 我们的歌词键，绿色 ✓ 原地不动：
    // [分享 58] [我们的歌词键 215] [绿色 ✓ 371 —— 不动]
    // ⚠️ 代价是"关着歌词时它会挡住歌手/歌名" ⇒ 那一档要把标题行挪到左上角
    // （`applyClosedTitleTransform`）。
    //
    // 控件条的**中线**（页面坐标 y）。来源：绿色 ✓ 的中心 ≈626pt
    // （那是 Spotify 自己的位置，**我们不动它**）—— 另外两颗对齐到同一条线。
    static let controlBandMidY: CGFloat = 626

    /// 控件条那一条的**半高**（44pt 高的键 ⇒ 上沿 = `controlBandMidY − 22` = 604）。
    ///
    /// 两个地方要用同一个口径，所以抽出来（原来 22 只写在 `applyContainerPassThrough` 里）：
    /// · 歌词容器从这一条起**放行触摸**（容器底边压在控件条上，不撞的话收藏/分享键点不到）；
    static let controlBandHalfHeight: CGFloat = 22

    /// 下面那一排里某一颗按钮的**中线 x**（页面坐标）—— 控件条要和它**同一条竖线**。
    ///
    /// 为什么不写死坐标：用户的判据是"和下面那颗对齐"，而这排的位置是
    /// Spotify 按屏宽排的（414pt 上 shuffle 39.9 / 播放 208）。量不到（那一颗被藏了 /
    /// 页面还没铺完）才退回兜底常量 —— 宁可回到常量，也不要摆一个左右不齐的键。
    static func transportColumnX(_ identifier: String, in page: UIView) -> CGFloat? {
        // 起点从小到大：整页 BFS 要先趟过列表里那些格子，800 的预算可能在到那儿之前就用完
        // （`visibleShareButton` 上面记过同一件事）。
        var roots: [UIView] = []
        if let player = findByIdentifier(nowPlayingViewIdentifier, in: page) { roots.append(player) }
        roots.append(page)

        for root in roots {
            guard let button = findByIdentifier(identifier, in: root) else { continue }
            let frame = untransformed(button, in: page)
            guard frame.width > 1, frame.midX > 0, frame.midX < page.bounds.width else { continue }
            return frame.midX
        }
        return nil
    }

    /// 分享键的目标中心 x（**兜底值**）。运行时优先量下面那一颗（见 `transportColumnX`）。
    ///
    /// 「分享按键并不和下面的**选择随机播放**按键同一条直线」——
    /// 对的：逐列量出来，分享键中心 **57.4pt**、下面那颗 shuffle 中心 **39.9pt**。
    /// 所以这一格改成**和 shuffle 同一条竖线**；这个常量只是"量不到 shuffle 时"的兜底。
    static let shareButtonCenterX: CGFloat = 40

    /// 歌词键的目标中心 x（**兜底值**）。运行时优先量 `SPTNowPlayingPlayButton`。
    ///
    /// 同上：「歌词按键不和下面的**暂停键**同一条直线」——
    /// 量出来歌词键 **214pt**、播放/暂停 **208pt** ⇒ 改成和它同一条竖线。
    static let toggleCenterX: CGFloat = 208

    /// 控件条要和**下面那一排**对齐，这是那两颗的 id。
    ///
    /// 播放键：`PlayButtonView@0,0,64,64,id=SPTNowPlayingPlayButton`（本文件早就在用它）。
    static let shuffleButtonIdentifier = "Components.UI.ShuffleButton"

    /// 分享键的判据（id）：`EncoreButton@0,0,44,44,id=ShareButtonNowPlayingView`。
    ///
    /// ⚠️ 页里也有**两份**⇒ 和收藏键同一条纪律：
    /// 判据是"**看得见、而且在屏上**的那一份"，不是"按 id 找到的第一份"。
    static let shareButtonIdentifier = "ShareButtonNowPlayingView"

    /// 关着歌词时，标题行放在导航条下沿**下面多少 pt**。
    ///
    /// 导航条下沿 ≈96、**原生大封面顶边 = 145** ⇒ 只有 96…145 这 49pt 可用，取 2 让行落在
    /// **98…144**，卡在中间，不压封面。
    ///
    /// ⚠️ **"行高 46"是估的**：真机量出来是 **51** ⇒ 行下沿 **149** > 封面顶 146，**压住 3pt**
    /// （被压住的正好是第二行 = 歌手那一行的下半截）⇒ 所以才需要 `closedTitleCoverGap` 那道夹子。
    static let closedTitleTopInset: CGFloat = 2

    /// 收起态标题行下沿与大封面顶边之间**至少**留这么多 pt（见 `applyClosedTitleTransform`）。
    ///
    /// 这道夹子是**兜底**：大封面缩到 242pt（`restingCoverSide`）之后它自己的顶边会落到 ≈208，
    /// 离标题行 59pt，本来就不压了；但"封面量不到 / 缩放没生效 / 别的机型"那几种情况下
    /// 这一行仍可能压到封面上 —— 那就往上让 6pt，而不是把歌手名字埋掉。
    static let closedTitleCoverGap: CGFloat = 6

    /// 歌手那一行的判据（id）：真机树里是
    /// `MarqueeLabel@0,24,308,22,id=now-playing-subtitle-label`（标题是 `now-playing-title-label`）。
    static let subtitleLabelIdentifier = "now-playing-subtitle-label"

    // MARK: 封面那两个"画出来"的圆角 + 移动用的弹簧（pw `SGRTokens`）
    //
    // 全尺寸封面时的圆角（pw：`SGRRadiusArtwork = 12`）。
    static let coverFullRadius: CGFloat = 12
    /// **缩略图在 72pt 下"看起来"的圆角**（pw：`SGRRadiusCover = 8`）。
    /// 注意：`transform` 的缩放会把圆角**一起缩放**，所以模型值要**除以 scale**
    /// —— pw 原话：*"a radius under a scale is drawn scaled, so the thumbnail asks for the radius
    /// it wants **divided by the shrink**"*。
    static let thumbDrawnRadius: CGFloat = 8
    /// 移动/缩放用的时长与阻尼：pw 的 `SGRMotionLayout` 是
    /// `animateWithDuration:0.45 usingSpringWithDamping:1 initialSpringVelocity:0`
    /// —— **阻尼 1 = 临界阻尼、不回弹**（"a spring with no overshoot"）。
    static let moveDuration: TimeInterval = 0.45

    /// 歌词区左右内缩。
    static let stageSideInset: CGFloat = 20
    /// 太低就不进场（还没布局完 / 横屏）。
    static let livingHeight: CGFloat = 200
    /// 走查上限（本仓库纪律）。
    static let maxNodes = 800

    // MARK: 「歌词键」那一枚从"隐形热区"改成"看得见的按钮"）
    //
    // 圆形键的边长（与 Spotify 自己的图标键同尺）。
    static let toggleSide: CGFloat = 44
    /// 与"底部那一坨"的间距。
    static let toggleGap: CGFloat = 6
    /// 播放键顶边到"底部那一坨"顶边的距离（真机树：控件行顶 701 − 那一坨顶 558 = 143，
    /// 而 64pt 的播放键在该行内居中 ⇒ 播放键顶 713，713 − 558 = **155**）。
    /// 兜底落点靠它把键放回"封面与那一坨之间那条空带"，而不是压在标题/进度条上。
    static let playToBandTop: CGFloat = 155
    /// 这一首没歌词时那枚键的透明度（pw：没词变灰）。
    static let toggleDisabledAlpha: CGFloat = 0.35
    /// 键上那个字形记的符号名（用来判断"要不要换图"）。
    static var toggleSymbolKey: UInt8 = 0

    // 判据
    static let listIdentifier = "scrolling_npv_collection_view_accessibility_identifier"
    static let bottomStackIdentifier = "npv.bottomStackView"
    static let coverImageIdentifier = "Encore.ImageView"
    static let titleLabelIdentifier = "now-playing-title-label"
    static let playButtonIdentifier = "SPTNowPlayingPlayButton"
    /// 播放器**自己**那份视图。它是"我们要的封面"最硬的那条判据 ——
    /// 播放器的每一件都在它里面（`npv.bottomStackView` 8 / 进度条 13 / 三颗按钮 14 / 标题行 15），
    /// 而**卡片自己的封面在它外面**（与它平级）。从起每份日志都有。
    static let nowPlayingViewIdentifier = "SPTNowPlayingView"

    // 关联对象
    static var containerKey: UInt8 = 0
    /// 歌词区底沿那条**署名**（SL 条款 §6 要的可点署名，见 `ensureCreditLabel`）。
    static var creditLabelKey: UInt8 = 0
    /// 记着那条署名（摘的时候不查 `lastPage`，见 `removeCreditLabel`）。
    static weak var lastCreditLabel: UILabel?

    static weak var lastPage: UIView?
    static weak var lastContainer: UIView?
    /// 新挂上去的 `UIHostingController` 第一帧可能还没画出内容（宿主视图在深色底上
    /// 看起来就是一块黑）。页内歌词每一次「打开」都从 `alpha = 0` 淡进来 0.22s，
    /// 把那一帧盖掉；同一程里后续每拍的重铺不再动 alpha。
    static var lyricsOnlyNeedsFadeIn = true
    /// 挂上宿主之后**等多久再淡入**（秒）。
    ///
    /// `UIHostingController` 挂上后的第一两帧里，
    /// SwiftUI 的内容还没画完，容器那一片会是一块深色。等 0.10s 再淡入，那一帧就在
    /// 容器完全透明的时候画完了；不会跟着淡入被看见。
    static var lyricsOnlyFadeInDelay: TimeInterval = 0
    /// 淡入令牌：挂上之后还没淡入就被收起 / 重挂时，作废上一次的延迟回调。
    static var lyricsOnlyFadeGeneration = 0
    /// 我们自己那份封面：**外层容器**（承载 transform 与阴影）+ **里面的 imageView**（承载圆角与裁剪）。
    ///
    /// 分两层是照 pw 的 `PlayerLyrics.x`：容器**永远按"Spotify 封面那个大小与位置"布局**
    /// （`bounds` + `center`），"缩小 + 往左上挪"**只写在容器的 `transform` 上**。
    /// 这样 `layoutAndMount` 每 0.3s 重排一次也**不会打断动画**；阴影与圆角跟着 transform 一起走，
    /// 不需要每帧重画。
    static weak var coverHost: UIView?
    static weak var coverImage: UIImageView?
    /// ⚠️ 封面 morph 的**取消令牌**现在在 `door.coverGeneration`（它不是"状态"，见 `LyricsDoor`）。
    static weak var lastToggleZone: UIControl?
    static weak var lastUnit: UIView?
    static weak var lastTitleElement: UIView?

    static weak var bandShareButton: UIView?
    /// 接管它之前它自己的 `transform`（还原时**原样写回**，不假设它一定是 identity）。
    static var bandShareOriginalTransform: CGAffineTransform?
    /// 一次开合只报一行（搬到哪里 / 会不会被裁 / 点不点得到）——按 `clearControlBand` 重置。
    static var didLogBandShare = false
    /// "这一页现在没有看得见的分享键"也只报一次（页面还没铺完时会问一次）。
    static var didLogBandShareMissing = false
    /// 关着歌词时被我们挪到左上角的那一行（离开页面 / 关开关时撤回来）。
    static weak var closedTitleRow: UIView?
    /// 同一行里被横向挪开的那个元素（收尾时也要还回去，见 `clearClosedTitleTransform`）。
    static weak var closedTitleElement: UIView?
    /// "找不到标题行"只报一次（进页面的头几拍可能还量不到）。
    static var didLogClosedTitleMissing = false
    /// "关着态那一行摆上了"只报一次（一次一页一行，下一份日志靠它判）。
    static var didLogClosedTitle = false
    /// 我们贴到歌手那一行右边的那一段（`"（NetEase）"`），收尾时按它精确摘掉。
    static var lastArtistSuffix: String?
    /// "贴了一次 / 被 binder 写回了一次"各留一行日志（免得变成"改了没生效"）。
    static var didLogArtistProvider = false
    static var didLogArtistReset = false
    /// 分享键的**替身热区**（那颗键自己点不到，见 `ensureShareRelay`）。
    static weak var bandShareRelay: UIControl?

    static var host: AnyObject?
    static weak var hostPage: UIView?

    /// 「展开到哪一步」的**唯一存储** —— 那六个旗标（`isOpen` / `wantsOpen` / `wantsOpenUntil` /
    /// `pendingOpenUntil` / `pageLeaving` / `coverGeneration`）现在都在这一个对象里，
    /// 状态机与两条窗口的寿命写在 `Appearance/LyricsDoor.swift`（纯逻辑、有单测、
    /// CI 每次 push 都编，见 `.github/workflows/tests.yml` 的 `Tests/LyricsDoor`）。
    ///
    /// ⚠️ 读它要写 `door.x`；**整组一起改**的那几处走它的方法
    /// （`openIntent` / `expireIntent` / `clearRetryWindow` / `armRetryWindowIfNeeded` /
    /// `close` / `pageDidAppear` / `pageWillLeave` / `nextCoverGeneration`），别在这里再写一遍。
    static var door = LyricsDoor()

    static var didLogInstall = false
    static var lastSkipReason = ""

    /// 这一层参不参与：**只看「歌词进播放器」**。
    ///
    /// ⚠️ 这里**不许**再挂「更好的逐词歌词」：那颗开关管的是 **Spotify 原生歌词页**用哪套渲染，
    /// 而这一层**本身就是** Apple Music 那套渲染 —— 挂上它的后果很具体：只开「逐词歌词」时
    /// **整层退出**，用户要的"版式留着、歌词照画"（缩封面 / 标题左上 / 控件条 / 单行歌词）全没了。
    /// 渲染能力由 `canShow` 里那条 **iOS 26** 判据兜着（这一整条链本就是 iOS 26 起的）。
    ///
    /// 这颗键由「修改Spotify听歌页布局」总开关统一写
    /// （`UserDefaults.nowPlayingLayout` 关掉时它也会被写成 `false`）；再叠一道总开关的门，
    /// 保证"总开关关掉 ⇒ 这一套一律不生效"（外部写回 / 导入备份也挡得住）。
    ///
    /// **新的「iOS 27 听歌页」开着时这一层自动让位**（两版布局互斥）——
    /// 它自己会把封面 / 标题行 / 理论上的歌词都拿走，两层同时生效就会打架。
    ///
    /// iOS 27 的页内歌词改由 `NowPlayingIOS27` 自己铺（只借这一层的
    /// `mountLyricsOnly` 容器/宿主），**不再**让这一整层参与 ⇒ 这里保持互斥。
    static var isEnabled: Bool {
        UserDefaults.nowPlayingLayout && UserDefaults.nowPlayingLyricsInPlayer
            && !UserDefaults.nowPlayingIOS27
    }


    // MARK: - 实现分布
    //
    // 这个 enum 的实现在同目录的 extension 文件里（本文件只放常量与状态）：
    // +Lifecycle 对外入口 / reconcile / 展开与收起
    // +Mount layoutAndMount / closeEverything
    // +Geometry 量几何
    // +Cover 封面与缩略图
    // +Title 标题行与控制条
    // +Artist 歌手行
    // +Toggle 歌词键 / 单行歌词 / 标题行触摸转发
    // +Container 容器 / 页脚署名 / 提示 / 节点缓存
    // 宿主类型在 `NowPlayingLyricsHost.swift`，触摸替身在 `NowPlayingLyricsRelayTargets.swift`。
}
