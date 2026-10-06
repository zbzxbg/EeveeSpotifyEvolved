import Foundation
import Orion
import UIKit
import QuartzCore

/// 「Spotify 一旦往我们清过的地方重画底色，就把这次写入丢掉」。
///
/// ## 出处
///
/// 借鉴 **spoti.pw v0.21.1** 的 `Redesigned/Kit/SGRRepaint.x`（那一版是 **GPL-3.0**；
/// v0.22.0 起该仓库改为 PolyForm Strict，**那里的代码不可复制**）。它的原文：
///
/// > Keeps the areas the redesign stripped transparent when Spotify repaints them.
///
/// ```objc
/// %hook CALayer
/// - (void)setBackgroundColor:(CGColorRef)color {
///     if (color && (…sgr_playlistRoot || sgr_albumRoot || …)) {
///         UIView *view = (UIView *)self.delegate;
///         if ([view isKindOfClass:UIView.class] && view.layer == self && !SGKeepsColor(view)) {
///             … else if (SGIsBaseSurface(color) && SGIsInside(view, …)) { color = NULL; }
///         }
///     }
///     %orig(color);
/// }
/// ```
///
/// ## 为什么必须有它（用户照片 103 那条"割裂感很强的线"）
///
/// 我们清底色原来只有**每 0.6s 走一遍页面**、而且只清 `depth ≤ 7`、只清等于 `#121212` 的那些 ——
/// 列表在深度 15+，**滚动时才创建的行**更是每一行都要重画一次 ⇒ 于是"页头区（我们的模糊底）"与
/// "列表区（Spotify 的底色）"之间出现一条硬边。
///
/// pw 不轮询，而是**劫住 `CALayer.setBackgroundColor:`**：谁想画底色就在那一刻被拦下 ⇒ 又准又省
/// （事件驱动，只在真有写入时走一次）。
///
/// ## 三道闸门（缺一不可，pw 逐字）
///
///   ① **当前确实在一个我们接管的页面里**（`EntityPageRepaint.root` 非空）——不在就一个字都不动；
///   ② `layer.delegate` 必须真是 `UIView`、而且 `view.layer === layer`（子层不算，pw 的 `view.layer == self`）；
///   ③ 颜色必须是**底面色**（近黑灰，pw 的 `SGIsBaseSurface`），而且那个视图在这个页面的子树里。
enum EntityPageRepaint {

    /// 我们接管的页面根。由 `EntityPageAppearance` 在每一拍里设（weak，页面走了自动失效）。
    static weak var root: UIView?

    static func shouldDrop(_ layer: CALayer, color: CGColor) -> Bool {
        guard let root else { return false }                                  // ①
        guard let view = layer.delegate as? UIView, view.layer === layer else { return false }  // ②
        guard view === root || view.isDescendant(of: root) else { return false }                // ③
        return isBaseSurface(color)
    }

    /// 与 `EntityPageAppearance` 清底色同一个判据：近黑、近灰、不透明。
    static func isBaseSurface(_ color: CGColor) -> Bool {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard UIColor(cgColor: color).getRed(&r, green: &g, blue: &b, alpha: &a) else { return false }
        guard a > 0.5 else { return false }
        return abs(r - g) < 0.02 && abs(g - b) < 0.02 && r < 0.12
    }
}

// MARK: - 挂点

struct EntityPageRepaintGroup: HookGroup {}

/// 全局劫一次 `CALayer.setBackgroundColor:`。**不在我们页面里时是一句 nil 检查**，不产生开销。
///
/// ⚠️ hook 类不能加 `final`/`private`/`fileprivate`（Orion 要为它生成胶水子类）。
class EntityPageRepaintLayerHook: ClassHook<CALayer> {
    typealias Group = EntityPageRepaintGroup
    static let targetName = "CALayer"

    func setBackgroundColor(_ color: CGColor?) {
        guard let color, EntityPageRepaint.shouldDrop(target, color: color) else {
            orig.setBackgroundColor(color)
            return
        }
        orig.setBackgroundColor(nil)
    }
}

/// 列表是**在自己的布局回合**把底色画上去的（pw 的 `PlaylistField.x` 原话：*"The list paints itself the
/// base surface from its own pass rather than through a layer that the repaint hook would hear about,
/// so it is cleared where it is laid out."*）—— 所以在它那一拍再清一次。
///
/// 类名来自我们自己的符号表与真机树（`dump-9.1.88.txt:12060`、
/// `[Tree] … FTPTouchCancellingCollectionView@0,0,414,896,id=SPTFreeTierPlaylistTableView`）。
class PlaylistListBackgroundHook: ClassHook<UIScrollView> {
    typealias Group = EntityPageRepaintGroup
    static let targetName = "_TtC35ListUXPlatform_FreeTierPlaylistImpl32FTPTouchCancellingCollectionView"

    func layoutSubviews() {
        orig.layoutSubviews()
        guard EntityPageRepaint.root != nil else { return }
        guard let colour = target.backgroundColor, let cg = colour.cgColor,
              EntityPageRepaint.isBaseSurface(cg) else { return }
        target.backgroundColor = .clear
    }
}

func activateEntityPageRepaint() {
    // 底色拦截只为「满幅封面 + 取色底」那颗开关服务（它不在，页面本来就不该被清成透明）。
    guard UserDefaults.entityPageDissolve else {
        writeDebugLog("[PageRepaint] off — the page field switch is off")
        return
    }

    let targets = [
        EntityPageRepaintLayerHook.targetName,
        PlaylistListBackgroundHook.targetName,
    ]
    let present = targets.filter { NSClassFromString($0) != nil }
    guard !present.isEmpty else {
        writeDebugLog("[PageRepaint] skipped — none of \(targets.joined(separator: ", ")) exist")
        return
    }

    EntityPageRepaintGroup().activate()
    writeDebugLog(
        "[PageRepaint] on — hooked \(present.count)/\(targets.count)"
            + " (\(present.joined(separator: ", "))): Spotify's base-surface paints inside our page"
            + " are dropped at the layer, and the playlist list's own pass is cleared where it lays out"
    )
}
