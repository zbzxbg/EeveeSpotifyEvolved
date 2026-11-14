#import <stdint.h>

// 音频输出探针的 hook 安装（实现见 `AudioTapProbeHooks.c`）。
//
// 用 fishhook 重绑 `AudioUnitSetProperty` / `AudioOutputUnitStart` 的符号指针 —— 只改数据段，
// **不碰代码页**。inline hook 这两个系统 framework 函数会让代码页变成 invalid page，进程
// 会被内核以 `CODESIGNING / Invalid Page` 杀掉。
//
// 返回值按位：1 = `AudioUnitSetProperty` 已重绑，2 = `AudioOutputUnitStart` 已重绑，
// 3 = 两个都成，0 = 一个都没找到符号指针，-1 = `rebind_symbols` 自身失败。
//
// 一个进程只能调一次：fishhook 记着这一组 rebindings 给后加载的 image 复用，重复安装属于未定义。
int EeveeAudioTapInstallHooks(void);
