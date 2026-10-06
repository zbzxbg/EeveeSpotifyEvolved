import Foundation
import Orion
import UIKit

/// Home 顶部那排**小卡片**（Liked Songs / 最近播放那些小方框）的底色 —— **从它自己的封面取色**。
///
/// ## 出处
///
/// 借鉴 **spoti.pw v0.21.1** 的 `Redesigned/Home/HomeTiles.m`（那一版是 **GPL-3.0**；
/// v0.22.0 起该仓库改为 PolyForm Strict，**那里的代码不可复制**）。它的原话就是这里的目标：
///
/// > the tile is a **dark surface tinted faintly towards the cover's dominant colour**,
/// > so the grid is not one grey and white text always reads.
///
/// 做法也照它：在卡片自己的 fill **之上**插一层我们自己的 `surface`（不吃触摸、不进无障碍），
/// 于是**标题、播放指示、按钮的点击全都还是 Spotify 的**；底色算一次、按图片缓存。
///
/// ## 为什么"结构推断"而不是照抄它那个 id
///
/// pw 挂的是 `InteractableLayoutBackingButton id=Shortcut.Card.Home`。我们 9.1.88 的
/// `dump-9.1.88.txt` 里**有这一组类**（`Home_AnchorsAndShortcutsKit22ShortcutsGridElementUI` /
/// `22ShortcutsCardElementUI` / `26ShortcutsCardDataElementUI`、`Home_ECMKit36ShortcutCardHomePlayingIndicatorView`），
/// 但**没有任何一次真机转储到过那一格**（转储器 `maxDepth = 24`、Home 内容已在 21~22 层 ⇒ 卡片在 25 层以下，
/// 根本到不了）。所以这里**认形状不认 id**：近似正方形的小卡、里面有一张图 ——
/// 认不出就什么都不做（宁可没效果，不要动错图）。第一次命中会把卡片结构打进日志，
/// 下一轮就能按真机结构收紧。
enum HomeTileTint {

    static var isEnabled: Bool { UserDefaults.homeTileTint }

    /// 底：Spotify 自己的"抬起一层"的深灰。往封面平均色混 `tintAmount`。
    private static let base = UIColor(white: 0.11, alpha: 1)
    /// 混多少。pw 是 "tinted **faintly**"（淡淡地偏向封面色）—— 多了白字读不清，少了看着还是一格灰。
    private static let tintAmount: CGFloat = 0.26

    private static var surfaceKey: UInt8 = 0
    /// 一张图只算一次（`ObjectIdentifier` 不做强引用）。
    private static var tints: [ObjectIdentifier: UIColor] = [:]
    private static let ciContext = CIContext(options: nil)
    private static var logged = Set<String>()

    /// 卡片自己那一拍。
    static func apply(to tile: UIView) {
        guard isEnabled, isTileShaped(tile) else { return }
        guard let cover = coverImageView(in: tile), let image = cover.image else { return }

        let colour = tint(for: image)
        let surface = surfaceIn(tile)
        if surface.superview !== tile { return }
        if surface.frame != tile.bounds { surface.frame = tile.bounds }
        if surface.backgroundColor != colour { surface.backgroundColor = colour }

        logOnce(
            "hit",
            "tile \(shape(tile)) tinted \(hex(colour)) from the cover \(shape(cover))"
                + " — the tile's own title, indicator and touches are untouched"
        )
    }

    /// 卡片自己那一拍（挂 `InteractableLayoutBackingButton` 那条路）：**先只报一次结构**
    /// —— 盲写代码时这是唯一能拿到真机结构的途径（转储器到不了那一层）—— 再按形状决定要不要上色。
    static func applyToCard(_ view: UIView) {
        guard isEnabled, isTileShaped(view) else { return }
        logStructureOnce(view)
        apply(to: view)
    }

    /// 网格那一拍：孩子自己不报的话，从这里扫一遍（并**把看到的结构打进日志**，
    /// 这就是这轮没有转储可用时的替代品）。
    static func applyToGrid(_ grid: UIView) {
        guard isEnabled else { return }
        logStructureOnce(grid)

        var queue: [UIView] = [grid]
        var visited = 0
        while !queue.isEmpty, visited < 400 {
            let view = queue.removeFirst()
            visited += 1
            apply(to: view)
            queue.append(contentsOf: view.subviews)
        }
    }

    // MARK: - 认形状

    /// 小卡片的形状：宽 120~340、高 40~80（真机上 Home 那排是 181×48 那种），而且里面有一张图。
    private static func isTileShaped(_ view: UIView) -> Bool {
        let size = view.bounds.size
        guard size.width >= 120, size.width <= 340, size.height >= 40, size.height <= 80 else { return false }
        return coverImageView(in: view) != nil
    }

    /// 卡片里那张封面图。取**第一个有图**的 `UIImageView`（占位图时期没有图 ⇒ 自动跳过）。
    private static func coverImageView(in root: UIView) -> UIImageView? {
        var queue: [UIView] = [root]
        var visited = 0
        while !queue.isEmpty, visited < 200 {
            let view = queue.removeFirst()
            visited += 1
            if let imageView = view as? UIImageView, imageView.image != nil { return imageView }
            queue.append(contentsOf: view.subviews)
        }
        return nil
    }

    // MARK: - 那一层底色

    /// 我们插的那一层。**插在卡片自己的 fill 之上**（= 第一个与卡片等大的子视图，pw 的取法），
    /// 找不到才放最底下 —— 两种都保证"标题/指示/按钮还压在它上面"。
    private static func surfaceIn(_ tile: UIView) -> UIView {
        if let existing = objc_getAssociatedObject(tile, &surfaceKey) as? UIView {
            if existing.superview !== tile {
                if let fill = tile.subviews.first(where: { $0.frame == tile.bounds }) {
                    tile.insertSubview(existing, aboveSubview: fill)
                } else {
                    tile.insertSubview(existing, at: 0)
                }
            }
            return existing
        }

        let surface = UIView()
        surface.isUserInteractionEnabled = false
        surface.accessibilityElementsHidden = true
        surface.backgroundColor = base
        surface.layer.cornerRadius = 8
        surface.layer.cornerCurve = .continuous
        surface.layer.masksToBounds = true
        if let fill = tile.subviews.first(where: { $0.frame == tile.bounds }) {
            tile.insertSubview(surface, aboveSubview: fill)
        } else {
            tile.insertSubview(surface, at: 0)
        }
        objc_setAssociatedObject(tile, &surfaceKey, surface, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return surface
    }

    // MARK: - 取色

    private static func tint(for image: UIImage) -> UIColor {
        let key = ObjectIdentifier(image)
        if let cached = tints[key] { return cached }
        let colour = averageColour(of: image).map { blend(base, toward: $0, amount: tintAmount) } ?? base
        tints[key] = colour
        return colour
    }

    /// 1×1 的 `CIAreaAverage` —— CoreImage 的归约，比逐像素遍历快得多；结果按图片缓存。
    private static func averageColour(of image: UIImage) -> UIColor? {
        guard let cgImage = image.cgImage else { return nil }
        let input = CIImage(cgImage: cgImage)
        guard !input.extent.isEmpty, !input.extent.isInfinite,
              let filter = CIFilter(
                  name: "CIAreaAverage",
                  parameters: [kCIInputImageKey: input, kCIInputExtentKey: CIVector(cgRect: input.extent)]
              ),
              let output = filter.outputImage else { return nil }

        var bitmap = [UInt8](repeating: 0, count: 4)
        ciContext.render(
            output,
            toBitmap: &bitmap,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return UIColor(
            red: CGFloat(bitmap[0]) / 255,
            green: CGFloat(bitmap[1]) / 255,
            blue: CGFloat(bitmap[2]) / 255,
            alpha: 1
        )
    }

    private static func blend(_ base: UIColor, toward other: UIColor, amount: CGFloat) -> UIColor {
        var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
        var or: CGFloat = 0, og: CGFloat = 0, ob: CGFloat = 0, oa: CGFloat = 0
        guard base.getRed(&br, green: &bg, blue: &bb, alpha: &ba),
              other.getRed(&or, green: &og, blue: &ob, alpha: &oa) else { return base }
        return UIColor(
            red: br + (or - br) * amount,
            green: bg + (og - bg) * amount,
            blue: bb + (ob - bb) * amount,
            alpha: 1
        )
    }

    // MARK: - 诊断

    private static func shape(_ view: UIView) -> String {
        "\(NSStringFromClass(type(of: view))) \(Int(view.bounds.width))x\(Int(view.bounds.height))"
    }

    private static func hex(_ colour: UIColor) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard colour.getRed(&r, green: &g, blue: &b, alpha: &a) else { return "?" }
        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }

    private static func logOnce(_ key: String, _ message: String) {
        guard logged.insert(key).inserted else { return }
        writeDebugLog("[HomeTiles] \(message)")
    }

    /// 把网格子树打进日志（有界：24 层 / 40 个节点）。这就是"转储到不了那一格"时的替代品。
    private static func logStructureOnce(_ grid: UIView) {
        guard logged.insert("structure").inserted else { return }

        var lines: [String] = []
        var queue: [(view: UIView, depth: Int)] = [(grid, 0)]
        var visited = 0
        while !queue.isEmpty, visited < 40, lines.count < 40 {
            let (view, depth) = queue.removeFirst()
            visited += 1
            let id = view.accessibilityIdentifier ?? ""
            let frame = view.frame
            lines.append(
                "\(depth).\(NSStringFromClass(type(of: view)))"
                    + "@\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width)),\(Int(frame.height))"
                    + (id.isEmpty ? "" : ",id=\(id)")
            )
            guard depth < 24 else { continue }
            queue.append(contentsOf: view.subviews.map { ($0, depth + 1) })
        }
        writeDebugLog("[HomeTiles] grid \(shape(grid)) subtree:\n  " + lines.joined(separator: "\n  "))
    }
}

// MARK: - 挂点

struct HomeShortcutTilesGroup: HookGroup {}

/// 每一张卡自己的那一拍（`layoutSubviews` 一定会在卡片出现/换内容时来）。
class HomeShortcutCardHook: ClassHook<UIView> {
    typealias Group = HomeShortcutTilesGroup
    static let targetName = "_TtC27Home_AnchorsAndShortcutsKit22ShortcutsCardElementUI"

    func layoutSubviews() {
        orig.layoutSubviews()
        HomeTileTint.apply(to: target)
    }
}

/// 网格那一拍：卡自己那拍万一不来，靠这里扫一遍孩子（并且把结构打进日志）。
class HomeShortcutGridHook: ClassHook<UIView> {
    typealias Group = HomeShortcutTilesGroup
    static let targetName = "_TtC27Home_AnchorsAndShortcutsKit22ShortcutsGridElementUI"

    func layoutSubviews() {
        orig.layoutSubviews()
        HomeTileTint.applyToGrid(target)
    }
}

/// ★ 2026-10-13（日志 84 之后补的）：Home 那排小卡片在真机上是**这个类** ——
/// `[ShellDump] LegacyUI_ECMCoreKit.InteractableLayoutBackingButton`（我们自己的日志里有过它），
/// pw 的树里同一个类带着 `id=Shortcut.Card.Home`。它是**真视图**，所以 `layoutSubviews` 挂得上；
/// 我第一版挂的 `…ShortcutsCardElementUI` 在 9.1.88 上**不存在**（日志 84：`hooked 1/2`），
/// 而那个 `…ElementUI` 多半根本不是视图。
///
/// ⚠️ 这个类**别处也在用**（曲库的 116×171 卡片、演出页的 374×346 卡、每行的「…」）——
/// 所以这里只按**形状**挑（`isTileShaped`：宽 120~340 / 高 40~80 / 里面有图），
/// 认不出就一个字节都不碰。
class HomeShortcutBackingButtonHook: ClassHook<UIView> {
    typealias Group = HomeShortcutTilesGroup
    static let targetName = "_TtC19LegacyUI_ECMCoreKit31InteractableLayoutBackingButton"

    func layoutSubviews() {
        orig.layoutSubviews()
        HomeTileTint.applyToCard(target)
    }
}

func activateHomeShortcutTiles() {
    guard HomeTileTint.isEnabled else { return }

    let targets = [
        HomeShortcutBackingButtonHook.targetName,
        HomeShortcutCardHook.targetName,
        HomeShortcutGridHook.targetName,
    ]
    let present = targets.filter { NSClassFromString($0) != nil }
    guard !present.isEmpty else {
        writeDebugLog("[HomeTiles] skipped — neither \(targets.joined(separator: " nor ")) exists")
        return
    }

    HomeShortcutTilesGroup().activate()
    writeDebugLog(
        "[HomeTiles] on — hooked \(present.count)/\(targets.count)"
            + " (\(present.joined(separator: ", "))); structure will be logged on the first grid pass"
    )
}
