import Foundation
import Orion
import UIKit
import ObjectiveC.runtime

/// 「听歌页 Music 式版式」的**旧版残留**：顶部大标题（歌名 + 艺人）。
///
/// ── 这个文件现在只负责一件事 ────────────────────────────────────────────────
/// 整个"观感"已经搬到 `NowPlayingShell.x.swift`（自绘壳 = 满屏取色背景 + 玻璃顶栏 +
/// 让原生吸顶头让位）。这里的 `applyLegacyTitle` 只剩**旧开关**
/// （`UserDefaults.musicStyleNowPlaying`）那一支的标题绘制 —— 为的是"用户手里的
/// 老开关继续能用、且关掉能完全还原"，不是新功能。
///
/// ── 为什么背景那段被删了（v1 的真机实证）────────────────────────────────────
/// v1 的 `ensureBackdrop` 是 `root.layer.insertSublayer(gradient, at: 0)`，插在**最底层**；
/// 而 Spotify 自己有两个**整屏不透明**的视图压在上面：
///   `10.UIView@0,0,414,896,bg=<封面色>` 与 `12.NPVGradientView@0,0,414,896`。
/// 日志 12（开）/ 14（关）两版里这些节点**逐字相同** —— 也就是说用户看到的颜色
/// 从头到尾都是 Spotify 自己染的，我们那层等于白画。**背景改由壳负责**
/// （`LyricsBackdropView(style: .stage)`：铺满整屏、在最前、经全屏歌词页验证过）。
///
/// ── 两条纪律 ────────────────────────────────────────────────────────────────
///   1. 只加不删：这个标题是"多加一层"，关掉即移除，不隐藏任何原生控件；
///   2. 探测式取数据：`SPTPlayerTrack` 的 getter 一律走 `string(ifResponding:)`
///      （手写 protocol 声明 ≠ 实现，2026-10-01 崩过两次）。
struct MusicStyleNowPlayingGroup: HookGroup {}

/// 由 `applyNowPlayingAppearance` 统一驱动。**不标 `@MainActor`** ——
/// 调用点已经过 `onMainThreadSync`，而"hook 方法/其直接调用链上不写 `@MainActor`"
/// 是本仓库的成文规矩（见 `LyricsChromeVisibility.swift:3-17`）。
enum MusicStyleNowPlaying {

    /// 旧开关：只驱动"我们画的那个大标题"。
    static var isEnabled: Bool { UserDefaults.musicStyleNowPlaying }

    /// 我们插进去的标题（weak：VC 的 view 换了就自动失效，下一轮重建）。
    private static weak var titleStack: UIStackView?
    private static let titleLabelTag = 0xEE01
    private static let artistLabelTag = 0xEE02

    private static var didReport = false

    // MARK: - 施加 / 还原

    /// 由 `applyNowPlayingAppearance(to:)` 在每次布局时调用。幂等。
    ///
    /// ⚠️ 用 `resolvedRoot` 而不是直接 `root`：新壳铺满整屏、压在原生内容之上，
    /// 标题如果挂在同一个视图上就会被壳的顺序影响。挂到**壳所在的父视图**
    /// （也就是听歌页的根视图）并置于最前，才能保证它在最上层。
    static func applyLegacyTitle(to root: UIView?) {
        guard let root else { return }

        guard isEnabled else {
            removeLegacyTitle()
            return
        }

        ensureTitleStack(in: root, track: statefulPlayer?.currentTrack())

        // 每次布局都抬一次：Spotify 自己也会调整层级。
        if let stack = titleStack { root.bringSubviewToFront(stack) }

        if !didReport {
            didReport = true
            writeDebugLog("[MusicStyle] 旧版标题已施加（native chrome untouched）")
        }
    }

    /// 关掉开关时把插进去的标题摘掉。只动**我们自己的**视图，不碰 Spotify 的任何东西。
    private static func removeLegacyTitle() {
        titleStack?.removeFromSuperview()
        titleStack = nil
    }

    // MARK: - 顶部大标题 + 艺人

    private static func ensureTitleStack(in root: UIView, track: SPTPlayerTrack?) {
        let stack: UIStackView
        if let existing = titleStack, existing.superview === root {
            stack = existing
        } else {
            titleStack?.removeFromSuperview()
            stack = makeTitleStack()
            root.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 6),
                stack.leadingAnchor.constraint(equalTo: root.safeAreaLayoutGuide.leadingAnchor, constant: 24),
                stack.trailingAnchor.constraint(equalTo: root.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            ])
            titleStack = stack
        }

        let title = stack.viewWithTag(titleLabelTag) as? UILabel
        let artist = stack.viewWithTag(artistLabelTag) as? UILabel

        // 探测式取字符串：`artistTitle()` 在 9.1.86 上不存在，这里只调存在的。
        let newTitle = track?.string(ifResponding: "trackTitle")
        let newArtist = track?.string(ifResponding: "artistName")
        if title?.text != newTitle { title?.text = newTitle }
        if artist?.text != newArtist { artist?.text = newArtist }
    }

    private static func makeTitleStack() -> UIStackView {
        let title = UILabel()
        title.tag = titleLabelTag
        title.font = .systemFont(ofSize: 26, weight: .bold)
        title.textColor = .white
        title.textAlignment = .center
        title.numberOfLines = 2
        title.layer.shadowColor = UIColor.black.cgColor
        title.layer.shadowOpacity = 0.45
        title.layer.shadowRadius = 6
        title.layer.shadowOffset = CGSize(width: 0, height: 1)

        let artist = UILabel()
        artist.tag = artistLabelTag
        artist.font = .systemFont(ofSize: 14, weight: .medium)
        artist.textColor = UIColor.white.withAlphaComponent(0.78)
        artist.textAlignment = .center
        artist.numberOfLines = 1
        artist.layer.shadowColor = UIColor.black.cgColor
        artist.layer.shadowOpacity = 0.45
        artist.layer.shadowRadius = 6
        artist.layer.shadowOffset = CGSize(width: 0, height: 1)

        let stack = UIStackView(arrangedSubviews: [title, artist])
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        // 只显示、不挡触摸（原生返回键/更多键都在这一带）。
        stack.isUserInteractionEnabled = false
        return stack
    }
}
