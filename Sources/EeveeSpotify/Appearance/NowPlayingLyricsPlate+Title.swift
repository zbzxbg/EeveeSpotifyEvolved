// 「歌词进播放器」——标题行与控制条（位移 / 渐隐 / 分享键替身 / 控件条量取）。
// 从 `NowPlayingLyricsPlate.swift` 原样拆出（`NowPlayingLyricsPlate` 的 extension）；
// 形状、动画与硬约束见那个文件的头注。
import Foundation
import SwiftUI
import UIKit
import Orion
import ObjectiveC.runtime

@MainActor
extension NowPlayingLyricsPlate {
    /// 标题行上移 + 右移 + 尾部渐隐（pw 的 `placeTitleRow` / `clipTitle`）。
    static func applyTitleTransform(geometry: Geometry, page: UIView) {
        guard let row = geometry.titleRow else { return }
        lastUnit = row

        let rise = CGAffineTransform(translationX: 0, y: geometry.lift.rounded())
        let title = geometry.titleElement
        let slide = title.map { _ in
            CGAffineTransform(translationX: geometry.shift.rounded(), y: 0)
        }
        moveTitleRow(row: row, rise: rise, element: title, slide: slide)

        if let title {
            lastTitleElement = title
            // 长标题向右会撞到"加号"：**用 mask 渐隐**，不改宽度（Spotify 的 marquee 会把宽度写回）。
            applyTitleMask(to: title, page: page)
        }
    }

    /// 标题行的两段位移（上移 + 右移）**只在这一处写**，而且**只在目标真的变了**时才放动画。
    ///
    /// 为什么必须"变了才动"：这条链的节拍是 0.3s、动画是 0.45s —— **每拍无条件 `UIView.animate`
    /// 就等于每拍重开一次**，画面上是"永远在动"。目标 == 现值时直接不进这个分支，动画才播得完。
    ///
    /// 为什么第一程**不**加动画：那一程这一行还在 Spotify 的原生位置（`transform == .identity`），
    /// 进页面时它会从屏幕中间"跳"到左上角，滑过去反而更怪；只有"已经在我们的某个位置上"
    /// （展开 ⇄ 收起）才滑。
    static func moveTitleRow(
        row: UIView,
        rise: CGAffineTransform,
        element: UIView?,
        slide: CGAffineTransform?
    ) {
        let rowNeedsMove = row.transform != rise
        var elementNeedsMove = false
        if let element, let slide { elementNeedsMove = element.transform != slide }
        guard rowNeedsMove || elementNeedsMove else { return }

        let change = {
            if rowNeedsMove { row.transform = rise }
            if let element, let slide, elementNeedsMove { element.transform = slide }
        }
        // pw 那一套：0.45s + 临界阻尼（`usingSpringWithDamping 1`）+ 允许用户交互 + 从当前状态开始
        // （最后一条是"连点两次不跳"的关键）；开了「减弱动态效果」就不动。
        guard !UIAccessibility.isReduceMotionEnabled, row.transform != .identity else {
            UIView.performWithoutAnimation(change)
            return
        }
        UIView.animate(
            withDuration: moveDuration,
            delay: 0,
            usingSpringWithDamping: 1,
            initialSpringVelocity: 0,
            options: [.allowUserInteraction, .beginFromCurrentState],
            animations: change,
            // ⚠️ `completion` 显式写 `nil`：UIKit 那个 Swift 签名虽然给了默认值，
            // 但这个仓库的编译器版本只保证"最多一个警告"，不冒这个险（同 `applyCoverState`）。
            completion: nil
        )
    }

    /// 渐隐宽度 = 标题可用宽度（到右边那排控件为止 / 到页面右沿为止）—— 量不到就整行不遮。
    static func applyTitleMask(to title: UIView, page: UIView) {
        let bounds = title.bounds
        guard bounds.width > 1, bounds.height > 1 else { return }

        // ⚠️ **坐标口径**：`trailingControlX` 量的是**页面坐标**，而 `bounds` 与 `mask.frame` 是
        // **元素自己的坐标**；元素自己已经右移了 `shift`（≈74pt）⇒ 直接拿页面坐标当宽度用会差整整一个
        // `shift`（"右边没有别的控件"那条兜底尤其糟：`room = bounds.width` ⇒ 上面那条 guard 把 mask
        // 清掉 ⇒ **一行 mask 都不贴**）。所以两条路都换算到元素自己的坐标，再兜"页面右沿 − 8"。
        // ⚠️ 这里**不能用 `untransformed`**（它减掉元素自己的 `tx`，是给 `measure` 算"位移前起点"用的）：
        // mask 挂在这个元素的 layer 上 ⇒ x=0 对的是元素**当前（位移后）**的左边，用它算会多出一个 `shift`
        // ⇒ `width == bounds.width` ⇒ mask 被删掉。要用 `convert`（**含 transform**）。
        let titleLeft = title.convert(title.bounds, to: page).minX
        // 右沿的余量也用 `titleGap`（原来是写死的 8pt）；与"离控件"那条
        // 同一个数 ⇒ 用户报的"滚动的右边界太靠右"只需调 `titleGap` 一处。
        let pageLimit = (page.bounds.maxX - titleGap) - titleLeft
        let limitRoom = trailingControlX(in: title, page: page)
            .map { $0 - titleLeft - titleGap }
        let room = min(min(limitRoom ?? pageLimit, pageLimit), bounds.width)
        let width = min(bounds.width, max(0, room))
        guard width < bounds.width - 0.5 else {
            title.layer.mask = nil
            return
        }

        let mask: CAGradientLayer
        if let existing = title.layer.mask as? CAGradientLayer {
            mask = existing
        } else {
            mask = CAGradientLayer()
            mask.colors = [UIColor.white.cgColor, UIColor.white.cgColor, UIColor.clear.cgColor]
            mask.startPoint = CGPoint(x: 0, y: 0.5)
            mask.endPoint = CGPoint(x: 1, y: 0.5)
            title.layer.mask = mask
        }
        let fade = min(titleFade, width)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.frame = CGRect(x: 0, y: 0, width: width, height: bounds.height)
        mask.locations = [0, NSNumber(value: width > 0 ? (width - fade) / width : 0), 1]
        CATransaction.commit()
    }

    static func clearTitleMask() {
        lastTitleElement?.layer.mask = nil
    }

    /// 标题右边那排控件的起点（找不到就不遮）。
    static func trailingControlX(in title: UIView, page: UIView) -> CGFloat? {
        guard let row = title.superview else { return nil }
        let titleLeft = untransformed(title, in: page).minX
        var limit: CGFloat?

        for sub in row.subviews {
            if sub === title || sub.isHidden || sub.alpha < 0.01 || sub.bounds.width < 1 { continue }
            let x = untransformed(sub, in: page).minX
            if x > titleLeft, limit == nil || x < limit! { limit = x }
        }
        return limit
    }

    // 把 Spotify 自己的**分享键**搬进"控件条"（进度条上方那一条空带 —— 绿色 ✓ 本来就在那儿）：
    // **[分享 58] [我们的歌词键 215] [绿色 ✓ 371（不动）]** —— 底部那两排一颗都不用改，
    // **收藏键不搬**（绿色 ✓ 留在原处）。
    //
    // ⚠️ 这是**视觉**搬运：搬过去之后**点不到**（已知并刻意选这一档）—— UIKit 的 hit-test 在祖先那一层
    // 就问 `point(inside:)`，而分享键被抬到 626pt 之后已经在它**父视图**（footer 那一行）的边界之外
    // ⇒ 触摸到不了它；要分享得走右上角 `⋯` 菜单里的 Share（`bandNote` 会把"被谁挡住"写进日志）。
    //
    // ⚠️ 两个状态都摆，和 `isOpen` 无关：这一条在**开着**和**关着**歌词时都是空的（关着时标题/歌手已被
    // `applyClosedTitleTransform` 挪去左上角）⇒ 每拍都摆。
    // ⚠️ 位移只写 `transform`：位置由父视图的 Auto Layout 决定，改 `frame` 会被下一拍写回（本仓库老教训）；
    // 只写平移分量，`a,b,c,d` 原样保留，每拍用 `untransformed` 重算，父视图重排也能跟上。
    @discardableResult
    static func applyControlBand(in page: UIView) -> Bool {
        guard let button = visibleShareButton(in: page) else {
            if !didLogBandShareMissing {
                didLogBandShareMissing = true
                writeDebugLog(
                    "[\(logTag)] no visible share button in this page yet — "
                        + "leaving it in the footer row"
                )
            }
            return false
        }

        // 换了一颗（换歌会重建这一排）⇒ 先把上一颗还回去，免得两处位移叠在同一颗上。
        if bandShareButton !== button {
            clearControlBand()
            bandShareButton = button
            bandShareOriginalTransform = button.transform
        }

        let current = untransformed(button, in: page)
        // 和**下面那颗 shuffle 同一条竖线**（量不到才用常量）。
        let columnX = transportColumnX(shuffleButtonIdentifier, in: page) ?? shareButtonCenterX
        let target = CGPoint(x: columnX, y: controlBandMidY)
        let dx = (target.x - current.midX).rounded()
        let dy = (target.y - current.midY).rounded()
        let landed = CGRect(
            x: (target.x - current.width / 2).rounded(),
            y: (target.y - current.height / 2).rounded(),
            width: current.width,
            height: current.height
        )

        let existing = button.transform
        let moved = CGAffineTransform(
            a: existing.a, b: existing.b, c: existing.c, d: existing.d,
            tx: dx, ty: dy
        )
        if button.transform != moved { button.transform = moved }

        // 它自己点不到 ⇒ **替它收点击**。
        ensureShareRelay(in: page, frame: landed)

        if !didLogBandShare {
            didLogBandShare = true
            writeDebugLog(
                "[\(logTag)] share button moved into the control band — "
                    + "\(Int(current.width))×\(Int(current.height)) from \(frameText(current))"
                    + " to \(frameText(landed))" + bandNote(for: button, landing: landed, page: page)
                    + " (a transparent relay covers that spot and forwards taps)"
            )
        }
        return true
    }

    /// 分享键的**替身热区**：一颗透明的 `UIControl`，点它 = 替用户按那颗真按钮。
    ///
    /// 为什么非它不可：搬过去之后分享键在**祖先的边界之外**，hit-test 在那一层就断了
    /// （`transform` 只改绘制与坐标换算，改不了父视图的命中范围）。要根治只能"把视图搬进另一个父视图"，
    /// 那会把 Spotify 的约束体系弄坏 —— 不做。
    ///
    /// 为什么这次可以用 `sendActions`（本仓库刚把"替用户按胶囊"整块删掉）：那一次删的理由是**切换类**
    /// 动作（按两次回到原状 + 会落盘用户偏好）；分享是"打开一个面板"，幂等、没有状态，转发它是安全的。
    static func ensureShareRelay(in page: UIView, frame: CGRect) {
        let relay: UIControl
        if let existing = bandShareRelay, existing.superview === page {
            relay = existing
        } else {
            let fresh = UIControl(frame: frame)
            // ⚠️ 别用 `alpha = 0`：`hitTest` 会把 alpha ≤ 0.01 的视图当成不存在 —— 那就白做了。
            fresh.backgroundColor = .clear
            fresh.accessibilityIdentifier = "eevee-npv-share-relay"
            fresh.isAccessibilityElement = false
            fresh.addTarget(
                NowPlayingShareRelayTarget.shared,
                action: #selector(NowPlayingShareRelayTarget.tapped),
                for: .touchUpInside
            )
            page.addSubview(fresh)
            bandShareRelay = fresh
            relay = fresh
        }
        if relay.frame != frame { relay.frame = frame }
        // ⚠️ 必须压在**歌词容器之上**（容器铺满歌词区，只在控件条那一条放行；就算放行了，
        // 也还是这颗热区先收到触摸 —— 它是页面最前面的一个子视图）。
        page.bringSubviewToFront(relay)
    }

    /// 关着歌词时：把**标题行**搬到左上角 —— 给控件条腾地方。
    ///
    /// 为什么必须搬：控件条的**第 ① 处**（分享键 58pt）正好压在**原生歌名/歌手**上 ⇒ **不展开歌词**时
    /// 歌名/歌手要贴左上角；**展开歌词以后**封面占左上角、歌名/歌手往右让位（见 `applyTitleTransform`）。
    ///
    /// 落点：`navBarBottom + closedTitleTopInset` —— 正好卡在导航条与**原生大封面顶边**之间，一行都不压。
    /// **x 不动**（原生歌名本来就在 34pt），只有 y 要抬。返回"这一拍有没有找到标题行"。
    @discardableResult
    static func applyClosedTitleTransform(in page: UIView) -> Bool {
        let list = findByIdentifier(listIdentifier, in: page)
        let label = (list.flatMap { findByIdentifier(titleLabelIdentifier, in: $0) })
            ?? findByIdentifier(titleLabelIdentifier, in: page)
        guard let element = label?.superview, let row = element.superview,
              let navBottom = navBarBottom(in: page) else {
            // 找不到就**什么都不做** —— 宁可保持 Spotify 原样，也不要瞎移一行。
            if !didLogClosedTitleMissing {
                didLogClosedTitleMissing = true
                writeDebugLog(
                    "[\(logTag)] cannot find the title row — leaving it where Spotify put it"
                )
            }
            return false
        }

        // 上一程"展开时"的那两段位移**不在这里手撤** —— 交给 `moveTitleRow` 一起动画：
        // 行往上滑回左上角的同时，字往左滑回原位（分开写会先"跳"一下）。
        let current = untransformed(row, in: page)
        guard current.height > 1 else { return false }

        // （大封面有时候会把歌手的名字的下半部分挡住）：
        // 原来这里**只看导航条**，从不问"封面顶边在哪"。
        // 行 `28,98,308,51`（下沿 **149**）vs 封面 `24,146,366,366`（顶边 **146**）
        // ⇒ **压 3pt**，而 51pt 高的行里第二行就是歌手 ⇒ 的正是"歌手名字的下半截"。
        // 现在：量得到封面就夹一道"行底 ≤ 封面顶 − 6"；量不到就照旧（宁可保持原样，别瞎移）。
        var top = navBottom + closedTitleTopInset
        if let list = findByIdentifier(listIdentifier, in: page),
           let cover = visibleCover(in: list, page: page) {
            let coverTop = untransformed(cover, in: page).minY
            let limit = coverTop - closedTitleCoverGap - current.height
            if top > limit { top = limit }
        }

        let dy = (top - current.minY).rounded()
        moveTitleRow(
            row: row,
            rise: CGAffineTransform(translationX: 0, y: dy),
            element: element,
            slide: .identity
        )
        closedTitleRow = row
        closedTitleElement = element

        // 一次一页只报一行：下一份日志靠它判"关着态到底摆上了没有"。
        if !didLogClosedTitle {
            didLogClosedTitle = true
            let landed = CGRect(
                x: current.minX,
                y: navBottom + closedTitleTopInset,
                width: current.width,
                height: current.height
            )
            writeDebugLog(
                "[\(logTag)] title row moved to the top left for the closed state — "
                    + "\(frameText(current)) to \(frameText(landed))"
            )
        }
        return true
    }

    /// 把分享键还回原处（关开关 / 离开页面）。**只撤我们写的那段平移**：
    /// 接管前它自己的 `transform` 原样写回（不假设它一定是 identity）。
    static func clearControlBand() {
        if let button = bandShareButton {
            let original = bandShareOriginalTransform ?? .identity
            if button.transform != original { button.transform = original }
        }
        bandShareButton = nil
        bandShareOriginalTransform = nil
        didLogBandShare = false
        didLogBandShareMissing = false
        // 替身热区也要一起拿走（它挂在页面上，不拿走会一直吃那一块的触摸）。
        bandShareRelay?.removeFromSuperview()
        bandShareRelay = nil
    }

    /// 热区被点了 ⇒ 把这一下**转给那颗真的分享键**。
    ///
    /// ⚠️ `bandShareButton` 的声明类型是 `UIView?`（我们只当它是"页里那个视图"），
    /// 而 `sendActions(for:)` 是 **`UIControl`** 的方法 ⇒ 这里必须 `as? UIControl`。
    /// 这一条让 CI 红过一次（`value of type 'UIView' has no member 'sendActions'`
    /// + `cannot infer contextual base in reference to member 'touchUpInside'`，
    /// 后一条是前一条的连锁）—— 自检 `swift_member_check.py` 的规则 ④ 就是为它加的。
    static func relayShareTap() {
        guard let view = bandShareButton else { return }
        let name = NSStringFromClass(type(of: view))

        guard let control = view as? UIControl else {
            // 不是 `UIControl` ⇒ 这颗键不是靠 target/action 响应的，转发不了。
            // 留一行日志：下一轮就能分清"转发发生了但对方不是 UIControl"和"热区没收到触摸"。
            writeDebugLog(
                "[\(logTag)] the share button (\(name)) is not a UIControl — cannot forward the tap"
            )
            return
        }
        writeDebugLog("[\(logTag)] relaying a tap to the share button (\(name))")
        control.sendActions(for: .touchUpInside)
    }

    /// 把「歌词提供商」写到**歌手那一行的右边**：`歌手（提供商）`。
    ///
    /// 为什么用"复查"而不是只写一次：这一行是 **Spotify 自己的标签**（`now-playing-subtitle-label`），
    /// 它的 binder 会在绑定 / 换歌时把文本写回 ⇒ 只写一次就是"过一会儿又变回去"。本仓库对"改原生标签"
    /// 的既有手法就是**常驻复查节拍**（写一次、每拍比一次、被写回时留一行日志），我们这条 0.3s 现成。
    ///
    /// ⚠️ **展开与收起都贴**（两个状态都显示）；只有**离开页面 / 关开关**才由 `restoreArtistLine`
    /// 精确摘掉（记住贴上去的那一段，不靠猜括号）。
    /// ⚠️ 两行的高度**不动**：标题与歌手各是 Spotify 自己的字号，我们只往歌手那行**追加文本**，
    /// 不换行、不改字体 —— "两行等高"就是"别把第二行撑高"。
    static func applyProviderToArtistLine(in page: UIView) {
        guard let label = artistLabel(in: page) else { return }
        guard let suffix = providerSuffix() else { return }

        let current = effectiveLabelText(label)
        guard !current.isEmpty else { return }

        // （用户：图片里 `（NetEase）` 被截断）：现在显示的可能**是我们裁过的**
        // `歌手…（提供商）` —— 真名在 `lastArtistFullBase`，不能从显示文本反推（会把省略号当名字）。
        var base = current
        if let previous = lastArtistSuffix, current.hasSuffix(previous), !lastArtistFullBase.isEmpty {
            base = lastArtistFullBase
        } else if let previous = lastArtistSuffix, previous != suffix, current.hasSuffix(previous) {
            base = String(current.dropLast(previous.count))
        }
        // ⚠️ 这里**不许**再 `guard !base.hasSuffix(suffix)`：宽度一变（展开 ↔ 收起、旋转）时，
        // 已经写着后缀的那一行要**重新按新宽度裁一次**，否则用户会在窄版式里继续看到截断。
        guard !base.isEmpty else { return }

        // （不能靠滚动来全展示么）：歌手那一行**本来就是 MarqueeLabel**
        // （`now-playing-subtitle-label`）。所以这里**不裁**：写完整的 `歌手（提供商）`，
        // 让它自己的 marquee 把后半段（提供商）滚出来 —— 裁掉才是"永远看不到"。
        // 普通 `UILabel` 没有滚动能力，仍然按可见宽度裁（见 `fittedArtistLine`）。
        let isMarqueeLabel = NSStringFromClass(type(of: label)).contains("Marquee")
        let trackId = currentTrackId() ?? ""
        let wanted: String
        if isMarqueeLabel {
            wanted = base + suffix
        } else {
            // 宽度**缓存**（见 `artistFitWidth` 的说明）—— 每拍重算会被我们自己
            // 写短的文本反馈回来，越算越小。只有换曲 / 换展开状态 / 换标签 / 文本被 binder
            // 写回原样时才重算一次；重算时标签上写的是 Spotify 给的**原歌手名**（没有被我们裁过）。
            let stateKey = door.isOpen ? "open" : "closed"
            let labelKey = "\(trackId)|\(stateKey)|\(String(describing: ObjectIdentifier(label)))"
            let alreadyHasOurs = lastArtistSuffix.map { current.hasSuffix($0) } ?? false
            var maxWidth = artistFitWidth
            if labelKey != artistFitWidthKey || maxWidth <= 20 || !alreadyHasOurs {
                let measured = visibleArtistLineWidth(label, in: page)
                if measured > 20 {
                    maxWidth = measured
                    artistFitWidth = measured
                    artistFitWidthKey = labelKey
                } else {
                    maxWidth = measured
                }
            }
            wanted = fittedArtistLine(base: base, suffix: suffix, maxWidth: maxWidth, label: label)
        }
        if current != wanted {
            setLabelText(wanted, on: label)

            if !isMarqueeLabel, wanted != base + suffix {
                if loggedArtistTruncationTrack != trackId {
                    loggedArtistTruncationTrack = trackId
                    let note = wanted == base
                        ? "the provider does not fit — kept the artist name whole and dropped the provider"
                        : "the artist line was shortened to keep the provider visible"
                    writeDebugLog("[\(logTag)] \(note) — \"\(wanted)\"")
                }
            }
        }
        lastArtistSuffix = suffix
        lastArtistFullBase = base

        // 这条日志原来**一个进程只打一次**，于是"换歌之后有没有重新贴上"
        // 而我们手里没有一行能判它的证据）。
        // 改成"每换一首歌允许再报一次"。
        if !didLogArtistProvider || loggedArtistProviderTrack != trackId {
            didLogArtistProvider = true
            loggedArtistProviderTrack = trackId
            writeDebugLog(
                "[\(logTag)] lyrics provider written next to the artist — \"\(base)\" + \"\(suffix)\""
            )
        } else if !didLogArtistReset, current == lastArtistBase {
            // 同一行、同一个歌手名，却又走到这里 ⇒ 是 binder 写回，不是换歌。
            didLogArtistReset = true
            writeDebugLog(
                "[\(logTag)] ⚠️ the artist line was written back by the binder -"
                    + " the 0.3s reconcile will keep putting the provider back"
            )
        }
        lastArtistBase = base
    }
}
