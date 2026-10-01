import Foundation
import Orion
import UIKit
import ObjectiveC.runtime

/// 音乐库（Your Library）的「改原生」第一批 —— 不是加层，是**改 Spotify 自己的视图**。
///
/// ── 为什么从这里开始 ────────────────────────────────────────────────────────
/// 听歌页那条线（"加一层壳"那一套，**2026-10-02 已整块删除**）做的是加壳：能改底色、能加顶栏，
/// 但页面本身的结构一点没动，所以观感上限锁死在"加了点东西"。要真的像 Apple Music，必须动
/// **原生视图自己** —— 这一批就是第一个例子。
///
/// ── 目标全部来自真机 dump 与解密 IPA 双向核对（不是猜的）─────────────────────
/// ```
/// 18.YourLibraryView@0,0,414,896            ← hook 目标
///    （IPA: _TtC28YourLibrary_YourLibraryXImpl15YourLibraryView）
/// 19.YourLibraryCollectionView@0,0,414,896,bg=#121212
/// 19.GradientView@0,0,414,148,id=LiquidGlass.GradientView   ← ★ 顶部那层滚边渐隐
///    （IPA: _TtCO22Reprise_LiquidGlassKit11LiquidGlass12GradientView）
/// 23.OBJC_ONLY_Label@48,7,72,34,id=YourLibraryHeader.title  ← ★ 标题
/// ```
///
/// ── ⚠️ 为什么必须"复查"，不能只靠 `layoutSubviews`（第一次交付就是这么白干的）──
/// 第一版只在 hook 到的 `layoutSubviews` 里改一次。问题有两个：
///   1. **不是每次变更都会再走一遍 layout** —— 改完那一次之后，页面上再也没有布局回合，
///      后续的覆盖就没人纠正了；
///   2. Spotify 的界面是 Encore 的 element 系统（`ElementView` + binder 驱动），
///      binder 在数据更新时会**把属性写回去**。
/// 这正是本仓库在"清爽"功能上栽过的同一个坑，解法也早就写好了：
/// `DeclutterChrome.reconcile` —— **常驻节拍复查**（定时器 + 前台 + 布局里顺手叫一次）。
/// 这里照同一套做，只是复查内容换成资料库这几项。
///
/// ── 三条纪律（照仓库既有做法）───────────────────────────────────────────────
///   1. **全程在开关后面**，关掉完全还原（改过的值全部记下来写回）；
///   2. **幂等**：每次复查都先判断再写（值没变就一个字节都不动）；
///   3. **只改读得到的属性**（`alpha` / `backgroundColor` / `textAlignment` /
///      `constraint.constant`），**不碰任何需要猜签名的方法**。
///
/// ⚠️ 这一批**刻意没做**的（留到下一批）：
///   · **大标题的字号/字重** —— 会被 binder 写回，改了会闪；要做得先摸清 binder 的更新时机；
///   · **列表行的封面圆角 / 发丝分隔线** —— 那些是 element 自己画的，不是
///     `UIImageView.layer.cornerRadius` 那种改法。
struct LibraryAppearanceGroup: HookGroup {}

/// 资料库这几处的排版常数。
enum LibraryAppearanceMetrics {
    /// 标题放大倍数（在 Spotify 原来的字号上乘）。
    ///
    /// 1.25 是"一眼看得出、又不至于把头部撑爆"的取值：真机 dump 里标题 label 是
    /// `@48,7,72,34`（高 34pt，说明原生已接近 `largeTitle` 偏小的一档），
    /// 再放大 25% 就明显是 AM 那种大标题了。
    static let titleScale: CGFloat = 1.25
}

enum LibraryAppearance {

    static var isEnabled: Bool { UserDefaults.libraryLargeTitle }

    /// 复查节拍。0.5s 与 `DeclutterChrome.reconcileInterval` 同量级：
    /// 足够快（人眼看不到跳变），又不至于每次布局都全树走一遍。
    private static let reconcileInterval: CFAbsoluteTime = 0.5
    private static var lastReconcileAt: CFAbsoluteTime = 0

    // MARK: 施加

    /// 由 hook 在布局时调用（快路径）。幂等。
    @MainActor
    static func apply(to root: UIView?) {
        guard let root else { return }
        note(root)
        reconcile(force: true)
    }

    /// 登记当前这一页。weak —— 页面销毁后自动失效，不用手动摘。
    ///
    /// ⚠️ 页面换了（切走再回来会新建视图）就重记：只认"还在窗口里"的那一个，
    /// 否则复查会一直对着一个已经离屏的旧视图做无用功（第一版的隐患）。
    @MainActor
    static func note(_ root: UIView) {
        if let existing = currentRoot, existing !== root, existing.window == nil {
            currentRoot = root
            lastReconcileAt = 0   // 新页面立刻生效，不等节流
        } else if currentRoot == nil {
            currentRoot = root
        }
        startReconcileTimer()
    }

    private static weak var currentRoot: UIView?

    /// 复查：把该有的改动补齐。**强制档**（`force`）跳过节流，用于开关刚被切换、
    /// 或页面刚出现的时候。
    @MainActor
    static func reconcile(force: Bool = false) {
        guard let root = currentRoot else { return }

        if !isEnabled {
            restore()
            return
        }

        let now = CFAbsoluteTimeGetCurrent()
        if !force, now - lastReconcileAt < reconcileInterval { return }
        lastReconcileAt = now

        applyLargeTitle(in: root)
        flushPendingLayoutInvalidation()
    }

    /// 开关被手动切换时当场落地（设置页调）。
    @MainActor
    static func reconcileNow() {
        reconcile(force: true)
    }

    // MARK: ① 大标题：字号/字重拉到 AM 那一档

    private static weak var titleLabel: UILabel?
    private static var originalFont: UIFont?
    /// 字体被 binder 写回过几次 —— 这个计数决定下一版走哪条路（见文件头说明）。
    private static var fontResetCount = 0
    /// 是否已经成功改过一次（用来区分"还没改"和"被写回"）。
    private static var hasAppliedOnce = false
    private static var didReportPersistentReset = false

    /// AM 的"大标题"比 Spotify 的**更大、更重**。
    ///
    /// ── ⚠️ 这里为什么必须靠复查，而不能只改一次 ────────────────────────────────
    /// 标题是 Encore 的 element（dump 里是 `OBJC_ONLY_Label@48,7,72,34,id=YourLibraryHeader.title`），
    /// 由 binder 驱动。binder 在数据更新时**可能把字体写回** —— 那一瞬间会闪一下我们
    /// 的字号再弹回去。所以这里做两件事：
    ///   1. 每次复查都检查一遍（值不对就再写一次）；
    ///   2. **数一下被写回的次数**并打日志 —— 如果一直在被写回，说明这条路走不通，
    ///      下一版要改成"我们自己画标题"，这是判据不是装饰。
    ///
    /// 顺带说明：**不再改 `textAlignment`**（第一版改过，等于没改）——
    /// 真机 dump 里那个 label 是 `@48,7,72,34`，宽度就是内容宽度，
    /// 对齐哪边都一样，肉眼永远看不出差别。这是"改了个寂寞"的典型。
    private static func applyLargeTitle(in root: UIView) {
        guard let label = titleLabel ?? findTitleLabel(in: root) else { return }
        titleLabel = label

        if originalFont == nil {
            originalFont = label.font
        }
        // ⚠️ `largeTitleFont(from:)` 返回的是**非 Optional** 的 `UIFont`，所以这里不能写
        // `let target = …`（那是给 Optional 用的语法，编译期报
        // "initializer for conditional binding must have Optional type"）。
        guard let original = originalFont else { return }
        let target = largeTitleFont(from: original)

        // 字体被 binder 写回去了吗？（判据：当前点数 ≠ 目标点数）
        //
        // ⚠️ 只在这两种情况认为"被写回"：
        //   · 点数恰好等于**原生**点数（说明它刚被重置回去），或
        //   · 点数既不等于原生也不等于目标（说明别的代码在改它）。
        // 第一次进来时 `label.font === original`，那是"还没改过"，不该算被写回。
        if label.font.pointSize != target.pointSize {
            if label.font.pointSize == original.pointSize, hasAppliedOnce {
                fontResetCount += 1
                if fontResetCount == 1 {
                    writeDebugLog("[Library] ⚠️ 标题字体被写回（第 1 次）— 复查会再写一遍")
                }
            }
            label.font = target
            if !hasAppliedOnce {
                hasAppliedOnce = true
                writeDebugLog(
                    "[Library] 大标题已换成 AM 档：\(Int(original.pointSize))pt → \(Int(target.pointSize))pt"
                )
            }
        } else if fontResetCount > 0, !didReportPersistentReset {
            // 连续被写回：说明这条"改原生字体"的路子在 Encore 的 element 下站不住。
            // 这条日志是"下一版该不该改成自己画标题"的判据。
            if fontResetCount >= 5, !didReportPersistentReset {
                didReportPersistentReset = true
                writeDebugLog(
                    "[Library] ⚠️ 标题字体已被写回 \(fontResetCount) 次 —— element 会持续覆盖它，"
                        + "需要考虑自绘标题"
                )
            }
        }
    }

    /// 在原生字号基础上"放大一档、加重一级"。
    ///
    /// 为什么不写死具体点数：Spotify 的标题字号随语言/动态字体变，写死会让其它语言错位。
    /// 相对放大既保持它的层次，又一眼看得出变大。
    private static func largeTitleFont(from font: UIFont) -> UIFont {
        let size = min(font.pointSize * LibraryAppearanceMetrics.titleScale, 40)
        let weight: UIFont.Weight = font.fontDescriptor.symbolicTraits.contains(.traitBold) ? .bold : .heavy
        return UIFont.systemFont(ofSize: size, weight: weight)
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

    // MARK: ② 顶部那层滚边渐隐 —— **已删除**

    // 这里原来按类名收掉 `Reprise_LiquidGlassKit.LiquidGlass.GradientView` 的 alpha。
    // 真机上它确实生效过（日志 18：`已收掉顶部滚边渐隐 (_TtCO22Reprise_LiquidGlassKit11LiquidGlass12GradientView)`），
    // 但**已经删掉**，两条理由：
    //
    //   1. **肉眼看不出来**：那层本来就极淡，静帧下几乎无差别（用户反馈"没任何改动"）。
    //   2. **它属于"动别人视图"那一类**，与听歌页那段把页面搞到划不动的代码同源。
    //      而且那层是**滚动边缘效果**，Spotify 会随滚动改它的 alpha —— 我们每 0.5 秒
    //      去把它归零，就是在和它的滚动动画对着干，轻则闪烁重则影响滚动。
    //
    // 要收它，前提是确认"它不会随滚动被重新写"，并且只做一次性改动 —— 不是现在。
    //
    // 现在这个开关只剩"大标题字号"一项：那是**改我们看得懂、也碰得起的东西**
    // （一个 `UILabel` 的 font），不动任何布局与滚动机制。

    // MARK: ③ 改了约束就要让 layout 重跑（第一版漏了这步）

    /// 改动**约束常数**之后必须告诉 Auto Layout 重新求解，否则那一处不会生效。
    ///
    /// 第一版只改了值、没调用 `setNeedsLayout()` —— 这是"看起来没任何改动"的一个可能来源。
    /// 这里攒起来，在复查末尾统一触发一次（避免同一帧里反复触发）。
    private static var needsLayoutFlush = false

    /// 对外提供的"记一次待刷新"入口，给未来会改约束的项用。
    static func markLayoutDirty() {
        needsLayoutFlush = true
    }

    private static func flushPendingLayoutInvalidation() {
        guard needsLayoutFlush else { return }
        needsLayoutFlush = false
        currentRoot?.setNeedsLayout()
    }

    // MARK: 复查节拍

    private static var reconcileTimer: Timer?

    private static func startReconcileTimer() {
        guard reconcileTimer == nil else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { _ in
            // Timer 的回调在 main runloop 上；`reconcile` 是 @MainActor，
            // 这里用仓库既有的 `onMainThreadSync` 表达这件事（不自己写 assumeIsolated）。
            onMainThreadSync {
                LibraryAppearance.reconcile()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        reconcileTimer = timer
        writeDebugLog("[Library] 复查节拍已启动 (0.5s) — 这是「改动会生效」的关键，不是可选")
    }

    // MARK: 还原

    @MainActor
    static func restore() {
        if let label = titleLabel, let font = originalFont, label.font.pointSize != font.pointSize {
            label.font = font
        }
        originalFont = nil
        titleLabel = nil
        hasAppliedOnce = false
        // 注：灰纱（`LiquidGlass.GradientView`）那一项已经整段删除（见上面 §②），
        // 所以这里**不再**有 `gradientView` / `originalGradientAlpha` 要还原 ——
        // 第一版删代码时漏删了这两行引用，编译期报 "cannot find … in scope"。
    }

    private static func className(_ view: UIView) -> String {
        NSStringFromClass(type(of: view))
    }
}

// MARK: - Hook

/// 音乐库页：`YourLibrary_YourLibraryXImpl.YourLibraryView`
/// （IPA `_TtC28YourLibrary_YourLibraryXImpl15YourLibraryView` ↔ 真机 dump `18.YourLibraryView`）。
///
/// 用 `layoutSubviews` 做**快路径**（页面出现时立刻生效），**不指望它每次都跑** ——
/// 真正的保障是上面那个复查节拍。
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
        "[Library] 音乐库改原生 installed (header="
            + "\(UserDefaults.libraryLargeTitle ? "ON" : "OFF"))"
    )
}
