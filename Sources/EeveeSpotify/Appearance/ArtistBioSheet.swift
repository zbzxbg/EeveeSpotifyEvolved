import Foundation
import UIKit

/// 艺人简介卡片：点 `i` 打开我们自己的这一张，不再显示 Spotify 原本那块「关于艺人」。
///
/// ## 正文从哪来（为什么不自己联网取）
///
/// 从 **Spotify 自己那个 `SPTArtistAboutBiographyView`** 里读（`eeveeLongestText`，见
/// `EntityPageHeader.swift`）—— 不引入新接口、不碰 token，读到的就是官方那份（也就是跟着 app 语言走的）
/// 文案 ✓。列表里那一段同时被折成 0 高（`EntityPageSectionDrop.aboutArtistFragment`），页面上不留重复 ✓。
///
/// ⚠️ 正文是**懒加载**的：页面刚打开时那一块还没建出来 ⇒ 点击 `i` 先"扫一遍列表"把它逼出来
/// （`eeveeMaterialiseBio`），**在同一个主线程回合里读走文字**（cell 一旦被回收就没了）。
///
/// ## 形态
///
/// 照 AM：底部一张卡片（顶部圆角、深色、可滚动），标题是艺人名，右上角一颗 ×，点背景也能关。
/// 读不到正文时不留白 —— 写一句话说明，并把"读了几个字"打进日志（下一份日志就能判断是不是被截断了）。
final class ArtistBioSheet: UIView {

    private static weak var current: ArtistBioSheet?

    private let card = UIView()
    private let titleLabel = UILabel()
    private let bodyView = UITextView()
    /// 来源署名（只有走 Genius 那条兜底时才显示 —— 它的条款要求署名）。
    private let creditLabel = UILabel()
    /// 那一颗 Wikipedia 链接的地址（`build` 里按 app 语言算好）。
    private var wikiURL: URL?
    /// 这一张卡片的艺人名（社交链接那颗胶囊在控件被回收时要用它拼兜底链接）。
    private var artistName = ""
    /// 从"关于艺人"那块卡里收下来的**社交链接控件**（见 `EntityPageHeaderManager.cachedBioLinks`）。
    private var linkRefs: [ArtistBioLinkRef] = []
    /// **已经真的显示了正文**吗（占位那句不算）—— 只给"原生正文晚一拍到了"那条补看用，
    /// 免得把已经取到的 Genius / 维基正文又盖掉。
    private var hasBody = false
    /// 卡片**静止时**的 y（下滑关闭时用它回弹 / 判"滑够了没有"）。
    private var cardRestY: CGFloat = 0

    /// 弹一张（同时只留一张：连点两次不会叠）。
    static func present(name: String, text: String?, colour: UIColor?) {
        guard let window = EntityPageAppearance.frontWindow() else { return }
        dismissCurrent()

        let sheet = ArtistBioSheet(frame: window.bounds)
        sheet.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        sheet.build(name: name, text: text, colour: colour)
        current = sheet

        // （翻译这东西**之前还是能用的**——说得对，这是我们的回归）：
        //
        // 原来是 `window.addSubview(sheet)`：卡片**裸挂在 window 上**，从正文往上的
        // responder chain 是 `UITextView → card → sheet → UIWindow → UIApplication`，
        // **一个 VC 都没有**。系统的编辑菜单里那项「翻译」要找一个 VC 来呈现它自己那张卡，
        // 找不到就让 UIKit 在 `-[UITextInputController _translate:]` 里 NSAssert ⇒ SIGABRT
        // （`Spotify--094701.ips`）。
        //
        // 什么时候坏的：`fd693c8`「our own artist bio sheet」把 Spotify 原生的
        // 「关于艺人」换成了这张卡 —— 原生那一页**在 VC 里**，所以翻译一直是好的；
        // 换成我们这张之后才崩。不是系统 bug，是宿主方式不对。
        //
        // ⇒ 现在把它放进一个真正的 `UIViewController` 里再 present（`.overFullScreen`，
        // 铺满整屏、背后的页面照常可见）。翻译因此恢复；万一拿不到 VC，
        // 退回老办法 —— 卡片至少能出来（那种情况下翻译仍然拦着，见 `_translate:` 那条 hook）。
        if let presenter = hostController(for: window) {
            let host = ArtistBioSheetHost()
            host.view.backgroundColor = .clear
            host.modalPresentationStyle = .overFullScreen
            host.modalTransitionStyle = .crossDissolve
            host.loadViewIfNeeded()
            host.view.frame = window.bounds
            sheet.frame = host.view.bounds
            host.view.addSubview(sheet)
            presenter.present(host, animated: false)
            currentHost = host
        } else {
            window.addSubview(sheet)
            writeDebugLog(
                "[ArtistBio] no view controller to host the sheet — fell back to the window"
                    + " (system Translate stays suppressed there)"
            )
        }

        sheet.alpha = 0
        UIView.animate(withDuration: 0.2) { sheet.alpha = 1 }
        // 这里原来还有一条"sheet presented + name/source/biography"的日志 ——
        // 它与 `build` 里那条**完全重复**（`build` 就在上面一行被调用），已删。
        // 现在那一行的内容更全：来源、**走哪条分支**、原生读到几个字，都在 `build` 里打。
    }

    /// 承载简介卡的那个 VC（只在 `present` 期间存在）。
    private static weak var currentHost: UIViewController?

    /// 简介卡的宿主：**空壳 VC**，存在的唯一理由就是给正文那个 `UITextView` 一个 VC 祖先。
    ///
    /// 不覆盖 `preferredStatusBarStyle` / `modalPresentationCapturesStatusBarAppearance`：
    /// 让**下面那一页**继续管状态栏，观感与"裸挂 window"时完全一致。
    private final class ArtistBioSheetHost: UIViewController {
        override func loadView() {
            let view = UIView()
            view.backgroundColor = .clear
            self.view = view
        }
    }

    /// 从窗口根 VC 往下找**最上面**那个（已经 present 出来的优先）。
    private static func hostController(for window: UIWindow) -> UIViewController? {
        guard var presenter = window.rootViewController else { return nil }
        while let presented = presenter.presentedViewController, !presented.isBeingDismissed {
            presenter = presented
        }
        // 没上屏的 VC 上 present 会静默失败 —— 那就别用这条路。
        guard presenter.isViewLoaded, presenter.view.window != nil else { return nil }
        return presenter
    }

    static func dismissCurrent() {
        current?.removeFromSuperview()
        current = nil
        // 卡现在住在 `ArtistBioSheetHost` 里 —— 只把视图摘掉会留下一个
        // **透明的空 VC 盖在最上面**（背后的页面就点不动了），所以要把宿主一起 dismiss。
        guard let host = currentHost else { return }
        currentHost = nil
        if host.presentingViewController != nil { host.dismiss(animated: false) }
    }

    // 这个视图往上有没有 `UIViewController`。
    //
    // （用户：`Spotify--094701.ips`）：
    // 崩溃栈是 `-[UIEditMenuListView _selectItemAtIndexPath:]` → `UICommand perform…`
    // → `-[UITextView _translate:]` → `-[UITextInputController _translate:]` → **NSAssert** → SIGABRT。
    // 也就是：在正文里选中一段字 → 编辑菜单点「翻译」→ 系统那条路自己断言失败。
    //
    // 我们这张卡是**直接挂在 window 上**的（`present` 里 `window.addSubview(sheet)`）——
    // 从正文往上的 responder chain 是 `UITextView → card → sheet → UIWindow → UIApplication`，
    // **一个 VC 都没有**，而系统的翻译要找一个 VC 去呈现它那张卡片。
    // ⇒ 这个判据就是那条 hook 的闸门：**只有"没有 VC 祖先"的文本框才拦**。
    static func hasViewControllerAncestor(_ view: UIView) -> Bool {
        var responder: UIResponder? = view
        var hops = 0
        while let current = responder, hops < 60 {
            hops += 1
            if current is UIViewController { return true }
            responder = current.next
        }
        return false
    }

    /// 这个视图是不是我们这张卡里的（日志归因用）。
    static func isInsideSheet(_ view: UIView) -> Bool {
        var node: UIView? = view
        while let current = node {
            if current is ArtistBioSheet { return true }
            node = current.superview
        }
        return false
    }

    private static var didReportForwardedTranslate = false

    /// 放行一次「翻译」时记一行 —— **只在我们这张卡上记**。
    ///
    /// 判据用途：卡现在有了宿主 VC，翻译应该恢复。如果**记了这行之后仍然崩**，
    /// 那份 `.ips` 就证明了"不是 VC 的问题"，下一个方向才是断言正文。
    static func reportForwardedTranslate(_ view: UIView) {
        guard !didReportForwardedTranslate, isInsideSheet(view) else { return }
        didReportForwardedTranslate = true
        writeDebugLog(
            "[ArtistBio] Translate forwarded to UIKit from the bio sheet"
                + " (it now has a host view controller) — if the app still crashes here,"
                + " the missing view controller was not the cause"
        )
    }

    private static var didReportSuppressedTranslate = false

    /// 拦下一次「翻译」只报一行 —— 顺带把**是哪个文本框、挂在谁身上**记下来。
    ///
    /// 这一行是**归因**用的。就等于确认
    /// "崩溃的是我们这张卡"；看到别的类名，就说明还有第二个文本框在踩同一个断言。
    static func reportSuppressedTranslate(_ view: UIView) {
        guard !didReportSuppressedTranslate else { return }
        didReportSuppressedTranslate = true
        var chain: [String] = []
        var node: UIView? = view
        var level = 0
        while let current = node, level < 5 {
            chain.append(NSStringFromClass(type(of: current)))
            node = current.superview
            level += 1
        }
        writeDebugLog(
            "[ArtistBio] suppressed Translate — the sheet is on the window, so it has no view"
                + " controller to present the system translation UI from"
                + " (UIKit asserts in -[UITextInputController _translate:]);"
                + " chain: " + chain.joined(separator: " ← ")
        )
    }

    // MARK: - 搭

    private func build(name: String, text: String?, colour: UIColor?) {
        backgroundColor = UIColor.black.withAlphaComponent(0.45)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(backdropTapped)))

        let height = min(max(240, bounds.height * 0.58), 560)
        card.frame = CGRect(x: 0, y: bounds.height - height, width: bounds.width, height: height)
        card.autoresizingMask = [.flexibleWidth, .flexibleTopMargin]
        // （把艺人页的 `i` 点击后换成**液态玻璃**，并且可下滑关闭）：
        // 卡片底改成**真玻璃**（`GlassCapsule.makeGlassView`：iOS 26 的 `UIGlassEffect`
        // 带折射与边缘高光；拿不到就退 `.systemUltraThinMaterialDark`，见那个工厂的说明），
        // 底下再垫一层**很淡的取色** —— 纯玻璃压在浅色照片上时白字会看不清，
        // 这一层就是给对比度兜底的（原来是**不透明**色块，所以「换成玻璃」才看得出来）。
        card.backgroundColor = Self.cardColour(from: colour).withAlphaComponent(0.28)
        card.layer.cornerRadius = 24
        card.layer.cornerCurve = .continuous
        card.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        card.clipsToBounds = true
        let glass = GlassCapsule.makeGlassView(wantsInteractive: false).view
        glass.frame = card.bounds
        glass.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        card.insertSubview(glass, at: 0)
        addSubview(card)

        cardRestY = card.frame.origin.y
        // 下滑关闭（见 `cardPanned`）：正文那层滚动仍然交给 `bodyView`，
        // 手势**什么时候该让位**由 `gestureRecognizerShouldBegin` 判（正文没滚到顶就不抢）。
        let pan = UIPanGestureRecognizer(target: self, action: #selector(cardPanned))
        pan.delegate = self
        card.addGestureRecognizer(pan)

        titleLabel.text = name
        titleLabel.font = .systemFont(ofSize: 22, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.frame = CGRect(x: 20, y: 18, width: card.bounds.width - 88, height: 28)
        titleLabel.autoresizingMask = [.flexibleWidth]
        card.addSubview(titleLabel)

        let close = UIButton(type: .system)
        close.setImage(UIImage(systemName: "xmark"), for: .normal)
        close.tintColor = UIColor.white.withAlphaComponent(0.85)
        close.frame = CGRect(x: card.bounds.width - 56, y: 12, width: 44, height: 44)
        close.autoresizingMask = [.flexibleLeftMargin]
        close.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        card.addSubview(close)

        let footer: CGFloat = 52
        // 收下来社交链接时，正文上面让出一条 38pt 给那一排胶囊。
        let links = Array(EntityPageHeaderManager.cachedBioLinks(for: name).prefix(3))
        linkRefs = links
        artistName = name
        let linkRow: CGFloat = links.isEmpty ? 0 : 38
        bodyView.frame = CGRect(
            x: 16,
            y: 58,
            width: card.bounds.width - 32,
            height: card.bounds.height - 58 - footer - linkRow
        )
        bodyView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        bodyView.backgroundColor = .clear
        bodyView.isEditable = false
        bodyView.isScrollEnabled = true
        bodyView.showsVerticalScrollIndicator = true
        // （艺人简介这部分**可能会自带社交软件链接**，比如推特、维基百科什么的）：
        // 那段正文是 Spotify 给的原样文本（我们一个字都不改），里面就可能有 URL ——
        // 打开**链接识别**让它可点（点开走系统 Safari）。我们不自己解析、也不重排文字。
        bodyView.isSelectable = true
        bodyView.dataDetectorTypes = [.link]
        bodyView.textContainerInset = UIEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        bodyView.font = .systemFont(ofSize: 17)
        bodyView.textColor = UIColor.white.withAlphaComponent(0.92)
        card.addSubview(bodyView)

        let source = UserDefaults.artistBioSource
        writeDebugLog(
            "[ArtistBio] sheet — name \(name.isEmpty ? "MISSING" : name)"
                + ", source \(source.rawValue) (\(source)), native text "
                + (text.map { "\($0.count) char" } ?? "none")
        )
        switch source {
        case .spotify:
            if let text {
                show(text, credit: "artist_bio_from_spotify".localized)
            } else {
                showFailure("artist_bio_spotify_failed".localized)
                // 原生那份可能只是**还没建出来**（懒加载）⇒ 盯一会儿，抓到就补上。
                watchForNativeText(name)
            }
        case .genius:
            loadGenius(name)
        case .wikipedia:
            loadWikipedia(name)
        case .automatic:
            if let text {
                show(text, credit: "artist_bio_from_spotify".localized)
            } else {
                loadGenius(name)
                // 同上：Genius 在跑，原生那份晚一拍到了就换成它（`.automatic` = 原生优先）。
                watchForNativeText(name)
            }
        }

        // 页脚：左边一颗**维基百科链接**（只给入口、**不抄文本** ⇒ 不欠 CC BY-SA 的署名 ——
        // Spotify 自己的 About 页也是这么干的：`SPTArtistAbout:sArtistWikipediaButtonTitle`，dump:21079），
        // 右边一句**永远显示**的来源署名/状态（以前只有成功时才显示 —— 于是四档
        // 在失败时长得一模一样，用户以为设置没生效）。
        let wiki = UIButton(type: .system)
        // 它一直是个**入口按钮**，
        // 但文案与"来源"混在一起，用户就把它当成了来源标签 ⇒ 换成明确的链接说法。
        wiki.setTitle("artist_bio_open_wikipedia".localized, for: .normal)
        wiki.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
        wiki.setTitleColor(UIColor.white.withAlphaComponent(0.85), for: .normal)
        wiki.frame = CGRect(x: 12, y: card.bounds.height - footer, width: 170, height: 40)
        wiki.autoresizingMask = [.flexibleTopMargin]
        wiki.contentHorizontalAlignment = .left
        wiki.addTarget(self, action: #selector(wikipediaTapped), for: .touchUpInside)
        // **收到过真链接时这颗让位** —— 下面那一排胶囊里就有一张"维基百科"，
        // 再挂一颗"在维基百科中打开"是重复的（而且那颗只是**搜索页**，不是艺人的条目）。
        if !links.isEmpty { wiki.isHidden = true }
        card.addSubview(wiki)
        wikiURL = Self.wikipediaURL(for: name)

        // （原本有的维基 / 推特链接之类的没显示）：把 Spotify 自己那块卡里
        // 的社交链接按钮画成**一排胶囊**，点下去**转发给那些控件本身**（走 Spotify 自己的打开逻辑，
        // 所以是艺人真正的维基条目 / 推特账号，不是我们拼的搜索页）。
        // ⚠️ 控件是 weak 引用：那一格被回收之后点胶囊会走兜底（维基 → 搜索页），
        if !links.isEmpty {
            // ⚠️ 三颗胶囊**可能放不下**：卡宽 414、左边留 12 ⇒ 可用 402pt，而三颗各最多 132pt
            // 再加两道 8pt 间距 = 412pt ⇒ 第三颗会伸出卡片右边（`card.clipsToBounds = true`，
            // 真机上就是半颗被裁掉）。这里按**剩余宽度**夹一次；连 66pt（最短一颗）都放不下
            // 就停 —— 宁可少画一颗，也不画半颗。
            let usableRightEdge = card.bounds.width - 12
            var chipX: CGFloat = 12
            for (index, link) in links.enumerated() {
                let chip = UIButton(type: .system)
                chip.setTitle(link.title, for: .normal)
                chip.titleLabel?.font = .systemFont(ofSize: 14, weight: .medium)
                chip.setTitleColor(UIColor.white.withAlphaComponent(0.95), for: .normal)
                chip.backgroundColor = UIColor.white.withAlphaComponent(0.14)
                chip.layer.cornerRadius = 15
                chip.layer.cornerCurve = .continuous
                chip.tag = index
                chip.addTarget(self, action: #selector(linkTapped(_:)), for: .touchUpInside)
                let textWidth = (link.title as NSString).size(
                    withAttributes: [.font: UIFont.systemFont(ofSize: 14, weight: .medium)]
                ).width
                let chipWidth = min(
                    132,
                    max(66, ceil(textWidth) + 28),
                    usableRightEdge - chipX
                )
                guard chipWidth >= 66 else { break }
                chip.frame = CGRect(
                    x: chipX,
                    y: card.bounds.height - footer - linkRow + 4,
                    width: chipWidth,
                    height: 30
                )
                chip.autoresizingMask = [.flexibleTopMargin]
                card.addSubview(chip)
                chipX += chipWidth + 8
            }
        }

        creditLabel.font = .systemFont(ofSize: 12)
        creditLabel.textColor = UIColor.white.withAlphaComponent(0.55)
        creditLabel.textAlignment = .right
        // 两行 —— 失败原因那句比"来自 Genius"长
        // （"维基百科没有响应（本机网络可能屏蔽了它）"）。
        creditLabel.numberOfLines = 2
        creditLabel.isHidden = true
        creditLabel.frame = CGRect(
            x: card.bounds.width - 198,
            y: card.bounds.height - footer,
            width: 186,
            height: 40
        )
        creditLabel.autoresizingMask = [.flexibleTopMargin, .flexibleLeftMargin]
        card.addSubview(creditLabel)
    }

    @objc private func wikipediaTapped() {
        guard let wikiURL else { return }
        UIApplication.shared.open(wikiURL, options: [:], completionHandler: nil)
        writeDebugLog("[ArtistBio] wikipedia link opened")
    }

    /// **社交链接胶囊**（维基 / 推特 / …）：优先用**读到的真链接**直接打开；
    /// 读不到才转发给从"关于艺人"那块卡里收下来的**原控件**（走 Spotify 自己的打开逻辑）；
    /// 控件也没了（weak 变 nil）才退兜底：维基走搜索页，其余只打日志。
    @objc private func linkTapped(_ sender: UIButton) {
        guard linkRefs.indices.contains(sender.tag) else { return }
        let link = linkRefs[sender.tag]
        if let url = link.url {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
            writeDebugLog("[ArtistBio] link tapped — \(link.kind) → opened \(url.host ?? "-")")
            return
        }
        if let control = link.control {
            let path = eeveeFire(control) ?? "NOTHING (no action, no tap recogniser)"
            writeDebugLog("[ArtistBio] link tapped — \(link.kind) → \(path)")
            return
        }
        if link.kind == "wikipedia", let url = Self.wikipediaURL(for: artistName) {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        }
        writeDebugLog(
            "[ArtistBio] link tapped — \(link.kind) (no URL, no control; opened the fallback)"
        )
    }

    /// 维基百科那条**链接**：用**搜索页**（省掉"先找条目"这一步，同名艺人也不怕），
    /// wiki 主机与取词那条线**共用** `ArtistBioSource.wikipediaHost`（免得两处漂）。
    private static func wikipediaURL(for name: String) -> URL? {
        guard var components = URLComponents(
            string: "https://\(ArtistBioSource.wikipediaHost())/wiki/Special:Search"
        ) else {
            return nil
        }
        components.queryItems = [URLQueryItem(name: "search", value: name)]
        return components.url
    }

    /// 正文 + 底部那行**永远显示**的署名/状态。
    private func show(_ body: String, credit: String) {
        bodyView.text = body
        hasBody = true
        setCredit(credit)
    }

    /// **原生正文晚一拍才抓到时，把这张已经开着的卡片补上**。
    ///
    /// 为什么需要：那张卡是懒加载的（见 `EntityPageHeaderManager.artistBiographyAppeared` 的说明）
    /// —— 用户点 `i` 的**那一刻**它可能还没建出来，
    /// 而几秒之后卡片才露头、正文才被 `captureBioTextOnSight` 读走。
    /// 盯 6 秒（12 × 0.5s）：一拿到就写上去，仍按 `.automatic` 的口径"原生优先"，
    /// **但绝不盖掉已经真的显示出来的正文**（`hasBody`）。
    private func watchForNativeText(_ name: String) {
        guard !name.isEmpty else { return }
        for step in 1...12 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(step) * 0.5) { [weak self] in
                guard let self, self.superview != nil, !self.hasBody else { return }
                guard let text = EntityPageHeaderManager.cachedBioText(for: name) else { return }
                self.show(text, credit: "artist_bio_from_spotify".localized)
            }
        }
    }

    /// 拿不到正文：正文照旧那句说明，但**底部必须说清是哪一档没取到**（以前四种失败长得一样）。
    private func showFailure(_ credit: String) {
        bodyView.text = "artist_bio_empty".localized
        setCredit(credit)
    }

    private func setCredit(_ text: String) {
        creditLabel.text = text
        creditLabel.isHidden = false
    }

    /// Genius 那条（**英文**，卡片上要署名）。
    private func loadGenius(_ name: String) {
        bodyView.text = "artist_bio_empty".localized
        setCredit("artist_bio_loading".localized)
        ArtistBioSource.geniusBio(for: name) { [weak self] bio in
            guard let self else { return }
            guard let bio else {
                self.setCredit("artist_bio_genius_failed".localized)
                return
            }
            self.bodyView.text = bio
            self.hasBody = true
            self.setCredit("artist_bio_from_genius".localized)
        }
    }

    /// 维基百科那条（**CC BY-SA**：要署名 + 给许可链接 —— 页脚那颗 Wikipedia 按钮就是那个链接）。
    private func loadWikipedia(_ name: String) {
        bodyView.text = "artist_bio_empty".localized
        setCredit("artist_bio_loading".localized)
        ArtistBioSource.wikipediaBio(for: name) { [weak self] bio in
            guard let self else { return }
            guard let bio else {
                self.setCredit("artist_bio_wikipedia_failed".localized)
                return
            }
            self.bodyView.text = bio
            self.hasBody = true
            self.setCredit("artist_bio_from_wikipedia".localized)
        }
    }

    /// 卡片底色：跟着这一页的取色走（太暗就抬一点，免得和页面糊成一片）。
    private static func cardColour(from colour: UIColor?) -> UIColor {
        guard let colour else { return UIColor(white: 0.13, alpha: 1) }
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 1
        guard colour.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha) else {
            return UIColor(white: 0.13, alpha: 1)
        }
        return UIColor(
            hue: hue,
            saturation: min(1, saturation * 0.9),
            brightness: max(0.16, min(0.34, brightness * 0.72)),
            alpha: 1
        )
    }

    // MARK: - 关

    @objc private func backdropTapped(_ recognizer: UITapGestureRecognizer) {
        let point = recognizer.location(in: self)
        // 点卡片里面不关（`bodyView` 的滚动、选中都要能用）。
        if card.frame.contains(point) { return }
        dismiss()
    }

    @objc private func closeTapped() {
        dismiss()
    }

    /// **下滑关闭**用户点名要的）。
    ///
    /// 判据照系统 sheet：滑过卡片高度的 30% **或者**放手时向下速度 > 800pt/s 就关，
    /// 否则弹回原位（用弹簧，手感与 `GlassCapsule` 那套一致）。
    /// ⚠️ 正文还在滚的时候**不抢手势** —— 见 `gestureRecognizerShouldBegin`。
    @objc private func cardPanned(_ pan: UIPanGestureRecognizer) {
        let offset = max(0, pan.translation(in: self).y)

        switch pan.state {
        case .changed:
            card.frame.origin.y = cardRestY + offset
            alpha = max(0.35, 1 - offset / max(1, card.bounds.height))
        case .ended, .cancelled, .failed:
            let velocity = pan.velocity(in: self).y
            if offset > card.bounds.height * 0.3 || velocity > 800 {
                dismissFromDrag()
            } else {
                UIView.animate(
                    withDuration: 0.28,
                    delay: 0,
                    usingSpringWithDamping: 0.86,
                    initialSpringVelocity: 0
                ) {
                    self.card.frame.origin.y = self.cardRestY
                    self.alpha = 1
                }
            }
        default:
            break
        }
    }

    private func dismissFromDrag() {
        UIView.animate(
            withDuration: 0.22,
            animations: {
                self.card.frame.origin.y = self.bounds.height
                self.alpha = 0
            },
            completion: { _ in
                self.removeFromSuperview()
                if ArtistBioSheet.current === self { ArtistBioSheet.current = nil }
            }
        )
    }

    private func dismiss() {
        UIView.animate(
            withDuration: 0.18,
            animations: { self.alpha = 0 },
            completion: { _ in
                // 现在卡住在一个宿主 VC 里 —— 只摘视图会留下一个透明的空 VC
                // 盖在最上面（背后页面点不动），所以走 `dismissCurrent` 把宿主一起收。
                if ArtistBioSheet.current === self {
                    ArtistBioSheet.dismissCurrent()
                } else {
                    self.removeFromSuperview()
                }
            }
        )
    }

    /// **下拉关闭那条手势**：只在"下拉卡片"这一种情况下开始，其余全让给正文那层滚动 ——
    /// · 方向必须是**向下**（横向 / 向上都不抢）；
    /// · 手指落在正文里、而正文**还没滚到顶** ⇒ 那是用户在滚正文，不是在下拉卡片。
    ///
    /// 为什么不做"同时识别"：那样拖正文会一边滚一边把卡片往下拽，手感是坏的。
    ///
    /// ⚠️ **必须写在类体里、并且带 `override`**：`gestureRecognizerShouldBegin(_:)` 是 `UIView`
    /// 自己就有的方法（`UIKit.UIView.gestureRecognizerShouldBegin`）。写在 `extension` 里
    /// 既不能加 `override`（Swift 不允许在扩展里重写），不加又会被编译器判成"漏了 override"
    /// ——那次 IPA build 就是这么红的。
    override func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard let pan = gesture as? UIPanGestureRecognizer else { return true }

        let translation = pan.translation(in: self)
        guard translation.y > 0, abs(translation.y) > abs(translation.x) else { return false }

        let point = pan.location(in: card)
        if bodyView.frame.contains(point), bodyView.contentOffset.y > 0 { return false }
        return true
    }
}

/// 下拉关闭那条手势的 delegate —— 协议声明放这儿，**实现写在类体里**
/// （`gestureRecognizerShouldBegin(_:)` 是 `UIView` 的方法，扩展里不能重写，见那里的 ⚠️）。
extension ArtistBioSheet: UIGestureRecognizerDelegate {}

/// 「关于艺人」那块卡里的一条**社交链接**：认出来的是什么（`kind`）、画在胶囊上的短名（`title`）、
/// **从控件/它的 model 上读到的真链接**（`url`，读不到就是 nil），以及**那个控件本身**
/// （weak —— cell 一回收就自动失效，见 `ArtistBioSheet.linkTapped`）。
final class ArtistBioLinkRef {
    let kind: String
    let title: String
    let url: URL?
    weak var control: UIView?

    init(kind: String, title: String, url: URL? = nil, control: UIView?) {
        self.kind = kind
        self.title = title
        self.url = url
        self.control = control
    }
}
