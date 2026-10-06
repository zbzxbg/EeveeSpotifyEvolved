// 挡掉 Spotify 的 ClientMessagingPlatform（CMP）**营销面** —— 就是那两样东西：
//   · 全屏接管页："welcome back / Ends soon: 2 months of Premium"；
//   · 首页横幅："Final call: Get 2 months for $6.99"。
//
// 移植自上游 `EeveeSpotifyReincarnated/Sources/EeveeSpotify/ClientMessagingPlatformBlocker.x.swift`
// （195 行）。目标类名已用本仓库的 `C:\dsh\ipa\dump-9.1.88.txt` **逐条核对过**，7 个全在，
// 连 `P33_…` 那个哈希都一致。
//
// ## 为什么请求侧已经挡了，还要这一层
//
// 9.1.84 起这些消息走 `com.spotify.pendragon.v1.ClientMessageService`（FetchMessage 系列 RPC）。
// 请求侧在 `URL+Extension.swift` 的 `isPendragonFetchMessageList` 里已经拦住了 ——
// 但**已经落进 CMP 本地 SQLite 的消息**照样能弹出来，所以这里补一层**呈现侧**的兜底。
//
// ## 范围（别扩大）
//
// CMP 只承载服务端下发的营销/告知类消息。DSA 透明度弹窗（`DSA_Messaging*`）和我们自己的
// `PopUpHelper` 弹窗都在别的模块里，**不受这里影响**。
//
// ## 与其它拦截器的分工
//
// `UpsellPopupBlocker`（Encore 弹窗）/ `UpsellServiceBlocker`（服务 `.load()` 饿死）管的是
// 另一批目标；这三个是并列的，不重叠。三者都是**启动即生效、没有开关**（与那两个保持一致）。

import Foundation
import Orion
import UIKit

private func cmpLog(_ message: String) {
    writeDebugLog("[CMPBlock] \(message)")
}

struct CMPFullscreenContainerGroup: HookGroup {}
struct CMPModalContainerGroup: HookGroup {}
struct CMPBottomSheetPageGroup: HookGroup {}
struct CMPBannerViewGroup: HookGroup {}
struct UpsellElementViewGroup: HookGroup {}

// 全屏接管、居中模态、底部页各自有专门的容器视图控制器。
// 在 `viewWillAppear` 里就 dismiss ⇒ 容器**永远不会变成可见**；
// `dismiss(animated: false)` 是为了让 UIKit 的呈现记账保持一致（带动画反而可能留下残影）。
// 顺手把 `view` 藏掉是"双保险"：自定义容器呈现时 dismiss 有可能是空操作。
class CMPFullscreenContainerHook: ClassHook<UIViewController> {
    typealias Group = CMPFullscreenContainerGroup
    static let targetName =
        "_TtC37Messaging_ClientMessagingPlatformImpl33FullscreenContainerViewController"

    func viewWillAppear(_ animated: Bool) {
        orig.viewWillAppear(animated)
        cmpLog("suppressed fullscreen message container")
        target.view.isHidden = true
        target.view.isUserInteractionEnabled = false
        target.dismiss(animated: false, completion: nil)
    }
}

class CMPModalContainerHook: ClassHook<UIViewController> {
    typealias Group = CMPModalContainerGroup
    static let targetName =
        "_TtC37Messaging_ClientMessagingPlatformImpl28ModalContainerViewController"

    func viewWillAppear(_ animated: Bool) {
        orig.viewWillAppear(animated)
        cmpLog("suppressed modal message container")
        target.view.isHidden = true
        target.view.isUserInteractionEnabled = false
        target.dismiss(animated: false, completion: nil)
    }
}

class CMPBottomSheetPageHook: ClassHook<UIViewController> {
    typealias Group = CMPBottomSheetPageGroup
    static let targetName =
        "_TtC37Messaging_ClientMessagingPlatformImpl52ClientMessagingPlatformBottomSheetPageViewController"

    func viewWillAppear(_ animated: Bool) {
        orig.viewWillAppear(animated)
        cmpLog("suppressed bottom-sheet message container")
        target.view.isHidden = true
        target.view.isUserInteractionEnabled = false
        target.dismiss(animated: false, completion: nil)
    }
}

// 首页横幅有专门的 banner 视图。套路与 `SelfLoadingUpsellBannerViewKill` 一致：
// 挂上去时先藏，再摘掉。
class CMPBannerViewHook: ClassHook<UIView> {
    typealias Group = CMPBannerViewGroup
    static let targetName =
        "_TtC37Messaging_ClientMessagingPlatformImpl33ClientMessagingPlatformBannerView"

    func didMoveToSuperview() {
        orig.didMoveToSuperview()
        target.isHidden = true
        target.isUserInteractionEnabled = false
        if target.superview != nil {
            cmpLog("suppressed CMP banner view")
            target.removeFromSuperview()
        }
    }
}

// 从 Hub/队列组件树里渲出来的推销"元素"视图。目标名里带 UpsellBanner / PremiumUpsell，
// 所以 **DSA 或状态类界面不可能被误伤**。
class UpsellBannerElementUIHook: ClassHook<NSObject> {
    typealias Group = UpsellElementViewGroup
    static let targetName =
        "_TtC18Upsells_ElementKitP33_11E507536F1F78CA735FB7F17658749321UpsellBannerElementUI"

    func didMoveToSuperview() {
        orig.didMoveToSuperview()
        guard let view = target as? UIView else { return }
        view.isHidden = true
        view.isUserInteractionEnabled = false
        if view.superview != nil {
            cmpLog("suppressed UpsellBannerElementUI")
            view.removeFromSuperview()
        }
    }
}

class PremiumUpsellBannerElementUIHook: ClassHook<NSObject> {
    typealias Group = UpsellElementViewGroup
    static let targetName =
        "_TtC24Jam_QueueIntegrationImpl28PremiumUpsellBannerElementUI"

    func didMoveToSuperview() {
        orig.didMoveToSuperview()
        guard let view = target as? UIView else { return }
        view.isHidden = true
        view.isUserInteractionEnabled = false
        if view.superview != nil {
            cmpLog("suppressed PremiumUpsellBannerElementUI")
            view.removeFromSuperview()
        }
    }
}

class PremiumUpsellControlPanelHook: ClassHook<UIView> {
    typealias Group = UpsellElementViewGroup
    static let targetName =
        "_TtC19ReinventFree_ECMKit25PremiumUpsellControlPanel"

    func didMoveToSuperview() {
        orig.didMoveToSuperview()
        target.isHidden = true
        target.isUserInteractionEnabled = false
        if target.superview != nil {
            cmpLog("suppressed PremiumUpsellControlPanel")
            target.removeFromSuperview()
        }
    }
}

func activateClientMessagingPlatformBlocker() {
    let viewWillAppearSelector = Selector(("viewWillAppear:"))
    let didMoveToSuperviewSelector = Selector(("didMoveToSuperview"))

    let containerHooks: [(String, String, () -> Void)] = [
        (CMPFullscreenContainerHook.targetName, "FullscreenContainer", { CMPFullscreenContainerGroup().activate() }),
        (CMPModalContainerHook.targetName, "ModalContainer", { CMPModalContainerGroup().activate() }),
        (CMPBottomSheetPageHook.targetName, "BottomSheetPage", { CMPBottomSheetPageGroup().activate() }),
    ]

    let viewHooks: [(String, String, () -> Void)] = [
        (CMPBannerViewHook.targetName, "CMPBannerView", { CMPBannerViewGroup().activate() }),
        (UpsellBannerElementUIHook.targetName, "UpsellBannerElementUI", { UpsellElementViewGroup().activate() }),
        (PremiumUpsellBannerElementUIHook.targetName, "PremiumUpsellBannerElementUI", { UpsellElementViewGroup().activate() }),
        (PremiumUpsellControlPanelHook.targetName, "PremiumUpsellControlPanel", { UpsellElementViewGroup().activate() }),
    ]

    var activated = 0
    let total = containerHooks.count + viewHooks.count

    // 每个目标都先查"类在不在 + 方法在不在"，缺了只记一行日志 ——
    // 版本换一个名字不至于把整组 hook 带崩（用 `findTweakClass` 是为了兜住"注册晚一步"）。
    for (className, label, activate) in containerHooks {
        guard let cls = findTweakClass(className),
              class_getInstanceMethod(cls, viewWillAppearSelector) != nil else {
            cmpLog("\(label) unavailable; skipping (class not registered / no viewWillAppear)")
            continue
        }
        activate()
        activated += 1
        cmpLog("\(label) hook activated")
    }

    for (className, label, activate) in viewHooks {
        // 这里**不**做 UIView 类型断言：有些 ElementUI 类在部分构建上并不是 UIView 子类，
        // Orion 会以 `targetHasIncompatibleType` 拒绝。所以 hook 声明成 NSObject，
        // 在方法体里再自己 cast。
        guard let cls = findTweakClass(className),
              class_getInstanceMethod(cls, didMoveToSuperviewSelector) != nil else {
            cmpLog("\(label) unavailable; skipping (class not registered / no didMoveToSuperview)")
            continue
        }
        activate()
        activated += 1
        cmpLog("\(label) hook activated")
    }

    cmpLog("activated \(activated)/\(total) compatible hooks")
}
