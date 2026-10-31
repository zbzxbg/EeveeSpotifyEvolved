// 「队列页」—— 把 Spotify 自己的「队列」卡片做成 MeloX / AM 那种形状
// （队列页：顶部当前歌 + 一排圆按钮 + 原生列表）。
//
// ## 为什么是"插一块"而不是"重排"
//
// 那张卡是 Spotify **正在正常工作**的系统弹窗（拖动、移除、点播全在里面），而我们
// **一次都没有它的视图树**。整页重排 = 盲改一个能用
// 的弹窗，风险不成比例。所以这一版只做**加法**：
//
// · 找到那张卡的**列表**（`UITableView`），把我们的头部塞进 `tableHeaderView`
// —— 这是 UIKit 自己的机制：列表内容**自动**被推到下面，不用改任何原生 frame、
// 不用 contentInset、不需要知道它原来的布局，撤掉就是 `tableHeaderView = nil`；
// · 头部 = **当前歌曲行**（48pt 圆角封面 + 歌名 + 艺人）+ **一排三颗圆按钮**
// （随机 / 循环 / 定时器）；
// · 三颗按钮**不自己实现功能**：在卡片里按无障碍名（"随机 / 循环 / 定时"，
// 英文界面是 "shuffle / repeat / timer"）找**卡片自己那三颗**，点到就
// `sendActions(for: .touchUpInside)` 转发给它 —— 找不到的那颗**不画**（不放假按钮），
// 这也是为什么"原生列表不动"：我们只加了一行头。
//
// ## 顺带：这一版会自己把那张卡的视图树打进日志
//
// 第一次认出队列卡片时打一份 `[QueuePage] tree — …`（类名 / frame / id / alpha）。
// 以后不管有没有开「转储视图树」，
// "队列/编辑/正在播放 N" 那一行、以及三颗原生钮的确切位置一次对齐。
//
// 日志 tag：`[QueuePage]`。开关跟着「iOS 27 听歌页」（它才有那颗队列键）。
import Foundation
import UIKit
import ObjectiveC.runtime

@MainActor
enum QueuePage {

    static let logTag = "QueuePage"

    /// 头部尺寸（MeloX：歌曲行 + 一排 44pt 的圆按钮）。
    static let headerHeight: CGFloat = 128
    static let songRowHeight: CGFloat = 64
    static let coverSide: CGFloat = 48
    static let coverInset: CGFloat = 20
    static let coverTextGap: CGFloat = 12
    static let buttonRowHeight: CGFloat = 56
    static let buttonSide: CGFloat = 44
    static let cornerRadius: CGFloat = 8

    /// 找原生三颗按钮用的关键词（中英各一套；`accessibilityLabel` 命中即算）。
    static let shuffleNeedles = ["随机", "shuffle"]
    static let repeatNeedles = ["循环", "repeat"]
    static let timerNeedles = ["定时", "timer", "sleep"]

    // MARK: - 状态

    static weak var sheetView: UIView?
    static weak var headerView: UIView?
    static weak var coverView: UIImageView?
    static weak var titleLabel: UILabel?
    static weak var artistLabel: UILabel?
    static var buttonViews: [UIButton] = []
    /// 每颗按钮转发给谁（nil = 这颗没画出来）。
    static var nativeTargets: [UIView?] = []

    static var didDumpTree = false
    static var didLogInstall = false
    static var lastTrackKey = ""
    /// 我们接管之前那张表的 `tableHeaderView`（收尾要原样放回去）。
    static weak var originalTableHeader: UIView?
    /// 卡片的列表（弱引用；卡片重建就自己掉）。
    static weak var tableView: UITableView?
    /// 找原生三颗按钮的节流计数（没找齐时约 3 秒扫一次，别每拍 BFS）。
    static var controlSearchTicks = 0

    /// （改队列这个事情先回退吧）：**整条队列改版先关掉**。
    ///
    /// 上一版把 Spotify 的队列卡加了一层头部、又把它从半屏 sheet 抬到整页高度；用户看过后
    /// 决定先回退到 Spotify 原生那张卡。这里只把入口关掉 —— 定时器那一步会走
    /// `teardown`，把已经插进去的头部与按钮原样撤回（`tableHeaderView` 也会放回去）。
    ///
    /// 代码留着：下一轮拿到 `[QueuePage] tree` 之后按真实树重做 MeloX 那种整页，
    /// 到时把这一行改回 `UserDefaults.nowPlayingIOS27` 即可。
    static var isEnabled: Bool { false }

    // MARK: - 对外入口（蹭 0.3s 节拍）

    @discardableResult
    static func reconcile() -> Bool {
        guard isEnabled else {
            if sheetView != nil || headerView != nil { teardown(reason: "switch off") }
            return false
        }
        guard let sheet = presentedQueueSheet(), let root = sheet.viewIfLoaded else {
            if sheetView != nil || headerView != nil { teardown(reason: "sheet dismissed") }
            return false
        }
        if sheetView !== root {
            // 换了一张卡（上一张的弱引用还在）⇒ 先把旧的拆干净。
            teardown(reason: "new sheet")
            sheetView = root
        }
        // 先打树（不管有没有表）：这是下一轮的图纸，一次就够。
        if !didDumpTree { dumpTree(root) }

        guard let table = tableFor(root) else {
            if !didLogInstall {
                didLogInstall = true
                let scrollClass = firstScrollView(in: root)
                    .map { NSStringFromClass(type(of: $0)) } ?? "none"
                writeDebugLog(
                    "[\(logTag)] no UITableView on the queue sheet (first scroll view: \(scrollClass))"
                        + " — only the tree dump ran"
                )
            }
            return false
        }
        return install(in: root, table: table)
    }

    /// 只有一份日志用的：卡片里第一个滚动视图是谁（下一轮据此决定用 collectionView 那条路）。
    private static func firstScrollView(in root: UIView) -> UIView? {
        var queue: [UIView] = [root]
        var visited = 0
        while !queue.isEmpty, visited < 600 {
            let view = queue.removeFirst()
            visited += 1
            if view is UIScrollView { return view }
            queue.append(contentsOf: view.subviews)
        }
        return nil
    }

    /// 这张卡的列表：缓存一份，掉出窗口/换页再重新找（不每拍 600 节点 BFS）。
    private static func tableFor(_ root: UIView) -> UITableView? {
        if let cached = tableView, cached.window != nil, cached.isDescendant(of: root) {
            return cached
        }
        let found = firstTableView(in: root)
        tableView = found
        return found
    }

    // MARK: - 找那张卡
    //
    // 当前屏幕上那张队列卡片（`Queue_ViewImpl.QueueViewController`）。
    //
    // 从每个窗口的根 VC 往下走 `presentedViewController` **和** `children`
    // （它是弹出来的 sheet，通常在 presented 链上）。
    private static func presentedQueueSheet() -> UIViewController? {
        var roots: [UIViewController] = []
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                if let root = window.rootViewController { roots.append(root) }
            }
        }
        var queue = roots
        var visited = 0
        while !queue.isEmpty, visited < 300 {
            let controller = queue.removeFirst()
            visited += 1
            if NSStringFromClass(type(of: controller)).contains("QueueViewController") {
                return controller
            }
            if let presented = controller.presentedViewController { queue.append(presented) }
            queue.append(contentsOf: controller.children)
        }
        return nil
    }

    /// 卡片里那张列表（`UITableView` 优先；没有就返回 nil —— 只打树、不动界面）。
    private static func firstTableView(in root: UIView) -> UITableView? {
        var queue: [UIView] = [root]
        var visited = 0
        while !queue.isEmpty, visited < 600 {
            let view = queue.removeFirst()
            visited += 1
            if let table = view as? UITableView { return table }
            queue.append(contentsOf: view.subviews)
        }
        return nil
    }

    // MARK: - 装上头部

    @discardableResult
    private static func install(in root: UIView, table: UITableView) -> Bool {
        var changed = false
        // 还没排过版（宽度是 0）就等下一拍 —— 这时塞头部只会塞出一个 0 宽的框。
        let width = table.bounds.width
        guard width > 40 else { return false }

        let header: UIView
        if let existing = headerView, existing.superview === table || table.tableHeaderView === existing {
            header = existing
        } else {
            // 第一次接管：先把表原来那个头记下来（收尾要放回去，不能吞掉 Spotify 自己的东西）。
            if originalTableHeader == nil { originalTableHeader = table.tableHeaderView }
            header = makeHeader(width: width)
            headerView = header
            table.tableHeaderView = header
            changed = true
        }
        let wantedHeight = headerHeight
        if header.frame.width != width || header.frame.height != wantedHeight {
            header.frame = CGRect(x: 0, y: 0, width: width, height: wantedHeight)
            table.tableHeaderView = header   // UITableView 只认重新赋值时的 frame
            changed = true
        }
        if updateSong() { changed = true }
        if refreshButtons(in: root) { changed = true }
        return changed
    }

    /// 头部：上面一行当前歌曲，下面一排圆按钮。
    private static func makeHeader(width: CGFloat) -> UIView {
        let header = UIView(frame: CGRect(x: 0, y: 0, width: width, height: headerHeight))
        header.accessibilityIdentifier = "eevee-queue-header"

        let cover = UIImageView(frame: .zero)
        cover.contentMode = .scaleAspectFill
        cover.clipsToBounds = true
        cover.layer.cornerRadius = cornerRadius
        cover.layer.cornerCurve = .continuous
        cover.backgroundColor = UIColor(white: 1, alpha: 0.08)
        header.addSubview(cover)
        coverView = cover

        let title = UILabel(frame: .zero)
        title.font = UIFont.systemFont(ofSize: 17, weight: .semibold)
        title.textColor = .white
        title.lineBreakMode = .byTruncatingTail
        header.addSubview(title)
        titleLabel = title

        let artist = UILabel(frame: .zero)
        artist.font = UIFont.systemFont(ofSize: 13, weight: .regular)
        artist.textColor = UIColor(white: 1, alpha: 0.6)
        artist.lineBreakMode = .byTruncatingTail
        header.addSubview(artist)
        artistLabel = artist

        return header
    }

    /// 这一次量到的歌曲信息（封面优先拿我们自己画的那张 —— 同一首歌，已经在内存里）。
    private static func updateSong() -> Bool {
        guard let header = headerView, let cover = coverView,
              let title = titleLabel, let artist = artistLabel else { return false }

        let track = statefulPlayer?.currentTrack()
        // ⚠️ 用 `string(ifResponding:)` 取，**不要**直接调 `artistTitle`：
        // 那个选择器在 9.1.x 上不存在（见 `SPTPlayerTrack+Extension` 的说明）。
        let titleText = track?.string(ifResponding: "trackTitle") ?? ""
        let byName = track?.string(ifResponding: "artistName") ?? ""
        let artistText = byName.isEmpty
            ? (track?.string(ifResponding: "artistTitle") ?? "")
            : byName
        let key = titleText + "\u{1}" + artistText

        var changed = false
        if key != lastTrackKey {
            lastTrackKey = key
            if title.text != titleText { title.text = titleText; changed = true }
            if artist.text != artistText { artist.text = artistText; changed = true }
            changed = true
        }
        if cover.image !== NowPlayingIOS27.artworkView?.image {
            cover.image = NowPlayingIOS27.artworkView?.image
            changed = true
        }

        let rowTop = (songRowHeight - coverSide) / 2
        let coverFrame = CGRect(x: coverInset, y: rowTop, width: coverSide, height: coverSide)
        if cover.frame != coverFrame { cover.frame = coverFrame; changed = true }
        let textX = coverInset + coverSide + coverTextGap
        let textWidth = max(40, header.bounds.width - textX - 16)
        let titleFrame = CGRect(x: textX, y: rowTop + 4, width: textWidth, height: 21)
        if title.frame != titleFrame { title.frame = titleFrame; changed = true }
        let artistFrame = CGRect(x: textX, y: rowTop + 26, width: textWidth, height: 17)
        if artist.frame != artistFrame { artist.frame = artistFrame; changed = true }
        return changed
    }

    /// 一排三颗圆按钮：**找到了原生那颗才画**（不放假按钮）。
    private static func refreshButtons(in root: UIView) -> Bool {
        guard let header = headerView else { return false }
        var changed = false

        let specs: [(UIImage?, [String], String)] = [
            (systemGlyph("shuffle"), shuffleNeedles, "shuffle"),
            (systemGlyph("repeat"), repeatNeedles, "repeat"),
            (systemGlyph("timer"), timerNeedles, "timer"),
        ]
        var targets: [UIView?] = []
        let cachedTargets = nativeTargets
        let needsSearch = cachedTargets.count != specs.count
            || cachedTargets.contains { view in
                guard let view else { return true }
                return view.window == nil
            }
        if needsSearch {
            // 没找齐时**约 3 秒扫一次**（1500 节点 × 3 组关键词，不能每拍跑）。
            controlSearchTicks += 1
            if controlSearchTicks % 10 == 1 || cachedTargets.isEmpty {
                for (_, needles, _) in specs {
                    targets.append(findControl(in: root, needles: needles))
                }
            } else {
                targets = cachedTargets
            }
        } else {
            targets = cachedTargets
        }
        // 长度必须与 `specs` 对齐（被节流那一拍照样要能按下标取）。
        if targets.count != specs.count {
            targets = Array(repeating: nil, count: specs.count)
        }

        if buttonViews.count != specs.count {
            for button in buttonViews { button.removeFromSuperview() }
            buttonViews = specs.enumerated().map { index, spec in
                let button = UIButton(type: .system)
                button.tag = index
                button.accessibilityIdentifier = "eevee-queue-button-\(spec.2)"
                button.tintColor = UIColor(white: 1, alpha: 0.92)
                button.setImage(spec.0, for: .normal)
                button.layer.cornerRadius = buttonSide / 2
                button.layer.cornerCurve = .continuous
                button.backgroundColor = UIColor(white: 1, alpha: 0.10)
                button.addTarget(QueuePageTapTarget.shared, action: #selector(QueuePageTapTarget.tapped(_:)), for: .touchUpInside)
                header.addSubview(button)
                return button
            }
            changed = true
        }
        nativeTargets = targets

        let visible = specs.indices.filter { targets[$0] != nil }
        let rowTop = songRowHeight + (buttonRowHeight - buttonSide) / 2
        for (index, button) in buttonViews.enumerated() {
            let shown = visible.contains(index)
            if button.isHidden == shown {   // isHidden 为 true = 不显示
                button.isHidden = !shown
                changed = true
            }
            guard shown, let slot = visible.firstIndex(of: index) else { continue }
            let count = max(1, visible.count)
            let slotWidth = header.bounds.width / CGFloat(count)
            let centreX = slotWidth * (CGFloat(slot) + 0.5)
            let frame = CGRect(
                x: (centreX - buttonSide / 2).rounded(),
                y: rowTop.rounded(),
                width: buttonSide,
                height: buttonSide
            )
            if button.frame != frame { button.frame = frame; changed = true }
        }

        if !didLogInstall {
            didLogInstall = true
            let names = ["shuffle", "repeat", "timer"]
            let found = specs.indices.map { index in
                targets[index].map { "\(names[index])=\(NSStringFromClass(type(of: $0)))" }
                    ?? "\(names[index])=missing"
            }
            writeDebugLog(
                "[\(logTag)] header installed on \(NSStringFromClass(type(of: header.superview ?? header)))"
                    + " — song row + \(visible.count)/3 round button(s); " + found.joined(separator: ", ")
            )
        }
        return changed
    }

    /// 按无障碍名找那颗原生按钮（卡片自己的随机 / 循环 / 定时器）。
    private static func findControl(in root: UIView, needles: [String]) -> UIView? {
        var queue: [UIView] = [root]
        var visited = 0
        while !queue.isEmpty, visited < 1500 {
            let view = queue.removeFirst()
            visited += 1
            queue.append(contentsOf: view.subviews)
            guard view is UIControl else { continue }
            let label = (view.accessibilityLabel ?? "").lowercased()
            let identifier = (view.accessibilityIdentifier ?? "").lowercased()
            let haystack = label + " " + identifier
            if needles.contains(where: { haystack.contains($0.lowercased()) }) { return view }
        }
        return nil
    }

    private static func systemGlyph(_ name: String) -> UIImage? {
        let configuration = UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        return UIImage(systemName: name, withConfiguration: configuration)?
            .withRenderingMode(.alwaysTemplate)
    }

    // MARK: - 转发那一下
    //
    // 圆按钮被点了（`QueuePageTapTarget` 转进来）：把这一下交给卡片自己那颗。
    static func tapButton(index: Int) {
        guard index >= 0, index < nativeTargets.count, let target = nativeTargets[index] else {
            writeDebugLog("[\(logTag)] button \(index) has no native target — nothing to forward to")
            return
        }
        guard let control = target as? UIControl else {
            writeDebugLog(
                "[\(logTag)] \(NSStringFromClass(type(of: target))) is not a UIControl — cannot forward"
            )
            return
        }
        control.sendActions(for: .touchUpInside)
    }

    // MARK: - 视图树（一次性，给下一轮当图纸）

    private static func dumpTree(_ root: UIView) {
        guard !didDumpTree else { return }
        didDumpTree = true
        var lines: [String] = []
        var queue: [(UIView, Int)] = [(root, 0)]
        var visited = 0
        while !queue.isEmpty, visited < 400 {
            let (view, depth) = queue.removeFirst()
            visited += 1
            let frame = view.frame
            let identifier = view.accessibilityIdentifier ?? ""
            let label = view.accessibilityLabel ?? ""
            var line = String(repeating: "  ", count: min(depth, 12))
            line += NSStringFromClass(type(of: view))
            line += " \(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height))"
            if !identifier.isEmpty { line += " id=\(identifier)" }
            if !label.isEmpty { line += " label=\(label)" }
            if view.alpha < 0.99 { line += " alpha=\(String(format: "%.2f", view.alpha))" }
            if view.isHidden { line += " hidden" }
            lines.append(line)
            for sub in view.subviews { queue.append((sub, depth + 1)) }
        }
        writeDebugLog("[\(logTag)] tree — \(visited) view(s)\n" + lines.joined(separator: "\n"))
    }

    // MARK: - 收尾

    static func teardown(reason: String) {
        if let header = headerView {
            if let table = header.superview as? UITableView, table.tableHeaderView === header {
                // 把表原来那个头放回去（我们只借了这一格）。
                table.tableHeaderView = originalTableHeader
            }
            header.removeFromSuperview()
        }
        for button in buttonViews { button.removeFromSuperview() }
        buttonViews = []
        nativeTargets = []
        headerView = nil
        coverView = nil
        titleLabel = nil
        artistLabel = nil
        sheetView = nil
        originalTableHeader = nil
        tableView = nil
        controlSearchTicks = 0
        lastTrackKey = ""
        didDumpTree = false
        if didLogInstall {
            writeDebugLog("[\(logTag)] removed (\(reason))")
        }
        didLogInstall = false
    }
}

/// 圆按钮的 target（`UIControl` 的 target 必须是 ObjC 对象）。
final class QueuePageTapTarget: NSObject {
    static let shared = QueuePageTapTarget()

    @objc func tapped(_ sender: UIButton) {
        onMainThreadSync { QueuePage.tapButton(index: sender.tag) }
    }
}
