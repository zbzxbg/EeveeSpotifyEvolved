#import <AudioToolbox/AudioToolbox.h>
#import <stdint.h>

#import "fishhook.h"

// 探针的 hook 装在这里：**fishhook 重绑符号指针**，不改代码页。
//
// 为什么不能 inline hook：`AudioUnitSetProperty` / `AudioOutputUnitStart` 在系统 framework
// `AudioToolboxCore` 里，代码页来自 dyld shared cache、受代码签名保护。`MSHookFunction` 原地
// 改掉入口之后，那一页就成了 invalid page —— 内核在下一次执行该入口时以
// `EXC_BAD_ACCESS` + `KERN_PROTECTION_FAILURE` 杀掉进程（termination 写的是
// `CODESIGNING / Invalid Page`）。重绑只改 `__la_symbol_ptr` 里的指针值（数据段，
// `VM_PROT_COPY` 私有化），代码页一个字节都不动。
//
// 代价：只能拦到**走符号指针**的调用。Spotify 自己对这些函数的调用是这种，所以够用；
// 系统 framework 内部的直接调用拦不到，那部分本来也不是探针要看的。

// 记录点由 Swift 侧实现（`AudioTapProbeHooks.swift` 里的 `@_cdecl` 函数）：去重、格式解析、
// 日志都在那一侧，这里只负责转发并调原实现。
void EeveeAudioTapNoteSetProperty(
    void *unit,
    UInt32 propertyID,
    UInt32 scope,
    UInt32 element,
    const void *data,
    UInt32 size
);
void EeveeAudioTapNoteStarted(void *unit, int32_t status);

// fishhook 会把"改之前那个指针值"写回 `replaced`，而且**新 image 加载时会再写一次**（它把
// rebindings 存起来重复用）⇒ 这两个变量必须是活到进程结束的静态存储，不能指向栈上临时量。
static OSStatus (*EeveeOrigAudioUnitSetProperty)(
    AudioUnit,
    AudioUnitPropertyID,
    AudioUnitScope,
    AudioUnitElement,
    const void *,
    UInt32
) = NULL;
static OSStatus (*EeveeOrigAudioOutputUnitStart)(AudioUnit) = NULL;

static OSStatus EeveeAudioUnitSetPropertyReplacement(
    AudioUnit unit,
    AudioUnitPropertyID propertyID,
    AudioUnitScope scope,
    AudioUnitElement element,
    const void *data,
    UInt32 size
) {
    EeveeAudioTapNoteSetProperty((void *)unit, propertyID, scope, element, data, size);
    if (EeveeOrigAudioUnitSetProperty == NULL) {
        // 重绑没成却还是被调到：状态已经乱了，别再往下传一个空指针。
        return -50; // paramErr
    }
    return EeveeOrigAudioUnitSetProperty(unit, propertyID, scope, element, data, size);
}

static OSStatus EeveeAudioOutputUnitStartReplacement(AudioUnit unit) {
    if (EeveeOrigAudioOutputUnitStart == NULL) {
        return -50; // paramErr
    }
    OSStatus status = EeveeOrigAudioOutputUnitStart(unit);
    EeveeAudioTapNoteStarted((void *)unit, (int32_t)status);
    return status;
}

int EeveeAudioTapInstallHooks(void) {
    struct rebinding rebindings[] = {
        {
            "AudioUnitSetProperty",
            (void *)EeveeAudioUnitSetPropertyReplacement,
            (void **)&EeveeOrigAudioUnitSetProperty
        },
        {
            "AudioOutputUnitStart",
            (void *)EeveeAudioOutputUnitStartReplacement,
            (void **)&EeveeOrigAudioOutputUnitStart
        },
    };
    int result = rebind_symbols(rebindings, sizeof(rebindings) / sizeof(rebindings[0]));
    if (result != 0) {
        return -1;
    }
    int state = 0;
    if (EeveeOrigAudioUnitSetProperty != NULL) {
        state |= 1;
    }
    if (EeveeOrigAudioOutputUnitStart != NULL) {
        state |= 2;
    }
    return state;
}
