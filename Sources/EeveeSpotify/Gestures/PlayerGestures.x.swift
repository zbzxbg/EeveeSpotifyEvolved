import Foundation
import Orion
import UIKit
import ObjectiveC.runtime

/// 播放器双击手势。
///
/// 三个面**各自一个开关**（用户自己挑在哪儿生效），行为**一个选项**（切歌 / 前后跳 15 秒）。
/// 所有动作都复用仓库里既有的原语，不另造一套播放控制：
///   · 切歌 → `WordByWordPlaybackControl.skipToPrevious()/skipToNext()`
///     （它已经处理了"statefulPlayer 选择器找不到就点原生按钮"两条路）
///   · 跳转 → `SponsorBlockSkipper.shared.currentPlayhead()` 取当前位置 +
///     `seekTo(seconds:)` 落点
///
/// 面与运行期类名（全部来自真机转储与 `dump-9.1.86.txt`）：
///   正在播放页（大封面那页） `_TtC21NowPlaying_ScrollImpl23NPVScrollViewController`
///   全屏歌词页               `_TtC32Lyrics_FullscreenElementPageImpl31FullscreenElementViewController`
///                          + `_TtC34Lyrics_FullscreenSingalongPageImpl31FullscreenElementViewController`
///   迷你播放条（标签栏上方）  `_TtC22NowPlaying_BarPageImplP33_…TouchPassthroughView`
///     （不用 `NowPlayingBarTopStack`：它只有 8pt 高，做点击目标太小）
///
/// ⚠️ 手势挂在**别人的视图**上，两条纪律：
///   1. `cancelsTouchesInView = false` —— 不抢 Spotify 自己的点击/滑动（进度条拖动照常）；
///   2. 开关关掉要能**摘掉**手势（把 recognizer 存在关联对象里），否则关一次开关
///      双击就一直生效到重启。
enum PlayerGestureBehavior: Int {
    case skip = 0
    case seek = 1

    var localizedKey: String {
        switch self {
        case .skip: return "gesture_behavior_skip"
        case .seek: return "gesture_behavior_seek"
        }
    }
}

private var playerGestureRecognizerKey: UInt8 = 0

enum PlayerGestures {

    /// 前后跳的秒数。spoti.pw 那边也是 15s，跟它的默认对齐。
    static let seekStep: Double = 15

    static var behavior: PlayerGestureBehavior {
        PlayerGestureBehavior(rawValue: UserDefaults.playerGestureBehavior) ?? .skip
    }

    /// 幂等：开关开着就确保有手势，关着就确保没有。
    static func apply(wantEnabled: Bool, to view: UIView, surface: String) {
        let existing = objc_getAssociatedObject(view, &playerGestureRecognizerKey) as? UITapGestureRecognizer

        if wantEnabled {
            guard existing == nil else { return }

            let tap = UITapGestureRecognizer(
                target: PlayerGestureTapHandler.shared,
                action: #selector(PlayerGestureTapHandler.handleTap(_:))
            )
            tap.numberOfTapsRequired = 2
            // 不抢 Spotify 自己的点击与滑动（进度条拖动必须照常）。
            tap.cancelsTouchesInView = false

            view.addGestureRecognizer(tap)
            objc_setAssociatedObject(
                view,
                &playerGestureRecognizerKey,
                tap,
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
            writeDebugLog("[Gestures] attached on \(surface)")
            return
        }

        guard let recognizer = existing else { return }

        view.removeGestureRecognizer(recognizer)
        objc_setAssociatedObject(view, &playerGestureRecognizerKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        writeDebugLog("[Gestures] detached on \(surface)")
    }
}

/// 双击的处理者。
///
/// 单例 `NSObject`：`UITapGestureRecognizer` 的 target 必须是 ObjC 对象，
/// 而 `PlayerGestures` 是 enum（不能当 target）。`@objc` 方法在 NSObject 子类上合法。
final class PlayerGestureTapHandler: NSObject {

    static let shared = PlayerGestureTapHandler()

    @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard let view = recognizer.view else { return }

        let isLeftHalf = recognizer.location(in: view).x < view.bounds.midX
        let behavior = PlayerGestures.behavior

        switch behavior {
        case .skip:
            if isLeftHalf {
                writeDebugLog("[Gestures] double tap left → previous")
                WordByWordPlaybackControl.skipToPrevious()
            } else {
                writeDebugLog("[Gestures] double tap right → next")
                WordByWordPlaybackControl.skipToNext()
            }

        case .seek:
            let current = SponsorBlockSkipper.shared.currentPlayhead().position
            let target = isLeftHalf ? current - PlayerGestures.seekStep : current + PlayerGestures.seekStep

            writeDebugLog(
                String(
                    format: "[Gestures] double tap %@ → seek %.0fs (from %.0fs)",
                    isLeftHalf ? "left" : "right", target, current
                )
            )
            SponsorBlockSkipper.shared.seekTo(seconds: target)
        }
    }
}

// MARK: - 三个面

struct GestureNowPlayingGroup: HookGroup {}
struct GestureFullscreenLyricsGroup: HookGroup {}
struct GestureMiniBarGroup: HookGroup {}

/// 正在播放页（大封面那页）。
class NowPlayingGestureHook: ClassHook<UIViewController> {
    typealias Group = GestureNowPlayingGroup
    static let targetName = "_TtC21NowPlaying_ScrollImpl23NPVScrollViewController"

    func viewDidAppear(_ animated: Bool) {
        orig.viewDidAppear(animated)

        PlayerGestures.apply(
            wantEnabled: UserDefaults.playerGestureNowPlaying,
            to: self.target.view,
            surface: "now playing page"
        )
    }
}

/// 全屏歌词页（两个变体都挂）。
class FullscreenLyricsGestureHook: ClassHook<UIViewController> {
    typealias Group = GestureFullscreenLyricsGroup
    static let targetName = "_TtC32Lyrics_FullscreenElementPageImpl31FullscreenElementViewController"

    func viewDidAppear(_ animated: Bool) {
        orig.viewDidAppear(animated)

        PlayerGestures.apply(
            wantEnabled: UserDefaults.playerGestureFullscreenLyrics,
            to: self.target.view,
            surface: "full screen lyrics"
        )
    }
}

class SingalongFullscreenLyricsGestureHook: ClassHook<UIViewController> {
    typealias Group = GestureFullscreenLyricsGroup
    static let targetName = "_TtC34Lyrics_FullscreenSingalongPageImpl31FullscreenElementViewController"

    func viewDidAppear(_ animated: Bool) {
        orig.viewDidAppear(animated)

        PlayerGestures.apply(
            wantEnabled: UserDefaults.playerGestureFullscreenLyrics,
            to: self.target.view,
            surface: "full screen singalong lyrics"
        )
    }
}

/// 迷你播放条（标签栏上方那条，414x64）。
class MiniBarGestureHook: ClassHook<UIView> {
    typealias Group = GestureMiniBarGroup
    static let targetName =
        "_TtC22NowPlaying_BarPageImplP33_CCC0D2EEA6D4725EECD8965E8C38C86D20TouchPassthroughView"

    func layoutSubviews() {
        orig.layoutSubviews()

        PlayerGestures.apply(
            wantEnabled: UserDefaults.playerGestureMiniBar,
            to: self.target,
            surface: "mini player bar"
        )
    }
}

func activatePlayerGestures() {
    // 和别处一样：类不在就不装，并打一行日志说明，不留给 Orion 报非致命错误。
    if NSClassFromString(NowPlayingGestureHook.targetName) != nil {
        GestureNowPlayingGroup().activate()
    } else {
        writeDebugLog("[Gestures] missing \(NowPlayingGestureHook.targetName) — now playing hook inactive")
    }

    let lyricsTargets = [
        FullscreenLyricsGestureHook.targetName,
        SingalongFullscreenLyricsGestureHook.targetName,
    ]
    if lyricsTargets.contains(where: { NSClassFromString($0) != nil }) {
        GestureFullscreenLyricsGroup().activate()
    } else {
        writeDebugLog("[Gestures] missing full screen lyrics classes — those hooks inactive")
    }

    if NSClassFromString(MiniBarGestureHook.targetName) != nil {
        GestureMiniBarGroup().activate()
    } else {
        writeDebugLog("[Gestures] missing \(MiniBarGestureHook.targetName) — mini bar hook inactive")
    }

    writeDebugLog(
        "[Gestures] installed (nowPlaying="
            + "\(UserDefaults.playerGestureNowPlaying ? "ON" : "OFF")"
            + " fullscreenLyrics=\(UserDefaults.playerGestureFullscreenLyrics ? "ON" : "OFF")"
            + " miniBar=\(UserDefaults.playerGestureMiniBar ? "ON" : "OFF")"
            + " behavior=\(PlayerGestures.behavior == .skip ? "skip" : "seek"))"
    )
}
