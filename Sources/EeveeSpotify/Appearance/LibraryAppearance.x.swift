import Foundation
import Orion
import UIKit
import ObjectiveC.runtime

/// 音乐库（Your Library）的「改原生」第一批 —— 不是加层，是**改 Spotify 自己的视图**。
///
/// ── 为什么从这里开始 ────────────────────────────────────────────────────────
/// 听歌页那两版（`NowPlayingShell`）做的是"加一层壳"：能改底色、能加顶栏，但页面本身的
/// 结构一点没动，所以观感上限锁死在"加了点东西"。要真的像 Apple Music，必须动
/// **原生视图自己** —— 这一批就是第一个例子。
///
/// ── 目标全部来自真机 dump（日志 17 的 `[Tree] #2`，不是猜的）─────────────────
/// ```
/// 18.YourLibraryContentView@0,0,414,896
/// 18.YourLibraryHeaderView@0,0,414,148          ← 头部（标题行 48 + 筛选行 52 + 余量）
/// 19.YourLibraryCollectionView@0,0,414,896,bg=#121212
/// 19.GradientView@0,0,414,148,id=LiquidGlass.GradientView   ← ★ 顶部那层"滚边渐隐"遮罩
/// 19.UIView@0,48,414,48                          ← 48 高的一条（疑似头部色条/分隔）
/// 19.YourLibraryHeaderContentFiltersView@0,96,414,52        ← 筛选行容器
/// 23.OBJC_ONLY_Label@48,7,72,34,id=YourLibraryHeader.title  ← ★ 标题（x=48 说明是左内缩，不是居中）
/// ```
///
/// ── 三条纪律（照仓库既有做法）───────────────────────────────────────────────
///   1. **全程在开关后面**，关掉完全还原（改过的值全部记下来写回）；
///   2. **幂等**：每次布局都先判断再写（Spotify 的 binder 可能把值改回去）；
///   3. **只改读得到的属性**（`alpha` / `backgroundColor` / `textAlignment` /
///      `constraint.constant` / `UILabel` 的字体与颜色），**不碰任何需要猜签名的方法**。
///
/// ⚠️ 这一批**刻意没做**的事，以及为什么：
///   · **不换大标题的字体**：标题是 Encore 的 element（`ElementView<…>` + binder），
///     字号很可能在每次数据更新时被 binder 写回 —— 改了就闪。要换字体得先弄清
///     binder 的更新时机（下一批再说），这一批只做"能站住的改动"。
///   · **不碰列表行**（封面圆角/发丝分隔）：行是 cell 复用 + element 绘制，
///     不是 `UIImageView` 的 `cornerRadius` 那种改法，得单独摸一轮。
struct LibraryAppearanceGroup: HookGroup {}

enum LibraryAppearance {

    static var isEnabled: Bool { UserDefaults.libraryLargeTitle }

    // MARK: 施加

    /// 由 `LibraryAppearanceHook` 在每次布局时调用。幂等。
    static func apply(to headerView: UIView?) {
        guard let headerView else { return }
        guard isEnabled else {
            restore()
            return
        }

        applyLargeTitle(in: headerView)
        hideScrollEdgeGradient(near: headerView)
    }

    // MARK: ① 大标题：左对齐 + 与头像拉开一点

    private static weak var titleLabel: UILabel?
    private static var originalAlignment: NSTextAlignment?
    private static var adjustedLeadingConstraint: (constraint: NSLayoutConstraint, original: CGFloat)?

    /// AM 的"大标题"是**左对齐、字号更大、字重更重**。
    ///
    /// 字号与字重这一批不碰（见文件头的说明）；这里做两件确定站得住的事：
    ///   · 对齐改成左对齐（AM 的标题一律贴左边）；
    ///   · 如果标题左边那条约束的间距是 0，把它调到 8 —— 让标题和头像之间有一点呼吸。
    private static func applyLargeTitle(in headerView: UIView) {
        guard let label = findTitleLabel(in: headerView) else { return }
        titleLabel = label

        if originalAlignment == nil {
            originalAlignment = label.textAlignment
        }
        if label.textAlignment != .left {
            label.textAlignment = .left
        }

        // 找"标题左边那条 ≥/=" 约束，把它的 constant 抬到 8（只改一次，原值记下）。
        guard adjustedLeadingConstraint == nil else { return }
        for constraint in headerView.constraints {
            let involvesTitle = constraint.firstItem as? UIView === label
                || constraint.secondItem as? UIView === label
            guard involvesTitle else { continue }

            let isLeading = constraint.firstAttribute == .leading
                || constraint.firstAttribute == .left
                || constraint.secondAttribute == .leading
                || constraint.secondAttribute == .left
            guard isLeading, constraint.constant < 8 else { continue }

            adjustedLeadingConstraint = (constraint, constraint.constant)
            constraint.constant = 8
            break
        }
    }

    private static func findTitleLabel(in view: UIView) -> UILabel? {
        if let label = view as? UILabel,
           label.accessibilityIdentifier?.hasPrefix("YourLibraryHeader.title") == true {
            return label
        }
        for sub in view.subviews {
            if let found = findTitleLabel(in: sub) { return found }
        }
        return nil
    }

    // MARK: ② 顶部那层滚边渐隐

    /// `LiquidGlass.GradientView` 是 Spotify 在新设计语言下给"内容滚到栏下"准备的渐隐遮罩。
    ///
    /// 为什么收掉它：AM 的资料库顶部**没有这层灰纱** —— 大标题直接压在纯色底上。
    /// 这层纱正是"看起来像 Spotify"的一个具体来源。
    ///
    /// 做法**保守**：只把它 `alpha` 归零（可还原），**不隐藏** —— `isHidden` 会牵动
    /// 兄弟视图的布局，而 `alpha` 只影响画面。找不到就什么都不做。
    private static weak var gradientView: UIView?
    private static var originalGradientAlpha: CGFloat?

    private static func hideScrollEdgeGradient(near root: UIView) {
        // ⚠️ 搜索范围必须**从资料库这一页往下**，不要往外走到窗口：
        // 窗口里还有别的 `GradientView`（首页那个 `LiquidGlass.GradientView` 之类），
        // 走远了就可能把**别人**的渐隐收掉（第一版就是走到窗口，范围太大）。
        let target = gradientView ?? findGradientView(in: root)
        guard let target else { return }
        gradientView = target

        if originalGradientAlpha == nil {
            originalGradientAlpha = target.alpha
        }
        if target.alpha != 0 {
            target.alpha = 0
            writeDebugLog("[Library] 已收掉顶部滚边渐隐 (\(typeName(target)))")
        }
    }

    /// 只认**我们自己要收的那一层**：`--LiquidGlass.GradientView--`。
    ///
    /// 真名从解密 IPA 核过：`_TtCO22Reprise_LiquidGlassKit11LiquidGlass12GradientView`
    /// → `Reprise_LiquidGlassKit.LiquidGlass.GradientView`（真机 dump 里显示成
    /// `GradientView id=LiquidGlass.GradientView`）。
    ///
    /// ⚠️ 不加 `contains("GradientView")` 那种宽松匹配：资料库里还有别的地方会用到
    /// 渐变（卡片、占位），收错了就是"改坏了别人的视图"。LiquidGlass 命名空间是唯一
    /// 指向"滚边渐隐"的判据。
    private static func findGradientView(in view: UIView) -> UIView? {
        let name = NSStringFromClass(type(of: view))
        if name.contains("Reprise_LiquidGlassKit") && name.contains("GradientView") {
            return view
        }
        for sub in view.subviews {
            if let found = findGradientView(in: sub) { return found }
        }
        return nil
    }

    // MARK: 还原

    static func restore() {
        if let label = titleLabel, let alignment = originalAlignment {
            label.textAlignment = alignment
        }
        originalAlignment = nil
        titleLabel = nil

        if let adjusted = adjustedLeadingConstraint, adjusted.constraint.constant == 8 {
            adjusted.constraint.constant = adjusted.original
        }
        adjustedLeadingConstraint = nil

        if let gradient = gradientView, let alpha = originalGradientAlpha, gradient.alpha == 0 {
            gradient.alpha = alpha
        }
        originalGradientAlpha = nil
        gradientView = nil
    }

    private static func typeName(_ view: UIView) -> String {
        NSStringFromClass(type(of: view))
    }
}

// MARK: - Hook

/// 音乐库页：`YourLibrary_YourLibraryXImpl.YourLibraryView`
/// （类名从解密 IPA 的 `dump-9.1.86.txt` 与真机 dump 双向核对过：
///  `_TtC28YourLibrary_YourLibraryXImpl15YourLibraryView`）。
///
/// ⚠️ 用 `layoutSubviews` 而不是 `viewDidLayoutSubviews`：我们要读的是这个**视图自己**
/// 的子层级（标题、渐隐层都在它的树里），视图级时机更贴近。
class LibraryAppearanceHook: ClassHook<UIView> {
    typealias Group = LibraryAppearanceGroup
    static let targetName = "YourLibrary_YourLibraryXImpl.YourLibraryView"

    func layoutSubviews() {
        orig.layoutSubviews()
        // hook 方法上不写 `@MainActor`、方法体里用 `onMainThreadSync` —— 仓库成文规矩
        // （见 `LyricsChromeVisibility.swift:3-17`）。
        //
        // ⚠️ 先把 `target` 取成局部量再进闭包：Orion 生成的那个属性在闭包里引用
        // 容易踩隔离/捕获的坑，取出来最省事。
        let view = self.target
        onMainThreadSync {
            LibraryAppearance.apply(to: view)
        }
    }
}

func activateLibraryAppearance() {
    guard NSClassFromString(LibraryAppearanceHook.targetName) != nil else {
        writeDebugLog("[Library] missing \(LibraryAppearanceHook.targetName) — hook inactive")
        return
    }

    LibraryAppearanceGroup().activate()
    writeDebugLog(
        "[Library] 音乐库改原生 installed (largeTitle="
            + "\(UserDefaults.libraryLargeTitle ? "ON" : "OFF"))"
    )
}
