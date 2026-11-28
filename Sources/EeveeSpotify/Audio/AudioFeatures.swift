import AudioToolbox
import CoreAudio
import Foundation
import os

/// 只读音频特征层：在 RemoteIO 的 PostRender 回调里量包络，并给出 **onset 事件**。
///
/// 这一层跑在 render 线程上，纪律与 `AudioTapProbe` 相同，且更严：
/// · 不分配、不建 Swift 集合、不拼字符串、不写日志、不取时间 —— 只做浮点运算；
/// · 锁只 `trylock`，拿不到就丢掉这一拍（宁可少一拍，不能卡音频线程）；
/// · 事件只写进一块**固定大小**的元组，不扩容。
///
/// 判据：**两路包络的上升沿**，不是"整块 RMS 够不够大"。
/// · 每采样点维护 15ms 的平方包络（等价于幅度包络），按 **128 帧（≈2.9ms）** 读一次；
///   包络先把相位抹平，低频鼓点不会因为 2.9ms 窗只覆盖半个周期而一记抖成两下；
/// · `low` = 100Hz 二阶低通、`high` = 1200Hz 以上；`mid`（100–1200）**不触发**，
///   只给"这一下是不是军鼓"当旁证 —— 人声的基频与辅音都在那一段，用它触发会把每个
///   音节都变成一下震动；
/// · 每一路对比一条慢包络（low/high ≈120ms、mid ≈40ms）：抬升要同时超过
///   `floor × 0.5` 与 `慢包络 × (ratio − 1)`；
/// · 低频还有一道**占优判据**：`low > high × 1.5`。军鼓的 190Hz 主体会漏进二阶低通，
///   没有这一道时它会冒充底鼓；底鼓的能量本来就集中在 100Hz 以下，两者比值差得很开；
/// · 每一路有自己的不应期（low 70ms / high 120ms），同一次敲击不会在相邻两窗各报一次。
///
/// 安装与生命周期都在 `AudioTapService` / `AudioReactiveEngine` 里；这里只被它们调用。
enum AudioFeatures {

    static let logTag = "AudioPulse"

    /// 一次 onset：哪个频带、多强、落在这一块的哪个位置。
    struct Onset {
        /// 单调递增；消费方按它判"哪些是新的"。
        var serial: UInt64 = 0
        /// 0 = low（底鼓）、1 = high（军鼓 / 拍手）。
        var band: UInt8 = 0
        /// 0…1，按该带 `floor` 的绝对响度折算。
        var strength: Float = 0
        /// 这一块 PCM 的 host time（mach 绝对时钟，0 = 回调没给）。
        var hostTime: UInt64 = 0
        /// 相对该块开头的秒数。
        var offsetSeconds: Float = 0
    }

    /// 喂给主线程的一拍数据。值类型，跨线程只走这里的副本。
    struct Snapshot {
        /// 低频（100Hz 以下）能量，已压成 0…1，给律动当包络用。
        var low: Float = 0
        /// 高频（1.2kHz 以上）能量，同样 0…1，诊断用。
        var high: Float = 0
        /// 全带宽 RMS / 峰值（原始值，0…1）。
        var rms: Float = 0
        var peak: Float = 0
        /// 累计回调数：没变说明音频停了（暂停 / 切歌 / 后台），
        /// 消费方据此把包络放回 0，而不是停在最后一拍的能量上。
        var callbacks: UInt64 = 0
        /// 最近一拍的块大小（帧）。诊断用。
        var blockFrames: UInt32 = 0
        /// 最近一拍那块 PCM 的 host time。
        var blockHostTime: UInt64 = 0
        /// 最新事件的序号。没变 = 这一拍没有新的 onset。
        var onsetSerial: UInt64 = 0
        /// 最近四个 onset，**新的在前**。一次 tick 里再密也不会超过四个。
        var onsets: (Onset, Onset, Onset, Onset) = (
            Onset(), Onset(), Onset(), Onset()
        )
        /// 当前音频格式能不能读（只支持 float32）。false 时上面那些值恒为 0。
        var isSupported = false
    }

    // MARK: - 参数

    /// 检测窗：128 帧 ≈ 2.9ms（44.1k）。包络已经把相位抹平，这里只决定判定的节拍。
    private static let windowFrames = 128

    /// 分频：100Hz 二阶低通（底鼓）、1200Hz 一阶低通（高频分界）。
    private static let lowCutoffHz = 100.0
    private static let highCutoffHz = 1200.0

    /// 平方包络的时间常数（≈幅度包络）。15ms 对 55Hz 的鼓点只剩 ~9% 纹波。
    private static let envelopeSeconds = 0.015
    /// 慢包络：比较"抬升"的基线。
    private static let slowSeconds = 0.12
    /// mid 只需要"有没有起来"当旁证，基线短一点，长段人声不会把军鼓的旁证压掉。
    private static let midSlowSeconds = 0.04

    /// 每一路的触发门槛：绝对地板、相对慢包络的倍数、不应期（毫秒）。
    private static let lowFloor = 0.018
    private static let highFloor = 0.035
    private static let midFloor = 0.010
    private static let lowRatio = 2.0
    private static let highRatio = 3.0
    private static let midRatio = 2.2
    private static let lowRefractoryMs = 70.0
    private static let highRefractoryMs = 120.0

    /// 低频要"占优"：低/高比低于它就不算底鼓（军鼓会漏进低频）。
    private static let lowDominance = 1.5

    /// 峰值地板：整窗都没什么内容时不做 onset 判定。
    private static let peakFloor = 0.02

    /// 低频 / 高频压成 0…1 的显示增益（只给包络与日志用）。
    private static let lowDisplayGain = 5.0
    private static let highDisplayGain = 8.0

    /// 刚打开时头几块先看不动：那时的慢包络还是 0，任何内容都会被判成 onset。
    private static let warmupBlocks: UInt64 = 4

    /// 每块最多分析的帧数。RemoteIO 的块通常 ≤ 1024，这里是上限而不是截断目标。
    private static let scratchCapacity = 8192

    // MARK: - 共享状态（render 线程写 / 主线程读）

    /// 锁在堆上：它的地址必须稳定（会被 audio 线程拿着）。静态变量的 `&` 在 Swift 里是
    /// inout 语义，不是 C 的取地址。
    private static let lock: UnsafeMutablePointer<os_unfair_lock> = {
        let pointer = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        pointer.initialize(to: os_unfair_lock())
        return pointer
    }()

    /// 把非交错 / 交错两种布局统一成 mono 的临时缓冲。在 `setActive(true)` 时分配一次。
    private static var scratch: UnsafeMutablePointer<Float>?

    /// render 线程要不要算。由 `AudioReactiveEngine` 在开关变化时拨。
    private static var active = false

    /// 格式（由 `AudioTapService` 在 StreamFormat 那一拍喂进来）。
    private static var sampleRate = 0.0
    private static var isInterleaved = false
    private static var isSupported = false
    private static var alphaLow = 0.0
    private static var alphaHighCut = 0.0
    private static var alphaEnvelope = 0.0
    private static var alphaSlow = 0.0
    private static var alphaMidSlow = 0.0
    /// 上一次报过的"能不能读"。只在支持状态**变化**时写一行日志（同一格式会被设好几次）。
    private static var didLogFormat = false
    private static var didLogSupportedValue = false

    /// 滤波与包络状态（跨块保持）。
    private static var lpLow1 = 0.0
    private static var lpLow2 = 0.0
    private static var lpHighCut = 0.0
    private static var envLow = 0.0
    private static var envMid = 0.0
    private static var envHigh = 0.0
    /// 三路慢包络。
    private static var slowLow = 0.0
    private static var slowMid = 0.0
    private static var slowHigh = 0.0
    /// 每一路上次 onset 的音频时间（毫秒），-1 = 还没有。
    private static var lastLowMs = -1.0
    private static var lastHighMs = -1.0

    /// 时间只按"走过的帧数"换算：render 线程不取时间，也就不受系统时钟跳变影响。
    private static var elapsedFrames: UInt64 = 0
    private static var blocksSeen: UInt64 = 0

    private static var callbacks: UInt64 = 0
    private static var blockFrames: UInt32 = 0
    private static var blockHostTime: UInt64 = 0

    /// 最近四个 onset，新的在前（`onsets.0`）。固定大小，不扩容。
    private static var onsets: (Onset, Onset, Onset, Onset) = (
        Onset(), Onset(), Onset(), Onset()
    )
    private static var onsetSerial: UInt64 = 0

    private static var low: Float = 0
    private static var high: Float = 0
    private static var rms: Float = 0
    private static var peak: Float = 0

    // MARK: - 对外

    /// 开关刚打开 / 关掉时调（`AudioReactiveEngine.refresh`）。关掉时把这一整层清零，
    /// 免得下一次打开先读到上一轮的残留能量。
    static func setActive(_ value: Bool) {
        os_unfair_lock_lock(lock)
        active = value
        if value, scratch == nil {
            // 主线程：分配一次，render 线程只写不扩容。
            scratch = UnsafeMutablePointer<Float>.allocate(capacity: scratchCapacity)
        }
        if !value {
            low = 0
            high = 0
            rms = 0
            peak = 0
            lpLow1 = 0
            lpLow2 = 0
            lpHighCut = 0
            envLow = 0
            envMid = 0
            envHigh = 0
            slowLow = 0
            slowMid = 0
            slowHigh = 0
            lastLowMs = -1
            lastHighMs = -1
            blocksSeen = 0
            blockFrames = 0
            blockHostTime = 0
            onsets = (Onset(), Onset(), Onset(), Onset())
        }
        os_unfair_lock_unlock(lock)
    }

    /// 主线程读一拍（30 / 60Hz）。锁只在这一瞬间持有；render 线程那边是 `trylock`，不会互相等。
    static func snapshot() -> Snapshot {
        os_unfair_lock_lock(lock)
        let value = Snapshot(
            low: low,
            high: high,
            rms: rms,
            peak: peak,
            callbacks: callbacks,
            blockFrames: blockFrames,
            blockHostTime: blockHostTime,
            onsetSerial: onsetSerial,
            onsets: onsets,
            isSupported: isSupported
        )
        os_unfair_lock_unlock(lock)
        return value
    }

    /// StreamFormat 那一拍：记下采样率 / 是否交错 / 是否 float32，并把滤波与包络的
    /// 系数算好 —— `exp` 不能出现在 render 线程上。
    ///
    /// 喂进来的必须是**真正会被挂渲染通知的那个 output unit**（RemoteIO）；别的输出单元
    /// 的格式不能拿来解释 RemoteIO 的 buffer 布局。
    static func noteFormat(_ format: AudioStreamBasicDescription) {
        let float = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let supported = float
            && format.mBitsPerChannel == 32
            && format.mSampleRate > 0
            && format.mChannelsPerFrame > 0
        let rate = Double(format.mSampleRate)
        let alphaLow = supported ? 1 - exp(-2 * Double.pi * lowCutoffHz / rate) : 0
        let alphaHighCut = supported ? 1 - exp(-2 * Double.pi * highCutoffHz / rate) : 0
        let alphaEnvelope = supported ? 1 - exp(-1 / (rate * envelopeSeconds)) : 0
        // 慢包络是**每窗**更新一次，所以系数按"一窗多少秒"算，不是按采样点。
        let windowSeconds = Double(windowFrames) / rate
        let alphaSlow = supported ? 1 - exp(-windowSeconds / slowSeconds) : 0
        let alphaMidSlow = supported ? 1 - exp(-windowSeconds / midSlowSeconds) : 0

        os_unfair_lock_lock(lock)
        // 同一个 unit 上可能先来 Spotify 内部的中间格式、后来硬件格式：float32 的那份优先，
        // 与 `AudioTapProbe` 收格式的判据一致。
        if supported || !isSupported {
            sampleRate = rate
            isInterleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
            isSupported = supported
            self.alphaLow = alphaLow
            self.alphaHighCut = alphaHighCut
            self.alphaEnvelope = alphaEnvelope
            self.alphaSlow = alphaSlow
            self.alphaMidSlow = alphaMidSlow
        }
        let shouldLog = !didLogFormat || didLogSupportedValue != supported
        if shouldLog {
            didLogFormat = true
            didLogSupportedValue = supported
        }
        os_unfair_lock_unlock(lock)

        guard shouldLog else { return }
        writeDebugLog(
            "[\(logTag)] format \(Int(format.mSampleRate))Hz \(format.mChannelsPerFrame)ch"
                + " \(format.mBitsPerChannel)bit flags=\(format.mFormatFlags)"
                + " supported=\(supported) interleaved=\(format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0)"
        )
    }

    // MARK: - render 线程

    /// PostRender 的 PCM：算这一块的包络与 onset。**绝不阻塞**：拿到锁就算，拿不到就丢这一拍。
    static func handleRender(
        actionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        busNumber: UInt32,
        numberFrames: UInt32,
        ioData: UnsafeMutablePointer<AudioBufferList>?,
        timeStamp: UnsafePointer<AudioTimeStamp>? = nil
    ) -> OSStatus {
        guard actionFlags.pointee.contains(AudioUnitRenderActionFlags.unitRenderAction_PostRender) else {
            return noErr
        }
        guard let ioData else { return noErr }
        guard os_unfair_lock_trylock(lock) else { return noErr }
        guard active, isSupported, sampleRate > 0, let scratch = scratch else {
            os_unfair_lock_unlock(lock)
            return noErr
        }

        elapsedFrames &+= UInt64(numberFrames)
        let buffers = UnsafeMutableAudioBufferListPointer(ioData)

        // 把这一块统一成 mono：非交错是"一个 buffer 一个声道"，交错是"一个 buffer N 个声道"。
        // 两种都取前两声道平均；尾部多出来的声道不参与。
        var frames = 0
        if !isInterleaved, buffers.count >= 2,
           let leftData = buffers[0].mData, let rightData = buffers[1].mData {
            let left = leftData.assumingMemoryBound(to: Float.self)
            let right = rightData.assumingMemoryBound(to: Float.self)
            let leftFrames = Int(buffers[0].mDataByteSize) / MemoryLayout<Float>.size
            let rightFrames = Int(buffers[1].mDataByteSize) / MemoryLayout<Float>.size
            frames = min(min(Int(numberFrames), scratchCapacity), min(leftFrames, rightFrames))
            var index = 0
            while index < frames {
                scratch[index] = (left[index] + right[index]) * 0.5
                index += 1
            }
        } else if buffers.count >= 1, let data = buffers[0].mData {
            let step = max(1, Int(buffers[0].mNumberChannels))
            let samples = data.assumingMemoryBound(to: Float.self)
            let available = Int(buffers[0].mDataByteSize) / MemoryLayout<Float>.size / step
            frames = min(min(Int(numberFrames), scratchCapacity), available)
            var index = 0
            while index < frames {
                let base = index * step
                scratch[index] = step >= 2
                    ? (samples[base] + samples[base + 1]) * 0.5
                    : samples[base]
                index += 1
            }
        }
        guard frames > 0 else {
            os_unfair_lock_unlock(lock)
            return noErr
        }

        // 只有真的读到帧才记一拍：`callbacks` 是消费方判"有没有新数据"的唯一依据，
        // 空块也加会让引擎把上一块的电平当成新的一拍。
        callbacks &+= 1
        blockFrames = numberFrames
        blockHostTime = timeStamp?.pointee.mHostTime ?? 0

        let blockStartMs = Double(elapsedFrames - UInt64(numberFrames)) * 1000 / sampleRate

        var totalAll2 = 0.0
        var blockPeak = 0.0
        var blockLowPeak = 0.0
        var blockHighPeak = 0.0
        var windowStart = 0

        while windowStart < frames {
            let windowEnd = min(windowStart + windowFrames, frames)
            var windowPeak = 0.0
            var index = windowStart
            while index < windowEnd {
                let mono = Double(scratch[index])
                // 100Hz 二阶低通：底鼓；1200Hz 一阶低通：高频分界。
                lpLow1 += alphaLow * (mono - lpLow1)
                lpLow2 += alphaLow * (lpLow1 - lpLow2)
                lpHighCut += alphaHighCut * (mono - lpHighCut)
                let lowSignal = lpLow2
                let midSignal = lpHighCut - lpLow1
                let highSignal = mono - lpHighCut
                // 15ms 平方包络：先把相位抹平，再拿幅度。
                envLow += alphaEnvelope * (lowSignal * lowSignal - envLow)
                envMid += alphaEnvelope * (midSignal * midSignal - envMid)
                envHigh += alphaEnvelope * (highSignal * highSignal - envHigh)
                totalAll2 += mono * mono
                let magnitude = abs(mono)
                if magnitude > windowPeak { windowPeak = magnitude }
                index += 1
            }
            if windowPeak > blockPeak { blockPeak = windowPeak }

            let rmsLow = envLow.squareRoot()
            let rmsMid = envMid.squareRoot()
            let rmsHigh = envHigh.squareRoot()
            if rmsLow > blockLowPeak { blockLowPeak = rmsLow }
            if rmsHigh > blockHighPeak { blockHighPeak = rmsHigh }

            // 判定用的是**上一窗结束时**的慢包络；判完再让它追上来。
            if blocksSeen > warmupBlocks, windowPeak > peakFloor {
                let onsetMs = blockStartMs + Double(windowEnd) * 1000 / sampleRate
                let offsetSeconds = Float(Double(windowEnd) / sampleRate)
                // 军鼓的主体会漏进低频：没有"低频占优"这一道，它会冒充底鼓。
                let lowDominant = rmsLow > rmsHigh * lowDominance
                if rmsLow > lowFloor, lowDominant,
                   rmsLow - slowLow > max(lowFloor * 0.5, slowLow * (lowRatio - 1)),
                   onsetMs - lastLowMs > lowRefractoryMs {
                    lastLowMs = onsetMs
                    emit(
                        band: 0,
                        strength: Float(min(1, rmsLow / (lowFloor * 4))),
                        hostTime: blockHostTime,
                        offsetSeconds: offsetSeconds
                    )
                }
                // 高频要有 mid 的旁证（军鼓/拍手的身板），否则踩镲也会打一下。
                let midRisen = rmsMid > midFloor
                    && rmsMid - slowMid > max(midFloor * 0.5, slowMid * (midRatio - 1))
                if rmsHigh > highFloor, midRisen,
                   rmsHigh - slowHigh > max(highFloor * 0.5, slowHigh * (highRatio - 1)),
                   onsetMs - lastHighMs > highRefractoryMs {
                    lastHighMs = onsetMs
                    emit(
                        band: 1,
                        strength: Float(min(1, rmsHigh / (highFloor * 4))),
                        hostTime: blockHostTime,
                        offsetSeconds: offsetSeconds
                    )
                }
            }

            slowLow += alphaSlow * (rmsLow - slowLow)
            slowMid += alphaMidSlow * (rmsMid - slowMid)
            slowHigh += alphaSlow * (rmsHigh - slowHigh)

            windowStart = windowEnd
        }

        blocksSeen &+= 1
        let frameCount = Double(frames)
        // 显示值取这一块里包络的**峰值**：取块尾那一瞬的话，鼓点早衰减没了，封面律动会变弱。
        low = Float(min(1, blockLowPeak * lowDisplayGain))
        high = Float(min(1, blockHighPeak * highDisplayGain))
        rms = Float(min(1, (totalAll2 / frameCount).squareRoot()))
        peak = Float(min(1, blockPeak))

        os_unfair_lock_unlock(lock)
        return noErr
    }

    /// 写入最近四个 onset（新的在前）。固定元组，不分配。
    private static func emit(
        band: UInt8,
        strength: Float,
        hostTime: UInt64,
        offsetSeconds: Float
    ) {
        onsetSerial &+= 1
        let onset = Onset(
            serial: onsetSerial,
            band: band,
            strength: strength,
            hostTime: hostTime,
            offsetSeconds: offsetSeconds
        )
        onsets.3 = onsets.2
        onsets.2 = onsets.1
        onsets.1 = onsets.0
        onsets.0 = onset
    }
}
