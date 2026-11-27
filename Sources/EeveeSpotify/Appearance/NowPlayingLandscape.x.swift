import Foundation
import UIKit
import Orion
import ObjectiveC.runtime

// 横屏听歌页。
//
// Spotify 自己只认竖屏：App delegate 的 `application:supportedInterfaceOrientationsForWindow:`
// 返回的遮罩里没有横屏，所以整机横过来它也不转。这一条只做两件事：
//
// 1. **开闸**：听歌页在屏上、开关打开时，把那个遮罩并上横屏；其余页面保持原样。
// 2. **排版**：横过来时让 `NowPlayingIOS27` 自动进"页内歌词"（封面缩成缩略图、歌词铺满），
//    并把底排那 -55pt 的抬升收回去 —— 横屏只有 414pt 高，再抬就压到歌词上。
//
// ⚠️ 竖屏锁定开着时**什么都不转**。那是系统层面的锁：遮罩放宽不等于强行旋转。
// 与 pw 的文案一致（"Nothing turns while Portrait Orientation Lock is on"）。
//
// 做法对照：pw（chroma.pw 1.1.0）钩的也是同一个方法，并在开关变化后调
// `setNeedsUpdateOfSupportedInterfaceOrientations`（它的二进制里有这个符号）；
// 它没有用已废弃的 `attemptRotationToDeviceOrientation`，这里也不要用。

struct NowPlayingLandscapeGroup: HookGroup {}

enum NowPlayingLandscape {

    static let logTag = "Landscape"

    /// 只在 **AM 布局**（`nowPlayingIOS27`）下有意义：那一版布局是我们自己画的，横过来能重排；
    /// 旧那版是 Spotify 的原生版式，转了只会得到一张被拉长的竖屏，不如不转。
    static var isEnabled: Bool {
        UserDefaults.nowPlayingLandscapeLyrics && UserDefaults.nowPlayingIOS27
    }

    /// 听歌页在屏上 —— 只有这时才放宽遮罩。
    ///
    /// `NowPlayingIOS27` 是 `@MainActor` 的，而这一层是**非隔离**的（朝向钩子必须非隔离，
    /// 见 `LyricsChromeVisibility.swift` 文件头）⇒ 读它的 `lastPage` 要用 `onMainThreadValue`
    /// 把"就在主线程"显式表达出来。UIKit 只在主线程问朝向，所以不会走到 `false` 那一支。
    static var isPlayerOnScreen: Bool {
        onMainThreadValue(false) {
            guard let page = NowPlayingIOS27.lastPage else { return false }
            return page.window != nil
        }
    }

    /// 把窗口遮罩并上横屏（不该放宽时原样返回）。
    @discardableResult
    static func widened(_ mask: UIInterfaceOrientationMask) -> UIInterfaceOrientationMask {
        guard isEnabled, isPlayerOnScreen else { return mask }
        return mask.union(.landscape)
    }

    /// 拨完开关、或离开听歌页之后叫一次：让 UIKit 重新问一遍方向。
    ///
    /// 用 iOS 16 的 `setNeedsUpdateOfSupportedInterfaceOrientations` —— 老的
    /// `attemptRotationToDeviceOrientation` 已经废弃。竖屏锁定开着时这一步不会转，
    /// 锁在系统那边，不是我们该绕的。
    static func refreshOrientation() {
        guard let vc = orientationViewController() else { return }
        vc.setNeedsUpdateOfSupportedInterfaceOrientations()
    }

    /// 问方向时**该问谁**：听歌页在屏上就问它自己那一层 VC，否则问最顶上的。
    ///
    /// 整段都要摸 UIKit（还要读 `NowPlayingIOS27.lastPage`）⇒ 同一条纪律，走 `onMainThreadValue`；
    /// 不在主线程时返回 nil（`refreshOrientation` 就什么都不做，下一次调用会补上）。
    static func orientationViewController() -> UIViewController? {
        onMainThreadValue(nil as UIViewController?) {
            if let page = NowPlayingIOS27.lastPage {
                var responder: UIResponder? = page
                while let current = responder, !(current is UIViewController) {
                    responder = current.next
                }
                if let pageViewController = responder as? UIViewController {
                    return pageViewController
                }
            }

            let keyWindow = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first { $0.isKeyWindow }
            var controller = keyWindow?.rootViewController
            while let presented = controller?.presentedViewController {
                controller = presented
            }
            return controller
        }
    }

    // MARK: - 日志
    //
    // 遮罩这个方法是**高频**的（每次旋转、每个模态呈现都会问一遍），所以只在
    // "结论变化的那一次"写：哪一次开始放宽、哪一次又被收回去。

    private static var loggedWidened: Bool?

    static func noteMask(original: UIInterfaceOrientationMask, widened: UIInterfaceOrientationMask) {
        let isWidened = widened != original
        guard loggedWidened != isWidened else { return }
        loggedWidened = isWidened
        writeDebugLog(
            "[\(logTag)] window mask \(describe(original)) → \(describe(widened))"
                + (isWidened ? " (player on screen)" : " (left alone)")
        )
    }

    private static func describe(_ mask: UIInterfaceOrientationMask) -> String {
        if mask == .portrait { return "portrait" }
        if mask == .allButUpsideDown { return "allButUpsideDown" }
        var parts: [String] = []
        if mask.contains(.portrait) { parts.append("portrait") }
        if mask.contains(.portraitUpsideDown) { parts.append("upsideDown") }
        if mask.contains(.landscapeLeft) { parts.append("landscapeLeft") }
        if mask.contains(.landscapeRight) { parts.append("landscapeRight") }
        return parts.isEmpty ? "none" : parts.joined(separator: "+")
    }

    // MARK: - VC 那一层（真正拦横屏的地方）

    /// 这一层 VC 该不该放宽朝向。
    ///
    /// 只认"视图里真的托着听歌页"的那几层（听歌页自己的 VC 与它的容器）：盖在上面的
    /// sheet / 设置页 / 别的标签页一律原样返回，否则整个 App 都能转。
    static func widens(_ controller: UIViewController) -> Bool {
        guard isEnabled else { return false }
        return onMainThreadValue(false) {
            guard let page = NowPlayingIOS27.lastPage, page.window != nil else { return false }
            guard let host = controller.viewIfLoaded else { return false }
            return host === page || page.isDescendant(of: host)
        }
    }

    private static var loggedControllerWidened: Bool?

    static func noteControllerMask(
        _ type: AnyClass,
        original: UIInterfaceOrientationMask,
        widened: UIInterfaceOrientationMask
    ) {
        let isWidened = widened != original
        guard loggedControllerWidened != isWidened else { return }
        loggedControllerWidened = isWidened
        writeDebugLog(
            "[\(logTag)] view controller mask \(describe(original)) → \(describe(widened))"
                + " (\(NSStringFromClass(type)))"
        )
    }

    /// 第一次真的被问"这一层能不能转"时，把整条 VC 链打一遍（那一刻听歌页确实在屏上）。
    private static var didProbeChain = false

    static func noteChainProbeOnce() {
        guard !didProbeChain else { return }
        didProbeChain = true
        probeOrientationChain("first query with the player on screen")
    }

    /// 一次性诊断：从根 VC 走到最上层，逐层打"允许什么朝向 / 能不能转 / 是不是自己实现的"。
    ///
    /// 为什么需要：`supportedInterfaceOrientations` 是**子类实现优先**的（与
    /// `EntityPageStatusBar.x.swift` 里那条教训同一个机制）⇒ 挂在 `UIViewController` 上的
    /// swizzle 会被"自己实现了它"的容器 VC 整个挡住。不把这串链打出来就只能猜是谁在拦。
    static func probeOrientationChain(_ reason: String) {
        onMainThreadSync {
            guard let window = currentKeyWindow() else {
                writeDebugLog("[\(logTag)] orientation chain (\(reason)) — no key window")
                return
            }
            let maskSelector = #selector(getter: UIViewController.supportedInterfaceOrientations)
            let rotateSelector = #selector(getter: UIViewController.shouldAutorotate)
            var controller = window.rootViewController
            var depth = 0
            while let current = controller, depth < 8 {
                let type = type(of: current)
                writeDebugLog(
                    "[\(logTag)] chain[\(depth)] \(NSStringFromClass(type))"
                        + " mask=\(describe(current.supportedInterfaceOrientations))"
                        + " autorotate=\(current.shouldAutorotate)"
                        + " ownMask=\(implementsItself(type, maskSelector))"
                        + " ownAutorotate=\(implementsItself(type, rotateSelector))"
                )
                controller = current.presentedViewController
                    ?? (current as? UINavigationController)?.topViewController
                    ?? (current as? UITabBarController)?.selectedViewController
                depth += 1
            }
        }
    }

    private static func currentKeyWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
    }

    /// 这个类**自己**实现了这个方法吗（而不是从 `UIViewController` 继承来的）。
    ///
    /// 与 `EntityPageStatusBar.ownsStatusBarStyle` 同一个手法（那个只问状态栏那一个选择器）；
    /// 这里要问两个选择器，所以写成带参的。
    private static func implementsItself(_ type: AnyClass, _ selector: Selector) -> Bool {
        var count: UInt32 = 0
        guard let methods = class_copyMethodList(type, &count) else { return false }
        defer { free(methods) }
        for index in 0..<Int(count) where method_getName(methods[index]) == selector {
            return true
        }
        return false
    }
}

/// **VC 那一层的闸门** —— 真机上拦横屏的是它，不是 App delegate。
///
/// App delegate 的遮罩本来就含横屏（`allButUpsideDown` = 竖屏 + 左右横屏），所以"放宽
/// delegate"在真机上经常是空转；而 UIKit 的判据是
/// **app delegate 遮罩 ∩ 顶层 VC 的 `supportedInterfaceOrientations`** ⇒ 后者返回竖屏时，
/// 设备横过来屏幕一动不动。这里按"这一层托着听歌页、且开关打开"放宽，别的一律 `orig`。
///
/// ⚠️ `supportedInterfaceOrientations` 是子类实现优先的：如果 Spotify 的容器 VC 自己实现了，
/// 这个 `UIViewController` 级的 swizzle 会被挡住（见 `EntityPageStatusBar.x.swift` 里同样的
/// 教训）。真遇到那种情况，`probeOrientationChain` 打出的 `[Landscape] chain[…]` 会直接
/// 点出是哪一层、以及它是不是自己实现的。
class PlayerOrientationHook: ClassHook<UIViewController> {
    typealias Group = NowPlayingLandscapeGroup
    static let targetName = "UIViewController"

    func supportedInterfaceOrientations() -> UIInterfaceOrientationMask {
        let original = orig.supportedInterfaceOrientations()
        guard NowPlayingLandscape.widens(target) else { return original }
        NowPlayingLandscape.noteChainProbeOnce()
        let widened = original.union(.landscape)
        NowPlayingLandscape.noteControllerMask(
            type(of: target),
            original: original,
            widened: widened
        )
        return widened
    }

    func shouldAutorotate() -> Bool {
        if NowPlayingLandscape.widens(target) { return true }
        return orig.shouldAutorotate()
    }
}

/// Spotify 的 App delegate。9.2.2 上就是 `_TtC24MusicApp_ContainerWiring18SpotifyAppDelegate`
/// （pw 1.1.0 钩的也是这个方法：它二进制里带着 `supportedInterfaceOrientationsForWindow:`）。
///
/// ⚠️ 只放宽、不收窄：原来的遮罩原样并上横屏，别的朝向一个都不动。
class SpotifyAppOrientationHook: ClassHook<NSObject> {
    typealias Group = NowPlayingLandscapeGroup
    static let targetName = "_TtC24MusicApp_ContainerWiring18SpotifyAppDelegate"

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsForWindow window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        let original = orig.application(application, supportedInterfaceOrientationsForWindow: window)
        let widened = NowPlayingLandscape.widened(original)
        NowPlayingLandscape.noteMask(original: original, widened: widened)
        return widened
    }
}

/// 挂上去。目标类或方法不在就只记一行 —— 横屏功能整体不生效，别把 App 带崩。
func activateNowPlayingLandscape() {
    let className = SpotifyAppOrientationHook.targetName
    let selector = Selector(("application:supportedInterfaceOrientationsForWindow:"))

    guard let cls = NSClassFromString(className),
          class_getInstanceMethod(cls, selector) != nil else {
        writeDebugLog(
            "[\(NowPlayingLandscape.logTag)] \(className) has no"
                + " application:supportedInterfaceOrientationsForWindow: — the player stays portrait"
        )
        return
    }

    NowPlayingLandscapeGroup().activate()
    writeDebugLog("[\(NowPlayingLandscape.logTag)] orientation gate hooked (\(className))")
}
