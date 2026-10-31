import Foundation
import Orion
import UIKit
import ObjectiveC.runtime

// MARK: - 用 App 自己的链接分发器打开一个 `spotify:` URI
//
// 艺人页那张「最新发布」卡片的数据改由 Spotify 自己的 Web API 提供时，
// 它手里只有一个 **`spotify:album:…`**（页面里"那一格"还没建出来，没法转发点击）。
// 要打开它，最稳的一条路就是 App **自己的**链接分发器 —— 与真人点一条 `spotify:` 链接
// 完全同一条链路（落地页 / 导航栈都由 Spotify 自己决定）。
//
// 目标类与调用形状来自 pw v0.21.1 的 `tweak/Sources/Shared/Navigation/Links.x`（逐字）：
//
// ```
// %hook SPTLinkDispatcherImplementation
// - (void)setMainUILoaded:(BOOL)loaded { %orig; sg_linkDispatcher = self; }   // 单例初始化的最后一次调用
// ...
// [dispatcher navigateToURI:uri options:0 interactionID:nil];
// ```
//
// 两条纪律：
// · 单例是 **weak**（我们只是借用 App 的对象，绝不持有 —— 也就不会成环）；
// · 目标类不在（换版 / 改名）就只记一行日志：卡片退回"只转发页面里那一格"，不崩、不猜。
//
// 3 个参数的那条 `navigateToURI:options:interactionID:`。
//
// `id` → `AnyObject`、`SEL` → `Selector`、`NSURL *` → `NSURL`、`options`（整数 0）→ `Int64`、
// `interactionID`（nil）→ `AnyObject?`。返回值在真机上是 void（pw 那边也不取）。
private typealias SpotifyNavigateFunction = @convention(c) (
    AnyObject,
    Selector,
    NSURL,
    Int64,
    AnyObject?
) -> Void

struct SpotifyURIOpenerGroup: HookGroup {}

/// `-setMainUILoaded:` 是那个单例初始化的**最后一次调用**（pw 的 `Links.x` 逐字注释：
/// "the last call of its setup (objc-methods.txt:38809)"）—— 挂它，实例一到手就记住。
class SPTLinkDispatcherMainUILoadedHook: ClassHook<NSObject> {
    typealias Group = SpotifyURIOpenerGroup
    static let targetName = "SPTLinkDispatcherImplementation"

    func setMainUILoaded(_ loaded: Bool) {
        orig.setMainUILoaded(loaded)
        // ⚠️ 先把 `target` 取成局部量再往外传（本仓库既有做法，见 `CoverFlashGuard.x.swift`）：
        // Orion 生成的 `target` 属性挂在 hook 实例上，闭包/属性访问别把它一起捕获住。
        let dispatcher = target
        SpotifyURIOpener.attach(dispatcher)
    }
}

enum SpotifyURIOpener {

    /// App 自己那个链接分发器。**弱引用**：我们只借用，不持有（也就不会成环）。
    private static weak var dispatcher: NSObject?

    /// 取 3 个参数那条选择器（拼写与 pw 逐字一致）。
    private static let navigateSelectorName = "navigateToURI:options:interactionID:"

    /// 分发器抓到没有。
    ///
    /// 没抓到时 `open` 会退回 `UIApplication.open(spotify:…)` ——
    /// 对 App 自己那个 scheme 是**空操作**（不会弹、也不会跳）。调用方（听歌页的歌名/艺人点击）
    /// 据此改走"转发给原生控件"，而不是让用户觉得"点上去没反应"。
    static var isReady: Bool { dispatcher != nil }

    // MARK: - 交给 hook 的那一半
    //
    // `-setMainUILoaded:` 把单例交过来时调用（**主线程**，App 启动阶段）。
    static func attach(_ object: AnyObject) {
        guard let candidate = object as? NSObject else {
            writeDebugLog("[LinkOpen] setMainUILoaded: — the object is not an NSObject, nothing captured")
            return
        }
        let same = SpotifyURIOpener.dispatcher === candidate
        SpotifyURIOpener.dispatcher = candidate
        guard !same else { return }
        let kind = NSStringFromClass(type(of: candidate))
        writeDebugLog("[LinkOpen] captured the app's link dispatcher — \(kind)")
    }

    // MARK: - 打开一个 URI
    //
    // 用 App 自己的分发器打开 `uri`。返回"有没有把这一下交出去"（不是"页面有没有跳"）。
    //
    // - Note: 卡片点击本来就在主线程；万一不是，就排到主队列再打开（导航必须在主线程）。
    @discardableResult
    static func open(_ uri: String) -> Bool {
        let trimmed = uri.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            writeDebugLog("[LinkOpen] asked to open an empty uri, nothing done")
            return false
        }
        guard trimmed.lowercased().hasPrefix("spotify:") else {
            writeDebugLog("[LinkOpen] refused — not a spotify uri: \(trimmed)")
            return false
        }
        guard let url = URL(string: trimmed) else {
            writeDebugLog("[LinkOpen] refused — could not build a URL from \(trimmed)")
            return false
        }

        guard Thread.isMainThread else {
            writeDebugLog("[LinkOpen] \(trimmed) came in off the main thread, queued on the main queue")
            DispatchQueue.main.async { _ = open(trimmed) }
            return true
        }
        guard let dispatcher = SpotifyURIOpener.dispatcher else {
            return fallbackOpen(
                url,
                uri: trimmed,
                reason: "the link dispatcher is not captured yet (setMainUILoaded: never fired)"
            )
        }

        let selector = NSSelectorFromString(navigateSelectorName)
        let kind = NSStringFromClass(type(of: dispatcher))
        guard dispatcher.responds(to: selector) else {
            return fallbackOpen(
                url,
                uri: trimmed,
                reason: "\(kind) has no \(navigateSelectorName)"
            )
        }
        guard let method = class_getInstanceMethod(type(of: dispatcher), selector) else {
            return fallbackOpen(
                url,
                uri: trimmed,
                reason: "the navigate method could not be looked up on \(kind)"
            )
        }

        // ⚠️ 三个参数：`(id, SEL, NSURL *, int64 0, nil)`。
        //
        // 为什么是 `method_getImplementation` 而不是 `objc_msgSend`：两者**同一个函数指针**，
        // 但 `objc_msgSend` 在 Swift 里能不能被 import 到取决于工具链（本机没有 Swift 编译器，
        // 没法当场验证）—— `method_getImplementation` 一定在 `ObjectiveC.runtime` 里。
        // 行为完全一致：同样的选择器、同样三个参数、同样 `unsafeBitCast`。
        let navigate = unsafeBitCast(
            method_getImplementation(method),
            to: SpotifyNavigateFunction.self
        )
        navigate(dispatcher, selector, url as NSURL, 0, nil)
        writeDebugLog("[LinkOpen] opened \(trimmed) through the app's own link dispatcher")
        return true
    }

    /// 分发器那条路走不通时的最后兜底：交回 `UIApplication.open`（App 注册了 `spotify` scheme）。
    ///
    /// 它不如分发器可控（可能先弹一次"在 Spotify 中打开"），但用户点卡片时**至少有个反应** ——
    /// 而且这条只在"hook 没装上 / 类改名"时才走，正常真机一次都用不到。
    private static func fallbackOpen(_ url: URL, uri: String, reason: String) -> Bool {
        writeDebugLog("[LinkOpen] \(reason) — falling back to UIApplication.open for \(uri)")
        DispatchQueue.main.async {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        }
        return true
    }
}

/// 装这一组。目标类缺失就只打一行日志（与 `activateCoverFlashGuard` 同一条纪律）。
///
/// ⚠️ **不按开关决定装不装**：这条 hook 只记一个弱引用，门禁在卡片那一侧
/// （「艺人页自画页头」开着才可能画出可点的卡片）。装了再判比"按开关重装"稳。
func activateSpotifyURIOpener() {
    let targetName = SPTLinkDispatcherMainUILoadedHook.targetName
    if NSClassFromString(targetName) != nil {
        SpotifyURIOpenerGroup().activate()
        writeDebugLog("[LinkOpen] armed on \(targetName)")
    } else {
        writeDebugLog(
            "[LinkOpen] missing \(targetName) — the latest-release card can only forward a page cell,"
                + " it cannot open an album by uri"
        )
    }
}
