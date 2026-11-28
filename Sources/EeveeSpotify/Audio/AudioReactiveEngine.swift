import AVFoundation
import Foundation
import QuartzCore
import UIKit

/// 音频驱动功能的 30Hz 驱动层：把 `AudioFeatures` 的快照变成两条现场指令。
///
/// 分工：
/// · render 线程只往 `AudioFeatures` 里写（不分配、不加锁等待）；
/// · 这里**在主线程**按 30Hz 读快照 → 一条包络（attack 快、release 慢）→ 分发给
///   `CoverPulse`（封面律动）与 `MusicHaptics`（音乐触感）。
///
/// 为什么用 CADisplayLink 而不是 GCD 定时器：App 进后台时它自然停，不必自己判前后台；
/// 30Hz 也不是每帧，`preferredFrameRateRange` 直接把刷新率压下来省电。
final class AudioReactiveEngine: NSObject {

    static let shared = AudioReactiveEngine()

    /// 两颗开关的并集：都关着时，`AudioFeatures` 与 ticker 全停（hook 仍在，但没人读）。
    static var isWanted: Bool {
        UserDefaults.coverPulseEnabled || UserDefaults.musicHapticsEnabled
    }

    /// 律动幅度：跟着低频包络走的缩放上限（`1 + amplitude * envelope`）。
    ///
    /// 2% 是"能看出来、又不至于廉价"的一档：再大就像整块封面在呼吸而不是音乐在动。
    private static let amplitude: Double = 0.02
    /// 释放时间：attack 是"当拍就到位"，release 走这条指数衰减（≈150ms）。
    private static let releaseSeconds: Double = 0.15
    /// 包络低于这个值就直接归零，省掉"永远差一点点"的 30Hz 属性写。
    private static let envelopeFloor: Double = 0.02

    private var displayLink: CADisplayLink?
    private var lastCallbacks: UInt64 = 0
    private var lastTickAt: CFTimeInterval = 0
    private var startedAt: CFTimeInterval = 0
    private var envelope: Double = 0
    private var pulseRunning = false
    private var hapticsRunning = false
    private var tickRateHz = 30
    private var didLogStart = false
    private var didLogAudio = false
    private var didLogSilence = false

    private override init() {
        super.init()
    }

    /// 开关 / 设置页改动之后调一次：需要就装 hook + 起 ticker，不需要就全部停掉并把画面还原。
    ///
    /// 幂等：反复调只做状态对齐，不会重复起 display link、也不会重复装 hook。
    func refresh() {
        // CADisplayLink 挂在主队列上：启动路径若不在主线程，挪过去再起。
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.refresh() }
            return
        }
        if Self.isWanted {
            AudioTapService.ensureInstalled()
            AudioFeatures.setActive(true)
            start()
        } else {
            AudioFeatures.setActive(false)
            stop()
        }
    }

    private var isRunning: Bool { displayLink != nil }

    private func start() {
        guard !isRunning else { return }
        // 基线取**当前**回调数：`AudioFeatures` 的计数是跨开关累计的，从 0 起会让第一拍
        // 误判成"刚有新数据"。
        lastCallbacks = AudioFeatures.snapshot().callbacks
        lastTickAt = CACurrentMediaTime()
        startedAt = lastTickAt
        envelope = 0
        didLogAudio = false
        didLogSilence = false
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 20, maximum: 60, preferred: 30)
        link.add(to: .main, forMode: .common)
        displayLink = link
        tickRateHz = 30
        updateTickRate()
        if !didLogStart {
            didLogStart = true
            writeDebugLog(
                "[\(AudioFeatures.logTag)] ticker on — cover pulse=\(UserDefaults.coverPulseEnabled)"
                    + " haptics=\(UserDefaults.musicHapticsEnabled)"
            )
            logAudioRoute()
        }
    }

    /// 一条一次：当前输出路由与系统报的延迟。有线 / 蓝牙的听感延迟差一个数量级，
    /// 诊断"触感偏早还是偏晚"时不能只靠猜。
    private static func logAudioRoute() {
        let session = AVAudioSession.sharedInstance()
        let outputs = session.currentRoute.outputs
        let route = outputs.isEmpty
            ? "none"
            : outputs.map { $0.portType.rawValue }.joined(separator: ",")
        writeDebugLog(
            "[\(AudioFeatures.logTag)] route — \(route)"
                + " outputLatency=\(String(format: "%.4f", session.outputLatency))"
                + " ioBuffer=\(String(format: "%.4f", session.ioBufferDuration))"
                + " sampleRate=\(Int(session.sampleRate))"
        )
    }

    /// 触感开着时把这一拍提到 60Hz。
    ///
    /// onset 已经带了时间戳，但消费得越晚、打出去也越晚：30Hz 那档最多晚 33ms。
    /// 只看封面律动时留在 30Hz 省电。
    private func updateTickRate() {
        let wanted = UserDefaults.musicHapticsEnabled ? 60 : 30
        guard wanted != tickRateHz, let link = displayLink else { return }
        tickRateHz = wanted
        link.preferredFrameRateRange = CAFrameRateRange(
            minimum: 20,
            maximum: 60,
            preferred: Float(wanted)
        )
    }

    private func stop() {
        displayLink?.invalidate()
        displayLink = nil
        envelope = 0
        pulseRunning = false
        hapticsRunning = false
        // 关开关要**当场**把封面缩放 / field 透明度放回去：留着 1.02 的变换没人收，
        // 下次再开会对不上"当前幅度"。
        CoverPulse.reset()
        MusicHaptics.reset()
    }

    /// 主线程一拍。**不碰音频线程**：`AudioFeatures.snapshot()` 只是把锁短暂拿一下。
    @objc private func tick(_ link: CADisplayLink) {
        guard Self.isWanted else {
            refresh()
            return
        }

        let now = CACurrentMediaTime()
        let delta = max(0.001, min(0.1, now - lastTickAt))
        lastTickAt = now
        updateTickRate()

        let snapshot = AudioFeatures.snapshot()
        // 暂停 / 切歌的那一瞬间音频回调会停：没有新数据就把包络放到 0，而不是停在最后一拍。
        let fresh = snapshot.callbacks != lastCallbacks
        lastCallbacks = snapshot.callbacks

        // 两条一次性的现场判据（每个 ticker 生命周期各一行）：
        // 拿到数据 = 这条路通了；6 秒还没有 = 渲染通知没挂上，要去暂停再播一次。
        if fresh, !didLogAudio {
            didLogAudio = true
            writeDebugLog(
                "[\(AudioFeatures.logTag)] audio flowing — supported=\(snapshot.isSupported)"
                    + " low=\(String(format: "%.3f", snapshot.low))"
                    + " rms=\(String(format: "%.3f", snapshot.rms))"
                    + " peak=\(String(format: "%.3f", snapshot.peak))"
                    + " blk=\(snapshot.blockFrames)"
            )
        } else if !fresh, !didLogAudio, !didLogSilence, now - startedAt > 6 {
            didLogSilence = true
            writeDebugLog(
                "[\(AudioFeatures.logTag)] no PCM after 6s — the tap attaches on the next"
                    + " playback start, so pause and resume once"
            )
        }

        let level = fresh ? Double(snapshot.low) : 0
        let decay = exp(-delta / Self.releaseSeconds)
        envelope = level > envelope ? level : envelope * decay
        if envelope < Self.envelopeFloor { envelope = 0 }

        if UserDefaults.coverPulseEnabled {
            pulseRunning = true
            CoverPulse.apply(
                scale: CGFloat(1 + Self.amplitude * envelope),
                breath: CGFloat(envelope)
            )
        } else if pulseRunning {
            // 只关掉律动、留触感时 ticker 不会停 ⇒ 这里必须当场把封面/field 写回静止值。
            pulseRunning = false
            CoverPulse.reset()
        }
        if UserDefaults.musicHapticsEnabled {
            hapticsRunning = true
            MusicHaptics.consume(snapshot, isFresh: fresh, now: now)
        } else if hapticsRunning {
            // 同上：关掉触感后要让 `primed` 归位，否则再打开时会用冻结的基准补打一下。
            hapticsRunning = false
            MusicHaptics.reset()
        }
    }
}
