// 「歌词进播放器」——容器 / 页脚署名 / 提示文案 / 节点查找缓存。
// 从 `NowPlayingLyricsPlate.swift` 原样拆出（`NowPlayingLyricsPlate` 的 extension）；
// 形状、动画与硬约束见那个文件的头注。
import Foundation
import SwiftUI
import UIKit
import Orion
import ObjectiveC.runtime

@MainActor
extension NowPlayingLyricsPlate {
    // MARK: - 我们自己的容器

    static func ensureContainer(in page: UIView, frame: CGRect) -> UIView {
        if let existing = objc_getAssociatedObject(page, &containerKey) as? UIView {
            if existing.superview !== page { page.addSubview(existing) }
            if existing.frame != frame { existing.frame = frame }
            // 歌词要能点（点行跳转），但**容器之外不吃触摸**；容器本身只占歌词区。
            existing.isUserInteractionEnabled = true
            existing.isOpaque = false
            applyContainerPassThrough(to: existing, frame: frame)
            page.bringSubviewToFront(existing)
            lastContainer = existing
            return existing
        }

        let container = NowPlayingLyricsContainerView(frame: frame)
        container.backgroundColor = .clear
        // ★★ 2026-10-24：容器是透明层，`isOpaque` 必须显式关掉（默认 true 在 clear 底色上
        //   可能合成出一层暗底 —— 图片 4 那块"残留矩形"的候选之一）。
        container.isOpaque = false
        container.clipsToBounds = true
        container.accessibilityIdentifier = "eevee-npv-lyrics-container"
        container.isAccessibilityElement = false
        applyContainerPassThrough(to: container, frame: frame)
        page.addSubview(container)
        page.bringSubviewToFront(container)
        objc_setAssociatedObject(page, &containerKey, container, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        lastContainer = container
        return container
    }

    // MARK: - 歌词区底沿的署名（Spicy Lyrics 条款 §6）

    /// 署名那一行的高度 / 距控制条上沿的距离 / 与歌词之间留的空隙。
    ///
    /// ★ 2026-10-13（用户）：「把滚动歌词的下部分抬高，确保歌词不会穿过这个上传者什么的」
    ///   —— 这三个数**同时**决定"歌词区底部要抬高多少"（见 `stageBottomReserve`）：
    ///   歌词（连同它自己的底部渐隐带）必须止步在署名**上方** `creditGapAboveLyrics` 处。
    static let creditHeight: CGFloat = 14
    static let creditBottomInset: CGFloat = 3
    static let creditGapAboveLyrics: CGFloat = 8

    /// 署名那一行的**顶边**（页面坐标系）。
    static var creditTop: CGFloat {
        controlBandMidY - controlBandHalfHeight - creditBottomInset - creditHeight
    }

    /// 歌词区底部要为署名让出的高度。stage 本来就比署名低时返回 0 —— **绝不为负**，
    /// 否则容器会被算成负高（小屏 + 大字号时真的可能量到）。
    static func stageBottomReserve(for stage: CGRect) -> CGFloat {
        max(0, stage.maxY - (creditTop - creditGapAboveLyrics))
    }

    /// 歌词区**底沿**那条小字署名：`上传者 X · 制作者 Y`（没有社区署名时是彩蛋
    /// `Thx,Spicy Lyrics!`），**可点**。
    ///
    /// ★ **不重复提供商** —— 提供商在歌手那一行，这一行只承担条款里"可链接的上传者/制作者"
    /// 那半。拼接规则见 `currentLyricsPlateCreditText()`。
    ///
    /// 为什么要有它：Spicy Lyrics 的服务条款把 `/docs/attribution` 定为**条款的一部分**（§6）——
    /// *"Always name the provider… When `source` is `spicy_lyrics`, credit **and link** the
    /// uploader, and the maker… Attribution goes wherever the lyrics are."* 于是三处分工：
    /// **歌手那一行**只放**短名**；**注入 payload 的 `providedBy`** 放**完整纯文本**（原生歌词页 /
    /// 卡片底部那一行，点不动，但位置够）；**这里**放**可点的那一份** —— "link"落在这。
    ///
    /// 位置的两条硬约束：
    /// 1. **必须在控制条上沿之上**（`controlBandMidY − controlBandHalfHeight` ≈ 604）：那一条是 Spotify
    ///    自己的键（收藏 / 分享……），而我们的容器在那一带**放行触摸**（`applyContainerPassThrough`）
    ///    ⇒ 署名若压上去会实心吃掉那些键的点击。贴着 604 往上摆，正好落在歌词区自己的底部渐隐带里。
    /// 2. **跟着歌词一起出现 / 收起**：只在展开态的 `layoutAndMount` 里摆，收起与离页由
    ///    `removeCreditLabel()` 摘掉；没有歌词时署名文本为空 ⇒ 也不会空挂一条。
    static func ensureCreditLabel(in page: UIView, lyricsFrame: CGRect) {
        // 文本由 `currentLyricsPlateCreditText()` 拼（**这一行专用**：只写"上传者/制作者"，
        // 提供商留给歌手那一行；没有社区署名时走那句彩蛋 `Thx,Spicy Lyrics!`，别的源留空
        // ⇒ 这一条整行不出现）。
        // 自绘歌词页页脚用的是 `currentLyricsCreditText()`（**带**提供商，那一页没有歌手行）。
        let credit = currentLyricsPlateCreditText()
        guard !credit.isEmpty else {
            removeCreditLabel()
            return
        }

        let label: UILabel
        if let existing = objc_getAssociatedObject(page, &creditLabelKey) as? UILabel {
            label = existing
            if label.superview !== page { page.addSubview(label) }
        } else {
            let fresh = UILabel()
            fresh.font = .systemFont(ofSize: 11, weight: .regular)
            fresh.textColor = .secondaryLabel
            fresh.numberOfLines = 1
            fresh.lineBreakMode = .byTruncatingMiddle
            fresh.adjustsFontSizeToFitWidth = true
            fresh.minimumScaleFactor = 0.8
            fresh.isUserInteractionEnabled = true
            fresh.accessibilityIdentifier = "eevee-npv-lyrics-credit"
            fresh.addGestureRecognizer(
                UITapGestureRecognizer(
                    target: NowPlayingLyricsCreditTarget.shared,
                    action: #selector(NowPlayingLyricsCreditTarget.tapped)
                )
            )
            page.addSubview(fresh)
            objc_setAssociatedObject(page, &creditLabelKey, fresh, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            lastCreditLabel = fresh
            label = fresh
        }
        lastCreditLabel = label

        if label.text != credit { label.text = credit }
        // 无障碍：有链接就按"链接"播报（与可点这件事保持一致）。
        label.isAccessibilityElement = true
        label.accessibilityLabel = credit
        label.accessibilityTraits = creditLinks().isEmpty ? .staticText : .link

        let height = Self.creditHeight
        let inset: CGFloat = 2
        let bottom = (controlBandMidY - controlBandHalfHeight) - Self.creditBottomInset
        let target = CGRect(
            x: lyricsFrame.minX + inset,
            y: (bottom - height).rounded(),
            width: max(0, lyricsFrame.width - inset * 2),
            height: height
        )
        if label.frame != target { label.frame = target }
        // 后写的赢：容器是在我们之前 `bringSubviewToFront` 的，署名要压在它上面才点得到。
        page.bringSubviewToFront(label)
    }

    static func removeCreditLabel() {
        // ⚠️ 用记下来的那个 `label` 摘，**不查 `lastPage`** —— 离页时 `lastPage` 可能已经换了人，
        //   查它会留下一条挂在上一页上的孤儿署名。
        //
        // ⚠️ 2026-10-17：清关联对象必须**在 `removeFromSuperview()` 之前**。那一下会把
        //   `label.superview` 置成 nil ⇒ 之后 `if let page = label.superview` 永远不成立 ⇒
        //   关联对象一直挂在 page 上，**页面永远强引用那条已经下屏的 label**（把
        //   `lastCreditLabel` 置 nil 也没用，那是另一条弱引用）。
        if let label = lastCreditLabel, let page = label.superview {
            objc_setAssociatedObject(page, &creditLabelKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        lastCreditLabel?.removeFromSuperview()
        lastCreditLabel = nil
    }

    /// 可点的链接（顺序 = 显示顺序）：提供者站点 + 每个带 `url` 的贡献者。
    ///
    /// 条款 §6 原话是 *"Use the `url` on each contributor as the link target"* ——
    /// 所以点开的是**他们自己的页面**，不是我们的。
    static func creditLinks() -> [(title: String, url: URL)] {
        var links: [(title: String, url: URL)] = []
        let provider = currentLyricsProvider.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = currentLyricsProviderURL, !provider.isEmpty {
            links.append((provider, url))
        }
        for contributor in currentLyricsContributors {
            guard let url = contributor.url else { continue }
            links.append((contributor.role.label + " " + contributor.name, url))
        }
        return links
    }

    /// 点那条署名：一个链接就直接开；多个弹一张 Action Sheet（每条链接一个按钮）。
    ///
    /// 为什么不是"整条文字里逐词命中"：那需要把标签拆成多段并做字符级命中测试，
    /// 而这行字只有一两段链接、点一下就能选 —— 不值得为它引一套富文本命中。
    static func openCreditLink(_ sender: UIView?) {
        let links = creditLinks()
        guard !links.isEmpty else {
            writeDebugLog("[\(logTag)] credit tapped but nothing is linkable")
            return
        }
        if links.count == 1 {
            open(links[0].url)
            return
        }

        guard let host = sender?.window?.rootViewController
            ?? lastPage?.window?.rootViewController
            ?? keyWindowRootViewController() else {
            open(links[0].url)
            return
        }
        var top = host
        while let presented = top.presentedViewController { top = presented }

        let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .alert)
        for link in links {
            sheet.addAction(UIAlertAction(title: link.title, style: .default) { _ in
                NowPlayingLyricsPlate.open(link.url)
            })
        }
        sheet.addAction(UIAlertAction(title: "Cancel".uiKitLocalized, style: .cancel))
        top.present(sheet, animated: true)
    }

    /// 既没有 sender、也没有记住的听歌页时，退回**当前 key window** 的根控制器。
    ///
    /// 谁需要这条路：**自绘歌词页页脚的署名**（`AppleMusicLyricsPage.providerFooter`）。
    /// 那一页不是本类型记住的 `lastPage`，所以不补这一步的话，多条链接（提供商 + 两个社区
    /// 贡献者）会**只开出第一条** —— 条款 §6 要的"链接上传者/制作者"就落空了。
    static func keyWindowRootViewController() -> UIViewController? {
        let windows = UIApplication.shared.windows
        return (windows.first(where: { $0.isKeyWindow }) ?? windows.first)?.rootViewController
    }

    static func open(_ url: URL) {
        writeDebugLog("[\(logTag)] opening attribution link \(url.host ?? "?")")
        onMainThreadSync { UIApplication.shared.open(url) }
    }

    /// 把"控件条那一条要放行触摸"告诉容器（见 `NowPlayingLyricsContainerView`）。
    ///
    /// 放行的范围：从 `controlBandMidY − 22`（≈604）起**到底边** —— 收藏键（＋/✓）与搬过去的分享键
    /// 都落在 604…648，而歌词容器的底边原来是 641 ⇒ 那一片必须让开。
    ///
    /// ⚠️ 现在容器底边被 `stageBottomReserve` 抬到 ≈579（署名顶边之上），**已经不再压住那一条**，
    /// 所以这里的值通常是 0；留着它是因为这个函数还有别的调用点：版式变了（进度条量不到、走了
    /// `lyricsBottom` 那条退路）时容器仍可能伸进控制条。
    static func applyContainerPassThrough(to container: UIView, frame: CGRect) {
        guard let plate = container as? NowPlayingLyricsContainerView else { return }
        plate.passThroughBottom = max(0, frame.maxY - (controlBandMidY - controlBandHalfHeight))
    }

    static func applyEdgeFade(to container: UIView) {
        let mask: CAGradientLayer
        if let existing = container.layer.mask as? CAGradientLayer {
            mask = existing
        } else {
            mask = CAGradientLayer()
            mask.colors = [
                UIColor.clear.cgColor,
                UIColor.white.cgColor,
                UIColor.white.cgColor,
                UIColor.clear.cgColor,
            ]
            mask.locations = NowPlayingMetrics.lyricFadeStops
            mask.startPoint = CGPoint(x: 0.5, y: 0)
            mask.endPoint = CGPoint(x: 0.5, y: 1)
            container.layer.mask = mask
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.frame = container.bounds
        CATransaction.commit()
    }

    // MARK: - 宿主与数据

    @available(iOS 26.0, *)
    static func currentHost(for page: UIView) -> NowPlayingLyricsHost? {
        if let existing = host as? NowPlayingLyricsHost, hostPage === page { return existing }
        (host as? NowPlayingLyricsHost)?.detach()
        let fresh = NowPlayingLyricsHost()
        host = fresh
        hostPage = page
        return fresh
    }

    /// 这一首**有没有能画的东西**（行级即可）—— 与 `canShow` 前两道门同一条判据，
    /// 但**不打日志**：那枚歌词键每 0.3s 复查一次都要问它，所以只能是几个 bool 读
    /// （`currentLines()` 会建整个数组，不能放在这条热路径上）。
    static func hasLyricsAvailable() -> Bool {
        // ★ 2026-10-12：**不再**看「更好的逐词歌词」—— 那两颗开关在这一层里的分工见
        //   `isEnabled` 上面那段：这一层画的就是那套渲染，"更好的"只管 Spotify 原生歌词页。
        //   （以前这里一 false，那枚键会被画成灰的，用户会以为"这首没词"。）
        return hasUsableWordLevelData(currentLyricsDto) || hasUsableLineLevelData(currentLyricsDto)
    }

    /// 这一首有没有能画的东西（行级即可 —— 与上一版放宽后的门禁一致）。
    ///
    /// ★ 2026-10-11：**再加一条"有事可说"的路** —— 用户要的是"键随时能按"：
    ///   没词可画时打开，就在歌词的位置写「未找到歌词」/「此歌曲为纯音乐。」/「正在查找歌词…」。
    ///   （以前这里直接 false ⇒ 键看得见、点下去什么都不会发生，用户报的就是这个。）
    static func canShow(for page: UIView) -> Bool {
        if #available(iOS 26.0, *) {} else { return false }
        // ★★ **这里不再要求「更好的逐词歌词」。** 这一层画的就是那套渲染（iOS 26 起），在这一层里
        //   **没有第二种渲染可选** ⇒ 那颗开关不该在这里当闸门：它管的是 Spotify **原生歌词页**用哪套
        //   渲染（`AppleMusicLyricsOverlay` ↔ 旧 `LyricsWordByWord`）。在这里 guard 的后果很具体：
        //   只开「逐词歌词」时**键摆着、点下去这里 false ⇒ 点不动**（而"整层退出"又会让 kumone 那套
        //   版式消失，同样不对）。
        // ★ 用户要求「键随意能按」⇒ 这里**永远为真**：有词就画词，没词就写一句说明（见 `noticeText()`），
        //   画不出来的异常也照样给一句话，绝不留下"点了没反应"的键。
        return true
    }

    /// 打开之后写在歌词**正中间**的那句话。`nil` = 有歌词可画（不写）。
    ///
    /// **选哪一档**全在 `LyricsNoticePolicy`（纯逻辑、有单测、CI 每次 push 都跑）；这里只负责把当前
    /// 数据喂进去、再把那一档翻成中文文案。四种"没词"必须分开说，混档就是用户能看见的误报：
    ///   · 源**明确**说是纯音乐 ⇒ `song_is_instrumental`（不许拿"查无此歌"冒充它）；
    ///   · **有行、但一行时间都没有**、连文本都提不出来 ⇒ `lyrics_no_timeline`；
    ///   · 查完了没有 / 转换异常 ⇒ `lyrics_unavailable`；
    ///   · 还在查 ⇒ `lyrics_looking_up`（调试页那颗彩蛋会把文案换掉）。
    ///
    /// ⚠️ 参数按**短路**的顺序算：`hasLines` 为假时不去碰 `currentLines()` / `currentUntimedLines()`
    /// （那两个会建数组，而 `hasSomethingToShow()` 会走到这里）。
    static func noticeText() -> String? {
        // ★ 2026-10-22：上一首的模型要当成"没有行" —— 否则 `hasLines=true` / `hasDrawableLines=false`
        //   会掉进 `.unavailable`（"未找到歌词"），而实际是这一首的歌词**还没到**。
        let modelIsCurrent = lineModelIsCurrentTrack()
        let dto = modelIsCurrent ? currentLyricsDto : nil
        let lines = dto?.lines ?? []
        let hasLines = !lines.isEmpty
        let notice = LyricsNoticePolicy.notice(
            hasLines: hasLines,
            hasDrawableLines: hasLines && currentLines() != nil,
            isInstrumental: dto?.isInstrumental == true,
            hasAnyTimestamp: hasLines && lines.contains { $0.offsetMs != nil },
            hasUntimedText: hasLines && currentUntimedLines() != nil,
            // 模型还不属于这一首 ⇒ 等同于"还在查"（这一首的词马上就到/正在查）。
            isLookingUp: isLookingUpLyrics || !modelIsCurrent
        )
        guard let notice else { return nil }
        switch notice {
        case .instrumental:
            return "song_is_instrumental".localized
        case .noTimeline:
            return "lyrics_no_timeline".localized
        case .unavailable:
            return "lyrics_unavailable".localized
        case .lookingUp:
            // ★ 2026-10-30（用户）：「删除替换寻找歌词时的占位符这个功能」——
            //   那句「少女祈祷中…」的彩蛋连同调试页开关、UserDefaults 键、l10n 一起删了。
            //   现在这里永远只写标准的「正在查找歌词…」。
            return "lyrics_looking_up".localized
        }
    }

    /// 数据还没到、而且**还在查**（`.idle` / `.loading`）。查完了没有 ⇒ `.failed` / `.found`。
    static var isLookingUpLyrics: Bool {
        switch currentLyricsLookupState {
        case .idle, .loading: return true
        case .failed, .found: return false
        }
    }

    static weak var lastNoticeLabel: UILabel?

    /// 摆 / 撤那句说明。`text == nil` ⇒ 撤掉（有歌词可画了）。
    static func applyNoticeLabel(_ text: String?, in container: UIView) {
        guard let text else {
            lastNoticeLabel?.removeFromSuperview()
            lastNoticeLabel = nil
            return
        }

        let label: UILabel
        if let existing = lastNoticeLabel, existing.superview === container {
            label = existing
        } else {
            lastNoticeLabel?.removeFromSuperview()
            let fresh = UILabel()
            fresh.accessibilityIdentifier = "eevee-npv-lyrics-notice"
            fresh.textAlignment = .center
            fresh.numberOfLines = 0
            fresh.font = .systemFont(ofSize: 17, weight: .medium)
            fresh.textColor = UIColor.white.withAlphaComponent(0.55)
            // 我们自己的一句话，不该抢歌词行的点击（点行跳转仍在 SwiftUI 那一层）。
            fresh.isUserInteractionEnabled = false
            container.addSubview(fresh)
            lastNoticeLabel = fresh
            label = fresh
        }

        if label.text != text { label.text = text }

        // 居中：容器就是"歌词那一块"（日志 55 的 `20,261,374,323`），
        // 用 `sizeThatFits` 量出文字高度再把它摆在中间 —— 直接铺满会变成顶对齐。
        let maxWidth = max(container.bounds.width - 32, 40)
        let size = label.sizeThatFits(CGSize(width: maxWidth, height: .greatestFiniteMagnitude))
        let frame = CGRect(
            x: 16,
            y: ((container.bounds.height - size.height) / 2).rounded(),
            width: maxWidth,
            height: size.height
        )
        if label.frame != frame { label.frame = frame }
        container.bringSubviewToFront(label)
    }

    /// 把"没有时间轴的文本行"包成渲染层吃的 `LyricLine`（时间一律 0、无音节）。
    ///
    /// ★ **复用**就是对的做法：**同一套**渲染层 + `AppleMusicLyricsPage.isStatic` 接管三件事
    /// （不高亮、不跟随、点行不跳）；字号 / 行距 / 左右内边距 / 滚动容器 / 底部 120pt 留白
    /// （正好让最后一行躲开控件条）全部自动一致。
    /// ★ 这一档也**照样带译文与罗马字**，都按**原数组下标**配对（所以入参带下标）；罗马字仍走仓库
    /// 那条既有罗马化管线。
    /// ⚠️ `time: 0` 只是**占位**：`isStatic` 那一档不读它。
    static func staticLines(from items: [(index: Int, text: String)]) -> [LyricLine] {
        let translationLines = currentLyricsDto?.translation?.lines ?? []
        // ⚠️ 走带缓存的 `romanizedContentsForDisplay()`（这个函数也在 0.3s 那条节拍上）。
        let romanizedContents = currentLyricsDto?.romanizedContentsForDisplay() ?? []

        return items.enumerated().map { order, item in
            let translation: String? = item.index < translationLines.count
                ? translationLines[item.index]
                : nil
            let trimmedText = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let romanized = item.index < romanizedContents.count
                ? romanizedContents[item.index].trimmingCharacters(in: .whitespacesAndNewlines)
                : ""

            return LyricLine(
                id: "eevee-static-\(order)",
                time: 0,
                duration: 0,
                timingKind: .lineSynchronized,
                text: item.text,
                syllables: [],
                // 与原文相同 ⇒ 不显示（同 `LyricLinesAdapter.romanization(original:romanized:)`）。
                romanization: (romanized.isEmpty || romanized == trimmedText) ? nil : romanized,
                translation: translation
            )
        }
    }

    /// ★ 2026-10-22：这份行模型**属于当前这一首**吗？
    ///
    /// 与 `AppleMusicLyricsOverlayHost` / `WordByWordHost`
    /// **同一口径**：`currentLyricsDtoTrackId` 与播放器实时曲目 id 都非空、且不相等 ⇒ 外来模型。
    ///
    /// 为什么听歌页这一层需要它：切歌后到新歌词到达之间，`currentLyricsDto` 还挂着**上一首**的行；
    /// 这一层原来直接拿它画（其它两层各有自己的逐帧守卫，这里没有），用户看到的就是
    /// 「当前歌曲显示上一首歌词」。判据只此一份，`currentLines()` / `currentUntimedLines()` 共用。
    static func lineModelIsCurrentTrack() -> Bool {
        let model = currentLyricsDtoTrackId
        let live = currentTrackId() ?? ""
        if !model.isEmpty, !live.isEmpty, model != live { return false }
        return true
    }

    static func currentLines() -> [LyricLine]? {
        guard lineModelIsCurrentTrack() else { return nil }
        let lines = (currentLyricsDto?.toAppleMusicLyricLines()) ?? []
        return lines.isEmpty ? nil : lines
    }

    /// 这一首"**没有时间轴、但有行**"的歌词文本（`nil` = 这一档不适用）。
    ///
    /// 为什么要它：这一档数据明明在（Spotify 自己那张卡列得出全文）⇒ 把文本提出来**静态列出来**
    /// （见 `staticLines(from:)` + `isStatic`），否则用户看到的就是"歌词呢"。
    ///
    /// ⚠️ 只认"**一行时间都没有**"这一档；只要有一行带 `offsetMs`，就交给时间轴那条路
    /// （`LyricLinesAdapter` 会把带时间的挑出来渲染）。
    /// ★ 返回的是 `(原数组下标, 文本)` —— 下标要**一直带着**，因为译文与罗马字都按同一个下标配对
    /// （空行被滤掉之后下标会错位，这正是本函数不返回 `[String]` 的原因）。
    static func currentUntimedLines() -> [(index: Int, text: String)]? {
        guard lineModelIsCurrentTrack() else { return nil }
        guard let dto = currentLyricsDto, !dto.lines.isEmpty else { return nil }
        guard !dto.lines.contains(where: { $0.offsetMs != nil }) else { return nil }
        let items = dto.lines.enumerated().compactMap { index, line -> (index: Int, text: String)? in
            let text = line.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : (index, text)
        }
        return items.isEmpty ? nil : items
    }

    /// 这一首**有没有东西可画**：画歌词 / 画静态歌词 / 写一句话 —— 三占其一。
    ///
    /// ⚠️ 它会建数组（`currentUntimedLines` / `noticeText`），**只能用在"点开的那几拍"**
    /// （重试窗口 ≤5 拍）；每 0.3s 的复查节拍上要用 `hasAnythingToDrawFast()`。
    static func hasSomethingToShow() -> Bool {
        if hasLyricsAvailable() { return true }
        if currentUntimedLines() != nil { return true }
        return noticeText() != nil
    }

    /// 热路径版（**不建数组**，只读几个 bool / 计数）：有没有东西可画。
    ///
    /// ⚠️ 不能在这里调 `noticeText()` / `currentLines()` —— 那是每 0.3s 一次的节拍
    /// （`hasLyricsAvailable()` 上面那段注释记过同一件事）。
    static func hasAnythingToDrawFast() -> Bool {
        if hasLyricsAvailable() { return true }
        if currentLyricsDto?.lines.isEmpty == false { return true }
        switch currentLyricsLookupState {
        case .idle, .loading: return true      // 还在查 ⇒ 键也该是亮的（点了会说明"正在查找"）
        case .failed, .found: return false
        }
    }

    static func currentTrackId() -> String? {
        let id = (statefulPlayer?.currentTrack() ?? nowPlayingScrollViewController?.loadedTrack)?
            .trackIdentifier ?? ""
        return id.isEmpty ? nil : id
    }

    // MARK: - 日志与小工具

    static func noteSkip(_ reason: String) {
        guard lastSkipReason != reason else { return }
        lastSkipReason = reason
        writeDebugLog("[\(logTag)] not expanding (\(reason))")
    }

    /// 「这一层为什么没参与」——一次一页只报一行。
    ///
    /// ★ 2026-10-12：这条现在只剩**一个**原因（「歌词进播放器」关了）。加它是因为
    /// "歌词键不见了"必须能从日志里读出来 —— 本仓库的老规矩：任何静默返回都要留话。
    static var lastEnabledSkipReason = ""

    static func noteDisabledReason() {
        let reason = "'Lyrics in the player' is off"
        guard lastEnabledSkipReason != reason else { return }
        lastEnabledSkipReason = reason
        writeDebugLog("[\(logTag)] our layer is not in play (\(reason))")
    }

    static func frameText(_ frame: CGRect) -> String {
        "\(Int(frame.origin.x)),\(Int(frame.origin.y)),\(Int(frame.width)),\(Int(frame.height))"
    }

    /// 锚点那种"可能量不到"的数值：量不到就说 `not found`，**不编造**。
    static func anchorText(_ value: CGFloat?) -> String {
        guard let value else { return "not found" }
        return "\(Int(value))"
    }

    /// 最近一次 `measure()` 量到的三个锚点（**只给日志用**，避免为了打印再走查一遍）。
    static var lastAnchorText = ""

    /// ★★ **`findByIdentifier` 的结果按"哪个 root + 哪个 id"缓存一次。**
    ///
    /// 为什么值得：那趟 BFS 的预算 `maxNodes = 800`，而一次 `reconcile` / `apply` 里能问三十来次，
    /// 绝大多数问的还是**同一对**（`listIdentifier` / `titleLabelIdentifier` …）；`DeclutterChrome`
    /// 那条 0.3s 节拍于是每拍把同一棵树重走十几遍。这些答案在"这一页 + 这一程"里是稳定的 ——
    /// 页面换了才需要重新认。
    ///
    /// 三条纪律（少一条就会变成"缓存住了一个错答案"）：
    ///   · **只缓存命中**：查不到**不许**缓存 —— 进页面头几拍树上还没有那些元素，缓存一个 nil 会把
    ///     `pendingOpenUntil` 那条"下一拍再试"的整条窗口掐死。
    ///   · 命中也要**验一次还活着**（在窗口里、仍是这个 root 的子孙）—— 换歌 / 重建元素后旧的那个
    ///     已经被摘掉了，这里清掉重查。
    ///   · 换页面 / 收层时 `invalidateNodeLookups()` **整块作废**。
    struct NodeLookupKey: Hashable {
        let root: ObjectIdentifier
        let identifier: String
    }

    /// ⚠️ 两个都是**弱引用**：缓存不该把一棵已经被摘掉的子树钉在内存里
    /// （而且 root 也弱引用之后，`ObjectIdentifier` 地址被复用的情况能被 `root === root` 挡掉）。
    struct NodeLookup {
        weak var root: UIView?
        weak var view: UIView?
    }

    static var nodeLookups: [NodeLookupKey: NodeLookup] = [:]
    /// 上限封死（按 root + id 计，一页也就十来对；满了整块重来，不做 LRU）。
    static let nodeLookupLimit = 64
    /// 这份缓存是**为哪一首歌**认的 —— 换歌就作废（见 `noteTrackForLookups`）。
    static var lookupTrackId = ""

    /// 换歌 ⇒ 缓存作废。
    ///
    /// 光验"还活着"不够：换歌时 Spotify 会**重建**那些元素，而同一个 id 可能**新旧两份同时在树上**
    /// （旧的那一份还没被摘掉）—— 缓存里存的是 BFS 里第一份，那就会一直认到旧的那一份。
    /// 代价只有两次属性读 + 一次字符串比较（`findByIdentifier` 一次 BFS 预算是 800 个节点）。
    static func noteTrackForLookups() {
        let track = currentTrackId() ?? ""
        guard track != lookupTrackId else { return }
        lookupTrackId = track
        invalidateNodeLookups()
    }

    static func invalidateNodeLookups() {
        guard !nodeLookups.isEmpty else { return }
        nodeLookups.removeAll(keepingCapacity: true)
    }

    static func findByIdentifier(_ identifier: String, in root: UIView) -> UIView? {
        let key = NodeLookupKey(root: ObjectIdentifier(root), identifier: identifier)
        if let entry = nodeLookups[key] {
            if let cached = entry.view, let entryRoot = entry.root, entryRoot === root,
               cached.window != nil, cached.isDescendant(of: root) {
                return cached
            }
            nodeLookups[key] = nil
        }

        var visited = 0
        var queue: [UIView] = [root]

        while !queue.isEmpty, visited < maxNodes {
            let view = queue.removeFirst()
            visited += 1
            if view.accessibilityIdentifier == identifier {
                if nodeLookups.count >= nodeLookupLimit { nodeLookups.removeAll(keepingCapacity: true) }
                nodeLookups[key] = NodeLookup(root: root, view: view)
                return view
            }
            queue.append(contentsOf: view.subviews)
        }
        return nil
    }
}
