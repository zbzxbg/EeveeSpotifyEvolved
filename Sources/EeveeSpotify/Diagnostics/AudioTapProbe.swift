import Foundation
import AudioToolbox
// `UnsafeMutableAudioBufferListPointer` 是 CoreAudio 的 Swift 扩展类型，
// AudioToolbox 不转出它，单独 import 才可见。
import CoreAudio
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
enum AudioTapProbe {

    static let logTag = "AudioTap"
    static let defaultsKey = "audioTapProbeEnabled"
    /// 探针装好后的 5 秒内如果进程就没了，下一次启动自动关掉探针（防 crash loop）。
    private static let launchMarkerKey = "audioTapProbeLaunchMarker"

    /// 装 hook 的串行队列。
    ///
    /// **装 hook 绝不能压在主线程上**。Orion 激活 hook 前要先解析目标符号，这条路走
    /// CydiaSubstrate 的 `MSFindSymbol`：它按 image 逐个解析 dyld shared cache 里的导出
    /// 符号，整个 cache 过一遍是几十秒量级的 CPU。主线程被卡住 10 秒就是 scene-update
    /// watchdog 的 `0x8BADF00D`（SIGKILL），崩溃栈正好停在
    /// `stat` ← `fileExists(atPath:)` ← `sharedCachePath()` ← `findPrivateSymbol` 这条链上。
    /// 装 hook 不需要任何 UI 资源，全部丢给这条队列；启动那一拍也一样，别在启动窗口里
    /// 拖住 runloop。
    private static let installQueue = DispatchQueue(
        label: "com.eeveespotify.audiotapprobe.install",
        qos: .userInitiated
    )

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
    private static var installed = false
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
    private static var renderUnits = Set<AudioUnit>()
    private static var loggedKeys = Set<String>()

    /// 定时器上一次打过的回调数；没变化就不重复刷日志。
    private static var loggedCallbacks: UInt64 = 0
    private static var waitedTicks = 0

    // MARK: - 生命周期

    /// 启动时调一次：开关开着才装 hook。装的动作异步丢给 `installQueue`，这里立刻返回 ——
    /// 启动窗口里不能有任何可能卡住主线程的符号解析。
    static func installIfEnabled() {
        guard isEnabled else {
            writeDebugLog("[\(logTag)] probe off — hooks not installed")
            return
        }
        if UserDefaults.container.bool(forKey: launchMarkerKey) {
            // 上一次开探针后 5 秒内进程就消失了 ⇒ 很可能是装 hook 时崩的。
            // 先关掉，别把 App 卡在启动即崩的循环里。
            UserDefaults.container.set(false, forKey: defaultsKey)
            UserDefaults.container.set(false, forKey: launchMarkerKey)
            writeDebugLog("[\(logTag)] disabled after an unclean launch — crash-loop guard")
            return
        }
        install()
    }

    /// 调试页的开关。打开时尝试当场激活 hook（异步，开关本身立刻返回）；音频单元已经
    /// 跑起来时，下一次 Start（换歌 / 暂停再播）才会挂上 render notify。
    static func setEnabled(_ enabled: Bool) {
        UserDefaults.container.set(enabled, forKey: defaultsKey)
        if enabled { install() }
        setActive(enabled)
    }

    /// 在 `installQueue` 上装 hook；调用方（主线程 / Tweak init）立刻返回。
    private static func install() {
        installQueue.async {
            guard !installed else { return }
            installed = true
            armCrashGuard()
            guard activateAudioTapProbeHooks() else {
                // 符号没解析到 ⇒ 什么都没装，别记成"装过"，下次开开关还能再试。
                installed = false
                disarmCrashGuard()
                setActive(false)
                return
            }
            // 装 hook 这段时间里用户可能已经把开关关掉，别把 `active` 又拨回去。
            setActive(isEnabled)
            startTimer()
            disarmCrashGuardAfterSurvival()
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
            writeDebugLog("[\(logTag)] armed on Spotify \(version) — AudioUnitSetProperty / AudioOutputUnitStart, read-only")
        }
    }

    /// 装之前先落 marker：这次装 hook 之后 5 秒内进程如果没了，下一次启动会看到 marker、
    /// 自动把开关关掉，不会把 App 卡在启动即崩的循环里。
    private static func armCrashGuard() {
        UserDefaults.container.set(true, forKey: launchMarkerKey)
    }

    /// 装完还活过 5 秒才算这次安全。用 main 队列是因为它只是清一个 UserDefaults 键，
    /// 顺便避开"后台队列在 App 已经被挂起后才执行"的那种情况。
    private static func disarmCrashGuardAfterSurvival() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            UserDefaults.container.set(false, forKey: launchMarkerKey)
        }
    }

    /// 根本没装上（符号没解析到）时立刻清掉 marker —— 这次没动过任何函数，不该让下次
    /// 启动白关一次开关。
    private static func disarmCrashGuard() {
        UserDefaults.container.set(false, forKey: launchMarkerKey)
    }

    private static func setActive(_ value: Bool) {
        os_unfair_lock_lock(lock)
        active = value
        os_unfair_lock_unlock(lock)
    }

    private static func startTimer() {
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
            if scope == kAudioUnitScope_Output, element == 0, output {
                os_unfair_lock_lock(lock)
                streamFormat = format
                formatIsFloat = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
                os_unfair_lock_unlock(lock)
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
        installRenderNotify(on: unit)
    }

    private static func installRenderNotify(on unit: AudioUnit) {
        os_unfair_lock_lock(lock)
        let already = renderUnits.contains(unit)
        if !already { renderUnits.insert(unit) }
        os_unfair_lock_unlock(lock)
        guard !already else { return }

        let status = AudioUnitAddRenderNotify(unit, audioTapRenderCallback, audioTapRefCon)
        writeDebugLog("[\(logTag)] AddRenderNotify unit=\(unit) status=\(status)")
    }

    // MARK: - render 线程

    fileprivate static func handleRender(
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
            channels = max(channels, Int(buffer.mNumberChannels))
            guard isFloat, let data = buffer.mData else { continue }
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
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
        writeDebugLog(
            "[\(logTag)] render callbacks=\(snapshot.0) frames=\(snapshot.1)"
                + " rms=\(String(format: "%.4f", snapshot.2))"
                + " peak=\(String(format: "%.3f", snapshot.3))"
                + " ch=\(snapshot.4) bytes=\(snapshot.5) bus=\(snapshot.6)"
                + " · \(formatText)"
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

/// render notify 的 refCon。必须是一个**活到进程结束**的非空指针；
/// 回调里不读它，只是 AudioUnit 的 API 要求成对出现。
private let audioTapRefCon: UnsafeMutableRawPointer = {
    let pointer = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
    pointer.storeBytes(of: 0, as: UInt8.self)
    return pointer
}()

/// render notify 的 C 回调。只做统计，不分配、不写文件；详情见 `handleRender`。
private func audioTapRenderCallback(
    _ refCon: UnsafeMutableRawPointer,
    _ actionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    _ timeStamp: UnsafePointer<AudioTimeStamp>,
    _ busNumber: UInt32,
    _ numberFrames: UInt32,
    _ ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    AudioTapProbe.handleRender(
        actionFlags: actionFlags,
        busNumber: busNumber,
        numberFrames: numberFrames,
        ioData: ioData
    )
}
