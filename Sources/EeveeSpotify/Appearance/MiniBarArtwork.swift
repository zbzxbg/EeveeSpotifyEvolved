import Foundation
import UIKit

/// 迷你播放器左边那张封面 —— 做成**圆形**。
///
/// ## 出处
///
/// 上游 EeveeSpotifyReincarnated 本来就有这颗开关：`LiquidGlassOptions.roundArtwork`
/// （设置行 `npb_round_artwork`，图标 `circle.fill`），实现就是一行 ——
/// `GlassNowPlayingBar.x.swift:97`：`options.roundArtwork ? artwork.bounds.width / 2 : 12`。
///
/// ## 真机结构（日志 82 逐字）
///
/// ```
/// 9.UIView@26,3,344,48,id=SPTNowPlayingBar      ← 迷你条内容（胶囊里的那条）
/// 10.UIView@0,0,398,56,id=now-playing-bar-content
/// 11.UIView@8,8,40,40                            ← ★ 就是它：40×40、贴左 8pt
/// 12.InformationContainer@0,0,206,40             ← 不是它（宽）
/// ```
///
/// 它**没有 id**，所以按**结构**认：近似正方形（边长 32~56）、里面有图、
/// 在 host 坐标里**最靠左**的那个（迷你条里只有封面贴左边）。
/// 认不出就什么都不做 —— 宁可没效果，不要动错图。
///
/// ## 撤回
///
/// 只改 `cornerRadius` 与 `clipsToBounds`，**原值记在视图自己身上**（关联对象），
/// 关开关时逐个写回（与 `DeclutterChrome` 同一条纪律：只撤我们改的）。
enum MiniBarArtwork {

    static var isEnabled: Bool { UserDefaults.miniBarRoundArtwork }

    private static var radiusKey: UInt8 = 0
    private static var clipsKey: UInt8 = 0
    private static var roundedKey: UInt8 = 0
    /// 改过的那几个视图（weak，视图换掉自动失效）。
    private static let touched = NSHashTable<UIView>.weakObjects()
    private static var didLog = false

    /// 每一拍调（`MiniBarGlass.apply(to:)` 里），**幂等**：圆角已经对了就一个字节都不碰。
    static func apply(to host: UIView) {
        guard isEnabled else {
            revert()
            return
        }
        guard let artwork = findArtwork(in: host) else { return }
        round(artwork)
        // 有些版本图在子视图上、父层不裁 ⇒ 子层也一起圆（只对"和父层差不多大的"那层动手）。
        for sub in artwork.subviews where sub.bounds.width >= artwork.bounds.width * 0.8 {
            round(sub)
        }

        guard !didLog else { return }
        didLog = true
        writeDebugLog(
            "[MiniBarArt] round artwork \(NSStringFromClass(type(of: artwork)))"
                + " \(Int(artwork.bounds.width))x\(Int(artwork.bounds.height))"
                + " at \(Int(artwork.frame.minX)),\(Int(artwork.frame.minY)) → r="
                + String(format: "%.0f", artwork.bounds.height / 2)
        )
    }

    /// 关开关时原样写回。
    static func revert() {
        for view in touched.allObjects {
            let hadKey = objc_getAssociatedObject(view, &roundedKey) != nil
            guard hadKey else { continue }
            if let radius = objc_getAssociatedObject(view, &radiusKey) as? NSNumber {
                view.layer.cornerRadius = CGFloat(radius.doubleValue)
            }
            if let clips = objc_getAssociatedObject(view, &clipsKey) as? NSNumber {
                view.layer.masksToBounds = clips.boolValue
            }
            objc_setAssociatedObject(view, &roundedKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        didLog = false
    }

    // MARK: - 认那一张图

    private static func round(_ view: UIView) {
        let radius = view.bounds.height / 2
        guard radius > 1 else { return }

        // ⚠️ **先把原值记下来再改**（顺序反了撤回就会写回"已经改过"的值 —— 我第一版就是那样）。
        if objc_getAssociatedObject(view, &roundedKey) == nil {
            objc_setAssociatedObject(
                view, &radiusKey,
                NSNumber(value: Double(view.layer.cornerRadius)),
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
            objc_setAssociatedObject(
                view, &clipsKey,
                NSNumber(value: view.layer.masksToBounds),
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
            objc_setAssociatedObject(view, &roundedKey, NSNumber(value: true), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            touched.add(view)
        }

        if view.layer.cornerRadius != radius { view.layer.cornerRadius = radius }
        if !view.layer.masksToBounds { view.layer.masksToBounds = true }
        if view.layer.cornerCurve != .circular { view.layer.cornerCurve = .circular }
    }

    /// 候选：近似正方形、边长 32~56、里面有图；取 host 坐标里**最靠左**的那个。
    private static func findArtwork(in host: UIView) -> UIView? {
        var best: (view: UIView, minX: CGFloat)?

        var queue: [UIView] = [host]
        var visited = 0
        while !queue.isEmpty, visited < 300 {
            let view = queue.removeFirst()
            visited += 1

            let size = view.bounds.size
            let square = abs(size.width - size.height) <= 2
            if square, size.width >= 32, size.width <= 56, containsImage(view) {
                let frame = view.convert(view.bounds, to: host)
                if frame.minX <= 16, best == nil || frame.minX < best!.minX {
                    best = (view, frame.minX)
                }
            }
            queue.append(contentsOf: view.subviews)
        }
        return best?.view
    }

    private static func containsImage(_ root: UIView) -> Bool {
        if let imageView = root as? UIImageView, imageView.image != nil { return true }
        var queue: [UIView] = root.subviews
        var visited = 0
        while !queue.isEmpty, visited < 40 {
            let view = queue.removeFirst()
            visited += 1
            if let imageView = view as? UIImageView, imageView.image != nil { return true }
            queue.append(contentsOf: view.subviews)
        }
        return false
    }
}
