import Foundation
import Orion
import UIKit
import ObjectiveC.runtime

/// ★★ 2026-10-31（用户：「歌词偏移放到听歌页，放到右上角的按钮」→ 选定「接管 ⋯ 弹窗加一行」）：
///
/// 播放页右上那颗 `⋯` 弹出的**不是 `UIMenu`，是一张 sheet**（`ContextMenuViewController`）。
/// 想往里加一行只有两条路：
///
///   ① 像 taurus 那样**整个接管重画**（`Redesigned/Player/PlayerMenu.x`，871 行：隐藏原 sheet、
///      自己画一张卡片、按行号重建全部行）。功能最全，但 Spotify 换一版菜单结构就整块失效；
///   ② **在它的表尾挂一行**（`tableView.tableFooterView`）。不动数据源、不动行号、
///      不动它自己的 cell，代价是这一行只能出现在**列表最后**。
///
/// 这里选 ② —— 我们只需要"多一个入口"，不需要重排它的菜单。判据也尽量少：
///
///   · **只认播放器那一张**：正在播放页在屏上（`nowPlayingScrollViewController` 的 view 还在窗口里），
///     或呈现者链里有 `NowPlaying` / `NPVScroll` 的类名。别处弹出的上下文菜单一个字节都不动；
///   · **只认有歌词上下文的时候**：拿不到「当前曲目 + 歌词源」就不挂（没有可偏的对象）；
///   · **Genius 不挂**：`LyricsTimingOffset.supportsOffset` 为假 —— 它的时间轴是纯文本推出来的，
///     平移没有意义（与设置页同一条口径）；
///   · 任何一环认不出 ⇒ **什么都不做，只打一行日志**（这条纪律与页头那套一致）。
struct PlayerMenuOffsetGroup: HookGroup {}

class ContextMenuOffsetRowHook: ClassHook<UIViewController> {
    typealias Group = PlayerMenuOffsetGroup
    static let targetName = "_TtC24ContextMenu_InternalImpl25ContextMenuViewController"

    func viewDidAppear(_ animated: Bool) {
        orig.viewDidAppear(animated)
        LyricsOffsetMenuRow.attach(to: target)
    }
}

/// 菜单表尾那一行「歌词偏移」。
enum LyricsOffsetMenuRow {

    /// 这一张菜单（点击时要用它 dismiss）。
    private static weak var activeMenu: UIViewController?
    /// 点开面板要的三个值（在**建行那一刻**取好 —— 菜单开着的时候不会切歌，但别赌）。
    private static var activeContext: (trackId: String, source: LyricsSource, song: String)?

    /// 表尾行的高度（与 Spotify 自己的行同高，不显得突兀）。
    private static let rowHeight: CGFloat = 56

    // MARK: - 挂上去

    static func attach(to menu: UIViewController) {
        guard let view = menu.viewIfLoaded else { return }
        guard isPlayerMenu(menu) else { return }
        guard let context = currentContext() else {
            logOnce("noContext", "player menu: no lyrics context (no track / no source) — no offset row")
            return
        }
        guard let table = tableView(in: view) else {
            logOnce(
                "noTable",
                "player menu: no UITableView inside \(NSStringFromClass(type(of: menu)))"
                    + " — the offset row has nowhere to go"
            )
            return
        }

        activeMenu = menu
        activeContext = context
        // 表还没量过宽度时退回页面宽度 —— `UITableView` 自己会把 footer 的宽度改成自己的 bounds，
        // 这里只是别让它一开始就是 1pt（那样会闪一下）。
        let width = table.bounds.width > 1 ? table.bounds.width : view.bounds.width
        let row = makeRow(context: context, width: width)
        table.tableFooterView = row
        logOnce(
            "attached",
            "player menu: offset row attached — \(NSStringFromClass(type(of: table)))"
                + " \(Int(table.bounds.width))×\(Int(table.bounds.height)),"
                + " \(context.source.description), \(context.trackId)"
        )
    }

    /// 这一张是不是**播放器**的 `⋯` 菜单。
    ///
    /// 两条判据取或：正在播放页在屏上；或呈现者链里出现 `NowPlaying` / `NPVScroll` 的类名。
    /// 两条都不成立就当作"别处的上下文菜单"，不碰。
    private static func isPlayerMenu(_ menu: UIViewController) -> Bool {
        if let page = nowPlayingScrollViewController?.viewIfLoaded, page.window != nil { return true }
        var node: UIViewController? = menu
        var hops = 0
        while let current = node, hops < 12 {
            hops += 1
            let name = NSStringFromClass(type(of: current))
            if name.contains("NowPlaying") || name.contains("NPVScroll") { return true }
            node = current.presentingViewController
        }
        return false
    }

    /// 当前这份歌词的「曲目 + 源 + 歌名」。任缺一项就不挂（没有可偏的对象）。
    private static func currentContext() -> (trackId: String, source: LyricsSource, song: String)? {
        let trackId = currentLyricsDtoTrackId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trackId.isEmpty, let source = currentLyricsSource else { return nil }
        guard LyricsTimingOffset.supportsOffset(source: source) else { return nil }
        let track = statefulPlayer?.currentTrack() ?? nowPlayingScrollViewController?.loadedTrack
        let title = track?.string(ifResponding: "trackTitle") ?? ""
        let artist = track?.string(ifResponding: "artistName")
            ?? track?.string(ifResponding: "artistTitle")
            ?? ""
        let song = [title, artist]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " — ")
        return (trackId, source, song)
    }

    private static func tableView(in root: UIView) -> UITableView? {
        var queue: [UIView] = [root]
        var visited = 0
        while !queue.isEmpty, visited < 800 {
            let view = queue.removeFirst()
            visited += 1
            if let table = view as? UITableView { return table }
            queue.append(contentsOf: view.subviews)
        }
        return nil
    }

    // MARK: - 那一行长什么样

    private static func makeRow(
        context: (trackId: String, source: LyricsSource, song: String),
        width: CGFloat
    ) -> UIView {
        let row = UIControl(frame: CGRect(x: 0, y: 0, width: max(width, 1), height: rowHeight))
        row.autoresizingMask = [.flexibleWidth]

        let icon = UIImageView(image: UIImage(systemName: "timer"))
        icon.tintColor = .secondaryLabel
        icon.contentMode = .scaleAspectFit
        icon.frame = CGRect(x: 20, y: (rowHeight - 22) / 2, width: 22, height: 22)
        row.addSubview(icon)

        let title = UILabel()
        title.text = "lyrics_offset_title".localized
        title.font = .systemFont(ofSize: 17)
        title.textColor = .label
        title.frame = CGRect(x: 54, y: 0, width: max(width - 160, 1), height: rowHeight)
        title.autoresizingMask = [.flexibleWidth]
        row.addSubview(title)

        let offset = LyricsTimingOffset.offsetMs(forTrackId: context.trackId, source: context.source)
        let value = UILabel()
        value.text = offset == 0 ? "" : "\(offset > 0 ? "+" : "−")\(abs(offset)) ms"
        value.font = .systemFont(ofSize: 15)
        value.textColor = .secondaryLabel
        value.textAlignment = .right
        value.frame = CGRect(x: width - 140, y: 0, width: 104, height: rowHeight)
        value.autoresizingMask = [.flexibleLeftMargin]
        row.addSubview(value)

        let chevron = UIImageView(image: UIImage(systemName: "chevron.right"))
        chevron.tintColor = .tertiaryLabel
        chevron.contentMode = .scaleAspectFit
        chevron.frame = CGRect(x: width - 28, y: (rowHeight - 14) / 2, width: 12, height: 14)
        chevron.autoresizingMask = [.flexibleLeftMargin]
        row.addSubview(chevron)

        row.addTarget(Target.shared, action: #selector(Target.tapped), for: .touchUpInside)
        row.accessibilityLabel = "lyrics_offset_title".localized
        return row
    }

    // MARK: - 点开

    /// `UIControl` 的 target 必须是个存活的对象 —— 用一个单例，别让行自己持有。
    final class Target: NSObject {
        static let shared = Target()

        @objc func tapped() {
            guard let context = LyricsOffsetMenuRow.activeContext else { return }
            let menu = LyricsOffsetMenuRow.activeMenu
            LyricsOffsetMenuRow.activeMenu = nil
            LyricsOffsetMenuRow.activeContext = nil
            writeDebugLog("[LyricsOffset] player menu row tapped — \(context.trackId)")
            // 先收起整张 sheet 再弹面板。
            // ⚠️ 要 dismiss **最外层**那个 VC：`ContextMenuViewController` 通常只是 sheet 里的
            //    子 VC，直接对它 `dismiss` 在 UIKit 里是空操作（taurus 的 `presentedSheet` 同理）。
            menu?.topmostPresented().dismiss(animated: true) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    LyricsOffsetPanel.present(
                        trackId: context.trackId,
                        source: context.source,
                        song: context.song
                    )
                }
            }
        }
    }

    // MARK: - 日志

    private static var logged = Set<String>()

    private static func logOnce(_ key: String, _ message: String) {
        guard logged.insert(key).inserted else { return }
        writeDebugLog("[LyricsOffset] \(message)")
    }
}

/// 沿 `parentViewController` 走到**最外层**那个 —— 收起 sheet 时要用它。
///
/// 为什么不能直接 dismiss 菜单那个 VC：`ContextMenuViewController` 通常只是 sheet 里的子 VC，
/// 对没被 present 的 VC 调 `dismiss` 在 UIKit 里是**空操作**（taurus 的 `presentedSheet` 也是先走到顶）。
private extension UIViewController {
    func topmostPresented() -> UIViewController {
        var top = self
        while let parent = top.parentViewController { top = parent }
        return top
    }
}

func activatePlayerMenuOffsetRow() {
    guard NSClassFromString(ContextMenuOffsetRowHook.targetName) != nil else {
        writeDebugLog(
            "[LyricsOffset] \(ContextMenuOffsetRowHook.targetName) missing —"
                + " the player menu keeps its own rows"
        )
        return
    }
    PlayerMenuOffsetGroup().activate()
    writeDebugLog("[LyricsOffset] player menu hook on — a \"lyrics offset\" row goes under Spotify's own rows")
}
