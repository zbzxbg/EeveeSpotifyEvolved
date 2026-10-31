// 「iOS 27 听歌页」的底部工具行：三颗字形按 AM 排开，触摸靠替身转发。
//
// AM 的底排是三颗、左右对称、等距：歌词气泡（左）/ 隔空播放（中）/ 队列（右），414×896 上是 x = 86 / 207 / 328，y = 底排中线（≈805）。Spotify 自己的布局是 Connect 在最左（≈38）、分享与队列挤在右边（≈329 / 376），中间一大片空 ⇒ 躲不开挪位置。
//
// 做法 —— **不移动任何原生控件，只藏字形 + 自绘 + 替身**：
// ① 三颗原生键（Connect / 分享 / 队列）只藏图标子树，按钮 `alpha` 保持 1；
// ② 在页面上按 AM 的三个位置画三颗字形（26pt 方框、SF Symbol）；
// ③ 三个位置各盖一块替身（`NowPlayingIOS27RemoteRelayView` 的 `zones`），命中后 `target.hitTest(中心)` ⇒ 原生键收到的是真触摸（手势、按压、它自己的动作全在）。
//
// 不用 `transform` 挪原生键：它们在 `UIStackView` 里，栈每次布局都会写 `frame`，给带 `transform` 的视图设 `frame` 会把位移吃掉。
//
// 左边那颗 = 歌词入口：先找 `lyrics-card-view`，再找它内部类名带 `ShowLyricsButton` 的那颗键（`Lyrics_CardElementImpl.ShowLyricsButtonElementUI`），找到就用替身把触摸打给它 ⇒ 走 Spotify 自己的"打开全屏歌词"；找不到（歌词卡片关了、或还没建出来）就让那颗键变暗 —— **不做假入口**。iOS 26+ 上整条让位：改成打开我们自己的页内歌词（`NowPlayingIOS27.toggleLyricsMode`），不依赖 `ShowLyricsButton` 是否存在。
//
// ⛔ 独立窗口的逐词歌词（`LyricsStage`）已整体删除，这颗键现在只有「页内歌词」一种去向。
// ⚠️ 分享键的图形被藏了，功能还在：Spotify 的 ⋯ 菜单里有分享（`ShareButtonNowPlayingView` 只是快捷方式）。
// 日志 tag：`[iOS27]`，一次性一行 `footer — …`。
import Foundation
import UIKit
import ObjectiveC.runtime

/// 工具行字形整体下移多少（**nonisolated**：`NowPlayingPageOverlay` 不是 `@MainActor`，
/// 读不了 `NowPlayingIOS27` 里的静态常量，所以真值放在这里）。
///
/// 34 → **64**下面还空了很大一块（即呼吸感））：原生行中线 811，
/// 被底部那一坨一起上移 55 后是 756；+34 = 790，离屏幕底还有 ~90pt，而音量行在 730…758。
/// +64 ⇒ 字形中线 820、框 807…833 —— 音量行与它之间约 26pt，底部只留安全区。
let nowPlayingIOS27FooterRowYOffset: CGFloat = 64

@MainActor
extension NowPlayingIOS27 {

    // MARK: - 常量
    //
    // 工具行那三颗（真机树 8.4：`Components.ConnectButtonOutputSwitcher` / `ShareButtonNowPlayingView` /
    // `QueueButtonNowPlaying`）。
    static let connectButtonIdentifier = "Components.ConnectButtonOutputSwitcher"
    /// Spotify 的歌词卡片。
    static let lyricsCardIdentifier = "lyrics-card-view"
    /// 卡片里那颗"打开全屏歌词"的键（旧版本 dump：`Lyrics_CardElementImpl.ShowLyricsButtonElementUI`）。
    static let lyricsButtonClassFragment = "ShowLyricsButton"
    /// 9.1.88 上那颗键的**类名不含** `ShowLyricsButton`：
    ///
    /// [NPVTree] 5.CardView@0,0,374,0,id=lyrics-card-view
    /// [NPVTree] 11.EncoreButton@0,0,44,44,id=lyrics-expand-button
    ///
    /// 旧判据找不到它 ⇒ 底排左边那颗气泡一直“找不到入口”（`lyrics entry missing`）。
    /// 现在两种判据都认：类名片段（老版本）+ 无障碍 id（9.1.88）。
    static let lyricsButtonIdentifier = "lyrics-expand-button"

    /// 我们画的三颗字形：id 前缀 + 名字（从左到右）。
    static let footerGlyphIdentifierPrefix = "eevee-ios27-footer-"
    /// AM 的三个中心 x（414×896 上量的；页面比这窄/宽时按比例换算）。
    static let footerGlyphCentres: [CGFloat] = [86, 207, 328]
    /// 字形方框边长（AM 那颗气泡 ≈ 26pt）。
    static let footerGlyphBox: CGFloat = 26
    /// 可点区域边长。
    ///
    /// ⚠️ 必须比字形大：原生那三颗只是**图标被藏了**、按钮还在原位（分享在 x≈329，
    /// 正好压在我们画的队列字形 328 底下）—— 可点区域太小的话，点"看得见的队列"会落到
    /// **看不见的分享键**上。44pt 正好把那一块盖住（苹果的最小触摸目标，也是它们的 frame）。
    static let footerTapSide: CGFloat = 44
    /// SF Symbol 的 pointSize。
    static let footerGlyphPointSize: CGFloat = 19
    /// 字形颜色（AM 是隐约的浅白）。
    static let footerGlyphTint = UIColor(white: 1, alpha: 0.92)
    /// 没有歌词入口时左边那颗的暗度。
    ///
    /// （不开实验性 fo 的情况下，这个歌词点不动）：
    /// 舞台关着时这颗键是**转发给 Spotify 的 `ShowLyricsButton`**，而 iOS 27 这一页
    /// 根本没有那颗按钮（日志：`lyrics entry missing`）⇒ 按下去没反应。
    /// 留着一颗死键只会让人以为坏了，所以改成 ⇒ **完全隐藏**（alpha 0）。
    /// 打开舞台（这颗开关）它就回来。
    static let footerGlyphDisabledAlpha: CGFloat = 0

    /// 工具行字形整体下移多少。
    ///
    /// （下面还空了很大一块（即呼吸感））：34 → **64**。
    /// 原生那一行中线在 811，被底部那一坨一起上移 55 之后是 756；再 +34 = 790。
    /// 790 到屏幕底（896）还剩 ~90pt 空档，而音量行就在 730…758 —— 上下都挤。
    /// 现在 +64 ⇒ 字形中线 820、框 807…833：音量行与它之间约 26pt，底部只留安全区那一档。
    /// ⚠️ 只挪**我们自己画的**字形与替身（原生按钮全是 `sendActions` 转发，与位置无关）。
    /// ⚠️ 真实值在文件顶部那个 **nonisolated** 的全局常量里（`NowPlayingPageOverlay` 不是
    /// `@MainActor`，读不了本 enum 的静态属性）。
    static let footerRowYOffset: CGFloat = nowPlayingIOS27FooterRowYOffset

    // MARK: - 状态（T2/T3 共用"藏字形"的一套表）
    //
    // 被我们藏掉的**原生字形子树**（按钮本身还活着，替身要能命中它们）。
    static let hiddenGlyphs = NSHashTable<UIView>.weakObjects()
    static var glyphAlphas: [ObjectIdentifier: CGFloat] = [:]

    /// 我们画的三颗（弱引用，页面走了自己掉）。
    static let footerGlyphs = NSHashTable<UIImageView>.weakObjects()
    static weak var footerRelay: NowPlayingIOS27RemoteRelayView?
    /// 上一次找到的"打开全屏歌词"那颗键（弱引用；页面重建就自己掉）。
    static weak var lyricsEntryView: UIView?
    /// 找歌词入口的节流计数（没找到时约 3 秒才全树扫一次）。
    static var lyricsSearchTicks = 0
    static var didLogFooter = false
    /// 左边那颗现在有没有歌词入口（决定暗不暗）。
    static var footerLyricsAvailable = false

    // MARK: - 藏原生字形（T2 循环键也用这一套）
    //
    // 把一颗原生键的**图标子树**按 `alpha = 0` 藏掉（按钮本身不动）。
    //
    // 为什么不是把按钮整体 `alpha = 0`：替身要靠 `hitTest` 进它，而 `alpha <= 0.01`
    // 的视图**参与不了命中测试**（UIKit 在 `hitTest` 第一句就返回 nil）。
    //
    // 这个函数原来会把**一整棵子树的所有层**都写成 `alpha = 0`。
    // 只要传给它的不是"那颗键"，而是一个**祖先容器**（`nearestControl` 会往上爬 6 跳），
    // 一次就能把 bottomStack 里所有兄弟控件一起藏掉。现在两条加固：
    // ① 调用方只传**按钮自己**，不再传 `nearestControl(...)` 的祖先；
    // ② 这里只藏**叶子视图**（真正的字形/文字），容器与别的 `UIControl` 只向下走、
    // 绝不整层按掉 —— 这样最坏也只是"图标没藏干净"，不会让一整块控件消失。
    @discardableResult
    static func hideGlyphSubtree(_ view: UIView) -> Bool {
        var changed = false
        var hidden = 0
        var queue: [UIView] = view.subviews
        var visited = 0
        while !queue.isEmpty, visited < 96 {
            let sub = queue.removeLast()
            visited += 1
            if !sub.subviews.isEmpty {
                // 容器：只往下走，不按掉。
                queue.append(contentsOf: sub.subviews)
                continue
            }
            // 叶子：真正的字形/文字。`UIControl` 叶子不能按 —— `alpha = 0` 会让它
            // 连触摸都收不到（替身还要把点击转发给它）。
            if sub is UIControl { continue }
            let key = ObjectIdentifier(sub)
            if glyphAlphas[key] == nil {
                glyphAlphas[key] = sub.alpha > 0.01 ? sub.alpha : 1
                hiddenGlyphs.add(sub)
            }
            if sub.alpha != 0 {
                sub.alpha = 0
                changed = true
                hidden += 1
            }
        }
        if hidden > 12, !NowPlayingIOS27.didLogWideGlyphHide {
            NowPlayingIOS27.didLogWideGlyphHide = true
            writeDebugLog(
                "[\(NowPlayingIOS27.logTag)] glyph hide — \(NSStringFromClass(type(of: view)))"
                    + " hid \(hidden) leaf view(s); if a whole section is blank, this subtree"
                    + " is the wrong target"
            )
        }
        return changed
    }

    /// 把藏起来的字形按原值写回（幂等；T2 与 T3 都会叫它）。
    static func revealHiddenGlyphs() {
        for sub in hiddenGlyphs.allObjects {
            guard let original = glyphAlphas[ObjectIdentifier(sub)] else { continue }
            if sub.alpha != original { sub.alpha = original }
        }
    }

    /// 清空那两张表（`clearState` 里调用）。
    static func clearHiddenGlyphs() {
        hiddenGlyphs.removeAllObjects()
        glyphAlphas.removeAll()
    }

    // MARK: - 每拍入口
    //
    // 把工具行排成 AM 的三颗。找不到工具行就返回 false。
    //
    // ⚠️ **先量到中线再藏**：量不到位置时若已经把原生字形藏掉，底排就空了。
    @discardableResult
    static func placeFooter(in page: UIView) -> Bool {
        let connect = footerControl(connectButtonIdentifier, in: page)
        let share = footerControl(NowPlayingLyricsPlate.shareButtonIdentifier, in: page)
        let queue = footerControl(queueButtonIdentifier, in: page)
        guard connect != nil || share != nil || queue != nil else { return false }
        guard let rowMidY = footerRowMidY(connect: connect, share: share, queue: queue, in: page) else {
            return false
        }

        var changed = false
        // （跨设备连接 这个按钮会抽搐）：
        // 上一版把原生 Connect 用 `transform` **搬**到中间（207）—— 它住在
        // `UIStackView` 里，栈每次布局写 `frame` 都会把 transform 的位移吃掉/叠加
        // 现在**不搬**：原生键留在原地（x≈38），只把它的字形藏掉；中间那颗自绘
        // airplay 字形的可点区交给替身的 `zones`（真触摸转发到原生键中心）。
        // 真按钮始终在 38，不需要跨半屏 hitTest。
        for button in [connect, share, queue].compactMap({ $0 }) {
            // 这里**只传按钮自己**。以前传的是
            // `nearestControl(button)`（会向上爬 6 跳），一旦爬到 footer 以上的容器，
            // 就会把 bottomStack 里标题/进度/传输/收藏的叶子一起按掉 ⇒ 整块控件消失。
            if hideGlyphSubtree(button) { changed = true }
        }
        // （我感觉应该是放得下的吧）：对，放得下 ——
        // 而音量行（28pt）落在 785…813、
        // 传输行底 781 ⇒ 三件挤在 30pt 里，任何"循环徽标"都会压上去。
        // 这一行（工具行字形 + 可点区）整体**下移 34pt ⇒ 845**：
        // · 音量行下沿 813 → 字形框顶 832，中间留 19pt；
        // · 框底 858 仍在安全区（862）以内；
        // · 循环徽标（24pt、中心 = 队列中心右上 13/−20 ⇒ 825）落在 813…837，
        // 既不碰音量行（813 起）、也不碰队列的**字形墨迹**（836 起）——
        // 就是 AM / MeloX 那种"小图标压在队列右上"的样子。
        // 只挪**我们自己画的**三颗与替身，原生那三颗一个字都不动（它们本来就被藏了字形）。
        let glyphMidY = rowMidY + footerRowYOffset
        if mountFooterGlyphs(in: page, midY: glyphMidY, connect: connect, share: share, queue: queue) {
            changed = true
        }
        return changed
    }

    /// 底排的一颗原生键 —— **只认当前可见页**。
    private static func footerControl(_ identifier: String, in page: UIView) -> UIView? {
        var queue: [UIView] = [page]
        var visited = 0
        while !queue.isEmpty, visited < 3000 {
            let view = queue.removeFirst()
            visited += 1
            // （72ee701 的回归）：三颗原生键本来就贴着页面**左右边缘**
            // （Connect ≈38、分享 ≈329、队列 ≈376），用默认的 20%…80% 中线判据会把
            // 它们全部筛掉 ⇒ `placeFooter` 直接 return false，底排三颗字形 + 替身
            // 一起消失。这里只要"中线还在页面横向范围内"即可；离屏 pager 副本在
            // x≈-413 / +414 之外，照样会被挡掉。
            if view.accessibilityIdentifier == identifier,
               NowPlayingIOS27.isControlOnPage(
                   view,
                   in: page,
                   requireAlpha: false,
                   horizontalMargin: 0
               ) {
                return view
            }
            queue.append(contentsOf: view.subviews)
        }
        return nil
    }

    /// 底排的中线 y（页面坐标）：三颗里能量到的取中位数，量不到就用底排的公共上沿推。
    private static func footerRowMidY(
        connect: UIView?, share: UIView?, queue: UIView?, in page: UIView
    ) -> CGFloat? {
        var values: [CGFloat] = []
        for view in [share, queue, connect].compactMap({ $0 }) {
            // ⚠️ 必须用 `convert`（**带 transform**）：起 `npv.bottomStackView`
            // 被整体上移 55pt（`placeBottomStack`），`untransformed` 会量到**上移之前**的位置，
            // 于是我们画的字形/替身留在老地方、和原生键错开一整段（上一轮翻车就这原因）。
            let rect = view.convert(view.bounds, to: page)
            guard rect.height > 1, rect.midY > 0, rect.midY < page.bounds.height else { continue }
            values.append(rect.midY)
        }
        guard !values.isEmpty else { return nil }
        values.sort()
        return values[values.count / 2]
    }

    // MARK: - 三颗字形 + 替身

    @discardableResult
    private static func mountFooterGlyphs(
        in page: UIView,
        midY: CGFloat,
        connect: UIView?,
        share: UIView?,
        queue: UIView?
    ) -> Bool {
        // （歌词这部分，不能直接复用吗，iOS 27 这边只需要改动画就好了）：
        // 左边这颗气泡**永远**开我们自己的页内歌词（正文复用 `AppleMusicLyricsPage`）；
        // iOS 26+ **根本不转发** Spotify 那颗键，所以连找都不用找
        // —— 省掉每 ~3 秒一次的 2000 节点 BFS。只有 iOS 26 以下才需要它。
        // ⚠️ 要认**缓存**：`lyricsEntryTarget` 是节流的，被节流的那一拍返回 nil，
        // 但上一拍已经找到的那颗还在（`lyricsEntryView`）—— 否则那颗键会每 3 秒"失灵 9 拍"、
        // 左边那颗也会跟着一闪一闪。
        let lyricsTarget: UIView? = canOpenOwnLyricsPage
            ? nil
            : (lyricsEntryTarget(in: page) ?? lyricsEntryView)
        // 那颗键**永远可点**：
        // iOS 26+ ⇒ 我们自己的页内歌词；iOS 26 以下 ⇒ 退回 Spotify 那颗 `lyrics-expand-button`。
        footerLyricsAvailable = canOpenOwnLyricsPage || lyricsTarget != nil

        // 页面换了（或上一份的宿主没了）⇒ 先把旧字形拆干净，别留在上一页上。
        if footerRelay == nil || footerRelay?.superview !== page {
            for glyph in footerGlyphs.allObjects { glyph.removeFromSuperview() }
            footerGlyphs.removeAllObjects()
        }

        let box = footerGlyphBox
        let scale = page.bounds.width / 414
        var changed = false
        var frames: [CGRect] = []
        let symbols = ["quote.bubble", "airplayaudio", "list.bullet"]
        let names = ["lyrics", "connect", "queue"]

        for (index, name) in names.enumerated() {
            let centreX = footerGlyphCentres[index] * scale
            let frame = CGRect(
                x: (centreX - box / 2).rounded(),
                y: (midY - box / 2).rounded(),
                width: box,
                height: box
            )
            frames.append(frame)

            let identifier = footerGlyphIdentifierPrefix + name
            var glyph = footerGlyphs.allObjects.first { $0.accessibilityIdentifier == identifier }
            if glyph == nil {
                let fresh = UIImageView(frame: frame)
                fresh.accessibilityIdentifier = identifier
                fresh.contentMode = .center
                fresh.isUserInteractionEnabled = false
                fresh.tintColor = footerGlyphTint
                fresh.image = footerSymbol(named: symbols[index])
                page.addSubview(fresh)
                footerGlyphs.add(fresh)
                glyph = fresh
                changed = true
            }
            guard let glyph else { continue }
            if glyph.frame != frame {
                glyph.frame = frame
                changed = true
            }
            // 舞台关着 + 找不到原生键 ⇒ **不画**（见 `footerGlyphDisabledAlpha`）。
            // 这一档叫不上“变暗”了，就是真的没有歌词入口。
            // Connect 那颗现在**由我们画**（原生键留在 38、字形被藏）⇒ 这一颗
            // 必须是 alpha 1，否则中间就空了（上一版是 0，因为原生字形被搬过来露着）。
            let wantedAlpha: CGFloat
            if name == "lyrics" && !footerLyricsAvailable {
                wantedAlpha = footerGlyphDisabledAlpha
            } else {
                wantedAlpha = 1
            }
            if glyph.alpha != wantedAlpha {
                glyph.alpha = wantedAlpha
                changed = true
            }
        }

        // `accessibilityActivate` / `sendActions` 对这颗 Encore 包装的 Connect 都不生效。
        // 最终方案：把原生 Connect 从 `UIStackView` 里**结构性地**搬到中间字形的位置
        // （207），原槽位留一个等宽 placeholder；然后用替身的 `zones`（真触摸转发）
        // 指向它 —— 目标真的在手指底下，`hitTest` 到的是按钮自己，不是 `.touchUpOutside`。
        // 不再用 transform（栈会吃位移 = 抽搐），也不再走 actionZone。
        //
        // 替身：三个互不相交的 zone，各指向一颗原生键。
        let relay: NowPlayingIOS27RemoteRelayView
        if let existing = footerRelay, existing.superview === page {
            relay = existing
        } else {
            let fresh = NowPlayingIOS27RemoteRelayView(frame: page.bounds)
            fresh.accessibilityIdentifier = "eevee-ios27-footer-relay"
            fresh.backgroundColor = .clear
            fresh.isUserInteractionEnabled = true
            page.addSubview(fresh)
            relay = fresh
            footerRelay = fresh
            changed = true
        }
        var actionZones: [(rect: CGRect, action: () -> Void)] = []
        var zones: [(rect: CGRect, target: UIView)] = []
        let tapSide = footerTapSide
        func tapRect(_ frame: CGRect) -> CGRect {
            CGRect(
                x: (frame.midX - tapSide / 2).rounded(),
                y: (frame.midY - tapSide / 2).rounded(),
                width: tapSide,
                height: tapSide
            )
        }
        // **一律走 `sendActions`**（`tapAction`），不再把触摸 hitTest 到
        // 原生键上 —— 那颗键不在手指底下，UIKit 算出来的点落在它 bounds 之外，
        // 控件发的是 `.touchUpOutside`（用户报的"iOS 27 下歌词点不了"就是它）。
        // 只有实在找不到 `UIControl` 时才退回 `zones`（至少不把触摸吞掉）。
        func addZone(_ frame: CGRect, target: UIView?, label: String) {
            guard let target else { return }
            let action = tapAction(for: target, label: label)
            // （下面那个雷达点不动）：中间那颗是 Spotify 的
            // Connect / 输出切换（`ConnectButtonOutputSwitcher`）。它在 9.1.88 上是
            // Encore 包出来的，`sendActions` 到最内层 `UIControl` 有时什么都不做 ——
            // 这里先试**无障碍激活**（`accessibilityActivate`），它走的是控件自己的
            // "我该干什么"那条路，对 SwiftUI/Encore 包装层比 target/action 稳。
            // 失败了再退回 `sendActions`（其它两颗维持原路）。
            if label == "connect" {
                // 目标可能是个 ViewHolder（`ConnectButtonOutputSwitcherViewHolder`），真正的
                // `EncoreButton` 在它里面 —— `accessibilityActivate` 要打在**那颗**上。
                let control = NowPlayingIOS27.nearestControl(target)
                actionZones.append((tapRect(frame), {
                    if let control, control.accessibilityActivate() {
                        writeDebugLog(
                            "[\(logTag)] connect: accessibilityActivate handled the tap"
                                + " (\(NSStringFromClass(type(of: control))))"
                        )
                        return
                    }
                    if let action {
                        action()
                        return
                    }
                    (target as? UIControl)?.sendActions(for: .touchUpInside)
                }))
                return
            }
            if let action {
                actionZones.append((tapRect(frame), action))
            } else {
                // 没有 target/action 的包装层：也走一次无障碍激活（比 hitTest 到远处可靠）。
                actionZones.append((tapRect(frame), {
                    if !target.accessibilityActivate() {
                        (target as? UIControl)?.sendActions(for: .touchUpInside)
                    }
                }))
            }
        }
        if canOpenOwnLyricsPage {
            // （歌词这部分，不能直接复用吗，iOS 27 这边只需要改动画就好了）：
            // **歌词键永远开我们自己的页** —— iOS 27 页内歌词（缩封面、移标题、铺
            // `AppleMusicLyricsPage`），进度/传输/音量/底排保持原样。
            // ⛔原来这里还有「独立窗口 LyricsStage」那一档，已随
            // 「更炫酷的逐词歌词」整体删除；现在只剩页内这一条。
            actionZones.append((tapRect(frames[0]), {
                writeDebugLog("[\(logTag)] lyrics: toggling the iOS 27 in-page lyrics")
                onMainThreadSync {
                    NowPlayingIOS27.toggleLyricsMode(in: page)
                }
            }))
        } else if let target = lyricsTarget, let action = tapAction(for: target, label: "lyrics") {
            // iOS 26 以下没有我们自己的歌词页：退回 Spotify 那颗键。
            actionZones.append((tapRect(frames[0]), action))
        }
        // Connect 这颗 `accessibilityActivate` / `sendActions` 都不认。把它从栈里
        // 结构性搬到 207（原槽位 placeholder），目标就真的在手指底下；再用 `zones`
        // 做真触摸转发。搬不动（不在 UIStackView 里）才退回动作级。
        if let connect, let target = NowPlayingIOS27.moveConnectHolder(
            connect, to: frames[1], in: page
        ) {
            zones.append((tapRect(frames[1]), target))
        } else if let connect {
            actionZones.append((tapRect(frames[1]), {
                NowPlayingIOS27.activateConnect(connect)
            }))
        }
        addZone(frames[2], target: queue, label: "queue")
        relay.zones = zones
        relay.actionZones = actionZones
        // （点右下角那颗，还是 Spotify 原生弹窗）：循环那颗是**另一块替身**，
        // 它的框和这里的"队列"可点区（44pt，必须盖住藏在下面的原生分享键）必然重叠。
        // 谁先收到触摸取决于 subviews 顺序（这一层每拍 bringToFront 一次）⇒ 同一处时而开队列、
        // 时而循环。现在把循环那颗的框从**本层**命中范围里排除：那一小块会让给下面那块替身，
        // 与顺序无关。（循环还没摆出来的那一两拍，`repeatPill` 为 nil，就不排除。）
        if let pill = repeatPill, pill.superview === page {
            relay.excludedRects = [pill.frame]
        } else {
            relay.excludedRects = []
        }
        if relay.frame != page.bounds { relay.frame = page.bounds }
        if page.subviews.last !== relay { page.bringSubviewToFront(relay) }

        if !didLogFooter {
            didLogFooter = true
            func name(_ view: UIView?) -> String {
                view.map { NSStringFromClass(type(of: $0)) } ?? "missing"
            }
            writeDebugLog(
                "[\(logTag)] footer — connect \(name(connect)), share \(name(share)),"
                    + " queue \(name(queue)); three glyphs at"
                    + " \(Int(frames[0].midX))/\(Int(frames[1].midX))/\(Int(frames[2].midX))"
                    + " (y \(Int(midY))); lyrics entry"
                    + (canOpenOwnLyricsPage
                        ? " = our lyrics page (reusing AppleMusicLyricsPage)"
                        : (footerLyricsAvailable
                            ? " = \(name(lyricsTarget))"
                            : " missing (left glyph hidden)"))
            )
        }
        return changed
    }

    /// 全屏歌词的入口：Spotify 歌词卡片里那颗 `ShowLyricsButton*`
    /// （dump：`Lyrics_CardElementImpl.ShowLyricsButtonElementUI`）。
    ///
    /// ⚠️ **不拿卡片本身当替身**：卡片整块是可点的歌词预览，把触摸打进它的中心有可能
    /// 落到"点某一行 ⇒ seek"上，那不是我们要的入口。找不到那颗键就让左边那颗变暗。
    ///
    /// 只在第一次（以及那颗键随页面重建消失时）做一次全树查找 —— 这条每 0.3s 会跑，
    /// 每次都 BFS 一遍播放页太贵。
    private static func lyricsEntryTarget(in page: UIView) -> UIView? {
        if let cached = lyricsEntryView, cached.window != nil, cached.alpha > 0.01 {
            return cached
        }
        // 没找到时**不要每拍全树扫**（0.3s 一次的 2000 节点 BFS 太贵）：约 3 秒找一次。
        lyricsSearchTicks += 1
        guard lyricsSearchTicks % 10 == 1 else { return nil }
        var roots: [UIView] = [page]
        if let list = NowPlayingOneScreen.pinnedList, list !== page { roots.append(list) }
        for root in roots {
            if let found = firstLyricsButton(in: root) {
                lyricsEntryView = found
                return found
            }
        }
        lyricsEntryView = nil
        return nil
    }

    /// 子树里第一颗“打开全屏歌词”的键（预算 2000 个视图）。
    ///
    /// 两条判据：类名含 `ShowLyricsButton`（老版本，要求是 `UIControl`）或者
    /// 无障碍 id 是 `lyrics-expand-button`（9.1.88 上它是一颗 `EncoreButton`，
    /// **不能**先要求 `is UIControl` —— 它是 SwiftUI 托管的控件，类型不一定是 UIControl）。
    /// 靠近位置/可见性不做判据：卡片在真机上被挤成 0 高（`CardView … 374,0`），
    /// 但那颗键自己仍然是 44×44、alpha 1、可命中。
    private static func firstLyricsButton(in root: UIView) -> UIView? {
        var visited = 0
        var queue: [UIView] = [root]
        while !queue.isEmpty, visited < 2000 {
            let view = queue.removeFirst()
            visited += 1
            queue.append(contentsOf: view.subviews)
            guard view.alpha > 0.01, !view.isHidden else { continue }

            if view.accessibilityIdentifier == lyricsButtonIdentifier {
                return view
            }
            guard view is UIControl else { continue }
            if NSStringFromClass(type(of: view)).contains(lyricsButtonClassFragment) {
                return view
            }
        }
        return nil
    }

    /// 我们自己的歌词页能不能开（iOS 26+ 的门）。
    static var canOpenOwnLyricsPage: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }

    private static func footerSymbol(named name: String) -> UIImage? {
        let configuration = UIImage.SymbolConfiguration(
            pointSize: footerGlyphPointSize,
            weight: .regular
        )
        return UIImage(systemName: name, withConfiguration: configuration)?
            .withRenderingMode(.alwaysTemplate)
    }

    /// 点我们画的中间那颗 airplay 字形 = 激活**原生 Connect**（它还在 38，字形被藏）。
    ///
    /// 为什么不是 `zones` / `sendActions`：见 `mountFooterGlyphs` 里那段 —— 替身的
    /// `zones` 把 `UITouch` 的真实坐标交给原生键，跨 170pt 必然 `.touchUpOutside`；
    /// 这里把**动作级**的三条路都试一遍：
    /// ① `accessibilityActivate`（由内到外）—— 不依赖位置，对 SwiftUI/Encore 包装层
    /// 比 target/action 稳；
    /// ② `sendActions(for: .primaryActionTriggered)` / `.touchUpInside` —— 经典
    /// target/action 兜底；
    /// ③ 都没有接受时只打日志，**不假装成功**；下一招才是把原生键真的摆到 207
    /// （重排 stack / 加占位），那会动布局，先留到这一招被真机否掉之后。
    static func activateConnect(_ holder: UIView) {
        var all: [UIView] = []
        var controls: [UIControl] = []
        var queue: [UIView] = [holder]
        var visited = 0
        while !queue.isEmpty, visited < 64 {
            let view = queue.removeFirst()
            visited += 1
            all.append(view)
            if let control = view as? UIControl { controls.append(control) }
            queue.append(contentsOf: view.subviews)
        }
        // 先内后外：最内层的 EncoreButton / ConnectButtonView 更可能是 accessibility element。
        for view in all.reversed() {
            if view.accessibilityActivate() {
                writeDebugLog(
                    "[\(logTag)] connect: accessibilityActivate handled the tap"
                        + " (\(NSStringFromClass(type(of: view))))"
                )
                return
            }
        }
        for control in controls {
            control.sendActions(for: .primaryActionTriggered)
            control.sendActions(for: .touchUpInside)
        }
        writeDebugLog(
            "[\(logTag)] connect: no action accepted the tap —"
                + " the native button still needs a real touch"
        )
    }

    /// 把**原生 Connect 按钮**从栈里结构性搬到目标中心（`frames[1]` = 207）。
    ///
    /// 为什么不是 transform：它在 `UIStackView` 里，栈每次布局写 `frame` 会把 transform
    /// 的位移吃掉/叠加。
    /// Encore 包装的 Connect 不认这两种动作；只有**真触摸**能开面板。
    /// 现在把栈里的那一格换成等宽 placeholder，把按钮本体搬到页面上；替身的 `zones`
    /// 在 207 做真触摸转发时，目标真的就在手指底下 —— 不会再 `.touchUpOutside`。
    ///
    /// - Returns: 搬到页面上、可交给 `zones` 的那个视图；搬不动返回 nil（调用方退回动作级）。
    @discardableResult
    static func moveConnectHolder(_ holder: UIView?, to frame: CGRect, in page: UIView) -> UIView? {
        guard let holder, holder.window != nil else { return nil }

        // 目标可能是 ViewHolder 里面的一层；往上找到 `UIStackView` 的直接子视图。
        var arranged = holder
        var hops = 0
        while hops < 6,
              let parent = arranged.superview,
              parent !== page,
              !(parent is UIStackView) {
            arranged = parent
            hops += 1
        }

        let width = arranged.bounds.width > 1 ? arranged.bounds.width : 47
        let height = arranged.bounds.height > 1 ? arranged.bounds.height : 36
        let wanted = CGRect(
            x: (frame.midX - width / 2).rounded(),
            y: (frame.midY - height / 2).rounded(),
            width: width,
            height: height
        )

        // 已经在页面上：只对齐位置。
        if arranged.superview === page {
            if movedConnectHolder !== arranged { movedConnectHolder = arranged }
            if arranged.frame != wanted { arranged.frame = wanted }
            return arranged
        }

        guard let stack = arranged.superview as? UIStackView,
              let index = stack.arrangedSubviews.firstIndex(of: arranged) else { return nil }

        if movedConnectHolder !== arranged {
            restoreMovedConnectHolder()
            movedConnectHolder = arranged
        }

        // Spotify 可能把按钮又塞回栈里；旧 placeholder 先清掉，避免一格变两格。
        if let old = connectPlaceholder {
            old.removeFromSuperview()
            connectPlaceholder = nil
        }

        let placeholder = UIView()
        placeholder.isUserInteractionEnabled = false
        placeholder.backgroundColor = .clear
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        placeholder.widthAnchor.constraint(equalToConstant: max(width, 44)).isActive = true
        placeholder.heightAnchor.constraint(equalToConstant: max(height, 36)).isActive = true
        stack.insertArrangedSubview(placeholder, at: index)
        connectPlaceholder = placeholder

        arranged.removeFromSuperview()
        arranged.transform = .identity
        arranged.translatesAutoresizingMaskIntoConstraints = true
        // 放到中间那颗自绘 airplay 字形**下面**：字形就是那颗按钮的"皮肤"，
        // 不能被按钮自己的玻璃底盖住。
        if let glyph = footerGlyphs.allObjects.first(where: {
            abs($0.center.x - frame.midX) < 2
        }), glyph.superview === page {
            page.insertSubview(arranged, belowSubview: glyph)
        } else {
            page.addSubview(arranged)
        }
        for glyph in footerGlyphs.allObjects {
            page.bringSubviewToFront(glyph)
        }
        arranged.frame = wanted

        if !didLogConnectMoved {
            didLogConnectMoved = true
            writeDebugLog(
                "[\(logTag)] connect: moved out of the stack to x=\(Int(wanted.midX)),"
                    + " y=\(Int(wanted.midY)) — the relay forwards a real touch"
            )
        }
        return arranged
    }

    /// 把搬过的原生 Connect 按钮放回原栈槽位（收尾 / 换页）。
    static func restoreMovedConnectHolder() {
        guard let holder = movedConnectHolder else {
            connectPlaceholder = nil
            movedConnectBase = nil
            return
        }
        if let placeholder = connectPlaceholder,
           let stack = placeholder.superview as? UIStackView {
            let index = stack.arrangedSubviews.firstIndex(of: placeholder) ?? 0
            stack.removeArrangedSubview(placeholder)
            placeholder.removeFromSuperview()
            if holder.superview !== stack {
                if holder.superview is UIStackView {
                    // 已经被 Spotify 塞进一个新的栈：不要再搬回旧栈。
                } else {
                    holder.removeFromSuperview()
                    holder.transform = .identity
                    holder.translatesAutoresizingMaskIntoConstraints = false
                    stack.insertArrangedSubview(
                        holder,
                        at: min(index, stack.arrangedSubviews.count)
                    )
                }
            }
        } else if let superview = holder.superview, !(superview is UIStackView) {
            holder.removeFromSuperview()
        }
        movedConnectHolder = nil
        connectPlaceholder = nil
        movedConnectBase = nil
    }

    // MARK: - 收尾

    static func teardownFooter() {
        restoreMovedConnectHolder()
        revealHiddenGlyphs()
        for glyph in footerGlyphs.allObjects {
            glyph.removeFromSuperview()
        }
        footerGlyphs.removeAllObjects()
        footerRelay?.removeFromSuperview()
        footerRelay = nil
    }

    static func clearFooterState() {
        footerGlyphs.removeAllObjects()
        footerRelay = nil
        lyricsEntryView = nil
        lyricsSearchTicks = 0
        didLogFooter = false
        footerLyricsAvailable = false
        movedConnectHolder = nil
        connectPlaceholder = nil
        movedConnectBase = nil
        didLogConnectMoved = false
    }
}
