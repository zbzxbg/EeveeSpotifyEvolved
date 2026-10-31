// 「iOS 27 听歌页」的传输行：藏掉随机与循环，循环挪到工具行。
//
// AM 的形状：传输行只有三颗（上一首 / 播放 / 下一首，白字形，没有随机、没有循环）；循环在底部工具行，一颗小圆玻璃钮贴在"队列"那颗的右上方（≈ +8pt / −20pt）；随机在 AM 里没有常驻入口（属于播放列表语境）—— 这里同理，Spotify 自己的 ⋯ 菜单本来就带重复/随机动作（`_TtC19NowPlaying_ViewImpl23ContextMenuRepeatAction`），藏掉按钮不等于功能消失。
//
// 真机结构（414×896）：
// ```
// 传输行 UIStackView@12,16,382,64
//   Shuffle 48×48 / Previous 56×56 / Play 64×64 / Next 56×56 / Repeat 48×48
// 工具行 UIStackView@12,0,386,44  →  Connect / Share / Queue
// ```
//
// 做法 —— **不移动任何原生控件**：
// · 随机：`hideChrome` ⇒ `alpha = 0`（记原值，`restore` 统一写回）。它那颗 slot 还在，所以上一首/下一首不会因为"少了两颗"重新排版，位置不变；
// · 循环：**只藏它的图标子树**，按钮本身 `alpha` 保持 1 —— 触摸要靠替身转给它（`alpha = 0` 的视图参与不了命中测试）；
// · 我们画的圆钮（30pt 圆 + `repeat` 字形）挂在 `page` 上，位置按队列那颗算；上面盖一层 `NowPlayingIOS27RemoteRelayView`，命中时把触摸打到原生循环键的中心，由它自己 `hitTest` 出真正接这一下的视图 ⇒ 原生按钮收到的是真的触摸（手势、按压、它自己的动作全都在）。
//
// 为什么替身是新类：`NowPlayingTitleRelayView` 只处理"行还在原地、只是被 transform 挪走"，用 `row.convert(row.bounds, to: self).contains(point)` 要求替身与目标同坐标；这里是跨位置映射（我们的圆钮 ↔ 传输行里的循环键），所以另写一个只认 `sourceRect`、命中后一律打到目标中心的替身。
//
// 日志 tag：`[iOS27]`，一次性两行：`transport — …` 与 `repeat state — …`。
import Foundation
import UIKit
import ObjectiveC.runtime

/// 跨位置替身：把"我们画的那颗"的触摸交给**另一处**的原生控件。
///
/// · `zones` 是若干**本层坐标**里的可点区域，每块各指向一颗原生视图；
/// ·**修正（这条很重要，别再往回改）**：`zones` 那条"把触摸 hitTest 到原生控件"
/// 的路**只在小位移时有效**。UIKit 交付给被命中视图的 `UITouch` 里存的仍然是**真实的窗口坐标**，
/// 控件换算到自己坐标系后落在 bounds **之外** ⇒ `UIControl` 发的是 `.touchUpOutside`，动作**不触发**。
/// 我们的字形和它对应的原生键差得越远越必然失败（歌词气泡离 `lyrics-expand-button` 有大半屏，
/// 报的"iOS 27 下歌词点不了"就是这条）。
/// ⇒ 现在**一律走 `actionZones` + `sendActions(for: .touchUpInside)`**：与位置无关。
/// `zones` 只剩"目标真的就在手指底下"那种情况可用。
/// · `actionZones` 命中时 `hitTest` 返回**本视图**，由自带的 `UITapGestureRecognizer` 在抬手时执行闭包
/// （「歌词舞台」那颗气泡也用它：舞台是独立窗口，没有原生控件可打）。
final class NowPlayingIOS27RemoteRelayView: UIView {

    var zones: [(rect: CGRect, target: UIView)] = []
    var actionZones: [(rect: CGRect, action: () -> Void)] = []

    /// **不接**的区域：让给叠在同一页上的**另一块替身**。
    ///
    /// （点右下角那颗，还是 Spotify 原生弹窗）：工具行的"队列"可点区
    /// 是 44pt（必须盖住藏在下面的原生分享键），而"循环"那颗是**另一块替身**、框只有 26pt
    /// ⇒ 两者必然重叠。谁先收到触摸取决于 `page.subviews` 的顺序（footer 每拍都
    /// `bringSubviewToFront` 一次），于是同一处时而开队列、时而循环。
    /// 现在 footer 这块替身把"循环那颗的框"从自己的命中范围里**排除**，触摸会自然落到
    /// 下面那块替身上 —— 与顺序无关。
    var excludedRects: [CGRect] = []

    private func accepts(_ point: CGPoint) -> Bool {
        guard !excludedRects.contains(where: { $0.contains(point) }) else { return false }
        return zones.contains { $0.rect.contains(point) }
            || actionZones.contains { $0.rect.contains(point) }
    }

    /// 抬手时才执行动作（与原生按钮的 `.touchUpInside` 同一时机；
    /// `UIControl` 那条路本来就是"命中即转发"，两者手感一致）。
    private var actionTap: UITapGestureRecognizer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        installActionTap()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        installActionTap()
    }

    private func installActionTap() {
        guard actionTap == nil else { return }
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleActionTap(_:)))
        tap.cancelsTouchesInView = false
        addGestureRecognizer(tap)
        actionTap = tap
    }

    @objc private func handleActionTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        let point = recognizer.location(in: self)
        guard let zone = actionZones.first(where: { $0.rect.contains(point) }) else { return }
        zone.action()
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard isUserInteractionEnabled, !isHidden, alpha > 0.01 else { return false }
        return accepts(point)
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard isUserInteractionEnabled, !isHidden, alpha > 0.01 else { return nil }
        if let zone = zones.first(where: { $0.rect.contains(point) }),
           !excludedRects.contains(where: { $0.contains(point) }) {
            let target = zone.target
            guard target.window != nil, target.alpha > 0.01, !target.isHidden else { return nil }
            let centre = CGPoint(x: target.bounds.midX, y: target.bounds.midY)
            // ⚠️ `hitTest` 可能返回 nil（目标把整棵子树按 alpha 藏了的时候）——
            // 那时**退回目标本身**：触摸仍然落在原生控件上（就是我们要的转发），
            // 而不是"掉到下面那块替身上、开了别的面板"的现场）。
            return target.hitTest(centre, with: event) ?? target
        }
        // 自己执行动作的那一块：返回自己，手势识别器接住这一下。
        if actionZones.contains(where: { $0.rect.contains(point) }),
           !excludedRects.contains(where: { $0.contains(point) }) {
            return self
        }
        return nil
    }
}

@MainActor
extension NowPlayingIOS27 {

    // MARK: - 常量
    //
    // 随机那颗（真机树 `EncoreButton…id=Components.UI.ShuffleButton`）。
    static let shuffleButtonIdentifier = "Components.UI.ShuffleButton"
    /// 循环那颗（交接文档 8.4：`Nowplaying-RepeatButton 48×48`）。
    static let repeatButtonIdentifier = "Nowplaying-RepeatButton"
    /// 工具行里"队列"那颗（AM 的循环就摆在它右上方）。
    static let queueButtonIdentifier = "QueueButtonNowPlaying"

    /// 我们自己画的那颗循环钮。
    static let repeatPillIdentifier = "eevee-ios27-repeat"
    static let repeatRelayIdentifier = "eevee-ios27-repeat-relay"
    /// 循环徽标：面积（只为触摸）。
    ///
    /// （我感觉应该是放得下的吧）：放得下 —— 关键是
    /// 工具行三颗已经整体下移到 845（`NowPlayingIOS27.footerRowYOffset`），音量行下沿是 813，
    /// 队列字形墨迹从 836 起 ⇒ 813…836 这 23pt 正好放一颗 24pt 的徽标（中心 825）。
    static let repeatPillSide: CGFloat = 24
    /// 徽标中心相对**队列字形中心**的偏移（AM 参考图：右 ≈13、上 ≈20）。
    static let repeatPillOffsetX: CGFloat = 13
    static let repeatPillOffsetY: CGFloat = -20
    /// 字形大小（SF Symbol pointSize）。AM 那颗 ≈12。
    static let repeatGlyphSize: CGFloat = 12
    /// 底色：**透明**。
    /// 留这个常量是为了不让 `mountRepeatPill` 里多一条"为什么没有底色"的谜。
    static let repeatPillFill = UIColor.clear
    /// 「循环开着」时字形用的 Spotify 绿。
    static let repeatActiveTint = UIColor(red: 0.11, green: 0.73, blue: 0.33, alpha: 1)
    /// 循环关着时的字形颜色。
    static let repeatIdleTint = UIColor(white: 1, alpha: 0.92)

    // MARK: - 状态
    //
    // 我们画的圆钮 + 它上面的替身。
    static weak var repeatPill: UIView?
    static weak var repeatGlyph: UIImageView?
    static weak var repeatRelay: NowPlayingIOS27RemoteRelayView?
    static var didLogTransport = false
    static var didLogRepeatState = false

    // MARK: - 每拍入口
    //
    // 藏随机与循环、把循环摆到工具行。找不到传输行就返回 false（不假装成功）。
    @discardableResult
    static func placeTransport(in page: UIView) -> Bool {
        guard let row = transportRow(in: page) else { return false }

        var changed = false
        if let shuffle = row.shuffle, hideChrome(shuffle) { changed = true }
        if let repeatKey = row.repeat {
            // 先摆圆钮、**再**藏图标：摆不出去（量不到工具行）就让循环留在传输行，
            // 而不是"藏了图标、又没有替身" ⇒ 那颗功能就彻底看不见了。
            if mountRepeatPill(in: page, forwardingTo: repeatKey) {
                changed = true
                if hideGlyphSubtree(repeatKey) { changed = true }
            }
        }

        if !didLogTransport {
            didLogTransport = true
            func describe(_ view: UIView?) -> String {
                guard let view else { return "missing" }
                return "hidden (\(NSStringFromClass(type(of: view))))"
            }
            // 把"谁压着谁"需要的三个框一次打全。
            func rect(_ view: UIView?) -> String {
                guard let view else { return "missing" }
                let r = view.convert(view.bounds, to: page)
                return "\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))×\(Int(r.height))"
            }
            func rect(_ identifier: String) -> String {
                rect(NowPlayingLyricsPlate.findByIdentifier(identifier, in: page))
            }
            let pill = repeatPill.map { view -> String in
                "\(Int(view.frame.minX)),\(Int(view.frame.minY))"
                    + " \(Int(view.frame.width))×\(Int(view.frame.height))"
            } ?? "not placed"
            writeDebugLog(
                "[\(logTag)] transport — shuffle \(describe(row.shuffle))"
                    + ", repeat \(describe(row.repeat)) @\(rect(row.repeat)), pill \(pill)"
                    + "; queue glyph \(rect(queueButtonIdentifier))"
                    // 音量行是我们自己那层（`NowPlayingPageOverlay`）的 id，这里直接查字面量。
                    + "; volume row \(rect("eevee-npv-volume-row"))"
                    + " (AM's three-button row; both stay reachable from the context menu)"
            )
        }
        return changed
    }

    // MARK: - 找传输行那两颗
    //
    // 返回传输行最外那两颗：**随机**（最左）与**循环**（最右）。
    //
    // 先按 id 找；**缺哪一颗就补哪一颗**（真机 8.4 的树里随机那颗常常没有 id）——
    // 补法是**结构**：从播放键往上爬到"装得下上一首、播放、下一首的那一层"，
    // 再把这一层里不在那三颗之列、看得见且够宽的最左/最右子视图当随机/循环。
    private static func transportRow(in page: UIView) -> (shuffle: UIView?, repeat: UIView?)? {
        // 这两颗贴着页面左右边缘（中线≈40 / 374），默认 20% 闸门会把它们
        // 全筛掉；而且 pager 里相邻页还有一份 ⇒ 用 margin 0 的 visibleView。
        var shuffle = visibleView(identifier: shuffleButtonIdentifier, in: page, horizontalMargin: 0)
        var repeatKey = visibleView(identifier: repeatButtonIdentifier, in: page, horizontalMargin: 0)
        if shuffle != nil, repeatKey != nil { return (shuffle, repeatKey) }

        if let structural = structuralTransportRow(in: page) {
            if shuffle == nil { shuffle = structural.shuffle }
            if repeatKey == nil { repeatKey = structural.repeat }
        }
        if shuffle == nil, repeatKey == nil { return nil }
        return (shuffle, repeatKey)
    }

    /// 按"和上一首/播放/下一首同一排"这个结构找最外两颗。
    private static func structuralTransportRow(in page: UIView) -> (shuffle: UIView?, repeat: UIView?)? {
        guard let play = visibleView(
            identifier: NowPlayingLyricsPlate.playButtonIdentifier, in: page, horizontalMargin: 0
        ), let previous = visibleView(
            identifier: NowPlayingControlsPlate.previousButtonID, in: page, horizontalMargin: 0
        ), let next = visibleView(
            identifier: NowPlayingControlsPlate.nextButtonID, in: page, horizontalMargin: 0
        ) else { return nil }

        var candidate: UIView? = play
        var visited = 0
        while let view = candidate, view !== page, visited < 10 {
            visited += 1
            if previous.isDescendant(of: view), next.isDescendant(of: view), view.subviews.count >= 3 {
                let core = [previous, play, next]
                let others = view.subviews.filter { sub in
                    guard !sub.isHidden, sub.frame.width > 20 else { return false }
                    return !core.contains { $0 === sub || $0.isDescendant(of: sub) }
                }
                guard others.count >= 2 else { return (nil, nil) }
                let left = others.min { $0.frame.minX < $1.frame.minX }
                let right = others.max { $0.frame.minX < $1.frame.minX }
                // 还没排过版（都挤在 0）就先别认，免得把别的行当传输行。
                if let left, let right, left.frame.minX == right.frame.minX { return (nil, nil) }
                return (left, right)
            }
            candidate = view.superview
        }
        return nil
    }

    // MARK: - 循环：工具行那颗圆钮 + 替身

    @discardableResult
    private static func mountRepeatPill(in page: UIView, forwardingTo repeatKey: UIView) -> Bool {
        // 落点：**队列字形的右上角**（AM 参考图 / MeloX 都是这个关系：小徽标压在队列右肩）。
        //
        // ⚠️的两轮反复，结论记在这里：
        // · 第一版按 AM 量了 +13/−18，但当时工具行还停在**原生中线 811**，而它上面挤着
        // 传输行底 781 + 音量行 785…813 ⇒ 徽标必然压到滑杆和队列字形（互相遮挡）；
        // · 于是先退到"传输行右端"（能点、不挤，但不是 AM 的样子）；
        // · 用户拿 MeloX 的播放页对照后确认**放得下** ⇒ 正解是把**我们画的**工具行整体
        // 下移 34pt（`NowPlayingIOS27.footerRowYOffset`，原生行不动），腾出 813…836 这一段。
        // 现在徽标 24pt、中心 = 队列中心 +（13, −20）⇒ 813…837：上不碰音量行、下不碰字形墨迹。
        guard let anchor = queueAnchorRect(in: page) else { return false }
        let side = repeatPillSide
        let centre = CGPoint(
            x: anchor.midX + repeatPillOffsetX,
            y: anchor.midY + repeatPillOffsetY
        )
        // 夹在页面里：贴边的机型上"右 8"会出屏。
        let origin = CGPoint(
            x: min(max(centre.x - side / 2, 4), page.bounds.width - side - 4),
            y: max(centre.y - side / 2, page.safeAreaInsets.top + 4)
        )
        let frame = CGRect(origin: origin, size: CGSize(width: side, height: side))

        var changed = false
        let pill: UIView
        if let existing = repeatPill, existing.superview === page {
            pill = existing
        } else {
            let fresh = UIView(frame: frame)
            fresh.accessibilityIdentifier = repeatPillIdentifier
            fresh.isUserInteractionEnabled = false
            fresh.backgroundColor = repeatPillFill
            fresh.layer.cornerRadius = side / 2
            fresh.layer.cornerCurve = .continuous
            fresh.clipsToBounds = true

            let glyph = UIImageView(frame: fresh.bounds)
            glyph.contentMode = .center
            glyph.isUserInteractionEnabled = false
            glyph.tintColor = repeatIdleTint
            glyph.image = repeatGlyphImage()
            fresh.addSubview(glyph)

            page.addSubview(fresh)
            repeatPill = fresh
            repeatGlyph = glyph
            // ⚠️这一句**必须有**。
            //
            // `pill` 是"先声明、后赋值"的常量，上面那个分支赋了（`existing`），这里
            // 原来只写了 `repeatPill = fresh`（那是**另一张表**里的弱引用），于是
            // 下面 `pill.frame` 那几行报 4 条
            // constant 'pill' used before being initialized
            // 同一个函数里那两颗 `relay` 是两条分支各赋一次、所以没事 —— 别照那颗的写法漏这一行。
            pill = fresh
            changed = true
        }
        if pill.frame != frame {
            pill.frame = frame
            repeatGlyph?.frame = pill.bounds
            changed = true
        }
        if updateRepeatGlyph(repeatKey) { changed = true }

        // 替身（整页大小，只有 `sourceRect` 那一块认触摸）。
        let relay: NowPlayingIOS27RemoteRelayView
        if let existing = repeatRelay, existing.superview === page {
            relay = existing
        } else {
            let fresh = NowPlayingIOS27RemoteRelayView(frame: page.bounds)
            fresh.accessibilityIdentifier = repeatRelayIdentifier
            fresh.backgroundColor = .clear
            fresh.isUserInteractionEnabled = true
            page.addSubview(fresh)
            relay = fresh
            repeatRelay = fresh
            changed = true
        }
        // 改成 `sendActions` 转发（`zones` 那条 hitTest 路对"不在手指底下"
        // 的控件无效 —— 详见 `NowPlayingIOS27RemoteRelayView` 的头注）；
        // 实在找不到 `UIControl` 才退回 hitTest（至少不会把触摸吞掉）。
        if let action = tapAction(for: repeatKey, label: "repeat") {
            relay.actionZones = [(frame, action)]
            relay.zones = []
        } else {
            relay.actionZones = []
            relay.zones = [(frame, repeatKey)]
        }
        if relay.frame != page.bounds { relay.frame = page.bounds }
        if page.subviews.last !== relay { page.bringSubviewToFront(relay) }
        return changed
    }

    /// 循环徽标的锚：**我们画的那颗队列字形**（工具行整体下移之后它才在 845 那一档）；
    /// 还没画出来（第一拍）就退到原生队列那颗、再退到分享那颗。
    private static func queueAnchorRect(in page: UIView) -> CGRect? {
        let glyphIdentifier = footerGlyphIdentifierPrefix + "queue"
        if let glyph = footerGlyphs.allObjects.first(where: {
            $0.accessibilityIdentifier == glyphIdentifier
        }) {
            let rect = NowPlayingLyricsPlate.untransformed(glyph, in: page)
            if rect.width > 8, rect.height > 8, rect.midY > 0, rect.midY < page.bounds.height {
                return rect
            }
        }
        for identifier in [queueButtonIdentifier, NowPlayingLyricsPlate.shareButtonIdentifier] {
            guard let view = NowPlayingLyricsPlate.findByIdentifier(identifier, in: page) else {
                continue
            }
            let rect = NowPlayingLyricsPlate.untransformed(view, in: page)
            if rect.width > 8, rect.height > 8, rect.midY > 0, rect.midY < page.bounds.height {
                return rect
            }
        }
        return nil
    }

    /// 循环开着就把字形染绿。只用来决定颜色 —— 判别式见下面的注释。
    ///
    /// ⚠️ 没能可靠区分"全部循环"与"单曲循环"（Spotify 是换字形、不是换 tint），
    /// 所以字形**固定是 `repeat`**，开着只是变绿；真要区分得等下一轮找到状态源。
    @discardableResult
    private static func updateRepeatGlyph(_ button: UIView) -> Bool {
        let active = repeatIsActive(button)
        guard let glyph = repeatGlyph else { return false }
        let wanted = active ? repeatActiveTint : repeatIdleTint
        var changed = false
        if glyph.tintColor != wanted {
            glyph.tintColor = wanted
            changed = true
        }
        if !didLogRepeatState {
            didLogRepeatState = true
            writeDebugLog(
                "[\(logTag)] repeat state — active=\(active ? "Y" : "N")"
                    + " class=\(NSStringFromClass(type(of: button)))"
            )
        }
        return changed
    }

    /// "循环开着吗"：控件 `isSelected`，或它某个子视图的 tint 被 Spotify 染成绿。
    private static func repeatIsActive(_ button: UIView) -> Bool {
        if let control = button as? UIControl, control.isSelected { return true }
        for view in button.subviews {
            guard let tint = view.tintColor else { continue }
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            guard tint.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { continue }
            if green > 0.45, red < 0.5, blue < 0.5 { return true }
        }
        return false
    }

    private static func repeatGlyphImage() -> UIImage? {
        let configuration = UIImage.SymbolConfiguration(
            pointSize: repeatGlyphSize,
            weight: .semibold
        )
        return UIImage(systemName: "repeat", withConfiguration: configuration)?
            .withRenderingMode(.alwaysTemplate)
    }

    // MARK: - 转发（T2/T3 共用）
    //
    // 把"点一下这颗原生视图"变成**与位置无关**的动作。
    //
    // 为什么需要它：替身把触摸 `hitTest` 到一颗**不在手指底下**的视图时，UIKit 交付的
    // `UITouch` 仍是真实窗口坐标 ⇒ 控件算出来的点在自己 bounds 之外 ⇒ 它发
    // `.touchUpOutside`（动作不触发）。`sendActions(for: .touchUpInside)` 不经过命中测试，
    // 走控件自己的 target/action / `UIAction` ⇒ 跨半屏也没问题。
    //
    // 返回 nil = 这颗视图附近**找不到 `UIControl`**（那时调用方就别放这块可点区，别造死键）。
    @MainActor
    static func tapAction(for target: UIView?, label: String) -> (() -> Void)? {
        guard let target else { return nil }
        guard let control = nearestControl(target) else {
            writeDebugLog(
                "[\(logTag)] \(label): no UIControl near"
                    + " \(NSStringFromClass(type(of: target))) — the tap would do nothing"
            )
            return nil
        }
        let controlClass = NSStringFromClass(type(of: control))
        return {
            writeDebugLog("[\(logTag)] \(label): sendActions → \(controlClass)")
            // ⚠️ 这个闭包存进的是**非隔离**的 ` -> Void`（替身的 `actionZones`）——
            // 这里用 `onMainThreadSync` 把 `@MainActor` 的操作显式包住，不靠
            // "闭包继承外围隔离"那条推断（上一轮就是这类推断让包白跑）。
            onMainThreadSync {
                // 先 `.touchDown` 再 `.touchUpInside`：有些控件只在"按下过"之后才认抬手
                // （`UIControl.sendActions` 只是逐个事件派发 target/action，发两个是安全的）。
                control.sendActions(for: .touchDown)
                control.sendActions(for: .touchUpInside)
            }
        }
    }

    /// 这颗视图自己、往上 6 跳、或往里 32 个视图之内最近的 `UIControl`。
    ///
    /// 顺序有意义：先认它自己（`EncoreButton` 本身就是 `UIButton`），再往上找
    /// （有些"键"只是容器），最后往里找（有些键把 target/action 挂在内部那颗 control 上）。
    @MainActor
    static func nearestControl(_ view: UIView) -> UIControl? {
        var current: UIView? = view
        var hops = 0
        while let candidate = current, hops < 6 {
            if let control = candidate as? UIControl { return control }
            current = candidate.superview
            hops += 1
        }
        var queue: [UIView] = view.subviews
        var visited = 0
        while !queue.isEmpty, visited < 32 {
            let candidate = queue.removeFirst()
            visited += 1
            if let control = candidate as? UIControl { return control }
            queue.append(contentsOf: candidate.subviews)
        }
        return nil
    }

    // MARK: - 收尾
    //
    // 拆掉我们的圆钮与替身。
    //
    // 藏掉的图标（随机走 `hideChrome`、循环走 `hideGlyphSubtree`）由 `restore` 里的
    // `revealChrome` / `revealHiddenGlyphs` 统一写回 —— T2 与 T3 共用那两套表，只写一次。
    static func teardownTransport() {
        repeatPill?.removeFromSuperview()
        repeatPill = nil
        repeatGlyph = nil
        repeatRelay?.removeFromSuperview()
        repeatRelay = nil
    }

    static func clearTransportState() {
        repeatPill = nil
        repeatGlyph = nil
        repeatRelay = nil
        didLogTransport = false
        didLogRepeatState = false
    }
}
