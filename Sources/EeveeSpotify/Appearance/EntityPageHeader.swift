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
    static let rowHeight: CGFloat = 48      // = pw 的 `SGRActionHeight`
    /// 两侧按钮那圈**玻璃圆**的直径（= pw 的 `SGRGlassCircleSize`）。
    static let glassCircle: CGFloat = 44
    /// 两侧按钮的字形边长。★ 2026-10-13（用户看真机：「旁边的按键小了点」）：
    /// 原来是"按 48pt 的 27% 内缩"≈26pt，看着比中间那颗胶囊轻 —— pw 是 44pt 玻璃圆里放字形，
    /// 所以这里改成**固定 22pt 字形 + 44pt 玻璃圆**，与 Music app 的分量对齐。
    static let glyphSide: CGFloat = 22
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

/// 以"点一下"的方式触发 Spotify 自己的控件。
///
/// **只发一个事件**：注册了 `primaryActionTriggered` 就发它，否则发 `touchUpInside`
/// —— 两个都发会把开关按两下（等于没按）。
@discardableResult
func eeveeFire(_ control: UIView?) -> Bool {
    guard let control = control as? UIControl else { return false }

    let hasPrimary = control.allTargets.contains { target in
        !(control.actions(forTarget: target, forControlEvent: .primaryActionTriggered)?.isEmpty ?? true)
    }
    control.sendActions(for: hasPrimary ? .primaryActionTriggered : .touchUpInside)
    return true
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
    var fallbackGlyph: UIImage?
    /// 关态颜色 / 开态颜色（开态按源控件的 `isSelected` 判断）。
    var glyphColor: UIColor = .label
    var onGlyphColor: UIColor = .systemGreen

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
    func feed(from control: UIView?) {
        source = control
        let glyph = eeveeGlyph(of: control) ?? fallbackGlyph
        glyphView.image = glyph?.withRenderingMode(.alwaysTemplate)
        accessibilityLabel = control?.accessibilityLabel ?? accessibilityLabel
        refreshTint()
    }

    private func refreshTint() {
        let isOn = (source as? UIControl)?.isSelected ?? false
        glyphView.tintColor = isOn ? onGlyphColor : glyphColor
    }

    @objc private func tapped() {
        refreshTint()
        writeDebugLog("[EntityPageHeader] header button tapped (source \(source == nil ? "missing" : "found"))")
        _ = eeveeFire(source)
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
        source = control
        if let glyph = eeveeGlyph(of: control) {
            glyphView.image = glyph.withRenderingMode(.alwaysTemplate)
        }
    }

    @objc private func tapped() {
        writeDebugLog("[EntityPageHeader] play capsule tapped (source \(source == nil ? "missing" : "found"))")
        _ = eeveeFire(source)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
        // 玻璃铺满整颗胶囊（圆角跟胶囊走）。
        if let glass {
            if glass.frame != bounds { glass.frame = bounds }
            glass.layer.cornerRadius = bounds.height / 2
        }

        // [字形][6pt][Play] 整体居中
        let glyphSide: CGFloat = 20
        let glyphWidth = glyphView.image == nil ? 0 : glyphSide
        let spacing: CGFloat = glyphWidth > 0 ? 6 : 0
        let wordWidth = ceil(wordLabel.sizeThatFits(
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

    private let titleLabel = EntityPageHeaderView.makeLabel(
        style: .title2, size: 22, weight: .bold, color: .label, lines: 2, alignment: .center
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
        height += EntityPageHeaderMetrics.rowHeight
        if !aboutLabel.isHidden {
            height += EntityPageHeaderMetrics.aboutAbove
            height += ceil(aboutLabel.sizeThatFits(CGSize(width: text, height: .greatestFiniteMagnitude)).height)
        }
        return height
    }

    override func layoutSubviews() {
        super.layoutSubviews()

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
        let side = EntityPageHeaderMetrics.rowHeight
        let playWidth = EntityPageHeaderMetrics.playMinWidth
        let play = CGRect(x: round((width - playWidth) / 2), y: y, width: playWidth, height: side)
        playButton.frame = play
        shuffleButton.frame = CGRect(
            x: play.minX - EntityPageHeaderMetrics.rowSpacing - side, y: y, width: side, height: side
        )
        trailingButton.frame = CGRect(
            x: play.maxX + EntityPageHeaderMetrics.rowSpacing, y: y, width: side, height: side
        )
        y += side

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
