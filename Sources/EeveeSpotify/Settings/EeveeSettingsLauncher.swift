import SwiftUI
import UIKit

/// 从**任意视图**打开 EeveeSpotify 设置页。
///
/// ⚠️ 2026-10-13：**它现在的调用方只有设置列表里那一行**（`pushEeveeSettings`）。原来还有一个
/// "长按标签栏第一颗（主页）"的入口，**那个功能已按用户要求整体回退** ——
/// 见 `TabBarSystemGlass.installStockGestures` 里留下的那条结论（重做时**两条栏各装一遍**）。
/// 这个落点本身与手势无关，留着：将来重做时直接接上就行。
///
/// ## 出处：pw 的 `SGOpenModSettings`
///
/// 借鉴 **spoti.pw v0.21.1**（**GPL-3.0**；v0.22.0 起改为 PolyForm Strict，那里的代码不可复制）。
/// 长按那两只手势在 `Native/Navbar/TabBarHooks.x`（`SGHomeHold`）与
/// `Redesigned/Navbar/TabBar.x:228-239`（`SGRSystemTabBar` 的 `held:`），
/// 两边最后都落到 `App/ModSettings.x` 的这一个函数上：
///
/// ```objc
/// void SGOpenModSettings(UIView *source) {
///     UIViewController *owner = nil;
///     for (UIResponder *r = source; r && !owner; r = r.nextResponder) {
///         if ([r isKindOfClass:UIViewController.class]) owner = (UIViewController *)r;
///     }
///     UINavigationController *nav = nil;
///     for (UIViewController *page = owner; page && !nav; page = page.parentViewController) nav = navigationIn(page);
///     SGShowPage(nav.topViewController ?: SGTopController(), modSettingsPage());
/// }
/// ```
///
/// 也就是两步：**沿 responder 链找控制器**，再**沿 `parentViewController` 找一个导航栈**
/// （它的 `navigationIn` 是"递归找子 VC 里的 `UINavigationController`"，不是只看
/// `viewController.navigationController` —— 标签栏那个控制器本身不在栈里，栈在它的子 VC 里）。
///
/// 我们多一条兜底：**实在没有栈就 present 一层自己的栈**。理由：长按主页这条路上我们不一定
/// 找得到栈，而"按了没反应"是不能接受的（那正是用户抱怨过的那类问题）。
/// 这条兜底只在标签栏那种"控制器不在栈里"的场合才会走到。
///
/// ⚠️ 与 `EeveeSettingsUniversal.x.swift` 里设置列表那一行**共用同一份页面**
/// （`makePage`）—— 两处各写一份迟早会漂（那颗 GitHub 按钮、标题、尺寸都会）。
enum EeveeSettingsLauncher {

    /// 打开设置页。返回是否成功（**认不出就什么都不做** —— 不猜、不崩，与本仓库同一条纪律）。
    @discardableResult
    static func open(from view: UIView, reason: String) -> Bool {
        guard let owner = viewController(of: view) else {
            writeDebugLog("[Settings] \(reason): no view controller above that view — nothing was opened")
            return false
        }

        // ① pw 那条路：找得到栈就 push 上去（设置页因此有 Spotify 自己的返回手势与转场）。
        if let navigation = navigation(in: owner) {
            let page = makePage(in: navigation, size: owner.view.bounds)
            navigation.pushViewController(page, animated: true)
            writeDebugLog("[Settings] \(reason): pushed onto Spotify's own stack (\(type(of: navigation)))")
            return true
        }

        // ② 兜底：自己 present 一层栈（标签栏控制器本身通常不在任何栈里）。
        guard let presenter = top(of: owner) else {
            writeDebugLog("[Settings] \(reason): no stack to push onto and nobody to present from — nothing was opened")
            return false
        }
        let navigation = UINavigationController()
        // 自己 present 出来的这层**不在 Spotify 的导航栈里** ⇒ 外观会跟着系统走（浅色模式的手机上
        // 会得到亮色页面）。Spotify 永远是深色，这一层也显式设成深色。
        navigation.overrideUserInterfaceStyle = .dark
        navigation.setViewControllers([makePage(in: navigation, size: presenter.view.bounds)], animated: false)
        presenter.present(navigation, animated: true)
        writeDebugLog("[Settings] \(reason): no stack to push onto — presented \(type(of: presenter)) instead")
        return true
    }

    /// 设置页本体（含右上角那颗 GitHub 按钮）。设置列表那一行也走这里，两处因此永远一致。
    static func makePage(in navigation: UINavigationController, size: CGRect) -> EeveeSettingsViewController {
        let page = EeveeSettingsViewController(
            size,
            settingsView: AnyView(EeveeSettingsView(navigationController: navigation)),
            navigationTitle: "EeveeSpotify"
        )

        let subButton = UIButton(type: .system)
        if let bundleImage = BundleHelper.shared.uiImage("hex"), bundleImage.size != .zero {
            subButton.setImage(bundleImage.withRenderingMode(.alwaysOriginal), for: .normal)
        } else {
            subButton.setImage(UIImage(systemName: "globe"), for: .normal)
        }
        subButton.tintColor = .white
        subButton.addAction(UIAction { [weak page] _ in
            page?.openRepositoryUrl(subButton)
        }, for: .touchUpInside)

        let menuBarItem = UIBarButtonItem(customView: subButton)
        menuBarItem.customView?.heightAnchor.constraint(equalToConstant: 22).isActive = true
        menuBarItem.customView?.widthAnchor.constraint(equalToConstant: 22).isActive = true
        page.navigationItem.rightBarButtonItem = menuBarItem
        return page
    }

    // MARK: - 找那两样（pw 的 `SGOpenModSettings` 逐字）

    /// 沿 responder 链找第一个控制器。
    private static func viewController(of view: UIView) -> UIViewController? {
        var responder: UIResponder? = view
        var level = 0
        while let current = responder, level < 64 {
            level += 1
            if let controller = current as? UIViewController { return controller }
            responder = current.next
        }
        return nil
    }

    /// 先问控制器自己**在不在栈上**，再沿 `parentViewController` 找（pw 的顺序是直接沿 parent 找）。
    private static func navigation(in controller: UIViewController) -> UINavigationController? {
        if let direct = controller.navigationController { return direct }
        var page: UIViewController? = controller
        var level = 0
        while let current = page, level < 32 {
            level += 1
            if let found = navigationIn(current) { return found }
            page = current.parent
        }
        return nil
    }

    /// pw 的 `navigationIn`：**递归找子 VC 里的导航栈**（栈在子 VC 里，不在标签栏控制器自己身上）。
    private static func navigationIn(_ controller: UIViewController) -> UINavigationController? {
        if let navigation = controller as? UINavigationController { return navigation }
        for child in controller.children {
            if let found = navigationIn(child) { return found }
        }
        return nil
    }

    /// 最上层那个**能 present 的**控制器（present 出去的那一层也要一起找）。
    private static func top(of controller: UIViewController) -> UIViewController? {
        var current: UIViewController? = controller
        var level = 0
        while let page = current, level < 32 {
            level += 1
            if let presented = page.presentedViewController {
                current = presented
                continue
            }
            if let navigation = page as? UINavigationController, let visible = navigation.visibleViewController {
                current = visible
                continue
            }
            if let tabs = page as? UITabBarController, let selected = tabs.selectedViewController {
                current = selected
                continue
            }
            return page
        }
        return current
    }
}
