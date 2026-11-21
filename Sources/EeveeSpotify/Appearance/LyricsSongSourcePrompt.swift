import Foundation
import UIKit
import ObjectiveC.runtime

/// 「这首歌不要再用这个歌词源」——**中间那颗 Connect 键（同心弧图标）的长按**，
/// 以及播放页 `⋯` 菜单表尾那一行，两个入口共用这一个弹窗。
///
/// 为什么挂在这颗键上：歌词键的长按已经是「时间轴偏移」、队列键的长按是「睡眠定时器」，
/// 三颗键各管一件事。这颗的短按是 Spotify 自己的输出切换（我们不改它），长按空着 ——
/// "这首的词根本不是这个源给的"正好占这个位置。
///
/// 为什么是弹窗而不是一整页：这件事只有一个决定（"这个源别再管这首歌了"）。设置页那张
/// 表负责**管理**（看已排除的歌、清空）；这里负责**当场修**，所以只给两三条动作。
enum LyricsSongSourcePrompt {

    struct Context {
        let trackId: String
        let source: LyricsSource
        let song: String
    }

    /// 当前这份歌词的（曲目、源、歌名）。
    ///
    /// 与 `LyricsOffsetMenuRow.currentContext()` 的区别：**不要求这一源能调偏移** ——
    /// Genius 这种纯文本源一样可以被排除，所以这里不套 `supportsOffset` 那道闸门。
    static func currentContext() -> Context? {
        let trackId = currentLyricsDtoTrackId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trackId.isEmpty, let source = currentLyricsSource else { return nil }

        let track = statefulPlayer?.currentTrack() ?? nowPlayingScrollViewController?.loadedTrack
        let title = track?.string(ifResponding: "trackTitle") ?? ""
        let artist = track?.string(ifResponding: "artistName")
            ?? track?.string(ifResponding: "artistTitle")
            ?? ""
        let song = [title, artist]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " — ")
        return Context(trackId: trackId, source: source, song: song)
    }

    /// 从**最上层**那个 VC 弹出来。
    ///
    /// 调用点可能在 sheet 里（`⋯` 菜单那一行）：先收掉菜单再弹，与偏移面板同一条路。
    static func present(afterDismissing dismissible: UIViewController? = nil) {
        guard let context = currentContext() else {
            writeDebugLog("[Lyrics] source prompt ignored — no lyrics loaded for this track yet")
            return
        }

        let show = {
            guard let window = EntityPageAppearance.frontWindow(),
                  var host = window.rootViewController else { return }
            while let presented = host.presentedViewController, !presented.isBeingDismissed {
                host = presented
            }

            let sheet = UIAlertController(
                title: "lyrics_source_menu_title".localized,
                message: "lyrics_source_menu_message".localizeWithFormat(context.source.description),
                preferredStyle: .actionSheet
            )

            sheet.addAction(
                UIAlertAction(
                    title: "lyrics_source_menu_exclude"
                        .localizeWithFormat(context.source.description),
                    style: .destructive
                ) { _ in
                    exclude(context)
                }
            )

            // 能调偏移的源才给这一项：Genius 的时间轴是推出来的，平移没有意义
            // （与设置页、`⋯` 菜单那两处同一条口径）。
            if LyricsTimingOffset.supportsOffset(source: context.source) {
                sheet.addAction(
                    UIAlertAction(title: "lyrics_offset_title".localized, style: .default) { _ in
                        LyricsOffsetPanel.present(
                            trackId: context.trackId,
                            source: context.source,
                            song: context.song
                        )
                    }
                )
            }

            sheet.addAction(UIAlertAction(title: "Cancel".localized, style: .cancel))

            // iPad / 弹出式：actionSheet 没有锚点会崩。
            if let popover = sheet.popoverPresentationController {
                popover.sourceView = host.view
                popover.sourceRect = CGRect(
                    x: host.view.bounds.midX,
                    y: host.view.bounds.maxY - 120,
                    width: 1,
                    height: 1
                )
                popover.permittedArrowDirections = []
            }
            host.present(sheet, animated: true)
            writeDebugLog(
                "[Lyrics] source prompt — \(context.trackId) via \(context.source.description)"
            )
        }

        guard let dismissible else {
            show()
            return
        }
        dismissible.dismiss(animated: true) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: show)
        }
    }

    // MARK: - 长按入口（挂在听歌页上）
    //
    // ⚠️ **不要改回"挂到某颗控件上"**。短按那条路是替身 `zones` 的真实触摸转发：
    // 这一下最终由 `hitTest` 链上的哪一层接住（原生 Connect 外面还包着 ViewHolder /
    // EncoreButton）不确定，挂在别处的识别器可能根本不在那条链上 —— 表现就是手势
    // 挂上了、却永远不识别。
    //
    // 现在挂**听歌页**（`placeFooter` 拿到的那个 `page`）：替身与原生键都是它的后代，
    // 任何一条转发路径都在它下面。识别之后按 `connectTapRect` 那一格判定，
    // 与"到底谁接住这一下"无关。

    /// 当前这一页的 Connect 槽位（页面坐标）。`nil` = 这一拍没有可长按的格子。
    fileprivate static var connectTapRect: CGRect?

    /// 每一拍刷新 Connect 槽位（页面坐标）。
    ///
    /// `placeFooter` 找不到工具行时传 `nil`：页面可能还活着，但那一格已经不在原位，
    /// 留着旧矩形就会长按在空处弹窗。
    static func setConnectTapRect(_ rect: CGRect?) {
        connectTapRect = rect
    }

    /// 给听歌页挂"长按 Connect 槽位 → 这个弹窗"。
    ///
    /// 幂等：同一页只挂一次（关联对象记着那枚手势）。页面重建（新的 `UIView`）会重新挂；
    /// 页面换了会把上一页那枚摘掉，别留在被回收的 cell 上。
    ///
    /// `cancelsTouchesInView` 保持 `true` —— 长按认出来之后，那一下点击不会再落到
    /// Spotify 自己的 Connect 动作上（不会"弹完窗又切设备"）。
    static func attachLongPress(to page: UIView, connectRect: CGRect?) {
        connectTapRect = connectRect
        guard let rect = connectRect else { return }
        if let previous = attachedPage, previous !== page {
            removePress(from: previous)
        }
        attachedPage = page
        guard objc_getAssociatedObject(page, &attachedKey) == nil else { return }
        let press = UILongPressGestureRecognizer(
            target: Target.shared,
            action: #selector(Target.connectLongPressed(_:))
        )
        press.minimumPressDuration = 0.45
        press.cancelsTouchesInView = true
        // 只在 Connect 那一格里起手才识别（`Target.gestureRecognizerShouldBegin`）：
        // 这道闸门必须收紧到**判决**这一步 —— 手势挂在整页上，若等识别完再按矩形过滤，
        // 页面上任何一处长按都会让 `cancelsTouchesInView` 生效，把歌词 / 队列两颗键
        // 以及列表的长按、拖动一起吃掉。
        press.delegate = Target.shared
        page.addGestureRecognizer(press)
        objc_setAssociatedObject(page, &attachedKey, press, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        writeDebugLog(
            "[Lyrics] long-press source prompt attached to the page — connect rect"
                + " \(Int(rect.minX)),\(Int(rect.minY))"
                + " \(Int(rect.width))×\(Int(rect.height)) (page coords)"
        )
    }

    /// 收尾：把页面上的长按手势摘掉，并清空槽位。
    ///
    /// 页面（cell）会被 Spotify 复用，留着一枚识别器就会在原位重新弹窗。
    /// 清空矩形之后，即便某条路径没走到这里（手势还挂着），也只是一次 no-op。
    static func detachLongPress() {
        connectTapRect = nil
        guard let page = attachedPage else { return }
        attachedPage = nil
        removePress(from: page)
    }

    /// 挂着手势的那一页（弱引用：页面走了自己掉）。
    private static weak var attachedPage: UIView?
    /// 关联对象的 key（存的是那枚 `UILongPressGestureRecognizer`，摘的时候要拿它）。
    private static var attachedKey: UInt8 = 0

    private static func removePress(from page: UIView) {
        let attached = objc_getAssociatedObject(page, &attachedKey)
        guard let press = attached as? UILongPressGestureRecognizer else { return }
        page.removeGestureRecognizer(press)
        objc_setAssociatedObject(page, &attachedKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    final class Target: NSObject, UIGestureRecognizerDelegate {
        static let shared = Target()

        /// 手指必须落在 Connect 槽位那一格里才识别（见 `attachLongPress` 里那段）。
        @objc func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            // 页面已经不在窗口里（收尾 / 复用中的 cell）⇒ 不识别。
            guard let page = recognizer.view, page.window != nil else { return false }
            guard let rect = LyricsSongSourcePrompt.connectTapRect else { return false }
            return rect.contains(recognizer.location(in: page))
        }

        @objc func connectLongPressed(_ recognizer: UILongPressGestureRecognizer) {
            guard recognizer.state == .began else { return }
            // 页面不在窗口里（收尾那一两拍）就不弹：复用中的 cell 上还有旧手势。
            guard let page = recognizer.view, page.window != nil else { return }
            guard let rect = LyricsSongSourcePrompt.connectTapRect,
                  rect.contains(recognizer.location(in: page)) else { return }
            writeDebugLog("[Lyrics] long press on the connect rect — source prompt")
            LyricsSongSourcePrompt.present()
        }
    }

    /// 把当前这个源加进"这首歌不用它"的表里，并让缓存失效。
    ///
    /// 只写排除表，不动全局的源顺序：为了这一首把全局顺序改了，其它歌会一起被改坏。
    private static func exclude(_ context: Context) {
        var sources = LyricsSongSourceExclusions.sources(forTrackId: context.trackId)
        guard sources.insert(context.source).inserted else {
            writeDebugLog(
                "[Lyrics] \(context.source.offsetStorageKey) is already excluded for \(context.trackId)"
            )
            return
        }
        LyricsSongSourceExclusions.setSources(
            sources,
            forTrackId: context.trackId,
            title: context.song
        )
        // 备忘录里可能还留着这个源刚产出的 payload：不清掉，60 秒内重听还是它。
        LyricsResponseCache.shared.reset()
        writeDebugLog(
            "[Lyrics] this song will skip \(context.source.offsetStorageKey) from now on"
                + " — \(context.trackId) (\(sources.count) source(s) excluded)"
        )
    }
}
