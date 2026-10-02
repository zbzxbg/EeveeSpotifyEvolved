import Foundation

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

    static func tick() {
        // 开关关着 = 一眼都不看（探针只服务于日志）。
        guard UserDefaults.enableLogRecording else { return }

        let track = statefulPlayer?.currentTrack()
        let durationMs = track?.trackDurationMilliseconds ?? 0
        let duration = Double(durationMs) / 1000
        let position = WordByWordPositionResolver.shared.currentPositionSeconds() ?? -1

        // ★ 判"换曲"只用数字，**不用 id**：总时长变了、或者位置**往回跳**了（新曲从 0 起）。
        let wentBackwards: Bool = position >= 0 && lastPosition >= 0 && position + 1 < lastPosition
        let trackChanged: Bool = !didReportFirst || durationMs != lastDurationMs || wentBackwards

        if trackChanged {
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

        guard duration > 0, position >= 0 else { return }

        if moved {
            stalledBeats = 0
            if didReportStall {
                didReportStall = false
                writeDebugLog(
                    String(format: "[%@] position resumed at %.1fs (dur=%.1fs)", logTag, position, duration)
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
                format: "[%@] ⚠️ position stalled at %.1fs for ~%.0fs (dur=%.1fs) — 无法播放的现场判据",
                logTag, position, stuckFor, duration
            )
        )
    }
}
