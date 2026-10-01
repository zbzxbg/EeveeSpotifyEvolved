import Foundation
import Orion
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
struct NowPlayingShellGroup: HookGroup {}

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
            // ⚠️ `current` 是 weak，这里取到的一定是非 Optional（上面那行 `if let`
            // 已经绑过了）；早期版本写成 `shell?.removeFromSuperview()` 是错的。
            current?.removeFromSuperview()
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
    /// 上一次施加时的尺寸（只在尺寸变化时才做一次性的收尾工作）。
    private var lastLayoutSize: CGSize = .zero

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

        // ── 背景用"透明档"，而不是歌词页那档实心底（照片 19/20 换来的）──────
        //
        // `LyricsBackdropView` 是给**全屏歌词页**写的：那一页我们要**替换**整页内容，
        // 所以它可以铺一张不透明的模糊封面 + 黑纱（`isBackdropOpaque = true`）。
        // 但听歌页的原生内容**正是我们要显示的东西**（封面、进度、三键都在下面），
        // 一铺实心就被整页盖住 —— 照片 19 是一片纯蓝，照片 20 连封面和按钮都成了
        // 模糊残影，就是这么来的。
        //
        // 所以这里走它**预留好的那条路**：`isBackdropOpaque = false` 时它整块透明、
        // 只留一圈边缘暗化渐变给我们的白字当底（那个类注释里写明这条路的用途是
        // "数据不可用就整块透明、交还原生"）。底色感由上面那条顶栏色带 + 原生自己的
        // 封面染色给，不再和我们自己抢画面。
        backdrop.style = .stage
        backdrop.solid = false
        backdrop.isBackdropOpaque = false
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
        // ⚠️ 不用 `UIButton.Configuration`（那条 API 是 **iOS 15+**，而本工程
        //    `Makefile` 的 deployment target 是 14.0 —— 用了就是编译期错误，
        //    不是运行期判断能救的）。退回 iOS 7 起就有的写法。
        chevronButton.setImage(
            UIImage(
                systemName: "chevron.down",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
            ),
            for: .normal
        )
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
                equalTo: safeAreaLayoutGuide.heightAnchor,
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
        // ⚠️⚠️ 这里**曾经**在布局里跑一遍"让原生吸顶头让位"（清它的底色与文字）。
        // 已经**整个删掉**，原因是真机反馈"页面划不动"：
        //   · 它每次布局都走一遍**整窗视图树**，并且在滚动过程中**改 Spotify 自己视图的
        //     `backgroundColor`** —— 等于边滚边动人家的视图，足以把滚动卡死；
        //   · 而它**没有任何视觉收益**：那个类名在 9.1.86 上根本没找到（日志 17 已证），
        //     也就是说这段代码在真机上一直是空转 + 添乱。
        //
        // 教训与仓库里那条一致：**不要为"可能有用"去动别人的视图**。
        // 要做"让位"，必须先拿到真类名（探针在查），并且只做**只读判断 + 一次性改动**，
        // 不在布局回调里反复写。
        guard bounds.size != lastLayoutSize else { return }
        lastLayoutSize = bounds.size
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
    /// ── 为什么**默认不用**真玻璃（照片 20 换来的）────────────────────────────
    /// iOS 27 上 `UIGlassEffect` **是真的能拿到**，但液态玻璃不是"贴上去就好看"的东西：
    /// 它的看家本领是折射与透镜，代价是**把底下的内容整个糊掉**。
    /// 照片 20 就是它盖在 121pt 高的顶栏上的结果 —— 连封面和按钮都成了残影，
    /// 读起来像"糊了一层玻璃上去"。
    ///
    /// 所以这里改成**默认不铺**，只留那条"从上往下渐隐"的色带（见 `applyHeaderTint`）：
    /// 它同样能让状态栏 → 导航条 → 内容连成一片，但**不吃画面**。
    /// 想做真玻璃观感时再打开 `nowPlayingShellGlass`（设置里那个开关），
    /// 并且那时应当把它**收窄到只有安全区那条**（写在这里当备忘）。
    ///
    /// 仍然保留探测式写法：拿得到就用真的、拿不到退材质，**不写 `#available`**
    ///（与本仓库既有做法一致，见 `AmoledTheme.x.swift`）。
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
    /// 顶栏那道"承上启下"的色带。
    ///
    /// 只用**我们算出来的封面底色**（`NowPlayingShellColors.baseColor()`）做一条
    /// 从上往下渐隐的带子：让状态栏 → 导航条 → 内容之间的过渡有个统一的色，白字也压得住。
    ///
    /// ⚠️ 这里**不再**去读原生吸顶头当下的颜色了。上一版那么做过，但它属于
    /// "主动去翻别人的视图树" 那一类做法 —— 与刚删掉的让位代码同源，同样有
    /// 边滚边读、影响页面的风险，而收益只是"颜色更贴一点"。底色我们本来就算得出来。
    private func applyHeaderTint(_ baseColor: UIColor) {
        headerTint.backgroundColor = .clear
        headerTint.layer.sublayers?.forEach { layer in
            if layer.name == NowPlayingShellMetrics.tintLayerName { layer.removeFromSuperlayer() }
        }

        let resolved = baseColor

        let gradient = CAGradientLayer()
        gradient.name = NowPlayingShellMetrics.tintLayerName
        // 只压顶部那一小块（状态栏与导航条所在），往下很快淡掉。
        // 数值是照片 19 之后调的：原来 0.98/0.55/0.00 会把"我们自己的标题"以外的
        // 东西也糊住。这里再收一档，因为底色已经交回给原生了，顶栏只需要一点点暗底
        // 保证白字清楚。
        gradient.colors = [
            resolved.withAlphaComponent(0.55).cgColor,
            resolved.withAlphaComponent(0.22).cgColor,
            resolved.withAlphaComponent(0.00).cgColor,
        ]
        gradient.locations = [0.0, 0.55, 1.0]
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
    // MARK: 让原生吸顶头让位（正确做法：只 hook 它自己，只在它自己布局时收一次）

    // 上一版是在壳的 `layoutSubviews` 里"遍历整窗 + 每帧清别人的底色"，结果把滚动搞停了。
    // 正确做法在 `StickyHeaderYieldHook`（文件末尾）：
    //   · 由**那个视图自己**的 `layoutSubviews` 触发 —— 只在它自己布局时跑，滚动中不动它；
    //   · 目标不用类名，改用"从歌曲标题 label 往上找第一个不透明的祖先"（见下面
    //     `firstTintedAncestor(of:)`）—— 不依赖任何会变的类名；
    //   · 只清一次（清了就记下来，值没变就一个字节都不动）。

    /// 吸顶头的底色原值（`StickyHeaderYieldHook` 填，`restore()` 写回）。
    static weak var yieldedTintView: UIView?
    static var yieldedTintOriginalColor: UIColor?

    /// 从歌曲标题那个 label 往上找**第一个带不透明底色的祖先** —— 那就是吸顶头那道渐显底色。
    ///
    /// 为什么用这条路而不是类名：日志里 Spotify 的头部类名在版本之间换过
    /// （`ScrollStickyHeader` 在 9.1.86 上根本不存在），而"标题文字上面压着一层底色"
    /// 这件事是稳定的。
    static func firstTintedAncestor(of label: UILabel) -> UIView? {
        var node: UIView? = label.superview
        var depth = 0
        while let current = node, depth < 10 {
            if let color = current.backgroundColor, color.cgColor.alpha > 0.01 {
                return current
            }
            node = current.superview
            depth += 1
        }
        return nil
    }

    /// 收掉那道底色（幂等：已经是透明的就什么都不做）。
    static func yieldTint(of view: UIView) {
        if yieldedTintView !== view {
            yieldedTintView = view
            yieldedTintOriginalColor = view.backgroundColor
        }
        guard let color = view.backgroundColor, color.cgColor.alpha > 0.01 else { return }
        view.backgroundColor = .clear
        writeDebugLog("[Shell] 吸顶头底色已收掉 (\(NSStringFromClass(type(of: view))))")
    }

    /// 完全还原。
    ///
    /// 现在只需要打一行日志：壳自己的东西随 `removeFromSuperview()` 一起消失，
    /// 而**我们持有改动的唯一原生视图就是吸顶头那道底色**（上面那对变量），写回即可。
    func restore() {
        if let view = NowPlayingShell.yieldedTintView,
           let original = NowPlayingShell.yieldedTintOriginalColor {
            view.backgroundColor = original
            NowPlayingShell.yieldedTintView = nil
            NowPlayingShell.yieldedTintOriginalColor = nil
            writeDebugLog("[Shell] 壳已拆除（吸顶头底色已写回）")
            return
        }
        writeDebugLog("[Shell] 壳已拆除（未改动任何原生视图）")
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
        // ⚠️ hook 方法上**不要**写 `@MainActor`，也别在这里直接调被标了 `@MainActor`
        // 的函数 —— 本仓库有成文的规矩与现成 helper：见 `LyricsChromeVisibility.swift:3-17`
        // 与 `onMainThreadSync`（Orion 的生成器是按源码文本拼 `override` 的，
        // 给覆写方法加 `@MainActor` 会拼出非法属性）。
        applyNowPlayingAppearance(to: self.target.view)
    }
}

/// 两条外观路径的统一入口（壳 + 旧版样品标题）。
///
/// 用仓库既有的 `onMainThreadSync` 表达"这里是主线程"，不自己写
/// `MainActor.assumeIsolated`（少一处重复实现，也少一处和仓库规矩打架的地方）。
func applyNowPlayingAppearance(to root: UIView?) {
    onMainThreadSync {
        NowPlayingShell.apply(to: root)
        MusicStyleNowPlaying.applyLegacyTitle(to: root)
    }
}

// MARK: - 让原生吸顶头让位（只 hook 它自己）

/// 原生的"滚动吸顶头"控制器。
///
/// 真名来自**解密 IPA**（`dump-9.1.86.txt:2034`）：
/// `_TtC19NowPlaying_ViewImpl30StickyHeaderViewControllerImpl`
/// → `NowPlaying_ViewImpl.StickyHeaderViewControllerImpl`。
///
/// ⚠️ 上一版按 `ScrollStickyHeader` 找，那个名字在 9.1.86 上**根本不存在**
/// （只有 `ScrollStickyHeader.ContentView` 这种 element 标识符，不是类名）——
/// 所以它一直在空转，而我却把"清别人底色"的逻辑放在了壳的每帧布局里，把页面搞到划不动。
/// 这一版两条都改：
///   · 挂在**正确的类**上，并且用它自己的 `viewDidLayoutSubviews` 触发
///     （只在"这个头自己重新布局"时才会跑，滚动过程中不会去动它）；
///   · 只清**一次**（值没变就什么都不做）。
class StickyHeaderYieldHook: ClassHook<UIViewController> {
    typealias Group = NowPlayingShellGroup
    static let targetName = "NowPlaying_ViewImpl.StickyHeaderViewControllerImpl"

    /// 被写回的次数。Spotify 若在每次布局都把底色写回来，我们就不再和它对着干
    /// （那种循环正是"滚动卡住"的温床）—— 这条计数就是判据。
    private static var resetCount = 0

    func viewDidLayoutSubviews() {
        orig.viewDidLayoutSubviews()
        let controller = self.target
        onMainThreadSync {
            guard UserDefaults.nowPlayingShellHeader else { return }
            guard let view = controller.view else { return }
            guard let label = StickyHeaderYieldHook.findTitleLabel(in: view) else {
                StickyHeaderYieldHook.reportMissingLabelOnce()
                return
            }
            guard let tint = NowPlayingShell.firstTintedAncestor(of: label) else { return }

            let wasTransparent = tint.backgroundColor.map { $0.cgColor.alpha <= 0.01 } ?? true
            if !wasTransparent {
                StickyHeaderYieldHook.resetCount += 1
                if StickyHeaderYieldHook.resetCount > 5 {
                    if !StickyHeaderYieldHook.didGiveUp {
                        StickyHeaderYieldHook.didGiveUp = true
                        writeDebugLog(
                            "[Shell] ⚠️ 吸顶头底色被反复写回 \(StickyHeaderYieldHook.resetCount) 次"
                                + " — 不再与它抢（保持原生，避免滚动受影响）"
                        )
                    }
                    return
                }
            }
            NowPlayingShell.yieldTint(of: tint)
        }
    }

    private static var didReportMissingLabel = false
    private static var didGiveUp = false

    /// 在吸顶头里找**歌曲标题**那个 label。
    ///
    /// 两条判据，任一中就够：
    ///   1. 文本等于当前曲名（最稳，不依赖任何标识符）；
    ///   2. 无障碍标识符里带 `trackTitle` / `title` 字样（备选）。
    private static func findTitleLabel(in view: UIView) -> UILabel? {
        let currentTitle = statefulPlayer?.currentTrack()?.string(ifResponding: "trackTitle")

        var fallback: UILabel?
        func walk(_ node: UIView) {
            if let label = node as? UILabel, let text = label.text, !text.isEmpty {
                if let currentTitle, !currentTitle.isEmpty, text == currentTitle {
                    fallback = label
                    return
                }
                if let identifier = label.accessibilityIdentifier,
                   identifier.contains("trackTitle") || identifier.contains("Title") {
                    fallback = fallback ?? label
                }
            }
            for sub in node.subviews { walk(sub) }
        }
        walk(view)
        return fallback
    }

    private static func reportMissingLabelOnce() {
        guard !didReportMissingLabel else { return }
        didReportMissingLabel = true
        writeDebugLog("[Shell] 吸顶头里没找到曲名 label — 让位这一步先跳过（不影响其它）")
    }
}

func activateStickyHeaderYield() {
    // ⚠️ 这里**不**调 `NowPlayingShellGroup().activate()`：它与壳共用同一个 group，
    // 上面 `activateNowPlayingShell()` 已经装过了。重复 activate 等于对同一个方法
    // 再 swizzle 一次 —— 这种赌没必要打。
    guard NSClassFromString(StickyHeaderYieldHook.targetName) != nil else {
        writeDebugLog("[Shell] missing \(StickyHeaderYieldHook.targetName) — 吸顶头让位未装")
        return
    }
    writeDebugLog("[Shell] 吸顶头让位 hook on（\(StickyHeaderYieldHook.targetName)）")
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
