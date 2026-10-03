import Foundation
import Orion
import UIKit
import ObjectiveC.runtime

/// 清爽开关：把 Spotify 自己画的三块"非内容"隐藏掉。
///
/// 目标类名**不是猜的**，来自 2026-09-30 的真机视图树转储 + 9.1.86 符号转储：
///
///   真机树里的形状                                    运行期名（`targetName`）
///   `5.TouchPassthroughView@0,749,414,64`           → `_TtC22NowPlaying_BarPageImplP33_CCC0D2EEA6D4725EECD8965E8C38C86D20TouchPassthroughView`
///     正好贴在标签栏上方（749 + 64 = 标签栏顶 813），里面才是 `id=SPTNowPlayingBar`
///   `12.TabBarGradientView@0,-112,414,195`          → `_TtC23NavigationUI_TabBarImpl18TabBarGradientView`
///   `5.LimitedExperienceIndicatorBar@0,896,414,0`   → `_TtC44LimitedExperienceIndicator_MessageBarRuntime29LimitedExperienceIndicatorBar`
///
/// ⚠️ 可撤销但**只管自己**：Spotify 自己在来回切这几处的 `isHidden`（真机树里同一个
/// `TouchPassthroughView` 一次是 `hidden`、一次不是 —— 取决于有没有在播放）。
/// 所以：
///   · 开关打开 → 藏，并**用关联对象记住"这一层是我藏的"**；
///   · 开关关掉 → 只撤回**我们**藏的那一次，Spotify 自己藏的一律不碰。
/// 第一版没有这条，结果是"关掉开关它也不回来"（用户以为坏了）—— 现在关掉即恢复。
///
/// ⚠️⚠️ 但"关掉即恢复"只在**下一次 layout 真的到来**时才成立。2026-10-01 的日志 8 证明
/// 它并不可靠，见下面 `reconcile` 那一段的说明（迷你播放条没上报、加号按钮没生效，
/// 用户那边的表现是"迷你条消失且无法恢复"）。所以每个开关现在**两个时机**都跑：
///   1. 目标类自己的 `layoutSubviews`（快路径，保持原样）；
///   2. `MainWindow` 的节流复查 + 开关被手动切换 + App 回到前台（兜底，见 `reconcile`）。
struct HideMiniPlayerGroup: HookGroup {}
struct HideHomeHeaderGroup: HookGroup {}
struct HideTransportChromeGroup: HookGroup {}

/// 关联对象的键。file-scope 的 `var` 地址稳定，这是本仓库既有的写法
/// （见 `UpsellPopupBlocker.x.swift` 的 `upsellPopupAssociationKey`）。
private var declutterHiddenByUsKey: UInt8 = 0

private func wasHiddenByUs(_ view: UIView) -> Bool {
    (objc_getAssociatedObject(view, &declutterHiddenByUsKey) as? NSNumber)?.boolValue == true
}

private func markHiddenByUs(_ view: UIView) {
    objc_setAssociatedObject(
        view,
        &declutterHiddenByUsKey,
        NSNumber(value: true),
        .OBJC_ASSOCIATION_RETAIN_NONATOMIC
    )
}

private func clearHiddenByUs(_ view: UIView) {
    objc_setAssociatedObject(view, &declutterHiddenByUsKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
}

enum DeclutterChrome {

    static var hideMiniPlayerBar: Bool { UserDefaults.hideMiniPlayerBar }

    /// 封面与歌名之间那一行"跟唱单行歌词"。
    ///
    /// 为什么它上面显示的是**我们的**歌词：`NgzhwmSettingsViewModel.isOfficialLyricsHidden`
    /// 是**数据层**的开关（取不到我们的词时用占位 payload 顶掉 Spotify 的歌词），它不隐藏
    /// 视图。反过来，我们供给的歌词会被 Spotify **自己的**视图渲染 —— 包括这个跟唱单行
    /// 视图。所以那一行不是"挂错了"，而是"Spotify 的壳 + 我们的字"。
    ///
    /// 真机证据（日志 6 的 NPV 转储）：
    ///   `22.CoverArtTiltView@15,0,335,335`            ← 封面
    ///   `22.LyricsContainerView@0,335,366,120`        ← 就在封面正下方
    ///   `23.LyricsView@0,0,366,120,id=singalong-lyrics-view`
    ///
    /// 默认**关**：用户说过那一行本身不是问题（他反馈的是"逐词歌词开、更好的逐词歌词关"
    /// 时逐行歌词挂错地方，已修在 `InlineLyricsHostLocator`）。这个开关只留作选择。
    static var hideSingalongLine: Bool { UserDefaults.hideSingalongLine }

    // MARK: - 首页 / 播放器那一批（2026-09-30 真机树实证）

    /// 首页顶部那条（问候语 + 筛选胶囊）。
    ///
    /// 证据：`HomeHeaderView@0,0,414,50`，只在**首页**的转储里出现（日志 7 的 #1–#7），
    /// 运行期类名 `_TtC19Home_FunkisPageImplP33_297EC57FD07AE9FCEAA7B66079FC278C14HomeHeaderView`。
    static var hideHomeHeader: Bool { UserDefaults.hideHomeHeader }

    /// 设备 / 输出切换按钮（"连接"）。
    ///
    /// 证据：`ConnectButtonView@0,0,44,40,id=Components.ConnectButtonOutputSwitcher`，
    /// **20/20 份转储全都有**（深度 14）—— 它在迷你播放条和播放器里共用，
    /// 所以关掉是"所有传输条上都不显示"，不只是播放器页。
    static var hideConnectButton: Bool { UserDefaults.hideConnectButton }

    /// 播放器里的"加号"按钮。
    ///
    /// 证据：`UIButton@0,0,44,40,id=Components.UI.AddToButton`，与设备按钮**同级**
    /// （同一深度 14）。它是普通 `UIButton`，按类名 hook 不到，所以从兄弟里按 id 找。
    static var hideAddToButton: Bool { UserDefaults.hideAddToButton }

    private static var reported: Set<String> = []

    /// 每个开关只报一次：证明 hook 真的跑到了，并说明藏的是哪一个。
    /// 和 AMOLED 那边同一个道理 —— 验收靠日志，不靠眼睛。
    static func reportOnce(_ key: String, _ message: String) {
        guard !reported.contains(key) else { return }
        reported.insert(key)
        writeDebugLog("[Declutter] \(message)")
    }

    /// ★★ 2026-10-09：**「封面下单行歌词」这个开关到底该干什么 —— 三层，各管一段。**
    ///
    /// ## 用户给的两轮现场
    ///
    /// 第一轮（照片 58/59，逐字）：
    /// > 图片 58 是胶囊显示「显示歌词」（**此时单行功能生效**）的时候截屏的
    /// > （但是这个功能似乎是**只隐藏歌词内容，不隐藏功能，所以封面被抬上去了**）；
    /// > 图片 59 是胶囊显示「隐藏歌词」的时候截屏的（**此时单行功能关闭，封面还是原来的正常的样子**）。
    /// > **我想要的高度效果是图片 59 的效果。**
    ///
    /// 第二轮（照片 60）：
    /// > **那个单行歌词并没有被隐藏** …… 并且开关「隐藏封面下单行歌词」的按钮没有用。
    ///
    /// ## 日志 53 说清了"为什么没有用"
    ///
    /// ```
    /// 08:08:02  [Declutter] singalong is on but the show/hide-lyrics pill was not found
    ///                       - leaving it alone (you can still switch it off by hand; …)
    /// ```
    ///
    /// 上一轮把整个机制压在**"替用户按下那颗胶囊"**这一条路上，而那颗胶囊的判据是
    /// **类名子串 `ShowLyricsButton`**（来自类名表 `dump-9.1.88.txt:3570`
    /// 的 `Lyrics_CardElementImpl.ShowLyricsButtonElementUI`）。日志 53 的
    /// `[NPVTree]`（听歌页子树，390–556 节点，**没有截断**）里**一个含 `ShowLyricsButton`
    /// 的视图都没有** ⇒ 那条判据在运行期根本命不中，于是：不按、不藏、什么都不做。
    /// **类名子串是猜的，不是从视图树上读来的** —— 这正是仓库规矩 4 说的那件事。
    ///
    /// ## 现在的三层（从"立刻能看见"到"从根上关掉"）
    ///
    /// | 层 | 做什么 | 什么时候生效 |
    /// |---|---|---|
    /// | ① **当场藏掉那一行**（`singalong.isHidden = true` + 我们的标记） | 屏幕上立刻没有那一行歌词 | 下一拍（≤0.3s） |
    /// | ② **按它自己的胶囊**（判据放宽：类名子串 **或** 无障碍标签；**一场只按一次**） | Spotify 自己的功能被真正关掉 | 找到就立刻 |
    /// | ③ **关掉它自己的 flag**（`lyrics_under_cover_art_enabled=false`，见 `DynamicPremium+ModifyingFunctions`） | 连"封面被抬起来"的布局后果与那颗胶囊一起消失 | **下次启动**（customize 重发） |
    ///
    /// ①与②③**不冲突**：①只让那一行看不见（内容层），③管的是"这个功能在不在"（布局层）。
    /// 上一轮把①整块删掉、只留②，于是②一失败就**什么都没有** —— 那正是照片 60 的状态。
    ///
    /// ⚠️ 找到胶囊时**用 `sendActions(for: .touchUpInside)` 而不是改它的 state**：
    /// 让 Spotify 自己走一遍它的动作（它要落盘用户偏好、要重排那一格）。
    ///
    /// ⚠️ 判据为什么从"整窗 BFS 2000 节点"改成"**key window + 更大预算**"：
    /// 那颗胶囊在听歌页的**覆盖层**上（照片 58 里它在底部左侧、进度条上方），
    /// 而听歌页子树本身就有 390–556 个节点，全窗口 BFS 的前 2000 个很容易被首页那棵大树吃光。
    @discardableResult
    static func applySingalongPreference(singalong: UIView, in root: UIView) -> Bool {
        // ① 内容层：不管功能开没开，这一行都不该出现（开关开着的时候）。
        if !singalong.isHidden {
            singalong.isHidden = true
            markHiddenByUs(singalong)
            reportOnce(
                "singalongLineHidden",
                "hid the sing-along line itself (the feature is still Spotify's; see the flag below)"
            )
        }

        // 本来就关着（那一格高度 0）：没什么可关的，算成功。
        guard singalong.bounds.height > 1 else { return true }

        // ★★ 一次会话**只按一次**（独立复核抓到的 blocker）。
        //
        // 那颗胶囊上写的是「显示歌词 / 隐藏歌词」—— **两个标签都在判据表里**，
        // 而判据不看 `alpha` / `isHidden`。所以"按过之后再按一次"是**完全可能**的：
        // 节流只挡住 2s 内的重复，T+2s / T+4s 那两拍会再次找到**同一个控件**并按下去。
        // `sendActions` 是**切换**，于是按两次 = 又开回来（照片 58 的封面被抬起 = 用户报的那个症状），
        // 而日志还会连着说两遍"已经关掉了"。
        //
        // ⇒ 按下过就记账（`pillWeHid` 非空 = 这一场已经按过），不再找、不再按。
        //    真要"再关一次"只有两条路：用户把开关关掉再打开（`restoreSingalongIfNeeded` 清账），
        //    或者**第三层**（`lyrics_under_cover_art_enabled=false`，下次启动）。
        guard pillWeHid == nil else { return true }

        // ② 功能层：替他按下那颗胶囊。
        switch lookUpShowLyricsPill(in: root) {
        case .found(let control):
            control.sendActions(for: .touchUpInside)
            // ★ 按住的就是**刚按下去的那一个**（不要再走一次查找 —— 那条查找有 2s 节流与 3 次上限，
            //   第二次调用必然空手而归，胶囊就会留在屏幕上，而用户明确说过它不该出现）。
            pillWeHid = control
            control.alpha = 0
            reportOnce(
                "singalongOff",
                "turned Spotify's own singalong line off through its pill"
                    + " (hiding the view was not enough: it removed the text but left the cover lifted)"
            )
            reportOnce(
                "singalongPillHidden",
                "hid the show/hide-lyrics pill (the singalong is off, so it has nothing left to toggle)"
            )
            return true

        case .notFound:
            // ★ 只有**真的把三次预算走完**才算"找不到"（独立复核抓到：节流/预算用尽那一拍
            //   上一版也会走到这里，于是第一次空手就打"找不到"，那句日志此后永不重复，
            //   结果是"三次都空"和"只试了一次"在日志里长得一模一样）。
            guard pillSearchAttempts >= pillSearchMaxAttempts else { return false }
            reportPillSearchShapeOnce()
            reportOnce(
                "singalongPillMissing",
                "singalong is on but no show/hide-lyrics pill was found after"
                    + " \(pillSearchMaxAttempts) search(es) - the line stays hidden,"
                    + " and the flag replacement (next launch) takes the feature itself away"
            )
            return false

        case .skipped:
            // 节流 / 预算用尽：这一拍**根本没查**，什么都不许报。
            return false
        }
    }

    /// 那行被抬起来之后要写回的东西：`.singalong` 视图本身（旧版本可能给它写过 `hidden`）
    /// 和我们按住过的那颗胶囊。
    private static weak var pillWeHid: UIView?

    /// 关掉开关时写回。
    ///
    /// ⚠️ **写回的是"我们动过的视图"，不是"Spotify 的偏好"**（独立复核指出这里原来那句话说得太满）：
    /// 我们按下去的那颗胶囊走的是 Spotify 自己的动作（它会落盘用户偏好），而**偏好写不回去** ——
    /// 想还原只能"再按一次"，可那时屏幕上分不清"是我们关的"还是"用户自己关的"
    /// （判据只有那一行的高度），再按一次就可能**违背用户刚刚的手动选择**。
    /// ⇒ 所以：视图全部还原（那一行、那颗胶囊的 `alpha`）、**偏好留给用户自己按一下**
    ///   （胶囊已经被我们写回可见了），并在文档里写明这一点。
    private static func restoreSingalongIfNeeded(_ view: UIView) {
        // 旧机制（藏视图）留下的痕迹也要清掉，否则升级上来的用户会一直看不到那一行。
        if wasHiddenByUs(view) {
            view.isHidden = false
            clearHiddenByUs(view)
            writeDebugLog("[Declutter] singalongLine restored")
        }
        // 那条走查的账也要清：用户关掉再打开开关时，应该重新给三次机会去找那颗胶囊
        // （`pillWeHid` 也一起清 —— 「一次会话只按一次」那条门禁就是它）。
        pillSearchAttempts = 0
        lastPillSearchAt = 0
        reportedPillSearchShape = false
        lastPillSearchControlsSeen = 0

        guard let pill = pillWeHid else { return }
        pill.alpha = 1
        pillWeHid = nil
        writeDebugLog(
            "[Declutter] the show/hide-lyrics pill is visible again"
                + " (Spotify's own preference is whatever our single press left it at -"
                + " press the pill once if you want it back)"
        )
    }

    /// 那颗「显示歌词 / 隐藏歌词」胶囊 —— **它没有 id**，找到后要拿到它**能点的那个 `UIControl`**。
    ///
    /// ## 两条判据（2026-10-09 放宽）
    ///
    /// 1. **类名子串 `ShowLyricsButton`** —— 来自类名表
    ///    （`Lyrics_CardElementImpl.ShowLyricsButtonElementUI`，`dump-9.1.88.txt:3570`）。
    ///    ⚠️ 它在日志 53 的听歌页视图树（`[NPVTree]`，390–556 节点、**没有被预算截断**）里
    ///    **一个都没有** ⇒ 这条判据在运行期很可能永远不成立。留着只是因为"某些构建里它也许真是那个类"，
    ///    代价只是一次字符串判断。
    /// 2. **无障碍标签逐字命中**「显示歌词 / 隐藏歌词」（英文 `Show lyrics` / `Hide lyrics`）
    ///    —— 胶囊上写的就是这几个字（照片 58/59 逐像素可见）。仓库里已有先例：
    ///    `WordByWordPlaybackControl` 找原生控件用的就是标签表（`["expand", "full screen", …]`）。
    ///
    /// ★ **找不到就只打一行日志，绝不拿"看起来像"的控件去按。** 判据必须能说清"为什么是它"。
    ///
    /// ## 预算与节流
    ///
    /// 那颗胶囊在听歌页的**覆盖层**上（照片 58：底部左侧、进度条上方），而听歌页子树本身
    /// 就有 390–556 个节点 ⇒ 整窗 BFS 的 2000 节点很容易被首页那棵大树吃光（上一版就是 2000）。
    /// 这里给到 8000，并且**每次最多 3 次尝试、每次间隔 ≥2s** ——
    /// 找不到就不再空转（仓库纪律：走查有界，且不做变相轮询）。
    private static let showLyricsPillLabels: [String] = [
        "显示歌词", "隐藏歌词",
        "Show lyrics", "Hide lyrics",
    ]

    private static let pillSearchNodes = 8000
    private static let pillSearchInterval: CFAbsoluteTime = 2.0
    private static let pillSearchMaxAttempts = 3
    private static var pillSearchAttempts = 0
    private static var lastPillSearchAt: CFAbsoluteTime = 0
    private static var reportedPillSearchShape = false
    /// 最近一次走查看到过多少个 `UIControl`（只进那行"形状"日志）。
    private static var lastPillSearchControlsSeen = 0

    /// 那一次查找的三种结局 —— **必须分开**（独立复核抓到的假日志）：
    /// 上一版把"节流没过、根本没查"与"查了、没有"混成同一个 `nil`，
    /// 于是日志会在第一次空手时就说"没找到"，而且那句此后不再重复。
    private enum PillLookup {
        case found(UIControl)
        case notFound
        case skipped
    }

    private static func lookUpShowLyricsPill(in root: UIView) -> PillLookup {
        let now = CFAbsoluteTimeGetCurrent()
        guard pillSearchAttempts < pillSearchMaxAttempts,
              now - lastPillSearchAt >= pillSearchInterval else { return .skipped }
        lastPillSearchAt = now
        pillSearchAttempts += 1

        var visited = 0
        var controlsSeen = 0
        var queue: [UIView] = [root]

        while !queue.isEmpty, visited < pillSearchNodes {
            let view = queue.removeFirst()
            visited += 1

            if let control = view as? UIControl {
                controlsSeen += 1
                if let label = control.accessibilityLabel?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   showLyricsPillLabels.contains(label) {
                    lastPillSearchControlsSeen = controlsSeen
                    return .found(control)
                }
            }
            if NSStringFromClass(type(of: view)).contains("ShowLyricsButton") {
                if let control = firstControl(in: view) {
                    lastPillSearchControlsSeen = controlsSeen
                    return .found(control)
                }
            }
            queue.append(contentsOf: view.subviews)
        }

        lastPillSearchControlsSeen = controlsSeen
        return .notFound
    }

    /// 走查的形状**只报一次**（预算真的走完之后才调）：
    /// 下一次日志里就能看出"那条路走过几次、看了多少控件、比对了什么"，
    /// 而不是像日志 53 那样只能看到一句"没找到"（连找过几个节点都不知道）。
    private static func reportPillSearchShapeOnce() {
        guard !reportedPillSearchShape else { return }
        reportedPillSearchShape = true
        writeDebugLog(
            "[Declutter] show/hide-lyrics pill: \(pillSearchAttempts) search(es),"
                + " ≤\(pillSearchNodes) nodes each, \(lastPillSearchControlsSeen) control(s) inspected"
                + " — neither a view whose class contains ShowLyricsButton"
                + " nor a control labelled one of \(showLyricsPillLabels.joined(separator: " / "))"
        )
    }

    private static func firstControl(in view: UIView) -> UIControl? {
        if let control = view as? UIControl { return control }
        var visited = 0
        var queue: [UIView] = view.subviews
        while !queue.isEmpty, visited < 64 {
            let node = queue.removeFirst()
            visited += 1
            if let control = node as? UIControl { return control }
            queue.append(contentsOf: node.subviews)
        }
        return nil
    }

    // ★ 2026-10-09：`hideShowLyricsPill(in:)` 已删 —— 它在按下胶囊之后**又查一次**
    //   （`showLyricsPillView`），而新加的查找有 2s 节流 + 3 次上限 ⇒ 第二次必然空手而归，
    //   胶囊就留在屏幕上（用户明确说过它不该出现）。现在由 `applySingalongPreference`
    //   直接把"刚按下的那一个"写进 `pillWeHid` 并 `alpha = 0`（一次查找只服务一次动作）。

    /// 藏 / 撤销，两个方向都幂等。
    ///
    /// 关键区别在"谁藏的"：`isHidden == true` 可能是 Spotify 自己写的（没在播放时
    /// 迷你条本来就不显示）。所以撤销只针对被我们打过标的那些视图。
    ///
    /// ## ⚠️ 2026-10-08：**这里曾经试过 `soft: true`（用 `alpha` 代替 `hidden`），已撤回**
    ///
    /// 经过：用户照片 58（隐藏开）/ 59（隐藏关）对照显示封面高度不同，我先判成
    /// "`hidden` 让 Encore 重排 ⇒ 用 `alpha` 就不会动"。**用户随后纠正了**：
    ///
    /// > 那个功能确实会隐藏单行歌词，但是**不会阻止封面上抬**。所以在用户的视角来看是：
    /// > 这个单行歌词里面没有单行歌词滚过，但**把封面往上抬的功能没有阻止**。
    ///
    /// ⇒ 真正的问题是"**只藏了文字、没有撤销布局后果**"，而 `alpha` 恰好**把那一格留着**，
    /// 等于把那个后果**保下来** —— 方向反了。所以回到 `hidden`（它至少让 Encore 重排一次），
    /// 并且**默认值保持「关」**、不改这一块的行为。
    /// **下一步必须先问清"开着的时候你到底想让封面去哪"，再动这里**（见交接文档 §13）。
    static func apply(
        wantHidden: Bool,
        to view: UIView,
        reportKey: String,
        reportMessage: String
    ) {
        if wantHidden {
            guard !view.isHidden else { return }

            view.isHidden = true
            markHiddenByUs(view)
            reportOnce(reportKey, reportMessage)
            return
        }

        guard wasHiddenByUs(view) else { return }

        view.isHidden = false
        clearHiddenByUs(view)
        writeDebugLog("[Declutter] \(reportKey) restored")
    }

    // MARK: - 复查（reconcile）：把"藏 / 还原"接到一个一定会跑的节拍上

    /// ⚠️ 为什么必须有它（2026-10-01 日志 8 的实证）
    ///
    /// 原来只有"目标类自己的 `layoutSubviews`"一个时机，两个后果：
    ///
    ///   · **迷你播放条**：启动时没在播放，Spotify 把 `TouchPassthroughView` 设成 `hidden`，
    ///     我们的 `apply` 走 `guard !view.isHidden` 直接返回（不标记、不上报）。等 Spotify
    ///     把它显示回来时不一定再有 layout 回合 —— 日志 8 的 #19/#20 里它已经显示，
    ///     而整份日志**一行 `[Declutter]` 都没有**（日志 5 那次恰好启动时就在播放，才有）。
    ///     用户那边的表现就是"迷你条消失且无法恢复"。
    ///
    ///   · **加号按钮**：它只能从 `ConnectButtonView` 的兄弟里找，而那颗按钮**已经被我们藏了**，
    ///     被藏的视图不再收 layout 回合 → 那次扫描实际只跑过启动一次（日志 8 的 #4–#20
    ///     里 `id=Components.UI.AddToButton` 全部可见，且从没上报）。
    ///
    /// 所以换成**常驻可见的宿主**（`MainWindow`，`_TtC30ContainerUI_RootUIInternalImpl10MainWindow`，
    /// 每份真机转储里都在、每次布局都跑）做节流复查，另外两个时机也强制跑：
    ///   · 开关被手动切换（设置页 → `reconcileNow()`，关掉要**当场**还回来）；
    ///   · App 回到前台（`didBecomeActive`，正是"划出 Spotify 再回来"那一步）。
    ///
    /// 复查是幂等的：开关开着就确保藏起来，关着就只撤回**我们**藏过的那一次。

    /// 解析结果的缓存。全窗口扫描不便宜，所以结果留着；视图被换掉时 `weak` 自动失效，
    /// 下一轮重扫即可。
    private struct ResolvedTargets {
        weak var miniBar: UIView?
        weak var singalong: UIView?
        weak var homeHeader: UIView?
        weak var connect: UIView?
        weak var addTo: UIView?
    }

    private static var targets = ResolvedTargets()
    private static var lastReconcileAt: CFAbsoluteTime = 0
    private static var lastScanAt: CFAbsoluteTime = 0
    /// 节流窗口。`MainWindow` 在滚动时几乎每帧都有 layout，0.3s 一次足够追上 Spotify 的
    /// 显示逻辑，又不至于每帧走一遍窗口树。
    private static let reconcileInterval: CFAbsoluteTime = 0.3
    /// 找那两颗按 id 认的按钮比"重新施加一遍"贵，单独再节流一次。
    private static let scanInterval: CFAbsoluteTime = 1.0
    /// 扫描节点上限。正常一屏远小于它，纯粹防病态情况。
    private static let maxScanNodes = 3000

    /// 开关被手动切换 / App 回到前台时调用：**当场**落地，不等下一次 layout。
    static func reconcileNow() {
        lastReconcileAt = 0
        lastScanAt = 0
        reconcile(in: keyWindowRoot())
    }

    /// 把当前所有清爽开关重新施加一遍。幂等、只读查找、不改别的视图。
    static func reconcile(in root: UIView?, force: Bool = false) {
        guard let root else { return }

        let now = CFAbsoluteTimeGetCurrent()

        if !force {
            guard now - lastReconcileAt >= reconcileInterval else { return }
        }
        lastReconcileAt = now

        // 那两个按 id 认的按钮，只有对应开关开着时才需要找（默认都关着 → 默认零扫描）。
        // 关掉开关时**不需要**重新找：`targets` 里还留着上一次的引用，够用来还原。
        if (hideConnectButton || hideAddToButton), now - lastScanAt >= scanInterval {
            lastScanAt = now
            resolveIDTargets(in: root)
        }

        if let view = targets.miniBar {
            apply(
                wantHidden: hideMiniPlayerBar,
                to: view,
                reportKey: "miniPlayer",
                reportMessage: "mini player bar hidden (TouchPassthroughView)"
            )
        }
        if let view = targets.singalong {
            if hideSingalongLine {
                // ★★ 2026-10-09：**两层一起做** —— ①当场藏掉那一行（屏幕上立刻见效），
                //    ②替他按下 Spotify 自己那颗胶囊（功能真的关掉，并把胶囊一起按住）。
                //    上一轮只剩②，而②的判据（类名子串）在运行期零命中 ⇒ 什么都没有发生。
                //    第二层之上还有第三层：`lyrics_under_cover_art_enabled=false`
                //    （见 `DynamicPremium+ModifyingFunctions` 的 flag 替换，下次启动生效）。
                _ = applySingalongPreference(singalong: view, in: root)
            } else {
                restoreSingalongIfNeeded(view)
            }
        }
        if let view = targets.homeHeader {
            apply(
                wantHidden: hideHomeHeader,
                to: view,
                reportKey: "homeHeader",
                reportMessage: "home header hidden (HomeHeaderView)"
            )
        }
        if let view = targets.connect {
            apply(
                wantHidden: hideConnectButton,
                to: view,
                reportKey: "connectButton",
                reportMessage: "connect button hidden (Components.ConnectButtonOutputSwitcher)"
            )
        }
        if let view = targets.addTo {
            apply(
                wantHidden: hideAddToButton,
                to: view,
                reportKey: "addToButton",
                reportMessage: "add-to button hidden (Components.UI.AddToButton)"
            )
        }

        // ★ v4.8：迷你条那条胶囊的"封面色底"守卫（`MiniBarGlass.swift`）——
        //   Spotify 会在我们清完之后**再写回**封面色，而那个写回**不一定**伴随宿主的
        //   布局回合（照片 36 那块蓝就是这么留下来的：清一次 → 被写回 → 再没有布局回合）。
        //   这里就是"看一眼 + 幂等清"（一次属性读），开关关着 / 没迷你条时零开销；
        //   它自己还有一轮 50ms 级的短促重试负责首帧。
        //   ⚠️ 刻意**不新开定时器** —— 蹭的就是这个既有的节拍（0.5s，且非前台不跑）。
        onMainThreadSync { MiniBarGlassPlate.reconcileCoverColor() }

        // ★ 2026-10-03 夜：听歌页那层"封面取色底"的**换歌/滚动**自愈
        //   （`NowPlayingBackdrop.reconcile()`）。日志 38 的 #7→#9 是现场：
        //   用户**一直待在听歌页**，Spotify 那层底色自己从 `bg=#E84838` 变成 `bg=#584860`、
        //   高度 896 变 1682，而这期间**没有第三次 `[NPVStyle]`**（`apply` 只在
        //   `viewWillAppear`/`viewDidAppear` 跑）⇒ 换歌、滚动之后我们的层必然失配。
        //   没在听歌页时它的成本 = 两次 weak 读 + 一次 `window` 读；
        //   在听歌页时再加**一次 `backgroundColor` 读**（换色那一刻才问 metadata）。
        //   同一条纪律：**不新开定时器**，蹭这个节拍。
        onMainThreadSync { _ = NowPlayingBackdrop.reconcile() }

        // ★ 2026-10-03 夜：听歌页「一屏」的**重算节拍**（`NowPlayingOneScreen.reconcile()`）。
        //   卡片是列表建好之后**才陆续到**的，每来一张都会把内容高度顶上去，而 `apply`
        //   只在进页面时跑一遍；`willDisplayCell` 那一刻的高度更是"一个 runloop 之后才定"
        //   （pw 为此专门补了一枪 async）。同一条纪律：**不新开定时器**，蹭这个节拍；
        //   值没漂就一个字节都不写，没在听歌页时只是两次 weak 读。
        onMainThreadSync { _ = NowPlayingOneScreen.reconcile() }

        // ★ 听歌页「**我们自己的覆盖层**」（`NowPlayingPageOverlay`）也要跟着重排：
        //   Spotify 换帧会重排 subviews 把我们挤下去，换歌 / 转场之后底部锚的 frame 也会变。
        //   同一条纪律：**不新开定时器**，frame 没变就一个字节都不写。
        onMainThreadSync { _ = NowPlayingPageOverlay.reconcile() }

        // ★ 2026-10-04：「歌词进播放器」那一层也要跟着重排 + 驱动时间轴。
        //   它的位置来自底部那一坨（卡片折叠/换歌都会动），时间轴**刻意**就用这个节拍
        //   （约 0.3s 一拍，不新开 CADisplayLink —— 行间移动本身带 SwiftUI 动画，
        //   肉眼与每帧没差别）。没开开关时成本 = 一次 bool 读。
        onMainThreadSync { _ = NowPlayingLyricsPlate.reconcile() }

        // ★ 2026-10-04：「控制键换成本地字形」的保活（Spotify 换帧会重排那一排的 subviews）。
        //   没开开关时成本 = 一次 bool 读。
        onMainThreadSync { _ = NowPlayingControlsPlate.reconcile() }

        // ★ 2026-10-03 夜：**只读播放器状态探针**（`PlayerStateProbe`）—— 给「突然无法播放
        //   任何歌曲」那条线补现场判据（它至今零判据：31 份日志里 drm/license/unplayable
        //   全零命中，分不开"服务端按地区判不可播"和"账号风控"）。
        //   它自己先看「启用日志记录」，开关关着 = 一眼都不看；只在**换曲 / 卡住 / 恢复**
        //   时打，所以不刷屏。同一条纪律：**不新开定时器**。
        onMainThreadSync { PlayerStateProbe.tick() }

        // ★ v4.9：标签栏那一行的**纵向复核**。点开「创建」时那一颗处于暂时态，
        //   而**菜单关掉时这条栏不一定再布局** —— 日志 29 里我们的 transform 就停在
        //   `+2.5`，创建那颗一直比另外三颗高 8pt（16 秒没回来）。
        //   这里跟上面同一个纪律：**只在"这一行还没稳"时才真的重算**，稳着时是一次 bool 读。
        onMainThreadSync { TabBarGlassPlate.reconcileRowIfTransient() }
    }

    // MARK: 目标登记

    /// 五个"有专属类名"的目标：由各自的 hook 在 `layoutSubviews` 里登记自己。
    ///
    /// ⚠️ 为什么不在这里按类名去找：`NSStringFromClass` 对 Swift 类返回什么形式
    /// （`_TtC…` 混淆名，还是别的写法）依 Swift 版本而异，拿它跟 `targetName` 比字符串
    /// 是一场不必要的赌注；而 **hook 手里已经有实例了**，让它顺手登记一下最稳。
    enum Target {
        case miniBar
        case singalong
        case homeHeader
    }

    static func note(_ target: UIView, as kind: Target) {
        switch kind {
        case .miniBar: targets.miniBar = target
        case .singalong: targets.singalong = target
        case .homeHeader: targets.homeHeader = target
        }
    }

    /// 只有设备按钮与加号按钮这里按**无障碍 id** 找（判据与原 hook 完全相同）。
    ///
    /// 这两个没有能单独 hook 的类名：加号是普通 `UIButton`，而"从 `ConnectButtonView` 的
    /// 兄弟里扫"这条路会被"被藏掉就不再 layout"掐断 —— 这正是日志 8 里它没生效的原因。
    private static func resolveIDTargets(in root: UIView) {
        var connect: UIView?
        var addTo: UIView?
        var queue: [UIView] = [root]
        var index = 0

        while index < queue.count, index < maxScanNodes, connect == nil || addTo == nil {
            let view = queue[index]
            index += 1

            if let identifier = view.accessibilityIdentifier {
                if connect == nil, identifier == "Components.ConnectButtonOutputSwitcher" {
                    connect = view
                } else if addTo == nil, identifier == "Components.UI.AddToButton" {
                    addTo = view
                }
            }

            queue.append(contentsOf: view.subviews)
        }

        // 只更新这两个；另外五个由各自的 hook 登记，别在这里清掉。
        targets.connect = connect
        targets.addTo = addTo
    }

    private static func keyWindowRoot() -> UIView? {
        let windows = UIApplication.shared.windows
        return windows.first(where: { $0.isKeyWindow }) ?? windows.first
    }

    // MARK: - 复查的两个驱动（定时器 + 前台）

    private static var lifecycleObserver: NSObjectProtocol?
    private static var reconcileTimer: Timer?

    static func installReconcileDrivers() {
        startReconcileTimer()

        guard lifecycleObserver == nil else { return }

        // App 回到前台时强制复查一次。用户反馈的"划出 Spotify（不是杀掉）再回来，
        // 迷你条就没了/回不来"正发生在这一步：视图可能被重建，或 Spotify 自己重排了一遍。
        // 每次前台打一行日志，方便下一份日志直接确认这条路径跑过。
        lifecycleObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            writeDebugLog("[Declutter] reconcile (app became active)")
            DeclutterChrome.reconcileNow()
        }
    }

    /// 兜底节拍器。
    ///
    /// ⚠️ 为什么不能只靠 `MainWindow` 的 `layoutSubviews`：UIKit 的布局只从"自己
    /// `needsLayout`"的那些视图上往下跑，**深层子视图重新布局不一定会走到 window 自己**，
    /// 所以那个节拍并不保证。这里补一个和 `ViewTreeDumper` 同款的定时器（`.common` 模式，
    /// 滚动时也不会停；App 进后台被挂起时自然停摆），保证"Spotify 把 chrome 显示回来"
    /// 这件事在 0.5s 内一定被复查到。
    private static func startReconcileTimer() {
        guard reconcileTimer == nil else { return }

        let timer = Timer(timeInterval: 0.5, repeats: true) { _ in
            // **熄屏/后台不做任何事**（与 `ViewTreeDumper.dumpOnce` 同一条纪律）。
            // Spotify 在后台放歌时进程不会挂起，这个 0.5s 的节拍没必要在用户看不见屏幕时空转。
            // 手动调用的那两个入口（开关切换 / didBecomeActive）不受这条影响，照常当场落地。
            guard UIApplication.shared.applicationState == .active else { return }
            reconcile(in: keyWindowRoot())
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        reconcileTimer = timer
    }
}

/// 迷你播放条（标签栏上方那条，用户照片里就是它）。藏的是它的 host：
/// host 的 frame 正好等于 bar 区域（414x64），藏它才不会留一条空白。
class MiniPlayerBarHideHook: ClassHook<UIView> {
    typealias Group = HideMiniPlayerGroup
    static let targetName =
        "_TtC22NowPlaying_BarPageImplP33_CCC0D2EEA6D4725EECD8965E8C38C86D20TouchPassthroughView"

    func layoutSubviews() {
        orig.layoutSubviews()

        // 顺手登记：之后这个实例就被复查（`DeclutterChrome.reconcile`）持续盯着，
        // 即使它自己后来不再收到 layout 回合。
        DeclutterChrome.note(self.target, as: .miniBar)

        // ★ 迷你播放条的**液态玻璃胶囊**（`MiniBarGlass.swift`）蹭的就是这个布局回调 ——
        //   同一个类上再挂一个 ClassHook 是没验证过的行为，所以那边只画、不钩。
        //   顺序无所谓：藏掉时它照样画（看不见而已），开关关掉它会自己撤掉并把底色还原。
        // ⚠️ hook 方法体是**非隔离**的（Orion 的代码生成器会把 `@MainActor` 拼坏，见
        //   `LyricsChromeVisibility.swift` 顶上那段），所以这里必须套 `onMainThreadSync`。
        let host = self.target
        onMainThreadSync { MiniBarGlassPlate.apply(to: host) }

        DeclutterChrome.apply(
            wantHidden: DeclutterChrome.hideMiniPlayerBar,
            to: self.target,
            reportKey: "miniPlayer",
            reportMessage: "mini player bar hidden (TouchPassthroughView)"
        )
    }
}

/// 封面下那行跟唱歌词。
/// ⚠️ 它是**通用类**（`Lyrics_TextComponentImpl.LyricsView`），别的地方也可能用同一类，
/// 所以判据只认那个 id：`accessibilityIdentifier == "singalong-lyrics-view"`
/// （真机树实测值）。命中不了就什么都不做 —— 宁可漏，不可误伤别处的歌词视图。
///
/// 已知局限：只藏视图本身，**120pt 的槽位可能还在**（容器 `LyricsContainerView` 是
/// Spotify 的布局，动它有把歌词卡一起弄坏的风险）。真机如果看出空档，再单独处理。
struct HideSingalongLineGroup: HookGroup {}

class SingalongLyricsLineHideHook: ClassHook<UIView> {
    typealias Group = HideSingalongLineGroup
    static let targetName = "_TtC24Lyrics_TextComponentImpl10LyricsView"

    func layoutSubviews() {
        orig.layoutSubviews()

        guard self.target.accessibilityIdentifier == "singalong-lyrics-view" else { return }

        // 只登记；**真正动手的是 `reconcile` 那条节拍里的 `applySingalongPreference`**
        // —— 那条路手上有页面根（要找得到那颗胶囊），而这里只有这一行自己。
        DeclutterChrome.note(self.target, as: .singalong)
    }
}

/// 首页顶部那条（问候语 + 筛选胶囊）。
class HomeHeaderHideHook: ClassHook<UIView> {
    typealias Group = HideHomeHeaderGroup
    static let targetName =
        "_TtC19Home_FunkisPageImplP33_297EC57FD07AE9FCEAA7B66079FC278C14HomeHeaderView"

    func layoutSubviews() {
        orig.layoutSubviews()

        DeclutterChrome.note(self.target, as: .homeHeader)

        DeclutterChrome.apply(
            wantHidden: DeclutterChrome.hideHomeHeader,
            to: self.target,
            reportKey: "homeHeader",
            reportMessage: "home header hidden (HomeHeaderView)"
        )
    }
}

/// 传输控件那一排：设备按钮（自己）+ 加号按钮（同级的普通 UIButton）。
///
/// 挂在 `ConnectButtonView` 上，因为它是这一批里唯一有"专属类名 + 稳定 id"的节点；
/// 加号只能从它的兄弟里按 id 找（`Components.UI.AddToButton`）。
class TransportChromeHideHook: ClassHook<UIView> {
    typealias Group = HideTransportChromeGroup
    static let targetName = "_TtC23Connect_EntryPointsImpl17ConnectButtonView"

    func layoutSubviews() {
        orig.layoutSubviews()

        DeclutterChrome.apply(
            wantHidden: DeclutterChrome.hideConnectButton,
            to: self.target,
            reportKey: "connectButton",
            reportMessage: "connect button hidden (Components.ConnectButtonOutputSwitcher)"
        )

        guard let siblings = self.target.superview?.subviews else { return }

        for sibling in siblings where sibling !== self.target {
            guard sibling.accessibilityIdentifier == "Components.UI.AddToButton" else { continue }

            DeclutterChrome.apply(
                wantHidden: DeclutterChrome.hideAddToButton,
                to: sibling,
                reportKey: "addToButton",
                reportMessage: "add-to button hidden (Components.UI.AddToButton)"
            )
        }
    }
}

/// 复查的**宿主**。
///
/// 为什么是 `MainWindow`：真机树里它是 `0.MainWindow@0,0,414,896,id=spotify-main-window`，
/// 运行期名 `_TtC30ContainerUI_RootUIInternalImpl10MainWindow`；它在**每一份**转储里都在，
/// 而且每次布局都会走一遍 —— 拿它当节拍器，就不会再出现"目标被我们藏掉之后再没有 layout"
/// 这种死结（日志 8 的迷你条与加号按钮就是这么坏的）。
struct DeclutterReconcileGroup: HookGroup {}

class DeclutterReconcileHook: ClassHook<UIView> {
    typealias Group = DeclutterReconcileGroup
    static let targetName = "_TtC30ContainerUI_RootUIInternalImpl10MainWindow"

    func layoutSubviews() {
        orig.layoutSubviews()
        DeclutterChrome.reconcile(in: self.target)
    }
}

func activateDeclutterChrome() {
    // 每个 group 各自按"类在不在"决定装不装（本仓库既有做法）：目标类缺失时 Orion
    // 会报一条非致命错误，不如自己先判掉，日志也更干净。
    if NSClassFromString(MiniPlayerBarHideHook.targetName) != nil {
        HideMiniPlayerGroup().activate()
    } else {
        writeDebugLog("[Declutter] missing \(MiniPlayerBarHideHook.targetName) — mini player hook inactive")
    }

    if NSClassFromString(SingalongLyricsLineHideHook.targetName) != nil {
        HideSingalongLineGroup().activate()
    } else {
        writeDebugLog("[Declutter] missing \(SingalongLyricsLineHideHook.targetName) — singalong hook inactive")
    }

    if NSClassFromString(HomeHeaderHideHook.targetName) != nil {
        HideHomeHeaderGroup().activate()
    } else {
        writeDebugLog("[Declutter] missing \(HomeHeaderHideHook.targetName) — home header hook inactive")
    }

    if NSClassFromString(TransportChromeHideHook.targetName) != nil {
        HideTransportChromeGroup().activate()
    } else {
        writeDebugLog("[Declutter] missing \(TransportChromeHideHook.targetName) — transport hook inactive")
    }

    // 复查的两个驱动：0.5s 定时器（主节拍）+ App 回到前台（划出/回来那一刻）。
    // 宿主 hook 缺失也不致命：那两个驱动还在，只是少一个免费节拍。
    if NSClassFromString(DeclutterReconcileHook.targetName) != nil {
        DeclutterReconcileGroup().activate()
    } else {
        writeDebugLog("[Declutter] missing \(DeclutterReconcileHook.targetName) — reconcile hook inactive")
    }
    DeclutterChrome.installReconcileDrivers()

    writeDebugLog(
        "[Declutter] installed (miniPlayer="
            + "\(DeclutterChrome.hideMiniPlayerBar ? "ON" : "OFF")"
            + " singalongLine=\(DeclutterChrome.hideSingalongLine ? "ON" : "OFF")"
            + " homeHeader=\(DeclutterChrome.hideHomeHeader ? "ON" : "OFF")"
            + " connectButton=\(DeclutterChrome.hideConnectButton ? "ON" : "OFF")"
            + " addToButton=\(DeclutterChrome.hideAddToButton ? "ON" : "OFF"))"
    )
}
