import Orion
import UIKit

private var shouldOverrideLocalTrackURI = false

class SPTPlayerTrackHook: ClassHook<NSObject> {
    typealias Group = BaseLyricsGroup
    static let targetName = EeveeSpotify.hookTarget == .latest
        ? "SPTPlayerTrackImplementation"
        : "SPTPlayerTrack"

    func metadata() -> [String: String] {
        var meta = orig.metadata()

        // 诊断日志已移除 —— 它的使命完成了：
        //   · 确认了这条覆写**确实被调用**（日志 9/10 里数百行 `[TrackHook]`）；
        //   · 拿到了原始值：失败曲目 `spotify:track:5utfun3R35e5AsBalPSxBe` ⇒ `false`；
        //   · 结论：**面 B 的门控不是这个键** —— 覆写每次都返回 `has_lyrics = "true"`，
        //     面 B 却依然只有 SECRET 出现。说明门控读的是 Swift 内部字段、走静态派发，
        //     ObjC 侧 getter 的改写到不了它那里（与取证报告证据 6 一致）。
        //
        // 移除它的另两个理由：`metadata()` 在热路径上（一次会话刷几百行）；而且去重用的
        // 全局变量是**无锁**的，被多线程交错写 `var` 有踩坑风险。
        // 将来若要验证"线上改完之后这个值有没有变"，再加回来即可。
        meta["has_lyrics"] = NgzhwmSettingsViewModel.isLyricsFeatureDisabled ? "false" : "true"
        return meta
    }
    
    func URI() -> NSURL? {
        let uri = orig.URI()
        
        guard shouldOverrideLocalTrackURI,
              let absoluteString = uri?.absoluteString,
              absoluteString.isLocalTrackIdentifier else {
            return uri
        }

        writeDebugLog("[Lyrics] Overriding local track URI → spotify:track:")
        return NSURL(string: "spotify:track:")!
    }
}

class LyricsScrollProviderHook: ClassHook<NSObject> {
    // 9.1.x 上 `Lyrics_NPVCommunicatorImpl.ScrollProvider` 已不存在（真机日志 targetNotFound），
    // 挪进永不激活的隔离组，避免注册期崩掉注入工具。
    typealias Group = V91UnavailableLyricsGroup
    static var targetName = HookTargetNameHelper.lyricsScrollProvider
    
    func isEnabledForTrack(_ track: SPTPlayerTrack) -> Bool {
        return !NgzhwmSettingsViewModel.isLyricsFeatureDisabled
    }
}

/// 内嵌（预览）歌词的逐词宿主查找器。
///
/// 背景：ng 原来靠 `LyricsWordByWordModernHostHook` 直接 hook
/// `Lyrics_NPVCommunicatorImpl.LyricsOnlyViewController` 拿内嵌歌词 VC；
/// 该类在 9.1.x 上已被移除（9.1.76 主二进制类名扫描：整个二进制里都不存在
/// `LyricsOnlyViewController`；真机日志 targetNotFound）。
///
/// 为什么不再「换个 targetName 重新 hook」：Orion 在**注册期**解析不到目标类/方法时
/// 会走错误路径 —— 在 App 里只是一条日志，但在注入工具进程里加载同一个 dylib 时
/// 会直接 SIGTRAP 把工具崩掉（已实测：官方 dylib 能注入、我们的一注入就闪退）。
/// 因此这里**不新增任何 hook**，改为在已经绑定成功的 NPV 宿主里用纯 UIKit 遍历查找；
/// 最坏情况只是「没找到、没效果」，不会引入新的注册期崩溃。
///
/// 候选类名来自 9.1.76 主二进制扫描（`Lyrics_TextElementImpl` /
/// `Lyrics_TextComponentImpl` / `Lyrics_NPVElementsKitImpl` 三个模块）；
/// 真机日志里 statefulPlayer 也会以 `LyricsTextElementService` 特征串被取出，
/// 与「内嵌歌词由这套组件渲染」一致。
///
/// ⚠️ 查找**不是一次性的**：宿主在 `viewWillAppear` 那一刻往往还不存在（卡片要等歌词），
/// 而且它是自适应表格 cell、会被复用重建。所以这里配了一个 1.5s 的看门狗
/// （见 `startWatchdog`），只要"内嵌层没挂上/挂了但不在窗口里"就再查一次 ——
/// 这是让预览里的逐词歌词"总能挂上、掉了还能自己回来"的关键。
/// 内嵌（预览）歌词**内容视图**的已知类名。
///
/// **唯一来源**，两个消费者：
///   · `InlineLyricsHostLocator` 用它找宿主（预览卡片的歌词文本视图）；
///   · `WordByWordHost.attach` 用它判断"没有卡片容器时，退化成挂在内容视图上"是否安全。
///
/// ⚠️ 日志实证（9.1.76）：`Lyrics_TextComponentImpl.LyricsView`（366x120、挂在
/// **歌曲封面容器**里）不在这个名单里 —— 它一旦被当成歌词内容使用，整层就跑到封面上去了。
let inlineLyricsContentClassNames: Set<String> = [
    "Lyrics_TextElementImpl.LyricsTextElementUI",
    "Lyrics_TextElementImpl.LyricsTextView",
    "Lyrics_TextElementImpl.LyricsLabelsView",
    "Lyrics_NPVElementsKitImpl.LyricsViewElementUI",
]

enum InlineLyricsHostLocator {
    private static let viewControllerCandidates: [String] = [
        "Lyrics_TextComponentImpl.LyricsViewControllerImplementation",
    ]

    private static let viewCandidates = inlineLyricsContentClassNames

    static func scheduleLookup(from root: UIViewController?) {
        guard let root else { return }
        Watchdog.shared.root = root
        // 让布局先跑一拍，VC 层级与视图都在位了再找。
        DispatchQueue.main.async { lookup(from: root) }
        startWatchdog()
    }

    /// NPV 页面消失时调用：停掉看门狗（页面都不在了，再查也没有意义）。
    static func stopLookup() {
        Watchdog.shared.timer?.cancel()
        Watchdog.shared.timer = nil
        Watchdog.shared.root = nil
    }

    /// 让看门狗**立刻**再查一次。
    ///
    /// 两个调用点：逐词歌词刚到达（`WordByWordHost.refreshForCurrentLyrics`），
    /// 以及关闭全屏回到内嵌时（`WordByWordHost.reattachToInline` 找不到宿主）。
    /// 这两刻正是"卡片刚刚出现/重建"的时刻，等下一个 1.5s 心跳就慢了。
    static func retryLookupIfNeeded() {
        tick()
    }

    // MARK: 看门狗

    /// 看门狗状态。
    ///
    /// 放在一个小类里而不是文件级 `weak var`：类型属性不能标 `weak`，
    /// 而强引用会把正在播放页的 VC 一直留住。
    private final class Watchdog {
        static let shared = Watchdog()
        weak var root: UIViewController?
        var timer: DispatchSourceTimer?
    }

    /// 为什么要**定时重查**而不是只查一次：
    ///   1. 卡片是歌词到了才建的 —— `NPVScrollViewController.viewWillAppear`
    ///      那一拍它还不存在（这正是"预览逐词几乎不挂载"的第一成因）；
    ///   2. 卡片里的歌词是**自适应高度的表格 cell**（`Lyrics_TextElementImpl.LyricsCell`
    ///      + `SelfSizingTableView`），换行、滚动、换歌都会把它复用重建，
    ///      我们挂在它上面的层跟着一起消失（第二成因）；
    ///   3. 逐词数据、开关状态都可能晚于宿主出现。
    /// 三条在真机上都表现为"预览里的逐词歌词时有时无"，只有持续盯着才能自愈。
    private static func startWatchdog() {
        guard Watchdog.shared.timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now() + .milliseconds(1500),
            repeating: .milliseconds(1500),
            leeway: .milliseconds(300)
        )
        timer.setEventHandler { tick() }
        Watchdog.shared.timer = timer
        timer.resume()
        writeDebugLog("[WordByWord] inline host watchdog started")
    }

    private static func tick() {
        onMainThreadSync {
            // 先做便宜的判据，最后才去找宿主（找宿主可能要遍历整棵视图树）。
            guard NgzhwmSettingsViewModel.isWordByWordLyricsEnabled else { return }
            // 没有**可用的逐词数据**时查了也挂不上（`attach` 会直接返回）——
            // 这条判据必须与 `attach` 用的是同一个函数，省掉一次白遍历。
            //
            // ⚠️ 2026-09-25 起判据从"行级"收回到"**逐词**"：只有逐行的歌现在整首交还
            // Spotify 原生那页/那张卡（见 `attach` 里那一段产品规则）。看门狗再去找宿主、
            // 再挂一次都是白费，还会把日志刷成 `attach declined`。数据升到逐词时
            // `currentLyricsVersion` 会变，`refreshForCurrentLyrics()` 自己会重挂，不靠轮询。
            guard hasUsableWordLevelData(currentLyricsDto) else { return }
            // 先把"标记说全屏还挂着、其实那一层已经不在任何窗口里"的**残留**清掉 ——
            // 否则下面那道闸门会把预览层永久挡在外面（真机：全屏里点几下歌词行再退出，
            // 之后预览与后续每一首都退化成逐行/原生，重启才恢复）。
            WordByWordHost.shared.clearStaleAttachmentIfNeeded()
            // ⚠️ 全屏层正挂在屏上时**绝不**重挂预览层 —— 那会把全屏的层拽回卡片。
            guard !WordByWordHost.shared.fullscreenOverlayIsAttached else { return }
            // 已经挂上、而且还在窗口里 → 什么都不用做（这是常态，开销只有几次判空）。
            guard !WordByWordHost.shared.inlineOverlayIsLive else { return }
            // 页面不在窗口里（正在播放页被关掉 / 还没上来）→ 这一轮什么都不做。
            // 没有这道闸门时，宿主查找会在离屏的视图树上"成功地"挂上一层，
            // 然后每 1.5s 重挂一次 —— 白耗电，而且会污染 `lastPreviewContentView`。
            guard let root = resolvedRoot(), root.isViewLoaded, root.view.window != nil else {
                return
            }
            lookup(from: root)
        }
    }

    /// 正在播放页的 VC。
    ///
    /// 正常情况下由 `NPVScrollViewControllerHook.viewWillAppear` 记进来；
    /// 这里补一条**按类名在窗口里找**的兜底，覆盖"hook 没赶上"的场景：
    /// 例如功能是在已经进入正在播放页之后才打开的、或那一次 `viewWillAppear`
    /// 发生在 tweak 初始化之前。找不到就返回 nil（什么都不做，不崩）。
    private static func resolvedRoot() -> UIViewController? {
        if let root = Watchdog.shared.root { return root }
        guard let rootViewController = keyWindow?.rootViewController else { return nil }

        var queue: [UIViewController] = [rootViewController]
        var visited = 0
        while !queue.isEmpty && visited < 128 {
            let vc = queue.removeFirst()
            visited += 1
            if nowPlayingPageClassNames.contains(NSStringFromClass(type(of: vc))) {
                Watchdog.shared.root = vc
                writeDebugLog("[WordByWord] NPV page located by class name (hook missed it)")
                return vc
            }
            queue.append(contentsOf: vc.children)
            if let presented = vc.presentedViewController { queue.append(presented) }
        }
        return nil
    }

    /// 正在播放页 VC 的类名（与 `NPVScrollViewControllerHook.targetName` 同一个）。
    private static let nowPlayingPageClassNames: Set<String> = [
        "NowPlaying_ScrollImpl.NPVScrollViewController",
    ]

    private static var keyWindow: UIWindow? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        return windows.first { $0.isKeyWindow } ?? windows.first
    }

    private static func lookup(from root: UIViewController) {
        guard NgzhwmSettingsViewModel.isWordByWordLyricsEnabled else { return }
        guard let match = findHost(from: root) else {
            // ⚠️ 2026-09-27 起这句话的语义是"**这一轮没有在屏幕上的候选**"，
            // 不再等于"9.1.x 候选类不存在"：命中的若是复用/离屏实例，`viewHost`
            // 现在直接返回 nil（理由见那里），宁可下一轮 1.5s 后再看。
            logThrottled("[WordByWord] inline host not found (no on-screen candidate) — will retry")
            return
        }

        logThrottled(
            "[WordByWord] inline host found: \(NSStringFromClass(type(of: match.contentView)))"
            + " in \(NSStringFromClass(type(of: match.controller)))"
        )
        // 挂上了就把看门狗起来：卡片的 cell 一旦被复用重建，我们那层会跟着消失，
        // 只有持续盯着才能自己挂回来。这里也顺手覆盖"hook 没赶上"的场景
        // （那种情况下 `scheduleLookup` 没被调用过，还没有看门狗）。
        startWatchdog()
        onMainThreadSync {
            // 关键：把**命中的歌词视图**作为 contentView 传进去，而不是上溯到的 VC。
            //
            // WordByWordHost.attach 在预览场景（showsProviderFooter == false）会执行
            // `cardContainer(for: contentView)`，把 overlay 铺到「预览歌词卡片」上 ——
            // 那才是「只有歌词那一块逐词、页面其余部分保持原生」的正确挂载点。
            //
            // 之前传的是上溯得到的 NPVScrollViewController，contentView 变成整页根视图，
            // cardContainer 找不到卡片 → 退化成铺满整个正在播放页（就是之前那个现象）。
            WordByWordHost.shared.rememberInlineController(match.controller)
            WordByWordHost.shared.attach(
                to: match.controller,
                contentView: match.contentView,
                showsTranslation: false
            )
        }
    }

    /// 宿主查找的日志节流。
    ///
    /// 看门狗每 1.5s 走一次这条路，不节流的话「没找到」会一直往日志文件里写
    /// （`writeDebugLog` 是真的写文件，还会走统一日志）—— 查不到宿主时反而把电池吃光。
    /// 同一条消息 5s 内只记一次；消息变了立刻记（状态变化要看得见）。
    private static var lastLookupLogMessage: String?
    private static var lastLookupLogTime: Date = .distantPast

    private static func logThrottled(_ message: String) {
        let now = Date()
        if lastLookupLogMessage == message, now.timeIntervalSince(lastLookupLogTime) < 5 {
            return
        }
        lastLookupLogMessage = message
        lastLookupLogTime = now
        writeDebugLog(message)
    }

    private struct HostMatch {
        let controller: UIViewController
        let contentView: UIView
    }

    /// 这个视图是不是"封面下那一行跟唱歌词"。
    ///
    /// 为什么必须排除它（2026-09-30 用户反馈）：9.1.86 上
    /// `Lyrics_TextComponentImpl.LyricsViewControllerImplementation` 的 root view
    /// **正好就是**它（`Lyrics_TextComponentImpl.LyricsView`，366x120，待在封面容器里）。
    /// 卡片还没建出来的那一拍，`findHost` 会退化成拿这个 root view 当宿主 →
    /// 挂上去就是"逐行歌词跑到封面和歌手名中间那一行"。
    ///
    /// ⚠️ 这个类**刻意不在** `inlineLyricsContentClassNames` 里（那里注释写着
    /// "它一旦被当成歌词内容使用，整层就跑到封面上去了"），所以排除它与既有设计一致。
    ///
    /// AM（「更好的逐词歌词」）那条路径里另有一道 `preview host rejected` 闸门挡住它；
    /// 但**逐词歌词开、更好的逐词歌词关**时走的是旧的 overlay 路径，没有那道闸门 ——
    /// 所以在源头（宿主查找这里）就把它排除，两条路径一起受益。
    private static func isSingalongLineHost(_ view: UIView) -> Bool {
        if view.accessibilityIdentifier == "singalong-lyrics-view" { return true }

        return NSStringFromClass(type(of: view)) == "Lyrics_TextComponentImpl.LyricsView"
    }

    /// 先找 VC 候选（含子 VC 与 present 链）；视图候选命中时返回**该视图本身**
    /// 作为挂载内容视图，而不是它上溯到的 VC 根视图。
    ///
    /// ⚠️ 命中多个时**优先取在窗口里的那个**：视图树里往往同时存在离屏的
    /// 复用 cell 和当前显示的那一份，取错了就会"挂上了一层看不见的层"——
    /// 表现和"根本没挂载"一模一样。
    private static func findHost(from root: UIViewController) -> HostMatch? {
        var queue: [UIViewController] = [root]
        var visited = 0
        /// VC 自己的 root view —— 白名单外的兜底，**最后**才用。
        var controllerFallback: HostMatch?

        while !queue.isEmpty && visited < 64 {
            let vc = queue.removeFirst()
            visited += 1

            // ⚠️ 顺序很重要（2026-09-27，依用户反馈"AM 怎么经常挂在单行歌词上"改）：
            // **先在子树里找白名单里的卡片歌词视图**，再考虑"VC 自己的 root view"。
            //
            // 以前是反的：VC 候选一命中就 early return，而 9.1.86 上
            // `Lyrics_TextComponentImpl.LyricsViewControllerImplementation` 的 root view
            // 正好是**封面下那一行单行歌词**（`Lyrics_TextComponentImpl.LyricsView` 366x120，
            // 白名单里**刻意没有**它 —— 见 `inlineLyricsContentClassNames` 的说明）。
            // 于是只要它在屏幕上，我们就再也看不到同一棵树里的卡片歌词视图
            // （`Lyrics_TextElementImpl.LyricsTextView` 342x256）→ 层挂到单行歌词那一行上；
            // 而挂上之后"已挂载"短路又会挡住随后才出现的真卡片 ——
            // 这正是用户看到的"第一次进页面正常、切个歌回来就不行"。
            if let match = viewHost(in: vc.view) { return match }

            if controllerFallback == nil,
               viewControllerCandidates.contains(NSStringFromClass(type(of: vc))),
               vc.view.window != nil,
               !isSingalongLineHost(vc.view),
               WordByWordHost.isVisibleOnScreen(vc.view) {
                // 只留作兜底：`attach` 那边还会用 `cardContainer(for:)` 复核挂载点，
                // 复核不过（例如它压根不在卡片里）就会拒绝，交给看门狗下一轮再找。
                controllerFallback = HostMatch(controller: vc, contentView: vc.view)
            }

            queue.append(contentsOf: vc.children)
            if let presented = vc.presentedViewController { queue.append(presented) }
        }
        // ⚠️ 2026-09-27：不再返回**离屏** fallback（见 `viewHost` 的说明）。
        // 这里返回的兜底也过了可见性判据，且 `attach` 还会复核。
        return controllerFallback
    }

    private static func viewHost(in root: UIView?) -> HostMatch? {
        guard let root else { return nil }
        var queue: [UIView] = [root]
        var visited = 0
        while !queue.isEmpty && visited < 2000 {
            let view = queue.removeFirst()
            visited += 1
            if viewCandidates.contains(NSStringFromClass(type(of: view))) {
                var responder: UIResponder? = view
                while let current = responder {
                    if let vc = current as? UIViewController {
                        let match = HostMatch(controller: vc, contentView: view)
                        // ⚠️ 判据从"在窗口里"升级为"**真的在屏幕上**"（`isVisibleOnScreen`）。
                        //
                        // 复用中的 cell **仍然持有 window**，只看 `view.window != nil` 会把
                        // 离屏的复用 cell 当成命中项**直接 return** —— 而 `attach` 随后用更严的
                        // `isVisibleOnScreen` 把它拒掉，于是看门狗每 1.5s 命中同一个离屏宿主、
                        // 每 1.5s 被拒，屏幕上那份歌词**永远挂不上**。
                        //
                        // 真机日志 25（NE 源）：03:18:57 那次切歌之后，所有曲目都只剩
                        // `⚠️ preview host off-screen … attach declined`，包括本来有 yrc 的歌 ——
                        // 用户看到的就是"原本有逐字的歌没有逐字了"。
                        if view.window != nil, WordByWordHost.isVisibleOnScreen(view) { return match }
                        break
                    }
                    responder = current.next
                }
            }
            queue.append(contentsOf: view.subviews)
        }
        // ⚠️ 2026-09-27：**没找到"在屏幕上"的候选就返回 nil**，不再拿离屏的那一份兜底。
        //
        // 离屏兜底的唯一效果是让 `attach` 立刻被拒（AM 预览分支的可见性闸门），
        // 而 `attach` 在拒绝**之前**已经把 `lastPreviewController/lastPreviewContentView`
        // 记成了这个离屏视图 —— 退出全屏时的 `reattachToInline()` 又拿它去挂，继续失败。
        // 真机日志 17（`ただ声一つ`）：卡片容器明明在（`[PreviewShell] card container … 374x320`），
        // 命中的却是复用的歌词视图，于是 17 秒里一轮都没挂上。
        // 返回 nil 只是让这一轮什么都不做 —— 看门狗 1.5s 后再来，那才是自愈的正确姿势。
        return nil
    }
}

class NPVScrollViewControllerHook: ClassHook<NSObject> {
    typealias Group = ModernLyricsGroup
    static var targetName = "NowPlaying_ScrollImpl.NPVScrollViewController"

    func viewWillAppear(_ animated: Bool) {
        shouldOverrideLocalTrackURI = true
        writeDebugLog("[Lyrics] NPV scroll — enabling local track URI override")
        orig.viewWillAppear(animated)

        // 9.1.x 上内嵌歌词宿主已改名，改为运行时查找（不新增 hook，避免注册期崩溃）。
        InlineLyricsHostLocator.scheduleLookup(from: target as? UIViewController)

        // 「仿 AM 的整页取色底」——**搭在这条既有 hook 上**，不新开 hook
        // （Orion 注册期解析不到目标会崩注入工具，本仓库有先例）。
        //
        // ⚠️ 故意**不**加 `viewDidLayoutSubviews`：那是可选方法，9.1.88 的
        // `NPVScrollViewController` 没覆写就会 `Failed to hook method`。
        // 刷新时机改为"每次进这一页" + "设置里切开关时当场落地"两处。
        // ⚠️ 把 `target` 自己传进去 —— 它就是这个 VC；不能靠 `npvScrollViewController`
        // 那个全局（9.1.x 上恒为 nil，见 `refreshNowPlayingBackdrop` 的说明）。
        refreshNowPlayingBackdrop(page: target as? UIViewController)

        // 「一屏」：把播放器下面那些卡片折起来 + 把列表钉在顶部（kumone 那种"一屏一首歌"）。
        // ⚠️ 这一刻列表常常还没建出来 —— `apply` 对"找不到"是**静默**的，
        // 真正的重算交给 `DeclutterChrome` 那条既有的 0.3s 复查节拍
        // （`NowPlayingOneScreen.reconcile`，同一条"不新开定时器"的纪律）。
        if let page = target as? UIViewController, let pageView = page.view {
            NowPlayingOneScreen.apply(in: pageView)
            NowPlayingPageOverlay.apply(in: pageView)
            // ★ 2026-10-04：把这一页登记给「定向转储」（`ViewTreeDumper.setPage`）——
            //   听歌页那一棵约 800 节点，整窗 BFS 的 400 预算永远够不到头部/控件/footer。
            //   登记只是一个指针，不改任何视图、不读任何内容。
            ViewTreeDumper.setPage(pageView)
            // ⚠️ 下面这两层都是 `@MainActor` 的，而 hook 方法**不能**标 `@MainActor`
            // （Orion 的代码生成器按源码文本拼接，会拼出 `@MainActoroverride` —— 成文规矩见
            // `LyricsChromeVisibility.swift`）⇒ 用 `onMainThreadSync` 把"这里是主线程"
            // 显式表达出来（已是主线程时**同步执行**，不改时序）。
            onMainThreadSync {
                // 「歌词进播放器」：那一刻列表/底部那一坨常常还没建好，`apply` 里的
                // `reconcile` 对"没位置"是安静的，真正的重算交给 `DeclutterChrome` 的复查节拍。
                NowPlayingLyricsPlate.apply(in: pageView)
                // 「控制键换成本地字形」的兜底落点：万一 `PlaybackControlsElementsUnit`
                // 那个 hook 被 Orion 拒了，这条路照样能装（判据都是 id，与类名无关）。
                NowPlayingControlsPlate.apply(to: pageView)
            }
        }
    }

    /// 再补一次（`viewWillAppear` 那次可能早于曲目元数据/取色到位）。
    ///
    /// ⚠️ 只用**视图控制器的** `viewDidAppear`，不用 `viewDidLayoutSubviews`：
    /// 视图控制器的 `viewDidAppear` 一定会被覆写（转场就是它驱动的），
    /// 而 `viewDidLayoutSubviews` 是可选方法 —— 挂上去可能 `Failed to hook method`。
    /// 这一次的重复调用是**幂等**的：`NowPlayingBackdrop.apply` 已经垫过就只对齐尺寸、
    /// 颜色没变就一个字节都不碰（本轮起去掉了"同色就早退"—— 那个早退让自愈永远来不了）。
    func viewDidAppear(_ animated: Bool) {
        orig.viewDidAppear(animated)
        refreshNowPlayingBackdrop(page: target as? UIViewController)

        // 「一屏」的第二次机会：`viewDidAppear` 时列表通常已经建好了。
        if let page = target as? UIViewController, let pageView = page.view {
            NowPlayingOneScreen.apply(in: pageView)
            NowPlayingPageOverlay.apply(in: pageView)
            ViewTreeDumper.setPage(pageView)
            onMainThreadSync {
                NowPlayingLyricsPlate.apply(in: pageView)
                NowPlayingControlsPlate.apply(to: pageView)
            }
        }
    }
    
    func viewWillDisappear(_ animated: Bool) {
        shouldOverrideLocalTrackURI = false
        orig.viewWillDisappear(animated)
        // 页面要走了：停掉内嵌宿主看门狗（否则它会对着一个已经离开屏幕的页面一直查）。
        InlineLyricsHostLocator.stopLookup()
        // 定向转储的登记也一起撤掉 —— 否则离开听歌页之后还会一直按"页面"预算转储。
        ViewTreeDumper.setPage(nil)
        // 「歌词进播放器」那一层也收掉：页面已经不在屏幕上，留着只是白占一份 hosting。
        // ⚠️ 它在 `@MainActor` 上，而这里是非隔离的 hook 方法 ⇒ 走 `onMainThreadSync`。
        // 这一处**必须同步**（`viewWillDisappear` 里的清理不能延后），而它已经是主线程，
        // 所以 `assumeIsolated` 会立即执行 —— 时序与直接调用一致。
        onMainThreadSync { NowPlayingLyricsPlate.remove(reason: "page disappeared") }
    }
}

/// 「仿 AM 的整页取色底」的**唯一**刷新入口（全局函数，不是某个 hook 的方法）。
///
/// 调用点：
///   1. `NPVScrollViewControllerHook.viewWillAppear` / `.viewDidAppear` —— 每次进听歌页
///      （**传入 `target`**）；
///   2. 设置页切那个开关时 —— 关掉要**当场**还原（那时没有 `target`）。
///
/// ⚠️ **为什么必须能传 `page`**（2026-10-03 真机日志 37 换来的）：
/// 原来这个函数只认全局 `npvScrollViewController`，而给它赋值的
/// `provideScrollViewControllerWithDependencies:` 在 9.1.x 上已被移除、hook 被隔离在
/// `V91UnavailableLyricsGroup` ⇒ **那个全局恒为 nil** ⇒ 函数第一行就 return，
/// 日志里 `[NPVStyle]` 一行都没有、页面上什么都看不到。
/// 现在 hook 直接把 `target`（它自己就是那个 VC）传进来，不再依赖那个全局。
///
/// ★ 2026-10-03 夜（日志 38 之后）：日志 38 证明这条路已经通了（`[NPVStyle]` 两行），
/// 但"垫上去了却没变化"。真正的刷新缺口在**换歌/滚动之后**
/// （见 `NowPlayingBackdrop.reconcile()`）—— 不在这里。
/// 这一版只多一件事：没有 VC 时（= 设置页切开关）退到
/// `NowPlayingBackdrop.refreshLastPage()`，而不是干打一行"拿不到 VC"就结束。
///
/// 取封面色与歌词配色**同一处口径**（`track.metadata()["extracted_color"]`）。
func refreshNowPlayingBackdrop(page: UIViewController? = nil) {
    let controller = page ?? (npvScrollViewController as? UIViewController)
    guard let controller else {
        // 设置页那条路：没有 VC，但有"最近一次垫过的那一页"。它还挂着就当场落地。
        NowPlayingBackdrop.refreshLastPage()
        return
    }

    let view = controller.view
    guard let view, view.bounds.width > 1 else {
        writeDebugLog("[NPVStyle] 听歌页 view 还没尺寸（\(type(of: controller))）— 本次不施加")
        return
    }

    let track = statefulPlayer?.currentTrack() ?? nowPlayingScrollViewController?.loadedTrack
    let hex = track?.metadata()["extracted_color"]
    if hex == nil {
        // 这一行是 2026-10-03 补的：日志 37 里 `[NPVStyle]` **零行**，而当时分不清
        // 是"没跑到"还是"跑到但没取色"。现在两种情况各有一条日志。
        writeDebugLog("[NPVStyle] 这次没拿到封面取色（track=\(track == nil ? "nil" : "ok")）— 保留 Spotify 原始底")
    }
    NowPlayingBackdrop.apply(hex: hex, in: view)
}

class NowPlayingScrollViewControllerHook: ClassHook<NSObject> {    typealias Group = LegacyLyricsGroup
    static var targetName = "NowPlaying_ScrollImpl.NowPlayingScrollViewController"
    
    func nowPlayingScrollViewModelWithDidLoadComponentsFor(
        _ track: SPTPlayerTrack,
        withDifferentProviders: Bool,
        scrollEnabledValueChanged: Bool
    ) -> NowPlayingScrollViewController {
        let controller = orig.nowPlayingScrollViewModelWithDidLoadComponentsFor(
            track,
            withDifferentProviders: withDifferentProviders,
            scrollEnabledValueChanged: scrollEnabledValueChanged
        )
        
        if !scrollEnabledValueChanged {
            controller.scrollEnabled = true
            controller.nowPlayingScrollViewModelDidChangeScrollEnabledValue()
        }
        
        return controller
    }
}
