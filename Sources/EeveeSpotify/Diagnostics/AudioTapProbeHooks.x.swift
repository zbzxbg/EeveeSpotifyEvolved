import Orion
import AudioToolbox
import Foundation

/// 音频输出域探针的 hook 组（见 `AudioTapProbe`）。
///
/// 只 hook 两个 C 函数：
/// · `AudioUnitSetProperty` —— 记录 unit 的 component / 格式 / 连接关系（只读）；
/// · `AudioOutputUnitStart` —— 先走原实现，再给 RemoteIO 挂 PostRender 只读通知。
///
/// 两个函数都是 AudioToolbox 导出的；`image: nil` 表示任何 image 里的同名符号，
/// 这样 Spotify 把调用放在主二进制还是框架里都能命中。
struct AudioTapProbeGroup: HookGroup { }

class AudioUnitSetPropertyHook: FunctionHook {
    typealias Group = AudioTapProbeGroup
    static let target = Function.symbol("AudioUnitSetProperty", image: URL?.none)

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
    static let target = Function.symbol("AudioOutputUnitStart", image: URL?.none)

    func function(_ unit: AudioUnit) -> OSStatus {
        let status = orig.function(unit)
        AudioTapProbe.noteStarted(unit: unit, status: status)
        return status
    }
}

/// 由 `AudioTapProbe.install()` 调用。组激活留在 Orion 预处理的这一侧，
/// 纯 Swift 那边只拿一个普通函数，不直接碰 HookGroup 类型。
func activateAudioTapProbeHooks() {
    AudioTapProbeGroup().activate()
}
