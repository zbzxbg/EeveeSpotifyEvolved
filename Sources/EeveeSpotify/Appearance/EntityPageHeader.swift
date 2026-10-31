import Foundation
import UIKit

/// 「专辑 / 歌单页头」—— 把 Spotify 的页头换成 Apple Music 式的版本。
///
/// 形态（Music app 的专辑 / 歌单页），整块**贴底排**（内容底边距视图底 14pt）：
/// ```
///              标  题          ← 居中、粗体、最多 2 行
///            创 建 者          ← 居中、次要色
///         8 首歌 · 41 分钟      ← 居中、三级色（Spotify 自己那行原文）
///         ──────────────      ← 16pt
///      [shuffle] (  ▶ Play  )  [尾随]
///         ──────────────      ← 14pt
///           描 述             ← 自然对齐、最多 2 行
/// ```
/// 标题与创建者正好压在封面的"溶解"边上，封面要伸到内容顶部往下 56pt（`titleRise`，给 hero 用）。
///
/// 三条关键取舍：
/// 1. **不摆 Spotify 的控件，整列藏掉自己画**：摆它的列就要回应它每一拍的 stack 重排与 Auto Layout 写回，实测会被改回去；
/// 2. **按钮"镜像 + 转发"**：字形取自被藏起来的 Spotify 控件（取不到用 SF Symbol 兜底），点击 `sendActions` 转发给那个控件 ⇒ 动作 / 状态 / 语言都留在 Spotify 那边；
/// 3. **只有文字真正画到的地方吃触摸**：这块和页面一样宽，其余部分必须让下拉与点击穿过去。
///
/// 安全阀：**认不出标题就整块不动**（`apply` 早退，一个视图都不藏）。任何一环失配的结果是"这个功能没生效"，而不是"歌单页坏了"。
/// 判据照 pw v0.21.1 `SGRHeaderInfo` / `PlaylistHeader.x` 重写，目标类与标识符用真机日志重新核对过。
enum EntityPageHeaderMetrics {
    static let side: CGFloat = 20           // 文字左右内缩
    static let playMinWidth: CGFloat = 148  // Play 胶囊最小宽度（Music app 的）
    static let rowSpacing: CGFloat = 16
    static let rowAbove: CGFloat = 16       // 文字与按钮行之间
    static let aboutAbove: CGFloat = 14     // 按钮行与描述之间
    static let bottom: CGFloat = 14         // 内容底边距视图底
    static let titleRise: CGFloat = 56      // 封面要伸到内容顶部往下这么多（hero 用）
    /// （用户给了 8 张 AM 艺人页，photo_1/3/5/7）：三颗的**尺寸关系**照 Apple Music 来
    /// —— 两侧是**小圆**（`ⓘ` 与 `☆`，≈56pt），中间是**大一档的圆**（纯白 `▶`，≈80pt）。
    /// 原来是 pw 的"两颗 44 圆 + 一颗 148×48 的白胶囊"；现在中间那颗**从胶囊变成圆**（去掉"播放"二字）。
    static let rowHeight: CGFloat = 56      // = 两侧小圆的直径
    static let playSide: CGFloat = 84       // = 中间那颗粒子的直径
    /// 页头**右上角那颗 `⋯`** 的直径 —— AM 在同一位置放一颗"分享 + ⋯"的
    /// 玻璃胶囊，与左上角的返回键同高。
    static let pinnedMoreSide: CGFloat = 44
    /// 两侧按钮那圈**玻璃圆**的直径（= pw 的 `SGRGlassCircleSize`）。
    static let glassCircle: CGFloat = 44
    /// 两侧按钮的字形边长。（旁边的按键小了点）：
    /// 原来是"按 48pt 的 27% 内缩"≈26pt，看着比中间那颗胶囊轻 —— pw 是 44pt 玻璃圆里放字形，
    /// 所以这里改成**固定字形 + 44pt 玻璃圆**，与 Music app 的分量对齐。
    /// 同日再调（这播放旁边的播放图标太小了吧）：22 → **24**。
    static let glyphSide: CGFloat = 24
}

/// 浅色玻璃（Play 胶囊里那片）。**探测式**，与 `GlassCapsule.makeGlassView` 同一套手法
/// —— 那一条是给深色标签栏用的（材质兜底是 dark），这颗胶囊要浅色，所以另开一个：
/// iOS 26 有 `UIGlassEffect` 就用真玻璃（带折射与边缘高光），否则退浅色材质。
///
/// 返回的视图**不吃触摸**（它只是底），点击由外面的 `UIControl` 收。
func eeveeMakeLightGlassView(interactive: Bool) -> UIVisualEffectView {
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
func eeveeInsertGlass(in host: UIView, interactive: Bool) -> UIVisualEffectView {
    let glass = eeveeMakeLightGlassView(interactive: interactive)
    glass.frame = host.bounds
    glass.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    host.insertSubview(glass, at: 0)
    return glass
}

// MARK: - 藏 / 找 / 点
//
// 把 Spotify 的视图**藏死**。三个动作缺一不可：
//
// · **改 `layer.isHidden`，不碰 `view.isHidden`** —— Spotify 自己会 `setHidden:NO` 把东西
// 显示回来（改层挡得住），而且 Encore 的 stack 在 arranged view 被 `hidden` 时可能在
// `updateConstraints` 里 trap；
// · **空 mask** —— Spotify 不碰 mask，被空 mask 罩住的层什么都不画，这是第二道保险；
// · 关交互 + 关无障碍（藏掉的东西不该再能被点到或读屏读到）。
//
// 幂等，每一拍调都行。
func eeveeConceal(_ view: UIView?) {
    guard let view else { return }
    if !view.layer.isHidden { view.layer.isHidden = true }
    if view.layer.mask == nil { view.layer.mask = CALayer() }
    if view.isUserInteractionEnabled { view.isUserInteractionEnabled = false }
    view.accessibilityElementsHidden = true
}

/// **只加空 mask** 的藏法：视图什么都不画，但 `layer.isHidden` / `view.isHidden` 一个都不碰。
///
/// 什么时候必须用它 —— 视图在 **`OverflowStackView`** 里的时候。
/// pw 在艺人页踩过这个真机崩溃，注释逐字：
///
/// > `ios-creator-impl.context_menu_in_navigation_bar_enabled_artist` moves more out of the header's
/// > row, and with it gone Spotify's OverflowStackView force-unwraps the tallest view of a line that
/// > has none and **traps as the page opens** (device crash19:09,
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
/// （点击（`i`）后**跳转到关于艺人模块**）：艺人页的"关于"在列表很下面
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
/// 给艺人页那颗 `i` 兜底 —— "关于艺人"（`SPTArtistAboutBiographyView`）是列表里
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

// MARK: - 「关于艺人」在这一版艺人页上的真实名字
//
// 卡片：id 前缀 `Components.UI.CreatorBiographyCard.*`、Swift 类名里含 `CreatorBiography`。
// 正文：`Components.UI.CreatorBiographyCard.BiographyLabel`（真机树里那一格就是它）。
//
// ⚠️ 为什么不能只认 `SPTArtistAboutBiographyView`：
// · 那个类**在二进制里还在** ⇒ 启动那行 `about-artist hook on` 照样打得出来，
// 但它在**这一版艺人页上从头到尾没出现过**：`applyToArtistPage` 那条 BFS 只试两拍、
// `eeveeMaterialiseBio` 滚到列表底也只报 `nothing built` —— 而**同一份日志**的
// `[HeaderProbe]` 明明列出了 `id=Components.UI.CreatorBiographyCard.HeaderLabel` /
// `.FreshFindsForwardBadge`：卡片在页面上，**只是不叫那个名字**。
// · 这件事本仓库自己早写下来了（`EntityPageRepaint` 的 `aboutArtistClassFragment`：
// 「`aboutArtistFragment` 那条判据在这一版艺人页上永远不可能命中」）—— 那一轮只把
// **折叠**改对了，**读取侧没跟上** ⇒ 折叠照做（那一段被折成 0 高）、我们的卡片又读不到正文，
// 于是点击 i 之后，观感还是之前的那个）。
let eeveeArtistBioCardIdPrefix = "Components.UI.CreatorBiographyCard"
let eeveeArtistBioTextId = "Components.UI.CreatorBiographyCard.BiographyLabel"
let eeveeArtistBioClassFragment = "CreatorBiography"

/// 往上找带这个无障碍 id 的祖先（有界，与 `isArtistPageAncestor` 同一条边界）。
func eeveeAncestor(withIdentifier identifier: String, of view: UIView) -> UIView? {
    var node: UIView? = view
    var level = 0
    while let current = node, level < 28 {
        level += 1
        if current.accessibilityIdentifier == identifier { return current }
        node = current.superview
    }
    return nil
}

/// 找这一步的搜索根：① `creator-page`（整页）② 它自己的最外层 scroll ③ 窗口。
///
/// 为什么必须有它：`i` 那颗按键的**起点是页头里那颗按钮**，从它**往下**走根本到不了列表里
/// 那张卡（卡在 cell 里）—— 必须先**往上**走到"整页"那一层再往下找。
func eeveeArtistBioSearchRoot(from view: UIView) -> UIView {
    if let page = eeveeAncestor(withIdentifier: "creator-page", of: view) { return page }
    if let scroll = eeveeOutermostScroll(from: view) { return scroll }
    return view.window ?? view
}

/// 「关于艺人」那一块 —— **零滚动**，按真机证实过的名字找。
///
/// 顺序：正文 label（id 精确）→ 它上面第一个 `CreatorBiography` 类祖先 → id 前缀 → 类名片段。
/// ⚠️ 只认**落在 `creator-page` 里**的卡：听歌页那张"了解艺人"卡是同一族（`CreatorBiography`），
/// 不设这道闸就会在别的页面上乱认。
func eeveeArtistBioCard(in view: UIView) -> UIView? {
    let root = eeveeArtistBioSearchRoot(from: view)
    let nodeLimit = 20000

    var found: UIView?
    if let label = eeveeFindView(root, identifier: eeveeArtistBioTextId, maxNodes: nodeLimit) {
        // 卡片 = label 往上第一个类名含 `CreatorBiography` 的祖先（没有就退回 label 自己）。
        var node: UIView? = label
        var level = 0
        while let current = node, level < 12 {
            level += 1
            if NSStringFromClass(type(of: current)).contains(eeveeArtistBioClassFragment) {
                found = current
                break
            }
            node = current.superview
        }
        if found == nil { found = label }
    }
    if found == nil {
        found = eeveeFindView(root, identifier: eeveeArtistBioCardIdPrefix + "*", maxNodes: nodeLimit)
    }
    if found == nil {
        found = eeveeFindView(root, classNameContains: eeveeArtistBioClassFragment, maxNodes: nodeLimit)
    }
    guard let found, eeveeAncestor(withIdentifier: "creator-page", of: found) != nil else { return nil }
    return found
}

/// 从那一块里读正文：**优先 id 精确的那颗 label**，读不到返回 nil（调用方再退"最长的一段"）。
///
/// ⚠️ 读的是**界面上的文字**：Spotify 会把长简介截断（flag `is_async_biography_truncation_enabled`），
/// 要完整正文只能去 hook 数据层（`SPTArtistAboutDataLoader`，见 `ArtistBioSource` 的说明）。
func eeveeArtistBioText(in card: UIView) -> String? {
    guard let label = eeveeFindView(card, identifier: eeveeArtistBioTextId)
        ?? eeveeFindView(card, identifier: eeveeArtistBioTextId + "*") else { return nil }
    let raw = (label as? UILabel)?.text ?? (label as? UITextView)?.text
    let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let trimmed, !trimmed.isEmpty else { return nil }
    return trimmed
}

/// 把列表**扫一遍**，逼"关于艺人"那一段建出来，然后返回它。
///
/// 做法：**在同一个主线程回合里**把最外层 scroll view 逐屏（`animated: false`）往下翻，
/// collection view 会为每一屏建 cell；那一段建出来时 `SPTArtistAboutBiographyView` 的 `layoutSubviews`
/// 就会响（`ArtistBiographyViewHook`），我们当场拿到它。全程不动画、最后**回到原位**，用户看不到跳动。
///
/// ⚠️ 步数有上限（12 屏）；找不到就返回 nil，调用方照旧退回"滚一屏"那条老路。
///
/// 现在改成：**每一屏都重新读一次 `contentSize`**，翻到"当前这一趟的底"再继续 ——
/// 列表边滚边长，所以"底"也必须边滚边问。
@discardableResult
func eeveeMaterialiseBio(from view: UIView) -> UIView? {
    // **先零滚动找一遍**。卡片本来就在页面上（只是不叫
    // `SPTArtistAboutBiographyView`），cell 通常也已经建出来了 ⇒ 不用滚、也不受"折成 0 高"影响。
    // 这一步把"扫列表"从**主路**降成**兜底** —— 以前它是主路，而它一次都没成功过
    if let card = eeveeArtistBioCard(in: view) {
        EntityPageHeaderManager.artistBiographyAppeared(card)
        writeDebugLog(
            "[EntityPageHeader] about-artist found without scrolling — "
                + NSStringFromClass(type(of: card))
        )
        return card
    }
    guard let scroll = eeveeOutermostScroll(from: view), scroll.bounds.height > 1 else { return nil }
    let origin = scroll.contentOffset
    let step = max(120, scroll.bounds.height * 0.9)
    var offset: CGFloat = 0
    var deepest: CGFloat = 0
    var passes = 0
    var found: UIView?
    while passes < 12 {
        passes += 1
        deepest = offset
        scroll.setContentOffset(CGPoint(x: origin.x, y: offset), animated: false)
        scroll.layoutIfNeeded()
        if let bio = EntityPageHeaderManager.artistBioTarget {
            found = bio
            break
        }
        // ⚠️ 重新问一次"现在到底有多长"。
        let bottom = max(
            0,
            scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom
        )
        guard offset < bottom else { break }
        offset = min(offset + step, bottom)
    }
    if found == nil { found = EntityPageHeaderManager.artistBioTarget }
    // 滚完再按真机那三个名字找一次 —— 滚的过程把 cell 建出来了，
    // 但钩子（`SPTArtistAboutBiographyView`）在这一版页面上永远不会响。
    if found == nil, let card = eeveeArtistBioCard(in: view) {
        EntityPageHeaderManager.artistBiographyAppeared(card)
        found = card
    }
    // 回到用户原来的位置（不管找没找到）—— 只有真找到时，调用方才把它滚进视野。
    scroll.setContentOffset(origin, animated: false)
    writeDebugLog(
        "[EntityPageHeader] about-artist sweep — \(passes) step(s) down to"
            + " \(Int(deepest))pt of \(Int(scroll.contentSize.height))pt, "
            + (found == nil ? "nothing built" : "found it")
    )
    return found
}

/// 卡片里那些**界面文字**（不是正文）—— 拼正文时跳过。
/// ⚠️ 只放"Spotify 自己给这一块画的按钮 / 小标题"，**别放可能是简介的词**（宁可多留）。
let eeveeArtistBioUILabels: Set<String> = [
    "关于", "关于艺人", "更多", "展开", "收起", "显示更多", "阅读更多", "查看全部",
    "播放", "关注", "已关注", "关注中", "分享",
    "About", "More", "Show more", "Read more", "See more", "Play", "Follow", "Following", "Share",
]

/// 「关于艺人」卡里那些**不是简介**的整块 UI —— 按**类名 / 无障碍 id** 认（语言无关）。
///
/// 名字是从**解压后的 9.1.88 主二进制**里挖出来的 —— `ArtistAbout_CommonUIKit` 那一族：
/// · `SPTArtistAboutListenersView` + id `artist-about-listeners`（"每月有 x 名听众"那一行，
/// 文案 key `sArtistListenersSubtitleText`，见二进制 @179424128）；
/// · `SPTArtistAboutRankView` + id `artist-about-rank`（排行榜那一行，key `sArtistRankSubtitleText`）。
/// 这两块都是 Spotify 画在"关于艺人"里的**附加信息**，不是简介正文 ⇒ 拼正文时整块跳过。
///
/// 为什么再按类名认一遍：下面 `eeveeSanitizedArtistBio` 那两条文字判据（带数字 + "听众/listener"）
/// 碰到没列到的语言就漏；类名与 id 与语言无关，是**第一道**判据。
func eeveeIsArtistBioNonBodyChrome(_ view: UIView) -> Bool {
    let className = NSStringFromClass(type(of: view))
    if className.contains("ArtistAboutListenersView") || className.contains("ArtistAboutRankView") {
        return true
    }
    if let identifier = view.accessibilityIdentifier,
       identifier == "artist-about-listeners" || identifier == "artist-about-rank" {
        return true
    }
    return false
}

/// 社交链接那一颗的**类名特征** —— 二进制 @200596249 逐字：`SPTArtistExternalSocialLinkButton`/// （同处还有 `SPTArtistExternalSocialLinkButtonViewModel` / `SPTArtistSocialLink`，
/// 以及委托方法 `externalSocialLinkTappedForType:`）。
///
/// 按**类名**认是与语言无关的那条判据（文字判据只当兜底：有的版本只画图标、没有文字）。
let eeveeArtistSocialLinkClassFragment = "ArtistExternalSocialLinkButton"

/// 能在控件 / 它的 model 上读链接的候选键（**先 `responds(to:)` 再问** ——
/// KVC 撞到不存在的键会抛 ObjC 异常，Swift 接不住，那就是崩溃）。
let eeveeSocialLinkURLKeys = [
    "url", "URL", "linkURL", "link", "webURL", "externalURL", "urlString", "targetURL",
]
/// 一跳：按钮把 model 挂在哪个键上（同样是候选，逐一试）。
let eeveeSocialLinkModelKeys = [
    "viewModel", "model", "socialLink", "linkModel", "viewModelObject",
]

/// **认一颗社交链接控件** —— 类名优先（`SPTArtistExternalSocialLinkButton`，语言无关），
/// 其次是文字 / URL 主机名。认不出返回 nil。
///
/// 返回值里的 `url` 是**从控件或它的 model 上读到的真链接**（读不到就是 nil ⇒
/// `ArtistBioSheet` 退回"把点击转发给控件本身"）。
func eeveeArtistBioLink(from view: UIView) -> (kind: String, title: String, url: URL?)? {
    let className = NSStringFromClass(type(of: view))
    let classHit = className.contains(eeveeArtistSocialLinkClassFragment)

    // ⚠️ 先做**便宜的早退**：这一支会被页面里每一拍每个节点调用（有界 800 节点 × 若干拍），
    // 而下面的 `eeveeControlText` 自己最多走 200 个节点 —— 不加这一道就是 O(n²)。
    let label = (view.accessibilityLabel ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let isTappable = view is UIControl || !(view.gestureRecognizers ?? []).isEmpty
    guard classHit || isTappable || !label.isEmpty else { return nil }

    var text = label
    if text.isEmpty, classHit || isTappable {
        text = eeveeControlText(of: view).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    let url = eeveeSocialLinkURL(in: view)
    // 文字 / 主机名里认类型（类名命中但读不到任何文字时，交给 URL 主机名或兜底的 "link"）。
    let haystack = (text + " " + (url?.host ?? "")).lowercased()
    let kinds: [(kind: String, title: String, needles: [String])] = [
        ("wikipedia", "维基百科", ["wikipedia", "维基", "ウィキ"]),
        ("twitter", "Twitter", ["twitter", "推特", "x.com"]),
        ("instagram", "Instagram", ["instagram"]),
        ("facebook", "Facebook", ["facebook"]),
        ("tiktok", "TikTok", ["tiktok", "抖音"]),
        ("whatsapp", "WhatsApp", ["whatsapp", "wa.me"]),
        ("website", "网站", ["official site", "official website", "官网", "官方网站", "website", "网站"]),
    ]
    let match = kinds.first { entry in entry.needles.contains { haystack.contains($0) } }
    guard classHit || match != nil || url != nil else { return nil }

    let kind = match?.kind ?? "link"
    let title = match?.title ?? (text.isEmpty ? (url?.host ?? "链接") : text)
    return (kind, title, url)
}

/// 在控件自己、以及它挂着的 model 上**逐键试**着读一个链接。
///
/// ⚠️ 每一次 `value(forKey:)` 之前都要 `responds(to:)`：KVC 撞到不存在的键会抛
/// ObjC 异常，Swift 的 `try` 接不住 —— 那是崩溃，不是错误。
func eeveeSocialLinkURL(in view: UIView) -> URL? {
    if let direct = eeveeSocialLinkURL(on: view as NSObject) { return direct }
    for key in eeveeSocialLinkModelKeys {
        guard view.responds(to: NSSelectorFromString(key)),
              let model = view.value(forKey: key) as? NSObject else { continue }
        if let nested = eeveeSocialLinkURL(on: model) { return nested }
    }
    return nil
}

func eeveeSocialLinkURL(on object: NSObject) -> URL? {
    for key in eeveeSocialLinkURLKeys {
        guard object.responds(to: NSSelectorFromString(key)),
              let value = object.value(forKey: key) else { continue }
        if let url = value as? URL { return url }
        if let string = value as? String,
           let url = URL(string: string),
           url.scheme != nil {
            return url
        }
    }
    return nil
}

/// 一颗社交链接的**短名**（画在胶囊上）。
func eeveeArtistBioLinkTitle(for kind: String) -> String {
    switch kind {
    case "wikipedia": return "维基百科"
    case "twitter": return "Twitter"
    case "instagram": return "Instagram"
    case "facebook": return "Facebook"
    case "tiktok": return "TikTok"
    case "whatsapp": return "WhatsApp"
    case "website": return "网站"
    default: return "链接"
    }
}

// MARK: - Spotify 自己的「关于艺人」数据模型（`SPTArtistAbout`）
//
// 从 `SPTArtistAbout` 上读**姓名**。
//
// 下面这几个读法全部对着**二进制的类 → 方法表**写（`SPTArtistAbout` 的方法
// 逐字：`artistName` / `biographyText` / `socialLinks` / `monthlyListenersCount` /
// `globalChartPosition` / `isRegistered` / `artistFactDictionaries`）。
func eeveeArtistAboutName(from about: NSObject) -> String? {
    guard about.responds(to: NSSelectorFromString("artistName")),
          let name = about.value(forKey: "artistName") as? String else { return nil }
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

/// 从 `SPTArtistAbout` 上读**完整简介** —— 这是"关于艺人"的**权威正文**。
///
/// 为什么这才是正解（解决方法总不能是正则式匹配字吧）：界面那张卡里除了正文还画着
/// 艺人名与收听人数，**任何**从界面拼文字的方案都得靠"猜哪一行不是正文"；而这个字段就是
/// 正文本身，一个字都不多。它同时不受界面那条
/// `is_async_biography_truncation_enabled` 截断的影响。
func eeveeArtistAboutBiography(from about: NSObject) -> String? {
    guard about.responds(to: NSSelectorFromString("biographyText")),
          let raw = about.value(forKey: "biographyText") as? String else { return nil }
    let cleaned = eeveePlainArtistAboutText(raw)
    return cleaned.isEmpty ? nil : cleaned
}

/// `SPTArtistAbout.socialLinks` → 一串 `(kind, 真链接)`。
///
/// `SPTArtistSocialLink` 的方法表（同一份 dump）：`twitter` / `facebook` / `instagram` /
/// `wikipedia` / `whatsapp` / `tiktok`，属性类型全是 **`NSURL *`**，另有
/// `urlForSocialLinkType:`。⇒ 用户要的"维基 / 推特链接"在这里是**现成的地址**，
/// 不用点、不用转发、也不用拼搜索页。
func eeveeArtistAboutLinks(from about: NSObject) -> [(kind: String, url: URL)] {
    guard about.responds(to: NSSelectorFromString("socialLinks")),
          let links = about.value(forKey: "socialLinks") as? NSObject else { return [] }

    var out: [(kind: String, url: URL)] = []
    let kinds = ["wikipedia", "twitter", "instagram", "facebook", "tiktok", "whatsapp"]
    for kind in kinds {
        guard links.responds(to: NSSelectorFromString(kind)),
              let value = links.value(forKey: kind) else { continue }
        if let url = value as? URL {
            out.append((kind, url))
        } else if let string = value as? String,
                  let url = URL(string: string),
                  url.scheme != nil {
            out.append((kind, url))
        }
    }
    return out
}

/// `SPTArtistAbout.biographyText` 是**带标记的纯文本** —— 按 Spotify 自己的规则落地成纯文本。
///
/// 那三条规则在二进制里逐字可读（@184282728）：
/// ```
/// (\r\n|\n)
/// <br>
/// <a href="spotify:search:[^"]+">([^<]+)</a>   →  $1
/// ```
/// 这里是**同一件事的 Swift 写法**：`<br>` 折算成换行、锚点只留标签文字、其余标签去掉。
/// ⚠️ 这与"靠文字猜哪一行是正文"是两回事：这里处理的字段**本来就只有正文**。
func eeveePlainArtistAboutText(_ raw: String) -> String {
    var text = raw
    text = text.replacingOccurrences(of: "\r\n", with: "\n")
    text = text.replacingOccurrences(of: "\r", with: "\n")
    for token in ["<br>", "<br/>", "<br />", "</p>", "</div>"] {
        text = text.replacingOccurrences(of: token, with: "\n", options: .caseInsensitive)
    }
    if let anchors = try? NSRegularExpression(pattern: "<a [^>]*>([^<]*)</a>", options: .caseInsensitive) {
        let range = NSRange(text.startIndex..., in: text)
        text = anchors.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "$1")
    }
    if let tags = try? NSRegularExpression(pattern: "<[^>]+>", options: []) {
        let range = NSRange(text.startIndex..., in: text)
        text = tags.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
    }
    let entities = [
        ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", " "),
    ]
    for (entity, value) in entities {
        text = text.replacingOccurrences(of: entity, with: value)
    }
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// 在**活着的对象**里找那个"关于艺人"的模型（`SPTArtistAbout`）—— 不 hook、不联网，
/// 只是问一句"你响应 `biographyText` 吗"。
///
/// 给数据线没接上时留一条**零风险**的备用路（比如那一页的 loader 没被创建）。
/// 有界（默认 600 个节点）；每一步都先 `responds(to:)`，不存在的方法名不会被问。
func eeveeArtistAboutModel(in root: UIView, limit: Int = 600) -> NSObject? {
    let selector = NSSelectorFromString("biographyText")
    var queue: [UIView] = [root]
    var visited = 0
    while !queue.isEmpty, visited < limit {
        let view = queue.removeFirst()
        visited += 1
        if view.responds(to: selector) { return view }
        queue.append(contentsOf: view.subviews)
    }
    return nil
}

/// 「关于艺人」那一块里那些**不是简介**的整行文字 —— 存正文之前按**整行**跳过。
///
/// 那张卡里除了正文，还画着**艺人名**与**收听人数**两行；
/// `eeveeArtistBioBlockText` 是"把卡里所有文字按位置拼起来" ⇒ 这两行被当成正文收进了
/// `bioTexts`。这里按行剔掉，**段与段之间的空行保留**。
///
/// ⚠️ 判据只在**已经认出来的那张卡片内部**用（`eeveeArtistBioBlockText` 的返回值），
/// 别拿去筛页面上别处的文字。
let eeveeArtistBioChromeLines: Set<String> = [
    "关于", "关于艺人", "更多", "展开", "收起", "显示更多", "阅读更多", "查看全部",
    "播放", "关注", "已关注", "关注中", "分享",
    "About", "More", "Show more", "Read more", "See more", "Play", "Follow", "Following", "Share",
    // Spotify 自己给 About 那块画的**社交链接按钮**（dump:21074-21079 的
    // `SPTArtistAbout:sArtist*ButtonTitle` 就是它们的文案）—— 那是入口、不是正文。
    "维基百科", "维基百科中打开", "在维基百科中打开", "Wikipedia",
    "Twitter", "X", "Instagram", "Facebook", "TikTok", "WhatsApp",
    "网站", "官网", "官方网站", "Website", "Official site",
]

/// 「每月有 x 名听众」那类行的特征词 —— 必须**同时**含数字才算（见 `eeveeSanitizedArtistBio`）。
let eeveeArtistBioListenerWords: [String] = [
    "听众", "listener", "リスナー", "zuhörer", "auditeurs", "ascoltatori", "oyentes", "слушател",
]

/// 把从"关于艺人"卡里读到的文字**收拾成真正的简介**：剔掉艺人名那行、收听人数那行、
/// Spotify 自己那几个按钮文案，并收掉首尾空行（段间空行保留）。
///
/// 读不到正文时（剔完什么都不剩）**原样返回** —— 宁可把原文交出去，也不能把简介吞掉。
func eeveeSanitizedArtistBio(_ text: String, artistName: String) -> String {
    let name = artistName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    var kept: [String] = []
    var dropped = 0

    for rawLine in text.components(separatedBy: "\n") {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.isEmpty {
            // 段之间的空行只留一行（Spotify 常常一段一个 label，拼起来之后空行就是段距）。
            if let last = kept.last, !last.isEmpty { kept.append("") }
            continue
        }
        let folded = line.lowercased()
        if !name.isEmpty, folded == name {
            dropped += 1
            continue
        }
        if eeveeArtistBioChromeLines.contains(line) {
            dropped += 1
            continue
        }
        // ⚠️ 必须**带数字**才算收听人数那行 —— 简介正文里出现"听众"这个词太正常了。
        if line.contains(where: { $0.isNumber }),
           eeveeArtistBioListenerWords.contains(where: { folded.contains($0) }) {
            dropped += 1
            continue
        }
        kept.append(line)
    }

    while let last = kept.last, last.isEmpty { kept.removeLast() }
    guard !kept.isEmpty else { return text }

    let cleaned = kept.joined(separator: "\n")
    if dropped > 0 {
        let before = text.count
        let after = cleaned.count
        writeDebugLog(
            "[ArtistBio] body cleaned — dropped \(dropped) non-bio line(s), \(before) → \(after) char"
        )
    }
    return cleaned
}

/// 「关于艺人」那一块里的**整段正文**：块里所有文字**按位置顺序**拼起来（每段一行）。
/// 为什么不是"取最长的那一段"（见 `eeveeArtistBio` 里那段说明）：字数门槛误伤短简介，
/// 而"最长"在卡片里会挑错东西；Spotify 又常常**一段一个 label**，只取最长那一个会把正文
/// 切成一段、段之间的空行也一起丢掉。
///
/// 判据只在**已经认出来的那张卡片内部**用（`eeveeArtistBioCard` 的返回值），
/// 不会拿到页面上别处的文字；走查仍按本仓库纪律**有界**（300 个节点）。
func eeveeArtistBioBlockText(in card: UIView) -> String? {
    var blocks: [(y: CGFloat, x: CGFloat, text: String)] = []
    var queue: [UIView] = [card]
    var visited = 0

    while !queue.isEmpty, visited < 300 {
        let view = queue.removeFirst()
        visited += 1

        // "每月有 x 名听众" / 排行榜那两块**整块**跳过（按类名 / id 认，
        // 见 `eeveeIsArtistBioNonBodyChrome`）—— 它们不是简介，而且与语言无关。
        if eeveeIsArtistBioNonBodyChrome(view) { continue }

        var raw: String?
        if let label = view as? UILabel { raw = label.text }
        if let textView = view as? UITextView { raw = textView.text }

        if let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
           !trimmed.isEmpty,
           !eeveeArtistBioUILabels.contains(trimmed) {
            let origin = view.convert(view.bounds.origin, to: card)
            blocks.append((origin.y, origin.x, trimmed))
        }
        queue.append(contentsOf: view.subviews)
    }

    guard !blocks.isEmpty else { return nil }
    let ordered = blocks.sorted { lhs, rhs in
        lhs.y == rhs.y ? lhs.x < rhs.x : lhs.y < rhs.y
    }
    return ordered.map(\.text).joined(separator: "\n")
}

/// 一棵子树里**最长的那段文字** —— 艺人简介就在 `SPTArtistAboutBiographyView` 的正文里
/// （`UILabel` / `UITextView` 两种都可能，取最长的那个）。
///
/// `minimum` = "短于这个字数不算正文"（页头里"收听""已关注"那些短标签会被排除掉）。
func eeveeLongestText(in root: UIView, minimum: Int = 40) -> String? {
    var best: String?
    var queue: [UIView] = [root]
    var visited = 0
    while !queue.isEmpty, visited < 300 {
        let view = queue.removeFirst()
        visited += 1
        var text: String?
        if let label = view as? UILabel { text = label.text }
        if let textView = view as? UITextView { text = textView.text }
        if let candidate = text?.trimmingCharacters(in: .whitespacesAndNewlines),
           candidate.count >= minimum,
           candidate.count > (best?.count ?? 0) {
            best = candidate
        }
        queue.append(contentsOf: view.subviews)
    }
    return best
}

/// 往上找**最外层**的 `UIScrollView`（与 `eeveeScrollPageDown` 同一条，只是这里只取不滚）。
func eeveeOutermostScroll(from view: UIView) -> UIScrollView? {
    var outermost: UIScrollView?
    var node: UIView? = view.superview
    var levels = 0
    while let current = node, levels < 24 {
        levels += 1
        if let scroll = current as? UIScrollView { outermost = scroll }
        node = current.superview
    }
    return outermost
}

/// 以"点一下"的方式触发 Spotify 自己的控件。**返回真正走通的那条路**（`nil` = 一条都没通）。
///
/// ## 为什么返回值是"路"而不是 Bool（这是被真机打回来的第二次）
///
/// 旧版第一句是 `guard let control = control as? UIControl else { return false }` —— Spotify 的
/// shuffle / play 是 `Encore.Button` 一族（点击挂在 `UITapGestureRecognizer` 上）⇒ 这一句把转发
/// 整个吞掉；返回值又没人看 ⇒ **"日志说转发成功了、界面一动不动"**。
///
/// （艺人页 / 歌单页的**点击播放**按键没反应「艺人页左边那颗
/// 应该是 `i`…但现在是歌单的**随机播放**按钮，并且点击没反应」）—— 同样的现场**又复现了**。
/// 这一版把三件事一起做掉：
///
/// ① **UIControl 也要先看有没有 target**：没有 target 的 `UIControl`（`Encore.Button` 正是
/// 如此）`sendActions` 是**空转**，而旧代码会因此 `return true`，把后面那条手势路一起挡掉。
/// ② **包装层要往下钻**：按 id 找到的常常是 `ElementView<URL, Any, Any>` 那层包装
/// （本文件 `firstControl` 的注释早就写了），真控件在它里面。调用方现在统一先 `findControl`
/// 钻一次，这里再补一道"子树里找手势"。
/// ③ **tap recogniser 可能挂在子树里的某个视图上**，不在我们拿到的那一层。
///
/// ⚠️ **只走通一条就返回** —— 两条都发 = 一次点击触发两次（等于没点）。
@discardableResult
func eeveeFire(_ control: UIView?, skippingControlAction: Bool = false) -> String? {
    guard let control else { return nil }

    // ① 真·UIControl **且确实注册了 target** ⇒ 发那一个事件（顺序按"最可能的"排）。
    // `skippingControlAction` 给右上角那颗 `⋯` —— 它是 `Encore.Button`，
    // 菜单不走 `sendActions`，
    // 跳过这一档才有机会走到 ② 的手势那一条。
    if !skippingControlAction, let uiControl = control as? UIControl {
        for (event, label) in eeveeFireEvents where eeveeHasTargets(uiControl, event) {
            uiControl.sendActions(for: event)
            return "UIControl.\(label)"
        }
    }

    // ② 手势：先自己，再（有界地）往下钻子树。
    if let fired = eeveeFireGesture(in: control) { return fired }

    // ②½（右上角的三个点的按钮点击无反应）：
    // **再往子树里找一颗真的有 target 的 `UIControl`**。按 id 找到的是外层
    // `EncoreButton`，真正把菜单弹出来的那颗 `CondensedButton` / 内部按钮可能在它里面；
    // 旧版只往"手势"里钻，**子控件自己的 target/action 从来没试过**。
    // 有界（深度 4 / 120 个节点）、只发第一颗有 target 的，不会把一次点击变成两次。
    if let fired = eeveeFireSubControlAction(in: control) { return fired }

    // ③有界地再往上看两层。
    //
    // ⚠️ 两道闸门（只在"自己+子树都没有"时才走到这里，而且最多两层）：
    // · **不碰 `UIScrollView`** —— 那上面的 tap 是"点空白关页面"那一类；
    // · **不碰比目标宽太多的容器** —— 免得点到整页/整段那一级。
    var ancestor = control.superview
    var levels = 0
    while let current = ancestor, levels < 2 {
        let tooWide = current.bounds.width > control.bounds.width * 1.6 + 40
        if !tooWide, !(current is UIScrollView),
           let fired = eeveeFireRecognizers(of: current) {
            return "ancestor\(levels + 1).\(fired)"
        }
        ancestor = current.superview
        levels += 1
    }
    return nil
}

/// **比 `eeveeFire` 更宽一档的转发** —— 只给艺人页那颗 `i`（"关于艺人"）用。
///
/// 三档，走通一档就返回：
/// ① 先按 `eeveeFire` 的老三档（自己 → 子树 → 上两层）；
/// ② **再往上走 6 层**找 tap（闸门照旧：不碰 `UIScrollView` / `UICollectionView` / `UITableView`，
/// 也不碰比目标宽太多的容器）；
/// ③ 祖先链上有 `UICollectionViewCell` / `UITableViewCell` 就走**它的选中回调** ——
/// 这正是真人点一下走的那条路。
@discardableResult
func eeveeFireWide(_ view: UIView?, skippingControlAction: Bool = false) -> String? {
    guard let view else { return nil }
    if let fired = eeveeFire(view, skippingControlAction: skippingControlAction) { return fired }

    var node: UIView? = view.superview
    var levels = 0
    while let current = node, levels < 6 {
        if current is UIScrollView || current is UICollectionView || current is UITableView { break }
        let tooWide = current.bounds.width > view.bounds.width * 1.8 + 60
        if !tooWide, let fired = eeveeFireRecognizers(of: current) {
            return "wide.ancestor\(levels + 1).\(fired)"
        }
        node = current.superview
        levels += 1
    }
    return eeveeSelectAncestorCell(of: view)
}

/// 顺着祖先链找 `UICollectionViewCell` / `UITableViewCell`，**替用户"选中"它**。
///
/// ⚠️ 调的是 delegate 的可选方法（`collectionView(_:didSelectItemAt:)` / `tableView(_:didSelectRowAt:)`），
/// 也就是真人点一下走的那一条；`selectItem` 只是把选中态一起做掉（Spotify 的 cell 多半自己画高亮）。
func eeveeSelectAncestorCell(of view: UIView) -> String? {
    var node: UIView? = view
    var levels = 0
    while let current = node, levels < 10 {
        if let cell = current as? UICollectionViewCell {
            if let collection = eeveeEnclosingCollectionView(of: cell),
               let indexPath = collection.indexPath(for: cell) {
                collection.selectItem(at: indexPath, animated: false, scrollPosition: [])
                guard let delegate = collection.delegate else {
                    return "cell.selected(\(indexPath.section),\(indexPath.item)) but no delegate"
                }
                delegate.collectionView?(collection, didSelectItemAt: indexPath)
                return "cell.didSelectItemAt(\(indexPath.section),\(indexPath.item))"
            }
        }
        if let cell = current as? UITableViewCell {
            if let table = eeveeEnclosingTableView(of: cell), let indexPath = table.indexPath(for: cell) {
                table.selectRow(at: indexPath, animated: false, scrollPosition: .none)
                guard let delegate = table.delegate else {
                    return "row.selected(\(indexPath.section),\(indexPath.row)) but no delegate"
                }
                delegate.tableView?(table, didSelectRowAt: indexPath)
                return "row.didSelectRowAt(\(indexPath.section),\(indexPath.row))"
            }
        }
        node = current.superview
        levels += 1
    }
    return nil
}

func eeveeEnclosingCollectionView(of view: UIView) -> UICollectionView? {
    var node: UIView? = view.superview
    while let current = node {
        if let collection = current as? UICollectionView { return collection }
        node = current.superview
    }
    return nil
}

func eeveeEnclosingTableView(of view: UIView) -> UITableView? {
    var node: UIView? = view.superview
    while let current = node {
        if let table = current as? UITableView { return table }
        node = current.superview
    }
    return nil
}

/// `sendActions` 候选事件。**顺序有讲究**：`primaryActionTriggered` 是 iOS 14+ 那个"主操作"
/// 事件，Spotify 的 Encore 按钮注册的多半是它；`touchUpInside` 是经典那颗。
let eeveeFireEvents: [(UIControl.Event, String)] = [
    (.primaryActionTriggered, "primaryActionTriggered"),
    (.touchUpInside, "touchUpInside"),
    (.touchDown, "touchDown"),
]

func eeveeHasTargets(_ control: UIControl, _ event: UIControl.Event) -> Bool {
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
func eeveeFireGesture(in root: UIView, depthLimit: Int = 6, nodeLimit: Int = 200) -> String? {
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

/// 往子树里找一颗**注册了 target/action 的 `UIControl`**，替用户按下去。
///
/// 只给 `eeveeFire` 的第 ②½ 档用：外层拿到的是 `EncoreButton`，菜单真正的动作可能挂在
/// 它内部那颗 `CondensedButton` 上。有界（深度 4 / 120 节点），**只发第一颗**有 target 的
/// —— 一次点击绝不能变成两次。
func eeveeFireSubControlAction(in root: UIView) -> String? {
    var queue: [(view: UIView, depth: Int)] = root.subviews.map { ($0, 1) }
    var visited = 0
    while !queue.isEmpty, visited < 120 {
        let (view, depth) = queue.removeFirst()
        visited += 1
        if let control = view as? UIControl {
            for (event, label) in eeveeFireEvents where eeveeHasTargets(control, event) {
                control.sendActions(for: event)
                return "subControl.\(NSStringFromClass(type(of: control))).\(label)"
            }
        }
        guard depth < 4 else { continue }
        for sub in view.subviews { queue.append((sub, depth + 1)) }
    }
    return nil
}

/// **pw 的 `SGRActivate` / `SGRFire` 逐行移植**（`Redesigned/Kit/SGRRestyle.m`）。
///
/// 这三个点这部分能不能**直接抄 pw 的**—— 能，而且本来就该抄：
/// 他们已经把"点一颗 Spotify 自己的按钮"这件事收敛成了两条规则，我们这边却是一长串
/// 自己发明的档位（手势 `_targets` 读不到、无障碍返回 false、子控件没 target…）。
///
/// pw 的做法（注释逐字）：
/// > the first control under it, through the actions it registered, and through accessibility
/// > for an Encore control that reads its touches from a gesture recognizer instead.
///
/// ① 在子树里找**第一颗 `UIControl`**（含自身）；
/// ② 看它注册了哪些事件：**`primaryActionTriggered` 优先，其次 `touchUpInside`**，
/// 两个都没有就**什么都不发**（`SGRFire` 返回 NO）；
/// ③ ②没发出去 ⇒ `accessibilityActivate`（Encore 那一族很多就把"点一下"实现成它）。
///
/// 与 `eeveeFire` 的分工：`eeveeFire` 那串档位保留作**兜底**（手势 / 祖先 / cell 选中），
/// 而**先**走这一个 —— 它才是 pw 在真机上验证过的那条。
///
/// - Returns: 走了哪一档（只进日志）。
@discardableResult
func eeveeActivate(_ source: UIView?) -> String? {
    guard let source else { return nil }

    // ① 子树里第一颗 UIControl（含自身）。
    var control: UIControl?
    var queue: [UIView] = [source]
    var visited = 0
    while !queue.isEmpty, visited < 120 {
        let view = queue.removeFirst()
        visited += 1
        if let found = view as? UIControl {
            control = found
            break
        }
        queue.append(contentsOf: view.subviews)
    }

    // ② pw 的 `SGRFire`：primary action → touch up inside → 什么都不发。
    if let control {
        let events: [(UIControl.Event, String)] = [
            (.primaryActionTriggered, "primaryActionTriggered"),
            (.touchUpInside, "touchUpInside"),
        ]
        for (event, label) in events where eeveeHasTargets(control, event) {
            control.sendActions(for: event)
            return "activate.\(label)(\(NSStringFromClass(type(of: control))))"
        }
    }

    // ③ 无障碍那一条（pw：`[target accessibilityActivate]`，target = control ?: source）。
    let target: UIView = control ?? source
    let activated = target.accessibilityActivate()
    return "activate.accessibility(\(activated))"
}

// MARK: - 弹层有没有出现（`⋯` 的点击结果）
//
// 屏幕上的"弹层迹象"：window 个数 + 类名带 Menu / Platter / Popover 的视图数。
struct EeveePopupSnapshot: Equatable {
    let windows: Int
    let menuLike: Int
}

/// `⋯` 点完之后**界面上到底多出了什么**。
///
/// 前几版日志只能证明"事件发出去了"，
/// 证明不了"菜单弹没弹"。这里数两样东西：**window 个数**（`UIMenu` / platter 常常自建一层
/// window）与**类名带 Menu / Platter / Popover 的视图数**。点之前数一次，0.9s 后再数一次：
/// 两次一样 ⇒ 这一档转发确实什么都没换来（下一步就该换"我们自己建菜单"那条路）。
func eeveePopupSnapshot() -> EeveePopupSnapshot {
    var windows = 0
    var menuLike = 0
    for scene in UIApplication.shared.connectedScenes {
        guard let windowScene = scene as? UIWindowScene else { continue }
        windows += windowScene.windows.count
        for window in windowScene.windows {
            var queue: [UIView] = [window]
            var visited = 0
            while !queue.isEmpty, visited < 1500 {
                let view = queue.removeFirst()
                visited += 1
                let name = NSStringFromClass(type(of: view))
                if name.contains("Menu") || name.contains("Platter") || name.contains("Popover") {
                    menuLike += 1
                }
                queue.append(contentsOf: view.subviews)
            }
        }
    }
    return EeveePopupSnapshot(windows: windows, menuLike: menuLike)
}

/// 只进日志：一颗控件到底"为什么点不动"——target/action、手势、`UIMenu`、子控件各有哪些。
///
/// （右上角的三个点的按钮点击无反应）：上一版已经跳过 `sendActions`
/// 直接走手势，仍然没反应 ⇒ 不再猜。下一次点击 `⋯` 时把这一行打出来，就能分清：
/// ① 它其实有 target/action（只是事件类型不对）；
/// ② 它是一个 `UIButton.menu`（靠 UIKit 自己的触摸弹出，`sendActions` 天生无效）；
/// ③ 动作挂在子树里某颗子控件上（见 `eeveeFireSubControlAction`）；
/// ④ 只有手势，而手势的 target 在更上面一层。
func eeveeDescribeClickability(_ root: UIView?) -> String {
    guard let root else { return "nil" }

    var parts: [String] = []
    parts.append("class=\(NSStringFromClass(type(of: root)))")
    parts.append("id=\(root.accessibilityIdentifier ?? "-")")
    parts.append("uicontrol=\(root is UIControl)")

    if let control = root as? UIControl {
        var events: [String] = []
        for (event, label) in eeveeFireEvents {
            let targets = control.allTargets.compactMap { target -> String? in
                let actions = control.actions(forTarget: target, forControlEvent: event) ?? []
                guard !actions.isEmpty else { return nil }
                // `allTargets` 是 `Set<AnyHashable>` ⇒ 先当 `AnyObject` 再取动态类名
                // （直接 `type(of: target)` 会得到 `AnyHashable.Type`，不是 `AnyClass`）。
                let object = target as AnyObject
                return "\(NSStringFromClass(type(of: object))).\(actions.joined(separator: "+"))"
            }
            if !targets.isEmpty {
                events.append("\(label)=\(targets.joined(separator: "|"))")
            }
        }
        parts.append("targets=[\(events.isEmpty ? "none" : events.joined(separator: ";"))]")
    }

    if let button = root as? UIButton {
        parts.append("menu=\(button.menu == nil ? "nil" : "yes")")
        parts.append("showsMenuAsPrimaryAction=\(button.showsMenuAsPrimaryAction)")
    }

    let gestures = (root.gestureRecognizers ?? []).map { NSStringFromClass(type(of: $0)) }
    parts.append("gestures=[\(gestures.isEmpty ? "none" : gestures.joined(separator: ","))]")
    let interactions = root.interactions.map { NSStringFromClass(type(of: $0 as AnyObject)) }
    parts.append("interactions=[\(interactions.isEmpty ? "none" : interactions.joined(separator: ","))]")

    var subs: [String] = []
    var queue: [(view: UIView, depth: Int)] = root.subviews.map { ($0, 1) }
    var visited = 0
    while !queue.isEmpty, visited < 80, subs.count < 3 {
        let (view, depth) = queue.removeFirst()
        visited += 1
        if let control = view as? UIControl {
            var labels: [String] = []
            for (event, label) in eeveeFireEvents where eeveeHasTargets(control, event) {
                labels.append(label)
            }
            if !labels.isEmpty {
                subs.append("\(NSStringFromClass(type(of: control))) [\(labels.joined(separator: "+"))]")
            }
        }
        guard depth < 4 else { continue }
        for sub in view.subviews { queue.append((sub, depth + 1)) }
    }
    parts.append("subControls=[\(subs.isEmpty ? "none" : subs.joined(separator: ","))]")

    return parts.joined(separator: "; ")
}

func eeveeFireRecognizers(of view: UIView) -> String? {
    let targetKey = NSSelectorFromString("target")
    let actionKey = NSSelectorFromString("action")
    for recognizer in view.gestureRecognizers ?? [] where recognizer is UITapGestureRecognizer {
        // （崩溃 `Spotify--150419.ips`）：
        // `value(forKey: "_targets")` 在**没有这个键**的 `UITapGestureRecognizer`（子类 / 系统
        // 自绘手势）上会抛 `valueForUndefinedKey:` —— 那是 ObjC 异常，Swift 接不住，直接 abort。
        // 先 `responds(to:)` 再读；没有就跳过这一颗，绝不拿 KVC 去赌。
        guard recognizer.responds(to: NSSelectorFromString("_targets")),
              let pairs = recognizer.value(forKey: "_targets") as? [AnyObject] else { continue }
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
/// （（关注）功能正常。但是如果艺人已经关注了，它应该是有**绿色描边**的，
/// 但现在没有）：旧版只有 `(source as? UIControl)?.isSelected` 一条判据 —— 而按 id 找到的
/// 常常是 `ElementView<…>` **包装层**（`isSelected` 恒假），于是**永远不变绿**。
/// `firstControl` 的注释里逐字写着这件事，但 Follow 那颗当时没走它。
///
/// 这里把三条能拿到的信号都试一遍，从最标准到最兜底：
/// ① `UIControl.isSelected`；② `accessibilityTraits` 里的 `.selected`（App 暴露开关态的标准做法）；
/// ③ **文字里的"已关注"标记**（`Follow` 是文字按钮：关注 ↔ 已关注 / Follow ↔ Following）。
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

let eeveeFollowingMarkers = ["已关注", "已追蹤", "Following", "Siguiendo", "Abonniert", "已關注"]

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
//
// 「镜像按钮」：字形取自被藏起来的 Spotify 控件，点击转发给它。
