import Foundation
import UIKit

/// 迷你播放器左边那张封面 —— 做成**圆形**。
///
/// ## 出处
///
/// 上游 EeveeSpotifyReincarnated 有这颗开关（`LiquidGlassOptions.roundArtwork` / 设置行
/// `npb_round_artwork`），而 **pw v0.21.1** 的 `Redesigned/NowPlayingBar/NowPlayingBar.x`
/// （GPL-3.0；v0.22.0 起该仓库改为 PolyForm Strict，那里的代码不可复制）把它写得最准，
/// 这里就是照它重写的 —— 连判据和"往外扩到同样大小的祖先"都一样：
///
/// ```objc
/// BOOL square = size.width >= 36 && size.width <= 48 && fabs(size.width - size.height) < 1;
/// if (!square || v.layer.cornerRadius <= 0) return;          // ★ 只认"已经有圆角"的方块
/// if (v.layer.cornerRadius >= size.width / 2) { … return; }   // 已经是圆的：认它，不动
/// for (u = v; u && u != card && CGSizeEqualToSize(u.bounds.size, size); u = u.superview) {
///     roundView(u, size.width / 2); u.clipsToBounds = YES;    // 连外层同样大小的容器一起圆
/// }
/// ```
///
/// 它的树注释（`trees/home.txt`）写着那格是 `artwork 40x40 **r=4**` —— **这就是那条去重判据的来历**：
/// Spotify 给封面方块留了 4pt 圆角，而同一个 40×40 的容器（`InformationContainer` 里那个）**没有圆角**。
///
/// ⚠️ 我第一版用"里面有没有图"去分辨，日志 84 证明**分不出来**（`[MiniBarArt]` 一行都没有），
/// 而且失败时什么都不打 —— 两处都已照 pw 改正。
///
/// ## 真机结构（日志 82/84 逐字）
///
/// ```
/// 9.UIView@26,3,344,48,id=SPTNowPlayingBar      ← 迷你条内容（胶囊里那条）
/// 10.UIView@0,0,398,56,id=now-playing-bar-content
/// 11.UIView@8,8,40,40                            ← ★ 就是它：40×40、贴左 8pt（r=4）
/// ```
///
/// ## 撤回
///
/// 只改 `cornerRadius` 与 `masksToBounds`，**原值在改之前**记在视图自己身上（关联对象），
/// 关开关时逐个写回（与 `DeclutterChrome` 同一条纪律：只撤我们改的）。
enum MiniBarArtwork {

    static var isEnabled: Bool { UserDefaults.miniBarRoundArtwork }

    private static var radiusKey: UInt8 = 0
    private static var clipsKey: UInt8 = 0
    private static var roundedKey: UInt8 = 0
    /// 改过的那几个视图（weak，视图换掉自动失效）。
    private static let touched = NSHashTable<UIView>.weakObjects()
    private static var didLog = false
    /// "没认出来"只报一次（见 `logMissOnce`）。
    private static var didLogMiss = false

    /// 每一拍调（`MiniBarGlass.apply(to:)` 里），**幂等**。
    ///
    /// - Parameter content: **必须是迷你条内容视图**（`id=SPTNowPlayingBar` 那个，即
    ///   `MiniBarGlass.findContent` 找到的那一个），不是外层 host —— 判据要相对它算。
    static func apply(to content: UIView) {
        guard isEnabled else {
            revert()
            return
        }
        guard let artwork = roundArtwork(in: content) else {
            logMissOnce(in: content)
            return
        }

        guard !didLog else { return }
        didLog = true
        writeDebugLog(
            "[MiniBarArt] round artwork \(NSStringFromClass(type(of: artwork)))"
                + " \(Int(artwork.bounds.width))x\(Int(artwork.bounds.height))"
                + " at \(Int(artwork.frame.minX)),\(Int(artwork.frame.minY))"
                + " → r=\(Int(artwork.bounds.width / 2))"
                + " (pw's rule: a 36–48pt square that already carries a corner radius)"
        )
    }

    /// 关开关时原样写回。
    static func revert() {
        for view in touched.allObjects {
            guard objc_getAssociatedObject(view, &roundedKey) != nil else { continue }
            if let radius = objc_getAssociatedObject(view, &radiusKey) as? NSNumber {
                view.layer.cornerRadius = CGFloat(radius.doubleValue)
            }
            if let clips = objc_getAssociatedObject(view, &clipsKey) as? NSNumber {
                view.layer.masksToBounds = clips.boolValue
            }
            objc_setAssociatedObject(view, &roundedKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        didLog = false
        didLogMiss = false
    }

    // MARK: - 认那一张图（pw 的判据）

    /// 找到并圆掉，返回最外层被动过的那个视图（可能是封面方块本身，也可能是包着它的同尺寸容器）。
    private static func roundArtwork(in root: UIView) -> UIView? {
        guard let artwork = firstArtworkCandidate(in: root) else { return nil }
        // 已经是圆的：认它、不动（pw 同一分支：`cornerRadius >= width / 2`）。
        guard artwork.layer.cornerRadius < artwork.bounds.width / 2 else { return artwork }

        var outer = artwork
        var node: UIView? = artwork
        // pw：**连外层"同样大小"的祖先一起圆** —— 图片有可能在更外面那层裁剪容器里。
        while let current = node, current !== root, current.bounds.size == artwork.bounds.size {
            round(current)
            outer = current
            node = current.superview
        }
        return outer
    }

    /// 第一个"36~48pt 的方块、**而且已经有圆角**"的视图（深度优先，先命中先算）。
    private static func firstArtworkCandidate(in root: UIView) -> UIView? {
        var queue: [UIView] = [root]
        var visited = 0
        while !queue.isEmpty, visited < 400 {
            let view = queue.removeFirst()
            visited += 1
            let size = view.bounds.size
            let square = size.width >= 36 && size.width <= 48 && abs(size.width - size.height) < 1
            if square, view.layer.cornerRadius > 0 { return view }
            queue.append(contentsOf: view.subviews)
        }
        return nil
    }

    private static func round(_ view: UIView) {
        let radius = view.bounds.width / 2
        guard radius > 1 else { return }

        // ⚠️ **先把原值记下来再改**（顺序反了，撤回会把我们自己的值写回去）。
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
        if view.layer.cornerCurve != .continuous { view.layer.cornerCurve = .continuous }
    }

    /// 认不出时报一次，**并把方形候选打出来**（含各自有没有圆角 —— 这正是那条判据）——
    /// 盲写代码时这就是下一轮的依据。
    private static func logMissOnce(in root: UIView) {
        guard !didLogMiss else { return }
        didLogMiss = true

        var candidates: [String] = []
        var queue: [UIView] = [root]
        var visited = 0
        while !queue.isEmpty, visited < 300, candidates.count < 8 {
            let view = queue.removeFirst()
            visited += 1
            let size = view.bounds.size
            if abs(size.width - size.height) <= 2, size.width >= 20, size.width <= 80 {
                let frame = view.convert(view.bounds, to: root)
                candidates.append(
                    "\(NSStringFromClass(type(of: view)))"
                        + " \(Int(size.width))x\(Int(size.height))"
                        + "@\(Int(frame.minX)),\(Int(frame.minY))"
                        + " r=\(String(format: "%.1f", view.layer.cornerRadius))"
                )
            }
            queue.append(contentsOf: view.subviews)
        }

        writeDebugLog(
            "[MiniBarArt] no artwork found in \(NSStringFromClass(type(of: root)))"
                + " \(Int(root.bounds.width))x\(Int(root.bounds.height))"
                + " — square candidates: " + (candidates.isEmpty ? "none" : candidates.joined(separator: " | "))
        )
    }
}
