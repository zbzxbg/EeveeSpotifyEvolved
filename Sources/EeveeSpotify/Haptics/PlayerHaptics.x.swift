import Foundation
import Orion
import UIKit

/// 播放器控件的触感。
///
/// 挂在 `-[UIControl sendAction:to:forEvent:]` 上 —— **公开 API**，所以这条 hook 不
/// 依赖任何 Spotify 私有类名，是这一批里唯一不怕版本漂移的部分。命中判断交给
/// `PlayerHapticSurface`（关键词匹配，见那边的说明）。
///
/// 两个安全属性：
///   · 开关关着时这条 hook **根本不装**（见 `activatePlayerHaptics`）—— 不开触感的
///     用户连一次额外的消息发送都不会有；
///   · 只认 `UIEvent.type == .touches`：`sendAction` 也会被播放状态变化之类的
///     非触摸路径调用，那些不该震。
///
/// ⚠️ 两处与 Orion 语义有关的硬要求（静态审查抓出来的，改之前先看这两条）：
///   1. **必须原样返回 `orig` 的 `Bool`**：`-[UIControl sendAction:to:forEvent:]` 的
///      返回值是"这个 action 有没有被派发"。hook 声明成 `Void` 就不会写返回寄存器，
///      调用方读到的是未定义值 —— 那等于全 App 的控件派发行为被这条 hook 改变了。
///   2. **被 hook 的对象是 `target`**（Orion 的 `ClassHook` 持有 `target` 属性，
///      `self` 是 hook 自己）。而本方法的参数恰好也叫 `target`，所以必须写
///      `self.target`。仓库里 `CustomLyrics+ScrollCrashFix.x.swift` 用的就是 `target`。
struct PlayerHapticsGroup: HookGroup {}

class ControlSendActionHapticHook: ClassHook<UIControl> {
    typealias Group = PlayerHapticsGroup

    // 显式写出选择器：Swift 侧叫 `for:`，ObjC 侧那一段是 `forEvent:`，
    // 靠标签推导容易错（仓库里 CarPlayCrashFix 也是这么显式声明的）。
    @objc(sendAction:to:forEvent:)
    func sendAction(_ action: Selector, to target: Any?, forEvent event: UIEvent?) -> Bool {
        let handled = orig.sendAction(action, to: target, forEvent: event)

        guard HapticFeedback.isEnabled else { return handled }

        PlayerHapticSurface.logChainIfRequested(self.target)

        guard event?.type == .touches else { return handled }
        guard PlayerHapticSurface.matches(self.target) else { return handled }

        HapticFeedback.tap()
        return handled
    }
}

func activatePlayerHaptics() {
    guard UserDefaults.hapticsEnabled else {
        writeDebugLog("[Haptics] off — UIControl hook not installed")
        return
    }

    PlayerHapticsGroup().activate()
    writeDebugLog("[Haptics] installed — keywords: \(UserDefaults.hapticsSurfaceKeywords)")
}
