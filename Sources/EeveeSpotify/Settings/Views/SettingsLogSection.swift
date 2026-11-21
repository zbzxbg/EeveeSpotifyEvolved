import SwiftUI
import UIKit

/// 根页的「日志」一节：开启记录 / 导出 / 清除。
///
/// 为什么在根页：遇到问题时的第一步就是"打开记录、复现、把日志发出去"，而这三件事
/// 原来在「调试」页里 —— 那一页是转储与探针，普通用户不该为了发日志先钻进去。
/// 它和调试页的转储开关写的是同一个文件（`eeveespotify_debug.log`），只是入口分开。
///
/// 「导出前脱敏」不在这里：那是一个**隐私默认值**，跟排查开关放在一起更合适
/// （调试页末尾，见 `EeveeDebugSettingsView`）。
struct SettingsLogSection: View {

    var body: some View {
        Section(
            header: Text("log_tools_section".localized),
            footer: Text("enable_log_recording_description".localized)
        ) {
            Toggle(
                "enable_log_recording".localized,
                isOn: Binding<Bool>(
                    get: { UserDefaults.enableLogRecording },
                    set: { newValue in
                        UserDefaults.enableLogRecording = newValue
                        if newValue {
                            writeDebugLog("[LOG] Log recording enabled")
                        }
                    }
                )
            )

            Button(action: exportDebugLog) {
                HStack {
                    Image(systemName: "square.and.arrow.up")
                    Text("export_debug_log".localized)
                }
            }

            Button(action: clearDebugLog) {
                HStack {
                    Image(systemName: "trash")
                    Text("clear_debug_log".localized)
                }
                .foregroundColor(.red)
            }
        }
    }

    /// 导出**可分享的那一份**：`redactSharedLog` 开着时是假名化后的副本，
    /// 原文件一个字都不动（排查要用的真实曲目还留在本地）。
    /// 凭证/设备标识那一层不在这里 —— 它在写入口就生效了，见 `DebugLogSanitizer`。
    ///
    /// ⚠️ 脱敏版生成失败时**绝不回退到原文件**：那正好是"以为已经脱敏、实际分享了明文"
    /// 的场景。宁可导出失败并告诉他，也不能静默 fail-open。
    private func exportDebugLog() {
        let logPath = NSTemporaryDirectory() + "eeveespotify_debug.log"
        guard FileManager.default.fileExists(atPath: logPath),
              let logData = FileManager.default.contents(atPath: logPath),
              logData.count > 0 else {
            PopUpHelper.showPopUp(message: "no_debug_log_found".localized, buttonText: "OK".localized)
            return
        }

        let logURL: URL
        if UserDefaults.redactSharedLog {
            guard let redacted = DebugLogSanitizer.sharedLogFile(from: logPath, redact: true) else {
                PopUpHelper.showPopUp(
                    message: "redact_log_failed".localized,
                    buttonText: "OK".localized
                )
                return
            }
            logURL = redacted
        } else {
            logURL = DebugLogSanitizer.sharedLogFile(from: logPath, redact: false)
                ?? URL(fileURLWithPath: logPath)
        }

        let activityVC = UIActivityViewController(activityItems: [logURL], applicationActivities: nil)
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootVC = scene.windows.first?.rootViewController {
            var topVC = rootVC
            while let presented = topVC.presentedViewController { topVC = presented }
            if let popover = activityVC.popoverPresentationController {
                popover.sourceView = topVC.view
                popover.sourceRect = CGRect(x: topVC.view.bounds.midX, y: topVC.view.bounds.midY, width: 0, height: 0)
            }
            topVC.present(activityVC, animated: true)
        }
    }

    /// 清空调试日志：把文件换成一个空文件，再让常驻句柄重开，最后回一行日志。
    private func clearDebugLog() {
        let logPath = NSTemporaryDirectory() + "eeveespotify_debug.log"
        guard FileManager.default.fileExists(atPath: logPath),
              let logData = FileManager.default.contents(atPath: logPath),
              logData.count > 0 else {
            PopUpHelper.showPopUp(message: "no_log_to_clear".localized, buttonText: "OK".localized)
            return
        }
        try? "".write(toFile: logPath, atomically: true, encoding: .utf8)
        // 上面这行换掉了文件本体，常驻句柄要跟着重开，否则后面的日志写进旧 inode。
        resetDebugLogFile()
        writeDebugLog("Log cleared by user")
        PopUpHelper.showPopUp(message: "debug_log_cleared".localized, buttonText: "OK".localized)
    }
}
