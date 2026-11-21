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

    /// 给某颗控件挂"长按 → 这个弹窗"。
    ///
    /// 幂等：页脚每次布局都会调到，同一颗控件只挂一次。`cancelsTouchesInView` 用默认的
    /// `true` —— 长按认出来之后，那一下点击就不会再落到 Spotify 自己的 Connect 动作上。
    static func attachLongPress(to control: UIView) {
        guard objc_getAssociatedObject(control, &attachedKey) == nil else { return }
        objc_setAssociatedObject(control, &attachedKey, true, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        let press = UILongPressGestureRecognizer(
            target: Target.shared,
            action: #selector(Target.longPressed(_:))
        )
        press.minimumPressDuration = 0.45
        control.addGestureRecognizer(press)
        writeDebugLog(
            "[Lyrics] long-press source prompt attached — \(NSStringFromClass(type(of: control)))"
        )
    }

    private static var attachedKey: UInt8 = 0

    final class Target: NSObject {
        static let shared = Target()

        @objc func longPressed(_ recognizer: UILongPressGestureRecognizer) {
            guard recognizer.state == .began else { return }
            writeDebugLog("[Lyrics] long press on the connect key — source prompt")
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
