import SwiftUI

extension EeveeLyricsSettingsView {

    /// 选中 Musixmatch 但还没有合法令牌时的**可选**填写弹窗。
    ///
    /// ★ 2026-10-13（匿名令牌接回来之后）：这个弹窗**不再强制**，也**不再回退来源选择**。
    ///   · 匿名令牌那条路是自动的（`AnonymousTokenHelper` → 取词时
    ///     `MusixmatchLyricsRepository.ensureTokenIfNeeded()` 自己换一个），
    ///     所以"没有令牌"根本不影响能不能用 Musixmatch；
    ///   · 填自己的令牌 = 用**自己账号的额度**，这是唯一需要它的场景；
    ///   · 因此取消、或粘进来的东西识别不出令牌，都**保留 Musixmatch 这个选择**
    ///     （旧版会把来源改回去，等于"选了 Musixmatch 却不让你用"——与自动路径自相矛盾）。
    ///
    /// 两种粘贴形态都认（`getMusixmatchTokenFromDebugInfo` / `getMusixmatchToken`）：
    ///   · Musixmatch 官方 App 里「设置 > 获取帮助 > 复制调试信息」整段；
    ///   · 或者直接贴 54 位小写十六进制令牌。
    ///
    /// ⚠️ 历史：这个弹窗**曾经从来没被调用过** —— 唯一的调用点是
    /// `EeveeLyricsSettingsView.swift` 里 `.onReceive(viewModel.musixmatchTokenInputAlertPublisher)`，
    /// 而那个 `PassthroughSubject` 全工程没有任何一处 `send`。
    /// 现在由 `lyricsSourceBinding` 在选中的那一刻直接调用，那个死订阅没有带回来。
    func showMusixmatchTokenAlert() {
        let alert = UIAlertController(
            title: "musixmatch_token_optional_title".localized,
            message: "musixmatch_token_optional_message".localized,
            preferredStyle: .alert
        )

        alert.addTextField() { textField in
            textField.placeholder = "---- Debug Info ---- [Device]: \(UIDevice.current.isIpad ? "iPad" : "iPhone")"
        }

        // 取消 = 什么都不做（**不回退来源**）：匿名令牌会在取词时自动换一个。
        alert.addAction(UIAlertAction(title: "Cancel".uiKitLocalized, style: .cancel))

        alert.addAction(UIAlertAction(title: "OK".uiKitLocalized, style: .default) { _ in
            let text = alert.textFields?.first?.text ?? ""

            // 识别不出就当用户没填：**仍然保留 Musixmatch**，不打断他的选择。
            guard let token =
                viewModel.getMusixmatchTokenFromDebugInfo(text)
                ?? viewModel.getMusixmatchToken(text)
            else {
                return
            }

            viewModel.musixmatchToken = token
            UserDefaults.musixmatchTokenIsAnonymous = false
        })

        WindowHelper.shared.present(alert)
    }
}
