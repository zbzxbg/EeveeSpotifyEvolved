import Foundation
import Orion
import UIKit
import ObjectiveC.runtime

/// 音乐库（Your Library）的**行与网格卡片** —— 照 pw 的 `Redesigned/Library/LibraryRows.x`
/// （同一个信号、同一套 id；9.1.88 那份解密 IPA 里
/// `YourLibrary_CommonKit.YourLibrarySwipeableCollectionViewCellContainer` 逐字都在）。
///
/// ── 目标：Apple Music 那两笔（用户 2026-10-12 点名"要 AM 的优雅感"）─────────────
///   · **封面是连续圆角的小圆角**（AM 的唱片封面 6pt、大图 8pt，都是 `kCACornerCurveContinuous`）；
///     Spotify 自己给的是直角味的 4pt；
///   · **行与行之间一条发丝线，从「文字左沿」开始**（AM 的列表分隔线就是这么缩进的），
///     而不是横贯整行。厚度是**物理发丝**（1/scale），颜色 white @ 12%（pw 的 `SGRHairline`）。
///
/// ── 真机结构（pw 的树；我们的 dump 里同一个 id 也在）──────────────────────────
/// ```
/// YourLibrarySwipeableCollectionViewCellContainer          ← hook 目标（复用单元）
/// └ 402x80 的一行（id=Playlist.Row.Library / Album.Row.Library / Podcast.Row.Library）
///   └ AutoLayoutStackView {16, 8} 370x64
///     ├ id=Artwork.Row.Library 64x64 r=4                   ← 封面（换连续圆角 6）
///     └ 12pt 之后是标题 / 类型 / 作者                        ← 发丝线从这里起
///   或者 112.67x161.33 的卡片（id=Components.UI.CardLibrary.Artwork r=4）  ← 换连续圆角 8
/// ```
///
/// ── 两条实现细节（都照 pw，理由也是他的，别再自己发明）───────────────────────
///   1. **艺人的画像是圆的**：它的 `cornerRadius` 已经是"半边长"，**一个字节都不许改** ——
///      判据是 `cornerRadius >= side/2 - 0.5` 就放过（真机树里 r=32 的就是这一类）；
///   2. **发丝线用 `CALayer`，不用 view**：单元复用极快，加 view 会看到线"滑"进来 ⇒
///      用 layer + `CATransaction.setDisableActions(true)`；形状不对（卡片）时**只是藏起来**，
///      不删层（同一个单元一会儿还会变回行）。
///
/// ⚠️ 还原：封面原半径/原圆角曲线记在**那颗封面自己身上**（关联对象）⇒ 单元复用也不会串；
///    开关关掉时（本文件的 hook 每拍都会跑）**逐颗写回**。
enum LibraryRowsMetrics {
    /// pw 的 `SGRRadiusThumb` = 6：**行**里的 64pt 缩略图。
    static let thumbRadius: CGFloat = 6
    /// pw 的 `SGRRadiusCover` = 8：网格卡片的封面（AM 的规矩也是"图越大、圆角越大"）。
    static let coverRadius: CGFloat = 8
    /// 封面右沿 → 文字左沿（pw 读真机树：封面到 64，文字从 76 起）。
    static let textGap: CGFloat = 12
    /// pw 的 `SGRHairline`：white @ 12%。
    static let hairlineAlpha: CGFloat = 0.12
    /// "这是一行"的形状判据（照 pw）：宽 > 300 且高 ≤ 120 —— 卡片不要线。
    static let rowMinWidth: CGFloat = 300
    static let rowMaxHeight: CGFloat = 120
}

enum LibraryRowsAppearance {

    /// 与头部那一批**共用同一个开关**（`UserDefaults.libraryLargeTitle`）。
    static var isEnabled: Bool { LibraryAppearance.isEnabled }

    /// 发丝线（挂在那颗单元上的关联键）。
    private static var lineKey: UInt8 = 0
    /// 封面原半径 / 原圆角曲线（挂在那颗**封面**上的关联键 —— 单元会复用，挂在单元上会串）。
    private static var originalRadiusKey: UInt8 = 0
    private static var originalCurveKey: UInt8 = 0
    private static var didReportRows = false
    private static var didReportMissing = false

    private static let thumbIdentifier = "Artwork.Row.Library"
    private static let cardArtworkIdentifier = "Components.UI.CardLibrary.Artwork"

    /// 由 hook 在**那颗复用的单元**每次布局时调用。幂等。
    @MainActor
    static func apply(to cell: UIView) {
        guard isEnabled else {
            restore(cell)
            return
        }

        let thumb = LibraryAppearance.findView(in: cell, where: {
            $0.accessibilityIdentifier == thumbIdentifier
        })
        let cover = thumb == nil ? LibraryAppearance.findView(in: cell, where: {
            $0.accessibilityIdentifier == cardArtworkIdentifier
        }) : nil
        if let thumb {
            round(thumb, to: LibraryRowsMetrics.thumbRadius)
        } else if let cover {
            round(cover, to: LibraryRowsMetrics.coverRadius)
        }
        hairline(on: cell, thumb: thumb)

        // 第一次量到**有尺寸的**封面才报（布局第一拍上它还是 0x0，报出来没意义）。
        if !didReportRows, let thumb, thumb.window != nil, thumb.bounds.width > 1 {
            didReportRows = true
            writeDebugLog(
                "[Library] rows styled — the first thumbnail is \(Int(thumb.bounds.width))pt at r="
                    + "\(String(format: "%.1f", thumb.layer.cornerRadius)) (continuous)"
                    + "; the hairline starts at the text's leading edge"
            )
        }
        // 两个 id 一个都没找到 ⇒ 自报一行（否则这一片是**静默不生效**，下一个人还得重猜一遍）。
        if !didReportMissing, thumb == nil, cover == nil, cell.bounds.width > 100, cell.bounds.height > 20 {
            didReportMissing = true
            writeDebugLog(
                "[Library] ⚠️ no row artwork id on a \(Int(cell.bounds.width))x\(Int(cell.bounds.height)) cell"
                    + " — looked for \(thumbIdentifier) and \(cardArtworkIdentifier)"
                    + "; this build may name the artwork differently"
            )
        }
    }

    /// 圆角：换成 AM 那一档的连续圆角；**本来就是圆的（艺人头像）一个字节都不动**。
    @MainActor
    private static func round(_ artwork: UIView, to radius: CGFloat) {
        let side = min(artwork.bounds.width, artwork.bounds.height)
        guard side > 1 else { return }
        let layer = artwork.layer
        // 艺人头像：原生半径已经是半边长 ⇒ 放过（pw 的判据，逐字照抄）。
        if layer.cornerRadius >= side / 2 - 0.5 { return }

        if objc_getAssociatedObject(artwork, &originalRadiusKey) == nil {
            objc_setAssociatedObject(
                artwork,
                &originalRadiusKey,
                NSNumber(value: Double(layer.cornerRadius)),
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
            objc_setAssociatedObject(
                artwork,
                &originalCurveKey,
                NSNumber(value: layer.cornerCurve == .continuous),
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        }
        if layer.cornerRadius != radius { layer.cornerRadius = radius }
        if layer.cornerCurve != .continuous { layer.cornerCurve = .continuous }
        if !layer.masksToBounds { layer.masksToBounds = true }
    }

    /// 行与行之间那条线：从**文字左沿**（= 封面右沿 + 12）拉到单元右沿，1/scale 厚。
    @MainActor
    private static func hairline(on cell: UIView, thumb: UIView?) {
        let size = cell.bounds.size
        let artwork = thumb.map { $0.convert($0.bounds, to: cell) } ?? .zero
        // 只有"行"要线：卡片（见 `LibraryRowsMetrics` 的形状判据）不要。单元从行复用成卡片时，
        // 那条留在上面的线必须藏起来 —— 否则卡片下面挂着一条来历不明的线。
        let wanted = thumb != nil
            && size.width > LibraryRowsMetrics.rowMinWidth
            && size.height <= LibraryRowsMetrics.rowMaxHeight
            && artwork.width > 1

        guard wanted else {
            (objc_getAssociatedObject(cell, &lineKey) as? CALayer)?.isHidden = true
            return
        }

        var line = objc_getAssociatedObject(cell, &lineKey) as? CALayer
        if line == nil {
            let made = CALayer()
            made.backgroundColor = UIColor(white: 1, alpha: LibraryRowsMetrics.hairlineAlpha).cgColor
            made.zPosition = 1
            objc_setAssociatedObject(cell, &lineKey, made, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            line = made
        }
        guard let line else { return }
        if line.superlayer !== cell.layer { cell.layer.addSublayer(line) }

        let scale = cell.window?.screen.scale ?? UIScreen.main.scale
        let thickness = 1 / max(1, scale)
        let leading = artwork.maxX + LibraryRowsMetrics.textGap
        let frame = CGRect(
            x: leading,
            y: size.height - thickness,
            width: max(0, size.width - leading),
            height: thickness
        )
        // 单元复用极快 ⇒ 关掉隐式动画，否则线会"滑"到位（pw 的原话）。
        if line.isHidden || line.frame != frame {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            line.isHidden = false
            line.frame = frame
            CATransaction.commit()
        }
    }

    /// 开关关掉 / 页面走了：逐颗写回原半径与圆角曲线，并把线藏起来。
    @MainActor
    private static func restore(_ cell: UIView) {
        var artworks: [UIView] = []
        if let thumb = LibraryAppearance.findView(in: cell, where: { $0.accessibilityIdentifier == thumbIdentifier }) {
            artworks.append(thumb)
        }
        if let cover = LibraryAppearance.findView(in: cell, where: { $0.accessibilityIdentifier == cardArtworkIdentifier }) {
            artworks.append(cover)
        }
        for artwork in artworks {
            guard let radius = objc_getAssociatedObject(artwork, &originalRadiusKey) as? NSNumber else { continue }
            let layer = artwork.layer
            if layer.cornerRadius != CGFloat(radius.doubleValue) {
                layer.cornerRadius = CGFloat(radius.doubleValue)
            }
            let wasContinuous = (objc_getAssociatedObject(artwork, &originalCurveKey) as? NSNumber)?.boolValue ?? false
            if layer.cornerCurve != (wasContinuous ? .continuous : .circular) {
                layer.cornerCurve = wasContinuous ? .continuous : .circular
            }
            objc_setAssociatedObject(artwork, &originalRadiusKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            objc_setAssociatedObject(artwork, &originalCurveKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        (objc_getAssociatedObject(cell, &lineKey) as? CALayer)?.isHidden = true
        didReportRows = false
    }
}

// MARK: - Hook

/// 音乐库列表里**每一颗可滑动的单元**（行与网格卡片共用这一个容器类）。
///
/// 用 `layoutSubviews` 而不是 0.5s 节拍：单元是**复用的**，它自己每次布局就是最准的时机
/// （pw 也是只挂这一个）。开关关掉时同一个 hook 会把它写回。
///
/// ⚠️ hook 方法上不写 `@MainActor`、方法体里用 `onMainThreadSync` —— 仓库成文规矩
/// （见 `LyricsChromeVisibility.swift:3-17`）；`target` 先取成局部量再进闭包。
class LibraryRowStyleHook: ClassHook<UIView> {
    typealias Group = LibraryAppearanceGroup
    static let targetName = "YourLibrary_CommonKit.YourLibrarySwipeableCollectionViewCellContainer"

    func layoutSubviews() {
        orig.layoutSubviews()
        let cell = self.target
        onMainThreadSync {
            LibraryRowsAppearance.apply(to: cell)
        }
    }
}
