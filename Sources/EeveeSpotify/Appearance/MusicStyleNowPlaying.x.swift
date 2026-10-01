import Foundation
import Orion
import UIKit
import ObjectiveC.runtime

/// 「听歌页 Music 式版式」样品 **v1** —— 整套"观感自绘"路线的第一屏。
///
/// 目的不是做完整版，而是**花一次编译回答一个问题**：把听歌页往 Apple Music 那个方向推，
/// 值不值得铺到其它七屏。
///
/// ── 这一版只做两件（都是"不需要知道任何原生坐标"的）─────────────────────────
///   1. **整页背景跟着封面取色**：铺一层渐变在最底层（封面主色 → 压暗 → 近黑）。
///      这是 Apple Music 最标志性的一眼特征，而且只用安全区之外的整屏尺寸，零定位风险。
///   2. **顶部大标题 + 艺人**：贴在安全区顶部、居中（Apple Music 也是把字压在封面顶部；
///      它那里放艺人名，我们放歌名 + 艺人，信息更全）。用 Auto Layout 锚点，不碰原生 frame。
///
/// ── 刻意**不藏任何 Spotify 原生控件**（这一版只加不删）───────────────────────
/// 最坏情况是"多了一层、有点挤"，不会让播放页不能用。玻璃胶囊控件行 + 藏掉原生传输行留给 v2，
/// 等这一版的背景和标题方向确认了再做。
///
/// ── 三条纪律（照仓库既有做法）─────────────────────────────────────────────
///   1. **全程在开关后面，关掉完全还原**（移除我们插的视图）；
///   2. **幂等**：挂在 `viewDidLayoutSubviews` 上，重复调用不重复插；
///   3. **探测式取数据**：`SPTPlayerTrack` 的 getter 一律走
///      `string(ifResponding:)`（手写 protocol 声明 ≠ 实现，2026-10-01 崩溃的教训）。
///
/// 为什么挂 `viewDidLayoutSubviews` 而不是 `viewDidAppear`：
/// `NowPlayingGestureHook` 已经用了同一个类的 `viewDidAppear`，这里换一个**不同的 selector**，
/// 两条 hook 各swizzle各的，互不干扰（同 selector 双 swizzle 没必要冒险）。
struct MusicStyleNowPlayingGroup: HookGroup {}

enum MusicStyleNowPlaying {

    static var isEnabled: Bool { UserDefaults.musicStyleNowPlaying }

    /// 我们插进去的视图（weak：VC 的 view 换了就自动失效，下一轮重建）。
    private static weak var backdrop: CAGradientLayer?
    private static weak var titleStack: UIStackView?
    private static let titleLabelTag = 0xEE01
    private static let artistLabelTag = 0xEE02

    /// 上一次渲染用的曲目 id + 颜色，避免每次布局都重算/重绘。
    private static var lastTrackID: String?
    private static var didReport = false

    // MARK: - 施加 / 还原

    /// 由 `NowPlayingMusicStyleHook` 在每次布局时调用。幂等。
    static func apply(to root: UIView?) {
        guard let root else { return }

        guard isEnabled else {
            remove(from: root)
            return
        }

        let track = statefulPlayer?.currentTrack()

        ensureBackdrop(in: root, track: track)
        ensureTitleStack(in: root, track: track)

        if !didReport {
            didReport = true
            writeDebugLog("[MusicStyle] now playing sample applied — backdrop + title (native chrome untouched)")
        }
    }

    /// 关掉开关时把插进去的东西全部摘掉。只动**我们自己的**视图，不碰 Spotify 的任何东西。
    private static func remove(from root: UIView) {
        backdrop?.removeFromSuperlayer()
        backdrop = nil

        titleStack?.removeFromSuperview()
        titleStack = nil

        lastTrackID = nil
    }

    // MARK: - 背景：跟着封面取色

    private static func ensureBackdrop(in root: UIView, track: SPTPlayerTrack?) {
        let layer: CAGradientLayer
        if let existing = backdrop, existing.superlayer === root.layer {
            layer = existing
        } else {
            let created = CAGradientLayer()
            created.startPoint = CGPoint(x: 0.5, y: 0)
            created.endPoint = CGPoint(x: 0.5, y: 1)
            // 插在最底层：VC 自己的 `backgroundColor` 先画，我们的层盖在它上面、内容之下。
            root.layer.insertSublayer(created, at: 0)
            backdrop = created
            layer = created
        }

        if layer.frame != root.bounds {
            layer.frame = root.bounds
        }

        // 只在换歌时重算颜色（`extractedColorHex()` 是 Spotify 从封面里抽好的，日志 8 见过
        // `FF62787D` 这种 8 位 ARGB —— 解析不出来就保持上一次的，不编造颜色）。
        let trackID = track?.trackIdentifier ?? ""
        guard trackID != lastTrackID || layer.colors == nil else { return }
        lastTrackID = trackID

        guard let tint = tintColor(fromHex: track?.extractedColorHex()) else {
            // 拿不到颜色（本地文件、还没抽好）→ 给一层中性的深色，保证页面不出现"半透明黑洞"。
            layer.colors = [UIColor(white: 0.10, alpha: 1).cgColor, UIColor(white: 0.04, alpha: 1).cgColor]
            layer.locations = [0, 1]
            return
        }

        layer.colors = [
            tint.cgColor,
            darken(tint, by: 0.55).cgColor,
            UIColor(white: 0.03, alpha: 1).cgColor,
        ]
        layer.locations = [0, 0.55, 1]
    }

    /// `extractedColorHex()` → `UIColor`。8 位按 ARGB（`FF62787D`），6 位按 RGB。
    private static func tintColor(fromHex hex: String?) -> UIColor? {
        guard var raw = hex?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if raw.hasPrefix("#") { raw.removeFirst() }
        guard raw.count == 6 || raw.count == 8, let value = UInt32(raw, radix: 16) else { return nil }

        // 8 位是 ARGB：低 24 位才是 RGB（日志 8 的 `FF62787D` → #62787D）。
        let rgb = raw.count == 8 ? value & 0xFFFFFF : value
        return UIColor(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }

    /// 压暗（保色相、降亮度）。取不到 HSB 就原样返回。
    private static func darken(_ color: UIColor, by amount: CGFloat) -> UIColor {
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        guard color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha) else {
            return color
        }
        return UIColor(
            hue: hue,
            saturation: saturation,
            brightness: max(0.04, brightness * (1 - amount)),
            alpha: alpha
        )
    }

    // MARK: - 顶部大标题 + 艺人

    private static func ensureTitleStack(in root: UIView, track: SPTPlayerTrack?) {
        let stack: UIStackView
        if let existing = titleStack, existing.superview === root {
            stack = existing
        } else {
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
        title?.text = track?.string(ifResponding: "trackTitle")
        artist?.text = track?.string(ifResponding: "artistName")
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

/// 听歌页（大封面那页）：`_TtC21NowPlaying_ScrollImpl23NPVScrollViewController`
/// —— 与 `NowPlayingGestureHook` 同一个类，但用的是**另一个 selector**，互不干扰。
class NowPlayingMusicStyleHook: ClassHook<UIViewController> {
    typealias Group = MusicStyleNowPlayingGroup
    static let targetName = "_TtC21NowPlaying_ScrollImpl23NPVScrollViewController"

    func viewDidLayoutSubviews() {
        orig.viewDidLayoutSubviews()
        MusicStyleNowPlaying.apply(to: self.target.view)
    }
}

func activateMusicStyleNowPlaying() {
    guard NSClassFromString(NowPlayingMusicStyleHook.targetName) != nil else {
        writeDebugLog("[MusicStyle] missing \(NowPlayingMusicStyleHook.targetName) — hook inactive")
        return
    }

    MusicStyleNowPlayingGroup().activate()
    writeDebugLog(
        "[MusicStyle] installed (sample="
            + "\(UserDefaults.musicStyleNowPlaying ? "ON" : "OFF")"
            + " — backdrop tint + top title; native chrome untouched)"
    )
}
