import AudioToolbox
import CoreAudio
import Foundation
import os

/// 只读音频特征层：在 RemoteIO 的 PostRender 回调里量 RMS / 峰值 / 低频与高频能量，
/// 并给出 kick / snare 的瞬态计数；主线程按 30Hz 读 `snapshot()`。
///
/// 这一层跑在 render 线程上，纪律与 `AudioTapProbe` 相同，且更严：
/// · 不分配、不建 Swift 集合、不拼字符串、不写日志、不取时间 —— 只做浮点运算；
/// · 锁只 `trylock`，拿不到就丢掉这一拍（宁可少一拍，不能卡音频线程）；
/// · 每块最多扫前 `maxScanFrames` 帧（低频包络不需要整块 1024 帧）；
/// · 状态与探针**各自一份**，两者只共用 `AudioTapService` 那一次 fishhook 安装。
///
/// 安装与生命周期都在 `AudioTapService` / `AudioReactiveEngine` 里；这里只被它们调用。
enum AudioFeatures {

    static let logTag = "AudioPulse"

    /// 喂给主线程的一拍数据。值类型，跨线程只走这里的副本。
    struct Snapshot {
        /// 低频（200Hz 以下）能量，已压成 0…1，直接给律动当包络用。
        var low: Float = 0
        /// 高频（2.5kHz 以上）能量，同样 0…1，只用来判 snare。
        var high: Float = 0
        /// 全带宽 RMS / 峰值（原始值，0…1）。
        var rms: Float = 0
        var peak: Float = 0
        /// 从进程启动累计的 kick / snare 次数：消费方按差值判"这一拍有没有新的"。
        var kickCount: UInt64 = 0
        var snareCount: UInt64 = 0
        /// 累计回调数：没变说明音频停了（暂停 / 切歌 / 后台），消费方据此把包络放回 0，
        /// 而不是停在最后一拍的能量上。
        var callbacks: UInt64 = 0
        /// 这一拍读到的块大小（帧）。诊断用：块大小决定"命中落在块内"的不确定度。
        var blockFrames: UInt32 = 0
        /// 这一拍那块 PCM 的 host time（mach 绝对时钟，0 = 回调没给）。
        /// 主线程拿它和 `CACurrentMediaTime()` 一比，就知道"这块什么时候开始播"。
        var blockHostTime: UInt64 = 0
        /// 当前音频格式能不能读（只支持 float32）。false 时上面那些值恒为 0。
        var isSupported = false
    }

    // MARK: - 参数（都按"包络够用"取，不追求精确频谱）

    /// 每块最多扫多少帧。1024 帧/块时只扫前 512 帧 ≈ 11.6ms —— 低频包络用这段足够，
    /// 而且把 render 线程的读取量压到一半。
    private static let maxScanFrames = 512

    /// 低频档：一阶低通；高频档：原信号减一阶低通（相当于 2.5kHz 以上）。
    private static let lowCutoffHz = 200.0
    private static let highCutoffHz = 2500.0

    /// kick / snare 的判据：瞬时能量要比慢包络跳起多少倍、绝对地板、以及冷却时间。
    ///
    /// 三个数都是"相对量 + 绝对量"配合：只比值会在安静的歌里把每一个小鼓点都放大成触发，
    /// 只绝对量会在响的歌里一直触发。地板同时挡住静音段（没有内容可触发）。
    private static let kickFloor = 0.030
    private static let kickRatio = 1.8
    private static let kickCooldownMs = 140.0
    private static let snareFloor = 0.012
    private static let snareRatio = 2.2
    private static let snareCooldownMs = 110.0
    /// 峰值地板：整块都没什么内容时不做瞬态判定。
    private static let peakFloor = 0.02

    /// 慢包络的跟随速度（每块一次；47 块/秒 ⇒ 约 0.4s 时间常数）。
    private static let envelopeFollow = 0.05

    /// 低频 / 高频压成 0…1 的增益。低频 rms 0.03 上下是"有鼓但克制"的常见值。
    private static let lowDisplayGain = 5.0
    private static let highDisplayGain = 8.0

    /// 刚打开时头几块先看不动：那时的"慢包络"还是 0，任何内容都会被判成瞬态。
    private static let warmupBlocks: UInt64 = 4

    // MARK: - 共享状态（render 线程写 / 主线程读）

    /// 锁在堆上：它的地址必须稳定（会被 audio 线程拿着）。静态变量的 `&` 在 Swift 里是
    /// inout 语义，不是 C 的取地址。
    private static let lock: UnsafeMutablePointer<os_unfair_lock> = {
        let pointer = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        pointer.initialize(to: os_unfair_lock())
        return pointer
    }()

    /// render 线程要不要算。由 `AudioReactiveEngine` 在开关变化时拨。
    private static var active = false

    /// 格式（由 `AudioTapService` 在 StreamFormat 那一拍喂进来）。
    private static var sampleRate = 0.0
    private static var isInterleaved = false
    private static var isSupported = false
    private static var alphaLow = 0.0
    private static var alphaHigh = 0.0
    /// 上一次报过的"能不能读"。只在支持状态**变化**时写一行日志（同一格式会被设好几次）。
    private static var didLogFormat = false
    private static var didLogSupportedValue = false

    /// 滤波器状态（跨块保持）。两个都是一阶低通的状态。
    private static var lowState = 0.0
    private static var highState = 0.0
    /// 慢包络（不参与输出，只给瞬态判据当基线）。
    private static var lowSlow = 0.0
    private static var highSlow = 0.0

    /// 时间只按"走过的帧数"换算：render 线程不取时间，也就不受系统时钟跳变影响。
    private static var elapsedFrames: UInt64 = 0
    private static var blocksSeen: UInt64 = 0
    private static var lastKickMs = -1.0
    private static var lastSnareMs = -1.0

    private static var kickCount: UInt64 = 0
    private static var snareCount: UInt64 = 0
    private static var callbacks: UInt64 = 0
    private static var blockFrames: UInt32 = 0
    private static var blockHostTime: UInt64 = 0

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
        if !value {
            low = 0
            high = 0
            rms = 0
            peak = 0
            lowState = 0
            highState = 0
            lowSlow = 0
            highSlow = 0
            blocksSeen = 0
            blockFrames = 0
            blockHostTime = 0
        }
        os_unfair_lock_unlock(lock)
    }

    /// 主线程读一拍（30Hz）。锁只在这一瞬间持有；render 线程那边是 `trylock`，不会互相等。
    static func snapshot() -> Snapshot {
        os_unfair_lock_lock(lock)
        let value = Snapshot(
            low: low,
            high: high,
            rms: rms,
            peak: peak,
            kickCount: kickCount,
            snareCount: snareCount,
            callbacks: callbacks,
            blockFrames: blockFrames,
            blockHostTime: blockHostTime,
            isSupported: isSupported
        )
        os_unfair_lock_unlock(lock)
        return value
    }

    /// StreamFormat 那一拍：记下采样率 / 是否交错 / 是否 float32，并把一阶低通的
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
        let alphaLow = supported
            ? 1 - exp(-2 * Double.pi * lowCutoffHz / Double(format.mSampleRate))
            : 0
        let alphaHigh = supported
            ? 1 - exp(-2 * Double.pi * highCutoffHz / Double(format.mSampleRate))
            : 0

        os_unfair_lock_lock(lock)
        // 同一个 unit 上可能先来 Spotify 内部的中间格式、后来硬件格式：float32 的那份优先，
        // 与 `AudioTapProbe` 收格式的判据一致。
        if supported || !isSupported {
            sampleRate = Double(format.mSampleRate)
            isInterleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
            isSupported = supported
            self.alphaLow = alphaLow
            self.alphaHigh = alphaHigh
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

    /// PostRender 的 PCM：算这一块的能量与瞬态。**绝不阻塞**：拿到锁就算，拿不到就丢这一拍。
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
        guard active, isSupported, sampleRate > 0 else {
            os_unfair_lock_unlock(lock)
            return noErr
        }

        elapsedFrames &+= UInt64(numberFrames)
        let buffers = UnsafeMutableAudioBufferListPointer(ioData)
        let scanFrames = min(Int(numberFrames), maxScanFrames)
        guard scanFrames > 0 else {
            os_unfair_lock_unlock(lock)
            return noErr
        }

        var lpLow = lowState
        var lpHigh = highState
        var sumLow = 0.0
        var sumHigh = 0.0
        var sumAll = 0.0
        var blockPeak = 0.0
        var readFrames = 0

        // 非交错（一个 buffer 一个声道）是 RemoteIO 的常态；交错时是"一个 buffer N 个声道、
        // 样本按声道并排"。两种都按 mono = 前两声道平均来取，尾部多出来的声道不参与。
        if !isInterleaved, buffers.count >= 2 {
            if let leftData = buffers[0].mData, let rightData = buffers[1].mData {
                let left = leftData.assumingMemoryBound(to: Float.self)
                let right = rightData.assumingMemoryBound(to: Float.self)
                let leftFrames = Int(buffers[0].mDataByteSize) / MemoryLayout<Float>.size
                let rightFrames = Int(buffers[1].mDataByteSize) / MemoryLayout<Float>.size
                let frames = min(scanFrames, min(leftFrames, rightFrames))
                var index = 0
                while index < frames {
                    let mono = (Double(left[index]) + Double(right[index])) * 0.5
                    lpLow += alphaLow * (mono - lpLow)
                    lpHigh += alphaHigh * (mono - lpHigh)
                    let lowSignal = lpLow
                    let highSignal = mono - lpHigh
                    sumLow += lowSignal * lowSignal
                    sumHigh += highSignal * highSignal
                    sumAll += mono * mono
                    let magnitude = abs(mono)
                    if magnitude > blockPeak { blockPeak = magnitude }
                    index += 1
                }
                readFrames = frames
            }
        } else if buffers.count >= 1, let data = buffers[0].mData {
            let step = max(1, Int(buffers[0].mNumberChannels))
            let samples = data.assumingMemoryBound(to: Float.self)
            let available = Int(buffers[0].mDataByteSize) / MemoryLayout<Float>.size / step
            let frames = min(scanFrames, available)
            var index = 0
            while index < frames {
                let base = index * step
                let mono: Double
                if step >= 2 {
                    mono = (Double(samples[base]) + Double(samples[base + 1])) * 0.5
                } else {
                    mono = Double(samples[base])
                }
                lpLow += alphaLow * (mono - lpLow)
                lpHigh += alphaHigh * (mono - lpHigh)
                let lowSignal = lpLow
                let highSignal = mono - lpHigh
                sumLow += lowSignal * lowSignal
                sumHigh += highSignal * highSignal
                sumAll += mono * mono
                let magnitude = abs(mono)
                if magnitude > blockPeak { blockPeak = magnitude }
                index += 1
            }
            readFrames = frames
        }

        lowState = lpLow
        highState = lpHigh

        guard readFrames > 0 else {
            os_unfair_lock_unlock(lock)
            return noErr
        }
        // 只有真的读到帧才记一拍：`callbacks` 是消费方判"有没有新数据"的唯一依据，
        // 空块也加会让引擎把上一块的电平当成新的一拍。
        callbacks &+= 1
        // 诊断用：块大小 + 这一块 PCM 的呈现时刻。两个都是整数写，render 线程不加活。
        blockFrames = numberFrames
        blockHostTime = timeStamp?.pointee.mHostTime ?? 0

        let count = Double(readFrames)
        let lowRms = (sumLow / count).squareRoot()
        let highRms = (sumHigh / count).squareRoot()
        let blockRms = (sumAll / count).squareRoot()

        let elapsedMs = Double(elapsedFrames) * 1000 / sampleRate
        blocksSeen &+= 1
        if blocksSeen > warmupBlocks {
            // 瞬态判据用的是**上一块**的慢包络：先用它判，判完再跟上，否则一次跳起会把自己抬高、
            // 下一次就判不出来。
            if blockPeak > peakFloor, lowRms > kickFloor, lowRms > lowSlow * kickRatio,
               elapsedMs - lastKickMs > kickCooldownMs {
                kickCount &+= 1
                lastKickMs = elapsedMs
            } else if blockPeak > peakFloor, highRms > snareFloor, highRms > highSlow * snareRatio,
                      elapsedMs - lastSnareMs > snareCooldownMs {
                snareCount &+= 1
                lastSnareMs = elapsedMs
            }
        }
        lowSlow += envelopeFollow * (lowRms - lowSlow)
        highSlow += envelopeFollow * (highRms - highSlow)

        low = Float(min(1, lowRms * lowDisplayGain))
        high = Float(min(1, highRms * highDisplayGain))
        rms = Float(min(1, blockRms))
        peak = Float(min(1, blockPeak))

        os_unfair_lock_unlock(lock)
        return noErr
    }
}
