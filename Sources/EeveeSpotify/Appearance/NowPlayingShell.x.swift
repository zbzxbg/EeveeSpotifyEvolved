import Foundation
import UIKit
import ObjectiveC.runtime

/// 听歌页的「自绘壳」—— 把整页做成我们自己的，而不是往 Spotify 的图层里见缝插针。
///
/// ── 为什么推倒重来（v1 的真机实证）──────────────────────────────────────────
/// v1 (`MusicStyleNowPlaying`) 的做法是：
///   · 背景：`root.layer.insertSublayer(gradient, at: 0)`
///   · 标题：`root.addSubview(stack)`
/// 日志 12/14 的 A/B + 照片 18 证明这条路上限很低：
///   · **背景等于没画** —— 插在最底层的层被 Spotify 自己那两个整屏不透明视图盖住
///     （`UIView@0,0,414,896,bg=<封面色>` 与 `NPVGradientView@0,0,414,896`；开/关两版
///     这些节点逐字相同，说明用户看到的颜色从头到尾是 Spotify 自己染的）；
///   · **标题会被吃掉** —— 原生吸顶头的 `6.UIView@0,0,414,48` 的 alpha 随滚动
///     0.00 → 0.41 → 1.00 → 0.97，那是一个整屏不透明容器，盖上来就没了。
/// 所以 v2 换结构：**整页接管**，壳自己铺底、自己画顶栏，并且**让原生的那一层让位**
/// （而不是去和它抢 z 序）。
///
/// ── 复用而不是重造 ──────────────────────────────────────────────────────────
/// 底下那块「跟封面取色的满屏模糊底」直接复用全屏歌词页那一套
/// （`LyricsBackdropView` + `style = .stage`）。那个类里针对"壳与肉必须落在同一块
/// 背景上"已经踩过一轮坑（`solidStageScrimAlpha` 的注释就是那段历史），
/// 我们照用，不再自己调参。
///
/// ── 三条纪律 ────────────────────────────────────────────────────────────────
///   1. 全程在开关后面，关掉**完全还原**（背景移除、原生吸顶头的原值写回）；
///   2. 幂等：所有施加都先判断再写，重复 layout 不叠加、不改动别人；
///   3. 探测式取值：`SPTPlayerTrack` 的 getter 一律走 `string(ifResponding:)`
///      （手写 protocol 声明 ≠ 实现，2026-10-01 崩过两次）。
enum NowPlayingShell {

    /// 当前活着的壳（一页一个）。weak：页面销毁后自动失效。
    private static weak var current: NowPlayingShellView?

    /// 由 `NowPlayingShellHook` 在每次布局时调用。幂等。
    @MainActor
    static func apply(to root: UIView?) {
        guard let root else { return }

        guard UserDefaults.nowPlayingShellEnabled else {
            remove()
            return
        }

        let shell: NowPlayingShellView
        if let existing = current, existing.superview === root {
            shell = existing
        } else {
            shell?.removeFromSuperview()
            let created = NowPlayingShellView()
            created.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(created)
            NSLayoutConstraint.activate([
                created.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                created.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                created.topAnchor.constraint(equalTo: root.topAnchor),
                created.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            ])
            // 全屏铺满、不裁剪：背景要盖住整页（含状态栏那一条）。
            created.clipsToBounds = false
            current = created
            shell = created
        }

        // 每次布局都要置于最前：Spotify 自己也会在布局里调整层级。
        root.bringSubviewToFront(shell)
        shell.refresh()
    }

    /// 关掉开关时彻底还原。
    @MainActor
    static func remove() {
        guard let shell = current else { return }
        shell.restore()
        shell.removeFromSuperview()
        current = nil
    }

    @MainActor
    static func teardown() {
        remove()
    }
}

// MARK: - 壳本体

/// 听歌页自绘壳。三个开关各自独立：背景 / 自绘顶栏 / 顶栏玻璃。
final class NowPlayingShellView: UIView {

    // MARK: 子视图

    private let backdrop = LyricsBackdropView()
    private let headerGlass = UIVisualEffectView(effect: nil)
    private let headerTint = UIView()
    private let titleLabel = UILabel()
    private let artistLabel = UILabel()
    /// 只用来给标题让出两侧（64 的触控宽度），自己不画任何东西。
    private let titleContainer = UIView()
    private let chevronButton = UIButton(type: .system)

    /// 上一次用于构建背景的 track key + 底色，避免每次 layout 都重建/重绘。
    private var lastBackdropKey: String?
    /// 上一次施加时的尺寸：尺寸没变就不重算约束（约束由 Auto Layout 管，不必手算）。
    private var lastLayoutSize: CGSize = .zero
    /// 原生吸顶头的原值（可撤销）。
    private var nativeTintSnapshots: [(view: UIView, color: UIColor?)] = []
    private var nativeLabelSnapshots: [(label: UILabel, text: String?)] = []

    // MARK: 初始化

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    /// 搭子视图。触摸策略见下面的 `hitTest` —— 壳不接收触摸、只有 ⌄ 例外。
    private func setup() {
        isUserInteractionEnabled = true
        backgroundColor = .clear

        backdrop.style = .stage
        backdrop.solid = true
        backdrop.isBackdropOpaque = true
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backdrop)

        headerGlass.translatesAutoresizingMaskIntoConstraints = false
        headerGlass.isHidden = true
        addSubview(headerGlass)

        headerTint.translatesAutoresizingMaskIntoConstraints = false
        headerTint.backgroundColor = .clear
        addSubview(headerTint)

        // ⌄ 关闭。**必须自绘**：上面那层背景把原生那颗键压住了。
        //
        // ⚠️ 它是个 UIControl，而 `WordByWordPlaybackControl.dismissFullscreen()` 会在
        // 窗口里按**无障碍标签**找"原生收起键" —— 那个函数自带 `isOwnControl` +
        // `isForwardingTap` 双重防重入（历史上自己点自己爆过栈）。所以我们只做两件事：
        // 不给它设 `accessibilityLabel`（不参与标签匹配），动作**只走那个函数**。
        var chevronConfig = UIButton.Configuration.plain()
        chevronConfig.image = UIImage(
            systemName: "chevron.down",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
        )
        chevronButton.configuration = chevronConfig
        chevronButton.tintColor = .white
        chevronButton.translatesAutoresizingMaskIntoConstraints = false
        chevronButton.addTarget(self, action: #selector(onChevron), for: .touchUpInside)
        addSubview(chevronButton)

        titleContainer.translatesAutoresizingMaskIntoConstraints = false
        titleContainer.isUserInteractionEnabled = false
        addSubview(titleContainer)

        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.textAlignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        artistLabel.font = .systemFont(ofSize: 12, weight: .regular)
        artistLabel.textColor = UIColor.white.withAlphaComponent(0.72)
        artistLabel.textAlignment = .center
        artistLabel.lineBreakMode = .byTruncatingTail
        artistLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(titleLabel)
        addSubview(artistLabel)

        activateConstraints()
    }

    // MARK: 布局

    private func activateConstraints() {
        // 背景铺满整屏（含状态栏）——这是"整页取色"能看见的前提。
        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: bottomAnchor),

            // 顶栏：只占**上沿那一条**，高度是"安全区 + 62"（照全屏歌词壳的排版常数）。
            // 不铺满整屏是刻意的：中间与底部必须留给 Spotify 的原生内容。
            headerGlass.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerGlass.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerGlass.topAnchor.constraint(equalTo: topAnchor),
            headerGlass.heightAnchor.constraint(
                equalTo: safeAreaLayoutGuide.topAnchor,
                constant: NowPlayingShellMetrics.headerHeight
            ),

            headerTint.leadingAnchor.constraint(equalTo: headerGlass.leadingAnchor),
            headerTint.trailingAnchor.constraint(equalTo: headerGlass.trailingAnchor),
            headerTint.topAnchor.constraint(equalTo: headerGlass.topAnchor),
            headerTint.bottomAnchor.constraint(equalTo: headerGlass.bottomAnchor),

            // 标题两行：**居中在"⌄ 与 ⋯ 之间"**，而不是居中在整屏。
            //
            // ⚠️ 这里以前用"居中对齐 + 左右 56 的 greaterThanOrEqual"来做，
            // 那在真机上是**冲突的约束**（居中到整屏和左侧留 56 不能同时成立，
            // Auto Layout 只能破一条并打警告）。改成"让容器把两侧留出来"：
            // 容器左右各收 56，标题在容器里居中 —— 既居中又不会撞到两颗键。
            titleLabel.centerXAnchor.constraint(equalTo: titleContainer.centerXAnchor),
            titleLabel.topAnchor.constraint(equalTo: titleContainer.topAnchor),
            titleLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: titleContainer.leadingAnchor
            ),
            titleLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: titleContainer.trailingAnchor
            ),

            titleContainer.topAnchor.constraint(
                equalTo: safeAreaLayoutGuide.topAnchor,
                constant: NowPlayingShellMetrics.titleTopInset
            ),
            titleContainer.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: NowPlayingShellMetrics.titleSideInset
            ),
            titleContainer.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -NowPlayingShellMetrics.titleSideInset
            ),

            artistLabel.centerXAnchor.constraint(equalTo: titleContainer.centerXAnchor),
            artistLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            artistLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: titleContainer.leadingAnchor
            ),
            artistLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: titleContainer.trailingAnchor
            ),
            titleContainer.bottomAnchor.constraint(equalTo: artistLabel.bottomAnchor),

            // ⌄ 与原生那颗键重合（原生键被我们的背景压住，点不到，所以位置照抄）。
            chevronButton.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: NowPlayingShellMetrics.closeLeadingInset
            ),
            chevronButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            chevronButton.widthAnchor.constraint(equalToConstant: NowPlayingShellMetrics.hitTargetSize),
            chevronButton.heightAnchor.constraint(equalToConstant: NowPlayingShellMetrics.hitTargetSize),
        ])
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != lastLayoutSize else { return }
        lastLayoutSize = bounds.size
        // 尺寸变了才重跑一遍"让位"——但它同时是幂等的，Spotify 把底色写回来时
        // 下一个尺寸变化还会再清一次。
        nativeTintYield()
    }

    // MARK: 触摸

    /// 只让**自己的那颗按钮**吃触摸，其余全部放行给下面的 Spotify。
    ///
    /// 不这么写的话：壳铺满整屏 → 它自己（或任何一个能收触摸的子视图）会把整页的
    /// 手势全吃掉，表现就是"看得到、点不动"。
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }

    // MARK: 刷新

    /// 每次布局调用。幂等。
    func refresh() {
        let track = statefulPlayer?.currentTrack()
        let trackKey = track?.trackIdentifier ?? "unknown"

        // ── 背景 ──
        //
        // `LyricsBackdropView` 自己去取封面（`loadArtworkIfNeeded`，带缓存），
        // 我们只负责喂底色 + 决定有没有封面。
        let baseColor = NowPlayingShellColors.baseColor()
        backdrop.configure(
            baseColor: baseColor,
            showsArtwork: UserDefaults.nowPlayingShellBackdrop && track != nil,
            material: true
        )
        backdrop.isHidden = !UserDefaults.nowPlayingShellBackdrop

        // ── 顶栏 ──
        let showsHeader = UserDefaults.nowPlayingShellHeader
        headerGlass.isHidden = !showsHeader
        headerTint.isHidden = !showsHeader
        titleLabel.isHidden = !showsHeader
        artistLabel.isHidden = !showsHeader
        chevronButton.isHidden = !showsHeader

        if showsHeader {
            applyGlass(to: headerGlass)
            applyHeaderTint(baseColor)

            // 探测式取值：`artistTitle()` 在 9.1.86 上不存在（崩过），只调存在的。
            let title = track?.string(ifResponding: "trackTitle")
            let artist = track?.string(ifResponding: "artistName")
            if titleLabel.text != title { titleLabel.text = title }
            if artistLabel.text != artist { artistLabel.text = artist }
        }

        if lastBackdropKey != trackKey {
            lastBackdropKey = trackKey
            writeDebugLog(
                "[Shell] 听歌页壳刷新 — track=\(trackKey)"
                    + " backdrop=\(UserDefaults.nowPlayingShellBackdrop ? "ON" : "OFF")"
                    + " header=\(UserDefaults.nowPlayingShellHeader ? "ON" : "OFF")"
                    + " glass=\(UserDefaults.nowPlayingShellGlass ? "ON" : "OFF")"
            )
        }
    }

    /// 顶栏玻璃。
    ///
    /// ⚠️ 探测式：真 `UIGlassEffect`（iOS 26+）拿得到就用，拿不到退
    /// `.systemUltraThinMaterialDark`（iOS 13+ 就有）——**不写 `#available`**，
    /// 与本仓库既有做法一致（见 `AmoledTheme.x.swift` 的同一套写法）。
    ///
    /// 为什么不自己画"折射感"：那正是系统玻璃与"模糊 + 描边"的差距所在；
    /// 但把它做成**必需**就等于把开关在旧系统上置灰（spoti.pw 就是这么做的，
    /// 它还为此挂了一个未修复的 iOS 17 问题）。这里选"降级可用"。
    private func applyGlass(to view: UIVisualEffectView) {
        guard UserDefaults.nowPlayingShellGlass else {
            view.effect = nil
            return
        }

        if let glassType = NSClassFromString("UIGlassEffect") as? UIVisualEffect.Type {
            view.effect = glassType.init()
            return
        }
        view.effect = UIBlurEffect(style: .systemUltraThinMaterialDark)
    }

    /// 顶栏那道"承上启下"的色带。
    ///
    /// 为什么需要它，而不是只留玻璃：听歌页有两块**属于原生的**界面在顶栏区域
    /// —— 上面是 Spotify 自己的导航条（含 ⋯ 与那颗 `✓`），下面是它那排内容。
    /// 只铺玻璃的话，我们画的玻璃会盖在导航条上、色调和页面脱节（"壳肉割裂"）。
    /// 所以这里读出**原生此刻正在用的那个封面底色**（`bg=#F8A880` 那一路），
    /// 用同一个颜色做一条从上往下渐隐的带子，让状态栏 → 导航条 → 内容平滑连起来。
    private func applyHeaderTint(_ baseColor: UIColor) {
        headerTint.backgroundColor = .clear
        headerTint.layer.sublayers?.forEach { layer in
            if layer.name == NowPlayingShellMetrics.tintLayerName { layer.removeFromSuperlayer() }
        }

        // 拿不到原生底色就不铺（宁可只有玻璃，也不要一个猜出来的颜色）。
        //
        // ⚠️ 从**窗口**开始走：吸顶头挂在 `SPTNowPlayingViewContainerViewController`
        // 那一层，从壳自己往下走是走不到的（第一版就是栽在这个范围上，已改）。
        let searchRoot = window ?? self
        guard let nativeTint = NowPlayingShellColors.nativeStickyHeaderColor(in: searchRoot) else { return }
        let resolved = NowPlayingShellColors.isUsable(nativeTint) ? nativeTint : baseColor

        let gradient = CAGradientLayer()
        gradient.name = NowPlayingShellMetrics.tintLayerName
        gradient.colors = [
            resolved.withAlphaComponent(0.98).cgColor,
            resolved.withAlphaComponent(0.55).cgColor,
            resolved.withAlphaComponent(0.00).cgColor,
        ]
        gradient.locations = [0.0, 0.62, 1.0]
        gradient.startPoint = CGPoint(x: 0.5, y: 0)
        gradient.endPoint = CGPoint(x: 0.5, y: 1)
        gradient.frame = headerTint.bounds
        headerTint.layer.addSublayer(gradient)
    }

    override func layoutSublayers(of layer: CALayer) {
        super.layoutSublayers(of: layer)
        // 渐变层跟着顶栏尺寸走（Auto Layout 改 bounds 之后才轮到它）。
        for sub in headerTint.layer.sublayers ?? [] where sub.name == NowPlayingShellMetrics.tintLayerName {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            sub.frame = headerTint.bounds
            CATransaction.commit()
        }
    }

    // MARK: 让原生吸顶头让位（可撤销）

    /// 把原生那道随滚动变不透明的封面底色**收掉**，并把它的标题文字清空。
    ///
    /// 照片 18 的病根：滚动时 `6.UIView@0,0,414,48` 的 alpha 从 0 涨到 1，
    /// 那是一个整屏不透明的容器，盖上来就把我们画的标题吃了。
    ///
    /// 做法与理由：
    ///   · **清底色而不是藏视图** —— 藏掉那个容器等于把里面的 ⋯ 菜单一起藏了；
    ///     清成透明则它带来的交互原封不动（这也符合"差不多就行、别动原生"的选择）；
    ///   · **清文字而不是清容器** —— 否则我们画完标题，它自己又画一遍，两个标题叠在一起；
    ///   · 目标按**类名**找（`ScrollStickyHeader`，日志 14/16 的 dump 里逐字可见），
    ///     找到几个清几个，找不到就什么都不做（不猜、不猜类名、不做运行时类枚举）。
    ///   · 原值全部记下来，`restore()` 时写回 —— 关掉开关必须完全还原。
    private func nativeTintYield() {
        guard UserDefaults.nowPlayingShellHeader else { return }
        guard let searchRoot = window ?? superview else { return }

        var stickyViews: [UIView] = []
        collectStickyHeaderViews(in: searchRoot, into: &stickyViews)
        guard !stickyViews.isEmpty else {
            if !didLogStickyHeaderOutcome {
                didLogStickyHeaderOutcome = true
                writeDebugLog("[Shell] ⚠️ 没找到 ScrollStickyHeader — 原生吸顶头无法让位（标题可能仍会被盖）")
            }
            return
        }
        if !didLogStickyHeaderOutcome {
            didLogStickyHeaderOutcome = true
            writeDebugLog("[Shell] 找到原生吸顶头 \(stickyViews.count) 个 — 已让它让位")
        }

        for sticky in stickyViews {
            for node in [sticky] + allSubviews(of: sticky) {
                // 底色：只清"有底色且不是透明"的那些，并记原值。
                if let color = node.backgroundColor, color.cgColor.alpha > 0.01 {
                    rememberTint(node, node.backgroundColor)
                    node.backgroundColor = .clear
                }
                // 文字：清空原生标题/歌手（我们自己在画）。
                if let label = node as? UILabel, let text = label.text, !text.isEmpty {
                    rememberLabelText(label, text)
                    label.text = nil
                }
            }
        }
    }

    private var didLogStickyHeaderOutcome = false

    private func collectStickyHeaderViews(in view: UIView, into result: inout [UIView]) {
        let name = NSStringFromClass(type(of: view))
        if name.contains("ScrollStickyHeader") {
            result.append(view)
            return  // 同一个头里不再往里找，避免把子视图重复清一遍
        }
        for sub in view.subviews {
            collectStickyHeaderViews(in: sub, into: &result)
        }
    }

    private func allSubviews(of view: UIView) -> [UIView] {
        var result: [UIView] = []
        for sub in view.subviews {
            result.append(sub)
            result.append(contentsOf: allSubviews(of: sub))
        }
        return result
    }

    private func rememberTint(_ view: UIView, _ color: UIColor?) {
        guard !nativeTintSnapshots.contains(where: { $0.view === view }) else { return }
        nativeTintSnapshots.append((view: view, color: color))
    }

    private func rememberLabelText(_ label: UILabel, _ text: String?) {
        guard !nativeLabelSnapshots.contains(where: { $0.label === label }) else { return }
        nativeLabelSnapshots.append((label: label, text: text))
    }

    /// 完全还原：把记下来的原值写回。
    func restore() {
        for snapshot in nativeTintSnapshots where snapshot.view.superview != nil {
            snapshot.view.backgroundColor = snapshot.color
        }
        for snapshot in nativeLabelSnapshots where snapshot.label.superview != nil {
            snapshot.label.text = snapshot.text
        }
        nativeTintSnapshots.removeAll()
        nativeLabelSnapshots.removeAll()
        writeDebugLog("[Shell] 已还原原生吸顶头")
    }

    // MARK: 动作

    @objc private func onChevron() {
        // 只走既有原语：它自带 `isOwnControl` + `isForwardingTap` 双重防重入
        // （历史上自己点自己爆过栈）。它内部优先"点原生收起键"，失败才自己 dismiss。
        let ok = WordByWordPlaybackControl.dismissFullscreen()
        writeDebugLog("[Shell] 收起听歌页 → \(ok ? "ok" : "failed")")
    }
}

// MARK: - 排版常数

enum NowPlayingShellMetrics {
    /// 顶栏高度（照全屏歌词壳的 `LyricsShellLayout.headerHeight`）。
    static let headerHeight: CGFloat = 62
    /// 标题距安全区顶部。
    static let titleTopInset: CGFloat = 6
    /// 标题左右留白（给 ⌄ 与 ⋯ 让位）。
    static let titleSideInset: CGFloat = 56
    /// ⌄ 距左边。
    static let closeLeadingInset: CGFloat = 8
    /// 触控目标边长（Apple HIG 的最小值；视觉上那个符号只有 16pt）。
    static let hitTargetSize: CGFloat = 44
    /// 顶栏那道色带的图层名（用来找它自己，避免误删别的层）。
    static let tintLayerName = "eevee.nowPlaying.shell.tint"
}

// MARK: - 取色

enum NowPlayingShellColors {

    /// 本页"底色"。
    ///
    /// 三个来源，从准到糙：
    ///   1. `currentLyricsBackgroundColorARGB` —— CustomLyrics 算好的原生歌词背景色，
    ///      与 Spotify 这一页真正在用的颜色同源（`LyricsWordByWord.x.swift:48`）；
    ///   2. `backgroundViewModel?.color()` —— Spotify 自己的背景色 view model
    ///      （全屏歌词页也在用同一个，`LyricsWordByWord.x.swift:343`）；
    ///   3. 中性深色兜底 —— 保证"半透明黑洞"不会出现。
    static func baseColor() -> UIColor {
        if currentLyricsBackgroundColorARGB != 0 {
            let argb = currentLyricsBackgroundColorARGB
            return UIColor(
                red: CGFloat((argb >> 16) & 0xFF) / 255,
                green: CGFloat((argb >> 8) & 0xFF) / 255,
                blue: CGFloat(argb & 0xFF) / 255,
                alpha: 1
            )
        }

        if let object = backgroundViewModel as? NSObject,
           object.responds(to: Selector("color")),
           let color = object.perform(Selector("color"))?.takeUnretainedValue() as? UIColor {
            return color
        }

        return UIColor(white: 0.07, alpha: 1)
    }

    /// 从视图树里读**原生吸顶头此刻正在用的那个底色**。
    ///
    /// 为什么值得读它：日志 12/14 里 `6.UIView@0,0,414,48,bg=#F8A880` 这个颜色就是
    /// Spotify 自己算好的"这首歌的封面底色"。我们拿它做顶栏色带，就不用自己再算一遍、
    /// 也不会和它那排内容撞色。
    ///
    /// ⚠️ 搜索范围必须是**窗口**而不是听歌页的根视图：吸顶头虽然在同一个头里，
    /// 但它挂在 `SPTNowPlayingViewContainerViewController` 那一层（dump 实测），
    /// 从我们自己的 superview 往下走**根本走不到它**（这是第一版的错，已改）。
    static func nativeStickyHeaderColor(in root: UIView) -> UIColor? {
        var found: UIColor?
        func walk(_ node: UIView) {
            if found != nil { return }
            if NSStringFromClass(type(of: node)).contains("ScrollStickyHeader") {
                for child in [node] + descendants(of: node) {
                    if let color = child.backgroundColor, color.cgColor.alpha > 0.01 {
                        found = color
                        return
                    }
                }
            }
            for sub in node.subviews { walk(sub) }
        }
        walk(root)
        return found
    }

    private static func descendants(of view: UIView) -> [UIView] {
        var result: [UIView] = []
        for sub in view.subviews {
            result.append(sub)
            result.append(contentsOf: descendants(of: sub))
        }
        return result
    }

    /// 这个颜色能不能用来画（避免把 `.clear` 或近乎透明的色当成底色）。
    static func isUsable(_ color: UIColor) -> Bool {
        color.cgColor.alpha > 0.01
    }
}

// MARK: - Hook

/// 听歌页（大封面那页）：`_TtC21NowPlaying_ScrollImpl23NPVScrollViewController`。
///
/// ⚠️ **这个 selector 只能有一个 hook**。`MusicStyleNowPlaying.x.swift` 里原来那条
/// `viewDidLayoutSubviews` 已经改名为 `applyNowPlayingAppearance` 并由这里统一调用 ——
/// 同一个 selector 挂两条 Orion hook 就是在赌 swizzle 顺序，没必要冒这个险。
///
/// 用 `viewDidLayoutSubviews` 而不是 `viewDidAppear`：手势那条用的是后者，分开互不干扰。
class NowPlayingShellHook: ClassHook<UIViewController> {
    typealias Group = NowPlayingShellGroup
    static let targetName = "_TtC21NowPlaying_ScrollImpl23NPVScrollViewController"

    func viewDidLayoutSubviews() {
        orig.viewDidLayoutSubviews()
        applyNowPlayingAppearance(to: self.target.view)
    }
}

/// 两条外观路径的统一入口（壳 + 旧版样品标题）。
@MainActor
func applyNowPlayingAppearance(to root: UIView?) {
    NowPlayingShell.apply(to: root)
    MusicStyleNowPlaying.applyLegacyTitle(to: root)
}

func activateNowPlayingShell() {
    guard NSClassFromString(NowPlayingShellHook.targetName) != nil else {
        writeDebugLog("[Shell] missing \(NowPlayingShellHook.targetName) — hook inactive")
        return
    }

    NowPlayingShellGroup().activate()
    writeDebugLog(
        "[Shell] 听歌页壳 installed (shell="
            + "\(UserDefaults.nowPlayingShellEnabled ? "ON" : "OFF")"
            + " backdrop=\(UserDefaults.nowPlayingShellBackdrop ? "ON" : "OFF")"
            + " header=\(UserDefaults.nowPlayingShellHeader ? "ON" : "OFF")"
            + " glass=\(UserDefaults.nowPlayingShellGlass ? "ON" : "OFF"))"
    )
}
