import Orion
import AudioToolbox
import Darwin
import Foundation

/// 音频输出域探针的 hook 组（见 `AudioTapProbe`）。
///
/// 只 hook 两个 C 函数：
/// · `AudioUnitSetProperty` —— 记录 unit 的 component / 格式 / 连接关系（只读）；
/// · `AudioOutputUnitStart` —— 先走原实现，再给 RemoteIO 挂 PostRender 只读通知。
///
/// 目标用 `Function.address` 喂地址，**不用** `Function.symbol(_, image: nil)`：后者把解析
/// 交给 CydiaSubstrate 的 `MSFindSymbol`，而 `image: nil` 意味着"每个 image 都找一遍"，
/// 它要逐 image 解析 dyld shared cache 里的导出符号 —— 整个 cache 过一遍是几十秒量级的
/// CPU，足够把主调线程拖进 scene-update watchdog（`0x8BADF00D`）。
/// 地址改用 `dlsym` 从**已映射** image 的导出表里取，微秒级，也不依赖 shared cache 的
/// 磁盘路径（iOS 27 把它挪进了 `/private/preboot/Cryptexes/OS/...`）。
///
/// 这两个函数都由 AudioToolbox 导出；本文件 `import AudioToolbox`、且真正的 hook 回调里
/// 还直接调了 `AudioUnitAddRenderNotify` 等，所以 tweak 初始化时它一定已经加载。
struct AudioTapProbeGroup: HookGroup { }

/// 探针要 hook 的两个函数在本进程里的地址。
///
/// 由 `AudioTapProbe` 在后台队列上、激活 hook 之前调 `resolve()` 解析一次；解析不到就不
/// 激活，免得把空地址交给 `MSHookFunction`。只在同一条串行队列上读写。
enum AudioTapProbeTargets {
    /// 只在 `resolve()` 里写，别的地方只读。
    static var setProperty: UnsafeMutableRawPointer?
    static var outputUnitStart: UnsafeMutableRawPointer?

    /// AudioToolbox 在进程命名空间里的规范路径；`dlsym` 全部落空时的退路要用它。
    static let audioToolboxImage = "/System/Library/Frameworks/AudioToolbox.framework/AudioToolbox"

    @discardableResult
    static func resolve() -> Bool {
        setProperty = lookup("AudioUnitSetProperty")
        outputUnitStart = lookup("AudioOutputUnitStart")
        guard setProperty != nil, outputUnitStart != nil else {
            var missing: [String] = []
            if setProperty == nil { missing.append("AudioUnitSetProperty") }
            if outputUnitStart == nil { missing.append("AudioOutputUnitStart") }
            writeDebugLog(
                "[\(AudioTapProbe.logTag)] dlsym could not find \(missing.joined(separator: " / "))"
                    + " — hooks not installed"
            )
            return false
        }
        return true
    }

    private static func lookup(_ name: String) -> UnsafeMutableRawPointer? {
        // `RTLD_DEFAULT` 在 Swift 里没有导入（C 里是 `((void *) -2)`），自己拼一个：
        // 它让 `dlsym` 在所有已加载 image 的导出表里找。
        if let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2),
           let pointer = dlsym(defaultHandle, name) {
            return pointer
        }
        // 退路：显式打开 AudioToolbox 再查一次。它由本 dylib 链接，正常不会走到这里。
        guard let handle = dlopen(audioToolboxImage, RTLD_LAZY) else { return nil }
        return dlsym(handle, name)
    }

    /// 两个地址的文本形式，只给激活前那行日志用。
    static var addressesText: String {
        "setProperty=\(String(describing: setProperty)) start=\(String(describing: outputUnitStart))"
    }
}

class AudioUnitSetPropertyHook: FunctionHook {
    typealias Group = AudioTapProbeGroup

    static var target: Function {
        if let address = AudioTapProbeTargets.setProperty {
            return .address(address)
        }
        // 只有 `activateAudioTapProbeHooks()` 的解析失败又硬要激活时才会走到：退化成
        // 按 image 查，只扫 AudioToolbox 一个 image，而不是整个 shared cache。
        return .symbol("AudioUnitSetProperty", image: AudioTapProbeTargets.audioToolboxImage)
    }

    func function(
        _ unit: AudioUnit,
        _ id: AudioUnitPropertyID,
        _ scope: AudioUnitScope,
        _ element: AudioUnitElement,
        _ data: UnsafeRawPointer?,
        _ size: UInt32
    ) -> OSStatus {
        AudioTapProbe.noteSetProperty(
            unit: unit,
            id: id,
            scope: scope,
            element: element,
            data: data,
            size: size
        )
        return orig.function(unit, id, scope, element, data, size)
    }
}

class AudioOutputUnitStartHook: FunctionHook {
    typealias Group = AudioTapProbeGroup

    static var target: Function {
        if let address = AudioTapProbeTargets.outputUnitStart {
            return .address(address)
        }
        return .symbol("AudioOutputUnitStart", image: AudioTapProbeTargets.audioToolboxImage)
    }

    func function(_ unit: AudioUnit) -> OSStatus {
        let status = orig.function(unit)
        AudioTapProbe.noteStarted(unit: unit, status: status)
        return status
    }
}

/// 由 `AudioTapProbe.install()` 在后台队列上调用。组激活留在 Orion 预处理的这一侧，
/// 纯 Swift 那边只拿一个普通函数，不直接碰 HookGroup 类型。
///
/// - Returns: `false` = 两个函数一个都没解析到，什么都没装。
@discardableResult
func activateAudioTapProbeHooks() -> Bool {
    guard AudioTapProbeTargets.resolve() else { return false }
    // `activate()` 是同步的，而且 Orion 的错误处理必须终止进程（`OrionErrorHandler` 的返回
    // 类型是 `Never`）：`MSHookFunction` 在 shared cache 的页上挂不动时，这一步会直接 trap，
    // 没有异常可接。所以激活前先落一行带两个地址的日志，两条失败路径能分开辨认。
    writeDebugLog("[\(AudioTapProbe.logTag)] activating hooks at \(AudioTapProbeTargets.addressesText)")
    AudioTapProbeGroup().activate()
    return true
}
