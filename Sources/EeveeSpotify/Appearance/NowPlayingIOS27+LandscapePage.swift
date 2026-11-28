// 横屏「歌词自己的屏」—— 这一屏由我们自己搭。
//
// 旧的横屏做法是**改 Spotify 的原生几何**：把 `npv.bottomStackView` 收窄到左栏、压低它的
// 横向约束优先级、再把歌名 / 进度 / 传输三行搬出栈自己摆。那条路每一拍都在跟布局回合打架
// （真机上宽度与横位都没留住，盒子仍是 272pt），封面只能吃剩下的高度，而**歌词的左沿是从
// 左栏右边沿加一个间隙推出来的** —— 左栏一塌到下限，歌词就跟着滑到页面正中间。
//
// 这一层换做法：横屏时铺一屏**我们自己的**东西。
// · 歌名 / 艺人 / 进度 / 传输由这里画（文案读原生标签，动作走 `WordByWordPlaybackControl`
//   与 `WordByWordSeeker`，原生那一页仍然连着真实播放管线）；
// · 歌词还是那一份 SwiftUI 宿主（`NowPlayingLyricsPlate.mountLyricsOnly`），位置由这里给；
// · 原生那一坨（歌名 / 进度 / 传输 / 收藏 / 工具行）整块 `alpha = 0` 按下去，只当状态源；
// · 封面仍由 `updateArtwork` 画（那张图本来就是我们自己的），位置取本层的 `cover`。
//
// 几何**只由页面尺寸与安全区推**，不读 Spotify 的任何一坨 ⇒ 换歌 / 换页 / 转屏都不会让
// 歌词再挪位置。右栏口径：右沿落在右上那颗 ⋯ 与它下面三颗字形之内侧，宽度封顶
// `landscapeLyricsMaxWidth`（多出来的宽度**放到左边**，不往中间挤）。
//
// 开关 `landscapePageEnabled`：关掉退回旧的两栏路径（`placeLandscapeStack` + `LandscapeRows`），
// 便于并排对比两版。日志 tag：`[iOS27]`，一次性一行 `landscape page — …`。
import Foundation
import SwiftUI
import UIKit
import ObjectiveC.runtime

@MainActor
extension NowPlayingIOS27 {

    /// 横屏自建页这一档开不开。关掉走旧路径（收窄底排 + 搬行）。
    static let landscapePageEnabled = true

    // MARK: - 几何

    /// 横屏这一屏的框（页面坐标）。只由页面尺寸与安全区推出来。
    struct LandscapePageGeometry {
        var column: CGRect
        var cover: CGRect
        var title: CGRect
        var artist: CGRect
        /// 进度 / 两端时间 / 传输那一条（SwiftUI 控件自带内部排版）。
        var controls: CGRect
        var lyrics: CGRect

        /// 交给 `landscapeLayout` 的那一份：封面与歌词都从它取（见 `artworkFrame` / `lyricsStageFrame`）。
        var shared: LandscapeLayout {
            LandscapeLayout(
                column: column,
                cover: cover,
                lyrics: lyrics,
                stackLeft: column.minX,
                stackInset: 24,
                stackContentHeight: 0
            )
        }
    }

    /// 自建页的几何；竖屏 / 页面太矮 / 开关关着时 nil。
    ///
    /// 左栏自上而下：封面 → 歌名 → 艺人 → 进度 → 时间 → 传输。封面吃的是
    /// 「可用高 − 这一列控件 − 空隙」，所以它和这一列是互相约束的（不是写死的）。
    static func landscapePageGeometry(in page: UIView) -> LandscapePageGeometry? {
        guard landscapePageEnabled, isLandscapeTwoColumn(page) else { return nil }
        let bounds = page.bounds
        let insets = page.safeAreaInsets
        let left = max(12, insets.left + 16)
        let top = max(16, insets.top + 8)
        let bottom = bounds.height - max(12, insets.bottom + 6)
        let usable = bottom - top
        // 右缘那一列（右上角的 ⋯ 与它下面三颗字形）由这里让出去。
        let rightRail = bounds.width - max(24, insets.right + 64)
        guard usable > 220, rightRail - left > 320 else { return nil }

        let titleHeight: CGFloat = 24
        let artistHeight: CGFloat = 18
        let controlsHeight: CGFloat = 104
        let textGap: CGFloat = 4
        let rowGap: CGFloat = 10
        let bandHeight = titleHeight + textGap + artistHeight + rowGap + controlsHeight
        var coverSide = min(
            LayoutGeometry.landscapeCoverMaxSide,
            usable - bandHeight - LayoutGeometry.landscapeCoverStackGap
        )
        coverSide = max(LayoutGeometry.landscapeMinCoverSide, coverSide)
        let columnWidth = min(max(coverSide, LayoutGeometry.landscapeColumnMinWidth), rightRail - left)

        let column = CGRect(x: left, y: top, width: columnWidth, height: usable)
        let cover = CGRect(x: left, y: top, width: coverSide, height: coverSide)
        var y = cover.maxY + LayoutGeometry.landscapeCoverStackGap
        let title = CGRect(x: left, y: y, width: columnWidth, height: titleHeight)
        y = title.maxY + textGap
        let artist = CGRect(x: left, y: y, width: columnWidth, height: artistHeight)
        y = artist.maxY + rowGap
        let controls = CGRect(x: left, y: y, width: columnWidth, height: controlsHeight)

        // 歌词贴右：右沿落在 rail 上，宽度封顶。多出来的宽度**留在左边**（不去中间）。
        let room = rightRail - (column.maxX + LayoutGeometry.landscapeColumnGap)
        guard room > 200 else { return nil }
        let lyricsWidth = min(room, landscapeLyricsMaxWidth)
        let lyrics = CGRect(x: rightRail - lyricsWidth, y: top, width: lyricsWidth, height: usable)

        return LandscapePageGeometry(
            column: column,
            cover: cover,
            title: title,
            artist: artist,
            controls: controls,
            lyrics: lyrics
        )
    }

    // MARK: - 状态

    /// 我们自己那一屏（透明的承载层 + 两颗 UIKit 标签 + 一条 SwiftUI 控件）。
    static var landscapePageView: LandscapePageView?
    static var landscapePageTitle: UILabel?
    static var landscapePageArtist: UILabel?
    static var landscapePageControls: UIHostingController<LandscapePageControls>?
    /// 被整块按下去的原生底排（收回时要按原值写回）。
    static weak var landscapeHiddenStack: UIView?
    static var didLogLandscapePage = false

    /// 播放状态投影：时间 / 时长 / 是否在播（`AppleMusicLyricsPlaybackControl` 里那份）。
    static let landscapePageProjection = AppleMusicLyricsPlaybackProjection {
        WordByWordPositionResolver.shared.currentPositionSeconds()
    }

    // MARK: - 每拍入口

    /// 把这一屏摆好；不在横屏 / 开关关着时收走。
    ///
    /// ⚠️ 必须排在 `updateLyricsStage` 之前（歌词容器按 `landscapeLayout` 的 `lyrics` 铺）。
    @discardableResult
    static func placeLandscapePage(in page: UIView) -> Bool {
        guard let geometry = landscapePageGeometry(in: page) else {
            clearLandscapePage()
            return false
        }
        // 这一档不搬行：上一档留下的三行先放回底排（否则底排里的槽位是空的）。
        if landscapeTitleRow != nil || landscapeProgressRow != nil || landscapeTransportRow != nil {
            restoreLandscapeRows()
        }

        let view = ensureLandscapePageView(in: page)
        var changed = false
        if view.frame != page.bounds {
            view.frame = page.bounds
            changed = true
        }

        let titleText = landscapePageText(identifier: NowPlayingLyricsPlate.titleLabelIdentifier, in: page)
        if updateLandscapePageLabel(landscapePageTitle, text: titleText, frame: geometry.title) {
            changed = true
        }
        let artistText = landscapePageText(identifier: NowPlayingLyricsPlate.subtitleLabelIdentifier, in: page)
        if updateLandscapePageLabel(landscapePageArtist, text: artistText, frame: geometry.artist) {
            changed = true
        }
        if let controls = landscapePageControls, controls.view.frame != geometry.controls {
            controls.view.frame = geometry.controls
            changed = true
        }
        // 只有控件那一条吃触摸，其余全部放行给 Spotify 自己的手势。
        if view.hitRects != [geometry.controls] {
            view.hitRects = [geometry.controls]
        }
        // 位置 / 时长 / 是否在播：这一拍先刷一次（进度条就按这一拍的节拍走）。
        landscapePageProjection.refresh()

        if !didLogLandscapePage {
            didLogLandscapePage = true
            let titleNote = titleText == nil ? "missing" : "ok"
            let artistNote = artistText == nil ? "missing" : "ok"
            writeDebugLog(
                "[\(logTag)] landscape page — cover \(Int(geometry.cover.width))pt at"
                    + " \(landscapeRectText(geometry.cover)),"
                    + " lyrics \(Int(geometry.lyrics.minX))…\(Int(geometry.lyrics.maxX)),"
                    + " title \(titleNote), artist \(artistNote)"
            )
        }
        return changed
    }

    /// 自建页这一档"可以亮歌词"：我们自己的封面已经在页上，不再等 Spotify 的标题行
    /// （那一行整块被我们按着，`titleRowPlaced` 永远不过）。
    static func landscapePageSceneReady(in page: UIView) -> Bool {
        guard landscapePageGeometry(in: page) != nil else { return false }
        return landscapePageView?.window != nil && artworkOnPage(in: page)
    }

    /// 把这一屏收走（回竖屏 / 关页面）。原生那一坨按原值放回来。
    static func clearLandscapePage() {
        if landscapePageControls != nil {
            landscapePageControls?.view.removeFromSuperview()
            landscapePageControls = nil
        }
        if landscapePageView != nil {
            landscapePageView?.removeFromSuperview()
            landscapePageView = nil
        }
        landscapePageTitle = nil
        landscapePageArtist = nil
        didLogLandscapePage = false
        revealLandscapeHiddenStack()
    }

    // MARK: - 原生底排的按 / 放

    /// 把原生那一坨整块按下去（**位置不碰**）。返回这一拍有没有写东西。
    static func hideLandscapeNativeStack(_ stack: UIView) -> Bool {
        landscapeHiddenStack = stack
        return hideChrome(stack)
    }

    /// 只把这一坨按原值放回来（不碰导航 chrome —— 那是 `placeNavChrome` 的账）。
    static func revealLandscapeHiddenStack() {
        guard let stack = landscapeHiddenStack else { return }
        landscapeHiddenStack = nil
        let key = ObjectIdentifier(stack)
        guard let original = chromeAlphas[key] else { return }
        if stack.alpha != original { stack.alpha = original }
        chromeAlphas.removeValue(forKey: key)
        hiddenChrome.remove(stack)
    }

    // MARK: - 视图

    /// 自建页的承载层：透明、**只在 `hitRects` 里吃触摸**，其余放行。
    final class LandscapePageView: UIView {
        var hitRects: [CGRect] = []

        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
            for rect in hitRects where rect.contains(point) { return true }
            return false
        }
    }

    private static func ensureLandscapePageView(in page: UIView) -> LandscapePageView {
        if let existing = landscapePageView, existing.superview === page { return existing }
        landscapePageView?.removeFromSuperview()
        let view = LandscapePageView(frame: page.bounds)
        view.backgroundColor = UIColor.clear
        view.isOpaque = false
        view.clipsToBounds = false
        view.accessibilityIdentifier = "eevee-ios27-landscape-page"

        let title = makeLandscapePageLabel(
            identifier: "eevee-ios27-landscape-title",
            size: 17,
            weight: .bold
        )
        let artist = makeLandscapePageLabel(
            identifier: "eevee-ios27-landscape-artist",
            size: 13,
            weight: .semibold
        )
        view.addSubview(title)
        view.addSubview(artist)
        page.addSubview(view)
        landscapePageView = view
        landscapePageTitle = title
        landscapePageArtist = artist
        _ = ensureLandscapePageControls(in: view)
        return view
    }

    private static func makeLandscapePageLabel(
        identifier: String,
        size: CGFloat,
        weight: UIFont.Weight
    ) -> UILabel {
        let label = UILabel()
        label.accessibilityIdentifier = identifier
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = UIColor.white
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        label.isUserInteractionEnabled = false
        return label
    }

    private static func updateLandscapePageLabel(
        _ label: UILabel?,
        text: String?,
        frame: CGRect
    ) -> Bool {
        guard let label else { return false }
        var changed = false
        if label.frame != frame {
            label.frame = frame
            changed = true
        }
        let wanted = text ?? ""
        if label.text != wanted {
            label.text = wanted
            changed = true
        }
        return changed
    }

    private static func ensureLandscapePageControls(
        in container: UIView
    ) -> UIHostingController<LandscapePageControls>? {
        if let existing = landscapePageControls, existing.view.superview === container {
            return existing
        }
        landscapePageControls?.view.removeFromSuperview()
        let root = LandscapePageControls(projection: landscapePageProjection) { seconds in
            WordByWordSeeker.seek(toMs: Int((seconds * 1000).rounded()))
        }
        let hosting = UIHostingController(rootView: root)
        hosting.view.backgroundColor = UIColor.clear
        hosting.view.isOpaque = false
        // 这一条由我们给框（几何从 `landscapePageGeometry` 来），不让 Auto Layout 参与。
        hosting.view.translatesAutoresizingMaskIntoConstraints = true
        hosting.view.accessibilityIdentifier = "eevee-ios27-landscape-controls"
        container.addSubview(hosting.view)
        landscapePageControls = hosting
        return hosting
    }

    // MARK: - 读原生标签 / 打日志

    /// 原生那颗标签的文字。
    ///
    /// `now-playing-title-label` 在部分版本里挂在**包着 label 的包装层**上，所以往下找
    /// 第一颗有文字的 `UILabel`，而不是要求命中的那个视图自己就是 label。
    private static func landscapePageText(identifier: String, in page: UIView) -> String? {
        guard let root = NowPlayingLyricsPlate.findByIdentifier(identifier, in: page) else {
            return nil
        }
        var queue: [UIView] = [root]
        var visited = 0
        while !queue.isEmpty, visited < 40 {
            let node = queue.removeFirst()
            visited += 1
            if let label = node as? UILabel, let text = label.text, !text.isEmpty {
                return text
            }
            queue.append(contentsOf: node.subviews)
        }
        return nil
    }

    private static func landscapeRectText(_ rect: CGRect) -> String {
        "\(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))×\(Int(rect.height))"
    }
}

// MARK: - 控件带
//
// 进度条 + 两端时间 + 上一首 / 播放 / 下一首。三个动作走 `WordByWordPlaybackControl`
// （原生那一页仍然连着真实播放管线，我们只是把它盖住），拖动走 `WordByWordSeeker`。
// 这一条**不带** `@available(iOS 26.0, *)`：它只用 SwiftUI 与现有动作层。

/// 横屏自建页的控制带。
struct LandscapePageControls: View {

    @ObservedObject var projection: AppleMusicLyricsPlaybackProjection
    /// 拖动进度条 → 跳到该位置（秒）。
    let onSeek: (TimeInterval) -> Void

    @State private var scrubbedFraction: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            progressBar
                .frame(height: 18)
            HStack(spacing: 0) {
                Text(Self.clock(projection.time))
                Spacer(minLength: 8)
                Text(remainingText)
            }
            .font(.system(size: 11, weight: .semibold).monospacedDigit())
            .foregroundColor(Color.white.opacity(0.66))
            .padding(.top, 2)
            Spacer(minLength: 8)
            transportRow
        }
    }

    // MARK: 进度

    private var progressBar: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)
            let fraction = displayedFraction
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.26))
                    .frame(height: 4)
                Capsule()
                    .fill(Color.white.opacity(0.95))
                    .frame(width: max(0, width * fraction), height: 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            // 轨道只有 4pt：命中区上下各撑 8pt，手指才按得准（不改外观）。
            .contentShape(Rectangle().inset(by: -8))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        scrubbedFraction = min(max(value.location.x / width, 0), 1)
                    }
                    .onEnded { _ in
                        if let fraction = scrubbedFraction, projection.duration > 0 {
                            onSeek(fraction * projection.duration)
                        }
                        scrubbedFraction = nil
                    }
            )
        }
    }

    private var displayedFraction: Double {
        if let scrubbedFraction { return scrubbedFraction }
        guard projection.duration > 0 else { return 0 }
        return min(max(projection.time / projection.duration, 0), 1)
    }

    private var remainingText: String {
        guard projection.duration > 0 else { return "" }
        return "-" + Self.clock(max(projection.duration - projection.time, 0))
    }

    // MARK: 三键

    private var transportRow: some View {
        HStack(spacing: 0) {
            glyph("backward.fill", size: 18, box: 44) {
                WordByWordPlaybackControl.skipToPrevious()
            }
            Spacer(minLength: 0)
            glyph(projection.isPlaying ? "pause.fill" : "play.fill", size: 26, box: 52) {
                WordByWordPlaybackControl.togglePlayPause()
            }
            Spacer(minLength: 0)
            glyph("forward.fill", size: 18, box: 44) {
                WordByWordPlaybackControl.skipToNext()
            }
        }
        .frame(height: 52)
    }

    private func glyph(
        _ systemName: String,
        size: CGFloat,
        box: CGFloat,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: box, height: box)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// `m:ss`，与 Spotify 原生一致（不补零到 `mm:ss`）。
    private static func clock(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return "\(total / 60):" + String(format: "%02d", total % 60)
    }
}
