import AudioToolbox
import EeveeSpotifyC
import Foundation

/// 音频输出域探针的 hook（见 `AudioTapProbe`）。
///
/// 装法用 fishhook **重绑符号指针**，不是 inline hook：
/// · `AudioUnitSetProperty` / `AudioOutputUnitStart` 在系统 framework `AudioToolboxCore` 里，
///   代码页来自 dyld shared cache、有代码签名。`MSHookFunction` 改掉入口之后那一页就成了
///   invalid page，内核下一次执行该入口时以 `EXC_BAD_ACCESS` + `KERN_PROTECTION_FAILURE`
///   杀掉进程（termination 写的是 `CODESIGNING / Invalid Page`）。
/// · 重绑只改 `__la_symbol_ptr` 里的指针值（数据段，`VM_PROT_COPY` 私有化），代码页一个
///   字节都不碰。代价是只拦得到**走符号指针**的调用 —— Spotify 自己对这些函数的调用都是这种。
///
/// C 侧（重绑 + 两个替换函数）见 `Sources/EeveeSpotifyC/AudioTapProbeHooks.c`。
enum AudioTapProbeHooks {

    /// 一个进程只能调一次（由 `AudioTapProbe` 的 `installed` 保证）：fishhook 把这一组
    /// rebindings 记着给后加载的 image 复用，重复安装属于未定义行为。
    ///
    /// - Returns: 两个函数各自有没有被重绑上。
    static func install() -> (setProperty: Bool, outputStart: Bool) {
        let state = EeveeAudioTapInstallHooks()
        // -1 = rebind_symbols 自己失败，不能按位去读。
        let rebound = state > 0
        return (
            setProperty: rebound && (state & 1) != 0,
            outputStart: rebound && (state & 2) != 0
        )
    }
}

/// C 侧的替换函数把观察到的调用转发到这里。
///
/// `unit` 在 C 里是 `void *`；`AudioUnit` 本身就是 `OpaquePointer`，按位取回即可。
@_cdecl("EeveeAudioTapNoteSetProperty")
public func eeveeAudioTapNoteSetProperty(
    _ unit: UnsafeMutableRawPointer?,
    _ propertyID: UInt32,
    _ scope: UInt32,
    _ element: UInt32,
    _ data: UnsafeRawPointer?,
    _ size: UInt32
) {
    guard let unit else { return }
    // `AudioUnit` 是 C 的 `ComponentInstanceRecord *`，和 `void *` 同宽；用 `unsafeBitCast`
    // 直接取回，不走 `bitPattern:` 那组初始化器（它们在这条 SDK 上解析成可空类型）。
    AudioTapProbe.noteSetProperty(
        unit: unsafeBitCast(unit, to: AudioUnit.self),
        id: propertyID,
        scope: scope,
        element: element,
        data: data,
        size: size
    )
}

@_cdecl("EeveeAudioTapNoteStarted")
public func eeveeAudioTapNoteStarted(_ unit: UnsafeMutableRawPointer?, _ status: Int32) {
    guard let unit else { return }
    AudioTapProbe.noteStarted(
        unit: unsafeBitCast(unit, to: AudioUnit.self),
        status: status
    )
}
