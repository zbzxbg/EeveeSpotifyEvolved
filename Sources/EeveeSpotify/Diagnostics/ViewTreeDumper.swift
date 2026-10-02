import UIKit

/// 离线的「看视图树」手段：按固定间隔把当前 key window 的**结构**写进调试日志。
///
/// 为什么需要它：给 Spotify 的界面写 hook 之前必须先知道屏幕上到底有哪些类。
/// AMOLED / 隐藏某个区块 / 播放器手势这三类改动全都卡在这一步。spoti.pw 那套是
/// FLEX + `make trees` 交互录屏；本项目是侧载，跑不了那套流程，所以退一步：
/// 一个**只读**定时器把结构写进日志，用户按现有习惯（`C:\dsh\readlog`）捞出来即可。
///
/// ⚠️ 三条纪律，都是本仓库用真金白银换来的：
///   1. **不做运行时类枚举**。2026-09 的两次启动崩溃都是这么来的：EXC_BREAKPOINT /
///      SIGTRAP，栈在 `_CF_forwarding_prep_0` → `swift_getObjectType`，寄存器里是
///      `__NSGenericDeallocHandler` —— 给已释放的类对象发消息。见 `Tweak.x.swift`
///      里 `logPlayerTrackCandidates` 那段注释与 `C:\dsh\readlog` 的 .ips。所以这里
///      **只从 key window 往下走活着的视图**，绝不碰 `objc_getClassList`。
///   2. **只读**：不改 frame / 颜色 / 层级，不注册手势，不读文本内容
///      （只读类名、frame、hidden、alpha、accessibilityIdentifier）。
///   3. **有界**：深度 ≤ 12、节点 ≤ 150、单次启动 ≤ 20 份、结构没变不重复打。
///
/// 开关在「调试」页，打开**立即**生效（设置页直接调 `applyEnabledState()`），
/// 并且已接到 `EeveeSpotify.init`，重启后自动续上。
enum ViewTreeDumper {

    private static let interval: TimeInterval = 2.0
    /// ⚠️ 深度上限给 24，不是 12。第二轮真机转储（09-30 12:48）暴露出来的：
    /// Spotify 自己的 chrome 就吃掉 12 层（window → App-Main-Content-View →
    /// barViewController container → UILayoutContainerView → UINavigationTransitionView
    /// → UIViewControllerWrapperView → **12.UIView = 页面**），页面内容从第 13 层才开始。
    /// 原来卡在 12，等于**每次都只转储外壳、永远看不到页面**。
    private static let maxDepth = 24
    /// 节点上限。广度优先之后这个数就是"能看到多少个节点"，400 足以铺满一整屏的
    /// 宽度（第三轮的 250 被外壳吃掉，屏幕下半部分完全看不到）。
    private static let maxNodes = 400
    /// ★ 2026-10-04：**定向页子树**的节点预算（听歌页那一棵约 800 节点，400 永远够不到底部那坨）。
    ///
    /// 为什么必须单开一档：日志 40/41 的 20 份树**每份正好 402 行**，正好卡在 `maxNodes` 上
    /// ⇒ 头部 / 控件 / footer 一次都没进过日志（pw 说的 `HeaderElementsUnit` /
    /// `PlaybackControlsElementsUnit` / `FooterElementsUnit` 在全量日志里**零命中**，
    /// 而"头部排版 / 控件行"这两刀正卡在这份证据上）。
    private static let maxPageNodes = 1200
    private static let maxDumps = 20

    /// ★ 定向转储的页根（2026-10-04）：由**页面自己的 hook** 登记（听歌页 = `NPVScrollViewControllerHook`）。
    ///
    /// 为什么不能在这里自己按类名找：那要做运行时类枚举 / 猜类名，本仓库为此崩过两次
    /// （见文件头纪律 1）。登记进来的这条链是**弱引用 + 校验还在窗口里**，页面走了就自动失效。
    ///
    /// 语义：开着「转储视图树」且用户在听歌页时，这一拍**只转储这一页的子树**（预算 `maxPageNodes`），
    /// 打 `[NPVTree]`；其它屏照旧走 `[Tree]`（整窗 BFS、400 节点）。
    private static weak var pageRoot: UIView?

    private static var timer: Timer?
    private static var dumpsTaken = 0
    private static var lastSkeleton = ""

    static var isRunning: Bool { timer != nil }

    /// 幂等：先停再按开关决定起不起。开关一变就调它。
    static func applyEnabledState() {
        stop()

        guard UserDefaults.dumpViewTree else {
            writeDebugLog("[Tree] off")
            return
        }

        writeDebugLog("[Tree] armed — one line every \(Int(interval))s, \(maxDumps) dumps max")
        let timer = Timer(timeInterval: interval, repeats: true) { _ in dumpOnce() }
        timer.tolerance = 0.5
        // `.common` 模式：滚动时主线程跑在 tracking 模式，用 default 会停摆。
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    static func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// ★ 定向转储：页面自己的 hook 在 `viewWillAppear` / `viewDidAppear` 里把**这一页的根视图**
    /// 登记进来（听歌页那两处调用点在 `CustomLyrics+AllTracksLyrics.x.swift` 的
    /// `NPVScrollViewControllerHook`）。**只登记一个指针**，什么都不做、什么都不改。
    ///
    /// 传 `nil` 会清掉登记（比如页面要走了）。刻意**不做**"自动判断页面是否还在"以外的清理：
    /// 每次用之前都会 `window` 校验一次，页面销毁后 weak 引用自己会变 nil。
    static func setPage(_ page: UIView?) {
        pageRoot = page
    }

    private static func dumpOnce() {
        // 定时器跑在主线程；访视图必须在主线程 —— 这两件事正好一致。
        guard dumpsTaken < maxDumps else {
            writeDebugLog("[Tree] cap reached (\(maxDumps)) — stopping")
            stop()
            return
        }
        guard UIApplication.shared.applicationState == .active else { return }
        guard let window = keyWindow() else { return }

        // ★ 在"登记过的页"上 → 只转储这一页的子树（预算更大），tag 用 `[NPVTree]`。
        //   为什么要换预算而不是追加：听歌页那一棵 800 节点，整窗 BFS 的前 400 个
        //   全被外壳和页面上半截吃掉 —— 那正是头部/控件/footer 从来没进过日志的原因。
        if let page = pageRoot, page.window != nil {
            dumpPage(page)
            return
        }

        var nodes: [String] = []
        var skeleton: [String] = []
        collect(window, nodes: &nodes, skeleton: &skeleton, limit: maxNodes)
        guard !nodes.isEmpty else { return }

        let skeletonText = skeleton.joined(separator: "/")
        // 结构没变就不重复打：设置页这种静态屏幕因此只占一行。
        guard skeletonText != lastSkeleton else { return }
        lastSkeleton = skeletonText
        dumpsTaken += 1

        // **一行一个节点**，不是整棵树挤成一行。
        //
        // 为什么改：第一轮真机转储（09-30）每棵树都被压成一行，而日志工具/编辑器
        // 按 2000 字符截断 —— 结果只能看到最上面 ~40 个节点，页面背景、播放器控件
        // 这些真正要写 hook 的地方全被截掉了。拆行之后整棵树都能读到。
        writeDebugLog(
            "[Tree] #\(dumpsTaken) begin vc=\(visibleControllerChain(window)) nodes=\(nodes.count)"
        )
        for node in nodes {
            writeDebugLog("[Tree] #\(dumpsTaken) \(node)")
        }
        writeDebugLog("[Tree] #\(dumpsTaken) end")
    }

    /// ★ 定向页转储：只走这一页的子树，预算 `maxPageNodes`，tag = `[NPVTree]`。
    ///
    /// 与整窗那份的**唯一**区别就是起点与预算；"结构没变就不打"那条规则照旧（同一套 skeleton）。
    /// 用**独立的**计数器后缀（`npv#N`）而不是接着 `[Tree] #N` 数：两份日志混在一起时，
    /// "这一份是整窗还是页面"必须一眼看得出来，否则事后又要靠行数反推。
    private static func dumpPage(_ page: UIView) {
        var nodes: [String] = []
        var skeleton: [String] = []
        collect(page, nodes: &nodes, skeleton: &skeleton, limit: maxPageNodes)
        guard !nodes.isEmpty else { return }

        let skeletonText = "page/" + skeleton.joined(separator: "/")
        guard skeletonText != lastSkeleton else { return }
        lastSkeleton = skeletonText
        dumpsTaken += 1

        writeDebugLog(
            "[NPVTree] #\(dumpsTaken) begin \(String(describing: type(of: page))) nodes=\(nodes.count)"
        )
        for node in nodes {
            writeDebugLog("[NPVTree] #\(dumpsTaken) \(node)")
        }
        writeDebugLog("[NPVTree] #\(dumpsTaken) end")
    }

    private static func keyWindow() -> UIWindow? {
        let windows = UIApplication.shared.windows
        return windows.first(where: { $0.isKeyWindow }) ?? windows.first
    }

    /// 当前屏幕上"在哪一页"的最短证据链：presented → navigation 的 visible → tab 的 selected。
    private static func visibleControllerChain(_ window: UIWindow) -> String {
        var chain: [String] = []
        var controller = window.rootViewController

        while let current = controller, chain.count < 6 {
            chain.append(String(describing: type(of: current)))

            if let presented = current.presentedViewController {
                controller = presented
            } else if let navigation = current as? UINavigationController {
                controller = navigation.visibleViewController
            } else if let tab = current as? UITabBarController {
                controller = tab.selectedViewController
            } else {
                controller = nil
            }
        }

        return chain.isEmpty ? "?" : chain.joined(separator: ">")
    }

    private static func collect(
        _ root: UIView,
        nodes: inout [String],
        skeleton: inout [String],
        limit: Int
    ) {
        // ⚠️ **广度优先**，不是深度优先。
        //
        // 原因：原来是深度优先 + 250 节点上限，结果配额全被"第一个分支"吃光 ——
        // 外壳（window → App-Main-Content-View → barViewController → navbar/tabbar）
        // 加页面开头就 250 个节点了，**屏幕下半部分的控件（进度条、播放键那一支）
        // 一个都到不了**。第三轮清点 39 份转储时发现的：里面 PlayButton 一堆，
        // 却没有任何 Slider / Scrubber / ProgressBar —— 不是没去过那屏，是没走到。
        //
        // 广度优先先铺满整屏的宽度，再逐层往下，所以"每一层有什么"都能看到。
        var queue: [(view: UIView, depth: Int)] = [(root, 0)]
        var index = 0

        while index < queue.count, nodes.count < limit {
            let (view, depth) = queue[index]
            index += 1

            guard depth <= maxDepth else { continue }

            let className = String(describing: type(of: view))
            skeleton.append(className)

            let frame = view.frame
            var detail = "\(depth).\(className)"
            detail += "@\(Int(frame.origin.x)),\(Int(frame.origin.y)),\(Int(frame.width)),\(Int(frame.height))"
            if view.isHidden { detail += ",hidden" }
            if view.alpha < 1 { detail += ",alpha=\(String(format: "%.2f", view.alpha))" }
            // 底色：第三轮的教训 —— "哪一层画了那层灰"光看类名看不出来，`bg=` 一看就知道
            // （AMOLED 要涂的正是它；`TabBarView` 那条 `barBg=0` 就是靠这个才能继续追）。
            if let background = view.backgroundColor, background != .clear {
                detail += ",bg=\(hexColor(background))"
            }
            if let identifier = view.accessibilityIdentifier, !identifier.isEmpty {
                detail += ",id=\(identifier)"
            }
            nodes.append(detail)

            for subview in view.subviews {
                queue.append((subview, depth + 1))
            }
        }
    }

    /// `#RRGGBB`。拿不到分量（图案色 / 动态色）就返回 `?`，不编造。
    private static func hexColor(_ color: UIColor) -> String {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0

        if color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
            return String(
                format: "#%02X%02X%02X",
                Int(red * 255), Int(green * 255), Int(blue * 255)
            )
        }

        var white: CGFloat = 0
        if color.getWhite(&white, alpha: &alpha) {
            let value = Int(white * 255)
            return String(format: "#%02X%02X%02X", value, value, value)
        }

        return "?"
    }
}
