import Foundation
import Orion
import UIKit
import ObjectiveC.runtime

/// 清爽开关：把 Spotify 自己画的三块"非内容"隐藏掉。
///
/// 目标类名**不是猜的**，来自 2026-09-30 的真机视图树转储 + 9.1.86 符号转储：
///
///   真机树里的形状                                    运行期名（`targetName`）
///   `5.TouchPassthroughView@0,749,414,64`           → `_TtC22NowPlaying_BarPageImplP33_CCC0D2EEA6D4725EECD8965E8C38C86D20TouchPassthroughView`
///     正好贴在标签栏上方（749 + 64 = 标签栏顶 813），里面才是 `id=SPTNowPlayingBar`
///   `12.TabBarGradientView@0,-112,414,195`          → `_TtC23NavigationUI_TabBarImpl18TabBarGradientView`
///   `5.LimitedExperienceIndicatorBar@0,896,414,0`   → `_TtC44LimitedExperienceIndicator_MessageBarRuntime29LimitedExperienceIndicatorBar`
///
/// ⚠️ 可撤销但**只管自己**：Spotify 自己在来回切这几处的 `isHidden`（真机树里同一个
/// `TouchPassthroughView` 一次是 `hidden`、一次不是 —— 取决于有没有在播放）。
/// 所以：
///   · 开关打开 → 藏，并**用关联对象记住"这一层是我藏的"**；
///   · 开关关掉 → 只撤回**我们**藏的那一次，Spotify 自己藏的一律不碰。
/// 第一版没有这条，结果是"关掉开关它也不回来"（用户以为坏了）—— 现在关掉即恢复。
///
/// ⚠️⚠️ 但"关掉即恢复"只在**下一次 layout 真的到来**时才成立。2026-10-01 的日志 8 证明
/// 它并不可靠，见下面 `reconcile` 那一段的说明（迷你播放条没上报、加号按钮没生效，
/// 用户那边的表现是"迷你条消失且无法恢复"）。所以每个开关现在**两个时机**都跑：
///   1. 目标类自己的 `layoutSubviews`（快路径，保持原样）；
///   2. `MainWindow` 的节流复查 + 开关被手动切换 + App 回到前台（兜底，见 `reconcile`）。
struct HideMiniPlayerGroup: HookGroup {}
struct HideHomeHeaderGroup: HookGroup {}
struct HideTransportChromeGroup: HookGroup {}

/// 关联对象的键。file-scope 的 `var` 地址稳定，这是本仓库既有的写法
/// （见 `UpsellPopupBlocker.x.swift` 的 `upsellPopupAssociationKey`）。
private var declutterHiddenByUsKey: UInt8 = 0

private func wasHiddenByUs(_ view: UIView) -> Bool {
    (objc_getAssociatedObject(view, &declutterHiddenByUsKey) as? NSNumber)?.boolValue == true
}

private func markHiddenByUs(_ view: UIView) {
    objc_setAssociatedObject(
        view,
        &declutterHiddenByUsKey,
        NSNumber(value: true),
        .OBJC_ASSOCIATION_RETAIN_NONATOMIC
    )
}

private func clearHiddenByUs(_ view: UIView) {
    objc_setAssociatedObject(view, &declutterHiddenByUsKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
}

enum DeclutterChrome {

    static var hideMiniPlayerBar: Bool { UserDefaults.hideMiniPlayerBar }

    /// 封面与歌名之间那一行"跟唱单行歌词"。
    ///
    /// 为什么它上面显示的是**我们的**歌词：`NgzhwmSettingsViewModel.isOfficialLyricsHidden`
    /// 是**数据层**的开关（取不到我们的词时用占位 payload 顶掉 Spotify 的歌词），它不隐藏
    /// 视图。反过来，我们供给的歌词会被 Spotify **自己的**视图渲染 —— 包括这个跟唱单行
    /// 视图。所以那一行不是"挂错了"，而是"Spotify 的壳 + 我们的字"。
    ///
    /// 真机证据（日志 6 的 NPV 转储）：
    ///   `22.CoverArtTiltView@15,0,335,335`            ← 封面
    ///   `22.LyricsContainerView@0,335,366,120`        ← 就在封面正下方
    ///   `23.LyricsView@0,0,366,120,id=singalong-lyrics-view`
    ///
    /// 默认**关**：用户说过那一行本身不是问题（他反馈的是"逐词歌词开、更好的逐词歌词关"
    /// 时逐行歌词挂错地方，已修在 `InlineLyricsHostLocator`）。这个开关只留作选择。
    static var hideSingalongLine: Bool { UserDefaults.hideSingalongLine }

    // MARK: - 首页 / 播放器那一批（2026-09-30 真机树实证）

    /// 首页顶部那条（问候语 + 筛选胶囊）。
    ///
    /// 证据：`HomeHeaderView@0,0,414,50`，只在**首页**的转储里出现（日志 7 的 #1–#7），
    /// 运行期类名 `_TtC19Home_FunkisPageImplP33_297EC57FD07AE9FCEAA7B66079FC278C14HomeHeaderView`。
    static var hideHomeHeader: Bool { UserDefaults.hideHomeHeader }

    /// 设备 / 输出切换按钮（"连接"）。
    ///
    /// 证据：`ConnectButtonView@0,0,44,40,id=Components.ConnectButtonOutputSwitcher`，
    /// **20/20 份转储全都有**（深度 14）—— 它在迷你播放条和播放器里共用，
    /// 所以关掉是"所有传输条上都不显示"，不只是播放器页。
    static var hideConnectButton: Bool { UserDefaults.hideConnectButton }

    /// 播放器里的"加号"按钮。
    ///
    /// 证据：`UIButton@0,0,44,40,id=Components.UI.AddToButton`，与设备按钮**同级**
    /// （同一深度 14）。它是普通 `UIButton`，按类名 hook 不到，所以从兄弟里按 id 找。
    static var hideAddToButton: Bool { UserDefaults.hideAddToButton }

    private static var reported: Set<String> = []

    /// 每个开关只报一次：证明 hook 真的跑到了，并说明藏的是哪一个。
    /// 和 AMOLED 那边同一个道理 —— 验收靠日志，不靠眼睛。
    static func reportOnce(_ key: String, _ message: String) {
        guard !reported.contains(key) else { return }
        reported.insert(key)
        writeDebugLog("[Declutter] \(message)")
    }

    /// 藏 / 撤销，两个方向都幂等。
    ///
    /// 关键区别在"谁藏的"：`isHidden == true` 可能是 Spotify 自己写的（没在播放时
    /// 迷你条本来就不显示）。所以撤销只针对被我们打过标的那些视图。
    static func apply(
        wantHidden: Bool,
        to view: UIView,
        reportKey: String,
        reportMessage: String
    ) {
        if wantHidden {
            guard !view.isHidden else { return }

            view.isHidden = true
            markHiddenByUs(view)
            reportOnce(reportKey, reportMessage)
            return
        }

        guard wasHiddenByUs(view) else { return }

        view.isHidden = false
        clearHiddenByUs(view)
        writeDebugLog("[Declutter] \(reportKey) restored")
    }

    // MARK: - 复查（reconcile）：把"藏 / 还原"接到一个一定会跑的节拍上

    /// ⚠️ 为什么必须有它（2026-10-01 日志 8 的实证）
    ///
    /// 原来只有"目标类自己的 `layoutSubviews`"一个时机，两个后果：
    ///
    ///   · **迷你播放条**：启动时没在播放，Spotify 把 `TouchPassthroughView` 设成 `hidden`，
    ///     我们的 `apply` 走 `guard !view.isHidden` 直接返回（不标记、不上报）。等 Spotify
    ///     把它显示回来时不一定再有 layout 回合 —— 日志 8 的 #19/#20 里它已经显示，
    ///     而整份日志**一行 `[Declutter]` 都没有**（日志 5 那次恰好启动时就在播放，才有）。
    ///     用户那边的表现就是"迷你条消失且无法恢复"。
    ///
    ///   · **加号按钮**：它只能从 `ConnectButtonView` 的兄弟里找，而那颗按钮**已经被我们藏了**，
    ///     被藏的视图不再收 layout 回合 → 那次扫描实际只跑过启动一次（日志 8 的 #4–#20
    ///     里 `id=Components.UI.AddToButton` 全部可见，且从没上报）。
    ///
    /// 所以换成**常驻可见的宿主**（`MainWindow`，`_TtC30ContainerUI_RootUIInternalImpl10MainWindow`，
    /// 每份真机转储里都在、每次布局都跑）做节流复查，另外两个时机也强制跑：
    ///   · 开关被手动切换（设置页 → `reconcileNow()`，关掉要**当场**还回来）；
    ///   · App 回到前台（`didBecomeActive`，正是"划出 Spotify 再回来"那一步）。
    ///
    /// 复查是幂等的：开关开着就确保藏起来，关着就只撤回**我们**藏过的那一次。

    /// 解析结果的缓存。全窗口扫描不便宜，所以结果留着；视图被换掉时 `weak` 自动失效，
    /// 下一轮重扫即可。
    private struct ResolvedTargets {
        weak var miniBar: UIView?
        weak var singalong: UIView?
        weak var homeHeader: UIView?
        weak var connect: UIView?
        weak var addTo: UIView?
    }

    private static var targets = ResolvedTargets()
    private static var lastReconcileAt: CFAbsoluteTime = 0
    private static var lastScanAt: CFAbsoluteTime = 0
    /// 节流窗口。`MainWindow` 在滚动时几乎每帧都有 layout，0.3s 一次足够追上 Spotify 的
    /// 显示逻辑，又不至于每帧走一遍窗口树。
    private static let reconcileInterval: CFAbsoluteTime = 0.3
    /// 找那两颗按 id 认的按钮比"重新施加一遍"贵，单独再节流一次。
    private static let scanInterval: CFAbsoluteTime = 1.0
    /// 扫描节点上限。正常一屏远小于它，纯粹防病态情况。
    private static let maxScanNodes = 3000

    /// 开关被手动切换 / App 回到前台时调用：**当场**落地，不等下一次 layout。
    static func reconcileNow() {
        lastReconcileAt = 0
        lastScanAt = 0
        reconcile(in: keyWindowRoot())
    }

    /// 把当前所有清爽开关重新施加一遍。幂等、只读查找、不改别的视图。
    static func reconcile(in root: UIView?, force: Bool = false) {
        guard let root else { return }

        let now = CFAbsoluteTimeGetCurrent()

        if !force {
            guard now - lastReconcileAt >= reconcileInterval else { return }
        }
        lastReconcileAt = now

        // 那两个按 id 认的按钮，只有对应开关开着时才需要找（默认都关着 → 默认零扫描）。
        // 关掉开关时**不需要**重新找：`targets` 里还留着上一次的引用，够用来还原。
        if (hideConnectButton || hideAddToButton), now - lastScanAt >= scanInterval {
            lastScanAt = now
            resolveIDTargets(in: root)
        }

        if let view = targets.miniBar {
            apply(
                wantHidden: hideMiniPlayerBar,
                to: view,
                reportKey: "miniPlayer",
                reportMessage: "mini player bar hidden (TouchPassthroughView)"
            )
        }
        if let view = targets.singalong {
            apply(
                wantHidden: hideSingalongLine,
                to: view,
                reportKey: "singalongLine",
                reportMessage: "singalong single-line lyrics hidden (id=singalong-lyrics-view)"
            )
        }
        if let view = targets.homeHeader {
            apply(
                wantHidden: hideHomeHeader,
                to: view,
                reportKey: "homeHeader",
                reportMessage: "home header hidden (HomeHeaderView)"
            )
        }
        if let view = targets.connect {
            apply(
                wantHidden: hideConnectButton,
                to: view,
                reportKey: "connectButton",
                reportMessage: "connect button hidden (Components.ConnectButtonOutputSwitcher)"
            )
        }
        if let view = targets.addTo {
            apply(
                wantHidden: hideAddToButton,
                to: view,
                reportKey: "addToButton",
                reportMessage: "add-to button hidden (Components.UI.AddToButton)"
            )
        }

        // ★ v4.8：迷你条那条胶囊的"封面色底"守卫（`MiniBarGlass.swift`）——
        //   Spotify 会在我们清完之后**再写回**封面色，而那个写回**不一定**伴随宿主的
        //   布局回合（照片 36 那块蓝就是这么留下来的：清一次 → 被写回 → 再没有布局回合）。
        //   这里就是"看一眼 + 幂等清"（一次属性读），开关关着 / 没迷你条时零开销；
        //   它自己还有一轮 50ms 级的短促重试负责首帧。
        //   ⚠️ 刻意**不新开定时器** —— 蹭的就是这个既有的节拍（0.5s，且非前台不跑）。
        onMainThreadSync { MiniBarGlassPlate.reconcileCoverColor() }

        // ★ 2026-10-03 夜：听歌页那层"封面取色底"的**换歌/滚动**自愈
        //   （`NowPlayingBackdrop.reconcile()`）。日志 38 的 #7→#9 是现场：
        //   用户**一直待在听歌页**，Spotify 那层底色自己从 `bg=#E84838` 变成 `bg=#584860`、
        //   高度 896 变 1682，而这期间**没有第三次 `[NPVStyle]`**（`apply` 只在
        //   `viewWillAppear`/`viewDidAppear` 跑）⇒ 换歌、滚动之后我们的层必然失配。
        //   没在听歌页时它的成本 = 两次 weak 读 + 一次 `window` 读；
        //   在听歌页时再加**一次 `backgroundColor` 读**（换色那一刻才问 metadata）。
        //   同一条纪律：**不新开定时器**，蹭这个节拍。
        onMainThreadSync { _ = NowPlayingBackdrop.reconcile() }

        // ★ 2026-10-03 夜：听歌页「一屏」的**重算节拍**（`NowPlayingOneScreen.reconcile()`）。
        //   卡片是列表建好之后**才陆续到**的，每来一张都会把内容高度顶上去，而 `apply`
        //   只在进页面时跑一遍；`willDisplayCell` 那一刻的高度更是"一个 runloop 之后才定"
        //   （pw 为此专门补了一枪 async）。同一条纪律：**不新开定时器**，蹭这个节拍；
        //   值没漂就一个字节都不写，没在听歌页时只是两次 weak 读。
        onMainThreadSync { _ = NowPlayingOneScreen.reconcile() }

        // ★ 听歌页「**我们自己的覆盖层**」（`NowPlayingPageOverlay`）也要跟着重排：
        //   Spotify 换帧会重排 subviews 把我们挤下去，换歌 / 转场之后底部锚的 frame 也会变。
        //   同一条纪律：**不新开定时器**，frame 没变就一个字节都不写。
        onMainThreadSync { _ = NowPlayingPageOverlay.reconcile() }

        // ★ 2026-10-04：「歌词进播放器」那一层也要跟着重排 + 驱动时间轴。
        //   它的位置来自底部那一坨（卡片折叠/换歌都会动），时间轴**刻意**就用这个节拍
        //   （约 0.3s 一拍，不新开 CADisplayLink —— 行间移动本身带 SwiftUI 动画，
        //   肉眼与每帧没差别）。没开开关时成本 = 一次 bool 读。
        onMainThreadSync { _ = NowPlayingLyricsPlate.reconcile() }

        // ★ 2026-10-03 夜：**只读播放器状态探针**（`PlayerStateProbe`）—— 给「突然无法播放
        //   任何歌曲」那条线补现场判据（它至今零判据：31 份日志里 drm/license/unplayable
        //   全零命中，分不开"服务端按地区判不可播"和"账号风控"）。
        //   它自己先看「启用日志记录」，开关关着 = 一眼都不看；只在**换曲 / 卡住 / 恢复**
        //   时打，所以不刷屏。同一条纪律：**不新开定时器**。
        onMainThreadSync { PlayerStateProbe.tick() }

        // ★ v4.9：标签栏那一行的**纵向复核**。点开「创建」时那一颗处于暂时态，
        //   而**菜单关掉时这条栏不一定再布局** —— 日志 29 里我们的 transform 就停在
        //   `+2.5`，创建那颗一直比另外三颗高 8pt（16 秒没回来）。
        //   这里跟上面同一个纪律：**只在"这一行还没稳"时才真的重算**，稳着时是一次 bool 读。
        onMainThreadSync { TabBarGlassPlate.reconcileRowIfTransient() }
    }

    // MARK: 目标登记

    /// 五个"有专属类名"的目标：由各自的 hook 在 `layoutSubviews` 里登记自己。
    ///
    /// ⚠️ 为什么不在这里按类名去找：`NSStringFromClass` 对 Swift 类返回什么形式
    /// （`_TtC…` 混淆名，还是别的写法）依 Swift 版本而异，拿它跟 `targetName` 比字符串
    /// 是一场不必要的赌注；而 **hook 手里已经有实例了**，让它顺手登记一下最稳。
    enum Target {
        case miniBar
        case singalong
        case homeHeader
    }

    static func note(_ target: UIView, as kind: Target) {
        switch kind {
        case .miniBar: targets.miniBar = target
        case .singalong: targets.singalong = target
        case .homeHeader: targets.homeHeader = target
        }
    }

    /// 只有设备按钮与加号按钮这里按**无障碍 id** 找（判据与原 hook 完全相同）。
    ///
    /// 这两个没有能单独 hook 的类名：加号是普通 `UIButton`，而"从 `ConnectButtonView` 的
    /// 兄弟里扫"这条路会被"被藏掉就不再 layout"掐断 —— 这正是日志 8 里它没生效的原因。
    private static func resolveIDTargets(in root: UIView) {
        var connect: UIView?
        var addTo: UIView?
        var queue: [UIView] = [root]
        var index = 0

        while index < queue.count, index < maxScanNodes, connect == nil || addTo == nil {
            let view = queue[index]
            index += 1

            if let identifier = view.accessibilityIdentifier {
                if connect == nil, identifier == "Components.ConnectButtonOutputSwitcher" {
                    connect = view
                } else if addTo == nil, identifier == "Components.UI.AddToButton" {
                    addTo = view
                }
            }

            queue.append(contentsOf: view.subviews)
        }

        // 只更新这两个；另外五个由各自的 hook 登记，别在这里清掉。
        targets.connect = connect
        targets.addTo = addTo
    }

    private static func keyWindowRoot() -> UIView? {
        let windows = UIApplication.shared.windows
        return windows.first(where: { $0.isKeyWindow }) ?? windows.first
    }

    // MARK: - 复查的两个驱动（定时器 + 前台）

    private static var lifecycleObserver: NSObjectProtocol?
    private static var reconcileTimer: Timer?

    static func installReconcileDrivers() {
        startReconcileTimer()

        guard lifecycleObserver == nil else { return }

        // App 回到前台时强制复查一次。用户反馈的"划出 Spotify（不是杀掉）再回来，
        // 迷你条就没了/回不来"正发生在这一步：视图可能被重建，或 Spotify 自己重排了一遍。
        // 每次前台打一行日志，方便下一份日志直接确认这条路径跑过。
        lifecycleObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            writeDebugLog("[Declutter] reconcile (app became active)")
            DeclutterChrome.reconcileNow()
        }
    }

    /// 兜底节拍器。
    ///
    /// ⚠️ 为什么不能只靠 `MainWindow` 的 `layoutSubviews`：UIKit 的布局只从"自己
    /// `needsLayout`"的那些视图上往下跑，**深层子视图重新布局不一定会走到 window 自己**，
    /// 所以那个节拍并不保证。这里补一个和 `ViewTreeDumper` 同款的定时器（`.common` 模式，
    /// 滚动时也不会停；App 进后台被挂起时自然停摆），保证"Spotify 把 chrome 显示回来"
    /// 这件事在 0.5s 内一定被复查到。
    private static func startReconcileTimer() {
        guard reconcileTimer == nil else { return }

        let timer = Timer(timeInterval: 0.5, repeats: true) { _ in
            // **熄屏/后台不做任何事**（与 `ViewTreeDumper.dumpOnce` 同一条纪律）。
            // Spotify 在后台放歌时进程不会挂起，这个 0.5s 的节拍没必要在用户看不见屏幕时空转。
            // 手动调用的那两个入口（开关切换 / didBecomeActive）不受这条影响，照常当场落地。
            guard UIApplication.shared.applicationState == .active else { return }
            reconcile(in: keyWindowRoot())
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        reconcileTimer = timer
    }
}

/// 迷你播放条（标签栏上方那条，用户照片里就是它）。藏的是它的 host：
/// host 的 frame 正好等于 bar 区域（414x64），藏它才不会留一条空白。
class MiniPlayerBarHideHook: ClassHook<UIView> {
    typealias Group = HideMiniPlayerGroup
    static let targetName =
        "_TtC22NowPlaying_BarPageImplP33_CCC0D2EEA6D4725EECD8965E8C38C86D20TouchPassthroughView"

    func layoutSubviews() {
        orig.layoutSubviews()

        // 顺手登记：之后这个实例就被复查（`DeclutterChrome.reconcile`）持续盯着，
        // 即使它自己后来不再收到 layout 回合。
        DeclutterChrome.note(self.target, as: .miniBar)

        // ★ 迷你播放条的**液态玻璃胶囊**（`MiniBarGlass.swift`）蹭的就是这个布局回调 ——
        //   同一个类上再挂一个 ClassHook 是没验证过的行为，所以那边只画、不钩。
        //   顺序无所谓：藏掉时它照样画（看不见而已），开关关掉它会自己撤掉并把底色还原。
        // ⚠️ hook 方法体是**非隔离**的（Orion 的代码生成器会把 `@MainActor` 拼坏，见
        //   `LyricsChromeVisibility.swift` 顶上那段），所以这里必须套 `onMainThreadSync`。
        let host = self.target
        onMainThreadSync { MiniBarGlassPlate.apply(to: host) }

        DeclutterChrome.apply(
            wantHidden: DeclutterChrome.hideMiniPlayerBar,
            to: self.target,
            reportKey: "miniPlayer",
            reportMessage: "mini player bar hidden (TouchPassthroughView)"
        )
    }
}

/// 封面下那行跟唱歌词。
/// ⚠️ 它是**通用类**（`Lyrics_TextComponentImpl.LyricsView`），别的地方也可能用同一类，
/// 所以判据只认那个 id：`accessibilityIdentifier == "singalong-lyrics-view"`
/// （真机树实测值）。命中不了就什么都不做 —— 宁可漏，不可误伤别处的歌词视图。
///
/// 已知局限：只藏视图本身，**120pt 的槽位可能还在**（容器 `LyricsContainerView` 是
/// Spotify 的布局，动它有把歌词卡一起弄坏的风险）。真机如果看出空档，再单独处理。
struct HideSingalongLineGroup: HookGroup {}

class SingalongLyricsLineHideHook: ClassHook<UIView> {
    typealias Group = HideSingalongLineGroup
    static let targetName = "_TtC24Lyrics_TextComponentImpl10LyricsView"

    func layoutSubviews() {
        orig.layoutSubviews()

        guard self.target.accessibilityIdentifier == "singalong-lyrics-view" else { return }

        DeclutterChrome.note(self.target, as: .singalong)

        DeclutterChrome.apply(
            wantHidden: DeclutterChrome.hideSingalongLine,
            to: self.target,
            reportKey: "singalongLine",
            reportMessage: "singalong single-line lyrics hidden (id=singalong-lyrics-view)"
        )
    }
}

/// 首页顶部那条（问候语 + 筛选胶囊）。
class HomeHeaderHideHook: ClassHook<UIView> {
    typealias Group = HideHomeHeaderGroup
    static let targetName =
        "_TtC19Home_FunkisPageImplP33_297EC57FD07AE9FCEAA7B66079FC278C14HomeHeaderView"

    func layoutSubviews() {
        orig.layoutSubviews()

        DeclutterChrome.note(self.target, as: .homeHeader)

        DeclutterChrome.apply(
            wantHidden: DeclutterChrome.hideHomeHeader,
            to: self.target,
            reportKey: "homeHeader",
            reportMessage: "home header hidden (HomeHeaderView)"
        )
    }
}

/// 传输控件那一排：设备按钮（自己）+ 加号按钮（同级的普通 UIButton）。
///
/// 挂在 `ConnectButtonView` 上，因为它是这一批里唯一有"专属类名 + 稳定 id"的节点；
/// 加号只能从它的兄弟里按 id 找（`Components.UI.AddToButton`）。
class TransportChromeHideHook: ClassHook<UIView> {
    typealias Group = HideTransportChromeGroup
    static let targetName = "_TtC23Connect_EntryPointsImpl17ConnectButtonView"

    func layoutSubviews() {
        orig.layoutSubviews()

        DeclutterChrome.apply(
            wantHidden: DeclutterChrome.hideConnectButton,
            to: self.target,
            reportKey: "connectButton",
            reportMessage: "connect button hidden (Components.ConnectButtonOutputSwitcher)"
        )

        guard let siblings = self.target.superview?.subviews else { return }

        for sibling in siblings where sibling !== self.target {
            guard sibling.accessibilityIdentifier == "Components.UI.AddToButton" else { continue }

            DeclutterChrome.apply(
                wantHidden: DeclutterChrome.hideAddToButton,
                to: sibling,
                reportKey: "addToButton",
                reportMessage: "add-to button hidden (Components.UI.AddToButton)"
            )
        }
    }
}

/// 复查的**宿主**。
///
/// 为什么是 `MainWindow`：真机树里它是 `0.MainWindow@0,0,414,896,id=spotify-main-window`，
/// 运行期名 `_TtC30ContainerUI_RootUIInternalImpl10MainWindow`；它在**每一份**转储里都在，
/// 而且每次布局都会走一遍 —— 拿它当节拍器，就不会再出现"目标被我们藏掉之后再没有 layout"
/// 这种死结（日志 8 的迷你条与加号按钮就是这么坏的）。
struct DeclutterReconcileGroup: HookGroup {}

class DeclutterReconcileHook: ClassHook<UIView> {
    typealias Group = DeclutterReconcileGroup
    static let targetName = "_TtC30ContainerUI_RootUIInternalImpl10MainWindow"

    func layoutSubviews() {
        orig.layoutSubviews()
        DeclutterChrome.reconcile(in: self.target)
    }
}

func activateDeclutterChrome() {
    // 每个 group 各自按"类在不在"决定装不装（本仓库既有做法）：目标类缺失时 Orion
    // 会报一条非致命错误，不如自己先判掉，日志也更干净。
    if NSClassFromString(MiniPlayerBarHideHook.targetName) != nil {
        HideMiniPlayerGroup().activate()
    } else {
        writeDebugLog("[Declutter] missing \(MiniPlayerBarHideHook.targetName) — mini player hook inactive")
    }

    if NSClassFromString(SingalongLyricsLineHideHook.targetName) != nil {
        HideSingalongLineGroup().activate()
    } else {
        writeDebugLog("[Declutter] missing \(SingalongLyricsLineHideHook.targetName) — singalong hook inactive")
    }

    if NSClassFromString(HomeHeaderHideHook.targetName) != nil {
        HideHomeHeaderGroup().activate()
    } else {
        writeDebugLog("[Declutter] missing \(HomeHeaderHideHook.targetName) — home header hook inactive")
    }

    if NSClassFromString(TransportChromeHideHook.targetName) != nil {
        HideTransportChromeGroup().activate()
    } else {
        writeDebugLog("[Declutter] missing \(TransportChromeHideHook.targetName) — transport hook inactive")
    }

    // 复查的两个驱动：0.5s 定时器（主节拍）+ App 回到前台（划出/回来那一刻）。
    // 宿主 hook 缺失也不致命：那两个驱动还在，只是少一个免费节拍。
    if NSClassFromString(DeclutterReconcileHook.targetName) != nil {
        DeclutterReconcileGroup().activate()
    } else {
        writeDebugLog("[Declutter] missing \(DeclutterReconcileHook.targetName) — reconcile hook inactive")
    }
    DeclutterChrome.installReconcileDrivers()

    writeDebugLog(
        "[Declutter] installed (miniPlayer="
            + "\(DeclutterChrome.hideMiniPlayerBar ? "ON" : "OFF")"
            + " singalongLine=\(DeclutterChrome.hideSingalongLine ? "ON" : "OFF")"
            + " homeHeader=\(DeclutterChrome.hideHomeHeader ? "ON" : "OFF")"
            + " connectButton=\(DeclutterChrome.hideConnectButton ? "ON" : "OFF")"
            + " addToButton=\(DeclutterChrome.hideAddToButton ? "ON" : "OFF"))"
    )
}
