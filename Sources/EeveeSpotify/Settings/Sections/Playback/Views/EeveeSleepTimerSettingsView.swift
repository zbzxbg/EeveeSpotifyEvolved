import SwiftUI

/// 「睡眠定时器」页。
///
/// 定时器本体跑在自己的 GCD 队列上（`SleepTimerController`），这里只做两件事：
/// 每秒刷新一次剩余时间、把开始/取消两个动作转给它。页面关掉之后定时器照常走
/// （`.task` 只会停掉这个刷新循环）。
struct EeveeSleepTimerSettingsView: View {

    @State private var minutes = UserDefaults.sleepTimerMinutes
    @State private var remaining: TimeInterval?

    var body: some View {
        List {
            Section(footer: Text("sleep_timer_description".localized)) {
                Picker("sleep_timer_duration".localized, selection: $minutes) {
                    ForEach(SleepTimerController.presetMinutes, id: \.self) { value in
                        Text(String(format: "sleep_timer_minutes_format".localized, value))
                            .tag(value)
                    }
                }
                .onChange(of: minutes) { value in
                    UserDefaults.sleepTimerMinutes = value
                }
            }

            Section {
                if let remaining {
                    HStack {
                        Text("sleep_timer_remaining".localized)
                        Spacer()
                        Text(clock(remaining))
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }

                    Button(role: .destructive) {
                        SleepTimerController.shared.cancel()
                        self.remaining = nil
                    } label: {
                        Text("sleep_timer_cancel".localized)
                    }
                } else {
                    Button {
                        SleepTimerController.shared.start(minutes: minutes)
                        self.remaining = SleepTimerController.shared.remaining
                    } label: {
                        Text("sleep_timer_start".localized)
                    }
                }
            }
        }
        .listStyle(InsetGroupedListStyle())
        .task {
            remaining = SleepTimerController.shared.remaining
            // 半秒一拍：剩余时间按秒显示，半秒粒度足够，也不会让这页一直在刷。
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                remaining = SleepTimerController.shared.remaining
            }
        }
    }

    /// 剩余时间按"分:秒"显示。向上取整：剩 0.4 秒时显示 0:01 比 0:00 更像还在跑。
    private func clock(_ seconds: TimeInterval) -> String {
        let total = max(Int(seconds.rounded(.up)), 0)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
