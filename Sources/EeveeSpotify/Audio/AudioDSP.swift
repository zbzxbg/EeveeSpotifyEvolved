import AudioToolbox
import CoreAudio
import Foundation
import os

/// 音频效果（十段图形 EQ + 低/高架 + 压缩器 + 耳机交叉馈送 + 前置增益）的 DSP 层。
///
/// 插入点：**包住源单元的 render callback**。这台机器上的音频图是「Spotify 自己的源单元
/// （回调供数据）→ 连接 → RemoteIO」：原回调把 PCM 填进 `ioData`，紧接着那个单元把数据
/// 交给 RemoteIO。所以"原回调返回之后、数据离开单元之前"是我们唯一能做到**零额外缓冲、
/// 零额外延迟**地改样本的位置。
///
/// 一条链的顺序：前置 → 低频架 → 高频架 → 十段 peaking → 压缩器 → 交叉馈送 → 限幅。
/// 架式在 ten-band 之前、压缩器在后：先定音色再压动态，压缩器看到的是用户最终想要的
/// 频谱；交叉馈送必须拿到**左右两个声道**，所以它放在逐帧层（见 `renderFrame`）。
///
/// 三条纪律：
/// · 回调包装在 tap 装好之后**总是装上**：关掉 DSP 时只是"原回调 + 一次立刻返回的空调用"，
///   这样开关可以立即生效，不必为了装/卸包装重启；
/// · render 线程上不分配、不等锁：参数用 `trylock` 拷一份到 render 本地的缓冲，拿不到锁就
///   用上一份；
/// · 系数（EQ / 架式 / 前置 / 采样率）在主线程或音频控制线程算好，render 线程只做乘加。
///
/// 块内布局由 buffer list 自己决定（一个 buffer 多声道 = 交错；多个 buffer = 非交错），
/// 不依赖格式标志：标志来自 control 线程，块却是实时线程拿到的，两者不一致时按实际布局走
/// 才不会把声道拆错。
enum AudioDSP {

    static let logTag = "AudioDSP"
    static let bandCount = AudioDSPBands.count
    /// 每组系数 5 个 double：b0, b1, b2, a1, a2。
    private static let coefficientStride = 5
    /// 只处理前两个声道：这套链路是给立体声播放用的，多声道布局其余声道原样放行。
    private static let maxChannels = 2
    private static let shelfCount = AudioDSPShelves.count
    /// 交叉馈送延迟线：最大延迟 + 1，读写下标错开一格不会撞上自己。
    private static let crossfeedRingSize = AudioDSPCrossfeed.maxDelaySamples + 1

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

    /// 控制线程侧的最后一组界面值：采样率变化时靠它们重算，不必再读 UserDefaults。
    private static var bandGainsDb = [Double](repeating: 0, count: AudioDSPBands.count)
    private static var lowShelfGainDb = 0.0
    private static var highShelfGainDb = 0.0
    private static var companderAmount = 0.0
    private static var crossfeedLevel = 0

    private static var companderParameters = AudioDSPCompander.Parameters.bypass
    private static var crossfeedSettings = AudioDSPCrossfeed.bypass

    /// 被包装过回调的源单元（只为状态提示与日志：`nil` 说明这次启动还没接管）。
    private(set) static var wrappedUnit: AudioUnit?

    private static var coefficients: UnsafeMutablePointer<Double> = makeIdentity(bandCount)
    private static var shelfCoefficients: UnsafeMutablePointer<Double> = makeIdentity(shelfCount)

    // MARK: - render 线程本地副本

    private static var renderCoefficients: UnsafeMutablePointer<Double> = makeIdentity(bandCount)
    private static var renderShelfCoefficients: UnsafeMutablePointer<Double> = makeIdentity(shelfCount)
    private static var renderTargetCoefficients: UnsafeMutablePointer<Double> = makeIdentity(bandCount)
    private static var renderShelfTargets: UnsafeMutablePointer<Double> = makeIdentity(shelfCount)

    /// 每段 / 每架 × 每声道 × 两个状态量。
    private static var renderStates: UnsafeMutablePointer<Double> = makeZeros(bandCount * maxChannels * 2)
    private static var renderShelfStates: UnsafeMutablePointer<Double> = makeZeros(shelfCount * maxChannels * 2)

    /// 每个声道一个压缩器包络。
    private static var renderCompanderEnvelopes: UnsafeMutablePointer<Double> = makeZeros(maxChannels)
    private static var renderCompanderParameters = AudioDSPCompander.Parameters.bypass
    private static var renderCompanderMix = 0.0
    private static var renderCompanderTargetMix = 0.0

    /// 交叉馈送：混入量逐块平滑；低通系数与延迟按采样率算好，直接换。
    private static var renderCrossfeedFeed = 0.0
    private static var renderCrossfeedTargetFeed = 0.0
    private static var renderCrossfeedCoefficient = 0.0
    private static var renderCrossfeedDelay = 1
    private static var renderCrossfeedStates: UnsafeMutablePointer<Double> = makeZeros(maxChannels)
    private static var renderCrossfeedDelayLineLeft: UnsafeMutablePointer<Double> = makeZeros(crossfeedRingSize)
    private static var renderCrossfeedDelayLineRight: UnsafeMutablePointer<Double> = makeZeros(crossfeedRingSize)
    private static var renderCrossfeedIndex = 0

    /// 每个块（≈23ms）把"当前系数"往"目标系数"拉近的比例。
    ///
    /// 0.25 ⇒ 大约 4 个块（≈90ms）走完九成。拖滑杆时必须这样过渡：直接换系数会让滤波器的
    /// 状态与冲激响应同时突变，听起来就是一格一格的咔哒声。
    private static let coefficientSmoothing = 0.25

    private static var renderEnabled = false
    /// 这一块要不要真的处理。与 `renderEnabled` 分开：关开关时先淡出到恒等，再退出处理。
    private static var renderActive = false
    private static var renderPreamp = 1.0
    private static var renderTargetPreamp = 1.0
    private static var renderResetSeen: UInt32 = 0
    private static var statesResetRequested = false
    private static var renderBroken = false
    /// render 线程置位、主线程读：出过一次非有限样本就让刻度旁路，并只报一行。
    fileprivate static var brokenFlag = false

    private static var didReportBroken = false
    private static var didLogWrapped = false
    private static var didLogFormat = false
    private static var didLogActive = false
    private static var ticker: DispatchSourceTimer?

    // MARK: - 内存

    /// 一组恒等系数（每项 b0 = 1，其余 0）。全 0 会让输出恒为 0。
    private static func makeIdentity(_ count: Int) -> UnsafeMutablePointer<Double> {
        let pointer = UnsafeMutablePointer<Double>.allocate(capacity: max(count, 1) * coefficientStride)
        pointer.initialize(repeating: 0, count: max(count, 1) * coefficientStride)
        for index in 0..<count {
            pointer[index * coefficientStride] = 1
        }
        return pointer
    }

    private static func makeZeros(_ count: Int) -> UnsafeMutablePointer<Double> {
        let capacity = max(count, 1)
        let pointer = UnsafeMutablePointer<Double>.allocate(capacity: capacity)
        pointer.initialize(repeating: 0, count: capacity)
        return pointer
    }

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
    ///
    /// 这里**不清滤波状态**（除非开关状态或交叉馈送档位变了）：状态清零会砍掉正在衰减的
    /// 尾巴，拖动滑杆时每个事件一次、听起来就是连续的咔哒。系数本身由 render 侧逐块
    /// 平滑过去（见 `process`）。
    static func reloadParameters() {
        let bands = UserDefaults.dspBandGainsDb
        let preampDb = UserDefaults.dspPreampDb
        let lowShelf = UserDefaults.dspLowShelfDb
        let highShelf = UserDefaults.dspHighShelfDb
        let compander = UserDefaults.dspCompanderAmount
        let crossfeed = UserDefaults.dspCrossfeedLevel
        let newEnabled = UserDefaults.dspEnabled

        os_unfair_lock_lock(lock)
        if newEnabled != enabled {
            enabled = newEnabled
            resetCounter &+= 1
        }
        if crossfeed != crossfeedLevel {
            // 档位一换，环形缓冲里装的是"旧延迟"的样本，直接清掉比听一段错位的过渡好。
            crossfeedLevel = crossfeed
            resetCounter &+= 1
        }
        preampLinear = pow(10, preampDb / 20)
        bandGainsDb = bands
        lowShelfGainDb = lowShelf
        highShelfGainDb = highShelf
        companderAmount = compander
        if sampleRate > 0 {
            recomputeCoefficientsLocked()
        }
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

        var line: String?
        os_unfair_lock_lock(lock)
        let matchesWrapped = wrappedUnit == nil ? !isOutputUnit : wrappedUnit == unit
        if matchesWrapped {
            sourceFormat = format
            sampleRate = format.mSampleRate
            recomputeCoefficientsLocked()
            resetCounter &+= 1
            if !didLogFormat {
                didLogFormat = true
                let interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
                line = "[\(logTag)] source format \(Int(format.mSampleRate))Hz"
                    + " \(format.mChannelsPerFrame)ch interleaved=\(interleaved)"
            }
        }
        os_unfair_lock_unlock(lock)

        if let line { writeDebugLog(line) }
    }

    /// 包装回调时由 C 侧转进来记一下 unit，并按已记下的格式激活参数。
    fileprivate static func noteWrappedUnit(_ unit: AudioUnit) {
        var line: String?
        os_unfair_lock_lock(lock)
        wrappedUnit = unit
        if let format = sourceFormat, format.mSampleRate > 0 {
            sampleRate = format.mSampleRate
            recomputeCoefficientsLocked()
            resetCounter &+= 1
        }
        if !didLogWrapped {
            didLogWrapped = true
            line = "[\(logTag)] wrapped the source render callback (unit=\(unit)) — pass-through until enabled"
        }
        os_unfair_lock_unlock(lock)

        if let line { writeDebugLog(line) }
    }

    /// 重算 10 段 peaking、两个架式、压缩器参数与交叉馈送设置（持锁调用）。
    private static func recomputeCoefficientsLocked() {
        guard sampleRate > 0 else { return }

        for band in 0..<bandCount {
            let raw = band < bandGainsDb.count ? bandGainsDb[band] : 0
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

        let shelfGains = [lowShelfGainDb, highShelfGainDb]
        for shelf in 0..<shelfCount {
            let raw = shelf < shelfGains.count ? shelfGains[shelf] : 0
            let gain = min(max(raw, AudioDSPShelves.minGainDb), AudioDSPShelves.maxGainDb)
            let c = shelf == 0
                ? BiquadCoefficients.lowShelf(
                    frequency: AudioDSPShelves.lowFrequency,
                    gainDb: gain,
                    slope: AudioDSPShelves.slope,
                    sampleRate: sampleRate
                )
                : BiquadCoefficients.highShelf(
                    frequency: AudioDSPShelves.highFrequency,
                    gainDb: gain,
                    slope: AudioDSPShelves.slope,
                    sampleRate: sampleRate
                )
            let base = shelf * coefficientStride
            shelfCoefficients[base] = c.b0
            shelfCoefficients[base + 1] = c.b1
            shelfCoefficients[base + 2] = c.b2
            shelfCoefficients[base + 3] = c.a1
            shelfCoefficients[base + 4] = c.a2
        }

        companderParameters = AudioDSPCompander.parameters(amount: companderAmount, sampleRate: sampleRate)
        crossfeedSettings = AudioDSPCrossfeed.settings(level: crossfeedLevel, sampleRate: sampleRate)
    }

    private static func startTickerIfNeeded() {
        guard ticker == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { tick() }
        timer.resume()
        ticker = timer
    }

    /// 主线程每 5 秒看两眼：效果链是不是真的在跑、有没有把自己旁路了。各只报一次。
    private static func tick() {
        if !didLogActive, isEnabled, isInsertActive {
            didLogActive = true
            writeDebugLog(
                "[\(logTag)] chain active — preamp, \(shelfCount) shelves, \(bandCount) bands,"
                    + " compander and crossfeed run on every block"
            )
        }
        guard brokenFlag, !didReportBroken else { return }
        didReportBroken = true
        writeDebugLog(
            "[\(logTag)] chain bypassed itself — a non-finite sample came out; output passes through"
        )
    }

    // MARK: - render 线程

    /// 原回调已经把 PCM 填进 `ioData` 了：在这里就地改样本。
    ///
    /// 开 / 关都不是"立刻切"：打开时从恒等系数淡入，关掉时先把系数拉回恒等再停处理。
    /// 否则"处理 ⇄ 不处理"的突变本身就是一声咔哒。
    fileprivate static func process(ioData: UnsafeMutableRawPointer?, numberFrames: UInt32) {
        guard let ioData, numberFrames > 0 else { return }

        if os_unfair_lock_trylock(lock) {
            if enabled {
                copy(coefficients, to: renderTargetCoefficients, count: bandCount)
                copy(shelfCoefficients, to: renderShelfTargets, count: shelfCount)
                renderTargetPreamp = preampLinear
                renderCompanderParameters = companderParameters
                renderCompanderTargetMix = companderParameters.isBypass ? 0 : 1
                renderCrossfeedTargetFeed = crossfeedSettings.feed
                renderCrossfeedCoefficient = crossfeedSettings.lowpassCoefficient
                renderCrossfeedDelay = crossfeedSettings.delaySamples
            } else {
                // 关闭时的目标 = 恒等：系数往恒等滑，信号就淡回原声。
                setTargetsIdentity()
            }
            renderEnabled = enabled
            if resetCounter != renderResetSeen {
                renderResetSeen = resetCounter
                statesResetRequested = true
            }
            os_unfair_lock_unlock(lock)
        }

        if renderEnabled, !renderActive {
            // 刚打开：把"当前系数"放回恒等再往目标滑，效果是淡入而不是硬切。
            renderActive = true
            statesResetRequested = true
            setIdentityCoefficients()
        }

        if statesResetRequested {
            statesResetRequested = false
            renderBroken = false
            resetStates()
        }
        guard renderActive else { return }

        smoothTowardsTarget()

        if renderBroken { return }
        if !renderEnabled, isCurrentIdentity() {
            // 淡出已经走完：之后每块只剩一次 trylock。
            renderActive = false
            resetStates()
            return
        }

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

    private static func copy(_ source: UnsafeMutablePointer<Double>,
                             to destination: UnsafeMutablePointer<Double>,
                             count: Int) {
        for index in 0..<(count * coefficientStride) {
            destination[index] = source[index]
        }
    }

    private static func resetStates() {
        for index in 0..<(bandCount * maxChannels * 2) {
            renderStates[index] = 0
        }
        for index in 0..<(shelfCount * maxChannels * 2) {
            renderShelfStates[index] = 0
        }
        for channel in 0..<maxChannels {
            renderCompanderEnvelopes[channel] = 0
            renderCrossfeedStates[channel] = 0
        }
        for index in 0..<crossfeedRingSize {
            renderCrossfeedDelayLineLeft[index] = 0
            renderCrossfeedDelayLineRight[index] = 0
        }
        renderCrossfeedIndex = 0
    }

    /// 把"当前"系数摆成恒等（b0 = 1，其余 0），前置 1.0、压缩器与交叉馈送退到 0 ——
    /// 逐位等于原声。
    private static func setIdentityCoefficients() {
        for band in 0..<bandCount {
            setIdentity(renderCoefficients, index: band)
        }
        for shelf in 0..<shelfCount {
            setIdentity(renderShelfCoefficients, index: shelf)
        }
        renderPreamp = 1
        renderCompanderMix = 0
        renderCrossfeedFeed = 0
    }

    private static func setTargetsIdentity() {
        for band in 0..<bandCount {
            setIdentity(renderTargetCoefficients, index: band)
        }
        for shelf in 0..<shelfCount {
            setIdentity(renderShelfTargets, index: shelf)
        }
        renderTargetPreamp = 1
        renderCompanderTargetMix = 0
        renderCrossfeedTargetFeed = 0
    }

    private static func setIdentity(_ coefficients: UnsafeMutablePointer<Double>, index: Int) {
        let base = index * coefficientStride
        coefficients[base] = 1
        coefficients[base + 1] = 0
        coefficients[base + 2] = 0
        coefficients[base + 3] = 0
        coefficients[base + 4] = 0
    }

    private static func isIdentity(_ coefficients: UnsafeMutablePointer<Double>, index: Int) -> Bool {
        let base = index * coefficientStride
        if abs(coefficients[base] - 1) > 1e-6 { return false }
        for offset in 1..<coefficientStride where abs(coefficients[base + offset]) > 1e-6 {
            return false
        }
        return true
    }

    /// 淡出是否已经到位（系数全恒等、前置 1.0、压缩器与交叉馈送都到 0）。
    private static func isCurrentIdentity() -> Bool {
        for band in 0..<bandCount where !isIdentity(renderCoefficients, index: band) {
            return false
        }
        for shelf in 0..<shelfCount where !isIdentity(renderShelfCoefficients, index: shelf) {
            return false
        }
        return abs(renderPreamp - 1) <= 1e-6
            && abs(renderCompanderMix) <= 1e-6
            && abs(renderCrossfeedFeed) <= 1e-6
    }

    /// 逐块把"当前系数 / 前置 / 两个混入量"往目标推一步。
    ///
    /// 这是"拖滑杆不咔哒"的关键：直接换系数等于让滤波器的冲激响应瞬间跳变，听感就是一格
    /// 一格的脆响。这里的步长很小（滑杆一档 0.5 dB），插值出来的中间系数仍在稳定范围内。
    private static func smoothTowardsTarget() {
        smooth(renderCoefficients, towards: renderTargetCoefficients, count: bandCount)
        smooth(renderShelfCoefficients, towards: renderShelfTargets, count: shelfCount)

        let preampDifference = renderTargetPreamp - renderPreamp
        renderPreamp = abs(preampDifference) < 1e-6
            ? renderTargetPreamp
            : renderPreamp + preampDifference * coefficientSmoothing

        let mixDifference = renderCompanderTargetMix - renderCompanderMix
        renderCompanderMix = abs(mixDifference) < 1e-6
            ? renderCompanderTargetMix
            : renderCompanderMix + mixDifference * coefficientSmoothing

        let feedDifference = renderCrossfeedTargetFeed - renderCrossfeedFeed
        renderCrossfeedFeed = abs(feedDifference) < 1e-6
            ? renderCrossfeedTargetFeed
            : renderCrossfeedFeed + feedDifference * coefficientSmoothing
    }

    private static func smooth(_ current: UnsafeMutablePointer<Double>,
                               towards target: UnsafeMutablePointer<Double>,
                               count: Int) {
        let total = count * coefficientStride
        for index in 0..<total {
            let difference = target[index] - current[index]
            current[index] = abs(difference) < 1e-7
                ? target[index]
                : current[index] + difference * coefficientSmoothing
        }
    }

    private static func processInterleaved(buffer: AudioBuffer, frames: Int) {
        guard let raw = buffer.mData else { return }
        let channelCount = Int(buffer.mNumberChannels)
        guard channelCount >= 1 else { return }
        let samples = raw.assumingMemoryBound(to: Float.self)
        let available = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
        let total = min(frames * channelCount, available)
        let stereo = channelCount >= 2

        var frame = 0
        while frame * channelCount < total {
            let base = frame * channelCount
            let leftInput = Double(samples[base])
            let rightInput = stereo ? Double(samples[base + 1]) : nil
            let (left, right) = renderFrame(left: leftInput, right: rightInput)
            samples[base] = left
            if stereo, let right { samples[base + 1] = right }
            frame += 1
        }
    }

    private static func processPlanar(buffers: UnsafeMutableAudioBufferListPointer, frames: Int) {
        let usable = min(buffers.count, maxChannels)
        guard usable >= 1, let leftRaw = buffers[0].mData else { return }

        let left = leftRaw.assumingMemoryBound(to: Float.self)
        let leftAvailable = Int(buffers[0].mDataByteSize) / MemoryLayout<Float>.size
        let rightRaw: UnsafeMutableRawPointer? = usable >= 2 ? buffers[1].mData : nil
        let right = rightRaw?.assumingMemoryBound(to: Float.self)
        let rightAvailable = right == nil
            ? frames
            : Int(buffers[1].mDataByteSize) / MemoryLayout<Float>.size
        let frameCount = min(frames, min(leftAvailable, rightAvailable))

        for index in 0..<frameCount {
            let rightInput = right.map { Double($0[index]) }
            let (leftValue, rightValue) = renderFrame(left: Double(left[index]), right: rightInput)
            left[index] = leftValue
            if let right, let rightValue { right[index] = rightValue }
        }
    }

    /// 一帧：两个声道各过一遍链，然后做一次交叉馈送，最后限幅。
    @inline(__always)
    private static func renderFrame(left: Double, right: Double?) -> (Float, Float?) {
        var leftValue = processChannel(left * renderPreamp, channel: 0)
        var rightValue = right.map { processChannel($0 * renderPreamp, channel: 1) }

        if let currentRight = rightValue, renderCrossfeedFeed > 1e-4 {
            // 读"延迟 N 拍之前的对侧样本"，再把这一拍的样本写进环形缓冲。
            let index = renderCrossfeedIndex
            let readIndex = (index + crossfeedRingSize - renderCrossfeedDelay) % crossfeedRingSize
            let delayedRight = renderCrossfeedDelayLineRight[readIndex]
            let delayedLeft = renderCrossfeedDelayLineLeft[readIndex]
            renderCrossfeedDelayLineLeft[index] = leftValue
            renderCrossfeedDelayLineRight[index] = currentRight
            renderCrossfeedIndex = index + 1 == crossfeedRingSize ? 0 : index + 1

            // 一阶低通：模拟头颅对高频的遮蔽；两个声道各一份状态。
            let coefficient = renderCrossfeedCoefficient
            renderCrossfeedStates[0] += (delayedRight - renderCrossfeedStates[0]) * coefficient
            renderCrossfeedStates[1] += (delayedLeft - renderCrossfeedStates[1]) * coefficient
            leftValue += renderCrossfeedFeed * renderCrossfeedStates[0]
            rightValue = currentRight + renderCrossfeedFeed * renderCrossfeedStates[1]
        }

        guard leftValue.isFinite, rightValue?.isFinite ?? true else {
            markBroken()
            return (0, rightValue == nil ? nil : 0)
        }
        return (
            Float(min(max(leftValue, -1), 1)),
            rightValue.map { Float(min(max($0, -1), 1)) }
        )
    }

    /// 一个声道走完"前置 → 低频架 → 高频架 → 十段 → 压缩器"。
    @inline(__always)
    private static func processChannel(_ input: Double, channel: Int) -> Double {
        var value = input

        var shelfStateIndex = channel * 2
        for shelf in 0..<shelfCount {
            let base = shelf * coefficientStride
            let b0 = renderShelfCoefficients[base]
            let b1 = renderShelfCoefficients[base + 1]
            let b2 = renderShelfCoefficients[base + 2]
            let a1 = renderShelfCoefficients[base + 3]
            let a2 = renderShelfCoefficients[base + 4]
            let z1 = renderShelfStates[shelfStateIndex]
            let z2 = renderShelfStates[shelfStateIndex + 1]
            let y = b0 * value + z1
            var nextZ1 = b1 * value + (-a1) * y + z2
            var nextZ2 = b2 * value + (-a2) * y
            if abs(nextZ1) < 1e-15 { nextZ1 = 0 }
            if abs(nextZ2) < 1e-15 { nextZ2 = 0 }
            renderShelfStates[shelfStateIndex] = nextZ1
            renderShelfStates[shelfStateIndex + 1] = nextZ2
            value = y
            shelfStateIndex += maxChannels * 2
        }

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
            var nextZ1 = b1 * value + (-a1) * y + z2
            var nextZ2 = b2 * value + (-a2) * y
            if abs(nextZ1) < 1e-15 { nextZ1 = 0 }
            if abs(nextZ2) < 1e-15 { nextZ2 = 0 }
            renderStates[stateIndex] = nextZ1
            renderStates[stateIndex + 1] = nextZ2
            value = y
            stateIndex += maxChannels * 2
        }

        if renderCompanderMix > 1e-4 || renderCompanderTargetMix > 1e-4 {
            var envelope = AudioDSPCompander.Envelope(magnitude: renderCompanderEnvelopes[channel])
            let gain = envelope.gain(for: value, parameters: renderCompanderParameters)
            renderCompanderEnvelopes[channel] = envelope.magnitude
            let wet = value * gain
            value += (wet - value) * renderCompanderMix
        }
        return value
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
