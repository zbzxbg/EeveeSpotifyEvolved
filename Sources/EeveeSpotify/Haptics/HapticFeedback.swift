import UIKit

/// 触感引擎。
///
/// 三条自我约束：
/// 1. **默认关**（`UserDefaults.hapticsEnabled`）—— 否则等于给所有用户凭空加震动；
/// 2. 只用公开 API：`impactOccurred(intensity:)`（iOS 13+）与
/// `UISelectionFeedbackGenerator`，不碰私有 `_intensity`；
/// 3. 只有 App 在前台才触发 —— 后台被系统调度时震动是"响错地方"。
enum HapticFeedback {

    private static let impact = UIImpactFeedbackGenerator(style: .light)

    static var isEnabled: Bool { UserDefaults.hapticsEnabled }

    /// 0.05 – 1.0。设置页滑杆是 0.2...1.0，这里是最后一道钳位。
    static var intensity: CGFloat {
        min(max(CGFloat(UserDefaults.hapticsStrength), 0.05), 1.0)
    }

    /// 一次"点击"反馈。
    static func tap() {
        guard isEnabled, isForeground else { return }

        impact.impactOccurred(intensity: intensity)
        // 提前唤醒 Taptic Engine，降低下一次的延迟。
        impact.prepare()
    }

    // MARK: - 音乐触感（`MusicHaptics` 用）
    //
    // 与上面的「界面触感」是**两套开关**：`hapticsEnabled` 管的是"点界面回不回震"，
    // 音乐触感有自己的 `musicHapticsEnabled`。所以这两条**故意不看** `isEnabled` ——
    // 用户可能只想让鼓点震、不想让点按钮震（或反过来）。
    //
    // 只要求 App 在前台：后台被系统调度时震动是"响错地方"。

    private static let kickImpact = UIImpactFeedbackGenerator(style: .light)
    private static let snareImpact = UIImpactFeedbackGenerator(style: .rigid)

    /// 底鼓：一次轻触。
    static func musicKick(intensity: CGFloat) {
        guard isForeground else { return }
        kickImpact.impactOccurred(intensity: clamped(intensity))
        kickImpact.prepare()
    }

    /// 军鼓：比底鼓更短更脆的一下。
    static func musicSnare(intensity: CGFloat) {
        guard isForeground else { return }
        snareImpact.impactOccurred(intensity: clamped(intensity))
        snareImpact.prepare()
    }

    /// 0.05 – 1.0：`impactOccurred(intensity:)` 对这个区间之外的值行为未定义。
    private static func clamped(_ value: CGFloat) -> CGFloat {
        min(max(value, 0.05), 1)
    }

    private static var isForeground: Bool {
        // 本文件只编进 App 主体（不进 appex），`UIApplication.shared` 安全。
        UIApplication.shared.applicationState == .active
    }
}
