import Foundation
import MediaPlayer

/// 只读的**播放器状态探针** —— 为「突然无法播放任何歌曲」那条线补现场判据。
///
/// ## 为什么需要它
///
/// 那条症状**至今零判据**（交接文档 §5 第 2 项 / §2.3）：31 份日志里
/// `drm|widevine|license|unplayable|restricted` 全零命中，用户澄清"开着覆盖配置也不行"
/// ⇒ 旧结论 H2（我们的配置层）被排除，剩下 H1（服务端按会话地区判可播放性）/
/// H3（账号风控）。要分开这两者，**本地唯一能看的**就是"播放器到底动没动"。
///
/// ## 打什么（**一个 id 都不打**）
///
///   · **换曲**：`[PLAYER] track changed — pos=…s dur=…s`
///     —— "点了歌没反应"时先看这行有没有出现；
///   · **卡住**：总时长 > 0 而位置连续 ≈3s 没动 ⇒ `⚠️ position stalled …`
///     —— 这就是"连上了但播不动"的现场；恢复时再打一行；
///   · 探针只记**数字与布尔**，所以既不碰脱敏规则（不用改规则），也不会把曲目指纹写进日志。
///
/// ## 谁调它 / 开销
///
/// 蹭 `DeclutterChrome` 既有的复查节拍（0.3s、非前台不跑）—— **不新开定时器**。
/// 另外**先看「启用日志记录」**：开关关着时整个探针是空转（本仓库纪律：开关关着零开销）。
/// 平时一份日志里也就几行（只在换曲/卡住/恢复时打）。
enum PlayerStateProbe {

    static let logTag = "PLAYER"

    /// 0.3s 一拍，10 拍 ≈ 3s 没动就算卡住。
    private static let stallBeats = 10
    private static let beatSeconds = 0.3

    private static var lastDurationMs = -1
    private static var lastPosition: Double = -1
    private static var stalledBeats = 0
    private static var didReportStall = false
    private static var didReportFirst = false

    /// ★★ 2026-10-12（用户：「退出重进 Spotify 大概率突然**无法播放全部歌曲**…点一下灰色歌曲
    /// 又突然能放了（以前也有）」）—— 日志 61 的现场：
    ///
    /// ```
    /// [PLAYER] track changed — pos=0.0s dur=0.0s        ← 启动：一个曲目都没载入
    /// [NET]    Auth request: POST login5.spotify.com/v4/login
    /// [NET]    Auth request: GET  apresolve.spotify.com/
    /// [NET]    Auth request: POST login5.spotify.com/v3/login
    /// …（用户点了一行灰歌）⇒ dur=272 / 215 / 262 / 162 …   ← 又能放了
    /// ```
    ///
    /// 而**旧探针在这个状态是哑的**：它只在 `duration > 0` 时判"卡住"，`dur=0` 直接 `return`
    /// ⇒ "什么都没有"这件事一行都没有（日志 61 里就那一条 `track changed`）。
    /// 现在补两件事，都只报一次：
    ///   · **长时间没有曲目** ⇒ 一行 `⚠️ no track loaded …`（这就是"点了没反应"的现场）；
    ///   · **启动到第一首的秒数** ⇒ 一行 `first track after launch — Xs`
    ///     （冷启动要等多久 / 要不要点一下，全看这个数字）。
    private static var beatsWithoutTrack = 0
    private static var didReportNoTrack = false
    private static var launchAt: CFAbsoluteTime?
    private static var firstTrackAt: CFAbsoluteTime?

    /// ★★ 2026-10-12（用户被问到"这一下是你自己按的暂停吗"时答："**忘了**"）——
    /// **暂停和"播不动"必须由日志自己分开**，不能靠回忆。系统 Now Playing 里带着播放速率：
    /// `rate == 0` ⇒ 是**暂停**（自己按的、或被系统暂停），那一行**不该**被读成"不可播放"；
    /// `rate > 0` 而位置不动，才是真正的"连上了但播不动"。
    /// 用 `MPNowPlayingInfoCenter`（公开 API；`NowPlayingPageOverlay` 已经 import 了 MediaPlayer）。
    private static var playbackRate: Double? {
        let info = MPNowPlayingInfoCenter.default().nowPlayingInfo
        if let rate = info?[MPNowPlayingInfoPropertyPlaybackRate] as? NSNumber { return rate.doubleValue }
        if #available(iOS 13.0, *) {
            switch MPNowPlayingInfoCenter.default().playbackState {
            case .playing: return 1
            case .paused, .stopped: return 0
            default: return nil
            }
        }
        return nil
    }
    private static var didReportPaused = false

    static func tick() {
        // 开关关着 = 一眼都不看（探针只服务于日志）。
        guard UserDefaults.enableLogRecording else { return }

        let now = CFAbsoluteTimeGetCurrent()
        if launchAt == nil { launchAt = now }

        let track = statefulPlayer?.currentTrack()
        let durationMs = track?.trackDurationMilliseconds ?? 0
        let duration = Double(durationMs) / 1000
        let position = WordByWordPositionResolver.shared.currentPositionSeconds() ?? -1

        // ★ 没有曲目 = "点了没反应"最常见的那一种：单独报一行（一次启动一行），
        //   然后**直接返回** —— 下面那些判据（卡住/恢复）都是以"有曲目"为前提的。
        guard duration > 0 else {
            beatsWithoutTrack += 1
            if beatsWithoutTrack >= stallBeats, !didReportNoTrack {
                didReportNoTrack = true
                let sinceLaunch = launchAt.map { now - $0 } ?? 0
                writeDebugLog(
                    String(
                        format: "[%@] \u{26a0}\u{fe0f} no track loaded for ~%.0fs (%.0fs since launch) - nothing can play in this state",
                        logTag, Double(beatsWithoutTrack) * beatSeconds, sinceLaunch
                    )
                )
            }
            return
        }
        beatsWithoutTrack = 0

        // ★ 判"换曲"只用数字，**不用 id**：总时长变了、或者位置**往回跳**了（新曲从 0 起）。
        let wentBackwards: Bool = position >= 0 && lastPosition >= 0 && position + 1 < lastPosition
        let trackChanged: Bool = !didReportFirst || durationMs != lastDurationMs || wentBackwards

        if trackChanged {
            if firstTrackAt == nil {
                firstTrackAt = now
                let sinceLaunch = launchAt.map { now - $0 } ?? 0
                writeDebugLog(
                    String(format: "[%@] first track after launch \u{2014} %.0fs in", logTag, sinceLaunch)
                )
            }
            didReportFirst = true
            lastDurationMs = durationMs
            lastPosition = position
            stalledBeats = 0
            didReportStall = false
            writeDebugLog(
                String(format: "[%@] track changed — pos=%.1fs dur=%.1fs", logTag, max(0, position), duration)
            )
            return
        }

        // 位置有没有动。⚠️ 没在放歌时位置恒为 0，那是正常的 —— 所以下面只在"有总时长"时才判卡住。
        let moved: Bool = abs(position - lastPosition) > 0.05
        lastPosition = position

        guard position >= 0 else { return }

        if moved {
            stalledBeats = 0
            didReportPaused = false
            if didReportStall {
                didReportStall = false
                writeDebugLog(
                    String(format: "[%@] position resumed at %.1fs (dur=%.1fs)", logTag, position, duration)
                )
            }
            return
        }

        // ★ 暂停 ≠ 播不动：播放器自己说 `rate == 0` 时**不计数**（也不报"不可播放"），
        //   只报一次"这一段是暂停"。这样"你当时按没按暂停"就不再需要回忆。
        if let rate = playbackRate, rate == 0 {
            stalledBeats = 0
            if !didReportPaused {
                didReportPaused = true
                writeDebugLog(
                    String(
                        format: "[%@] position held at %.1fs while the player reports paused (rate=0.00) — counted as a pause, not as unplayable",
                        logTag, position
                    )
                )
            }
            return
        }

        stalledBeats += 1
        guard stalledBeats >= stallBeats, !didReportStall else { return }
        didReportStall = true
        let stuckFor = Double(stallBeats) * beatSeconds
        writeDebugLog(
            String(
                format: "[%@] ⚠️ position stalled at %.1fs for ~%.0fs (dur=%.1fs, rate=%.2f) - the unplayable evidence line",
                logTag, position, stuckFor, duration, playbackRate ?? -1
            )
        )
    }
}
