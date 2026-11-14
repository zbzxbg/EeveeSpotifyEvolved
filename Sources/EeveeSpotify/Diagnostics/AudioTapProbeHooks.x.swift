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
/// 目标用 `Function.address` 喂地址，**不用** `Function.symbol(_, image: nil)`：后者在
/// Substrate 后端的实现是 `MSFindSymbol(nil, name)`，会按 image 逐个解析 dyld shared cache
/// 里的导出符号 —— 整个 cache 过一遍是几十秒量级的 CPU，足够把调用线程拖进 scene-update
/// watchdog（`0x8BADF00D`）。地址改用 `dlsym` 从**已映射** image 的导出表里取，微秒级，
/// 也不依赖 shared cache 的磁盘路径（iOS 27 把它挪进了 `/private/preboot/Cryptexes/OS/...`）。
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

    /// 两个目标函数入口那 4 字节（arm64 指令字）。
    ///
    /// `MSHookFunction` 是原地改 prologue，真挂上之后入口一定会变 —— 这是唯一一个不依赖
    /// Orion 内部状态的"到底挂上没挂上"判据（Orion 的失败只走 `Tweak.handleError`，不抛）。
    static func prologueWords() -> (UInt32?, UInt32?) {
        (word(at: setProperty), word(at: outputUnitStart))
    }

    private static func word(at address: UnsafeMutableRawPointer?) -> UInt32? {
        guard let address else { return nil }
        return address.load(as: UInt32.self)
    }

    /// 激活前后入口字节的对照；`patched` 要求两个入口都变了。
    static func prologueReport(
        before: (UInt32?, UInt32?),
        after: (UInt32?, UInt32?)
    ) -> (patched: Bool, text: String) {
        let setPropertyPatched = before.0 != nil && before.0 != after.0
        let startPatched = before.1 != nil && before.1 != after.1
        let text = "setProperty \(hex(before.0))→\(hex(after.0))"
            + " start \(hex(before.1))→\(hex(after.1))"
        return (setPropertyPatched && startPatched, text)
    }

    private static func hex(_ word: UInt32?) -> String {
        guard let word else { return "nil" }
        return String(format: "0x%08x", word)
    }
}

class AudioUnitSetPropertyHook: FunctionHook {
    typealias Group = AudioTapProbeGroup

    static var target: Function {
        guard let address = AudioTapProbeTargets.setProperty else {
            // 这个组只会在 `activateAudioTapProbeHooks()` 里、`resolve()` 成功之后被激活；
            // 走到这里说明有别的路径直接激活了它 —— 那是编程错误。别退化成按符号查：那正是
            // 会让进程卡在 shared cache 扫描里的写法。
            preconditionFailure("AudioTapProbeTargets.resolve() must run before activating AudioTapProbeGroup")
        }
        return .address(address)
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
        guard let address = AudioTapProbeTargets.outputUnitStart else {
            preconditionFailure("AudioTapProbeTargets.resolve() must run before activating AudioTapProbeGroup")
        }
        return .address(address)
    }

    func function(_ unit: AudioUnit) -> OSStatus {
        let status = orig.function(unit)
        AudioTapProbe.noteStarted(unit: unit, status: status)
        return status
    }
}

/// `activateAudioTapProbeHooks()` 的结果。
///
/// Orion 的 hook 失败在本仓是**非致命**的：`EeveeSpotify.handleError` 只记一行
/// `[ORION ERROR] …`，组照样被算作"激活过"（`MSHookFunction` 失败也一样）。所以
/// "调过 `activate()`"不等于"挂上了"，得看目标入口有没有被改写。
enum AudioTapProbeActivationResult {
    /// 两个地址都解析到，且入口字节确实变了：hook 生效。
    case activated
    /// `dlsym` 没拿到地址：一个函数都没动过，之后可以再试。
    case symbolsMissing
    /// 地址拿到了、`activate()` 也调了，但入口字节没变：Orion 没能改掉 prologue。
    /// 组已经算激活过，再激活一次只会再报一次错，只能等下次启动。
    case notPatched
}

/// 由 `AudioTapProbe.install()` 在后台队列上调用。组激活留在 Orion 预处理的这一侧，
/// 纯 Swift 那边只拿一个普通函数，不直接碰 HookGroup 类型。
@discardableResult
func activateAudioTapProbeHooks() -> AudioTapProbeActivationResult {
    guard AudioTapProbeTargets.resolve() else { return .symbolsMissing }

    let before = AudioTapProbeTargets.prologueWords()
    writeDebugLog("[\(AudioTapProbe.logTag)] activating hooks at \(AudioTapProbeTargets.addressesText)")
    AudioTapProbeGroup().activate()
    let report = AudioTapProbeTargets.prologueReport(
        before: before,
        after: AudioTapProbeTargets.prologueWords()
    )
    writeDebugLog(
        "[\(AudioTapProbe.logTag)] prologue \(report.text) — \(report.patched ? "hooked" : "NOT hooked")"
    )
    return report.patched ? .activated : .notPatched
}
