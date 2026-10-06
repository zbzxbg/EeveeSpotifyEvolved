import Foundation
import Orion
import UIKit

/// Home 顶部那排**小卡片**（Liked Songs / 最近播放那些小方框）—— 照 Apple Music 的"列表行"来：
/// **封面从卡片边缘内缩一点、带自己的圆角，标题跟着往里挪**，而卡片的底是
/// **暗面往封面的主色淡淡偏一点**（于是整片网格不是"一格灰 + 白字"）。
///
/// ## 期望效果（用户 2026-10-13：「不知道期望效果是什么记得说」）
///
/// 借鉴 **spoti.pw v0.21.1** 的 `Redesigned/Home/HomeTiles.m`（那一版是 **GPL-3.0**；
/// v0.22.0 起该仓库改为 PolyForm Strict，**那里的代码不可复制**）。它逐字写的就是这里的验收标准：
///
/// > a shortcut tile the way an Apple list row holds artwork. **The cover sits inset from the tile's
/// > edges with its own corners, the title follows it in**, and the tile is **a dark surface tinted
/// > faintly towards the cover's dominant colour**, so **the grid is not one grey and white text always
/// > reads**. Until the cover has loaded, the tile is the untinted surface.
///
/// 拆成三条可验收的：
///
/// 1. **封面内缩 + 圆角**（`coverInset = 5`、`coverRadius = 4`）：封面方块绕中心缩小、让出边缘，
///    标题那一摞跟着左移。这与底色是**两件事**，只做底色是看不出来的 —— 上一版就是只做了底色，
///    所以用户说"没有期望效果"。
/// 2. **底色淡染**：暗面朝封面的**主色**（不是平均色）混 35%（主色先压到亮度 0.05）——
///    "faintly"是故意的：多了白字读不清，少了看着还是一格灰。
/// 3. **图晚到也跟上**：图没到时是**未染色的暗面**，图到了再淡入。
///
/// ## 与 pw 的实现对应
///
/// | pw | 这里 |
/// |---|---|
/// | `partsOf`：`Encore.ImageView` 里的 `UIImageView` + 它的父视图（方块）+ 第一个与卡等大的子视图（fill）| `coverImageView` / `insetCover` / `surfaceIn` |
/// | `inset()`：transform 缩放方块 + 兄弟左移 | `insetCover`（逐字照抄常数与算法）|
/// | `SGRPalette +tintForImage:`：主色（3 位分箱、按覆盖率×饱和度打分）压亮度后混 35% | `dominantColour` / `tint` |
/// | `NSMapTable weakToStrongObjects` 缓存 + **后台队列**算色 | `tints` / `tintQueue` |
/// | `SGRObserveImage` 跟图 | 每拍 + 结果回来时再核一次（等效）|
///
/// ## 为什么"结构推断"而不是照抄它那个 id
///
/// pw 挂的是 `InteractableLayoutBackingButton id=Shortcut.Card.Home`。我们 9.1.88 的
/// `dump-9.1.88.txt` 里**有这一组类**（`Home_AnchorsAndShortcutsKit22ShortcutsGridElementUI` /
/// `22ShortcutsCardElementUI` / `26ShortcutsCardDataElementUI`、`Home_ECMKit36ShortcutCardHomePlayingIndicatorView`），
/// 但**没有任何一次真机转储到过那一格**（转储器 `maxDepth = 24`、Home 内容已在 21~22 层 ⇒ 卡片在 25 层以下，
/// 根本到不了）。所以这里**认 id + 形状**：日志 86 的 `[HomeTiles] grid … subtree:` 第一行就是
/// `LegacyUI_ECMCoreKit.InteractableLayoutBackingButton@0,0,187,48,id=Shortcut.Card.Home` ——
/// **pw 用的那个 id 在我们 9.1.88 上一模一样**。认不出就什么都不做（宁可没效果，不要动错图）。
enum HomeTileTint {

    static var isEnabled: Bool { UserDefaults.homeTileTint }

    // MARK: - 常数（pw 的 `HomeTiles.m` / `SGRPalette.m`）

    /// 封面从上/下/左边缘让出这么多（pw 的 `kInset = 5`）。
    private static let coverInset: CGFloat = 5
    /// 让出之后封面的圆角（pw 的 `kCoverRadius = 4`）。
    private static let coverRadius: CGFloat = 4
    /// 卡片的暗面：Spotify 自己的"抬起一层"的深灰。
    private static let base = UIColor(white: 0.11, alpha: 1)
    /// pw 的 `kTintLuminance = 0.05`：主色先压到这个亮度（线性光）。
    private static let tintLuminance: CGFloat = 0.05
    /// pw 的 `kTintShare = 0.35`：再按这个比例混进暗面。
    private static let tintShare: CGFloat = 0.35
    /// 主色采样边长（pw 的 `kSample = 64`）。
    private static let sample = 64

    // MARK: - 状态

    private static var surfaceKey: UInt8 = 0
    /// 取过的色：**按图片对象**（图活着才留）—— pw 的 `NSMapTable weakToStrongObjectsMapTable`。
    ///
    /// ⚠️ 上一版用的是 `[ObjectIdentifier: UIColor]`：`ObjectIdentifier` **不持有**那张图，
    /// 图被释放之后地址会被下一张图复用 ⇒ 新卡片可能捡到上一张封面的颜色。这里改成弱表。
    /// **只在主线程读写**（`NSMapTable` 自己不加锁）。
    private static let tints = NSMapTable<UIImage, UIColor>.weakToStrongObjects()
    /// 取色在后台（pw 的 `SGRPalette` 有自己的串行队列 `spotifyglass.redesign.palette`）。
    private static let tintQueue = DispatchQueue(label: "eevee.hometiles.tint", qos: .userInitiated)
    /// 报过几张（有界：8 张）—— 原来 `logOnce` 只报全局第一张，
    /// "首页那几个小卡片到底覆盖了几张"从日志里**看不出来**。
    private static var reported = 0
    private static var logged = Set<String>()

    // MARK: - 卡片自己那一拍

    static func apply(to tile: UIView) {
        guard isEnabled, isTile(tile) else { return }
        guard let cover = coverImageView(in: tile), let image = cover.image else { return }

        // ① 封面内缩 + 圆角 + 标题跟移（pw 的 `inset`）—— 与底色无关，是这排卡片的"形"。
        insetCover(in: tile)

        let surface = surfaceIn(tile)
        if surface.superview !== tile { return }
        if surface.frame != tile.bounds { surface.frame = tile.bounds }

        if let known = tints.object(forKey: image) {
            if surface.backgroundColor != known { surface.backgroundColor = known }
            report(tile: tile, cover: cover, colour: known)
            return
        }

        // ② 没算过：**在后台算**，回来时这张卡可能已经换了封面/被复用 ⇒ 核一次再上色。
        tintQueue.async {
            let colour = tint(for: image) ?? base
            DispatchQueue.main.async {
                tints.setObject(colour, forKey: image)
                guard isTile(tile),
                      let current = coverImageView(in: tile)?.image, current === image else { return }
                let target = surfaceIn(tile)
                if target.backgroundColor != colour { target.backgroundColor = colour }
                report(tile: tile, cover: cover, colour: colour)
            }
        }
    }

    /// 卡片自己那一拍（挂 `InteractableLayoutBackingButton` 那条路）：**先只报一次结构**
    /// —— 盲写代码时这是唯一能拿到真机结构的途径（转储器到不了那一层）—— 再按形状决定要不要上色。
    static func applyToCard(_ view: UIView) {
        guard isEnabled, isTile(view) else { return }
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

    // MARK: - 认那一格（真机结构，日志 85/86 逐字）

    /// ★ 2026-10-13：**改认 id** —— 日志 85 的 `[HomeTiles] grid … subtree:` 第一行就写着
    /// `LegacyUI_ECMCoreKit.InteractableLayoutBackingButton@0,0,187,48,id=Shortcut.Card.Home`：
    /// **pw 用的那个 id 在我们 9.1.88 上一模一样**（它树注释里的 `InteractableLayoutBackingButton
    /// id=Shortcut.Card.Home 181x48` 就是同一格）。⇒ 不再靠形状猜，直接认它。
    private static func isTile(_ view: UIView) -> Bool {
        guard view.accessibilityIdentifier == "Shortcut.Card.Home" else { return false }
        let size = view.bounds.size
        return size.width >= 120 && size.width <= 340 && size.height >= 40 && size.height <= 80
    }

    /// pw 的 `partsOf` 逐字：封面在 **`Encore.ImageView`** 里面那个 `UIImageView`。
    ///
    /// ⚠️ **必须已经布好局**：日志 85 里第一次网格那一拍，整棵子树的 frame 还都是 **0×0**
    /// （`[HomeTiles] tile … tinted #1A1A1A from the cover UIImageView 0x0`），
    /// 从一张 0×0 的图取平均色 ⇒ 近乎黑 ⇒ 看起来"没变"。所以这里要求封面至少 24pt 宽，
    /// 没布好就**这一拍不动**，等下面某一拍（或封面图晚到时）再来。
    private static func coverImageView(in tile: UIView) -> UIImageView? {
        guard let holder = eeveeFindView(tile, identifier: "Encore.ImageView") else { return nil }
        guard let imageView = holder.subviews.compactMap({ $0 as? UIImageView }).first else { return nil }
        guard imageView.image != nil, imageView.bounds.width >= 24, imageView.bounds.height >= 24 else { return nil }
        return imageView
    }

    // MARK: - 封面内缩（pw 的 `inset`）

    /// 封面方块**绕中心缩放**，从卡片边缘让出 `coverInset`；方块之后那一摞（标题那一行）
    /// 跟着左移同样的距离。
    ///
    /// 用 transform 而**不是** frame：Spotify 的 Auto Layout 不读 transform ⇒ 它的约束一个都不用动
    /// （pw 逐字：「The inset and the title's move are transforms, which Spotify's layout never reads,
    /// so its constraints are left as they are」）。所以这是可逆、也不会跟布局打架的做法。
    private static func insetCover(in tile: UIView) {
        guard let holder = eeveeFindView(tile, identifier: "Encore.ImageView") else { return }
        // 那个 48×48、带圆角的方块就是 image holder 的父视图（pw 的 `parts.square = holder.superview`）。
        guard let square = holder.superview else { return }
        let side = square.bounds.height
        guard side > coverInset * 4 else { return }

        let scale = (side - coverInset * 2) / side
        let shrink = CGAffineTransform(scaleX: scale, y: scale)
        if square.transform != shrink { square.transform = shrink }

        let layer = square.layer
        // 圆角是**画**出来的，会跟着 transform 一起缩 ⇒ 除以 scale 才是看上去的那个半径（pw 逐字）。
        let radius = coverRadius / scale
        if layer.cornerRadius != radius { layer.cornerRadius = radius }
        if layer.cornerCurve != .continuous { layer.cornerCurve = .continuous }
        if !layer.masksToBounds { layer.masksToBounds = true }

        let follow = CGAffineTransform(translationX: -square.bounds.width * (1 - scale) / 2, y: 0)
        var after = false
        for sibling in square.superview?.subviews ?? [] {
            if sibling === square { after = true; continue }
            if after, sibling.transform != follow { sibling.transform = follow }
        }
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

    // MARK: - 取色（pw 的 `SGRPalette`：主色 → 压亮度 → 混进暗面）

    /// pw 的 `dominantIn`：图缩到 64×64，每通道 **3 位分箱**（512 格），每格按
    /// `count × (0.25 + 饱和度)` 打分（近黑 ×0.3、近白 ×0.3 降权），取分最高那一格的**平均色**
    /// —— 平均是在**线性光**里做的。忙乱的封面因此给的是它的**主色**，
    /// 而不是"整张图平均"出来的那种灰（这正是上一版看不出效果的原因之一）。
    private static func dominantColour(of image: UIImage) -> UIColor? {
        guard let cgImage = image.cgImage else { return nil }
        let side = sample
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }

        var sums = [Double](repeating: 0, count: 512 * 3)
        var scores = [Double](repeating: 0, count: 512)
        var counts = [Int](repeating: 0, count: 512)

        for index in 0..<(side * side) {
            let pixel = index * 4
            guard pixels[pixel + 3] >= 128 else { continue }
            let red = Double(pixels[pixel]) / 255
            let green = Double(pixels[pixel + 1]) / 255
            let blue = Double(pixels[pixel + 2]) / 255
            let bin = Int(pixels[pixel] >> 5) << 6 | Int(pixels[pixel + 1] >> 5) << 3 | Int(pixels[pixel + 2] >> 5)
            let high = max(red, max(green, blue))
            let low = min(red, min(green, blue))
            let saturation = high > 0 ? (high - low) / high : 0
            scores[bin] += (0.25 + saturation) * (high < 0.12 ? 0.3 : 1) * (low > 0.88 ? 0.3 : 1)
            counts[bin] += 1
            sums[bin * 3] += linear(red)
            sums[bin * 3 + 1] += linear(green)
            sums[bin * 3 + 2] += linear(blue)
        }

        var best = 0
        for index in 1..<512 where scores[index] > scores[best] { best = index }
        guard counts[best] > 0 else { return nil }
        let count = Double(counts[best])
        return UIColor(
            red: encoded(sums[best * 3] / count),
            green: encoded(sums[best * 3 + 1] / count),
            blue: encoded(sums[best * 3 + 2] / count),
            alpha: 1
        )
    }

    /// pw 的 `tintOf`：主色压到亮度 `tintLuminance`（线性光、三通道**同一系数**，色相不变），
    /// 再按 `tintShare` 混进暗面。
    ///
    /// ⚠️ pw 踩过的坑（它的 issue #36，这里照抄它的处理）：混完**比暗面还暗**的（近黑封面）
    /// 会让卡片比"未染色的暗面"还黑，一路掉进 AMOLED 的纯黑里 —— 于是"黑方块丢在黑页上"。
    /// 所以混完比暗面暗就按**同一系数**抬回暗面的亮度（抬不爆：目标是暗面那点亮度）。
    private static func tint(for image: UIImage) -> UIColor? {
        guard let dominant = dominantColour(of: image) else { return nil }
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 1
        guard dominant.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }

        var lr = linear(Double(red)), lg = linear(Double(green)), lb = linear(Double(blue))
        let luminance = 0.2126 * lr + 0.7152 * lg + 0.0722 * lb
        if luminance > 0, luminance > Double(tintLuminance) {
            let scale = Double(tintLuminance) / luminance
            lr *= scale
            lg *= scale
            lb *= scale
        }

        var baseRed: CGFloat = 0, baseGreen: CGFloat = 0, baseBlue: CGFloat = 0, baseAlpha: CGFloat = 1
        guard base.getRed(&baseRed, green: &baseGreen, blue: &baseBlue, alpha: &baseAlpha) else { return nil }
        let share = Double(tintShare)
        let baseLinear = [linear(Double(baseRed)), linear(Double(baseGreen)), linear(Double(baseBlue))]
        var mixed = [
            baseLinear[0] * (1 - share) + lr * share,
            baseLinear[1] * (1 - share) + lg * share,
            baseLinear[2] * (1 - share) + lb * share,
        ]

        let want = 0.2126 * baseLinear[0] + 0.7152 * baseLinear[1] + 0.0722 * baseLinear[2]
        let have = 0.2126 * mixed[0] + 0.7152 * mixed[1] + 0.0722 * mixed[2]
        if have <= 0 { return base }
        if have < want {
            let lift = want / have
            mixed = mixed.map { $0 * lift }
        }
        return UIColor(
            red: encoded(mixed[0]),
            green: encoded(mixed[1]),
            blue: encoded(mixed[2]),
            alpha: 1
        )
    }

    private static func linear(_ value: Double) -> Double {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    private static func encoded(_ value: Double) -> CGFloat {
        let clamped = max(0, min(1, value))
        let out = clamped <= 0.0031308 ? clamped * 12.92 : 1.055 * pow(clamped, 1 / 2.4) - 0.055
        return CGFloat(max(0, min(1, out)))
    }

    // MARK: - 诊断

    private static func report(tile: UIView, cover: UIView, colour: UIColor) {
        guard reported < 8 else { return }
        reported += 1
        writeDebugLog(
            "[HomeTiles] tile \(shape(tile)) tinted \(hex(colour)) from the cover \(shape(cover))"
                + " — cover inset \(Int(coverInset))pt r=\(Int(coverRadius));"
                + " title moved in with it (pw's Apple-list-row look)"
        )
    }

    private static func shape(_ view: UIView) -> String {
        "\(NSStringFromClass(type(of: view))) \(Int(view.bounds.width))x\(Int(view.bounds.height))"
    }

    private static func hex(_ colour: UIColor) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard colour.getRed(&r, green: &g, blue: &b, alpha: &a) else { return "?" }
        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
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
/// 我第一版挂的 `…ShortcutsCardElementUI` 在 9.1.88 上**不存在**（日志 84：`hooked 1/2`）。
///
/// ⚠️ 这个类**别处也在用**（曲库的 116×171 卡片、演出页的 374×346 卡、每行的「…」）——
/// 所以这里只按 **id + 尺寸** 挑，认不出就一个字节都不碰。
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
            + " (\(present.joined(separator: ", ")));"
            + " the tile is a dark surface tinted towards the cover's dominant colour,"
            + " with the cover inset 5pt (pw's Apple-list-row look); structure logged on the first grid pass"
    )
}
