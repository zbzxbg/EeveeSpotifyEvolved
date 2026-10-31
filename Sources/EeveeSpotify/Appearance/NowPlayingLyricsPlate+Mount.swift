// 「歌词进播放器」——铺到页面上（layoutAndMount）与整体收起（closeEverything / settleAfterClosing）。
// 从 `NowPlayingLyricsPlate.swift` 原样拆出（`NowPlayingLyricsPlate` 的 extension）；
// 形状、动画与硬约束见那个文件的头注。
import Foundation
import SwiftUI
import UIKit
import Orion
import ObjectiveC.runtime

@MainActor
extension NowPlayingLyricsPlate {
    // MARK: - 开关与几何
    //
    // 进场：把封面缩成缩略图、标题行上移贴边、歌词淡入到"标题之下、进度条之上"。
    //
    // **返回这一拍到底铺上了没有**。铺不上就**不认"已展开"**（`isOpen` 由调用方回退）——
    // 否则会出现那种"标题已经上移、歌词已经画出来、而原生封面还整张露着"的半成品。
    @discardableResult
    static func layoutAndMount(in page: UIView) -> Bool {
        guard #available(iOS 26.0, *) else { return false }

        // `measure` 从"返回 `Geometry?`"改成"返回带原因的两种结局"。
        //
        // 为什么必须改：旧写法把**四种完全不同的失败**压成同一句话
        // （`cannot measure the artwork area / title row (layout not finished yet?)`），
        // 还是标题行没量到、还是歌词区太矮、还是"标题行已经在缩略图线上方"。
        // 仓库规矩是「静默分支不许静默」，这里是它的变体：**一个分支不许盖住四种死法**。
        let geometry: Geometry
        switch measure(in: page) {
        case .ok(let measured):
            geometry = measured
        case .failed(let reason):
            noteSkip(reason)
            return false
        }

        // ⚠️ 把"这一首有没有得画"这道门**提到所有副作用之前**：它只读歌词模型与播放器状态，
        // **不碰任何视图**；而下面 ①②③ 全是**副作用**（藏掉 Spotify 那条封面、位移标题行、建容器）
        // ⇒ 顺序反了，那一步一失败就会留下"封面藏了、标题移了、而 `isOpen` 还是 false"的半成品
        // （只能等离页时 `closeEverything` 去收）；加了重试窗口之后这条路径一晚会走好几回，更要紧。
        // 判据是"要么有行，要么有一句可说的事"：**没有歌词可画时不再"点了没反应"** ——
        // 键照样能开，打开之后在歌词的位置居中写一句说明（`noticeText`）。
        let notice = noticeText()
        guard let trackId = currentTrackId() else {
            noteSkip("no track id yet (the player has not reported one)")
            return false
        }
        let timedLines = currentLines() ?? []
        // （歌词呢+「不是复用有时间轴的逻辑吗」）：
        // **没有时间轴**那一档不再自己画——把文本包成**合成行**（时间全 0、无音节）
        // 交给**同一个渲染层**，由 `isStatic` 告诉它"不高亮、不跟随、点行不跳"。
        // 这样字号 / 行距 / 左右内边距 / 滚动 / 底部留白（120pt，正好躲开控件条）全部同一套。
        let staticTexts = currentUntimedLines()
        let isStatic = timedLines.isEmpty && staticTexts != nil
        let lines = isStatic ? Self.staticLines(from: staticTexts ?? []) : timedLines
        if lines.isEmpty, notice == nil {
            noteSkip("no lyric lines to draw right now (the line model is not ready)")
            return false
        }

        // ① 我们自己那份封面（同一张图，所以"换"看不出来）+ **把它动画到缩略图**。
        // ⚠️ **它必须成功**：失败时原生封面就还露着，而下面两步会照样跑
        // ⇒ 歌词与上移后的标题会被画在封面图上。所以这里直接不展开。
        // pw 也是这个取舍：*"without a picture there would be a hole where the cover was,
        // so the cover stays and the lyrics wait."*
        guard let coverHostView = ensureCover(in: page, geometry: geometry),
              let coverImageView = coverImage else {
            // ⚠️ 这行原来是中文 + **ASCII 双引号**做强调（`与"藏起原生封面"都做不了`），
            // 字面量被那两个引号提前截断 ⇒ CI 报 `expected ',' separator` /
            // `cannot find '藏起原生封面' in scope` / `extra argument in call`。
            // **日志文案一律用英文**（定下的规矩），中文强调改用「」也不会再踩这个坑。
            noteSkip("no artwork for this track (cannot build the thumbnail or hide Spotify's cover) - not opening")
            return false
        }
        applyCoverState(open: true, host: coverHostView, imageView: coverImageView, geometry: geometry)

        // ② 标题行上移 + 右移（transform —— 改约束会被 stack view 布局写回）。
        applyTitleTransform(geometry: geometry, page: page)

        // ②b（用户）：**歌手右边写上歌词提供商**——`歌手（提供商）`。
        // 只在这条"展开"的路上贴；收起时由 `settleAfterClosing` 还原。
        applyProviderToArtistLine(in: page)

        // ③ 歌词区：标题之下、进度条之上。
        //
        // 「把滚动歌词的下部分抬高，确保歌词不会穿过这个上传者什么的」
        // —— 底部先为**底沿那行署名**让出 `stageBottomReserve`（≈62pt，见那几个常量）。
        // 不让的话最后几行会从署名底下穿过去：罗马字与日文那两行正好压在
        // "Spicy Lyrics" 上。收窄容器（而不是只加内部留白）的好处是**底部渐隐带**
        // 也跟着上移，于是"最后一行淡出"和"署名"不会落在同一块区域里。
        var frame = geometry.stage
        frame.size.height = max(0, frame.size.height - Self.stageBottomReserve(for: geometry.stage))
        guard frame.height > livingHeight / 2 else {
            noteSkip("no room between the title and the progress bar (\(Int(frame.height))pt)")
            return false
        }

        let container = ensureContainer(in: page, frame: frame)
        // 容器是共用的；页内歌词那一档会把它从 alpha 0 淡进来，
        // 老布局这一档（"歌词进播放器"）必须立即是不透明的。
        container.alpha = 1
        applyEdgeFade(to: container)
        // 歌词区**底沿**那条可点署名（Spicy Lyrics 条款 §6）。必须在
        // `ensureContainer` 之后 —— 它要把自己 `bringSubviewToFront` 到容器上面才点得到。
        ensureCreditLabel(in: page, lyricsFrame: frame)
        // 说明文案写在这一块**正中间**（写歌词的正中间最好）。
        applyNoticeLabel(notice, in: container)

        if let host = currentHost(for: page) {
            let version = currentLyricsVersion
            if host.isCurrent(version: version, trackId: trackId, isStatic: isStatic) {
                // 最新 → 这一拍只驱动时间轴。
            } else if host.isAttached {
                host.updateLines(lines, version: version, trackId: trackId, isStatic: isStatic)
            } else {
                host.mount(
                    in: container,
                    lines: lines,
                    version: version,
                    trackId: trackId,
                    isStatic: isStatic,
                    onSeek: { seconds in
                        // （我选中某一行歌词，定位到上一行歌词去了）：
                        // 这里以前是**另写的一份** `Int((seconds * 1000).rounded)` ——
                        // 少了那 5ms ⇒ 落在行边界上 ⇒ 被判成上一行。
                        // 现在两处都走 `seekToTappedLyricLine`（定义在
                        // `AppleMusicLyricsOverlay.swift` 开头，理由都写在那儿）。
                        seekToTappedLyricLine(seconds)
                    }
                )
            }
            host.tick(seconds: WordByWordPositionResolver.shared.currentPositionSeconds())
            // 逐词歌词改用**每帧**驱动（原来只有那条 0.5s 的复查节拍 ⇒ 2Hz ⇒ 一格一格跳）。
            // 占不到共享时钟就不抢，退回节拍（有日志）。
            host.usePerFrameClockIfAvailable()
        }

        if !didLogInstall {
            didLogInstall = true
            // ⚠️ 不要用嵌套的双引号字面量（`\(a ? "x" : "y")` 那种）—— 本仓库第 6 条自检
            // `swift_string_check.py` 是按"闭合引号后面跟了什么字符"扫的，嵌套字面量会被它
            // 当成"字符串被提前关掉"那次 CI 红就是这么来的）。先算成变量再插。
            let titleNote: String
            if geometry.titleRow == nil {
                titleNote = "not found (no lift, expanding anyway)"
            } else {
                titleNote = "lifted \(Int(geometry.lift))pt / shifted \(Int(geometry.shift))pt"
            }
            let staticNote: String
            if isStatic {
                staticNote = " static lyrics \(lines.count) line(s) (this track has no timeline;"
                    + " same renderer, static mode)"
            } else {
                staticNote = ""
            }
            // （把罗马字和歌词翻译接上去吧）：这两档各写了多少行也打进日志 ——
            // 否则下一次又是"接了没生效、不知道卡在哪"（译文要过设置那道门、罗马字要过语言那道门）。
            let translationCount = lines.filter { $0.translation?.isEmpty == false }.count
            let romanizationCount = lines.filter { $0.romanization?.isEmpty == false }.count
            let supplementalNote = " translation \(translationCount)/\(lines.count)"
                + " romanization \(romanizationCount)/\(lines.count)"
            writeDebugLog(
                "[\(logTag)] expanded — thumbnail \(Int(geometry.thumb.width))pt at \(frameText(geometry.thumb)), "
                    + "lyrics area \(frameText(frame)), cover shrunk in from \(frameText(geometry.cover)), "
                    + "title row \(titleNote)"
                    + staticNote
                    + supplementalNote
                    // 三个锚点的**实测值**（`measure` 里算的，这里只管打印）——
                    // →68 那两片几何全靠它对齐，下一份日志一眼就能看出量到没有。
                    + " " + lastAnchorText
            )
        }
        return true
    }

    /// （点击歌词之后……只想要封面/歌名/艺人动，按钮别改）：
    /// iOS 27 听歌页专用 —— **只铺歌词**，不碰封面、不碰标题、不加自己的键、不动控件条。
    /// 容器/宿主/滚动/逐词时钟都复用这一层现成的东西；位置由调用方给。
    @discardableResult
    static func mountLyricsOnly(in page: UIView, frame: CGRect) -> Bool {
        guard #available(iOS 26.0, *) else { return false }
        let notice = noticeText()
        guard let trackId = currentTrackId() else { return false }
        let timedLines = currentLines() ?? []
        let staticTexts = currentUntimedLines()
        let isStatic = timedLines.isEmpty && staticTexts != nil
        let lines = isStatic ? staticLines(from: staticTexts ?? []) : timedLines
        if lines.isEmpty, notice == nil { return false }

        let container = ensureContainer(in: page, frame: frame)
        // 容器是复用的，底色必须是透明（下面铺的是我们自己的 field，不是黑卡片）；
        // 每次挂都重申一次，防止上一程留下的状态。
        container.backgroundColor = .clear
        container.layer.backgroundColor = UIColor.clear.cgColor
        container.isOpaque = false
        if lyricsOnlyNeedsFadeIn { container.alpha = 0 }
        applyEdgeFade(to: container)
        applyNoticeLabel(notice, in: container)

        guard let host = currentHost(for: page) else { return false }
        let version = currentLyricsVersion
        if host.isCurrent(version: version, trackId: trackId, isStatic: isStatic) {
            // 最新：只驱动时间轴。
        } else if host.isAttached {
            host.updateLines(lines, version: version, trackId: trackId, isStatic: isStatic)
        } else {
            host.mount(
                in: container,
                lines: lines,
                version: version,
                trackId: trackId,
                isStatic: isStatic,
                onSeek: { seconds in seekToTappedLyricLine(seconds) }
            )
        }
        host.tick(seconds: WordByWordPositionResolver.shared.currentPositionSeconds())
        host.usePerFrameClockIfAvailable()

        // **第一帧不直接亮出来**。
        //
        // 黑底不是我们画的（容器/宿主都是 clear）—— 是 `UIHostingController` 刚挂上、
        // SwiftUI 还没画完内容那一帧的底色。打开时从 0 淡进来，0.22s 就把那一帧盖住了；
        // 同一程后面的每拍重铺（alpha 已经是 1）不会再闪。
        if lyricsOnlyNeedsFadeIn {
            lyricsOnlyNeedsFadeIn = false
            lyricsOnlyFadeGeneration += 1
            let generation = lyricsOnlyFadeGeneration
            let delay = max(0, lyricsOnlyFadeInDelay)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                // 这一程已经收起 / 重挂了 ⇒ 这次淡入作废（否则会把正在淡出的容器又点亮）。
                guard generation == NowPlayingLyricsPlate.lyricsOnlyFadeGeneration,
                      container.superview != nil else { return }
                UIView.animate(
                    withDuration: 0.18,
                    delay: 0,
                    options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction]
                ) {
                    container.alpha = 1
                }
            }
        }
        return true
    }

    /// 关歌词的第一段：**只把容器淡出到 0**，拆容器由调用方在动画结束后做。
    ///
    /// （从歌词页面到全溶封面的过渡不是很好）：
    /// 原来收起歌词的第一帧就 `unmountLyricsOnly`（`removeFromSuperview`）——
    /// 歌词一帧消失，而封面还要长 0.36s，中间那块直接空掉，看着就是"闪没"。
    /// 现在它和封面长回去共用 0.30s 淡出；调用方按 `lyricsModeGeneration`
    /// 决定动画结束后还要不要拆（快速重开时这次拆作废）。
    static func fadeOutLyricsOnly(duration: TimeInterval, completion: @escaping () -> Void) {
        // 作废"挂上之后延迟淡入"那一次回调：现在要淡出，不是淡入。
        lyricsOnlyFadeGeneration += 1
        guard let container = lastContainer, container.superview != nil else {
            completion()
            return
        }
        UIView.animate(
            withDuration: duration,
            delay: 0,
            options: [.curveEaseInOut, .beginFromCurrentState, .allowUserInteraction]
        ) {
            container.alpha = 0
        } completion: { _ in
            completion()
        }
    }

    /// 收掉 `mountLyricsOnly` 铺的东西（不碰任何原生视图、不动 `door`）。
    static func unmountLyricsOnly() {
        lyricsOnlyFadeGeneration += 1
        // ⚠️ `NowPlayingLyricsHost` 本身是 `@available(iOS 26.0, *)`；本文件所在的
        // extension 没有整体标可用性，所以这里必须自己在 `#available` 里做那次 cast
        // （CI 报的就是这一句：`'NowPlayingLyricsHost' is only available in iOS 26.0 or newer`）。
        if #available(iOS 26.0, *) {
            (host as? NowPlayingLyricsHost)?.detach()
        }
        lastContainer?.removeFromSuperview()
        lastContainer = nil
        // 下一次打开重新淡入。
        lyricsOnlyNeedsFadeIn = true
    }

    /// 全部还原：封面动画回原位后拿走、标题位移撤销、我们自己的层拿走。
    ///
    /// - Parameter animated: 收起封面时**要不要放动画**。
    /// `toggle`（用户再点一下）= `true`，会看到封面"飞回原位"；
    /// **切开关 / 页面消失 = `false`** —— 那两种情况下页面可能马上就不在了，
    /// 拖着 0.45s 的动画才把 Spotify 那条封面写回去，会在转场里露一个"没有封面"的帧。
    static func closeEverything(reason: String, animated: Bool) {
        // ⚠️ 这三行必须在那个 `guard` **之前**：重试窗口要在"关掉 / 离开页面"时**无条件**清掉，
        // 否则页面都走了它还挂着一个 deadline（虽然 `page.window` 会挡住，但账要算清）。
        let hadSomethingVisible = door.isOpen || isAnythingLive
        // 五个旗标**一次归位**（少清一项就会在下一程留残迹，`Tests/LyricsDoor` 有一条逐项断言）。
        door.close()
        // 这一程结束了 ⇒ 树也马上要换 / 已经换了，缓存整块作废（下次真查一遍）。
        invalidateNodeLookups()
        // ⚠️ "关着的样子"（控件条 + 标题行贴左上角）**必须最后摆**：这个函数中段还有撤销展开位移
        // 的那一句（`lastUnit?.transform = .identity`），它会把刚摆好的"标题去左上角"**当场撤销**
        // ⇒ 关掉之后那 0.3s 里标题回到**原生位置**（618），正好压在控件条第 ① 处的分享键（58,626）上。
        // 所以用 `defer`：无论从哪条路返回（含"没铺过东西"的提前 return）都在**最后**执行一次，
        // 而且它自己会判断"页面还在不在"，见 `settleAfterClosing`。
        defer { settleAfterClosing() }
        // 封面判据的日志预算**按"一次开合"重置** —— 否则开合三次就把 12 行用光，
        // 正好在下一个 bug 出现时看不见了（独立复核指出）。
        chosenCoverLogs = 0
        lastLoggedCover = nil
        guard hadSomethingVisible else { return }

        // 封面：先让它**动回原位**（同图，所以这就是"飞回去"），动画走完再撤 + 把 Spotify 那条写回。
        if let host = coverHost, let imageView = coverImage {
            let token = door.nextCoverGeneration()

            let cleanup = {
                // ⚠️ 收尾里要碰 `@MainActor` 的静态成员 ⇒ 走 `onMainThreadSync`（仓库成文规矩）。
                onMainThreadSync {
                    // 这中间用户又点开了 ⇒ 这一次的收尾作废（别把刚摆好的封面撤掉）。
                    guard token == door.coverGeneration else { return }
                    host.removeFromSuperview()
                    coverHost = nil
                    coverImage = nil
                    restoreSpotifyCover()
                }
            }

            if animated {
                applyCoverState(
                    open: false,
                    host: host,
                    imageView: imageView,
                    geometry: nil,
                    completion: cleanup
                )
            } else {
                host.layer.removeAllAnimations()
                host.transform = .identity
                imageView.layer.cornerRadius = coverFullRadius
                cleanup()
            }
        } else {
            restoreSpotifyCover()
        }

        // 标题行的位移**不在这里撤** —— 见 `settleAfterClosing`：
        // 页面还在时要让那一行**从缩略图右边滑回左上角**（用户要的动画），
        // 先在这儿撤成 identity 就会先跳一下。
        clearTitleMask()
        lastTitleElement = nil

        if #available(iOS 26.0, *) {
            (host as? NowPlayingLyricsHost)?.detach()
        }
        lastContainer?.removeFromSuperview()
        lastContainer = nil
        // 署名跟着歌词一起收（它只在展开态出现，见 `ensureCreditLabel`）。
        removeCreditLabel()
        didLogInstall = false
        writeDebugLog("[\(logTag)] collapsed (reason=\(reason))")
    }

    /// `closeEverything` 的最后一步（`defer` 里跑）：决定"关掉之后屏幕上是哪一副样子"。
    ///
    /// 两种结局：
    /// · **页面还在窗口里**（功能也开着）⇒ 摆"关着的样子"：控件条就位、标题行回左上角。
    /// 这里**故意不先撤**展开时那段位移 —— 让那一行直接从"缩略图右边"滑过去；先撤成
    /// `identity` 就会先跳回原生位置、再被下一拍挪走（那 0.3s 的重合就是这么来的）。
    /// · **页面不在 / 功能关了** ⇒ 把写在别人视图上的两段位移**全部撤掉**。
    static func settleAfterClosing() {
        // **「（提供商）」跟着页面走**，不再跟着"展开 / 收起"走。
        //
        // 歌词提供商并没有在歌手的后面展示，并选了
        // **"展开和收起都显示"** ⇒ 这一段以前那句无条件 `restoreArtistLine` 就是反的：
        // 它把收起态（也就是用户平时看到的那一屏）的提供商摘掉了。
        // 现在只在**页面要走 / 功能关了**时摘；页面还在就留着，下面那段会把它摆回去。
        let pageStays = isEnabled && (lastPage?.window != nil)
        if !pageStays, let page = lastPage {
            restoreArtistLine(in: page)
        }

        if pageStays, let page = lastPage {
            applyControlBand(in: page)
            applyProviderToArtistLine(in: page)
            if applyClosedTitleTransform(in: page) {
                lastUnit = nil
                lastTitleElement = nil
                return
            }
        }
        // 兜底：摆不上（量不到导航条 / 找不到那一行）或页面已经不在 ⇒ 把两段位移都撤掉，
        // 别留在别人的视图上（"关着态"那两段由 `clearClosedTitleTransform` 管）。
        if let row = lastUnit, row.transform != .identity { row.transform = .identity }
        if let element = lastTitleElement, element.transform != .identity {
            element.transform = .identity
        }
        lastUnit = nil
        lastTitleElement = nil
        clearClosedTitleTransform()
    }
}
