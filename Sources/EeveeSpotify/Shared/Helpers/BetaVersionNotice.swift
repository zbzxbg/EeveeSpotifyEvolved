import Foundation

/// 首次启动时的 beta 版提示。
///
/// 触发条件（两条同时满足）：
///   ① `EeveeSpotify.version` 带 `-beta`（`2.0.0-beta`、`2.0.0-beta.1` 都算）；
///   ② 这个版本号还没提示过（`UserDefaults.hasShownBetaWarningVersion`）。
///
/// 用**版本号**而不是 Bool 记录：换一个新的 beta 会再提示一次，同一个 beta 反复
/// 冷启动只弹一次 —— 既满足"首次启动提示"，也不会每次开 App 都烦人。
///
/// 时机：`EeveeSpotify.init()` 末尾调用，延后几秒再弹 —— init 时 Spotify 的窗口
/// 还没建好，`PopUpHelper` 的 presenter 也还没被创建。只有真的交给 presenter
/// （`onPresented`）才写版本号；如果那一刻正好有别的弹窗在显示，下一次启动会再试。
enum BetaVersionNotice {

    /// 延迟秒数：Spotify 冷启动到首屏通常 2~3 秒，留一点余量，避免弹窗和
    /// 启动动画/引导页打架。
    private static let delay: TimeInterval = 5

    static func scheduleIfNeeded() {
        let version = EeveeSpotify.version
        guard version.lowercased().contains("-beta") else { return }
        guard UserDefaults.hasShownBetaWarningVersion != version else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            // 这几秒里可能已经被别的启动路径写过（同一次启动 init 只跑一次，
            // 但设置页的重启流程可能让模块重新装载）。
            guard UserDefaults.hasShownBetaWarningVersion != version else { return }

            writeDebugLog("[Beta] showing the beta warning for \(version)")
            PopUpHelper.showPopUp(
                delayed: false,
                message: "beta_version_warning".localized,
                buttonText: "OK".uiKitLocalized,
                onPresented: {
                    UserDefaults.hasShownBetaWarningVersion = version
                    writeDebugLog("[Beta] beta warning presented — not showing it again for \(version)")
                }
            )
        }
    }
}
