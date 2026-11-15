import AudioToolbox
import CoreAudio
import Foundation
import os

/// 音频效果（十段图形 EQ + 前置增益）的 DSP 层。
///
/// 插入点：**包住源单元的 render callback**。这台机器上的音频图是「Spotify 自己的源单元
/// （回调供数据）→ 连接 → RemoteIO」：原回调把 PCM 填进 `ioData`，紧接着那个单元把数据
/// 交给 RemoteIO。所以"原回调返回之后、数据离开单元之前"是我们唯一能做到**零额外缓冲、
/// 零额外延迟**地改样本的位置。
///
/// 三条纪律：
/// · 回调包装在 tap 装好之后**总是装上**：关掉 DSP 时只是"原回调 + 一次立刻返回的空调用"，
///   这样开关可以立即生效，不必为了装/卸包装重启；
/// · render 线程上不分配、不等锁：参数用 `trylock` 拷一份到 render 本地的缓冲，拿不到锁就
///   用上一份；
/// · 系数（EQ / 前置 / 采样率）在主线程或音频控制线程算好，render 线程只做乘加。
///
/// 块内布局由 buffer list 自己决定（一个 buffer 多声道 = 交错；多个 buffer = 非交错），
/// 不依赖格式标志：标志来自 control 线程，块却是实时线程拿到的，两者不一致时按实际布局走
/// 才不会把声道拆错。
enum AudioDSP {

    static let logTag = "AudioDSP"
    static let bandCount = AudioDSPBands.count
    /// 每组系数 5 个 double：b0, b1, b2, a1, a2。
    private static let coefficientStride = 5
    /// 只处理前两个声道：这套 EQ 是给立体声播放用的，多声道布局其余声道原样放行。
    private static let maxChannels = 2

    private static let lock: UnsafeMutablePointer<os_unfair_lock> = {
        let pointer = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        pointer.initialize(to: os_unfair_lock())
        return pointer
    }()

    // MARK: - 参数（主线程 / 音频控制线程写，render 线程 trylock 拷贝）

    private static var enabled = false
    private static var preampLinear = 1.0
    private static var sampleRate = 0.0
    /// 每次参数变化 +1：render 发现它变了就清滤波状态（避免旧参数下的振铃带进新参数）。
    private static var resetCounter: UInt32 = 0
    private static var sourceFormat: AudioStreamBasicDescription?

    /// 被包装过回调的源单元（只为状态提示与日志：`nil` 说明这次启动还没接管）。
    private(set) static var wrappedUnit: AudioUnit?

    private static var coefficients: UnsafeMutablePointer<Double> = {
        let count = AudioDSPBands.count * 5
        let pointer = UnsafeMutablePointer<Double>.allocate(capacity: count)
        pointer.initialize(repeating: 0, count: count)
        // 初始 = 每段直通（b0 = 1，其余 0）。全 0 会让输出恒为 0。
        for band in 0..<AudioDSPBands.count {
            pointer[band * 5] = 1
        }
        return pointer
    }()

    // MARK: - render 线程本地副本

    private static var renderCoefficients: UnsafeMutablePointer<Double> = {
        let count = AudioDSPBands.count * 5
        let pointer = UnsafeMutablePointer<Double>.allocate(capacity: count)
        pointer.initialize(repeating: 0, count: count)
        for band in 0..<AudioDSPBands.count {
            pointer[band * 5] = 1
        }
        return pointer
    }()

    /// 每段 × 每声道 × 两个状态量。
    private static var renderStates: UnsafeMutablePointer<Double> = {
        let count = AudioDSPBands.count * 2 * 2
        let pointer = UnsafeMutablePointer<Double>.allocate(capacity: count)
        pointer.initialize(repeating: 0, count: count)
        return pointer
    }()

    private static var renderEnabled = false
    private static var renderPreamp = 1.0
    private static var renderResetSeen: UInt32 = 0
    private static var renderBroken = false
    /// render 线程置位、主线程读：出过一次非有限样本就让刻度旁路，并只报一行。
    fileprivate static var brokenFlag = false

    private static var didReportBroken = false
    private static var ticker: DispatchSourceTimer?

    // MARK: - 状态

    /// 开关（UserDefaults 的那一颗）。
    static var isEnabled: Bool { UserDefaults.dspEnabled }

    /// 这次启动有没有真的接管音频输出。开关开着但这里是 false ⇒ 音频图是在开关生效之前
    /// 建好的，要重启 Spotify 才会走到我们的包装。
    static var isInsertActive: Bool { wrappedUnit != nil }

    // MARK: - 生命周期

    /// 启动 / 开关 / 设置页改动后调一次；幂等。
    static func syncWithSettings() {
        if isEnabled {
            // 钩子只在有消费者时才装；DSP 打开时也要算一个消费者。
            AudioTapService.ensureInstalled()
        }
        reloadParameters()
        startTickerIfNeeded()
    }

    /// 把 UserDefaults 里的参数读进来重算系数（主线程）。滑杆每动一下就调。
    static func reloadParameters() {
        let bands = UserDefaults.dspBandGainsDb
        let preampDb = UserDefaults.dspPreampDb

        os_unfair_lock_lock(lock)
        enabled = UserDefaults.dspEnabled
        preampLinear = pow(10, preampDb / 20)
        if sampleRate > 0 {
            recomputeCoefficientsLocked(bands: bands, sampleRate: sampleRate)
        }
        resetCounter &+= 1
        os_unfair_lock_unlock(lock)
    }

    /// StreamFormat 那一拍（音频控制线程）。
    ///
    /// 只认"源单元"那一路：包装回调之前先记下最近一个**非输出单元**的格式；包装之后再
    /// 只接受同一个 unit 的格式更新。RemoteIO 的格式是硬件格式，拿来解释源单元的块没有意义。
    static func noteFormat(unit: AudioUnit, format: AudioStreamBasicDescription, isOutputUnit: Bool) {
        guard format.mSampleRate > 0 else { return }
        guard format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32 else { return }

        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }

        if let current = wrappedUnit {
            guard current == unit else { return }
        } else if isOutputUnit {
            return
        }

        sourceFormat = format
        sampleRate = format.mSampleRate
        recomputeCoefficientsLocked(bands: UserDefaults.dspBandGainsDb, sampleRate: sampleRate)
        resetCounter &+= 1
    }

    /// 包装回调时由 C 侧转进来记一下 unit，并按已记下的格式激活参数。
    fileprivate static func noteWrappedUnit(_ unit: AudioUnit) {
        os_unfair_lock_lock(lock)
        wrappedUnit = unit
        if let format = sourceFormat, format.mSampleRate > 0 {
            sampleRate = format.mSampleRate
            recomputeCoefficientsLocked(bands: UserDefaults.dspBandGainsDb, sampleRate: sampleRate)
            resetCounter &+= 1
        }
        os_unfair_lock_unlock(lock)
    }

    private static func recomputeCoefficientsLocked(bands: [Double], sampleRate: Double) {
        for band in 0..<bandCount {
            let raw = band < bands.count ? bands[band] : 0
            let gain = min(max(raw, AudioDSPBands.minGainDb), AudioDSPBands.maxGainDb)
            let c = BiquadCoefficients.peaking(
                frequency: AudioDSPBands.frequencies[band],
                gainDb: gain,
                q: AudioDSPBands.q,
                sampleRate: sampleRate
            )
            let base = band * coefficientStride
            coefficients[base] = c.b0
            coefficients[base + 1] = c.b1
            coefficients[base + 2] = c.b2
            coefficients[base + 3] = c.a1
            coefficients[base + 4] = c.a2
        }
    }

    private static func startTickerIfNeeded() {
        guard ticker == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { tick() }
        timer.resume()
        ticker = timer
    }

    /// 主线程每 5 秒看一眼 render 侧有没有"把自己旁路了"。只报一次。
    private static func tick() {
        guard brokenFlag, !didReportBroken else { return }
        didReportBroken = true
        writeDebugLog(
            "[\(logTag)] chain bypassed itself — a non-finite sample came out; output passes through"
        )
    }

    // MARK: - render 线程

    /// 原回调已经把 PCM 填进 `ioData` 了：在这里就地改样本。
    fileprivate static func process(ioData: UnsafeMutableRawPointer?, numberFrames: UInt32) {
        guard let ioData, numberFrames > 0, !renderBroken else { return }

        if os_unfair_lock_trylock(lock) {
            let count = bandCount * coefficientStride
            for index in 0..<count {
                renderCoefficients[index] = coefficients[index]
            }
            renderEnabled = enabled
            renderPreamp = preampLinear
            if resetCounter != renderResetSeen {
                renderResetSeen = resetCounter
                let states = bandCount * maxChannels * 2
                for index in 0..<states {
                    renderStates[index] = 0
                }
                renderBroken = false
            }
            os_unfair_lock_unlock(lock)
        }

        guard renderEnabled else { return }

        let buffers = UnsafeMutableAudioBufferListPointer(
            ioData.assumingMemoryBound(to: AudioBufferList.self)
        )
        let frames = Int(numberFrames)
        guard buffers.count >= 1 else { return }

        if buffers.count == 1 {
            // 交错（或多声道挤在一个 buffer 里）：L R L R …
            processInterleaved(buffer: buffers[0], frames: frames)
        } else {
            // 非交错：一个 buffer 一个声道。
            processPlanar(buffers: buffers, frames: frames)
        }
    }

    private static func processInterleaved(buffer: AudioBuffer, frames: Int) {
        guard let raw = buffer.mData else { return }
        let channelCount = Int(buffer.mNumberChannels)
        guard channelCount >= 1 else { return }
        let usableChannels = min(channelCount, maxChannels)
        let samples = raw.assumingMemoryBound(to: Float.self)
        let available = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
        let total = min(frames * channelCount, available)

        var index = 0
        while index < total {
            let channel = index % channelCount
            if channel < usableChannels {
                let processed = processSample(Double(samples[index]), channel: channel)
                samples[index] = Float(processed)
            }
            index += 1
        }
    }

    private static func processPlanar(buffers: UnsafeMutableAudioBufferListPointer, frames: Int) {
        let usable = min(buffers.count, maxChannels)
        guard usable >= 1 else { return }
        var channel = 0
        while channel < usable {
            defer { channel += 1 }
            guard let raw = buffers[channel].mData else { continue }
            let samples = raw.assumingMemoryBound(to: Float.self)
            let available = Int(buffers[channel].mDataByteSize) / MemoryLayout<Float>.size
            let total = min(frames, available)
            var index = 0
            while index < total {
                let processed = processSample(Double(samples[index]), channel: channel)
                samples[index] = Float(processed)
                index += 1
            }
        }
    }

    /// 一个样本走完"前置 → 十段级联 → 限幅"。非有限值会让整条链旁路（见 `markBroken`）。
    @inline(__always)
    private static func processSample(_ input: Double, channel: Int) -> Float {
        var value = input * renderPreamp
        var stateIndex = channel * 2
        for band in 0..<bandCount {
            let base = band * coefficientStride
            let b0 = renderCoefficients[base]
            let b1 = renderCoefficients[base + 1]
            let b2 = renderCoefficients[base + 2]
            let a1 = renderCoefficients[base + 3]
            let a2 = renderCoefficients[base + 4]
            let z1 = renderStates[stateIndex]
            let z2 = renderStates[stateIndex + 1]
            let y = b0 * value + z1
            var nextZ1 = b1 * value - a1 * y + z2
            var nextZ2 = b2 * value - a2 * y
            if abs(nextZ1) < 1e-15 { nextZ1 = 0 }
            if abs(nextZ2) < 1e-15 { nextZ2 = 0 }
            renderStates[stateIndex] = nextZ1
            renderStates[stateIndex + 1] = nextZ2
            value = y
            stateIndex += maxChannels * 2
        }
        guard value.isFinite else {
            markBroken()
            return 0
        }
        return Float(min(max(value, -1), 1))
    }

    private static func markBroken() {
        renderBroken = true
        brokenFlag = true
    }
}

// MARK: - C 桥

/// C 侧在 `SetRenderCallback` 那一拍问：要不要用我们的回调包住它。
///
/// 只要 tap 装好了就返回 1 —— 开关（`dspEnabled`）只决定 render 时处不处理，不决定包不包。
/// 这样"打开 DSP"不必重新等一次音频图重建。
@_cdecl("EeveeAudioDSPShouldWrapCallback")
public func eeveeAudioDSPShouldWrapCallback(_ unit: UnsafeMutableRawPointer?) -> Int32 {
    guard let unit else { return 0 }
    AudioDSP.noteWrappedUnit(unsafeBitCast(unit, to: AudioUnit.self))
    return 1
}

/// C 侧的包装回调在调用完原回调之后进来，就地处理 `ioData`。
@_cdecl("EeveeAudioDSPProcess")
public func eeveeAudioDSPProcess(_ ioData: UnsafeMutableRawPointer?, _ numberFrames: UInt32) {
    AudioDSP.process(ioData: ioData, numberFrames: numberFrames)
}
