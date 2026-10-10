import Foundation
import ObjectiveC.runtime
import Orion
import UIKit

/// **状态栏明暗跟着"页面取色"翻** —— 也就是 Apple Music 解决"照片铺到屏幕最顶"的办法。
///
/// ## 为什么需要它（用户 2026-10-17 的两张 AM 截图是判决）
///
/// `C:\dsh\readpicture\118.jpg`（Nanatsukaze）状态栏是**黑字**，`119.jpg`（Michael Jackson）是
/// **白字** —— 同一个 app、同一台机器，差别只有一个：页面取色的明暗。AM 不是靠"给照片留一条白"
/// 解决刘海/灵动岛压在照片上的，**是靠翻状态栏**。
///
/// 我们这边原来**一处都没碰过状态栏** ⇒ 亮封面（照片 115 的"你已点赞"）上白字直接消失。
///
/// ## 挂点为什么是 `preferredStatusBarStyle`（实测，不是猜的）
///
/// * IPA 解出来的 `C:\dsh\ipa\Payload\Spotify.app\Info.plist` 里
///   `UIStatusBarStyle = UIStatusBarStyleLightContent`，而
///   **`UIViewControllerBasedStatusBarAppearance` 这个键不存在** ⇒ 取默认值 `YES`
///   ⇒ 状态栏由 **view controller 那条链**决定，不是 app 级开关。
/// * 主二进制里 `statusBarStyle` / `setStatusBarStyle:` **0 次命中**（`UIApplication` 那条老路它没用），
///   而 `preferredStatusBarStyle` / `childViewControllerForStatusBarStyle` 各有命中
///   ⇒ 走的就是 VC 这条路，而且 app 侧几乎没有自己的状态栏机制。
///
/// ⇒ hook `UIViewController.preferredStatusBarStyle`：**没被我们强制时原样 `orig`**，
/// 对 app 自己那套（歌词页、视频流里的 `ColorBasedStatusBarSettingsManager`…）完全透明。
/// 判据只有一条，**与底色/文字反色共用 `EntityPageAppearance.isLight`**，不另立阈值。
///
/// ## ⚠️ 唯一的不确定，以及它为什么不会静默失败
///
/// 如果 Spotify 某一层基类**自己实现了** `preferredStatusBarStyle`，那么对它那些子类来说，
/// 挂在 `UIViewController` 上的这个 swizzle 是**被遮住**的（子类实现优先于父类）。
/// 所以这里在第一次真的要用它时打一行诊断：把 `root → 决策 VC` 那条链、以及链上**谁自己实现了
/// 这个方法**（带 `*`）一起报出来。下一份真机日志就能判定要不要改挂到那个具体类上。
///
/// ⚠️ 只在「封面下缘溶解」那颗开关开着时才有意义（它和取色底是同一套外观）——
/// 与 `EntityPageRepaint` 同一条纪律：开关关掉，这里连 hook 都不装。
enum EntityPageStatusBar {

    static let logTag = "PageStatusBar"

    /// 我们要强制的那一档；`nil` = 不干涉，原样交回 `orig`。
    ///
    /// ⚠️ 写成"私有存储 + 只读计算属性"而不是 `private(set) static var`：本仓库的
    /// `swift_member_check.py` 那正则认不出 `private(set)` 这种修饰符写法，会把
    /// `EntityPageStatusBar.forced` 误判成"类型里没有这个成员"（2026-10-17 实测踩到）。
    private static var forcedStyle: UIStatusBarStyle?
    static var forced: UIStatusBarStyle? { forcedStyle }

    /// 上一次**真正请求过**的值 —— 只有变了才写，免得 0.6s 那一拍每次都去叫 UIKit 重问。
    private static var requested: UIStatusBarStyle?
    /// 诊断只打一次。
    private static var didReportChain = false

    /// 由 `EntityPageAppearance.ensureField` 每拍调一次（值没变时只是一次比较）。
    static func apply(_ style: UIStatusBarStyle?) {
        guard style != requested else { return }
        requested = style
        forcedStyle = style
        reportChainOnce()
        refresh()
        // ⚠️ 拼好再传：**字符串插值里不要出现引号** —— 本仓库 `swift_member_check.py` 那套
        //    "去掉字符串"的扫描器遇到嵌套引号会提前收尾，剩下的英文单词会被当成裸标识符误报
        //    （2026-10-17 实测，`status` 就是这么被报出来的）。
        let described = style.map { name(of: $0) } ?? "released — the app's own style applies again"
        writeDebugLog("[\(logTag)] \(described)")
    }

    /// 放开（离开页面 / 关开关）。
    static func release() {
        apply(nil)
    }

    /// 让 UIKit 重新问一遍那条链：**只问根**，`childForStatusBarStyle` 会把问题带下去。
    private static func refresh() {
        guard let root = EntityPageAppearance.frontWindow()?.rootViewController else { return }
        root.setNeedsStatusBarAppearanceUpdate()
    }

    private static func name(of style: UIStatusBarStyle) -> String {
        switch style {
        case .darkContent: return "dark text (the page's colour is light — AM does the same)"
        case .lightContent: return "light text (the page's colour is dark)"
        default: return "style \(style.rawValue)"
        }
    }

    // MARK: - 诊断（只打一次）

    /// 把"最后是谁在决定状态栏"与"链上谁自己实现了它"报一次。
    ///
    /// 为什么值得这十几行：**这个 hook 有可能被 Spotify 自己的基类遮住**，而那种失败在界面上
    /// 只表现为"状态栏没变"，与"我们算错了颜色"长得一模一样。一行日志就能把两者分开。
    private static func reportChainOnce() {
        guard !didReportChain, let root = EntityPageAppearance.frontWindow()?.rootViewController else {
            return
        }
        didReportChain = true

        // 决策 VC：沿着 `childForStatusBarStyle` 一路问到底（容器会返回它的孩子）。
        var deciding = root
        for _ in 0..<8 {
            guard let child = deciding.childForStatusBarStyle else { break }
            deciding = child
        }

        // 它自己、以及它每一层祖先，谁实现了 `preferredStatusBarStyle` —— 带 `*` 的就是能遮住我们的。
        var classes: [String] = []
        var cls: AnyClass? = type(of: deciding)
        for _ in 0..<8 {
            guard let current = cls else { break }
            classes.append("\(NSStringFromClass(current))\(ownsStatusBarStyle(current) ? "*" : "")")
            cls = class_getSuperclass(current)
        }

        writeDebugLog(
            "[\(logTag)] deciding controller \(NSStringFromClass(type(of: deciding)))"
                + " in \(NSStringFromClass(type(of: root)));"
                + " `*` marks a class that implements preferredStatusBarStyle itself"
                + " (those are the ones that would shadow our hook): \(classes.joined(separator: " < "))"
        )
    }

    /// 这个类**自己**有没有实现 `preferredStatusBarStyle`（只看它自己的方法表，不算继承来的）。
    private static func ownsStatusBarStyle(_ cls: AnyClass) -> Bool {
        var count: UInt32 = 0
        guard let methods = class_copyMethodList(cls, &count) else { return false }
        defer { free(methods) }
        let wanted = #selector(getter: UIViewController.preferredStatusBarStyle)
        for index in 0..<Int(count) where method_getName(methods[index]) == wanted {
            return true
        }
        return false
    }
}

// MARK: - 挂点

struct EntityPageStatusBarGroup: HookGroup {}

/// hook 类不能加 `final`/`private`/`fileprivate`（Orion 要为它生成胶水子类）。
class EntityPageStatusBarHook: ClassHook<UIViewController> {
    typealias Group = EntityPageStatusBarGroup
    static let targetName = "UIViewController"

    func preferredStatusBarStyle() -> UIStatusBarStyle {
        if let forced = EntityPageStatusBar.forced { return forced }
        return orig.preferredStatusBarStyle()
    }
}

/// ★★ 2026-10-10（**日志 94 那行诊断第一次跑就把答案给了**）：
///
/// ```
/// deciding controller Navigation_PageAPIIntegrationImpl.MusicAppPageHostingViewController
///   in ContainerUI_RootUIInternalImpl.RootViewController;
///   `*` marks a class that implements preferredStatusBarStyle itself:
///   …MusicAppPageHostingViewController
///     < …IdentifiedPageHostingViewController*      ← 它**自己实现了**
///     < Tome_PageRuntime.PageHostingViewController
///     < UIViewController* < UIResponder < NSObject
/// ```
///
/// 带 `*` 的那个类自己实现了 `preferredStatusBarStyle` ⇒ **子类实现优先** ⇒ 挂在 `UIViewController`
/// 上的那个 swizzle 对 `MusicAppPageHostingViewController` 这一族**是被遮住的**，
/// 状态栏一个字都不会变（这正是那行诊断存在的理由：把"没生效"和"算错了颜色"分开）。
///
/// ⇒ 再挂一层：**就是那个类本身**。两个 hook 同时装着、各管各的（没被我们强制时都原样 `orig`），
/// 谁也挡不住谁。
class EntityPageStatusBarHostHook: ClassHook<UIViewController> {
    typealias Group = EntityPageStatusBarGroup
    static let targetName = "_TtC33Navigation_PageAPIIntegrationImpl35IdentifiedPageHostingViewController"

    func preferredStatusBarStyle() -> UIStatusBarStyle {
        if let forced = EntityPageStatusBar.forced { return forced }
        return orig.preferredStatusBarStyle()
    }
}

func activateEntityPageStatusBar() {
    // 与 `EntityPageRepaint` 同一条纪律：状态栏只为「满幅封面 + 取色底」那颗开关服务。
    guard UserDefaults.entityPageDissolve else {
        writeDebugLog("[\(EntityPageStatusBar.logTag)] off — the page field switch is off")
        return
    }

    EntityPageStatusBarGroup().activate()
    let host = EntityPageStatusBarHostHook.targetName
    let hostPresent = NSClassFromString(host) != nil
    writeDebugLog(
        "[\(EntityPageStatusBar.logTag)] on — preferredStatusBarStyle is ours: the status bar follows"
            + " the page's cover colour (AM flips it the same way: dark text on a light artist page,"
            + " light text on a dark one); the page host class \(hostPresent ? "is" : "is NOT")"
            + " present, so the shadowing hook \(hostPresent ? "is" : "is not") armed too"
    )
}
