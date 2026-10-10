import Foundation
import UIKit

/// 「专辑 / 歌单页头」——把 Spotify 的页头换成 Apple Music 式的版本。
///
/// ## 出处
///
/// 借鉴 **spoti.pw v0.21.1** 的 `Redesigned/Kit/SGRHeaderInfo.{h,m}` 与
/// `Redesigned/Playlist/PlaylistHeader.x`（该版本为 **GPL-3.0**；其 v0.22.0 起改为
/// PolyForm Strict，**那里的代码不可复制**）。这里是**按它的判断重写的 Swift 实现**，
/// 不是逐行翻译 —— 目标类与标识符全部用**我们自己真机日志** + `dump-9.1.88.txt` 重新核对。
///
/// ## 形态（Music app 的专辑 / 歌单页）
///
/// ```
///              标  题          ← 居中、粗体、最多 2 行
///            创 建 者          ← 居中、次要色
///         8 首歌 · 41 分钟      ← 居中、三级色（Spotify 自己那行原文）
///         ──────────────      ← 16pt
///      [shuffle] (  ▶ Play  )  [尾随]
///         ──────────────      ← 14pt
///           描 述             ← 自然对齐、最多 2 行
/// ```
/// 整块**贴底排**（内容底边距视图底 14pt）—— 这样标题与创建者正好压在封面的"溶解"边上，
/// 而封面要伸到内容顶部往下 56pt（`titleRise`，给 hero 用）。
///
/// ## 三条关键取舍（都是 pw 的判断）
///
/// 1. **不摆 Spotify 的控件，整列藏掉自己画**：摆它的列就要回应它每一拍的 stack 重排与
///    Auto Layout 写回，实测会被改回去。
/// 2. **按钮"镜像 + 转发"**：字形取自被藏起来的 Spotify 控件（取不到用 SF Symbol 兜底），
///    点击 `sendActions` 转发给那个控件 ⇒ 动作 / 状态 / 语言都留在 Spotify 那边。
/// 3. **只有文字真正画到的地方吃触摸**：这块和页面一样宽，其余部分必须让下拉与点击穿过去。
///
/// ## 安全阀
///
/// **认不出标题就整块不动**（`apply` 早退，一个视图都不藏）。所以任何一环失配的结果是
/// "这个功能没生效"，而不是"歌单页坏了"。每一步都会在调试日志里留一行。
enum EntityPageHeaderMetrics {
    static let side: CGFloat = 20           // 文字左右内缩
    static let playMinWidth: CGFloat = 148  // Play 胶囊最小宽度（Music app 的）
    static let rowSpacing: CGFloat = 16
    static let rowAbove: CGFloat = 16       // 文字与按钮行之间
    static let aboutAbove: CGFloat = 14     // 按钮行与描述之间
    static let bottom: CGFloat = 14         // 内容底边距视图底
    static let titleRise: CGFloat = 56      // 封面要伸到内容顶部往下这么多（hero 用）
    /// ★ 2026-10-13（用户给了 8 张 AM 艺人页，photo_1/3/5/7）：三颗的**尺寸关系**照 Apple Music 来
    /// —— 两侧是**小圆**（`ⓘ` 与 `☆`，≈56pt），中间是**大一档的圆**（纯白 `▶`，≈80pt）。
    /// 原来是 pw 的"两颗 44 圆 + 一颗 148×48 的白胶囊"；现在中间那颗**从胶囊变成圆**（去掉"播放"二字）。
    static let rowHeight: CGFloat = 56      // = 两侧小圆的直径
    static let playSide: CGFloat = 84       // = 中间那颗粒子的直径
    /// ★ 2026-10-13（照 AM）：页头**右上角那颗 `⋯`** 的直径 —— AM 在同一位置放一颗"分享 + ⋯"的
    /// 玻璃胶囊，与左上角的返回键同高。
    static let pinnedMoreSide: CGFloat = 44
    /// 两侧按钮那圈**玻璃圆**的直径（= pw 的 `SGRGlassCircleSize`）。
    static let glassCircle: CGFloat = 44
    /// 两侧按钮的字形边长。★ 2026-10-13（用户看真机：「旁边的按键小了点」）：
    /// 原来是"按 48pt 的 27% 内缩"≈26pt，看着比中间那颗胶囊轻 —— pw 是 44pt 玻璃圆里放字形，
    /// 所以这里改成**固定字形 + 44pt 玻璃圆**，与 Music app 的分量对齐。
    /// ★ 同日再调（用户：「这播放旁边的播放图标太小了吧」）：22 → **24**。
    static let glyphSide: CGFloat = 24
}

/// 浅色玻璃（Play 胶囊里那片）。**探测式**，与 `GlassCapsule.makeGlassView` 同一套手法
/// —— 那一条是给深色标签栏用的（材质兜底是 dark），这颗胶囊要浅色，所以另开一个：
/// iOS 26 有 `UIGlassEffect` 就用真玻璃（带折射与边缘高光），否则退浅色材质。
///
/// 返回的视图**不吃触摸**（它只是底），点击由外面的 `UIControl` 收。
private func eeveeMakeLightGlassView(interactive: Bool) -> UIVisualEffectView {
    let view = UIVisualEffectView(effect: nil)

    if let glassType = NSClassFromString("UIGlassEffect") as? UIVisualEffect.Type {
        let effect = glassType.init()
        // `isInteractive` 要先探 getter/setter 再写 —— KVC 碰未知 key 会抛异常（崩）。
        if interactive, let object = effect as? NSObject,
           object.responds(to: NSSelectorFromString("isInteractive")),
           object.responds(to: NSSelectorFromString("setInteractive:")) {
            object.setValue(true, forKey: "interactive")
        }
        view.effect = effect
    } else {
        view.effect = UIBlurEffect(style: .systemUltraThinMaterialLight)
    }

    view.isUserInteractionEnabled = false
    view.clipsToBounds = true
    view.layer.cornerCurve = .continuous
    view.layer.borderWidth = 0.75
    view.layer.borderColor = UIColor.white.withAlphaComponent(0.32).cgColor
    return view
}

/// 造一个"里面嵌着玻璃"的容器（pw 的 `SGRGlassInside` / `SGRGlassCapsuleInside` 同一件事）。
/// 玻璃铺满、圆角跟着容器；返回玻璃视图，调用方在 `layoutSubviews` 里让它跟着 bounds 走。
private func eeveeInsertGlass(in host: UIView, interactive: Bool) -> UIVisualEffectView {
    let glass = eeveeMakeLightGlassView(interactive: interactive)
    glass.frame = host.bounds
    glass.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    host.insertSubview(glass, at: 0)
    return glass
}

// MARK: - 藏 / 找 / 点

/// 把 Spotify 的视图**藏死**。三个动作缺一不可：
///
///   · **改 `layer.isHidden`，不碰 `view.isHidden`** —— Spotify 自己会 `setHidden:NO` 把东西
///     显示回来（改层挡得住），而且 Encore 的 stack 在 arranged view 被 `hidden` 时可能在
///     `updateConstraints` 里 trap；
///   · **空 mask** —— Spotify 不碰 mask，被空 mask 罩住的层什么都不画，这是第二道保险；
///   · 关交互 + 关无障碍（藏掉的东西不该再能被点到或读屏读到）。
///
/// 幂等，每一拍调都行。
func eeveeConceal(_ view: UIView?) {
    guard let view else { return }
    if !view.layer.isHidden { view.layer.isHidden = true }
    if view.layer.mask == nil { view.layer.mask = CALayer() }
    if view.isUserInteractionEnabled { view.isUserInteractionEnabled = false }
    view.accessibilityElementsHidden = true
}

/// **只加空 mask** 的藏法：视图什么都不画，但 `layer.isHidden` / `view.isHidden` 一个都不碰。
///
/// ★ 2026-10-13（艺人页）：什么时候必须用它 —— 视图在 **`OverflowStackView`** 里的时候。
/// pw 在艺人页踩过这个真机崩溃，注释逐字：
///
/// > `ios-creator-impl.context_menu_in_navigation_bar_enabled_artist` moves more out of the header's
/// > row, and with it gone Spotify's OverflowStackView force-unwraps the tallest view of a line that
/// > has none and **traps as the page opens** (device crash 2026-09-18 19:09,
/// > **SIGTRAP in -[OverflowStackView updateConstraints]**).
///
/// 空 mask 本身就让视图什么都不画，所以这里少一道 `hidden` 只是少一道保险，**不会漏**。
func eeveeBlank(_ view: UIView?) {
    guard let view else { return }
    if view.layer.mask == nil { view.layer.mask = CALayer() }
    if view.isUserInteractionEnabled { view.isUserInteractionEnabled = false }
    view.accessibilityElementsHidden = true
}

/// 深度优先找第一个（含自身）无障碍 id 匹配的视图。`identifier` 末尾写 `*` 表示前缀匹配
/// —— Spotify 有些 id 带后缀（如 `DownloadButton.Granular*`、`Components.Header.UI.Metadata*`）。
func eeveeFindView(_ root: UIView?, identifier: String, maxNodes: Int = 5000) -> UIView? {
    guard let root else { return nil }
    let isPrefix = identifier.hasSuffix("*")
    let needle = isPrefix ? String(identifier.dropLast()) : identifier

    var queue: [UIView] = [root]
    var visited = 0
    while !queue.isEmpty, visited < maxNodes {
        let view = queue.removeFirst()
        visited += 1
        if let id = view.accessibilityIdentifier, !id.isEmpty {
            if isPrefix ? id.hasPrefix(needle) : id == needle { return view }
        }
        queue.append(contentsOf: view.subviews)
    }
    return nil
}

/// 按**类名片段**找第一个（含自身）视图。
///
/// ★★ 2026-10-17：为什么必须有它 —— 艺人页的"关于艺人"是 **`SPTArtistAboutBiographyView`**
/// （真机树：`[Tree] #9 17.SPTArtistAboutBiographyView@16,82,382,1126`，与 `id=creator-page`
/// **同一棵树**；382 = 414−32，就是列表行的内缩，日志里量到过 `382,70` 收起 / `382,1126` 展开
/// 两种高度）。这种老 `SPT*` 视图**一个 accessibility id 都没有** ⇒ 按 id 永远找不到它
/// （日志 94 的 `leading none` 就是这么来的）。
func eeveeFindView(_ root: UIView?, classNameContains needle: String, maxNodes: Int = 5000) -> UIView? {
    guard let root else { return nil }
    var queue: [UIView] = [root]
    var visited = 0
    while !queue.isEmpty, visited < maxNodes {
        let view = queue.removeFirst()
        visited += 1
        if NSStringFromClass(type(of: view)).contains(needle) { return view }
        queue.append(contentsOf: view.subviews)
    }
    return nil
}

/// 把一个视图滚进它所在那个 `UIScrollView` 的视野。
///
/// ★★ 2026-10-17（用户：「点击（`i`）后**跳转到关于艺人模块**」）：艺人页的"关于"在列表很下面
/// （真机树里那一块展开后 1126pt 高），只把点击转发过去、**不滚动**的话用户什么都看不见 ——
/// 那个东西确实展开了，但不在屏幕上。
@discardableResult
func eeveeScrollIntoView(_ view: UIView, topPadding: CGFloat = 24) -> Bool {
    var node: UIView? = view.superview
    while let current = node {
        if let scroll = current as? UIScrollView {
            let target = view.convert(view.bounds, to: scroll).insetBy(dx: 0, dy: -topPadding)
            scroll.scrollRectToVisible(target, animated: true)
            return true
        }
        node = current.superview
    }
    return false
}

/// 从 `view` 往上找**最外层** `UIScrollView`，往下滚一屏。
///
/// ★★ 2026-10-17：给艺人页那颗 `i` 兜底 —— "关于艺人"（`SPTArtistAboutBiographyView`）是列表里
/// 懒加载的一段，页面刚打开时可能还没建出来。这时候点 `i`：**不许退回去做随机播放**，而是把页面
/// 往下滚一屏，让那一段被建出来；下一拍 `fireTarget` 就有了，再点就是"滚过去 + 展开"。
@discardableResult
func eeveeScrollPageDown(from view: UIView) -> Bool {
    var outermost: UIScrollView?
    var node: UIView? = view.superview
    var levels = 0
    while let current = node, levels < 24 {
        levels += 1
        if let scroll = current as? UIScrollView { outermost = scroll }
        node = current.superview
    }
    guard let scroll = outermost, scroll.bounds.height > 1 else { return false }
    let bottom = max(0, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
    let next = min(bottom, scroll.contentOffset.y + scroll.bounds.height)
    guard next > scroll.contentOffset.y + 1 else { return false }
    scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: next), animated: true)
    return true
}

/// 以"点一下"的方式触发 Spotify 自己的控件。**返回真正走通的那条路**（`nil` = 一条都没通）。
///
/// ## 为什么返回值是"路"而不是 Bool（这是被真机打回来的第二次）
///
/// ★★★ 2026-10-06（日志 93：**几百行** `shuffle tapped — source found`，而随机播放毫无动静）：
/// 旧版第一句是 `guard let control = control as? UIControl else { return false }` —— Spotify 的
/// shuffle / play 是 `Encore.Button` 一族（点击挂在 `UITapGestureRecognizer` 上）⇒ 这一句把转发
/// 整个吞掉；返回值又没人看 ⇒ **"日志说转发成功了、界面一动不动"**。
///
/// ★★★ 2026-10-17（用户真机第二轮：「艺人页 / 歌单页的**点击播放**按键没反应」「艺人页左边那颗
/// 应该是 `i`…但现在是歌单的**随机播放**按钮，并且点击没反应」）—— 同样的现场**又复现了**。
/// 这一版把三件事一起做掉：
///
///   ① **UIControl 也要先看有没有 target**：没有 target 的 `UIControl`（`Encore.Button` 正是
///      如此）`sendActions` 是**空转**，而旧代码会因此 `return true`，把后面那条手势路一起挡掉。
///   ② **包装层要往下钻**：按 id 找到的常常是 `ElementView<URL, Any, Any>` 那层包装
///      （本文件 `firstControl` 的注释早就写了），真控件在它里面。调用方现在统一先 `findControl`
///      钻一次，这里再补一道"子树里找手势"。
///   ③ **tap recogniser 可能挂在子树里的某个视图上**，不在我们拿到的那一层。
///
/// ⚠️ **只走通一条就返回** —— 两条都发 = 一次点击触发两次（等于没点）。
@discardableResult
func eeveeFire(_ control: UIView?) -> String? {
    guard let control else { return nil }

    // ① 真·UIControl **且确实注册了 target** ⇒ 发那一个事件（顺序按"最可能的"排）。
    if let uiControl = control as? UIControl {
        for (event, label) in eeveeFireEvents where eeveeHasTargets(uiControl, event) {
            uiControl.sendActions(for: event)
            return "UIControl.\(label)"
        }
    }

    // ② 手势：先自己，再（有界地）往下钻子树。
    return eeveeFireGesture(in: control)
}

/// `sendActions` 候选事件。**顺序有讲究**：`primaryActionTriggered` 是 iOS 14+ 那个"主操作"
/// 事件，Spotify 的 Encore 按钮注册的多半是它；`touchUpInside` 是经典那颗。
private let eeveeFireEvents: [(UIControl.Event, String)] = [
    (.primaryActionTriggered, "primaryActionTriggered"),
    (.touchUpInside, "touchUpInside"),
    (.touchDown, "touchDown"),
]

private func eeveeHasTargets(_ control: UIControl, _ event: UIControl.Event) -> Bool {
    control.allTargets.contains { target in
        !(control.actions(forTarget: target, forControlEvent: event)?.isEmpty ?? true)
    }
}

/// 读手势识别器的 `_targets` 再调它的 target/action —— pw 与我们的标签栏都用这一招
/// （`TabBarSystemGlass` 转发点击走的就是它，真机上已验证可行）。
///
/// ⚠️ `_targets` 是私有键，所以**先用 `responds(to:)` 确认两个键都在**才去 KVC：KVC 碰未知 key 是
/// **抛异常**（不是返回 nil），那会直接崩。
///
/// 广度优先、有界（`nodeLimit`）：命中的越浅越可能就是那颗按钮，所以不深挖。
private func eeveeFireGesture(in root: UIView, depthLimit: Int = 6, nodeLimit: Int = 200) -> String? {
    var queue: [(view: UIView, depth: Int)] = [(root, 0)]
    var visited = 0
    while !queue.isEmpty, visited < nodeLimit {
        let (view, depth) = queue.removeFirst()
        visited += 1
        if let fired = eeveeFireRecognizers(of: view) {
            return depth == 0 ? "gesture.\(fired)" : "gesture.sub\(depth).\(fired)"
        }
        guard depth < depthLimit else { continue }
        for sub in view.subviews { queue.append((sub, depth + 1)) }
    }
    return nil
}

private func eeveeFireRecognizers(of view: UIView) -> String? {
    let targetKey = NSSelectorFromString("target")
    let actionKey = NSSelectorFromString("action")
    for recognizer in view.gestureRecognizers ?? [] where recognizer is UITapGestureRecognizer {
        guard let pairs = recognizer.value(forKey: "_targets") as? [AnyObject] else { continue }
        for pair in pairs {
            guard let object = pair as? NSObject,
                  object.responds(to: targetKey), object.responds(to: actionKey),
                  let target = object.value(forKey: "target") as? NSObject,
                  let name = object.value(forKey: "action") as? String else { continue }
            let selector = NSSelectorFromString(name)
            guard target.responds(to: selector) else { continue }
            _ = target.perform(selector, with: recognizer)
            return "\(NSStringFromClass(type(of: target))).\(name)"
        }
    }
    return nil
}

/// 这颗源控件**现在是不是"开"态**（随机播放已开 / 已关注）。
///
/// ★★ 2026-10-17（用户：「（关注）功能正常。但是如果艺人已经关注了，它应该是有**绿色描边**的，
/// 但现在没有」）：旧版只有 `(source as? UIControl)?.isSelected` 一条判据 —— 而按 id 找到的
/// 常常是 `ElementView<…>` **包装层**（`isSelected` 恒假），于是**永远不变绿**。
/// `firstControl` 的注释里逐字写着这件事，但 Follow 那颗当时没走它。
///
/// 这里把三条能拿到的信号都试一遍，从最标准到最兜底：
///   ① `UIControl.isSelected`；② `accessibilityTraits` 里的 `.selected`（App 暴露开关态的标准做法）；
///   ③ **文字里的"已关注"标记**（`Follow` 是文字按钮：关注 ↔ 已关注 / Follow ↔ Following）。
///
/// ⚠️ 第 ③ 条是按本仓库已有的两套语言写的（与 `am_header_play` 那类一样直接落在代码里）。
/// 真实文本会由 `eeveeOnSignals` 打进日志 —— 下一份日志能直接告诉我们哪一条信号真的会变，
/// 到时候再收窄/扩宽，别靠猜。
func eeveeIsOn(_ view: UIView?) -> Bool {
    guard let view else { return false }
    if let control = view as? UIControl, control.isSelected { return true }
    if view.accessibilityTraits.contains(.selected) { return true }
    let text = eeveeControlText(of: view)
    return eeveeFollowingMarkers.contains { text.localizedCaseInsensitiveContains($0) }
}

private let eeveeFollowingMarkers = ["已关注", "已追蹤", "Following", "Siguiendo", "Abonniert", "已關注"]

/// 把一条源控件上的**所有**状态信号拼成一行（只进日志，不参与判断）。
func eeveeOnSignals(_ view: UIView?) -> String {
    guard let view else { return "source missing" }
    let selected = (view as? UIControl)?.isSelected ?? false
    let trait = view.accessibilityTraits.contains(.selected)
    let text = eeveeControlText(of: view)
    return "isSelected=\(selected) selectedTrait=\(trait)"
        + " label=\"\(view.accessibilityLabel ?? "-")\" text=\"\(text)\""
}

/// 这颗控件子树里第一段非空文字（`Follow` 那种文字按钮的"关注/已关注"就在里面）。
func eeveeControlText(of root: UIView) -> String {
    var queue: [UIView] = [root]
    var visited = 0
    while !queue.isEmpty, visited < 200 {
        let view = queue.removeFirst()
        visited += 1
        if let label = view as? UILabel, let text = label.text, !text.isEmpty { return text }
        if let button = view as? UIButton,
           let text = button.title(for: .normal) ?? button.title(for: .selected), !text.isEmpty {
            return text
        }
        if view !== root, let text = view.accessibilityLabel, !text.isEmpty, view is UIControl { return text }
        queue.append(contentsOf: view.subviews)
    }
    return ""
}

/// 从被藏起来的控件上取字形：它自己/子树里的 `UIImageView.image`，或 `UIButton` 的 image。
func eeveeGlyph(of control: UIView?) -> UIImage? {
    guard let control else { return nil }
    if let button = control as? UIButton {
        return button.image(for: .normal) ?? button.image(for: .selected) ?? button.image(for: .highlighted)
    }

    var queue: [UIView] = control.subviews
    var visited = 0
    while !queue.isEmpty, visited < 200 {
        let view = queue.removeFirst()
        visited += 1
        if let imageView = view as? UIImageView, let image = imageView.image { return image }
        queue.append(contentsOf: view.subviews)
    }
    return nil
}

// MARK: - 页头里那三颗控件

/// 「镜像按钮」：字形取自被藏起来的 Spotify 控件，点击转发给它。
final class EntityPageHeaderButton: UIControl {

    private let glyphView = UIImageView()
    private weak var source: UIView?
    /// 那圈玻璃（44pt 圆，见 `layoutSubviews`）。
    private var glass: UIVisualEffectView?

    /// 源控件取不到字形时的兜底（SF Symbol）。
    ///
    /// ★ 2026-10-13（艺人页）：**换兜底字形要立刻生效** —— 艺人页那一颗是 Follow（文字按钮，
    /// `eeveeGlyph` 永远拿不到字形），"未关注 / 已关注"就是靠这里换一对 SF Symbol 表达的；
    /// 而 `feed(from:)` 在"源没变"时会早退，所以只能在这一侧的 didSet 里补。
    var fallbackGlyph: UIImage? {
        didSet {
            // ★★ 2026-10-17（用户：「艺人页左边应该是一个 `i`…但现在是歌单的**随机播放**按钮」）：
            //    **显式设的兜底字形必须立刻生效**。旧版这里是 `guard glyphView.image == nil` ——
            //    而 `applyToArtistPage` 先 `updateRow`（那一刻 leading 还是 shuffle ⇒ `feed` 取到
            //    shuffle 的字形），随后才 `setLeadingGlyph(info.circle)`，于是被这一句**挡掉**
            //    ⇒ 那颗按钮永远是随机播放的样子（功能也没接对，见那边的说明）。
            //    顺序上不会误伤：`updateRow` 里兜底是**先设、后 feed**，真字形仍然赢。
            guard let fallbackGlyph else { return }
            glyphView.image = fallbackGlyph.withRenderingMode(.alwaysTemplate)
        }
    }
    /// 关态颜色 / 开态颜色（开态按源控件的 `isSelected` 判断）。
    var glyphColor: UIColor = .label
    var onGlyphColor: UIColor = .systemGreen
    /// 这颗按钮的**身份**（`shuffle` / `trailing`）—— 只进日志：用户报"右边那颗和别的按钮重合"时，
    /// 日志里必须能分清他说的是哪一颗（见 `updateRow` 与 `tapped`）。
    var role = "side button"

    /// ★★ 2026-10-17（用户：「点击后**跳转到关于艺人模块**」）：这一颗点下去要**先把源滚进视野**
    /// 再转发 —— 艺人页的"关于"（`SPTArtistAboutBiographyView`）在列表很下面，只转发不滚动的话
    /// 用户什么都看不见。由调用方按需打开。
    var scrollsSourceIntoView = false

    /// ★★ 2026-10-17：**真正要转发的目标**（可以不是 `source`）。
    ///
    /// 艺人页左边那颗 `i` 就是这样：`source` 只负责"这颗按钮显示什么字形"（找不到"关于艺人"时
    /// 退回 shuffle 只是为了让按钮**有东西可显示**），而**动作**必须落在"关于艺人"上 ——
    /// 目标还没有时**宁可只往下滚一屏、也绝不退回去做随机播放**（图标说 `i`、动作却是随机，
    /// 正是用户上一轮报的那件事）。
    weak var fireTarget: UIView?

    override init(frame: CGRect) {
        super.init(frame: frame)
        glyphView.contentMode = .scaleAspectFit
        glyphView.isUserInteractionEnabled = false
        // ★ 2026-10-13（用户：「旁边的按键小了点」）：两侧按钮嵌一圈玻璃圆（pw 的 `SGRGlassInside`
        //   用的就是 `SGRGlassCircleSize = 44`）—— 字形 22pt 落在 44pt 玻璃圆里，分量才对得上
        //   中间那颗胶囊。
        _ = eeveeInsertGlass(in: self, interactive: false)
        glass = subviews.first as? UIVisualEffectView
        addSubview(glyphView)
        addTarget(self, action: #selector(tapped), for: .touchUpInside)
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// 认一个 Spotify 的控件：记引用、取字形、取标签（顺带把无障碍名字带过来）。
    ///
    /// ★ 2026-10-13（性能）：**同一个源控件只取一次字形** —— 这一拍在页头折叠的每一帧都会走到，
    /// 而"取字形"要遍历源控件的子树、还会 `withRenderingMode` 造一张新图。
    func feed(from control: UIView?) {
        let sameSource = (source as? NSObject) === (control as? NSObject)
        source = control
        accessibilityLabel = control?.accessibilityLabel ?? accessibilityLabel
        refreshTint()
        guard !sameSource || glyphView.image == nil else { return }

        let glyph = eeveeGlyph(of: control) ?? fallbackGlyph
        glyphView.image = glyph?.withRenderingMode(.alwaysTemplate)
    }

    private func refreshTint() {
        let isOn = eeveeIsOn(source)
        glyphView.tintColor = isOn ? onGlyphColor : glyphColor
        // ★★ 2026-10-17（用户：「如果艺人已经关注了，它应该是有**绿色描边**的，但现在没有」）：
        //    Spotify 自己的"已关注"就是**绿字 + 绿描边**，AM 那颗收藏键也是描边态
        //    ⇒ 把那圈玻璃的边描上（玻璃本身就是那颗 44pt 圆，圆角在 `layoutSubviews` 里跟着走）。
        if let glass {
            let width: CGFloat = isOn ? 1.5 : 0
            if glass.layer.borderWidth != width {
                glass.layer.borderWidth = width
                glass.layer.borderColor = isOn ? onGlyphColor.cgColor : nil
            }
        }
    }

    @objc private func tapped() {
        refreshTint()

        // 转发目标：**优先 `fireTarget`**；只有没开"先滚进视野"这一档时才退回 `source`
        // （否则目标缺失时就会去点那颗只负责显示字形的 shuffle —— 见 `fireTarget` 的说明）。
        let target = fireTarget ?? (scrollsSourceIntoView ? nil : source)
        var scrolled = false
        var path = "NOTHING (no target, no tap recogniser)"
        if let target {
            if scrollsSourceIntoView { scrolled = eeveeScrollIntoView(target) }
            path = eeveeFire(target) ?? path
        } else if scrollsSourceIntoView {
            // 目标那一段还没建出来（懒加载）⇒ 把页面往下滚一屏让它出现，**不转发**。
            scrolled = eeveeScrollPageDown(from: self)
            path = scrolled
                ? "NOTHING yet (the target is not built) — scrolled the page a screen to build it"
                : "NOTHING (the target is not built and the page has nothing to scroll)"
        }

        // ⚠️ 不要在这些字符串**插值里写引号**：`swift_member_check.py` 的去字符串扫描器会提前
        //    收尾、把剩下的英文当裸标识符误报（2026-10-17 踩过，见 `EntityPageStatusBar`）。先拼好。
        let kind = (target ?? source).map { NSStringFromClass(type(of: $0)) } ?? "-"
        let isControl = (target ?? source) as? UIControl != nil
        let signals = eeveeOnSignals(source)
        writeDebugLog(
            "[EntityPageHeader] \(role) tapped — class \(kind), uicontrol=\(isControl),"
                + " scrolledIntoView=\(scrolled), fired: \(path); \(signals)"
        )
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // 玻璃圆居中（`glassCircle`，比按钮矮 4pt 留出边距），字形固定 `glyphSide` 落在它中间。
        let circle = min(EntityPageHeaderMetrics.glassCircle, min(bounds.width, bounds.height))
        let glassFrame = CGRect(
            x: round((bounds.width - circle) / 2),
            y: round((bounds.height - circle) / 2),
            width: circle,
            height: circle
        )
        if let glass {
            if glass.frame != glassFrame { glass.frame = glassFrame }
            glass.layer.cornerRadius = circle / 2
        }

        let side = EntityPageHeaderMetrics.glyphSide
        glyphView.frame = CGRect(
            x: round((bounds.width - side) / 2),
            y: round((bounds.height - side) / 2),
            width: side,
            height: side
        )
    }
}

/// 白色的 Play 胶囊（Music app 那颗）。字形同样镜像 Spotify 的 Play。
final class EntityPageHeaderPlay: UIControl {

    private let glyphView = UIImageView()
    private let wordLabel = UILabel()
    private weak var source: UIView?
    /// 胶囊里那片玻璃（见 `init`）。
    private var glass: UIVisualEffectView?

    override init(frame: CGRect) {
        super.init(frame: frame)
        // ★ 2026-10-13（用户看真机：「播放那个不是液态玻璃」）：pw 的 `SGRPlayCapsule` 是
        //   **白底 + 里面再嵌一片玻璃**（v0.21.1 的 `SGRGlassCapsuleInside(self, &kCapsuleGlassKey,
        //   bounds.size, YES)`，interactive 打开），所以这里照做：白底留一点透明（让玻璃有东西
        //   可折射：底下的封面与取色底），玻璃嵌在最底层，字形与文字保持黑色（浅玻璃上才读得清）。
        //   iOS 26 以下拿不到 `UIGlassEffect` 时退浅色材质 —— 见 `eeveeMakeLightGlassView`。
        backgroundColor = UIColor.white.withAlphaComponent(0.9)
        layer.masksToBounds = true
        _ = eeveeInsertGlass(in: self, interactive: true)
        glass = subviews.first as? UIVisualEffectView

        glyphView.contentMode = .scaleAspectFit
        glyphView.tintColor = .black
        glyphView.image = UIImage(systemName: "play.fill")?.withRenderingMode(.alwaysTemplate)
        glyphView.isUserInteractionEnabled = false
        addSubview(glyphView)

        wordLabel.text = "am_header_play".localized
        wordLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        wordLabel.textColor = .black
        wordLabel.textAlignment = .center
        addSubview(wordLabel)

        addTarget(self, action: #selector(tapped), for: .touchUpInside)
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = wordLabel.text
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func feed(from control: UIView?) {
        let sameSource = (source as? NSObject) === (control as? NSObject)
        source = control
        // 同一个源控件就不重复取字形（见上面 `EntityPageHeaderButton.feed` 的说明）。
        guard !sameSource || glyphView.image == nil else { return }
        if let glyph = eeveeGlyph(of: control) {
            glyphView.image = glyph.withRenderingMode(.alwaysTemplate)
        }
    }

    /// ★★ 2026-10-17：**长按 = 随机播放**。
    ///
    /// 左边那颗位置让给 AM 的 `i`（"关于艺人"）之后，随机播放就没地方点了 —— 用户早就问过
    /// 「左边还是点不了的随机播放上哪点去」（见 `HANDOFF_2026-10-13_..._EntityPages-AM.md` §四.2），
    /// 当时定下的方案就是这一条。长按识别成功会**取消**这次触摸 ⇒ `touchUpInside` 不会跟着发，
    /// 所以"轻点 = 播放、长按 = 随机"不会互相打架。
    private weak var longPressSource: UIView?
    private var longPress: UILongPressGestureRecognizer?

    func feedLongPress(_ control: UIView?) {
        longPressSource = control
        guard longPress == nil else { return }
        let press = UILongPressGestureRecognizer(target: self, action: #selector(pressed))
        press.minimumPressDuration = 0.4
        addGestureRecognizer(press)
        longPress = press
    }

    @objc private func pressed(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began else { return }
        let path = eeveeFire(longPressSource) ?? "NOTHING (no target, no tap recogniser)"
        writeDebugLog("[EntityPageHeader] play long-pressed → shuffle fired: \(path)")
    }

    @objc private func tapped() {
        let path = eeveeFire(source) ?? "NOTHING (no target, no tap recogniser)"
        let kind = source.map { NSStringFromClass(type(of: $0)) } ?? "-"
        writeDebugLog("[EntityPageHeader] play capsule tapped — class \(kind), fired: \(path)")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
        // 玻璃铺满整颗（圆角跟形状走）。
        if let glass {
            if glass.frame != bounds { glass.frame = bounds }
            glass.layer.cornerRadius = bounds.height / 2
        }

        // ★ 2026-10-13（照 AM）：**形状决定形态**。布局那边给的是正方形（`playSide`，84pt）时，
        //   它就是 AM 那颗"大圆 ▶"——**没有"播放"两个字**；给的是扁的（旧的 148×48）时，
        //   还是 pw 那颗"▶ 播放"胶囊。两种形态共用这一份代码，不用开关、也不会两处漂。
        let isCircle = abs(bounds.width - bounds.height) < 8
        if wordLabel.isHidden != isCircle { wordLabel.isHidden = isCircle }

        // 形状决定底色：AM 那颗是**纯白**（照片 113 里我们这颗是"白 90% + 玻璃" ⇒ 在亮照片上
        // 灰得看不出来）；胶囊形态仍留一点透明，好让底下的封面透出来（pw 的做法）。
        let wanted: UIColor = isCircle ? .white : UIColor.white.withAlphaComponent(0.9)
        if backgroundColor != wanted { backgroundColor = wanted }
        glass?.alpha = isCircle ? 0 : 1

        // [字形][6pt][Play] 整体居中（圆形态里只剩字形，自然就是居中的）
        // ★★ 2026-10-06（用户：「播放按钮里面的按键**不够大**」）：圆形态 44 → **52**
        //   （AM 那颗 ▶ 占到圆的一半以上），胶囊形态仍是 24。
        let glyphSide: CGFloat = isCircle ? 52 : 24
        let glyphWidth = glyphView.image == nil ? 0 : glyphSide
        let spacing: CGFloat = (!isCircle && glyphWidth > 0) ? 6 : 0
        let wordWidth = isCircle ? 0 : ceil(wordLabel.sizeThatFits(
            CGSize(width: bounds.width, height: .greatestFiniteMagnitude)
        ).width)
        let total = glyphWidth + spacing + wordWidth
        let startX = round((bounds.width - total) / 2)

        glyphView.frame = CGRect(x: startX, y: round((bounds.height - glyphSide) / 2),
                                 width: glyphWidth, height: glyphSide)
        wordLabel.frame = CGRect(x: startX + glyphWidth + spacing, y: 0,
                                 width: wordWidth, height: bounds.height)
    }
}

// MARK: - 页头本体

/// 那一块文字与按钮。输入永远是"文本 + Spotify 自己的控件"，自己不持有任何 Spotify 状态。
final class EntityPageHeaderView: UIView {

    /// ★ 2026-10-13（AM 的标题**很大** —— photo_1 里 `Abel Tesfaye` 一个人占掉大半个屏宽）：
    /// 22 → **34**，缩放基准同时从 `.title2` 换成 `.largeTitle`（`makeLabel` 走 `UIFontMetrics`，
    /// 基准不换的话辅助功能字号下的比例会不对）。
    private let titleLabel = EntityPageHeaderView.makeLabel(
        style: .largeTitle, size: 34, weight: .bold, color: .label, lines: 2, alignment: .center
    )
    private let creatorLabel = EntityPageHeaderView.makeLabel(
        style: .body, size: 17, weight: .regular, color: .secondaryLabel, lines: 1, alignment: .center
    )
    private let lengthLabel = EntityPageHeaderView.makeLabel(
        style: .footnote, size: 13, weight: .regular, color: .tertiaryLabel, lines: 1, alignment: .center
    )
    private let aboutLabel = EntityPageHeaderView.makeLabel(
        style: .footnote, size: 13, weight: .regular, color: .secondaryLabel, lines: 2, alignment: .natural
    )

    private let shuffleButton = EntityPageHeaderButton()
    private let playButton = EntityPageHeaderPlay()
    private let trailingButton = EntityPageHeaderButton()

    /// 创建者那一行背后那个 Spotify 控件（点了打开作者页）——被藏起来、只负责响应。
    private weak var creatorLink: UIView?

    private static func makeLabel(
        style: UIFont.TextStyle, size: CGFloat, weight: UIFont.Weight,
        color: UIColor, lines: Int, alignment: NSTextAlignment
    ) -> UILabel {
        let label = UILabel()
        label.font = UIFontMetrics(forTextStyle: style).scaledFont(for: .systemFont(ofSize: size, weight: weight))
        label.adjustsFontForContentSizeCategory = true
        label.textColor = color
        label.numberOfLines = lines
        label.textAlignment = alignment
        label.lineBreakMode = .byTruncatingTail
        label.isHidden = true
        return label
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        for label in [titleLabel, creatorLabel, lengthLabel, aboutLabel] { addSubview(label) }
        titleLabel.accessibilityTraits = .header

        shuffleButton.fallbackGlyph = UIImage(systemName: "shuffle")
        // 关态用主色（Spotify 自己那颗关态是灰的，挨着白色 Play 像"坏了"）；开态给强调色，
        // 这样"随机播放已开"仍然看得出来。
        shuffleButton.glyphColor = .label
        shuffleButton.onGlyphColor = .systemGreen
        trailingButton.glyphColor = .label

        for button in [shuffleButton, playButton, trailingButton] {
            button.isHidden = true
            button.accessibilityIdentifier = "eevee-entity-header-button"
            addSubview(button)
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: 输入

    /// 文本变了才重排。返回是否变了（调用方用它决定要不要再走一遍）。
    @discardableResult
    func update(title: String, creator: String, length: String, about: String) -> Bool {
        var changed = false
        changed = setText(titleLabel, title) || changed
        changed = setText(creatorLabel, creator) || changed
        changed = setText(lengthLabel, length) || changed
        changed = setText(aboutLabel, about) || changed
        if changed { setNeedsLayout() }
        return changed
    }

    private func setText(_ label: UILabel, _ text: String) -> Bool {
        if (label.text ?? "") == text { return false }
        label.text = text
        label.isHidden = text.isEmpty
        return true
    }

    /// 三颗按钮各认一个 Spotify 控件；`nil` = 那颗不显示。
    func updateRow(shuffle: UIView?, play: UIView?, trailing: UIView?, trailingFallback: UIImage?) {
        // ★ 2026-10-13：给两颗按钮**标身份** —— 日志 89 只有一行 `header button tapped (source found)`，
        //   分不出用户点的是左边那颗还是右边那颗（他报告"右边那颗和原生按钮重合"时，
        //   这一条恰恰是最该看清的）。下一份日志会写成 `tapped (role trailing, source …)`。
        shuffleButton.role = "shuffle"
        trailingButton.role = "trailing"
        trailingButton.fallbackGlyph = trailingFallback
        shuffleButton.feed(from: shuffle)
        if let play { playButton.feed(from: play) }
        trailingButton.feed(from: trailing)

        let pairs: [(UIControl, Bool)] = [
            (shuffleButton, shuffle != nil),
            (playButton, play != nil),
            (trailingButton, trailing != nil),
        ]
        for (control, shown) in pairs where control.isHidden == shown {
            control.isHidden = !shown
            setNeedsLayout()
        }
    }

    /// ★★ 2026-10-17：**长按播放键 = 随机播放**（见 `EntityPageHeaderPlay.feedLongPress` 的说明）。
    /// 三个页面都接上：歌单/专辑页左边本来就是 shuffle，多一个入口无害；艺人页那颗位置让给 `i` 之后，
    /// 这里就是随机播放唯一的入口。
    func updatePlayLongPress(_ shuffle: UIView?) {
        playButton.feedLongPress(shuffle)
    }

    /// ★★ 2026-10-06（用户：「播放页左边的按钮不应该是那个 `i` 吗，还没改？」）：
    /// 左边那颗（AM 的 **Info**）在 Spotify 侧对应的是**艺人简介卡**，那颗卡上没有图标可镜像
    /// ⇒ 由调用方**显式给一个**字形（`info.circle`）。中间与右边那两颗不经过这里。
    func setLeadingGlyph(_ glyph: UIImage?) {
        shuffleButton.fallbackGlyph = glyph
    }

    /// ★★ 2026-10-17（用户：「点击（`i`）后**跳转到**关于艺人模块」）：左边那颗点下去要**先把源
    /// 滚进视野**再转发 —— 艺人页的"关于"（`SPTArtistAboutBiographyView`）在列表很下面。
    ///
    /// `target` 为 `nil`（那一块还没建出来）时**动作也不落在 `source` 上**（见 `fireTarget` 的说明）。
    func setLeadingTarget(_ target: UIView?, glyph: UIImage?) {
        shuffleButton.fireTarget = target
        shuffleButton.fallbackGlyph = glyph
        shuffleButton.scrollsSourceIntoView = true
    }

    /// 创建者那一行可点（点开作者页）：`control` 是 Spotify 自己那个按钮，被藏着只负责响应。
    func updateCreatorLink(_ control: UIView?) {
        creatorLink = control
        let live = control != nil
        guard creatorLabel.isUserInteractionEnabled != live else { return }
        creatorLabel.isUserInteractionEnabled = live
        creatorLabel.accessibilityTraits = live ? .button : .staticText
        guard live, creatorLabel.gestureRecognizers?.isEmpty ?? true else { return }
        creatorLabel.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(creatorTapped)))
    }

    @objc private func creatorTapped() {
        _ = eeveeFire(creatorLink)
    }

    // MARK: 布局（贴底排）

    /// 内容从标题顶到描述底的高度。`apply` 用它算"封面该伸到哪"。
    func contentHeight(forWidth width: CGFloat) -> CGFloat {
        let text = max(0, width - 2 * EntityPageHeaderMetrics.side)
        var height: CGFloat = 0
        var previous: UILabel?

        for label in [titleLabel, creatorLabel, lengthLabel] where !label.isHidden {
            if let previous { height += previous === creatorLabel ? 4 : 2 }
            height += ceil(label.sizeThatFits(CGSize(width: text, height: .greatestFiniteMagnitude)).height)
            previous = label
        }
        if previous != nil { height += EntityPageHeaderMetrics.rowAbove }
        // ★ 2026-10-13（照 AM）：按钮行的高度取三颗里**最高**的那颗（中间那颗比两侧大一档）。
        height += max(EntityPageHeaderMetrics.rowHeight, EntityPageHeaderMetrics.playSide)
        if !aboutLabel.isHidden {
            height += EntityPageHeaderMetrics.aboutAbove
            height += ceil(aboutLabel.sizeThatFits(CGSize(width: text, height: .greatestFiniteMagnitude)).height)
        }
        return height
    }

    /// ★ 2026-10-17：**只在会缩的页头上启用**上面那条渐隐。
    ///
    /// ⚠️ 照片 124 的教训：这条本来是给**艺人页**写的（那边 `HeaderContainer` 会从 520pt 缩到 100pt
    /// 的导航栏），但我无条件打开了 —— 而歌单页的 `PL.Header` **根本不会缩**，于是某一拍
    /// `bounds.height` 还没定下来时算出的 `fade = 0` 被留在那儿，**整块页头（标题 + 三颗按钮）
    /// 就此消失**，只剩 Spotify 自己的搜索框和 pill 行露在外面。
    /// ⇒ 改成一个显式开关，只有 `applyToArtistPage` 打开它。
    var fadesWhenTight = false

    override func layoutSubviews() {
        super.layoutSubviews()

        // ★★ 2026-10-17（用户：「歌单页的图标似乎**没下沉**」；照片 121 是现场：那一行三颗按钮浮在
        //    **收起来的导航栏**上、和 "AKIRVTXNSHI" 叠在一起）：
        //
        //    这一整块是**贴着页头底部**排的（`y = bounds.height - bottom - contentHeight`），而页头会随
        //    滚动从 520pt 缩到 100pt 的导航栏 ⇒ 内容放不下时 `y` 变成负数，标题与按钮就**溢出到页头
        //    上方**，正好压在 Spotify 自己的导航栏上 ✗。
        //
        //    ⇒ 页头矮到装不下这一块时，它整体**渐隐让位**（AM 里就是"跟着页头一起滚走"）：
        //      `room ≥ 32pt` 全亮、`room ≤ 0` 全隐、中间线性。用 `alpha` 而不是 `isHidden`，
        //      免得折叠过程中一闪一闪。
        if fadesWhenTight {
            let needed = contentHeight(forWidth: bounds.width) + EntityPageHeaderMetrics.bottom
            let room = bounds.height - needed
            let fade = max(0, min(1, room / 32))
            if alpha != fade { alpha = fade }
        } else if alpha != 1 {
            alpha = 1
        }

        let width = bounds.width
        let text = max(0, width - 2 * EntityPageHeaderMetrics.side)
        var y = round(bounds.height - EntityPageHeaderMetrics.bottom - contentHeight(forWidth: width))

        var previous: UILabel?
        for label in [titleLabel, creatorLabel, lengthLabel] where !label.isHidden {
            if let previous { y += previous === creatorLabel ? 4 : 2 }
            let height = ceil(label.sizeThatFits(CGSize(width: text, height: .greatestFiniteMagnitude)).height)
            label.frame = CGRect(x: EntityPageHeaderMetrics.side, y: y, width: text, height: height)
            y += height
            previous = label
        }
        if previous != nil { y += EntityPageHeaderMetrics.rowAbove }

        // Play 始终在页面正中，另两颗挂在它两侧 —— 少一颗也不动位置。
        //
        // ★ 2026-10-13（照 AM）：中间那颗**大一档**（84 vs 两侧 56），三颗要**圆心同高**
        //   ⇒ 中间那颗往上抬 `(big - side) / 2`，两侧才与它的圆心齐平。
        let side = EntityPageHeaderMetrics.rowHeight
        let big = EntityPageHeaderMetrics.playSide
        let play = CGRect(
            x: round((width - big) / 2),
            y: y - (big - side) / 2,
            width: big,
            height: big
        )
        playButton.frame = play
        shuffleButton.frame = CGRect(
            x: play.minX - EntityPageHeaderMetrics.rowSpacing - side, y: y, width: side, height: side
        )
        trailingButton.frame = CGRect(
            x: play.maxX + EntityPageHeaderMetrics.rowSpacing, y: y, width: side, height: side
        )
        y += max(side, big)

        if !aboutLabel.isHidden {
            y += EntityPageHeaderMetrics.aboutAbove
            let height = ceil(aboutLabel.sizeThatFits(CGSize(width: text, height: .greatestFiniteMagnitude)).height)
            aboutLabel.frame = CGRect(x: EntityPageHeaderMetrics.side, y: y, width: text, height: height)
        }
    }

    // MARK: 触摸

    /// 只有按钮和**创建者那行文字**吃触摸；其余位置一律还给页面
    /// （这一块和页面一样宽，全吃的话下拉就拉不动了）。
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        if hit === self || hit === creatorLabel { return creatorHit(point) }
        return hit
    }

    private func creatorHit(_ point: CGPoint) -> UIView? {
        guard creatorLabel.isUserInteractionEnabled, !creatorLabel.isHidden else { return nil }
        let size = creatorLabel.sizeThatFits(
            CGSize(width: creatorLabel.bounds.width, height: .greatestFiniteMagnitude)
        )
        let word = CGRect(
            x: round(creatorLabel.frame.midX - size.width / 2),
            y: creatorLabel.frame.minY,
            width: min(size.width, creatorLabel.frame.width),
            height: creatorLabel.frame.height
        ).insetBy(dx: -8, dy: -6)
        return word.contains(point) ? creatorLabel : nil
    }
}
