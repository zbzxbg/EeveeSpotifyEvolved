// 「歌词进播放器」——封面与缩略图（缩放 / 隐藏 / 取图 / 圆角）。
// 从 `NowPlayingLyricsPlate.swift` 原样拆出（`NowPlayingLyricsPlate` 的 extension）；
// 形状、动画与硬约束见那个文件的头注。
import Foundation
import SwiftUI
import UIKit
import Orion
import ObjectiveC.runtime

@MainActor
extension NowPlayingLyricsPlate {
    /// 我们缩过的那几张封面（**弱引用**：视图被回收就自动出册）+ 各自**自己的**原 transform。
    ///
    /// 只盯一个对象会让被换下去的那张弹回 366pt。
    static let scaledCovers = NSHashTable<UIView>.weakObjects()
    static var scaledCoverBase: [ObjectIdentifier: CGAffineTransform] = [:]

    /// 每拍把当前那张主封面**缩到 `restingCoverSide`**（见上面那段）。
    ///
    /// ⚠️ 只在真的不一样时才写：`CoverArtTiltView` 那条链上本来就有别人的 transform
    /// （倾斜），每拍无条件重写会把它们打断 —— 与 `applyCoverState` 旁边那条教训同源。
    static func applyCoverRestingScale(in page: UIView) {
        guard restingCoverSide > 1,
              let list = findByIdentifier(listIdentifier, in: page),
              let cover = visibleCover(in: list, page: page) else { return }

        // **只缩"播放器自己那一张"。**
        // `visibleCover` 的兜底那两趟能挑到**卡片**的封面（它自己的注释里写着
        // "卡片自己的封面不在 `SPTNowPlayingView` 里"）—— 把卡片那张缩了就成了新的 bug。
        // 挑不到主封面就**什么都不做**（宁可这一拍还是 366pt，也不许缩错对象）。
        if let owner = findByIdentifier(nowPlayingViewIdentifier, in: page),
           !cover.isDescendant(of: owner) {
            return
        }

        // **按对象记账，而且记的不止一个。**
        //
        // 为什么不是"上一个 / 这一个"两个变量：同一页里**挑中的封面会换** ⇒ 只盯一个对象的话，
        // "这一拍挑中另一个"就会把上一个**还原成 366pt**，而屏幕上正显示的可能正是它 —— 用户会看到
        // 封面在大小之间来回跳。现在：被我们缩过的都记在册（`NSHashTable` 弱引用，视图没了自动出册），
        // 每拍把它们都摆到目标尺寸；离开页面 / 关开关时**逐个**还回各自的原值。
        if scaledCoverBase.count > 2 {
            // 出册的条目要清掉：`ObjectIdentifier` 是地址，视图释放后地址可能被新视图复用。
            let live = Set(scaledCovers.allObjects.map { ObjectIdentifier($0) })
            scaledCoverBase = scaledCoverBase.filter { live.contains($0.key) }
        }

        let key = ObjectIdentifier(cover)
        applyRestingScale(to: cover, key: key, base: scaledCoverBase[key])
    }

    /// 把**这一张**封面当场缩到 `restingCoverSide`（记账 + 缩放）。两个调用点共用：
    /// · 0.3s 复查节拍（`applyCoverRestingScale`，兜底）；
    /// · 封面自己的 `layoutSubviews`（`coverDidLayOut` 的收起态分支，**换歌那一瞬间**）。
    ///
    /// （听歌的时候，会有 Spotify 大封面闪过）：原来只有节拍那一条，
    /// 换歌时新封面先是 366pt，要等下一拍才缩到 242pt ⇒ 那 0~0.3s 就是"大封面闪一下"。
    /// 事件驱动的这一支把空档变成 0；节拍那条继续负责"被 Spotify 写回 transform"的兜底。
    /// `key`/`base` 由调用方传入（节拍那边已经处理过"第一次接管"与出册清理）。
    static func applyRestingScale(
        to cover: UIView,
        key: ObjectIdentifier? = nil,
        base: CGAffineTransform? = nil
    ) {
        guard restingCoverSide > 1 else { return }
        let identifier = key ?? ObjectIdentifier(cover)
        let recorded: CGAffineTransform
        if let base {
            recorded = base
        } else if let existing = scaledCoverBase[identifier] {
            recorded = existing
        } else {
            recorded = cover.transform
        }
        if scaledCoverBase[identifier] == nil { scaledCoverBase[identifier] = recorded }
        scaledCovers.add(cover)

        let natural = cover.bounds.width
        guard natural > 1 else { return }
        let scale = min(1, restingCoverSide / natural)
        // 先让它自己那一套（多半是恒等）作用完，再叠我们的等比缩放 —— 两者都关于锚点（默认中心）。
        let wanted = recorded.concatenating(CGAffineTransform(scaleX: scale, y: scale))
        if cover.transform != wanted { cover.transform = wanted }
    }

    /// 把封面还回**它自己的** `transform`（关开关 / 离开页面 / 页面收尾 —— 不是"收起歌词"）。
    ///
    /// ⚠️ 收起歌词时**不许**调它：那时我们要的正是"缩小的封面"。
    static func restoreCoverScale() {
        for cover in scaledCovers.allObjects {
            guard let base = scaledCoverBase[ObjectIdentifier(cover)] else { continue }
            if cover.transform != base { cover.transform = base }
        }
        scaledCovers.removeAllObjects()
        scaledCoverBase.removeAll()
    }

    static func ensureCover(in page: UIView, geometry: Geometry) -> UIView? {
        // 图片从 Spotify 那个 `Encore.ImageView` 里取（它下面挂着真正的 UIImageView）。
        //
        // ⚠️ **判据必须和 `measure` 用的是同一个**（`visibleCover`）：页面上 `Encore.ImageView` 有一堆
        // （48×48 的图标、64×64 的…），按 id 走有界 BFS 取**第一个匹配**往往**不是那张封面** ⇒ 藏错了
        // 一个小图标、缩略图拿到别人的图，而 **Spotify 的封面一直整张露着**（标题与歌词就画在它上面）。
        let list = findByIdentifier(listIdentifier, in: page)
        let source = list.flatMap { visibleCover(in: $0, page: page) }
        // **先吃缓存**（页面开着的时候就已经认下来的那张），再退回"现在去抓树"。
        // 后者在真机树里经常还没就绪（`UIImageView(alpha=0.00)`），那正是"点了没反应"的来源。
        var availableImage = rememberArtworkIfNeeded(in: page)
        if availableImage == nil, let source { availableImage = firstImage(in: source) }
        if availableImage == nil, let list { availableImage = anyCoverImage(in: list) }

        // （切歌过程中会有 Spotify 原生封面闪过）：
        // 换歌那一两秒里 Spotify 的新封面对象**还没有图**，
        // 而展开页已经铺着 ⇒ `layoutAndMount` 失败 ⇒ 原生封面整张露回来，下一拍又藏掉 = 闪一下。
        // ⇒ 已经有我们自己那张宿主时，**先留着上一帧的图**把这一拍铺住（同图不同曲也看不出来），
        // 新图一到就原地替换。只有第一次铺（还没有宿主）才必须等图。
        if let existingHost = coverHost, let existingImage = coverImage {
            if let image = availableImage { existingImage.image = image }
            let coverFrame = geometry.cover
            existingHost.bounds = CGRect(origin: .zero, size: coverFrame.size)
            existingHost.center = CGPoint(x: coverFrame.midX, y: coverFrame.midY)
            existingHost.layer.shadowPath = UIBezierPath(rect: existingHost.bounds).cgPath
            if existingHost.superview !== page { page.addSubview(existingHost) }
            page.bringSubviewToFront(existingHost)
            if let source { hideSpotifyCover(source) }
            return existingHost
        }

        guard let source else { return nil }
        guard let image = availableImage else {
            noteSkip("no image inside that cover view (\(NSStringFromClass(type(of: source))))")
            return nil
        }

        let host: UIView
        let imageView: UIImageView
        if let existing = coverHost, let existingImage = coverImage {
            host = existing
            imageView = existingImage
        } else {
            host = UIView()
            host.isUserInteractionEnabled = false
            host.accessibilityIdentifier = "eevee-npv-cover-host"
            // 阴影挂在**容器**上（容器不裁剪）；跟着 transform 一起缩放/移动，不用每帧重画。
            host.layer.shadowColor = UIColor.black.cgColor
            host.layer.shadowOpacity = 0.35
            host.layer.shadowRadius = 20
            host.layer.shadowOffset = CGSize(width: 0, height: 12)
            host.layer.masksToBounds = false

            imageView = UIImageView(frame: host.bounds)
            imageView.contentMode = .scaleAspectFill
            imageView.clipsToBounds = true
            imageView.layer.cornerCurve = .continuous
            imageView.layer.cornerRadius = coverFullRadius
            imageView.isUserInteractionEnabled = false
            imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            imageView.accessibilityIdentifier = "eevee-npv-cover-thumb"
            host.addSubview(imageView)

            coverHost = host
            coverImage = imageView
        }

        imageView.image = image

        // 布局：**按 Spotify 封面那个大小与位置**（`bounds` + `center`，不用 `frame`）。
        // 注意这**不是**每拍把封面"摆回去"——动画在 transform 上，所以这里随便重写都不打扰它。
        let coverFrame = geometry.cover
        host.bounds = CGRect(origin: .zero, size: coverFrame.size)
        host.center = CGPoint(x: coverFrame.midX, y: coverFrame.midY)
        host.layer.shadowPath = UIBezierPath(rect: host.bounds).cgPath

        if host.superview !== page { page.addSubview(host) }
        page.bringSubviewToFront(host)

        // Spotify 那条封面**在我们这张出现的同一瞬间隐去**（两张同图，所以看不出"换"）。
        // pw：*"Spotify's cover goes the moment the redesign's own takes its place"* ——
        // 早一步会露一个空档，晚一步会两张同屏（一大一小）。
        hideSpotifyCover(source)
        return host
    }

    /// 缩略图该有的 `transform`：**关于自己的中心**先等比缩小、再平移到目标中心。
    ///
    /// ⚠️ 顺序照 pw：`CGAffineTransformConcat(Scale, Move)` = **先 Scale 后 Move**
    /// （Swift 里是 `scale.concatenating(move)`；写成 `move.scaledBy(…)` 顺序就反了）。
    static func thumbTransform(cover: CGRect, thumb: CGRect) -> CGAffineTransform {
        let scale = cover.width > 0 ? thumb.width / cover.width : 1
        let move = CGAffineTransform(
            translationX: (thumb.midX - cover.midX).rounded(),
            y: (thumb.midY - cover.midY).rounded()
        )
        return CGAffineTransform(scaleX: scale, y: scale).concatenating(move)
    }

    /// 圆角：**缩放会把圆角一起缩放**，所以想让它在缩略图尺寸下"看起来"是 `drawn`，
    /// 模型值就得**除以 scale**（pw：*"asks for the radius it wants divided by the shrink"*）。
    static func radiusDrawnAs(_ drawn: CGFloat, coverWidth: CGFloat, thumbWidth: CGFloat) -> CGFloat {
        let scale = coverWidth > 0 ? thumbWidth / coverWidth : 1
        return scale > 0.01 ? drawn / scale : drawn
    }

    /// 把封面**动画地**放到"展开 / 收起"两个状态之一（两个状态都只改 `transform` + 圆角）。
    ///
    /// 动画参数照 pw 的 `SGRMotionLayout`：
    /// `duration 0.45 / usingSpringWithDamping 1（临界阻尼、不回弹）/ velocity 0`，
    /// options = **`AllowUserInteraction` + `BeginFromCurrentState`**
    /// —— `.beginFromCurrentState` 是**连点两次不跳**的关键（从当前呈现位置接着走）。
    /// 另外 pw 在 **Reduce Motion** 打开时整段不做动画（`performWithoutAnimation`），这里也照做。
    ///
    /// - Parameter completion: **保证会被调用**（动画结束 / 已经在对的位置 / Reduce Motion 三条路都调）。
    /// 收起那一路靠它做收尾（撤封面 + 把 Spotify 那条写回）—— 漏调就会永远留着一张封面。
    static func applyCoverState(
        open: Bool,
        host: UIView,
        imageView: UIImageView,
        geometry: Geometry?,
        completion: (() -> Void)? = nil
    ) {
        if open { _ = door.nextCoverGeneration() }

        let target: CGAffineTransform
        let radius: CGFloat
        if open, let geometry {
            target = thumbTransform(cover: geometry.cover, thumb: geometry.thumb)
            radius = radiusDrawnAs(
                thumbDrawnRadius,
                coverWidth: geometry.cover.width,
                thumbWidth: geometry.thumb.width
            )
        } else {
            target = .identity
            radius = coverFullRadius
        }

        let change = {
            host.transform = target
            imageView.layer.cornerRadius = radius
        }

        // 已经在对的位置（含"上一次动画已经把模型值设成终点"）⇒ 一个字节都不写。
        // `UIView.animate` 会把模型值**立刻**设成终点值，所以 0.3s 的复查节拍天然不会打断动画。
        guard host.transform != target || abs(imageView.layer.cornerRadius - radius) > 0.01 else {
            completion?()
            return
        }

        guard !UIAccessibility.isReduceMotionEnabled else {
            UIView.performWithoutAnimation(change)
            completion?()
            return
        }

        UIView.animate(
            withDuration: moveDuration,
            delay: 0,
            usingSpringWithDamping: 1,
            initialSpringVelocity: 0,
            options: [.allowUserInteraction, .beginFromCurrentState],
            animations: change,
            completion: { _ in completion?() }
        )
    }

    /// 被我们按下 `alpha` 的**别人那些视图**（`Encore.ImageView` 壳 + 真正画图的那一层）—— 弱引用名册。
    ///
    /// ⚠️ 两条都踩过，所以形状是这样：
    /// ① 名册**必须静态**，不能挂在页面对象上 —— 还原那段以 `guard let page = lastPage` 开头，而
    /// `lastPage` 是 **weak**：页面先被释放（或已换成新的一页）时还原**整段跑不到**；而封面的
    /// 视图住在**会被复用的 cell** 里 ⇒ 复用到下一页时它还是 `alpha = 0` ⇒ **永久空白封面**
    /// （本仓库最不能接受的那种失败）。
    /// ② 还原**不许写死 `alpha = 1`**：壳原本可能是 0、也可能是 0.5 ⇒ 等于**把别人的值永久改坏**；
    /// 现在**逐视图记下原值**、按原值写回。
    static let hiddenCovers = NSHashTable<UIView>.weakObjects()
    static var hiddenCoverAlphas: [ObjectIdentifier: CGFloat] = [:]

    // MARK: - 封面图缓存（**不依赖"点的那一瞬间"**）
    //
    // 我们按曲目 id 认下来的封面图（最多留 `artworkCacheLimit` 张）。
    //
    // **为什么要它**：真机树里真正画图的那张常常是 `alpha=0.00` 的壳 + `PlaceholderView`，点"歌词"
    // 那一刻 `image` 可能还是 nil ⇒ 只能**拒绝展开**（有日志、不留半成品，但功能会"有时候点了没反应"）。
    // 所以改成：**页面开着的时候**（本来就在跑的 0.3s 节拍）顺手把当前这首的封面按曲目 id 存住，
    // 点的时候**先用缓存**、树只当兜底 —— **不新增定时器、不新增取景时机。**
    //
    // ⚠️ 与 pw 还有距离：pw 是**完全自己持有**那张图。要再稳一档就复用仓库既有的
    // `LyricsArtworkResolver`（`spotify:image:<hex>` → `https://i.scdn.co/image/<hex>` 这条链它已经
    // 走通），但它是**异步**的，要塞进一个同步返回 `Bool` 的 `layoutAndMount` 得先改结构。
    static let artworkCacheLimit = 8
    static var artworkCache: [String: UIImage] = [:]
    static var artworkCacheOrder: [String] = []

    /// 顺手认下当前这一首的封面（幂等：这一首已经有了就直接返回，不再走树）。
    @discardableResult
    static func rememberArtworkIfNeeded(in page: UIView) -> UIImage? {
        guard let trackId = currentTrackId() else { return nil }
        // 缓存里那张**也要够大**才算数 —— 旧版本可能已经把占位图按这一首的 id
        // 存进来了（真机日志 `remembered this track's artwork 4×4 (cache 1/8)`）。
        // 直接丢条目、让这一拍重新去树里认；不丢的话用户升级之后**这一首还是**那块灰方块。
        if let cached = artworkCache[trackId] {
            if isUsableArtwork(cached) { return cached }
            artworkCache.removeValue(forKey: trackId)
            artworkCacheOrder.removeAll { $0 == trackId }
            if !unusableArtworkReported {
                unusableArtworkReported = true
                writeDebugLog(
                    "[\(logTag)] dropped a cached artwork that is too small to be a cover — "
                        + "\(Int(cached.size.width))×\(Int(cached.size.height))"
                )
            }
        }

        // **换歌那一拍先不信视图树**：`currentTrackId` 是**立刻**变的，而 Spotify 的
        // 封面要**晚一点**才换过来 ⇒ 那一拍抓到的还是上一首的图，写进缓存就**永久错**下去
        // （缓存按曲目 id 存，而 `ensureCover` 优先吃缓存）。
        //
        // 所以：曲目 id 刚变的那一拍**只记 id、不认图**，下一拍（≤0.5s）再认 —— 那时图也换
        // 过来了。这一拍 `ensureCover` 退回 `firstImage(in: source)`，也就是**当前树里真实那张**。
        if lastArtworkTrackId != trackId {
            // 把**上一首**那张图记下来 —— 下一次真的去抓树时要用它判"树换过来了没有"。
            previousArtworkImage = artworkCache[lastArtworkTrackId]
            staleArtworkTrackId = ""
            artworkTrackChangedAt = CFAbsoluteTimeGetCurrent()
            lastArtworkTrackId = trackId
            writeDebugLog(
                "[\(logTag)] track just changed — not caching the artwork this tick"
                    + " (the view tree still shows the previous cover)"
            )
            return nil
        }

        guard let list = findByIdentifier(listIdentifier, in: page),
              let source = visibleCover(in: list, page: page),
              let image = firstImage(in: source) ?? anyCoverImage(in: list) else { return nil }

        // **"下一拍树就换过来了"这个假设不成立**：抓到的图可能还是上一首那张，写进新曲目的缓存后
        // `ensureCover` 优先吃缓存 ⇒ 缩略图一直显示上一首。
        // 判据：抓到的图**和上一首缓存里那张是同一个对象** ⇒ 树还没换过来 ⇒ 这一拍不写缓存
        // （`ensureCover` 退回 `firstImage(in: source)`，同一张，画面对齐；树真换过来后对象不同）。
        //
        // ⚠️ **只在换歌那一小段窗口里判**：同一个对象也可能是 Spotify 自己的图缓存把**同一张专辑**
        // 的图复用了（连听两首同专辑）—— 那时这条判据会**永久**不让缓存写进去：画面不会错（兜底拿的
        // 是同一张真图），但"点开之前就先认下这张图"这个收益没了。所以给它一个 1.5s 的窗口。
        if let previous = previousArtworkImage,
           image === previous,
           CFAbsoluteTimeGetCurrent() - artworkTrackChangedAt < staleArtworkWindow {
            if staleArtworkTrackId != trackId {
                staleArtworkTrackId = trackId
                writeDebugLog(
                    "[\(logTag)] the tree still shows the previous cover — not caching it for this track"
                        + " (falling back to the live image, will retry next tick)"
                )
            }
            return nil
        }

        // **够大才配进缓存**（占位图一旦进去就是"永久的错封面"，见 `firstImage`）。
        guard isUsableArtwork(image) else {
            noteUnusableArtwork(image, from: source)
            return nil
        }

        artworkCache[trackId] = image
        artworkCacheOrder.append(trackId)
        while artworkCacheOrder.count > artworkCacheLimit {
            artworkCache.removeValue(forKey: artworkCacheOrder.removeFirst())
        }
        writeDebugLog(
            "[\(logTag)] remembered this track's artwork \(Int(image.size.width))×\(Int(image.size.height))"
                + " (cache \(artworkCacheOrder.count)/\(artworkCacheLimit))"
        )
        return image
    }

    /// 上一次认图时的曲目 id。用来识别"刚换歌那一拍"（见 `rememberArtworkIfNeeded`）。
    static var lastArtworkTrackId = ""

    /// 「曲目刚变」那一刻，**上一首**缓存里那张图（见 `rememberArtworkIfNeeded` 的换歌判据）。
    static var previousArtworkImage: UIImage?

    /// 已经为哪一首报过"树里还是上一首的图"（只报一次，别每拍刷屏）。
    static var staleArtworkTrackId = ""

    /// 这一次"曲目刚变"发生的时刻 —— 那条"图还是上一首的"判据只在这个窗口里生效
    /// （见 `rememberArtworkIfNeeded`：同专辑连播时图可能真的是同一个对象，不能永久拦）。
    static var artworkTrackChangedAt: CFAbsoluteTime = 0
    static let staleArtworkWindow: CFAbsoluteTime = 1.5

    /// ⚠️ 收的是**已经认准的那一个**（由 `visibleCover` 挑出来），不再自己按 id 找一遍 ——
    /// 上一版这里又 `findByIdentifier` 了一次，于是"挑封面"与"藏封面"用的是两个不同的视图。
    static func hideSpotifyCover(_ source: UIView) {
        hideCoverView(source)
        // 它下面那层真正画图的 `UIImageView` 也一起（`Encore.ImageView` 只是壳）。
        for sub in source.subviews where sub.alpha > 0.01 && sub.bounds.width >= 200 {
            hideCoverView(sub)
        }
    }

    /// 按下某个视图的 `alpha`，并**只在第一次**记下它自己的原值（还原时按原值写回，见名册那段）。
    ///
    /// - Parameter restoringTo: 原值读不到 / 还是 0（换歌转场里新封面先以 `alpha = 0` 出现）时，
    /// 还原成什么。封面 tilt 的"正常可见"就是 1 ⇒ 调用方给 1；别的视图不传，照旧写回原值。
    static func hideCoverView(_ view: UIView, restoringTo fallback: CGFloat? = nil) {
        let key = ObjectIdentifier(view)
        if hiddenCoverAlphas[key] == nil {
            let original = view.alpha
            if original > 0.01 {
                hiddenCoverAlphas[key] = original
            } else {
                hiddenCoverAlphas[key] = fallback ?? original
            }
        }
        hiddenCovers.add(view)
        view.alpha = 0
    }

    /// 把被我们按下去的视图**按各自的原值**还回去。**不依赖页面**（见名册那段：页面可能已经没了）。
    static func restoreSpotifyCover() {
        for view in hiddenCovers.allObjects {
            guard let original = hiddenCoverAlphas[ObjectIdentifier(view)] else { continue }
            if view.alpha != original { view.alpha = original }
        }
        hiddenCovers.removeAllObjects()
        hiddenCoverAlphas.removeAll()
    }

    /// 在壳里找真正的 `UIImageView`（`Encore.ImageView` 自己不画图）。
    ///
    /// **图也要看尺寸**：壳里除了真正画图的 `UIImageView` 还挂着 `PlaceholderView`（占位图很小，
    /// 例如 4×4）—— 小图一旦被当成封面缓存下来，`ensureCover` **每一拍都优先吃缓存** ⇒ 缩略图永远是
    /// 那块灰方块，而且**这一首永久错下去**（缓存按曲目 id 存，LRU 到 8 张才挤掉）。
    /// 所以"**够大才算**"：太小的**跳过、继续往下走**（不是直接返回 nil —— 真图可能是它的兄弟节点）。
    static func firstImage(in view: UIView) -> UIImage? {
        if let imageView = view as? UIImageView, let image = imageView.image {
            if isUsableArtwork(image) { return image }
            noteUnusableArtwork(image, from: view)
        }
        for sub in view.subviews {
            if let image = firstImage(in: sub) { return image }
        }
        return nil
    }

    /// 封面图的最小边长。而正片封面在真机树里是
    /// 366×366 的壳 + 至少 300pt 以上的图 —— 128 这条线把占位图挡在外面，又给"小图放大"
    /// 留足余量（宁可放过一张小图，也不许把占位图当封面）。
    static let minimumArtworkSide: CGFloat = 128

    /// 这张图够格当封面吗（见 `minimumArtworkSide`）。
    static func isUsableArtwork(_ image: UIImage) -> Bool {
        image.size.width >= minimumArtworkSide && image.size.height >= minimumArtworkSide
    }

    /// 报一次"这张图太小、我跳过了"（只报一次，别每拍刷屏）。
    /// 下一份日志靠它把 `PlaceholderView` 这个来源钉死。
    static var unusableArtworkReported = false

    static func noteUnusableArtwork(_ image: UIImage, from view: UIView) {
        guard !unusableArtworkReported else { return }
        unusableArtworkReported = true
        let className = NSStringFromClass(type(of: view))
        writeDebugLog(
            "[\(logTag)] skipped an artwork that is too small to be a cover — "
                + "\(Int(image.size.width))×\(Int(image.size.height)) inside \(className)"
        )
    }

    /// 兜底：在整条列表子树里找**任意一张够大、看得见、真带图的** `UIImageView`。
    /// 判据与 `visibleCover` 同一个量级（≥200pt），走查有界（本仓库纪律）。
    ///
    /// ⚠️**同样要跳过"被「一屏」折掉的卡"里的图**，而且**同样是两趟**
    /// （严格找不到就退回旧判据）—— 这一层只负责"好歹给张图"，不许因为新判据而
    /// 从"有图但可能是卡的"变成"一张都没有"（那会让展开直接失败）。
    static func anyCoverImage(in list: UIView) -> UIImage? {
        if let strict = firstCoverImage(in: list, skippingCollapsedAncestors: true) { return strict }
        return firstCoverImage(in: list, skippingCollapsedAncestors: false)
    }

    static func firstCoverImage(
        in list: UIView,
        skippingCollapsedAncestors: Bool
    ) -> UIImage? {
        var visited = 0
        var queue: [UIView] = [list]

        while !queue.isEmpty, visited < maxNodes {
            let view = queue.removeFirst()
            visited += 1

            if let imageView = view as? UIImageView,
               let image = imageView.image,
               isUsableArtwork(image),
               imageView.bounds.width >= 200,
               !imageView.isHidden,
               imageView.alpha > 0.01,
               !(skippingCollapsedAncestors && hasCollapsedAncestor(imageView, root: list)) {
                return image
            }
            if view.isHidden { continue }
            queue.append(contentsOf: view.subviews)
        }
        return nil
    }
}
