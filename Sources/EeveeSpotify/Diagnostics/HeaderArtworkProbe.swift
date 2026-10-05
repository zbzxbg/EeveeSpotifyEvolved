import Foundation
import UIKit

/// **只读探针**：专辑页 / 歌单页**头部封面到底是哪一个视图**。
///
/// ── 为什么要它（2026-10-13 日志 77 实测）────────────────────────────────────
///
/// 两个页面的头部是**两套东西**，不能照抄：
///   · 歌单页：`Components.Header.UI.ArtworkImage`
///     （日志 75 逐字：`23.ShadowContainer@76,62,262,262,id=Components.Header.UI.ArtworkImage`）；
///   · 专辑页：`CreativeWorkPlatform` 那一族 —— 日志 77 逐字：
///     `14.CreativeWorkTemplateView@0,0,414,896` /
///     `15.HeaderNavigationBar@0,0,414,102` /
///     `18.ElementView<Props, Any, Any>@0,0,414,477,id=CreativeWorkPlatform.Header` /
///     `19.UIView@0,0,414,477,id=CreativeWorkPlatform.Components.UI.CreativeWorkHeader`。
///     ⚠️ 而且**那个 Header 跟着滚动淡入淡出**（同一份日志里它依次是
///     `alpha=-0.42 → 0.59 → -0.05`）⇒ 将来做 hero **不能跟它抢 alpha**，否则两边打架。
///
/// 卡点：**封面那一格没有 `accessibilityIdentifier`**，而 `ViewTreeDumper` 在**深度 24 截断**
/// ⇒ 树里根本看不到它 ✗。所以补这一个探针：**只在那两个头部里往下走**（限深限数），
/// 把"像封面的"（方形、≥ 80pt）连同类名 / 尺寸 / 位置打出来。
///
/// ⚠️ **纯只读**：不 hook、不调用、不改任何东西。每 2s 看一眼，每种头部最多报 3 次就自己停
/// （报完把定时器停掉，不留常驻节拍）。
enum HeaderArtworkProbe {

    /// 要找的头部容器（按 `accessibilityIdentifier` 认，日志 75 / 77 逐字核过）。
    private static let headerIdentifiers = [
        "CreativeWorkPlatform.Components.UI.CreativeWorkHeader",
        "Components.Header.UI.ArtworkImage",
    ]

    /// 每种头部最多报几次（一次 = 一行 + 一串候选）。
    private static let maxReportsPerHeader = 3
    /// 全局行数上限（防刷屏）。
    private static let maxLines = 90
    /// 头部子树往下走几层 / 最多看多少个节点。
    private static let maxDepth = 10
    private static let maxNodes = 120

    private static var timer: Timer?
    private static var reportedHeaders: [String: Int] = [:]
    private static var lines = 0

    static func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 2.0, repeats: true) { _ in tick() }
        timer.tolerance = 0.3
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        writeDebugLog(
            "[HeaderProbe] armed — read-only; it walks the album/playlist header and lists candidate cover views"
        )
    }

    private static func stop() {
        timer?.invalidate()
        timer = nil
    }

    private static func tick() {
        guard lines < maxLines else { stop(); return }
        guard let window = frontWindow() else { return }

        for identifier in headerIdentifiers {
            guard (reportedHeaders[identifier] ?? 0) < maxReportsPerHeader else { continue }
            guard let header = firstView(in: window, withIdentifier: identifier) else { continue }
            reportedHeaders[identifier] = (reportedHeaders[identifier] ?? 0) + 1
            report(header, identifier: identifier, in: window)
        }

        if headerIdentifiers.allSatisfy({ (reportedHeaders[$0] ?? 0) >= maxReportsPerHeader }) {
            stop()
            writeDebugLog("[HeaderProbe] done — every header reported; probe stopped")
        }
    }

    // MARK: - 报一行

    private static func report(_ header: UIView, identifier: String, in window: UIView) {
        let frame = header.convert(header.bounds, to: window)
        let className = String(describing: type(of: header))
        lines += 1
        writeDebugLog(
            "[HeaderProbe] \(shortName(identifier)) — \(className) \(rectText(frame))"
                + " alpha=\(String(format: "%.2f", header.alpha))"
                + " id=\(identifier)"
        )

        var candidates: [String] = []
        var seen = 0
        walk(header, header, in: window, depth: 0, seen: &seen, into: &candidates)

        for chunk in chunks(candidates, size: 4) {
            lines += 1
            guard lines < maxLines else { break }
            writeDebugLog("[HeaderProbe]   candidates: " + chunk.joined(separator: " | "))
        }
        if candidates.isEmpty {
            writeDebugLog("[HeaderProbe]   candidates: (none — nothing square and large enough in there)")
        }

        // ★ 2026-10-13 追加（**日志 80** 的教训）：**整页里带 id 的视图**也要列出来。
        //   歌单页的控制行（分享 / ⋯ / 随机 / 播放）、curation pill 行（添加 / 编辑 / 排序 / 姓名和详情）
        //   与"在此页面上查找"那个搜索框**都不在头部里** ⇒ 只摸头部的话，"藏掉 Spotify 那些按键"
        //   在歌单页**一个都命中不了**（日志 80 里连一行 `hid … chrome` 都没有 ✗）。
        //   这里只列 id + 尺寸 + 位置，限深限数。
        if let page = pageAncestor(of: header, in: window) {
            var ids: [String] = []
            var seenIds = 0
            collectIdentifiers(in: page, of: window, depth: 0, seen: &seenIds, into: &ids)
            for chunk in chunks(ids, size: 3) {
                guard lines < maxLines else { break }
                lines += 1
                writeDebugLog("[HeaderProbe]   page ids: " + chunk.joined(separator: " | "))
            }
        }
    }

    /// 子树里"像封面"的那些：**方形且 ≥ 80pt**、类名带 Image/Artwork/Cover、或自带 id。
    private static func walk(
        _ root: UIView,
        _ node: UIView,
        in window: UIView,
        depth: Int,
        seen: inout Int,
        into out: inout [String]
    ) {
        guard depth <= maxDepth, seen < maxNodes, lines < maxLines else { return }
        seen += 1

        let name = String(describing: type(of: node))
        let frame = node.convert(node.bounds, to: window)
        let identifier = node.accessibilityIdentifier ?? ""

        let isSquareAndBig = frame.width >= 80
            && abs(frame.width - frame.height) <= 2
            && frame.height >= 80
        let nameLooksLikeArtwork = name.contains("Image") || name.contains("Artwork") || name.contains("Cover")

        if node !== root, isSquareAndBig || nameLooksLikeArtwork || !identifier.isEmpty {
            var piece = "\(shortName(name)) \(rectText(frame))"
            if !identifier.isEmpty { piece += " id=\(identifier)" }
            out.append(piece)
        }

        guard frame.width > 1, frame.height > 1 else { return }
        for sub in node.subviews { walk(root, sub, in: window, depth: depth + 1, seen: &seen, into: &out) }
    }

    // MARK: - 小工具

    /// 头部往上第一个"占满屏"的祖先 = 这一页（与 `EntityPageAppearance.pageRoot` 同一条几何）。
    private static func pageAncestor(of view: UIView, in window: UIView) -> UIView? {
        var node: UIView? = view
        while let current = node, current !== window {
            let frame = current.convert(current.bounds, to: window)
            if frame.height >= window.bounds.height * 0.8 { return current }
            node = current.superview
        }
        return nil
    }

    /// 整页里**带 `accessibilityIdentifier`** 的视图（id + 尺寸 + 位置），限深限数。
    private static func collectIdentifiers(
        in node: UIView,
        of window: UIView,
        depth: Int,
        seen: inout Int,
        into out: inout [String]
    ) {
        guard depth <= 12, seen < 400, out.count < 120 else { return }
        seen += 1
        if let identifier = node.accessibilityIdentifier, !identifier.isEmpty {
            let frame = node.convert(node.bounds, to: window)
            out.append(
                "\(shortName(String(describing: type(of: node)))) \(rectText(frame)) id=\(identifier)"
            )
        }
        for sub in node.subviews {
            collectIdentifiers(in: sub, of: window, depth: depth + 1, seen: &seen, into: &out)
        }
    }

    private static func frontWindow() -> UIWindow? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .filter { !$0.isHidden && $0.alpha > 0.01 }
        return windows.first { $0.isKeyWindow } ?? windows.first
    }

    private static func firstView(in root: UIView, withIdentifier identifier: String) -> UIView? {
        if root.accessibilityIdentifier == identifier { return root }
        for sub in root.subviews {
            if let hit = firstView(in: sub, withIdentifier: identifier) { return hit }
        }
        return nil
    }

    private static func shortName(_ name: String) -> String {
        name.components(separatedBy: ".").last ?? name
    }

    private static func rectText(_ rect: CGRect) -> String {
        "\(Int(rect.minX.rounded())),\(Int(rect.minY.rounded()))"
            + ",\(Int(rect.width.rounded())),\(Int(rect.height.rounded()))"
    }

    private static func chunks<T>(_ items: [T], size: Int) -> [[T]] {
        guard size > 0 else { return [items] }
        return stride(from: 0, to: items.count, by: size).map {
            Array(items[$0..<min($0 + size, items.count)])
        }
    }
}
