import UIKit

/// 触感引擎。
///
/// 三条自我约束：
///   1. **默认关**（`UserDefaults.hapticsEnabled`）—— 否则等于给所有用户凭空加震动；
///   2. 只用公开 API：`impactOccurred(intensity:)`（iOS 13+）与
///      `UISelectionFeedbackGenerator`，不碰私有 `_intensity`；
///   3. 只有 App 在前台才触发 —— 后台被系统调度时震动是"响错地方"。
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

    private static var isForeground: Bool {
        // 本文件只编进 App 主体（不进 appex），`UIApplication.shared` 安全。
        UIApplication.shared.applicationState == .active
    }
}
