import AudioToolbox
import CoreAudio
import Foundation
import os

/// 一次性的音频观察服务。
///
/// 为什么要有这一层：fishhook 的 `rebind_symbols` 只改 `__la_symbol_ptr`（数据段）里的指针值，
/// **一个进程只能装一次** —— 它把这一组 rebindings 记着给后加载的 image 复用，再装一次属于
/// 未定义行为。而"谁要这份 PCM"现在有两个消费方，各有各的开关：
/// · 只读诊断探针（`AudioTapProbe`，设置 → 调试）；
/// · 音频驱动功能（`AudioFeatures`，封面律动 / 音乐触感）。
///
/// ⇒ 安装从这里统一发起（谁先需要就装），渲染回调也从这里分发；两边的状态完全独立，
/// 一个关掉不影响另一个。
enum AudioTapService {

    /// 日志 tag 沿用 `[AudioTap]`：这一族日志在排查时是同一件事的两个阶段。
    static let logTag = AudioTapProbe.logTag

    /// 装 hook 的串行队列。
    ///
    /// 装一次要遍历所有已加载 image 的 `__la_symbol_ptr` 再改指针值，是短任务，但它
    /// **不该压在主线程上**：主线程在 scene-update 窗口里被卡住 10 秒，watchdog 就会以
    /// `0x8BADF00D` 直接 SIGKILL。装 hook 不需要任何 UI 资源，全部丢给这条队列。
    private static let installQueue = DispatchQueue(
        label: "com.eeveespotify.audiotapservice.install",
        qos: .userInitiated
    )

    /// 装之前落下的 marker：这次装完 5 秒内进程就没了 ⇒ 下一次启动把**所有**依赖 hook 的
    /// 开关一起关掉，别把 App 卡在"启动即崩"的循环里。
    private static let launchMarkerKey = "audioTapLaunchMarker"
    /// 旧版探针单独用的 marker 键。升级过来的机器上可能还留着，跟着一起认、一起清。
    private static let legacyLaunchMarkerKey = "audioTapProbeLaunchMarker"

    /// 保护 `hooksReady` / `renderUnits`：`AudioOutputUnitStart` 的替换函数跑在音频控制线程上。
    private static let lock: UnsafeMutablePointer<os_unfair_lock> = {
        let pointer = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        pointer.initialize(to: os_unfair_lock())
        return pointer
    }()

    private static var installed = false
    private static var hooksReady = false
    private static var renderUnits = Set<AudioUnit>()

    /// 两个消费方里任意一个开着就需要 hook。
    static var isWanted: Bool { AudioTapProbe.isEnabled || AudioReactiveEngine.isWanted }

    /// 启动时调一次（在 `Tweak.x.swift` 的 `return` 之前）。
    static func startAtLaunch() {
        if recoverAfterUncleanLaunch() { return }
        guard isWanted else {
            writeDebugLog("[\(logTag)] audio service idle — no consumer enabled")
            return
        }
        ensureInstalled()
    }

    /// 有消费方要数据时调；装过一次就直接返回。
    static func ensureInstalled() {
        installQueue.async {
            guard !installed else { return }
            installed = true
            armCrashGuard()
            let rebound = AudioTapProbeHooks.install()
            guard rebound.setProperty, rebound.outputStart else {
                // 至少一个函数没重绑上：拿不到完整数据。**不能重试** —— 理由见类型说明。
                // 三个开关一起关掉：留着"看起来开着"的开关只是个空转的 30Hz ticker。
                disarmCrashGuard()
                UserDefaults.container.set(false, forKey: AudioTapProbe.defaultsKey)
                UserDefaults.coverPulseEnabled = false
                UserDefaults.musicHapticsEnabled = false
                AudioTapProbe.syncActiveWithSetting()
                AudioFeatures.setActive(false)
                AudioReactiveEngine.shared.refresh()
                writeDebugLog(
                    "[\(logTag)] hook install incomplete — setProperty=\(rebound.setProperty)"
                        + " outputUnitStart=\(rebound.outputStart), consumers turned off"
                )
                return
            }
            os_unfair_lock_lock(lock)
            hooksReady = true
            os_unfair_lock_unlock(lock)
            // 装 hook 这段里开关可能已经被关掉，所以让每个消费方自己去读它自己的状态。
            AudioTapProbe.syncActiveWithSetting()
            AudioTapProbe.startTimerIfNeeded()
            disarmCrashGuardAfterSurvival()
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
            writeDebugLog(
                "[\(logTag)] armed on Spotify \(version) — AudioUnitSetProperty /"
                    + " AudioOutputUnitStart, read-only"
            )
        }
    }

    /// `AudioOutputUnitStart` 之后（由 `AudioTapProbe.noteStarted` 转发）给这个 unit 挂一次渲染通知。
    ///
    /// 一个 unit 只挂一次：`AudioUnitAddRenderNotify` 没有"去重"语义，挂两次同一个回调意味着
    /// 每块 PCM 会被算两遍。**挂成功之后**才记进 `renderUnits` —— 挂失败还记着的话，这个 unit
    /// 这一辈子都拿不到数据了。
    static func installRenderNotify(on unit: AudioUnit) {
        os_unfair_lock_lock(lock)
        let ready = hooksReady
        let already = renderUnits.contains(unit)
        os_unfair_lock_unlock(lock)
        guard ready, !already else { return }

        let status = AudioUnitAddRenderNotify(unit, audioServiceRenderCallback, audioServiceRefCon)
        if status == noErr {
            os_unfair_lock_lock(lock)
            renderUnits.insert(unit)
            os_unfair_lock_unlock(lock)
            readBackFormat(of: unit)
        }
        // 这一行落在 `AudioOutputUnitStart` 的调用路径上（音频控制线程）：日志写文件不该压在
        // 开始播放这一拍，挪回主队列。
        DispatchQueue.main.async {
            writeDebugLog("[\(logTag)] AddRenderNotify unit=\(unit) status=\(status)")
        }
    }

    /// 把 unit **现在**的 StreamFormat 读回来喂给特征层。
    ///
    /// 为什么不能只靠 `AudioUnitSetProperty` 那一拍：格式通常在音频单元建起来时设一次，
    /// 中途打开开关时那次调用早就过去了 ⇒ 特征层会一直"不知道采样率"、什么都不输出。
    ///
    /// 两个 scope 都问：RemoteIO 的格式可能设在 input scope（bus 0）上，也可能在 output
    /// scope 上（探针两条都见过），float32 的那份优先。
    private static func readBackFormat(of unit: AudioUnit) {
        // float32 的那份优先（特征层只认它）；两个 scope 都不是 float32 时把第一个能读到的
        // 喂过去 —— 这样排查时至少能看到"格式不支持"，而不是一片空白。
        var fallback: AudioStreamBasicDescription?

        for scope in [kAudioUnitScope_Input, kAudioUnitScope_Output] as [AudioUnitScope] {
            var format = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            let status = AudioUnitGetProperty(
                unit,
                kAudioUnitProperty_StreamFormat,
                scope,
                0,
                &format,
                &size
            )
            guard status == noErr, format.mSampleRate > 0, format.mChannelsPerFrame > 0 else {
                continue
            }
            let float = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
            if float, format.mBitsPerChannel == 32 {
                AudioFeatures.noteFormat(format)
                return
            }
            if fallback == nil { fallback = format }
        }

        if let fallback {
            AudioFeatures.noteFormat(fallback)
        }
    }

    // MARK: - crash-loop 守卫

    private static func armCrashGuard() {
        UserDefaults.container.set(true, forKey: launchMarkerKey)
    }

    /// 装完还活过 5 秒才算这次安全。用 main 队列是因为它只清一个 UserDefaults 键。
    private static func disarmCrashGuardAfterSurvival() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            UserDefaults.container.set(false, forKey: launchMarkerKey)
        }
    }

    /// 没装上时立刻清掉 marker —— 这次一个指针都没改，不该让下次启动白关一次开关。
    private static func disarmCrashGuard() {
        UserDefaults.container.set(false, forKey: launchMarkerKey)
    }

    /// 上一次装 hook 之后 5 秒内进程就没了 ⇒ 很可能就是装的时候崩的。把依赖它的三个开关
    /// 全部关掉，这一次不装。
    ///
    /// - Returns: true 表示这次因为"上次崩过"而跳过安装。
    private static func recoverAfterUncleanLaunch() -> Bool {
        let dirty = UserDefaults.container.bool(forKey: launchMarkerKey)
            || UserDefaults.container.bool(forKey: legacyLaunchMarkerKey)
        UserDefaults.container.set(false, forKey: launchMarkerKey)
        UserDefaults.container.set(false, forKey: legacyLaunchMarkerKey)
        guard dirty else { return false }

        UserDefaults.container.set(false, forKey: AudioTapProbe.defaultsKey)
        UserDefaults.coverPulseEnabled = false
        UserDefaults.musicHapticsEnabled = false
        writeDebugLog(
            "[\(logTag)] turned off the audio consumers after an unclean launch — crash-loop guard"
        )
        return true
    }
}

/// render notify 的 refCon。必须是一个**活到进程结束**的非空指针；
/// 回调里不读它，只是 AudioUnit 的 API 要求成对出现。
private let audioServiceRefCon: UnsafeMutableRawPointer = {
    let pointer = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
    pointer.storeBytes(of: 0, as: UInt8.self)
    return pointer
}()

/// render notify 的 C 回调：先给探针、再给特征层，两者各自判自己的开关（关着就立刻返回）。
///
/// 顺序无所谓，也不共享任何状态；两次调用加起来是两次 `trylock` + 一次分支，可以忽略。
private func audioServiceRenderCallback(
    _ refCon: UnsafeMutableRawPointer,
    _ actionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    _ timeStamp: UnsafePointer<AudioTimeStamp>,
    _ busNumber: UInt32,
    _ numberFrames: UInt32,
    _ ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    _ = AudioTapProbe.handleRender(
        actionFlags: actionFlags,
        busNumber: busNumber,
        numberFrames: numberFrames,
        ioData: ioData
    )
    _ = AudioFeatures.handleRender(
        actionFlags: actionFlags,
        busNumber: busNumber,
        numberFrames: numberFrames,
        ioData: ioData
    )
    return noErr
}
