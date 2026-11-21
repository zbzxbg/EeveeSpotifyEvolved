import Foundation
import UIKit

/// iPad 上的一次性回退：把两条"按 iPhone 标签栏量的"玻璃关掉，并告诉用户为什么。
///
/// 为什么不在 iPad 上直接支持：标签栏玻璃的做法是"藏掉 Spotify 那条栏、在上面叠一条系统
/// `UITabBar`"，iPad 是常规宽度栏（931×76，自带 `UIVisualEffectView`），叠上去形态不对；
/// 迷你条玻璃的宽度在 iPhone 上取自标签栏胶囊，iPad 上没有这条参照。
///
/// 只做一次：跑过就把 `ipadFallbackHandled` 置位，之后尊重用户在设置里重新打开的开关。
enum IPadFallback {

    /// 启动早期调一次（默认值补偿之后、玻璃启动快照之前）。
    static func applyIfNeeded() {
        guard UIDevice.current.isIpad else { return }
        guard !UserDefaults.ipadFallbackHandled else { return }
        UserDefaults.ipadFallbackHandled = true

        // 两条玻璃 + 实体页整套外观：都是按 iPhone 的尺寸/栏位做的。
        let hadGlass = UserDefaults.tabBarSystemGlass || UserDefaults.miniBarGlass
        let hadPageLook = UserDefaults.entityPageDissolve
            || UserDefaults.entityPageAMHeader
            || UserDefaults.entityPageHideChrome
            || UserDefaults.playlistSingleCover
            || UserDefaults.artistHideTabs
        // 已经是原生的就不用打扰：回退动作本身没有可回退的东西。
        guard hadGlass || hadPageLook else { return }

        UserDefaults.tabBarSystemGlass = false
        UserDefaults.miniBarGlass = false
        UserDefaults.entityPageDissolve = false
        UserDefaults.entityPageAMHeader = false
        UserDefaults.entityPageHideChrome = false
        UserDefaults.playlistSingleCover = false
        UserDefaults.artistHideTabs = false
        writeDebugLog(
            "[INIT] iPad: reverted the iPhone-only looks — both glass bars (tab bar / mini bar)"
                + " and the artist / album / playlist page appearance are back to Spotify's native layout"
        )

        // 等窗口起来再弹：启动第 0 秒可能还没有 key window。
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            presentNotice()
        }
    }

    private static func presentNotice() {
        let alert = UIAlertController(
            title: "ipad_fallback_title".localized,
            message: "ipad_fallback_message".localized,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "ipad_fallback_restart".localized, style: .default) { _ in
            exitApplication()
        })

        // 自己找当前最上层的 VC：`WindowHelper` 在第一次访问时就强解包 key window，
        // 启动阶段拿它不安全。
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let root = scenes.flatMap({ $0.windows }).first(where: { $0.isKeyWindow })?.rootViewController
            ?? scenes.flatMap({ $0.windows }).first?.rootViewController else {
            return
        }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        top.present(alert, animated: true)
    }
}
