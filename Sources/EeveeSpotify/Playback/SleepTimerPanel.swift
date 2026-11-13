import SwiftUI

/// 听歌页底排「队列」键**长按**弹出来的睡眠定时器面板。
///
/// 为什么还要这一块：设置里那张页（`EeveeSleepTimerSettingsView`）是"配置"的地方，而真正
/// 会用到它的时刻是**躺下准备睡**——那时候人在听歌页，翻三层设置太远。这里做成
/// "点一个时长就开始，然后自己关掉"。
///
/// 与设置页共用同一个 `SleepTimerController`：两边看到的是同一个倒计时，哪边取消都算数。
struct SleepTimerPanel: View {

    @Environment(\.dismiss) private var dismiss
    @State private var remaining: TimeInterval?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let remaining {
                        HStack {
                            Text("sleep_timer_remaining".localized)
                            Spacer()
                            Text(clock(remaining))
                                .foregroundColor(.secondary)
                                .monospacedDigit()
                        }
                    } else {
                        Text("sleep_timer_pick_duration".localized)
                            .foregroundColor(.secondary)
                    }
                }

                Section {
                    ForEach(SleepTimerController.presetMinutes, id: \.self) { value in
                        Button {
                            SleepTimerController.shared.start(minutes: value)
                            UserDefaults.sleepTimerMinutes = value
                            writeDebugLog("[SleepTimer] picked \(value) min from the player")
                            dismiss()
                        } label: {
                            Text(String(format: "sleep_timer_minutes_format".localized, value))
                        }
                    }
                }

                if remaining != nil {
                    Section {
                        Button(role: .destructive) {
                            SleepTimerController.shared.cancel()
                            dismiss()
                        } label: {
                            Text("sleep_timer_cancel".localized)
                        }
                    }
                }
            }
            .navigationTitle("sleep_timer_title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK".localized) { dismiss() }
                }
            }
            .task {
                remaining = SleepTimerController.shared.remaining
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    remaining = SleepTimerController.shared.remaining
                }
            }
        }
    }

    /// 剩余时间按"分:秒"显示。向上取整：剩 0.4 秒时显示 0:01 比 0:00 更像还在跑。
    private func clock(_ seconds: TimeInterval) -> String {
        let total = max(Int(seconds.rounded(.up)), 0)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

extension SleepTimerPanel {

    /// 包成 `UIHostingController` 再 present。
    ///
    /// 宿主从窗口根往下取最上面那个 —— 与 `LyricsOffsetPanel.present` 同一套：
    /// 播放页自己可能正在转场（或手上还挂着别的 sheet），不能从它身上 present。
    static func present() {
        guard let window = EntityPageAppearance.frontWindow(),
              var host = window.rootViewController else { return }
        while let presented = host.presentedViewController, !presented.isBeingDismissed {
            host = presented
        }
        let controller = UIHostingController(rootView: SleepTimerPanel())
        controller.view.backgroundColor = .clear
        if let sheet = controller.sheetPresentationController {
            sheet.detents = [.medium()]
            sheet.prefersGrabberVisible = true
        }
        host.present(controller, animated: true)
        writeDebugLog("[SleepTimer] panel opened from the player")
    }
}
