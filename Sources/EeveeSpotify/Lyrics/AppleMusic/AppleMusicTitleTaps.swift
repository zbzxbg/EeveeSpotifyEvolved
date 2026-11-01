import UIKit

/// AM 样式下，标题 / 歌手那两行的透明命中区。
///
/// 为什么需要这一层：AM 壳（`AppleMusicLyricsOverlay`）是一层铺满整页的
/// `UIHostingController`，`isUserInteractionEnabled = true`，触摸命中整块区域；而标题 /
/// 歌手是 **Spotify 自己的 label**，在壳**下面** ⇒ 点击落不到原生控件上，表现就是
/// "AM 样式下点歌名/歌手什么都不发生"。
///
/// 沉浸式那条路有 `NowPlayingIOS27.placeTitleTapTargets`，但它的按钮挂在**页面**上，
/// 会被壳每帧 `bringSubviewToFront` 压回下面。这里把同形状的透明按钮挂到**壳自己**上：
/// 壳移动/置于最前时按钮跟着走，天然在上面。
///
/// 动作复用 `NowPlayingIOS27` 的两个入口（打开当前专辑 / 当前艺人），不另写一套 URL 逻辑。
enum AppleMusicTitleTaps {

    /// 当前挂载的壳。换壳（切页、重建 hosting）时要把旧按钮一起丢掉。
    private static weak var shell: UIView?
    private static var titleButton: UIButton?
    private static var artistButton: UIButton?

    /// 每帧调一次：按无障碍 id 找到原生那两行，把命中区对齐过去。
    ///
    /// 找不到 label 时不建按钮 —— 宁可点不动，也不要盖一块**错位的**命中区
    /// 把别处的点击吃掉。
    static func place(in page: UIView, on shell: UIView) {
        if AppleMusicTitleTaps.shell !== shell {
            clear()
            AppleMusicTitleTaps.shell = shell
        }

        guard let title = label(
            NowPlayingLyricsPlate.titleLabelIdentifier,
            in: page
        ), let artist = label(
            NowPlayingLyricsPlate.subtitleLabelIdentifier,
            in: page
        ) else { return }

        mount(
            &titleButton,
            on: shell,
            frame: hitFrame(of: title, in: shell),
            identifier: "eevee-am-title-tap"
        ) { NowPlayingIOS27.openAlbumFromTitleTap() }
        mount(
            &artistButton,
            on: shell,
            frame: hitFrame(of: artist, in: shell),
            identifier: "eevee-am-artist-tap"
        ) { NowPlayingIOS27.openArtistFromTitleTap() }
    }

    /// 壳被摘掉时由调用方收尾（按钮本身跟着壳走，这里只是把弱引用断掉）。
    static func clear() {
        titleButton?.removeFromSuperview()
        titleButton = nil
        artistButton?.removeFromSuperview()
        artistButton = nil
        shell = nil
    }

    // MARK: - 内部

    private static func mount(
        _ slot: inout UIButton?,
        on container: UIView,
        frame: CGRect,
        identifier: String,
        action: @escaping () -> Void
    ) {
        guard frame.width > 1, frame.height > 1 else {
            slot?.isHidden = true
            return
        }

        let button: UIButton
        if let existing = slot, existing.superview === container {
            button = existing
        } else {
            slot?.removeFromSuperview()
            button = UIButton(type: .custom)
            button.backgroundColor = .clear
            // 两行文字本身已经有读屏内容；这颗只是透明命中区，别让读屏多读一条。
            button.isAccessibilityElement = false
            button.accessibilityIdentifier = identifier
            button.addAction(UIAction { _ in action() }, for: .touchUpInside)
            container.addSubview(button)
        }

        button.isHidden = false
        if button.frame != frame { button.frame = frame }
        if container.subviews.last !== button {
            container.bringSubviewToFront(button)
        }
        slot = button
    }

    /// 命中区：label 在壳坐标里的矩形，四周各放 6pt（手指比字大）。
    private static func hitFrame(of label: UILabel, in container: UIView) -> CGRect {
        label.convert(label.bounds, to: container)
            .insetBy(dx: -6, dy: -6)
            .intersection(container.bounds)
    }

    /// 按无障碍 id 在页面里找那两行（深度优先的广度遍历，节点数封顶防跑飞）。
    ///
    /// 判定要求"真的在屏幕上"：隐藏的、透明的、不在窗口上的都不算 ——
    /// 切歌过渡期间 Spotify 会留着一份旧的 label，认错就会盖到错误的位置。
    private static func label(_ identifier: String, in page: UIView) -> UILabel? {
        var queue: [UIView] = [page]
        var visited = 0
        while !queue.isEmpty, visited < 3000 {
            let view = queue.removeFirst()
            visited += 1
            if let label = view as? UILabel,
               label.accessibilityIdentifier == identifier,
               !label.isHidden,
               label.alpha > 0.01,
               label.window != nil,
               label.bounds.width > 1,
               label.bounds.height > 1 {
                return label
            }
            queue.append(contentsOf: view.subviews)
        }
        return nil
    }
}
