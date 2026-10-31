// 页头那三块我们自己画的视图。从 `EntityPageHeader.swift` 原样拆出；尺寸常量在 `EntityPageHeaderMetrics`。
import Foundation
import UIKit

final class EntityPageHeaderButton: UIControl {

    private let glyphView = UIImageView()
    private weak var source: UIView?
    /// 那圈玻璃（44pt 圆，见 `layoutSubviews`）。
    private var glass: UIVisualEffectView?

    /// 源控件取不到字形时的兜底（SF Symbol）。
    ///
    /// **换兜底字形要立刻生效** —— 艺人页那一颗是 Follow（文字按钮，
    /// `eeveeGlyph` 永远拿不到字形），"未关注 / 已关注"就是靠这里换一对 SF Symbol 表达的；
    /// 而 `feed(from:)` 在"源没变"时会早退，所以只能在这一侧的 didSet 里补。
    var fallbackGlyph: UIImage? {
        didSet {
            // （艺人页左边应该是一个 `i`…但现在是歌单的**随机播放**按钮）：
            // **显式设的兜底字形必须立刻生效**。旧版这里是 `guard glyphView.image == nil` ——
            // 而 `applyToArtistPage` 先 `updateRow`（那一刻 leading 还是 shuffle ⇒ `feed` 取到
            // shuffle 的字形），随后才 `setLeadingGlyph(info.circle)`，于是被这一句**挡掉**
            // ⇒ 那颗按钮永远是随机播放的样子（功能也没接对，见那边的说明）。
            // 顺序上不会误伤：`updateRow` 里兜底是**先设、后 feed**，真字形仍然赢。
            guard let fallbackGlyph else { return }
            glyphView.image = fallbackGlyph.withRenderingMode(.alwaysTemplate)
        }
    }
    /// （播放按键右边的**添加艺人**显示有问题，改成中空的五角星（和 AM 一样）……
    /// 点击之后（即收藏艺人之后）变成现在的绿色勾）：
    /// **强制用兜底字形**，不采用 Spotify 那颗按钮自己的图。只给艺人页的 Follow 用，
    /// 而且只在**未关注**那一档打开 —— 那颗在未关注时是"＋人"，用户要的是 AM 那种中空五角星；
    /// 已关注时保持原样（Spotify 自己的绿勾，取不到才用 `checkmark` 兜底）。
    var prefersFallbackGlyph = false {
        didSet {
            // 与 `fallbackGlyph` 的 didSet 同一条理由：`feed(from:)` 在"源没变"时会早退，
            // 所以显式设的东西必须**当场**落到 `glyphView` 上。
            guard prefersFallbackGlyph, let fallbackGlyph else { return }
            glyphView.image = fallbackGlyph.withRenderingMode(.alwaysTemplate)
        }
    }
    /// 关态颜色 / 开态颜色（开态按源控件的 `isSelected` 判断）。
    var glyphColor: UIColor = .label
    var onGlyphColor: UIColor = .systemGreen
    /// 这颗按钮的**身份**（`shuffle` / `trailing`）—— 只进日志：用户报"右边那颗和别的按钮重合"时，
    var role = "side button"

    /// （如果未收藏艺人，点击收藏之后，按钮不会变绿，删除艺人之后，才会变绿）：
    /// **点击之后**再去读一次源控件的状态。
    ///
    /// 根因是时序：`tapped` 第一句就 `refreshTint`，而那一刻 Spotify **还没**把 Follow 的
    /// "已关注"写上去 —— 于是读到的是**点击前**的旧状态；之后如果页面没有新的布局回合，
    /// 这颗按钮就一直停在旧状态，直到下一次点击（于是"取消关注之后反而变绿"）。
    /// 这里在转发之后排几次复查，让状态跟上来（`refreshArtistFollow` 还会一起换字形）。
    var afterFire: (() -> Void)?

    /// 复查节拍：Follow 是网络请求，0.2s 往往还没回来；3.0s 是最后兜底。
    /// 只在按钮还挂在窗口上时执行（离开页面就不再打扰）。
    private static let afterFireDelays: [TimeInterval] = [0.2, 0.7, 1.6, 3.0, 5.0]

    /// `⋯` 的点击能力只打一次（见 `eeveeDescribeClickability`）—— 一次会话里够定位就行。
    private static var didLogMoreClickability = false

    /// 给调用方（`EntityPageHeaderView.updateFollow`）一个"立刻重读"的入口。
    func refreshTintNow() {
        refreshTint()
    }

    /// （歌单页右上角有一个**点不动的三点按键**）：
    /// Spotify 那颗 `⋯` 是 `Encore.Button` 一族，菜单靠**它自己的交互**弹出来，不是 target/action ——
    /// 界面一动不动）。
    /// ⇒ 这一颗**跳过第 ① 档**（送 target/action），直接走手势那一档（见 `eeveeFire` 的三档）。
    var skipsControlAction = false

    /// （点击后**跳转到关于艺人模块**）：这一颗点下去要**先把源滚进视野**
    /// 再转发 —— 艺人页的"关于"（`SPTArtistAboutBiographyView`）在列表很下面，只转发不滚动的话
    /// 什么都看不见。由调用方按需打开。
    var scrollsSourceIntoView = false

    var firesDeep = false

    var presentsOwnBio = false

    /// **真正要转发的目标**（可以不是 `source`）。
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
        // 两侧按钮嵌一圈玻璃圆（pw 的 `SGRGlassInside`
        // 用的就是 `SGRGlassCircleSize = 44`）—— 字形 22pt 落在 44pt 玻璃圆里，分量才对得上
        // 中间那颗胶囊。
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
    /// **同一个源控件只取一次字形** —— 这一拍在页头折叠的每一帧都会走到，
    /// 而"取字形"要遍历源控件的子树、还会 `withRenderingMode` 造一张新图。
    func feed(from control: UIView?) {
        let sameSource = (source as? NSObject) === (control as? NSObject)
        source = control
        accessibilityLabel = control?.accessibilityLabel ?? accessibilityLabel
        refreshTint()
        guard !sameSource || glyphView.image == nil else { return }

        let glyph = prefersFallbackGlyph ? fallbackGlyph : (eeveeGlyph(of: control) ?? fallbackGlyph)
        glyphView.image = glyph?.withRenderingMode(.alwaysTemplate)
    }

    private func refreshTint() {
        let isOn = eeveeIsOn(source)
        glyphView.tintColor = isOn ? onGlyphColor : glyphColor
        // （如果艺人已经关注了，它应该是有**绿色描边**的，但现在没有）：
        // Spotify 自己的"已关注"就是**绿字 + 绿描边**，AM 那颗收藏键也是描边态
        // ⇒ 把那圈玻璃的边描上（玻璃本身就是那颗 44pt 圆，圆角在 `layoutSubviews` 里跟着走）。
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

        if presentsOwnBio {
            let name = EntityPageHeaderManager.currentArtistName
            // 晚：**"不滚动就读简介"那一整套已删掉** —— 后台延后 1.5s 读 +
            // 每 1.5s 补读、点击时静默把列表翻一整趟 + 0.6s/1.6s 补扫，试过几轮都不成立
            // （那一段是懒加载的，不滚到就不建），而且每次都整页卡一下。
            // 现在只剩两件**零滚动**的事：
            // · 读缓存（用户滑到底之后被 `captureBioTextOnSight` 存下来的那份）；
            // · 认页面上**已经建出来**的那张卡（`eeveeArtistBioCard` 只做有界搜索）。
            // 都没有就照实弹占位符 —— 占位符里已经告诉用户"先滑到页面底部、再回来点"。
            var text = EntityPageHeaderManager.cachedBioText(for: name)
            if text == nil, let card = eeveeArtistBioCard(in: self) {
                EntityPageHeaderManager.artistBiographyAppeared(card)
                text = EntityPageHeaderManager.cachedBioText(for: name)
            }
            ArtistBioSheet.present(
                name: name,
                text: text,
                colour: EntityPageAppearance.currentFieldColour
            )
            return
        }

        // 转发目标：**优先 `fireTarget`**；只有没开"先滚进视野"这一档时才退回 `source`
        // （否则目标缺失时就会去点那颗只负责显示字形的 shuffle —— 见 `fireTarget` 的说明）。
        var target = fireTarget ?? (scrollsSourceIntoView ? nil : source)
        if target == nil, scrollsSourceIntoView {
            target = eeveeMaterialiseBio(from: self)
        }
        var scrolled = false
        // 右上角那颗 `⋯` 连续两版都"转发成功、界面不动" ⇒ 第一次点击时把它的
        // target/action、手势、`UIMenu`、子控件各有哪些**逐项打进日志**（只打一次）。
        if role == "more", !Self.didLogMoreClickability {
            Self.didLogMoreClickability = true
            writeDebugLog(
                "[EntityPageHeader] ⋯ clickability — \(eeveeDescribeClickability(target ?? source))"
            )
        }
        // （这三个点这部分能不能**直接抄 pw 的**）：
        // `⋯` 现在**只走 pw 那条** —— `eeveeActivate` 是 `SGRActivate` / `SGRFire` 的逐行移植
        // （子树里第一颗 `UIControl` → `primaryActionTriggered` → `touchUpInside` → 无障碍）。
        // 它只要发出过任何一个**控制事件**就算这一档用掉了：**不再叠**我们自己那串档位，
        // 否则一次点击会变成两次；只有它连事件都没发（只拿到 `activate.accessibility(false)`）时，
        // 才退回 `eeveeFire` / `eeveeFireWide` 那串兜底（手势 / 祖先 / cell 选中）。
        //
        // `targets=[touchUpInside=…]` 而 `fired: NOTHING` —— 是我们跳过了唯一有注册的那一档。
        // 其余按钮仍走老三档（play / shuffle / follow 本来就通，不冒险改）。
        var path = target == nil
            ? "NOTHING (no target at all — this button has no source)"
            : "NOTHING (the target has no action and no tap recogniser)"
        if let target {
            if scrollsSourceIntoView { scrolled = eeveeScrollIntoView(target) }

            if role == "more", let pw = eeveeActivate(target) {
                path = pw
                let sentControlEvent = pw.hasPrefix("activate.primaryActionTriggered")
                    || pw.hasPrefix("activate.touchUpInside")
                if !sentControlEvent {
                    path = (firesDeep
                        ? eeveeFireWide(target, skippingControlAction: true)
                        : eeveeFire(target, skippingControlAction: true)) ?? path
                }
            } else {
                // 那颗 `i` 走"宽转发"（祖先链上的 tap + cell 的选中回调），见 `eeveeFireWide`。
                path = (firesDeep
                    ? eeveeFireWide(target, skippingControlAction: skipsControlAction)
                    : eeveeFire(target, skippingControlAction: skipsControlAction)) ?? path
            }
        } else if scrollsSourceIntoView {
            // 目标那一段还没建出来（懒加载）⇒ 把页面往下滚一屏让它出现，**不转发**。
            scrolled = eeveeScrollPageDown(from: self)
            path = scrolled
                ? "NOTHING yet (the target is not built) — scrolled the page a screen to build it"
                : "NOTHING (the target is not built and the page has nothing to scroll)"
        }

        // `⋯` 还有最后一档 —— **无障碍激活**。很多自绘控件（包括 Encore 的）
        // 把"点一下"实现成 `accessibilityActivate`（VoiceOver 用的就是这条），而 target/action
        // 与手势都可能没有。只在前面几档全部落空时试，返回 true/false 都记进日志。
        if role == "more", path.hasPrefix("NOTHING"), let target {
            let activated = target.accessibilityActivate()
            path += activated ? " | accessibilityActivate=true" : " | accessibilityActivate=false"
        }

        // ⚠️ 不要在这些字符串**插值里写引号**：`swift_member_check.py` 的去字符串扫描器会提前
        // 收尾、把剩下的英文当裸标识符误报踩过，见 `EntityPageStatusBar`）。先拼好。
        let kind = (target ?? source).map { NSStringFromClass(type(of: $0)) } ?? "-"
        let isControl = (target ?? source) as? UIControl != nil
        let signals = eeveeOnSignals(source)
        writeDebugLog(
            "[EntityPageHeader] \(role) tapped — class \(kind), uicontrol=\(isControl),"
                + " scrolledIntoView=\(scrolled), fired: \(path); \(signals)"
        )

        // `⋯` 点完 0.9s 后再数一次"弹层迹象"。
        // 前几版日志只能说明事件发出去了，说不出菜单弹没弹（见 `eeveePopupSnapshot`）。
        if role == "more" {
            let before = eeveePopupSnapshot()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                let after = eeveePopupSnapshot()
                let appeared = after.windows > before.windows || after.menuLike > before.menuLike
                let verdict = appeared ? "something came up" : "nothing appeared"
                writeDebugLog(
                    "[EntityPageHeader] more result — window(s) \(before.windows) → \(after.windows),"
                        + " menu-like view(s) \(before.menuLike) → \(after.menuLike), \(verdict)"
                )
            }
        }

        // 点击之后源控件的状态才变（Follow 最明显，见 `afterFire`）。
        // 别只靠"下一次布局回合"——艺人页关注之后不一定还会布局一次。
        if let afterFire {
            for delay in Self.afterFireDelays {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self, self.window != nil else { return }
                    self.refreshTint()
                    afterFire()
                }
            }
        }
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

/// 中间那颗播放键。**和左右两颗同一套**：透明玻璃圆 + 实心三角字形。
///
/// （回退点击播放按键的播放按钮变透明的设计（设计成和旁边那两个按键
/// 一样的透明背景，只有线条吧）→ 随后「这个播放按钮的图标太丑了，换回之前那个图标」）：
/// 第一版把字形画成**中空描边三角**，用户看真机后觉得太丑 ⇒ **字形换回 SF Symbol
/// `play.fill`（实心三角）**；背景仍保持用户点名要的"和两侧一样的透明玻璃圆"，
/// 不再恢复白色圆盘。
/// ⚠️ 玻璃仍是 `eeveeMakeLightGlassView`（和两侧同一个函数），不是另写一套。
final class EntityPageHeaderPlay: UIControl {

    private let glyphView = UIImageView()
    private let wordLabel = UILabel()
    private weak var source: UIView?
    /// 圆形里那片玻璃（见 `init`）。
    private var glass: UIVisualEffectView?

    override init(frame: CGRect) {
        super.init(frame: frame)
        // 透明背景：底下的封面 / 取色底直接透出来，靠玻璃圆与白线字形保持可读性
        // （两侧那两颗就是这么做的，见 `EntityPageHeaderButton.init`）。
        backgroundColor = .clear
        layer.masksToBounds = true
        _ = eeveeInsertGlass(in: self, interactive: true)
        glass = subviews.first as? UIVisualEffectView

        glyphView.contentMode = .scaleAspectFit
        // 两侧字形用的是 `.label`（深色界面上就是白）—— 中间这颗跟它们走，不再用黑色。
        glyphView.tintColor = .label
        // 字形回到**实心三角**（`play.fill`）。上一版的中空描边三角用户看真机后
        // 说"太丑"，这里不再自己画图，直接用系统符号（加粗一档，放在 52pt 画布里分量够）。
        glyphView.image = Self.playGlyphImage()
        glyphView.isUserInteractionEnabled = false
        addSubview(glyphView)

        wordLabel.text = "am_header_play".localized
        wordLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        wordLabel.textColor = .label
        wordLabel.textAlignment = .center
        addSubview(wordLabel)

        addTarget(self, action: #selector(tapped), for: .touchUpInside)
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = wordLabel.text
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// 实心播放三角（`play.fill`）。只造一次 —— `layoutSubviews` / `feed` 都会走到。
    private static func playGlyphImage() -> UIImage? {
        let configuration = UIImage.SymbolConfiguration(pointSize: 44, weight: .bold)
        return UIImage(systemName: "play.fill", withConfiguration: configuration)?
            .withRenderingMode(.alwaysTemplate)
    }

    func feed(from control: UIView?) {
        source = control
        // 字形固定是我们自己的实心三角；`feed` 只负责记下"点它要转发给谁"。
        if glyphView.image == nil {
            glyphView.image = Self.playGlyphImage()
        }
    }

    /// **长按 = 随机播放**。
    ///
    /// 左边那颗位置让给 AM 的 `i`（"关于艺人"）之后，随机播放就没地方点了 ——
    /// 方案就是这一条：长按识别成功会**取消**这次触摸 ⇒ `touchUpInside` 不会跟着发，
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

        // **形状决定形态**。正方形时是"大圆 ▶"，扁的时是"▶ 播放"胶囊。
        //
        // （**那个槽里面就不需要文字了**）：胶囊现在**只画字形**，
        // 文字永远隐藏 —— 所以那颗 `wordLabel` 只留作无障碍文案，不再参与排版。
        // 形状仍然由布局决定（`EntityPageHeaderMetrics.playMinWidth` × `rowHeight`）。
        let isCircle = abs(bounds.width - bounds.height) < 8
        if !wordLabel.isHidden { wordLabel.isHidden = true }

        // **不再有白底**。两种形态都只留玻璃圆 + 线条字形，
        // 与左右两颗完全同材质（见类型说明）——所以这里连"圆形纯白 / 胶囊白 90%"那条分支一起删了。
        if backgroundColor != .clear { backgroundColor = .clear }
        glass?.alpha = 1

        // 字形**居中**（槽里没有文字要避让）。
        // （播放按钮里面的按键**不够大**）：圆形态 52；
        // 胶囊形态从 24 抬到 **28** —— 槽变宽之后 24 显得偏小。
        let glyphSide: CGFloat = isCircle ? 52 : 28
        let glyphWidth = glyphView.image == nil ? 0 : glyphSide
        let startX = round((bounds.width - glyphWidth) / 2)
        glyphView.frame = CGRect(x: startX, y: round((bounds.height - glyphSide) / 2),
                                 width: glyphWidth, height: glyphSide)
        wordLabel.frame = .zero
    }
}

// MARK: - 「最新发布」小卡片
//
// AM 艺人页三颗按钮下面那张卡片：
//
// ```
// ┌────────────────────────────────────┐
// │ [封面]  2026年8月22日               │
// │         空耳 - Single               │
// │         2 首歌曲                     │
// └────────────────────────────────────┘
// ```
//
// 数据在 `ArtistLatestReleaseSource`。
// 这一颗只负责画。
//
// （点击那个卡片应该是**跳转到对应的专辑**，而不是全部歌曲）：
// 卡片**可点**，但**不接受"我们自己编一个目标"** —— 点下去由 `EntityPageHeaderManager`
// 把点击**转发给页面里那一格**（`eeveeSelectAncestorCell`，走 `collectionView(_:didSelectItemAt:)`，
// 就是真人点那张卡的那一条）。数据来自苹果目录那条兜底时没有 Spotify 目标 ⇒ 那时卡片不可点
// （`isTappable = false`，不留"看得见、点不动"的控件）。
final class EntityPageHeaderReleaseCard: UIView {

    /// 高度与"卡片之间的间距"（`EntityPageHeaderView` 排版要用）。
    static let height: CGFloat = 96
    static let spacing: CGFloat = 10

    private let artworkView = UIImageView()
    private let dateLabel = UILabel()
    private let titleLabel = UILabel()
    private let metaLabel = UILabel()

    /// 点一下要做什么（由 `EntityPageHeaderView` 接到 manager 上；没有目标时保持 `nil`）。
    var onTap: (() -> Void)?

    /// 这张卡现在可不可点 —— 只改交互与无障碍，不改画法。
    var isTappable = false {
        didSet {
            guard isTappable != oldValue else { return }
            isUserInteractionEnabled = isTappable
            accessibilityTraits = isTappable ? .button : .staticText
        }
    }

    private static let artworkSide: CGFloat = 68
    private static let artworkInset: CGFloat = 13
    private static let textGap: CGFloat = 14
    private static let textInset: CGFloat = 12

    /// 图片缓存（同一张封面在页面重建时会再要一次）。
    private static let imageCache = NSCache<NSURL, UIImage>()
    private static let imageSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 16
        return URLSession(configuration: configuration)
    }()
    private var imageTask: URLSessionDataTask?
    private var imageURL: URL?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.white.withAlphaComponent(0.10)
        layer.cornerRadius = 16
        layer.cornerCurve = .continuous
        isUserInteractionEnabled = false

        artworkView.contentMode = .scaleAspectFill
        artworkView.clipsToBounds = true
        artworkView.layer.cornerRadius = 8
        artworkView.layer.cornerCurve = .continuous
        artworkView.backgroundColor = UIColor.white.withAlphaComponent(0.08)
        addSubview(artworkView)

        dateLabel.font = .systemFont(ofSize: 12)
        dateLabel.textColor = .secondaryLabel
        dateLabel.lineBreakMode = .byTruncatingTail
        addSubview(dateLabel)

        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.textColor = .label
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)

        metaLabel.font = .systemFont(ofSize: 12)
        metaLabel.textColor = .secondaryLabel
        metaLabel.lineBreakMode = .byTruncatingTail
        addSubview(metaLabel)

        // 手势一直挂着，交互由 `isTappable` 开关 —— 和别处"只改交互不改画法"同一个形状。
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap)))
    }

    @objc private func handleTap() {
        guard isTappable else { return }
        onTap?()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// 上一份数据的指纹（同一份不重画 —— 页头每一拍都会把卡片数据推一次）。
    private var lastContentSignature: String?

    /// 塞一份数据；`nil` 就清空（卡片本身由调用方显隐）。
    ///
    /// - Parameter artwork: 已经拿到的图（"艺人之选"那条从页面里直接读到 `UIImage`）。
    /// - Parameter artworkURL: 还没拿到的图（"最新发布"那条用 iTunes 的 URL，卡片自己下）。
    func update(
        title: String,
        date: String?,
        meta: String?,
        artwork: UIImage?,
        artworkURL: URL?
    ) {
        // 卡片挂到页头下面之后，这一条每一拍都会被调（`applyPick` 每拍都跑）——
        // 不拦一下会每帧取消并重启一次封面下载。
        let signature = [date ?? "", title, meta ?? "", artworkURL?.absoluteString ?? "-"]
            .joined(separator: "|")
        if artwork == nil, signature == lastContentSignature { return }
        lastContentSignature = signature

        dateLabel.text = date
        titleLabel.text = title
        metaLabel.text = meta
        accessibilityLabel = [date, title, meta].compactMap { $0 }.joined(separator: ", ")

        if let artwork {
            imageTask?.cancel()
            imageTask = nil
            imageURL = nil
            artworkView.image = artwork
        } else {
            loadArtwork(artworkURL)
        }
        setNeedsLayout()
    }

    private func loadArtwork(_ url: URL?) {
        imageTask?.cancel()
        imageTask = nil

        guard let url else {
            imageURL = nil
            artworkView.image = nil
            return
        }
        imageURL = url
        if let cached = Self.imageCache.object(forKey: url as NSURL) {
            artworkView.image = cached
            return
        }

        let task = Self.imageSession.dataTask(with: url) { [weak self] data, _, _ in
            guard let data, let image = UIImage(data: data) else { return }
            Self.imageCache.setObject(image, forKey: url as NSURL)
            DispatchQueue.main.async {
                guard let self, self.imageURL == url else { return }
                self.artworkView.image = image
            }
        }
        imageTask = task
        task.resume()
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        let side = Self.artworkSide
        artworkView.frame = CGRect(
            x: Self.artworkInset,
            y: round((bounds.height - side) / 2),
            width: side,
            height: side
        )

        let textX = Self.artworkInset + side + Self.textGap
        let textWidth = max(0, bounds.width - textX - Self.textInset)

        dateLabel.frame = CGRect(x: textX, y: 15, width: textWidth, height: 15)
        titleLabel.frame = CGRect(x: textX, y: 33, width: textWidth, height: 22)
        metaLabel.frame = CGRect(x: textX, y: 57, width: textWidth, height: 15)
    }
}

// MARK: - 页头本体
//
// 那一块文字与按钮。输入永远是"文本 + Spotify 自己的控件"，自己不持有任何 Spotify 状态。
final class EntityPageHeaderView: UIView {

    /// （AM 的标题**很大** —— photo_1 里 `Abel Tesfaye` 一个人占掉大半个屏宽）：
    /// 22 → **34**，缩放基准同时从 `.title2` 换成 `.largeTitle`（`makeLabel` 走 `UIFontMetrics`，
    /// 基准不换的话辅助功能字号下的比例会不对）。
    private let titleLabel = EntityPageHeaderView.makeLabel(
        style: .largeTitle, size: 34, weight: .bold, color: .label, lines: 2, alignment: .center
    )
    private let creatorLabel = EntityPageHeaderView.makeLabel(
        style: .body, size: 17, weight: .regular, color: .secondaryLabel, lines: 1, alignment: .center
    )
    /// （现在的**每月有 x 名听众**可能看不清）：原来这一行用的是
    /// `.tertiaryLabel` —— 深色模式下就是 **白 30%**，压在我们那块灰底上几乎读不出来。
    /// 抬到 `.secondaryLabel`（白 60%）：AM 的 meta 行也是"比标题弱一档、但看得清"，
    /// 而 `.tertiaryLabel` 那一档是给**禁用态**用的。歌单/专辑页的"12 首歌曲 · 45 分钟"共用这颗。
    private let lengthLabel = EntityPageHeaderView.makeLabel(
        style: .footnote, size: 13, weight: .regular, color: .secondaryLabel, lines: 1, alignment: .center
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
    //
    // 文本变了才重排。返回是否变了（调用方用它决定要不要再走一遍）。
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
    ///
    /// - Parameter trailingPrefersFallback: 右那颗**只用兜底字形**（见 `prefersFallbackGlyph`）——
    /// 艺人页未关注时要用中空五角星，不能采用 Spotify 那颗自己的"＋人"图。
    func updateRow(
        shuffle: UIView?,
        play: UIView?,
        trailing: UIView?,
        trailingFallback: UIImage?,
        trailingPrefersFallback: Bool = false
    ) {
        // 分不出用户点的是左边那颗还是右边那颗（他报告"右边那颗和原生按钮重合"时，
        // 这一条恰恰是最该看清的）。下一份日志会写成 `tapped (role trailing, source …)`。
        shuffleButton.role = "shuffle"
        trailingButton.role = "trailing"
        trailingButton.fallbackGlyph = trailingFallback
        trailingButton.prefersFallbackGlyph = trailingPrefersFallback
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

    /// 右边那颗 Follow 点击之后要**重新读一次**状态并换字形/描边。
    /// 由 `EntityPageHeaderManager` 在艺人页上装；别的页面不装（`afterFire` 保持 nil）。
    var onTrailingTapped: (() -> Void)? {
        didSet { trailingButton.afterFire = onTrailingTapped }
    }

    /// 把"关 / 开"两档的兜底字形与绿色描边一起刷新（艺人页 Follow）。
    ///
    /// - Parameters:
    /// - followed: 状态读出来是"已关注"吗（`eeveeIsOn`）。
    /// - glyph: 这一档该画的兜底字形（`star` / `checkmark`）。
    /// - source: 当前那颗 Follow 控件（可能和上一拍不是同一个实例）。
    func updateFollow(followed: Bool, glyph: UIImage?, source: UIView?) {
        trailingButton.fallbackGlyph = glyph
        trailingButton.prefersFallbackGlyph = !followed
        // feed 里会调 refreshTint（即使源没变也先刷新颜色），字形在 `feed` 的早退之后保持上面那张兜底图。
        if let source { trailingButton.feed(from: source) }
        trailingButton.refreshTintNow()
    }

    /// **「最新发布」小卡片**（艺人页三颗按钮下面那张）。
    ///
    /// 数据由 `EntityPageHeaderManager` 给（首选**页面自己那一格** —— 见 `captureLatestRelease`；
    /// 苹果目录只在页面读不到时兜底）。这一侧只把数据转给 manager —— 卡片**不再画在本视图里**。
    ///
    /// 卡片原来画在**页头内部**（贴底排的最后一项），
    /// 页头因此要长高 106pt；而 Spotify 的页头是 `UIStackView` 的一个 arranged subview，
    /// 我们改 `frame` 并不会让下面的列表跟着让位 ⇒ 卡片正好压在列表前两行上。
    /// 现在卡片挂到**页头下面的那一格**（见 `EntityPageHeaderManager.setReleaseCard`），
    /// 由 stack 自己把列表推下去；页头高度、标题、三颗、渐变全部回到原位。
    func updateRelease(
        title: String?,
        date: String?,
        meta: String?,
        artwork: UIImage? = nil,
        artworkURL: URL? = nil,
        isTappable: Bool = false
    ) {
        EntityPageHeaderManager.setReleaseCard(
            for: self,
            title: title,
            date: date,
            meta: meta,
            artwork: artwork,
            artworkURL: artworkURL,
            isTappable: isTappable
        )
    }

    /// **长按播放键 = 随机播放**（见 `EntityPageHeaderPlay.feedLongPress` 的说明）。
    /// 三个页面都接上：歌单/专辑页左边本来就是 shuffle，多一个入口无害；艺人页那颗位置让给 `i` 之后，
    /// 这里就是随机播放唯一的入口。
    func updatePlayLongPress(_ shuffle: UIView?) {
        playButton.feedLongPress(shuffle)
    }

    /// （播放页左边的按钮不应该是那个 `i` 吗，还没改？）：
    /// 左边那颗（AM 的 **Info**）在 Spotify 侧对应的是**艺人简介卡**，那颗卡上没有图标可镜像
    /// ⇒ 由调用方**显式给一个**字形（`info.circle`）。中间与右边那两颗不经过这里。
    func setLeadingGlyph(_ glyph: UIImage?) {
        shuffleButton.fallbackGlyph = glyph
    }

    /// （点击（`i`）后**跳转到**关于艺人模块）：左边那颗点下去要**先把源
    /// 滚进视野**再转发 —— 艺人页的"关于"（`SPTArtistAboutBiographyView`）在列表很下面。
    ///
    /// `target` 为 `nil`（那一块还没建出来）时**动作也不落在 `source` 上**（见 `fireTarget` 的说明）。
    func setLeadingTarget(_ target: UIView?, glyph: UIImage?) {
        shuffleButton.fireTarget = target
        shuffleButton.fallbackGlyph = glyph
        shuffleButton.scrollsSourceIntoView = true
        // 这一颗（艺人页的 `i`）要**宽转发** —— 见 `eeveeFireWide` 那段。
        shuffleButton.firesDeep = true
        shuffleButton.presentsOwnBio = true
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
    //
    // 内容从标题顶到描述底的高度。`apply` 用它算"封面该伸到哪"。
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
        // 按钮行的高度取三颗里**最高**的那颗。
        // 中间那颗改回**胶囊**（`playMinWidth` × `rowHeight`），不再比两侧高一档
        // ⇒ 整行高度就是两侧小圆的直径（见下面 `layoutSubviews` 里那段说明）。
        height += EntityPageHeaderMetrics.rowHeight
        if !aboutLabel.isHidden {
            height += EntityPageHeaderMetrics.aboutAbove
            height += ceil(aboutLabel.sizeThatFits(CGSize(width: text, height: .greatestFiniteMagnitude)).height)
        }
        return height
    }

    /// **只在会缩的页头上启用**上面那条渐隐。
    ///
    /// ⚠️ 的教训：这条本来是给**艺人页**写的（那边 `HeaderContainer` 会从 520pt 缩到 100pt
    /// 的导航栏），但我无条件打开了 —— 而歌单页的 `PL.Header` **根本不会缩**，于是某一拍
    /// `bounds.height` 还没定下来时算出的 `fade = 0` 被留在那儿，**整块页头（标题 + 三颗按钮）
    /// 就此消失**，只剩 Spotify 自己的搜索框和 pill 行露在外面。
    /// ⇒ 改成一个显式开关，只有 `applyToArtistPage` 打开它。
    var fadesWhenTight = false

    /// 贴底排时留多少（默认 `EntityPageHeaderMetrics.bottom` = 14）。
    var contentBottom: CGFloat = EntityPageHeaderMetrics.bottom

    /// **名字（标题）上沿**在本视图坐标里的 y；没有名字时是 −1。
    ///
    /// （AM 那三颗按键比 Spotify 靠下一点，所以它的渐变刚好不压到艺人名字；
    /// Spotify 的靠上就会被压住）：`EntityPageAppearance.ensureSharpHero` 用它把**满幅照片的渐变
    /// 收在名字上方**（`meltGap` / `meltSpanRatio`）—— AM 靠"把那一行做得更靠下"避开渐变，
    /// 我们靠这一行避开：**页头多高、Spotify 自己把那一行摆在哪，都不影响收口落点**。
    ///
    /// ⚠️ 读的是 `titleLabel.frame`，也就是**上一次 `layoutSubviews` 的结果**（本文件就是排它的地方）
    /// ⇒ 首帧可能还是 0，那一拍 `ensureSharpHero` 会退回默认收口，下一拍就对上了（0.6s 的拍子）。
    var textTop: CGFloat { titleLabel.isHidden ? -1 : titleLabel.frame.minY }

    /// 这一拍有没有标题 —— `textTop` 用 `-1` 表示"没有名字"，读它的地方要先问这一句，
    /// 否则"标题上沿正好压在本视图顶边（`textTop == -1`）"会被当成"没有标题"。
    var hasTitle: Bool { !titleLabel.isHidden }

    override func layoutSubviews() {
        super.layoutSubviews()

        // 这一整块是**贴着页头底部**排的（`y = bounds.height - bottom - contentHeight`），而页头会随
        // 滚动从 520pt 缩到 100pt 的导航栏 ⇒ 内容放不下时 `y` 变成负数，标题与按钮就**溢出到页头
        // 上方**，正好压在 Spotify 自己的导航栏上 ✗。
        //
        // ⇒ 页头矮到装不下这一块时，它整体**渐隐让位**（AM 里就是"跟着页头一起滚走"）：
        // `room ≥ 32pt` 全亮、`room ≤ 0` 全隐、中间线性。用 `alpha` 而不是 `isHidden`，
        // 免得折叠过程中一闪一闪。
        if fadesWhenTight {
            let needed = contentHeight(forWidth: bounds.width) + contentBottom
            let room = bounds.height - needed
            let fade = max(0, min(1, room / 32))
            if alpha != fade { alpha = fade }
        } else if alpha != 1 {
            alpha = 1
        }

        let width = bounds.width
        let text = max(0, width - 2 * EntityPageHeaderMetrics.side)
        var y = round(bounds.height - contentBottom - contentHeight(forWidth: width))

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
        // 中间那颗原来大一档（84 vs 两侧 56），三颗要**圆心同高**
        // ⇒ 中间那颗往上抬 `(big - side) / 2`。
        //
        // （那个播放按键做成 **melox/am 一样的槽形状**吧）：
        // 中间那颗从「84pt 的大圆」改成 **148×56 的胶囊**（`playMinWidth` × `rowHeight`）——
        // 与两侧小圆**一样高、同一行、同一圆心**，所以那条"往上抬半档"的偏移一并去掉。
        // 胶囊里是 `[▶][6pt][播放]`，由 `EntityPageHeaderPlay.layoutSubviews` 里那条
        // "非正方形 ⇒ 显示文字"的分支负责（它本来就支持两种形态，不用再加开关）。
        let side = EntityPageHeaderMetrics.rowHeight
        let pill = EntityPageHeaderMetrics.playMinWidth
        let play = CGRect(
            x: round((width - pill) / 2),
            y: y,
            width: pill,
            height: side
        )
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
    //
    // 只有按钮和**创建者那行文字**吃触摸；其余位置一律还给页面
    // （这一块和页面一样宽，全吃的话下拉就拉不动了）。
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
