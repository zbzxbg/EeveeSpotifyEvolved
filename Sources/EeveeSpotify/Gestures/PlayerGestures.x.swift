import Foundation
import Orion
import UIKit
import ObjectiveC.runtime

/// 播放器双击手势。
///
/// **两个面各自一个开关**（用户自己挑在哪儿生效），行为**一个选项**（切歌 / 前后跳 15 秒）。
/// 所有动作都复用仓库里既有的原语，不另造一套播放控制：
///   · 切歌 → `WordByWordPlaybackControl.skipToPrevious()/skipToNext()`
///     （它已经处理了"statefulPlayer 选择器找不到就点原生按钮"两条路）
///   · 跳转 → `WordByWordPositionResolver.shared.currentPositionSeconds()` 取当前位置 +
///     `WordByWordSeeker.seek(toMs:)` 落点
///
/// ⚠️ 跳转**原来**用的是 `SponsorBlockSkipper.shared.currentPlayhead()` + `seekTo(seconds:)`，
/// 2026-10-01 的日志 8 证明那条路走不通，用户反馈"十五秒手势不生效"：
///   · 它依赖 SB 的播放器观察者，而观察者的目标类 `SPTPlayerServiceImplementation` 在 9.1.86 上
///     **不存在**（日志 8：`[SB] activate: … class=<missing>`）→ `lastPlayer` 永远是 nil，
///     `seekTo` 里 `guard let player = lastPlayer else { return }` **静默返回**；
///   · 它还被 `options.enabled` 挡着（SB 默认关）。
/// 换成上面那两条原语后，同一份日志已经给出反证：`[WordByWord] position source:
/// statefulPlayer.position() -> Double` 与 `[WordByWord] seek to 0ms` 都真的跑通了。
///
/// 面与运行期类名（全部来自真机转储与 `dump-9.1.86.txt`）：
///   正在播放页（大封面那页） `_TtC21NowPlaying_ScrollImpl23NPVScrollViewController`
///   全屏歌词页               `_TtC32Lyrics_FullscreenElementPageImpl31FullscreenElementViewController`
///                          + `_TtC34Lyrics_FullscreenSingalongPageImpl31FullscreenElementViewController`
///
/// ⚠️ **迷你播放条那一面已删除**（2026-10-01，用户要求）。
/// 原来挂的是 `_TtC22NowPlaying_BarPageImplP33_CCC0D2EEA6D4725EECD8965E8C38C86D20TouchPassthroughView`
/// （414x64，标签栏正上方）。删的是**整个面**：hook、设置行、`playerGestureMiniBar` 键一起删，
/// 不留一个按了没反应的设置项。
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
            reportDiagnosticOnce(for: view, surface: surface)
            return
        }

        guard let recognizer = existing else { return }

        view.removeGestureRecognizer(recognizer)
        objc_setAssociatedObject(view, &playerGestureRecognizerKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        writeDebugLog("[Gestures] detached on \(surface)")
    }

    /// 诊断只报一次（每个面一次）。
    private static var reportedSurfaces: Set<String> = []

    /// ★ 诊断（一次性）：**双击的第一下会不会漏给 Spotify 自己的单击**。
    ///
    /// 依据：pw v0.21.1（GPL-3.0）`Shared/Gestures/Gestures.x` 写明 —— Spotify 自己的单击
    /// （封面进 3D 倾斜 / 滚到下面卡片）**会在双击的第一下就触发**；它的解法是把 host
    /// **及其所有上层**的单击手势都挂上 `requireGestureRecognizerToFail:`，而且因为
    /// "Spotify 是后加手势的、顺序不受我们控制"，还要在每次布局时按计数**重挂一遍**。
    /// 我们这一版**没有**那一步，所以这里先把事实打出来：
    ///
    ///   · `singleTapsAbove` = host 及其上层一共挂着几个**单击**手势；
    ///   · **0 就说明不存在"漏"这回事**（例如全屏歌词页可能就没有）⇒ 不值得为它花一轮；
    ///   · \> 0 就说明 pw 那条坑在我们这儿是**活的**。
    ///
    /// ⚠️ 刻意**不去查**"有没有已经让位"：`requireGestureRecognizerToFail` 没有公开的
    /// 查询 API，绕路去读 `gestureRecognizers` 得赌它的语义 —— 而我们本来就没调用过，
    /// 结论是恒定的（没让位）。探针要的是**便宜且不赌**。
    private static func reportDiagnosticOnce(for view: UIView, surface: String) {
        guard !reportedSurfaces.contains(surface) else { return }
        reportedSurfaces.insert(surface)

        var singleTaps = 0
        var node: UIView? = view
        var hops = 0
        while let current = node, hops < 12 {
            for other in current.gestureRecognizers ?? [] {
                guard let tap = other as? UITapGestureRecognizer else { continue }
                if tap.numberOfTapsRequired == 1 { singleTaps += 1 }
            }
            node = current.superview
            hops += 1
        }

        let verdict = singleTaps > 0
            ? " — ⚠️ 双击的第一下会漏给它们（pw 用 requireGestureRecognizerToFail 挡）"
            : " — 上层没有单击手势，不存在「漏一下」的问题"
        writeDebugLog(
            "[Gestures] diag surface=\(surface) host=\(type(of: view))"
                + " singleTapsAbove=\(singleTaps)" + verdict
        )
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
            // 位置来自 `statefulPlayer.position()`（日志 8 已证明可用）；读不到就**不装**，
            // 并打一行说明 —— 原来的写法会打出一行"看起来在跳"的日志然后什么都没发生。
            guard let current = WordByWordPositionResolver.shared.currentPositionSeconds() else {
                writeDebugLog("[Gestures] seek skipped — no position source (statefulPlayer.position() unresolved)")
                return
            }

            let target = max(0, isLeftHalf ? current - PlayerGestures.seekStep : current + PlayerGestures.seekStep)

            writeDebugLog(
                String(
                    format: "[Gestures] double tap %@ → seek %.0fs (from %.0fs)",
                    isLeftHalf ? "left" : "right", target, current
                )
            )
            WordByWordSeeker.seek(toMs: Int(target * 1000))
        }
    }
}

// MARK: - 两个面

struct GestureNowPlayingGroup: HookGroup {}
struct GestureFullscreenLyricsGroup: HookGroup {}

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

    writeDebugLog(
        "[Gestures] installed (nowPlaying="
            + "\(UserDefaults.playerGestureNowPlaying ? "ON" : "OFF")"
            + " fullscreenLyrics=\(UserDefaults.playerGestureFullscreenLyrics ? "ON" : "OFF")"
            + " behavior=\(PlayerGestures.behavior == .skip ? "skip" : "seek"))"
    )
}
