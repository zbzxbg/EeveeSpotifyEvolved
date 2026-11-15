import Foundation
import AudioToolbox
// `UnsafeMutableAudioBufferListPointer` 是 CoreAudio 的 Swift 扩展类型，
// AudioToolbox 不转出它，单独 import 才可见。
import CoreAudio
import EeveeSpotifyC
import os

/// 音频输出域探针（只读诊断）。
///
/// 目标：确认 Spotify 把音乐送进 `RemoteIO` 时，我们能在
/// `AudioUnitAddRenderNotify` 的 PostRender 拿到 PCM，并看清格式（采样率 / 声道 / 位深）。
///
/// 只做两件事：
/// · `AudioUnitSetProperty` / `AudioOutputUnitStart` 两个函数 hook，记录「哪个 unit、
///   什么 component、什么格式」；
/// · RemoteIO 启动后挂一个 render notify，只读 PostRender 的 buffer，算 RMS / peak，
///   每 2 秒在**定时器**里写一行日志（render 线程里不写文件）。
///
/// 不改音频、不注册新的音频单元；拿不到数据就什么都不做。
/// 开关：设置 → 调试 → 音频输出探针（默认关；打开即装 hook，不必重启）。
/// 日志 tag：`[AudioTap]`。
///
/// 安装（fishhook 只能装一次）与 render notify 的分发都在 `AudioTapService` 里 ——
/// 这里只做"探针自己要不要算"和日志；音频驱动功能（`AudioFeatures`）是另一个消费方。
enum AudioTapProbe {

    static let logTag = "AudioTap"
    static let defaultsKey = "audioTapProbeEnabled"

    static var isEnabled: Bool {
        UserDefaults.container.bool(forKey: defaultsKey)
    }

    // MARK: - 共享状态（render 线程 / 定时器）

    /// 一把 `trylock` 的锁：render 线程永远不阻塞；拿不到锁就跳过这一拍。
    ///
    /// 用**堆上的指针**而不是 `&staticVar`：锁的地址必须稳定（它会被 audio 线程拿着），
    /// 静态变量的 `&` 在 Swift 里仍然是 inout 语义，不是 C 的取地址。
    private static let lock: UnsafeMutablePointer<os_unfair_lock> = {
        let pointer = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        pointer.initialize(to: os_unfair_lock())
        return pointer
    }()

    private static var active = false
    private static var timer: DispatchSourceTimer?

    private static var callbacks: UInt64 = 0
    private static var frames: UInt64 = 0
    private static var lastRMS: Double = 0
    private static var lastPeak: Double = 0
    private static var lastChannels: Int = 0
    private static var lastBytes: Int = 0
    private static var lastBus: UInt32 = 0
    private static var streamFormat: AudioStreamBasicDescription?
    private static var formatIsFloat = false
    private static var loggedKeys = Set<String>()

    /// 定时器上一次打过的回调数；没变化就不重复刷日志。
    private static var loggedCallbacks: UInt64 = 0
    private static var waitedTicks = 0

    // MARK: - 生命周期

    /// 调试页的开关。打开时立刻请求装 hook（异步，开关本身不等待）；音频单元已经跑起来时，
    /// 下一次 `AudioOutputUnitStart`（换歌 / 暂停再播）才会挂上 render notify。
    static func setEnabled(_ enabled: Bool) {
        UserDefaults.container.set(enabled, forKey: defaultsKey)
        if enabled { AudioTapService.ensureInstalled() }
        setActive(enabled)
    }

    /// 安装完成后由 `AudioTapService` 调一次：把 `active` 对齐到开关的当前值。
    ///
    /// 不能反过来让安装那边直接写死一个值 —— 装 hook 是异步的，那段时间里开关可能已经被关掉。
    static func syncActiveWithSetting() {
        setActive(isEnabled)
    }

    private static func setActive(_ value: Bool) {
        os_unfair_lock_lock(lock)
        active = value
        os_unfair_lock_unlock(lock)
    }

    /// 2 秒一拍的日志定时器。只在安装成功后起一次；开关关着时 `tick` 只做一次 bool 读。
    static func startTimerIfNeeded() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { tick() }
        timer.resume()
        self.timer = timer
    }

    // MARK: - hook 回调

    /// `AudioUnitSetProperty`：只读观察。StreamFormat 记格式，MakeConnection 记走向。
    static func noteSetProperty(
        unit: AudioUnit,
        id: AudioUnitPropertyID,
        scope: AudioUnitScope,
        element: AudioUnitElement,
        data: UnsafeRawPointer?,
        size: UInt32
    ) {
        if id == kAudioUnitProperty_StreamFormat,
           let data,
           size >= UInt32(MemoryLayout<AudioStreamBasicDescription>.size) {
            let format = data.load(as: AudioStreamBasicDescription.self)
            let description = componentDescription(of: unit)
            let remote = isRemoteIO(description)
            let output = isOutput(description)
            let scopeName = scope == kAudioUnitScope_Output ? "out" : (scope == kAudioUnitScope_Input ? "in" : "scope\(scope)")
            logOnce(
                "fmt-\(unit)-\(scope)-\(element)-\(format.mSampleRate)-\(format.mChannelsPerFrame)-\(format.mBitsPerChannel)-\(format.mFormatFlags)",
                "[\(logTag)] \(scopeName) format \(Int(format.mSampleRate))Hz \(format.mChannelsPerFrame)ch"
                    + " \(format.mBitsPerChannel)bit flags=\(format.mFormatFlags)"
                    + " unit=\(unit) output=\(output) remoteIO=\(remote)"
            )
            // RemoteIO 的硬件格式是通过 **input scope（bus 0）** 设进来的，不能只认 output scope；
            // 同一个 unit 上后到的 float 格式优先（先到的那条可能是 Spotify 内部的中间格式）。
            if element == 0, output {
                let isFloat = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
                os_unfair_lock_lock(lock)
                if streamFormat == nil || isFloat {
                    streamFormat = format
                    formatIsFloat = isFloat
                }
                os_unfair_lock_unlock(lock)
                // 音频驱动功能（`AudioFeatures`）读的是同一份格式：它要知道采样率（换算时间）
                // 与是否交错（怎么取 mono），这些在 render 线程上算不了。
                //
                // 只认 RemoteIO：别的输出单元（比如录制/通话那条路）也会设 StreamFormat，
                // 拿它的交错标志去解释 RemoteIO 的 buffer 会把 mono 取错。
                if remote {
                    AudioFeatures.noteFormat(format)
                }
            }
        } else if id == kAudioUnitProperty_MakeConnection,
                  let data,
                  size >= UInt32(MemoryLayout<AudioUnitConnection>.size) {
            let connection = data.load(as: AudioUnitConnection.self)
            let description = componentDescription(of: unit)
            let remote = isRemoteIO(description)
            logOnce(
                "conn-\(unit)-\(String(describing: connection.sourceAudioUnit))-\(connection.sourceOutputNumber)",
                "[\(logTag)] connection into \(describe(description)) unit=\(unit)"
                    + " from unit=\(String(describing: connection.sourceAudioUnit))"
                    + " bus=\(connection.sourceOutputNumber) remoteIO=\(remote)"
            )
        }
    }

    /// `AudioOutputUnitStart`：先放行原实现，再把 render notify 挂到 output unit 上。
    static func noteStarted(unit: AudioUnit, status: OSStatus) {
        let description = componentDescription(of: unit)
        let remote = isRemoteIO(description)
        let output = isOutput(description)
        logOnce(
            "start-\(unit)",
            "[\(logTag)] AudioOutputUnitStart \(describe(description)) unit=\(unit)"
                + " status=\(status) output=\(output) remoteIO=\(remote)"
        )
        guard output, status == noErr else { return }
        AudioTapService.installRenderNotify(on: unit)
    }

    // MARK: - render 线程

    /// 探针自己的统计（只读诊断）。`AudioTapService` 的渲染回调里调它，另一个消费方
    /// （`AudioFeatures`）有自己的一份，互不共享状态。
    static func handleRender(
        actionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        busNumber: UInt32,
        numberFrames: UInt32,
        ioData: UnsafeMutablePointer<AudioBufferList>?
    ) -> OSStatus {
        // `AudioUnitRenderActionFlags` 在 Swift 里是 OptionSet，C 侧的
        // `kAudioUnitRenderAction_PostRender` 没有导成全局常量，只有这个静态成员。
        guard actionFlags.pointee.contains(AudioUnitRenderActionFlags.unitRenderAction_PostRender) else {
            return noErr
        }
        guard let ioData else { return noErr }
        // render 线程：拿不到锁就丢掉这一拍，绝不阻塞。
        guard os_unfair_lock_trylock(lock) else { return noErr }
        guard active else {
            os_unfair_lock_unlock(lock)
            return noErr
        }

        callbacks &+= 1
        frames &+= UInt64(numberFrames)
        lastBus = busNumber

        let buffers = UnsafeMutableAudioBufferListPointer(ioData)
        var sum = 0.0
        var peak = 0.0
        var samples = 0
        var bytes = 0
        var channels = 0
        let isFloat = formatIsFloat

        for buffer in buffers {
            bytes += Int(buffer.mDataByteSize)
            // 非交错布局是「一个 buffer 一个声道」，交错是「一个 buffer N 个声道」——
            // 累加才对；取最大值在非交错时会少报成 1。
            channels += Int(buffer.mNumberChannels)
            guard isFloat, let data = buffer.mData else { continue }
            // render 线程上不值当为统计把整个 buffer 走一遍：每块最多看 256 个样本就算 RMS/peak。
            let count = min(Int(buffer.mDataByteSize) / MemoryLayout<Float>.size, 256)
            let pointer = data.assumingMemoryBound(to: Float.self)
            var index = 0
            while index < count {
                // 显式标出 Float，别让 `Double(...)` 的重载解析依赖推断。
                let sample: Float = pointer[index]
                let value = Double(sample)
                sum += value * value
                let magnitude = abs(value)
                if magnitude > peak { peak = magnitude }
                index += 1
            }
            samples += count
        }

        lastChannels = channels
        lastBytes = bytes
        if samples > 0 {
            lastRMS = (sum / Double(samples)).squareRoot()
            lastPeak = peak
        }
        os_unfair_lock_unlock(lock)
        return noErr
    }

    // MARK: - 定时器

    private static func tick() {
        guard isEnabled else {
            setActive(false)
            return
        }
        setActive(true)

        os_unfair_lock_lock(lock)
        let snapshot = (callbacks, frames, lastRMS, lastPeak, lastChannels, lastBytes, lastBus, streamFormat)
        os_unfair_lock_unlock(lock)

        if snapshot.0 == 0 {
            waitedTicks += 1
            if waitedTicks == 5 {
                writeDebugLog("[\(logTag)] no render callbacks yet — play a track and check again")
            }
            return
        }
        guard snapshot.0 != loggedCallbacks else { return }
        loggedCallbacks = snapshot.0

        let formatText: String
        if let format = snapshot.7 {
            formatText = "\(Int(format.mSampleRate))Hz \(format.mChannelsPerFrame)ch"
                + " \(format.mBitsPerChannel)bit flags=\(format.mFormatFlags)"
        } else {
            formatText = "format unknown"
        }
        // C 侧的累计调用次数：这两个 API 到底有多热，只能靠它看。
        var setPropertyCalls: UInt64 = 0
        var startCalls: UInt64 = 0
        EeveeAudioTapReadCounters(&setPropertyCalls, &startCalls)
        writeDebugLog(
            "[\(logTag)] render callbacks=\(snapshot.0) frames=\(snapshot.1)"
                + " rms=\(String(format: "%.4f", snapshot.2))"
                + " peak=\(String(format: "%.3f", snapshot.3))"
                + " ch=\(snapshot.4) bytes=\(snapshot.5) bus=\(snapshot.6)"
                + " · \(formatText)"
                + " · calls setProperty=\(setPropertyCalls) start=\(startCalls)"
        )
    }

    // MARK: - unit 识别

    private static func componentDescription(of unit: AudioUnit) -> AudioComponentDescription {
        var description = AudioComponentDescription()
        let component = AudioComponentInstanceGetComponent(unit)
        AudioComponentGetDescription(component, &description)
        return description
    }

    private static func isRemoteIO(_ description: AudioComponentDescription) -> Bool {
        description.componentType == kAudioUnitType_Output
            && description.componentSubType == kAudioUnitSubType_RemoteIO
    }

    private static func isOutput(_ description: AudioComponentDescription) -> Bool {
        description.componentType == kAudioUnitType_Output
    }

    private static func describe(_ description: AudioComponentDescription) -> String {
        "\(fourCC(description.componentType))/\(fourCC(description.componentSubType))/\(fourCC(description.componentManufacturer))"
    }

    private static func fourCC(_ value: UInt32) -> String {
        let bytes = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff),
        ]
        return String(bytes: bytes, encoding: .ascii) ?? "\(value)"
    }

    private static func logOnce(_ key: String, _ message: @autoclosure () -> String) {
        os_unfair_lock_lock(lock)
        let first = loggedKeys.insert(key).inserted
        os_unfair_lock_unlock(lock)
        guard first else { return }
        writeDebugLog(message())
    }
}
