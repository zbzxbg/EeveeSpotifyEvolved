#import <AudioToolbox/AudioToolbox.h>
#import <stdint.h>
#import <stdlib.h>

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

// 调用计数：只做诊断用，给 Swift 侧定时器读，判断这两个 API 到底有多热。
static uint64_t EeveeAudioTapSetPropertyCalls = 0;
static uint64_t EeveeAudioTapStartCalls = 0;

void EeveeAudioTapReadCounters(uint64_t *setPropertyCalls, uint64_t *startCalls) {
    if (setPropertyCalls != NULL) {
        *setPropertyCalls = EeveeAudioTapSetPropertyCalls;
    }
    if (startCalls != NULL) {
        *startCalls = EeveeAudioTapStartCalls;
    }
}

// ── DSP：包住源单元的 render callback ────────────────────────────────────────
//
// 音频图是「源单元（回调供数据）→ 连接 → RemoteIO」，所以"原回调填完 ioData、单元把数据
// 交给 RemoteIO 之前"是唯一能零延迟改样本的位置：把回调换成我们的，先调原回调，再就地
// 处理同一块 `ioData`。
//
// 这两个函数由 Swift 侧（`AudioDSP.swift`）实现。`ShouldWrap` 只在 tap 已经装好时被问到，
// 返回 1 表示"包"；包不包与 DSP 开关无关 —— 开关只在 `Process` 里决定处不处理，这样打开
// DSP 不必等音频图重建。
int EeveeAudioDSPShouldWrapCallback(void *unit);
void EeveeAudioDSPProcess(void *ioData, uint32_t numberFrames);

typedef struct {
    AURenderCallback original;
    void *originalRefCon;
} EeveeDSPCallbackContext;

static OSStatus EeveeDSPWrappedRenderCallback(
    void *refCon,
    AudioUnitRenderActionFlags *actionFlags,
    const AudioTimeStamp *timeStamp,
    UInt32 busNumber,
    UInt32 numberFrames,
    AudioBufferList *ioData
) {
    EeveeDSPCallbackContext *context = (EeveeDSPCallbackContext *)refCon;
    if (context == NULL || context->original == NULL) {
        return noErr;
    }
    OSStatus status = context->original(
        context->originalRefCon, actionFlags, timeStamp, busNumber, numberFrames, ioData);
    if (status != noErr) {
        return status;
    }
    EeveeAudioDSPProcess(ioData, numberFrames);
    return noErr;
}

// 返回 1 = 这次 `SetRenderCallback` 已经用包装后的回调替掉了（`*outStatus` 是原实现的
// 返回值）；返回 0 = 按原样放行。
static int EeveeAudioDSPWrapRenderCallback(
    AudioUnit unit,
    AudioUnitScope scope,
    AudioUnitElement element,
    const void *data,
    UInt32 size,
    OSStatus *outStatus
) {
    if (data == NULL || size < sizeof(AURenderCallbackStruct)) {
        return 0;
    }
    if (!EeveeAudioDSPShouldWrapCallback((void *)unit)) {
        return 0;
    }
    const AURenderCallbackStruct *original = (const AURenderCallbackStruct *)data;
    if (original->inputProc == NULL) {
        return 0;
    }
    if (EeveeOrigAudioUnitSetProperty == NULL) {
        return 0;
    }

    // 上下文活到进程结束（回调挂在音频图里，拆不掉也不需要拆）。
    EeveeDSPCallbackContext *context =
        (EeveeDSPCallbackContext *)malloc(sizeof(EeveeDSPCallbackContext));
    if (context == NULL) {
        return 0;
    }
    context->original = original->inputProc;
    context->originalRefCon = original->inputProcRefCon;

    AURenderCallbackStruct wrapped;
    wrapped.inputProc = EeveeDSPWrappedRenderCallback;
    wrapped.inputProcRefCon = context;

    OSStatus status = EeveeOrigAudioUnitSetProperty(
        unit, kAudioUnitProperty_SetRenderCallback, scope, element, &wrapped, sizeof(wrapped));
    if (status != noErr) {
        free(context);
        return 0;
    }
    if (outStatus != NULL) {
        *outStatus = status;
    }
    return 1;
}


// fishhook 会把"改之前那个指针值"写回 `replaced`，而且**新 image 加载时会再写一次**（它把
// rebindings 存起来重复用）⇒ 这两个变量必须是活到进程结束的静态存储，不能指向栈上临时量。
static OSStatus EeveeAudioUnitSetPropertyReplacement(
    AudioUnit unit,
    AudioUnitPropertyID propertyID,
    AudioUnitScope scope,
    AudioUnitElement element,
    const void *data,
    UInt32 size
) {
    EeveeAudioTapSetPropertyCalls++;

    // 这个替换函数挂在音频控制线程上，每次跨到 Swift 都有成本，而探针只关心三种属性 ——
    // 其余的直接放行，不白跨。
    //
    // `SetRenderCallback` 是给 DSP 那条线留的判据：它出现（且 `inputProc` 非空）说明
    // Spotify 是**回调供数据**；只有 `MakeConnection` 说明是**连接供数据**。两者决定
    // 效果单元该插在哪里。
    if (propertyID == kAudioUnitProperty_StreamFormat
        || propertyID == kAudioUnitProperty_MakeConnection
        || propertyID == kAudioUnitProperty_SetRenderCallback) {
        EeveeAudioTapNoteSetProperty((void *)unit, propertyID, scope, element, data, size);
    }

    // DSP：把源单元的回调换成"先调原回调、再审同一块 ioData"的包装。返回 1 表示这次已经
    // 用包装后的回调替掉了，原样返回它的状态即可。
    if (propertyID == kAudioUnitProperty_SetRenderCallback) {
        OSStatus dspStatus = noErr;
        if (EeveeAudioDSPWrapRenderCallback(unit, scope, element, data, size, &dspStatus)) {
            return dspStatus;
        }
    }

    if (EeveeOrigAudioUnitSetProperty == NULL) {
        // 重绑没成却还是被调到：状态已经乱了，别再往下传一个空指针。
        return -50; // paramErr
    }
    return EeveeOrigAudioUnitSetProperty(unit, propertyID, scope, element, data, size);
}

static OSStatus EeveeAudioOutputUnitStartReplacement(AudioUnit unit) {
    EeveeAudioTapStartCalls++;
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
