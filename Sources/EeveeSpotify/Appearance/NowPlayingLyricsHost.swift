// 「歌词进播放器」那层自己的宿主（只属于这一层，不抢全屏页/卡片那个单例）。
// 从 `NowPlayingLyricsPlate.swift` 原样拆出；硬约束与总览见那个文件的头注。
import Foundation
import SwiftUI
import UIKit
import Orion
import ObjectiveC.runtime

// MARK: - 宿主（只属于这一层，不抢全屏页/卡片那个单例）

@available(iOS 26.0, *)
@MainActor
final class NowPlayingLyricsHost {

    var hostingController: UIHostingController<AppleMusicLyricsOverlayView>?
    var renderedVersion: Int = -1
    var renderedTrackId: String = ""
    /// 这一份挂上去的是**静态档**（没有时间轴）吗 —— 换档要重挂。
    var renderedStatic = false
    /// 挂上去那一份的**罗马化开关指纹** —— 变了要就地重写行模型。
    ///
    /// 为什么需要：罗马字是在 `LyricLinesAdapter` 里算进 `LyricLine` 的（按版本缓存），
    /// 而"日文/中文/韩文罗马化"三个开关只写 `UserDefaults`、**不会让版本号变**
    /// ⇒ 不做这件事的话，用户在设置里一开，得等下一次取词（换歌）才看得到。
    var renderedRomanization = -1

    let clock = AppleMusicLyricsClock()
    let projection = AppleMusicLyricsPlaybackProjection {
        WordByWordPositionResolver.shared.currentPositionSeconds()
    }

    var isAttached: Bool { hostingController != nil }

    /// 罗马化那三个开关的**指纹**（逐语言，就是"歌词页面里的选择"）。
    ///
    /// ⚠️ 实现**只有一份**：`romanizationSwitchesFingerprint`（`LyricLinesAdapter.swift` 开头）——
    /// 同一个判据抄两份，迟早只修一份那个 `seekToTappedLyricLine` 就是教训）。
    ///
    /// 它进 `isCurrent` ⇒ 用户一改开关，下一拍（≤0.3s）就会走 `updateLines` 把行模型重写一遍，
    /// 罗马字立刻出现/消失，不用等换歌。
    static func romanizationFingerprint() -> Int {
        romanizationSwitchesFingerprint()
    }

    func isCurrent(version: Int, trackId: String, isStatic: Bool) -> Bool {
        isAttached && renderedVersion == version && renderedTrackId == trackId
            && renderedStatic == isStatic
            && renderedRomanization == Self.romanizationFingerprint()
    }

    func mount(
        in container: UIView,
        lines: [LyricLine],
        version: Int,
        trackId: String,
        isStatic: Bool,
        onSeek: ((TimeInterval) -> Void)?
    ) {
        let root = AppleMusicLyricsOverlayView(
            lines: lines,
            // `.card` 与"透明档"一起用：不画任何背景（播放器这一档底下是整页取色底）。
            backdropStyle: .card,
            solidBackdrop: false,
            showsProviderFooter: false,
            sideInset: NowPlayingLyricsPlate.stageSideInset,
            previewHeaderInset: 0,
            // ⚠️ **不画**预览标题栏那一行（"歌词 · 分享 · 打开全屏歌词"）：它是
            // `AppleMusicLyricsOverlayView.previewHeader`，**我们自己画的**，不是 Spotify 的原生入口
            // ⇒ 去藏原生入口（`lyrics-share-button` 那一批）没用，屏幕上那一行纹丝不动。
            showsPreviewHeader: false,
            onSeek: onSeek,
            trackTitle: "",
            trackArtist: "",
            // ⚠️ **参数顺序必须与结构体里的属性声明顺序完全一致** —— SwiftUI 的逐成员初始化器
            // 是位置敏感的CI 抓到：我把 `transparentBackdrop` 写在 `previewHeaderInset`
            // 后面，编译器报 "argument labels do not match"）。
            transparentBackdrop: true,
            clock: clock,
            projection: projection,
            // 「没有时间轴」那一档 —— 见 `AppleMusicLyricsPage.isStatic`。
            isStatic: isStatic,
            // （**歌词进播放器**的时候也**没有额外的歌词结构**）：
            // 这一档 `showsProviderFooter` 必须是 `false`（不画署名页脚），而副唱以前被绑在它上面
            // ⇒ 的歌词永远没有"主词下方那一小行副唱"。这里显式打开：
            // 署名是元信息、副唱是歌词内容，两件事分开。
            showsBackgroundVocals: true
        )

        let hosting = UIHostingController(rootView: root)
        // ⚠️ 必须写全 `UIColor.clear`：这里没有上下文类型，`.clear` 推断不出来
        // （CI 报 "cannot infer contextual base in reference to member 'clear'"）。
        hosting.view.backgroundColor = UIColor.clear
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        hosting.view.accessibilityIdentifier = "eevee-npv-lyrics"

        container.addSubview(hosting.view)
        // **加进容器之后再重申一次**。
        // 宿主视图在第一次布局前偶尔会把底色写成系统的不透明底（深色模式下就是一块黑），
        // 只设一次不够；`isOpaque = false` 一起写死，`alpha` 淡入才盖得住那一帧。
        hosting.view.backgroundColor = UIColor.clear
        hosting.view.isOpaque = false
        hosting.view.layer.backgroundColor = UIColor.clear.cgColor
        // SwiftUI 第一帧布局之后可能把底色写回来 —— 下一轮再清一次（幂等）。
        DispatchQueue.main.async { [weak hosting] in
            guard let hosting else { return }
            if hosting.view.backgroundColor != .clear {
                hosting.view.backgroundColor = .clear
            }
            hosting.view.isOpaque = false
            hosting.view.layer.backgroundColor = UIColor.clear.cgColor
        }
        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: container.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        // SwiftUI 的 `HostingScrollView` 在 iOS 26 上带系统 `ScrollEdgeEffect`，
        // 它会在滚动区上盖一层暗色/模糊；我们的宿主又是透明的 ⇒ 看起来就是一块
        // 残留的卡片。这里把宿主的 scroll background 清掉、把上下 edge effect 藏掉
        // （只影响这一层，不碰 Spotify 自己的滚动视图）。
        clearScrollChrome(in: hosting.view)
        DispatchQueue.main.async { [weak hosting] in
            guard let hosting else { return }
            self.clearScrollChrome(in: hosting.view)
            // 再补一拍：SwiftUI 在第一次布局之后才把 `HostingScrollView` 建出来。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak hosting] in
                guard let hosting else { return }
                self.clearScrollChrome(in: hosting.view)
            }
        }

        hostingController?.view.removeFromSuperview()
        hostingController = hosting
        renderedVersion = version
        renderedTrackId = trackId
        renderedStatic = isStatic
        renderedRomanization = Self.romanizationFingerprint()
    }

    func updateLines(_ lines: [LyricLine], version: Int, trackId: String, isStatic: Bool) {
        guard let hosting = hostingController else { return }
        hosting.rootView.lines = lines
        hosting.rootView.isStatic = isStatic
        renderedVersion = version
        renderedTrackId = trackId
        renderedStatic = isStatic
        renderedRomanization = Self.romanizationFingerprint()
        // SwiftUI 偶尔会重建内部滚动视图 ⇒ 每一程都再清一次（幂等）。
        clearScrollChrome(in: hosting.view)
    }

    // MARK: - 宿主的滚动视图（iOS 26 的 ScrollEdgeEffect）
    //
    // 把宿主里那个 SwiftUI `HostingScrollView` 的**底色**与**系统 scroll edge effect** 清掉。
    //
    // 为什么：这一层是"只有歌词"的透明层，宿主/容器都是 clear；但 iOS 26 的
    // `UIScrollView` 自带 `topEdgeEffect` / `bottomEdgeEffect`，会在滚动区上画一层
    // 暗色 + 模糊 ⇒ 屏幕上就是一块**比底子暗一档的矩形**
    // 和上下两条"黑边"。只碰这一棵子树，不 hook 全局 UIScrollView。
    private func clearScrollChrome(in root: UIView) {
        var queue: [UIView] = [root]
        var visited = 0
        var scrollCount = 0
        while !queue.isEmpty, visited < 400 {
            let view = queue.removeFirst()
            visited += 1
            // 兜底：宿主里如果混进了系统的边缘模糊视图 / 歌词背景层，也一并藏掉
            // （这一层只该有歌词文字；背景由播放器自己的 field 负责）。
            let className = NSStringFromClass(type(of: view))
            if className.contains("ScrollEdgeEffect") || className.contains("LyricsBackdrop") {
                if !view.isHidden { view.isHidden = true }
            }
            if let scroll = view as? UIScrollView {
                scrollCount += 1
                if scroll.backgroundColor != UIColor.clear { scroll.backgroundColor = .clear }
                if scroll.isOpaque { scroll.isOpaque = false }
                if #available(iOS 26.0, *) {
                    if !scroll.topEdgeEffect.isHidden { scroll.topEdgeEffect.isHidden = true }
                    if !scroll.bottomEdgeEffect.isHidden { scroll.bottomEdgeEffect.isHidden = true }
                }
            }
            queue.append(contentsOf: view.subviews)
        }
        guard !Self.didLogScrollChrome else { return }
        Self.didLogScrollChrome = true
        writeDebugLog(
            "[\(NowPlayingLyricsPlate.logTag)] lyrics host — cleared \(scrollCount) scroll view(s)"
                + " (background clear / isOpaque off / scroll edge effects hidden)"
        )
    }

    private static var didLogScrollChrome = false

    func tick(seconds: TimeInterval?) {
        guard isAttached else { return }
        if let seconds { clock.submit(seconds: seconds) }
        projection.refresh()
    }

    // MARK: -逐词歌词改用**每帧时钟**

    var usingPerFrameClock = false

    /// 逐**词**高亮要每帧才顺：`tick(seconds:)` 若只由 `DeclutterChrome` 那条 **≈0.5s** 的复查
    /// 节拍驱动就只有 **2Hz**，肉眼一格一格跳（逐**行**看不出来 —— 行间本来有 SwiftUI 动画兜着）。
    ///
    /// 复用仓库既有的 `WordByWordPlaybackClock`（`CADisplayLink`），不新起定时器：
    /// ⚠️ 它的 `tickHandler` **只有一个槽**，旧 overlay 那条路（`LyricsWordByWord.x.swift`）
    /// 也在用 ⇒ **占不到就不抢**，退回节拍，绝不把别人的时钟顶掉。
    func usePerFrameClockIfAvailable() {
        guard !usingPerFrameClock else { return }
        let shared = WordByWordPlaybackClock.shared
        guard shared.tickHandler == nil else {
            writeDebugLog(
                "[\(NowPlayingLyricsPlate.logTag)] per-frame clock is taken by another overlay"
                    + " - word-by-word lyrics stay on the 0.5s review tick (choppier)"
            )
            return
        }
        shared.tickHandler = { @MainActor [weak self] ms in
            self?.tick(seconds: ms / 1000)
        }
        shared.start()
        usingPerFrameClock = true
        writeDebugLog("[\(NowPlayingLyricsPlate.logTag)] word-by-word lyrics are now driven per frame (shared CADisplayLink)")
    }

    /// 只停**我们自己**启动的那个时钟（`usingPerFrameClock` 就是这条账）。
    func releasePerFrameClock() {
        guard usingPerFrameClock else { return }
        usingPerFrameClock = false
        let shared = WordByWordPlaybackClock.shared
        shared.tickHandler = nil
        shared.stop()
    }

    func detach() {
        releasePerFrameClock()
        guard let hosting = hostingController else { return }
        hosting.view.removeFromSuperview()
        hostingController = nil
        renderedVersion = -1
        renderedTrackId = ""
    }
}
