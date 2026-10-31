// 「歌词进播放器」——歌手行（提供商后缀 / 还原 / 找 label）。
// 从 `NowPlayingLyricsPlate.swift` 原样拆出（`NowPlayingLyricsPlate` 的 extension）；
// 形状、动画与硬约束见那个文件的头注。
import Foundation
import SwiftUI
import UIKit
import Orion
import ObjectiveC.runtime

@MainActor
extension NowPlayingLyricsPlate {
    /// 上一次贴提供商时是哪一首（"每换一首歌允许再报一次"用，见 `applyProviderToArtistLine`）。
    static var loggedArtistProviderTrack = ""

    /// 把歌手那一行还原成纯歌手名（**离开页面 / 关开关** —— 不再跟着"收起歌词"走）。
    ///
    /// （用户：图片里 `（NetEase）` 被截断）：现在贴上去的可能是**裁过的**
    /// `歌手…（提供商）`，所以还原不能只摘括号（那样会把截断后的省略号留在 Spotify 的标签上）。
    /// 贴的时候把**完整歌手名**记在 `lastArtistFullBase`，这里优先用它写回。
    static func restoreArtistLine(in page: UIView) {
        guard let suffix = lastArtistSuffix, let label = artistLabel(in: page) else { return }
        let current = effectiveLabelText(label)
        if current.hasSuffix(suffix), !lastArtistFullBase.isEmpty {
            setLabelText(lastArtistFullBase, on: label)
        } else if current.hasSuffix(suffix) {
            setLabelText(String(current.dropLast(suffix.count)), on: label)
        }
        lastArtistSuffix = nil
        lastArtistFullBase = ""
    }

    /// 上一次贴之前那一行的**完整**歌手名（可能是 `"A, B, C"`）—— 与上面还原那段一起用。
    static var lastArtistFullBase = ""

    /// 上一次贴之前那一行的原文（用来分辨"换歌"与"被 binder 写回"，只给日志用）。
    static var lastArtistBase = ""

    /// 歌手那一行到底是哪一个 `UILabel`。判据**从硬到软**三条：
    ///
    /// ① **id**：`now-playing-subtitle-label`（Spotify 不是每份树都给它这个 id，不能只靠它）；
    /// ② **按文本认** —— 页面里那个写着**当前歌手名**的标签（歌手名从曲目元数据取）。**确定性**判据；
    /// ③ 位置兜底：标题那一行里、标题**正下方**、且与标题左边缘对齐的标签。
    ///
    /// ⚠️ **位置兜底会误中**一个 `text = "直播"` 的徽章 —— 提供商被贴到 LIVE 徽章上，的仍然是
    /// "提供商没写在歌手后面"（而且我们还改坏了别人的一个标签）⇒ ①② 必须先走。
    /// ⚠️ 三条判据都改用 `effectiveLabelText`：Spotify 的标签**未必把文字放在 `text` 里**
    /// （`attributedText` 是常态）—— 只认 `text` 会把真正的歌手行**整行跳过**，于是兜底才轮得到那个徽章。
    static func artistLabel(in page: UIView) -> UILabel? {
        let list = findByIdentifier(listIdentifier, in: page)
        let byId = (list.flatMap { findByIdentifier(subtitleLabelIdentifier, in: $0) })
            ?? findByIdentifier(subtitleLabelIdentifier, in: page)
        if let label = byId as? UILabel, !effectiveLabelText(label).isEmpty { return label }

        let titleLabel = (list.flatMap { findByIdentifier(titleLabelIdentifier, in: $0) })
            ?? findByIdentifier(titleLabelIdentifier, in: page)
        let titleFrame = titleLabel.map { untransformed($0, in: page) }
        let candidates = textLabels(in: page)

        // ② 按歌手名认（包含即可：Spotify 可能写成 "A, B" 而我们拿到的是主艺人）。
        let artist = currentArtistName()
        if !artist.isEmpty {
            let matched = candidates.filter { candidate in
                guard candidate.label !== titleLabel else { return false }
                let text = effectiveLabelText(candidate.label)
                return text.range(of: artist, options: .caseInsensitive) != nil
            }
            if let best = nearestBelow(matched, to: titleFrame) {
                if !didLogArtistLabelByText {
                    didLogArtistLabelByText = true
                    writeDebugLog(
                        "[\(logTag)] the artist line was found by its text — class "
                            + "\(NSStringFromClass(type(of: best)))"
                    )
                }
                return best
            }
        }

        // ③ 位置兜底：标题**正下方** + 左边缘对齐（比旧判据严一档：旧判据只要求"水平有重叠"，
        // 徽章也能满足）。三条都要过 `effectiveLabelText`。
        if let titleFrame {
            let positional = candidates.filter { candidate in
                guard candidate.label !== titleLabel else { return false }
                return candidate.frame.minY >= titleFrame.maxY - 2
                    && abs(candidate.frame.minX - titleFrame.minX) <= 12
            }
            if let best = nearestBelow(positional, to: titleFrame) {
                if !didLogArtistLabelFallback {
                    didLogArtistLabelFallback = true
                    writeDebugLog(
                        "[\(logTag)] the artist line was found by position, not by id — class "
                            + "\(NSStringFromClass(type(of: best)))"
                    )
                }
                return best
            }
        }

        // ④ 三条都不中：把**候选原样打进日志**（只打一次）。
        // 上一轮就是因为只有一句"找不到"，下一轮仍然只能猜 —— 这次让日志自己说出页面里有什么。
        if !didLogArtistLabelMissing {
            didLogArtistLabelMissing = true
            let dump = candidates.prefix(8).map { candidate -> String in
                let text = effectiveLabelText(candidate.label)
                let shown = text.count > 24 ? String(text.prefix(24)) + "..." : text
                let className = NSStringFromClass(type(of: candidate.label))
                return "\(className) [\(shown)] \(frameText(candidate.frame))"
            }.joined(separator: " | ")
            writeDebugLog("[\(logTag)] cannot find the artist line — candidates: \(dump)")
        }
        return nil
    }

    static var didLogArtistLabelMissing = false
    static var didLogArtistLabelFallback = false
    static var didLogArtistLabelByText = false

    /// 标签的**有效文本**：`text` 为空就看 `attributedText`。
    ///
    /// 写入 —— 旧判据只认 `text`，于是**真正的歌手行被整行跳过**，位置兜底才挑中了
    /// 一个 `text = "直播"` 的徽章。凡是要读标签文字的地方都走这一个口径。
    static func effectiveLabelText(_ label: UILabel) -> String {
        let plain = label.text ?? ""
        if !plain.isEmpty { return plain }
        return label.attributedText?.string ?? ""
    }

    /// 当前这首的**歌手名**（页面上的歌手那一行就该写着它）。
    ///
    /// 口径与仓库另外两处一致（`LyricsWordByWord` 的壳 `:897`、`AppleMusicLyricsOverlay` 的页头 `:671`）：
    /// 9.1.x 上要 `artistName`，老版本只有 `artistTitle`（见 `SPTPlayerTrack+Extension` 的说明）。
    static func currentArtistName() -> String {
        let track = statefulPlayer?.currentTrack() ?? nowPlayingScrollViewController?.loadedTrack
        let name = EeveeSpotify.hookTarget == .lastAvailableiOS14
            ? track?.artistTitle()
            : track?.artistName()
        return (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 标题那一行里所有"**有文字**的 `UILabel`"（含标题自己），带它们在页面坐标里的 frame。
    ///
    /// 起点**逐级放宽**：标题元素 → 标题行 → 整页；哪一级找到就不往下找（越近的越可能是它）。
    /// 走查有界（每级 64 个节点）。**只看有效文本非空的**（见 `effectiveLabelText`）。
    static func textLabels(in page: UIView) -> [(label: UILabel, frame: CGRect)] {
        let list = findByIdentifier(listIdentifier, in: page)
        let titleLabel = (list.flatMap { findByIdentifier(titleLabelIdentifier, in: $0) })
            ?? findByIdentifier(titleLabelIdentifier, in: page)

        var roots: [UIView] = []
        if let element = titleLabel?.superview { roots.append(element) }
        if let row = titleLabel?.superview?.superview { roots.append(row) }
        roots.append(page)

        var found: [(label: UILabel, frame: CGRect)] = []
        for root in roots {
            var visited = 0
            var queue: [UIView] = [root]
            while !queue.isEmpty, visited < 64 {
                let view = queue.removeFirst()
                visited += 1
                queue.append(contentsOf: view.subviews)
                guard !view.isHidden, view.alpha > 0.01, view.bounds.height > 1 else { continue }
                guard let label = view as? UILabel else { continue }
                guard !effectiveLabelText(label).isEmpty else { continue }
                if found.contains(where: { $0.label === label }) { continue }
                found.append((label, untransformed(view, in: page)))
            }
            if !found.isEmpty { break }
        }
        return found
    }

    /// 在候选里挑"**在标题下方、离标题最近**"的那个；没有标题 frame 就取第一个。
    static func nearestBelow(
        _ candidates: [(label: UILabel, frame: CGRect)],
        to titleFrame: CGRect?
    ) -> UILabel? {
        guard let titleFrame else { return candidates.first?.label }
        let below = candidates.filter { $0.frame.minY >= titleFrame.maxY - 2 }
        return below.min { $0.frame.minY < $1.frame.minY }?.label ?? candidates.first?.label
    }

    /// `"歌手（提供商）"` 里那一段后缀；提供商为空 ⇒ `nil`（那就什么都不写，保持 Spotify 原样）。
    static func providerSuffix() -> String? {
        let provider = currentLyricsProvider.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !provider.isEmpty else { return nil }
        return "（\(provider)）"
    }

    // MARK: - 让「（提供商）」永远看得见
    //
    // 这一行**实际能被看到**的宽度（page 坐标）。
    //
    // 三道取更窄的：
    // · 歌手标签自己的 `bounds.width`；
    // · 标签右边缘到**页面**右边（展开态整行右移 74pt 后，标签右边缘经常正好贴着屏幕边，
    // 照片里 `（NetEas` 就断在那里）；
    // · 祖先里**开了 `clipsToBounds`** 的右边缘（标题行的 cell 可能比屏幕还窄一截）。
    //
    // ⚠️ 这里用 `convert`（带全部祖先 transform）而不是 `untransformed` —— 后者会把标题行
    // 那 74pt 的平移**减掉**，量出来的是"没右移时"的宽度，反而会把提供商裁得更短。
    static func visibleArtistLineWidth(_ label: UILabel, in page: UIView) -> CGFloat {
        let frame = label.convert(label.bounds, to: page)
        var widths: [CGFloat] = []

        // （用户：长名字"感觉没滚动完"）：歌手那一行是 Spotify 的
        // **`MarqueeLabel`**（dump 里 `MarqueeLabel@0,24,308,22,id=now-playing-subtitle-label`），
        // 我们拼上「（提供商）」后一旦比它的**视口宽**（308pt），它就开始 marquee 滚动 ——
        // 长名字看起来就是"滚到一半停住 / 被切掉"。所以对 MarqueeLabel **必须**用
        // `bounds.width`（那是视口宽），而且写进去的文本要严格落在它里面。
        // 自撑开的普通 `UILabel` 才用页边/祖先那一路（它的 bounds 是文本的结果，不是约束）。
        let isMarquee = NSStringFromClass(type(of: label)).contains("Marquee")
        let intrinsic = label.intrinsicContentSize.width
        let selfSizing = !isMarquee && intrinsic > 1 && abs(label.bounds.width - intrinsic) <= 1.5
        if !selfSizing, label.bounds.width > 1 { widths.append(label.bounds.width) }

        let byPage = page.bounds.width - frame.minX
        if byPage > 1 { widths.append(byPage) }

        var node = label.superview
        var hops = 0
        while let current = node, hops < 24 {
            if current.clipsToBounds {
                let ancestor = current.convert(current.bounds, to: page)
                let byAncestor = ancestor.maxX - frame.minX
                if byAncestor > 1 { widths.append(byAncestor) }
            }
            if current === page { break }
            node = current.superview
            hops += 1
        }
        return widths.min() ?? 0
    }

    /// 这一行用什么字体量（Spotify 多半把字放在 `attributedText` 里）。
    static func artistLineFont(_ label: UILabel) -> UIFont {
        if let attributed = label.attributedText, attributed.length > 0,
           let font = attributed.attribute(.font, at: 0, effectiveRange: nil) as? UIFont {
            return font
        }
        return label.font ?? UIFont.systemFont(ofSize: 13)
    }

    /// `歌手（提供商）`，**先保证提供商完整**：放不下就从歌手名尾部裁、加省略号。
    ///
    /// （用户：图片里 `日のメゾンデ, 礼衣, 大漠波新 （NetEas` 被截断）：
    /// 以前只是把后缀拼到歌手名后面，Spotify 的标签按它自己的宽度从尾部截 ⇒ 被截掉的
    /// 恰恰是**我们新加的提供商**（信息量最大的那一段）。现在按可见宽度量一遍：
    /// 放不下就把歌手名缩短到能容下 `…（提供商）`。
    ///
    /// （：歌手名被慢慢吃光，最后只剩 `（NetEase）`）：**歌手名优先** ——
    /// 当连"…（提供商）"都放不下时，返回**完整歌手名**（放弃提供商），不再把整条换成提供商。
    ///
    /// 宽度量不到（首帧 / 标签还没布局）⇒ 原样返回，下一拍（0.3s）会再量。
    static func fittedArtistLine(
        base: String,
        suffix: String,
        maxWidth: CGFloat,
        label: UILabel
    ) -> String {
        let full = base + suffix
        guard maxWidth > 1 else { return full }

        let attributes: [NSAttributedString.Key: Any] = [.font: artistLineFont(label)]
        func width(_ text: String) -> CGFloat {
            (text as NSString).size(withAttributes: attributes).width
        }

        // 留 4pt：UILabel 自己还会做一次舍入/字距，量到"刚好等于宽度"时仍可能把最后一个字裁掉；
        // MarqueeLabel 更敏感 —— 只要比视口宽一点点，它就开始滚动（的"没滚动完"）。
        let limit = maxWidth - 4
        if width(full) <= limit { return full }

        let ellipsis = "…"
        let suffixWidth = width(suffix)
        let ellipsisWidth = width(ellipsis)
        let allowed = limit - suffixWidth - ellipsisWidth
        // （：最后只剩 `（NetEase）`）：**连"…（提供商）"都放不下时不再
        // 只剩提供商** —— 那等于把歌手名整条抹掉，比"提供商被截断"更糟。这里直接放弃提供商、
        // 把**完整歌手名**交回去（Spotify 若还是放不下，它自己按它的宽度截尾，至少名字在）。
        guard allowed > 1 else { return base }

        if width(base) <= allowed { return base + ellipsis + suffix }

        var trimmed = base
        while !trimmed.isEmpty {
            trimmed = String(trimmed.dropLast())
            if width(trimmed) <= allowed {
                return trimmed + ellipsis + suffix
            }
        }
        // 连一个字都放不下 ⇒ 同上：歌手名优先。
        return base
    }

    /// 这一次"因为放不下而缩短了歌手名"——每首只报一行，避免 0.3s 节拍刷屏。
    static var loggedArtistTruncationTrack = ""

    /// 这一行**可用宽度**的缓存（`applyProviderToArtistLine` 用）。key = 曲目 | 展开状态 | 标签对象。
    ///
    /// **必须缓存**。每拍重新量会把"我们自己写短之后变窄的标签"当成新的上限 ⇒
    /// 越量越小（的"慢慢往左吞"）。只在"换曲目 / 换展开状态 / 换标签 / 文本被 binder
    /// 写回原样"这四种情况下重算。
    static var artistFitWidthKey = ""
    static var artistFitWidth: CGFloat = 0

    /// 改 Spotify 标签的文本时**保住它自己的字体/颜色**：有 `attributedText` 就在它上面改，
    /// 没有才退回 `text`（直接写 `text` 会把 Spotify 设的属性字符串整段丢掉）。
    static func setLabelText(_ text: String, on label: UILabel) {
        if let attributed = label.attributedText, attributed.length > 0 {
            let mutable = NSMutableAttributedString(attributedString: attributed)
            mutable.replaceCharacters(
                in: NSRange(location: 0, length: mutable.length),
                with: text
            )
            label.attributedText = mutable
        } else {
            label.text = text
        }
    }

    /// 把我们写给标题行 / 标题元素的那两段位移撤掉（关开关 / 离开页面）。
    static func clearClosedTitleTransform() {
        if let row = closedTitleRow, row.transform != .identity { row.transform = .identity }
        if let element = closedTitleElement, element.transform != .identity {
            element.transform = .identity
        }
        closedTitleRow = nil
        closedTitleElement = nil
        didLogClosedTitleMissing = false
        didLogClosedTitle = false
    }

    /// 页里**看得见、而且在屏上**的那一份分享键。
    ///
    /// ⚠️ 不能用 `findByIdentifier`：它返回 BFS 里**第一份**，而页里有**两份**分享键（一份 `alpha=0.50`、
    /// 一份全亮）⇒ 位移会写在一份看不见（或不在屏上）的按钮上，屏幕上一点变化都没有，而日志还会说"成了"。
    ///
    /// 走查**起点从小到大**（同 `progressUnitTop` 的思路；整页 BFS 会被列表里那些格子吃掉预算）：
    /// ① `npv.bottomStackView`（分享键的家 —— 底部那一坨的 footer 行）；② `SPTNowPlayingView`；③ `page`。
    static func visibleShareButton(in page: UIView) -> UIView? {
        if let cached = bandShareButton,
           cached.window != nil,
           !cached.isHidden,
           cached.alpha > 0.01,
           cached.isDescendant(of: page) {
            return cached
        }

        var roots: [UIView] = []
        if let stack = findByIdentifier(bottomStackIdentifier, in: page) { roots.append(stack) }
        if let player = findByIdentifier(nowPlayingViewIdentifier, in: page) { roots.append(player) }
        roots.append(page)

        for root in roots {
            if let found = firstVisibleShareButton(in: root, page: page) { return found }
        }
        return nil
    }

    /// 一趟有界 BFS：按 **id + 看得见 + 在屏上** 挑分享键（判据风格与 `firstVisibleCover` 一致）。
    static func firstVisibleShareButton(in root: UIView, page: UIView) -> UIView? {
        var visited = 0
        var queue: [UIView] = [root]

        while !queue.isEmpty, visited < maxNodes {
            let view = queue.removeFirst()
            visited += 1

            if view.accessibilityIdentifier == shareButtonIdentifier,
               !view.isHidden,
               view.alpha > 0.01,
               view.window != nil,
               view.bounds.width >= 1,
               view.bounds.height >= 1,
               isOnScreen(view, in: page) {
                return view
            }
            // hidden 的子树不往下走。
            if view.isHidden { continue }
            queue.append(contentsOf: view.subviews)
        }
        return nil
    }

    /// 这一份是不是**真的在屏上**。那颗分享键在 815pt 那一排；
    /// "另外那一份"（`alpha=0.50`）通常在别的卡里 / 被折起来了 ⇒ 用它把那一份筛掉。
    static func isOnScreen(_ view: UIView, in page: UIView) -> Bool {
        let frame = untransformed(view, in: page)
        return frame.width >= 1
            && frame.height >= 1
            && frame.midY > 0
            && frame.midY < page.bounds.height
            && frame.intersects(page.bounds)
    }

    /// 搬进控件条之后的一行注脚：**会不会被裁** / **点不点得到**（只报，**不自动改**）。
    ///
    /// 三条判据都从"落点还在不在祖先的框里"推出来：有祖先 `clipsToBounds` 且框装不下落点 ⇒ 屏幕上可能
    /// **缺一块**（不自动清：清掉别人的裁剪可能把别的被裁内容一起放出来，那是更大的破坏）；
    /// **我们自己那个歌词容器**在它前面（铺满歌词区）⇒ 触摸会被我们先吃掉（比父视图边界更容易忘）；
    /// 有祖先（**没开裁剪也一样**）框装不下落点 ⇒ hit-test 在那一层就断了。
    static func bandNote(for view: UIView, landing: CGRect, page: UIView) -> String {
        var node = view.superview
        var hops = 0
        var clipper: String?
        var blocker: String?

        while let current = node, hops < 32 {
            if current.bounds.width > 1, current.bounds.height > 1,
               !untransformed(current, in: page).contains(landing) {
                if blocker == nil { blocker = NSStringFromClass(type(of: current)) }
                if current.clipsToBounds, clipper == nil {
                    clipper = NSStringFromClass(type(of: current))
                }
            }
            if current === page { break }
            node = current.superview
            hops += 1
        }

        if let clipper {
            return " — WARNING: \(clipper) clips to bounds and does not contain the landing spot,"
                + " so it may be cut off"
        }
        if let container = lastContainer, container.window != nil,
           container.convert(container.bounds, to: page).contains(landing) {
            return " (visual only: our own lyrics container is in front of it, so taps stay dead)"
        }
        if let blocker {
            return " (visual only: \(blocker) does not contain the landing spot, so taps stay dead)"
        }
        return " (inside every ancestor — it should still take taps)"
    }
}
