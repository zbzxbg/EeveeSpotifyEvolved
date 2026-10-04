import Foundation
import Orion
import UIKit
import ObjectiveC.runtime

/// 音乐库（Your Library）的「改原生」第一批 —— 不是加层，是**改 Spotify 自己的视图**。
///
/// ── 2026-10-12 这一批的分工（**Apple Music 那一档的观感**，用户点名"要 AM 的优雅感"）──
/// Apple Music 音乐库的解构（公开 App + HIG 的 token，见交接文档 §9）：**贴左的大标题（32pt/800）**、
/// 标题行右端一颗（Edit；iOS 26 是头像）、标题下面一整行**筛选 chips**、区块标题（18pt/800）、
/// 行 = 小圆角封面（6pt 连续）+ 主标题/灰色元信息、分隔线**从文字左沿起**、侧边距 16–18pt。
/// 落到 Spotify 自己的视图上就是三片（**同一个开关**，关掉各自精确还原）：
///   · **本文件**：头部 —— ① 大标题字号、③ 标题贴左 + 头像/按钮贴右、④ 收掉顶部灰纱、
///     ⑤ 收掉右侧那条**快速滚动条**（照片 84）；
///   · `LibraryRowsAppearance.x.swift`：列表行/网格卡片 —— 封面连续圆角（6/8pt）+ 行间发丝线；
///   · `LibrarySearchAppearance.x.swift`：库内搜索页 —— 搜索框与 Cancel 变胶囊 + 收灰纱。
///
/// ── ★ 2026-10-12 真机日志 64 核实过的事实（别再猜）────────────────────────────
/// ```
/// [Tree] #8 16.YourLibraryHeaderView@0,0,414,148
/// [Tree] #8 21.AutoLayoutStackView@8,0,402,48                       ← 标题那一行
/// [Tree] #8 21.OBJC_ONLY_Label@48,6,86,36,id=YourLibraryHeader.title
/// [Tree] #8 22.UILabel@-40,0,86,36,id=YourLibraryHeader.title-internal   ← ★ 位移写在**里层** UILabel 上
/// [Tree] #8 21.AdaptiveFaceContainer@350,0,48,48                    ← 头像在最右 ✓
/// [Tree] #8 21.EncoreButton@254,0,48,48,id=YourLibraryHeader.search  / @302 …plus   ← 靠右打包 ✓
/// [Tree] #8 17.QuickScrollView@0,0,414,896 + QuickScrollIndicator/@Handle（§⑤ 收掉）
/// [Tree] #8 23.ImageView@0,0,116,116,id=Components.UI.CardLibrary.Artwork          ← 卡片封面 id **存在**
/// ```
/// ⚠️ 两条由此得出的教训：
///   1. `YourLibraryHeader.title` 那串 id 挂在 **Encore 的包装视图**上，而**真正的 `UILabel` 是里层的
///      `.title-internal`**（`findTitleLabel` 命中后者）⇒ 字号与位移都写在里层，**看日志要看 `.title-internal` 那一行**；
///   2. 网格里那几颗 116×143 的**占位卡**（`Components.UI.AddArtistCardLibrary` / `AddPodcastCardLibrary` /
///      `AddEventCardLibrary` / `ImportMusicCardLibrary`）**本来就没有封面** ⇒ 上一版对它们报的
///      "no row artwork id" 是**假警报**（`LibraryRowsAppearance` 里已经改掉）。
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
/// ⚠️ 已经做掉的（旧版的"留到下一批"清单，别再照抄）：**大标题字号**在 §①（真机验过、没被 binder 写回）；
///    **列表行的封面圆角 / 发丝分隔线**在 `LibraryRowsAppearance.x.swift`（2026-10-12 补上）。
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
        // ⚠️ 灰纱**只在这一条快路径里收**（= 页面/头部自己的布局回合），**绝不进 0.5s 节拍** ——
        //    Spotify 会随滚动改它，每 0.5 秒强写一次就是在和滚动动画对着干（§② 记的就是那次教训）。
        if let header = headerView ?? findHeader(in: root) {
            headerView = header
            clearTopEdgeScrim(in: header)
        }
        hideQuickScroll(in: root)
        // ⑥ 顶部那块毛玻璃：**用公开 API 关掉它自己的效果**（不是去涂那一层视图）。
        hideTopEdgeEffect(in: root)
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
        placeHeaderControls(in: root)
        hideQuickScroll(in: root)
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
                    writeDebugLog("[Library] ⚠️ title font was written back (1st time) - reconcile will write it again")
                }
            }
            label.font = target
            if !hasAppliedOnce {
                hasAppliedOnce = true
                writeDebugLog(
                    "[Library] large title switched to the AM tier: \(Int(original.pointSize))pt → \(Int(target.pointSize))pt"
                )
            }
        } else if fontResetCount > 0, !didReportPersistentReset {
            // 连续被写回：说明这条"改原生字体"的路子在 Encore 的 element 下站不住。
            // 这条日志是"下一版该不该改成自己画标题"的判据。
            if fontResetCount >= 5, !didReportPersistentReset {
                didReportPersistentReset = true
                writeDebugLog(
                    "[Library] ⚠️ title font has been written back \(fontResetCount) times - the element keeps overriding it, "
                        + "so drawing our own title needs to be considered"
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

    // MARK: ③ 头部重排：标题靠左、头像与按钮靠右（2026-10-12）

    /// 这一条照 pw 的 `Redesigned/Library/LibraryHeader.x` —— **同一个信号、同一套 id**：
    /// 9.1.88 那份解密 IPA 里逐字都有 `YourLibrary_YourLibraryXImpl.YourLibraryHeaderView`、
    /// `YourLibrary_CommonKit.YourLibraryHeaderContentFiltersView`、
    /// `ListeningActivity_ElementsKit.AdaptiveFaceContainer`（见 `dump-9.1.88.txt`）。
    ///
    /// 真机结构（pw 的树 + 我们自己的 dump 对得上）：
    /// ```
    /// YourLibraryHeaderView
    /// ├ LiquidGlass.GradientView                       ← 顶部那层灰纱（§④ 收掉）
    /// ├ AutoLayoutStackView，48pt 高的一行
    /// │  ├ AdaptiveFaceContainer    id=Components.UI.SideDrawerButton  ← 头像（挪到最右）
    /// │  ├ YourLibraryHeader.title                                    ← 标题（挪到左沿）
    /// │  ├ (spacer)
    /// │  ├ YourLibraryHeader.recents （这个账号上隐藏）
    /// │  ├ YourLibraryHeader.search
    /// │  └ YourLibraryHeader.plus
    /// └ YourLibraryHeaderContentFiltersView            ← 筛选 chips：**原样保留，一个字不动**
    /// ```
    ///
    /// ── 为什么用 transform，而不是 frame ────────────────────────────────────
    /// 那一行是 Spotify 自己的 stack，每拍按约束摆一遍；而 **Auto Layout 只写 center 与 bounds、
    /// 不碰 transform** ⇒ 位移能活过它那一拍（pw 的原话就是这个）。位移一律从"布局摆出来的位置"
    /// 算（`center` 不受 transform 影响，`frame` 会）⇒ **幂等**：值没变一个字节都不写。
    ///
    /// ⚠️ 这一行全是 **arranged subview**：**绝不能把谁从 stack 里摘掉**
    /// （pw 的注释：摘一颗会让那个 stack 卡在 `updateConstraints` 里）—— 所以这里只有位移，没有移除。

    /// 右侧留边（pw 的 `kRowInset` = 8）：48pt 的按钮贴到右沿时，它 24pt 的字形离屏 20pt。
    private static let headerRowInset: CGFloat = 8
    /// 左侧留边（pw 的 `SGRSideMargin` = 16）。
    private static let headerSideMargin: CGFloat = 16
    /// 靠右打包的次序（读起来从左到右）；**头像排在最后 = 最右**，与 pw 的 Home/Library 一致。
    private static let headerTrailingIdentifiers = [
        "YourLibraryHeader.recents",
        "YourLibraryHeader.search",
        "YourLibraryHeader.plus",
    ]
    private static let adaptiveFaceClassName = "ListeningActivity_ElementsKit.AdaptiveFaceContainer"

    private static weak var headerView: UIView?
    private static let movedHeaderControls = NSHashTable<UIView>.weakObjects()
    private static var didLogHeaderRestyle = false

    @MainActor
    private static func placeHeaderControls(in root: UIView) {
        guard let header = headerView ?? findHeader(in: root) else { return }
        headerView = header
        moveHeaderControls(in: header)
    }

    private static func findHeader(in view: UIView) -> UIView? {
        if className(view).contains("YourLibraryHeaderView") { return view }
        for sub in view.subviews {
            if let found = findHeader(in: sub) { return found }
        }
        return nil
    }

    @MainActor
    private static func moveHeaderControls(in header: UIView) {
        guard header.bounds.width > 1 else { return }

        // ① 标题贴左沿。标题仍然是 **Spotify 自己那一个**（我们只放大过它的字号，见 §①）——
        //    不像 pw 那样另画一个：那条路要连字号/字重一起自己负责，而"字号"这一项我们已经验过。
        if let title = titleLabel ?? findTitleLabel(in: header) {
            titleLabel = title
            place(title, atLeading: headerSideMargin, in: header)
        }

        // ② 头像与按钮一起贴右沿打包，头像在最右。
        var trailing: [UIView] = []
        for identifier in headerTrailingIdentifiers {
            guard let control = findView(in: header, where: { $0.accessibilityIdentifier == identifier }),
                  !control.isHidden, control.alpha > 0.01, control.bounds.width > 1 else { continue }
            trailing.append(control)
        }
        if let face = findView(in: header, where: { className($0) == adaptiveFaceClassName && $0.bounds.width > 1 }) {
            trailing.append(face)
        }
        guard !trailing.isEmpty else { return }

        var right = header.bounds.width - headerRowInset
        for control in trailing.reversed() {
            let width = control.bounds.width
            place(control, atLeading: right - width, in: header)
            right -= width
        }

        if !didLogHeaderRestyle, header.window != nil {
            didLogHeaderRestyle = true
            writeDebugLog(
                "[Library] header restyled — the title sits at the leading edge, \(trailing.count) control(s) packed at the trailing edge"
                    + " (rightmost: \(trailing.last.map { className($0) } ?? "none"))"
            )
        }
    }

    /// 用 transform 把一颗控件挪到"相对头部左沿 = target"的位置。**幂等**。
    private static func place(_ control: UIView, atLeading target: CGFloat, in header: UIView) {
        guard let host = control.superview else { return }
        // ⚠️ 用 `center`（Auto Layout 摆出来的那个，transform 改不动它），**不要用 `frame`**
        //    （transform 一上，frame 就未定义了）。
        let hostOriginX = host.convert(CGPoint.zero, to: header).x
        let naturalLeading = hostOriginX + control.center.x - control.bounds.width / 2
        let move = CGAffineTransform(translationX: target - naturalLeading, y: 0)
        if control.transform != move { control.transform = move }
        if !movedHeaderControls.contains(control) { movedHeaderControls.add(control) }
    }

    // MARK: ④ 顶部灰纱（只在这条快路径里收，见 `apply`）

    /// 我们收过的灰纱（弱引用）+ 各自原 alpha 的关联键（原值记在视图自己身上）。
    private static let touchedScrims = NSHashTable<UIView>.weakObjects()
    private static var originalScrimAlphaKey: UInt8 = 0

    /// 收掉某个头部顶上那层滚边灰纱（`LiquidGlass.GradientView`）。**幂等**。
    ///
    /// ⚠️ 只在**页面/头部的布局回合**里写（`apply` 调），**不进 0.5s 节拍** —— 见 §②的账：
    ///    那层是**滚动边缘效果**，Spotify 随滚动改它的 alpha，每 0.5 秒归零就是在和滚动动画对着干。
    ///    现在这样与 pw 等价（他也是只在头部那一拍清一次），而且值已经是 0 就**一个字节都不写**。
    ///
    /// 音乐库页与**库内搜索页**各有自己的一层 ⇒ 判据只写这一份，原 alpha 记在**那层视图自己身上**
    /// （关联对象），还原走一张弱表。
    @MainActor
    static func clearTopEdgeScrim(in header: UIView) {
        guard let scrim = findView(in: header, where: { className($0).contains("GradientView") }) else { return }
        if objc_getAssociatedObject(scrim, &originalScrimAlphaKey) == nil {
            objc_setAssociatedObject(
                scrim,
                &originalScrimAlphaKey,
                NSNumber(value: Double(scrim.alpha)),
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
            touchedScrims.add(scrim)
            writeDebugLog(
                "[Library] the top edge scrim is off — \(className(scrim))"
                    + " (written on a layout pass only, never on the 0.5s tick: it follows the scroll)"
            )
        }
        if scrim.alpha != 0 { scrim.alpha = 0 }
    }

    // MARK: ⑥ 顶部那块"毛玻璃"（iOS 26 的滚动边缘效果）

    /// 真机树（日志 64 的 dump #8/#9）：
    /// ```
    /// 19.BackdropView@0,0,414,188
    /// 19.ScrollEdgeEffectView@0,0,414,188   ← ★ 顶部那块毛玻璃（#8 可见、#9 alpha=0.00 ⇒ 随滚动淡入淡出）
    /// ```
    /// 用户 2026-10-12：「音乐库页面顶部似乎有一块毛玻璃。这个毛玻璃可以去掉，但是**那上面的功能都需要还在**」。
    ///
    /// ★★ **用公开 API，不去涂那一层**：iOS 26 起 `UIScrollView` 有 `topEdgeEffect`
    /// （`UIScrollEdgeEffect`，`isHidden` 可写）—— 那正是系统画这块毛玻璃的开关。所以：
    /// **只关效果**，标题 / 头像 / 搜索 / 加号 / 筛选 chips **一个都不动、全都能用**。
    /// 「涂掉 `ScrollEdgeEffectView` 的 alpha」是野路子：它随滚动自己淡入淡出，涂了就是和它的动画打架
    /// （灰纱那笔账 §②，别再犯）。
    ///
    /// ⚠️ 代价（要跟用户说清楚）：**没有那层模糊之后，列表内容会直接从标题底下划过**（字压在内容上）。
    /// 想要"看着干净、又不糊"的折中，可以在这层下面垫一条我们自己的极淡渐隐 —— 那是另一件事。
    ///
    /// ⚠️ 只作用于**音乐库这一页的列表**（`YourLibraryContent.collectionView`）；主页/搜索页各有自己的列表，
    /// 要一起关得在各自的开关里再来一次（一行）。
    private static weak var edgeEffectList: UIScrollView?

    @MainActor
    static func hideTopEdgeEffect(in root: UIView) {
        guard #available(iOS 26.0, *) else { return }
        guard let list = (edgeEffectList ?? findLibraryList(in: root)) else {
            noteSkipOnce("no library collection view yet - the top edge effect is still the system's")
            return
        }
        edgeEffectList = list
        guard !list.topEdgeEffect.isHidden else { return }
        list.topEdgeEffect.isHidden = true
        writeDebugLog(
            "[Library] the top edge effect is gone — scrollView.topEdgeEffect.isHidden = true"
                + " (public API; the title, the avatar, search, plus and the filter chips are untouched and keep working)"
        )
    }

    private static func findLibraryList(in root: UIView) -> UIScrollView? {
        findView(in: root, where: {
            ($0 as? UIScrollView)?.accessibilityIdentifier == "YourLibraryContent.collectionView"
        }) as? UIScrollView
    }

    /// 有界找第一个满足条件的视图（找不到就 nil；只在头部子树里用，别拿它扫整页）。
    static func findView(in view: UIView, where matches: (UIView) -> Bool) -> UIView? {
        if matches(view) { return view }
        for sub in view.subviews {
            if let found = findView(in: sub, where: matches) { return found }
        }
        return nil
    }

    // MARK: ⑤ 右侧那条"快速滚动条"（可拖动、拖动时显示分组名）

    /// 真机证据（日志 64 的 `[Tree]`；照片 84 拍到的就是它）：
    /// ```
    /// 17.QuickScrollView@0,0,414,896                                   ← 整页覆盖层（与 collection view 平级）
    /// ├ 18.QuickScrollIndicator@244,654,90,28,bg=#262626,id=quickscroll.indicator  ← 拖动时那个日期气泡
    /// └ 18.QuickScrollHandle@381,644,48,48,bg=#262626,id=quickscroll.handle        ← 右边那颗可拖的圆把手
    /// ```
    /// 用户 2026-10-12：「音乐库在划动的过程中，右边会有个可以拖动的小条（图片 84）**这个条子可以隐藏吗**」。
    ///
    /// ── 为什么是"从父视图里拿走"，不是 `alpha = 0` ───────────────────────────────
    /// 它本来就会**随滚动自己显形/隐藏**（日志 64 里它有时 `hidden,alpha=0.00`、有时可见）
    /// ⇒ "每拍写一次 alpha"会和它的显示动画打架（灰纱那笔账的翻版，§②）。
    /// 拿走之后它再也显不出来，而且**它那块不再吃手势** —— "可拖动"也就一起关掉了（用户要的就是这个）。
    /// ⚠️ 记原父视图与下标，关开关时**按原位放回**。
    private static let removedQuickScroll = NSHashTable<UIView>.weakObjects()
    private static var quickScrollRestoreKey: UInt8 = 0
    private static var didReportQuickScroll = false

    private final class QuickScrollPlacement: NSObject {
        weak var parent: UIView?
        let index: Int
        init(parent: UIView?, index: Int) {
            self.parent = parent
            self.index = index
        }
    }

    @MainActor
    static func hideQuickScroll(in root: UIView) {
        guard let view = findView(in: root, where: { className($0).contains("QuickScroll") }) else { return }
        guard !removedQuickScroll.contains(view), let parent = view.superview else { return }
        let index = parent.subviews.firstIndex(of: view) ?? 0
        objc_setAssociatedObject(
            view,
            &quickScrollRestoreKey,
            QuickScrollPlacement(parent: parent, index: index),
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
        removedQuickScroll.add(view)
        view.removeFromSuperview()
        if !didReportQuickScroll {
            didReportQuickScroll = true
            writeDebugLog(
                "[Library] the quick-scroll scrubber is off — \(className(view))"
                    + " (taken out of the page, so nothing can bring it back; switching the toggle off puts it back)"
            )
        }
    }

    /// 放回原位（关开关 / 页面走了）。
    @MainActor
    private static func restoreQuickScroll() {
        for view in removedQuickScroll.allObjects {
            guard let placement = objc_getAssociatedObject(view, &quickScrollRestoreKey) as? QuickScrollPlacement,
                  let parent = placement.parent else { continue }
            parent.insertSubview(view, at: min(placement.index, parent.subviews.count))
            objc_setAssociatedObject(view, &quickScrollRestoreKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        removedQuickScroll.removeAllObjects()
        didReportQuickScroll = false
    }

    // MARK: ② 顶部那层滚边渐隐 —— 的历史（**现在在 §④**，别把这段当"不许做"）

    // v1 按类名收掉 `Reprise_LiquidGlassKit.LiquidGlass.GradientView` 的 alpha，真机生效过
    // （日志 18：`已收掉顶部滚边渐隐 (…LiquidGlass12GradientView)`），但那一版**被删掉了**，两条理由：
    //
    //   1. **肉眼看不出来**：那层本来就极淡，静帧下几乎无差别（用户当时反馈"没任何改动"）——
    //      所以 2026-10-12 这一版**把标题也挪到左沿**（§③），不再是"只收一层看不见的纱"；
    //   2. **它属于"动别人视图"那一类**：那层是**滚动边缘效果**，Spotify 会随滚动改它的 alpha，
    //      而 v1 是**每 0.5 秒**去把它归零 ⇒ 在和滚动动画对着干，轻则闪烁重则影响滚动。
    //
    // ⇒ 2026-10-12 的复刻（§④）把频率这一条钉死了：**只在页面/头部自己的布局回合写一次**
    //    （`apply` 那条快路径），**绝不进 0.5s 节拍**，且值已是 0 就一个字节都不写 —— 与 pw 等价。
    //
    // ⚠️ 这一次也只碰"alpha 与 transform"这两样能精确还原的东西；**布局与滚动机制一个字不动**
    //    （标题/头像/按钮全都是**位移**，不是改约束）。

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
        writeDebugLog("[Library] reconcile timer started (0.5s) - this is what makes the changes stick, not optional")
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

        // ③ 头部重排：位移回 0（那就是 Auto Layout 摆的位置）。
        for control in movedHeaderControls.allObjects where control.transform != .identity {
            control.transform = .identity
        }
        movedHeaderControls.removeAllObjects()

        // ④ 灰纱：写回**它自己原来的** alpha（不是一律写 1 —— 它随滚动变，原值可能就不是 1），
        //    然后把"记过账"这件事抹掉（关联对象也清）：下次再开开关时它是**新记的一次**，
        //    日志也会重新报一行（"只报一次"的旗子现在挂在关联对象上，不再是一个 static bool ——
        //    2026-10-12 那次编译错误就是漏删了旧的 `didReportScrim`）。
        for scrim in touchedScrims.allObjects {
            if let original = objc_getAssociatedObject(scrim, &originalScrimAlphaKey) as? NSNumber {
                scrim.alpha = CGFloat(original.doubleValue)
            }
            objc_setAssociatedObject(scrim, &originalScrimAlphaKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        touchedScrims.removeAllObjects()

        // ⑤ 快速滚动条：按原位放回。
        restoreQuickScroll()

        // ⑥ 毛玻璃：把系统那个开关还回去（我们只关过它一次，写回 false 就是原值）。
        if #available(iOS 26.0, *), let list = edgeEffectList, list.topEdgeEffect.isHidden {
            list.topEdgeEffect.isHidden = false
        }
        edgeEffectList = nil

        didLogHeaderRestyle = false
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
    // 三片各自一个 hook（头部在这里，行与库内搜索在各自文件里），**同一个 group** ⇒ 这里一次激活。
    // ⚠️ 缺哪个就照实报哪个：只有"一个都没有"才整个不装（少一片不该把另外两片也拖下水）。
    let targets = [
        LibraryAppearanceHook.targetName,
        LibraryRowStyleHook.targetName,
        LibrarySearchStyleHook.targetName,
    ]
    let missing = targets.filter { NSClassFromString($0) == nil }
    if missing.count == targets.count {
        writeDebugLog("[Library] missing \(missing.joined(separator: ", ")) — hook inactive")
        return
    }

    LibraryAppearanceGroup().activate()
    writeDebugLog(
        "[Library] library native restyle installed (switch="
            + "\(UserDefaults.libraryLargeTitle ? "ON" : "OFF"))"
            + " — header: title font + title leading + avatar trailing + scrim off;"
            + " rows: continuous corners + hairline; in-library search: capsules"
            + (missing.isEmpty ? "" : " (missing targets: \(missing.joined(separator: ", ")))")
    )
}
