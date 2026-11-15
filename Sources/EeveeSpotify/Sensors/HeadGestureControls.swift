import CoreMotion
import Foundation

// 头部姿态 → 切歌。
//
// AirPods（Pro / Max）把惯性传感器读到的姿态交给 CoreMotion 的
// `CMHeadphoneMotionManager`：每帧一条 `CMDeviceMotion`，`attitude` 就是头相对
// 「起流那一刻」的俯仰（pitch）/ 偏航（yaw），单位弧度。本文件把这条流变成两个动作：
//
//   点一下头（低头再回正）→ 下一首
//   摇一下头（向左再回正）→ 上一首
//
// 判定用的是**两摆**：单独一摆（只有低头、没回来）不算 —— 靠"幅度阈值 + 折返窗口"
// 把"认真点了一下头"和"走路时头在自然晃"分开。宁可漏，也不要误切歌：少识别一次手势
// 只是没反应，误切一首歌会直接打断正在听的东西。

// MARK: - 判定参数
//
// 全是"看着姿态角调"的经验值，集中在这里方便按机型微调（不同型号的传感器噪声不同）。

/// 俯仰一摆必须越过的幅度（弧度）。点头的行程通常远超它，而走路时的俯仰起伏在 0.1 上下。
private let nodSwingAmplitude: Double = 0.22
/// 偏航一摆必须越过的幅度（弧度）。摇头的行程比点头大，阈值跟着抬高一点。
private let shakeSwingAmplitude: Double = 0.26
/// 两摆之间允许的最大间隔（秒）—— 一次点头 / 摇头的全程。超过它说明这两摆不是同一个手势。
private let swingPairWindow: TimeInterval = 1.2
/// 触发之后的静默期（秒）：一次手势只切一首，也挡住"回正的那一下"再凑成第二对。
private let gestureCooldown: TimeInterval = 1.5
/// 自动重启的最小间隔（秒）。耳机重连事件不保证只来一次，起流失败更不能连着重试。
private let autoRestartThrottle: TimeInterval = 5.0

/// 调试输出的标签（见各一次性输出）。
private let headGestureLogTag = "HeadGesture"

// MARK: - 对外入口

/// 点头 / 摇头切歌。
///
/// 三个入口都在主线程调用；真正的样本判定在 `HeadGestureRunner` 自己的串行队列上。
enum HeadGestureControls {

    /// 当前有没有"能给头部姿态数据"的耳机连着（AirPods Pro / Max 等带惯性传感器的型号）。
    ///
    /// 设置页拿它显示状态行。它跟着耳机连接状态变，不是常量 —— 所以页面每次出现都要重读。
    static var isMotionAvailable: Bool {
        runner.manager.isDeviceMotionAvailable
    }

    /// 按设置键对齐运行状态：开着就起流，关掉就停流（幂等，可以反复调）。
    ///
    /// 开关只表达"要不要这个功能"；能不能真的起流还得看耳机在不在、给不给数据，
    /// 那部分判断收在 `HeadGestureRunner` 里。
    static func syncWithSettings() {
        runner.apply(enabled: UserDefaults.headGestureControlsEnabled)
    }

    /// 无条件停流（开关关掉、要兜底、或者外部要求立刻安静时用）。
    static func stop() {
        runner.stop()
    }

    /// 进程级单例：`CMHeadphoneMotionManager` 只建一个，耳机连接事件才会一直有人接。
    private static let runner = HeadGestureRunner()
}

// MARK: - 运行层

/// 姿态流的持有者。
///
/// 为什么是类而不是把状态摊进 `HeadGestureControls`：耳机连接 / 断开的回调来自
/// `CMHeadphoneMotionManagerDelegate`，那是实例方法，而上面是个没有实例的 enum。
///
/// 线程约定（两半各碰各的字段，只有"真的切歌"才跳一次主队列）：
/// · 主线程：`apply` / `stop` / 两个 delegate 回调、生命周期状态、一次性输出标记；
/// · `sampleQueue`：两个单轴计数器、静默期终点、流出错标记。
private final class HeadGestureRunner: NSObject, CMHeadphoneMotionManagerDelegate {

    let manager = CMHeadphoneMotionManager()

    /// 样本回调队列：串行、独立于主线程 —— 姿态流是 25–50Hz，判定不必压在主线程上。
    private let sampleQueue = OperationQueue()

    /// 我们**请求过**起流。与 CoreMotion 内部是否真的在推数据是两件事，
    /// 所以判断"能不能再起一次"只看它自己的流程，不去问框架。
    private var isRunning = false
    /// 上一次自动重启的时间，配合 `autoRestartThrottle` 防止连着重试。
    private var lastAutoStartAt: TimeInterval = 0

    /// 俯仰（点头）与偏航（摇头）各自的计数器。**只由 `sampleQueue` 碰**。
    private var nod = HeadSwingTracker()
    private var shake = HeadSwingTracker()
    /// 静默期终点（单调时钟，秒）。**只由 `sampleQueue` 碰**。
    private var quietUntil: TimeInterval = 0
    /// 流出错只留一行：出错可能每帧都来一次。**只由 `sampleQueue` 碰**。
    private var didLogStreamError = false

    /// 一次性标记：这条流每个进程只打一行"通了 / 起不来"，逐样本不打。
    private var didLogStart = false
    private var didLogUnavailable = false
    private var didLogFirstNod = false
    private var didLogFirstShake = false

    override init() {
        super.init()
        sampleQueue.name = "eevee.head-gesture"
        sampleQueue.qualityOfService = .userInitiated
        sampleQueue.maxConcurrentOperationCount = 1
        // `delegate` 是 weak 引用，持有者是本对象（`manager` 是它的属性）——
        // 两边不会互相持有，所以不必反向清理。
        manager.delegate = self
    }

    // MARK: 起流 / 停流

    func apply(enabled: Bool) {
        // 起流、以及连接事件，都要求调用线程上跑着 run loop（CoreMotion 的约定），
        // 统一收在主线程，调用方在哪条线程上都行。
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.apply(enabled: enabled) }
            return
        }
        if enabled {
            start()
        } else {
            stop()
        }
    }

    func stop() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.stop() }
            return
        }
        manager.stopDeviceMotionUpdates()
        // 开关关掉就不再需要连接事件：它只为"耳机回来了自动恢复"服务。
        manager.stopConnectionStatusUpdates()
        isRunning = false
        requestDetectorReset()
    }

    private func start() {
        // 耳机连接 / 断开的事件只有开了「连接状态更新」之后才会来，而断开之后这条流
        // 会自己停 —— 所以每次起流都再开一遍（重复调用是幂等的）。
        manager.startConnectionStatusUpdates()

        guard manager.isDeviceMotionAvailable else {
            if !didLogUnavailable {
                didLogUnavailable = true
                writeDebugLog(
                    "[\(headGestureLogTag)] no headphone motion — needs AirPods Pro / Max"
                        + " with motion sensors; waiting for them"
                )
            }
            // 耳机没连上：不起流、也不在这里重试，等 `headphoneMotionManagerDidConnect`。
            return
        }

        // 幂等起流：先把可能还挂着的旧流停掉 —— 否则"以为在跑、其实早断了"时永远起不来。
        manager.stopDeviceMotionUpdates()
        // 判定状态在开流**之前**清：样本一到就能用干净的基准，不会被上一轮的历史摆动配对。
        requestDetectorReset()
        manager.startDeviceMotionUpdates(to: sampleQueue) { [weak self] motion, error in
            self?.consume(motion, error: error)
        }
        isRunning = true
        if !didLogStart {
            didLogStart = true
            writeDebugLog(
                "[\(headGestureLogTag)] started — nod = next track, shake = previous track"
            )
        }
    }

    // MARK: 每一帧

    /// 一帧姿态。**只在 `sampleQueue` 上跑。**
    private func consume(_ motion: CMDeviceMotion?, error: Error?) {
        if let error {
            // 出错说明这条路断了（耳机被拿走、链路断了）。这里只清判定状态，
            // 运行状态交给重连回调或下一次 `syncWithSettings()` —— 不在样本回调里自己重试，
            // 否则一旦框架持续报错就会变成忙等。
            resetDetectors()
            if !didLogStreamError {
                didLogStreamError = true
                writeDebugLog(
                    "[\(headGestureLogTag)] stream failed — \(error.localizedDescription)"
                )
            }
            return
        }
        guard let motion else { return }

        // 单调时钟，与 `CACurrentMediaTime()` 同一时基；每帧只读一次，不产生对象。
        let now = ProcessInfo.processInfo.systemUptime
        let attitude = motion.attitude
        // 两个轴各自独立判定：点头只看俯仰，摇头只看偏航。
        let nodSwing = nod.feed(attitude.pitch, amplitude: nodSwingAmplitude, at: now)
        let shakeSwing = shake.feed(attitude.yaw, amplitude: shakeSwingAmplitude, at: now)

        // 静默期里照常喂样本（基准要跟着头走），但不允许再触发。
        guard now >= quietUntil else { return }

        if nodSwing != 0 {
            // 顺序不能反：先清两摆历史、再上静默期锁 —— 反过来会被"清历史"把锁一起清掉。
            resetSwingHistory()
            quietUntil = now + gestureCooldown
            DispatchQueue.main.async { [weak self] in self?.performNext() }
        } else if shakeSwing != 0 {
            resetSwingHistory()
            quietUntil = now + gestureCooldown
            DispatchQueue.main.async { [weak self] in self?.performPrevious() }
        }
    }

    /// 清掉两摆历史（基准点、上一摆方向与时间）。**只在 `sampleQueue` 上跑。**
    private func resetSwingHistory() {
        nod.reset()
        shake.reset()
    }

    /// 清掉两摆历史与静默期。**只在 `sampleQueue` 上跑。**
    private func resetDetectors() {
        resetSwingHistory()
        quietUntil = 0
    }

    /// 从主线程请求清一次判定状态（交给 `sampleQueue` 执行，避免跨线程写它的字段）。
    private func requestDetectorReset() {
        sampleQueue.addOperation { [weak self] in self?.resetDetectors() }
    }

    // MARK: 动作（主线程）

    /// 切下一首。**主线程**：`WordByWordPlaybackControl` 探测的是 UIKit 控件与播放器对象。
    private func performNext() {
        if !didLogFirstNod {
            didLogFirstNod = true
            writeDebugLog("[\(headGestureLogTag)] first nod — next track")
        }
        WordByWordPlaybackControl.skipToNext()
    }

    private func performPrevious() {
        if !didLogFirstShake {
            didLogFirstShake = true
            writeDebugLog("[\(headGestureLogTag)] first shake — previous track")
        }
        WordByWordPlaybackControl.skipToPrevious()
    }

    // MARK: 耳机连接 / 断开（CMHeadphoneMotionManagerDelegate）

    /// 耳机被拿走：CoreMotion 会自己停掉姿态流，而开关可能还开着 —— 不在这里把运行状态
    /// 让出来，设置页会一直显示"可用"、实际上一个样本都不来。
    func headphoneMotionManagerDidDisconnect(_ manager: CMHeadphoneMotionManager) {
        DispatchQueue.main.async { [weak self] in self?.handleDisconnect() }
    }

    /// 耳机回来了：开关还开着就自动恢复，省得用户为了继续用手势去重开一次开关。
    func headphoneMotionManagerDidConnect(_ manager: CMHeadphoneMotionManager) {
        DispatchQueue.main.async { [weak self] in self?.handleConnect() }
    }

    private func handleDisconnect() {
        guard isRunning else { return }
        manager.stopDeviceMotionUpdates()
        isRunning = false
        requestDetectorReset()
        writeDebugLog("[\(headGestureLogTag)] headphones gone — stream stopped until they return")
    }

    private func handleConnect() {
        // 连接事件不保证只来一次，而起流失败时更不能连着重试 —— 自动恢复走节流。
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastAutoStartAt >= autoRestartThrottle else { return }
        guard UserDefaults.headGestureControlsEnabled else { return }
        lastAutoStartAt = now
        start()
    }
}

// MARK: - 单轴计数器

/// 单轴（俯仰或偏航）的"两摆"计数。
///
/// 只记三件事：上一摆从哪儿起算（基准点）、上一摆的方向、上一摆的时间。
/// 新的一摆与上一摆**方向相反**、并且落在 `swingPairWindow` 内 ⇒ 一次完整手势。
///
/// 同方向连续越过幅度只把基准点往前推：那是同一摆的延续（慢慢转头、低头看手机），
/// 不是新的一摆 —— 否则一次缓慢漂移会被累积成连续手势。
private struct HeadSwingTracker {

    /// 上一次越过幅度时的角度；nil = 还没有基准（刚起流、或刚触发过）。
    private var anchor: Double?
    /// 上一摆的方向：+1 角度变大、-1 变小、0 = 还没有。
    private var direction: Double = 0
    /// 上一摆发生的时间（单调时钟，秒）。
    private var lastSwingAt: TimeInterval = 0

    /// 送一帧角度进来；返回值非 0 表示这一帧凑成了一次完整手势（值就是这一摆的方向）。
    mutating func feed(_ value: Double, amplitude: Double, at time: TimeInterval) -> Double {
        guard let currentAnchor = self.anchor else {
            self.anchor = value
            return 0
        }
        if value - currentAnchor >= amplitude {
            self.anchor = value
            return confirm(direction: 1, at: time)
        }
        if currentAnchor - value >= amplitude {
            self.anchor = value
            return confirm(direction: -1, at: time)
        }
        return 0
    }

    /// 归零。换耳机、重新起流、刚触发过都要调 —— 否则流里的历史摆动会被当成本次手势的
    /// 前半摆，一次点头可能被算成两次。
    mutating func reset() {
        anchor = nil
        direction = 0
        lastSwingAt = 0
    }

    private mutating func confirm(direction newDirection: Double, at time: TimeInterval) -> Double {
        // 同一摆的延续（还在朝同一侧走）：只把时间推上去，不算新的一摆。
        if newDirection == direction {
            lastSwingAt = time
            return 0
        }
        let paired = direction != 0 && time - lastSwingAt <= swingPairWindow
        direction = newDirection
        lastSwingAt = time
        return paired ? newDirection : 0
    }
}
