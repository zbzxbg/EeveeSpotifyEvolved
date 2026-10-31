import Foundation
import Orion
import UIKit
import ObjectiveC.runtime

/// 清爽开关：把 Spotify 自己画的三块"非内容"隐藏掉。
///
/// 目标类名**不是猜的**，来自的真机视图树转储 + 9.1.86 符号转储：
///
/// 真机树里的形状 运行期名（`targetName`）
/// `5.TouchPassthroughView@0,749,414,64` → `_TtC22NowPlaying_BarPageImplP33_CCC0D2EEA6D4725EECD8965E8C38C86D20TouchPassthroughView`
/// 正好贴在标签栏上方（749 + 64 = 标签栏顶 813），里面才是 `id=SPTNowPlayingBar`
/// `12.TabBarGradientView@0,-112,414,195` → `_TtC23NavigationUI_TabBarImpl18TabBarGradientView`
/// `5.LimitedExperienceIndicatorBar@0,896,414,0` → `_TtC44LimitedExperienceIndicator_MessageBarRuntime29LimitedExperienceIndicatorBar`
///
/// ⚠️ 可撤销但**只管自己**：Spotify 自己在来回切这几处的 `isHidden`（真机树里同一个
/// `TouchPassthroughView` 一次是 `hidden`、一次不是 —— 取决于有没有在播放）。
/// 所以：
/// · 开关打开 → 藏，并**用关联对象记住"这一层是我藏的"**；
/// · 开关关掉 → 只撤回**我们**藏的那一次，Spotify 自己藏的一律不碰。
/// 第一版没有这条，结果是"关掉开关它也不回来"（用户以为坏了）—— 现在关掉即恢复。
///
/// ⚠️⚠️ 但"关掉即恢复"只在**下一次 layout 真的到来**时才成立。
/// 它并不可靠，见下面 `reconcile` 那一段的说明（迷你播放条没上报、加号按钮没生效，
/// 那边的表现是"迷你条消失且无法恢复"）。所以每个开关现在**两个时机**都跑：
/// 1. 目标类自己的 `layoutSubviews`（快路径，保持原样）；
/// 2. `MainWindow` 的节流复查 + 开关被手动切换 + App 回到前台（兜底，见 `reconcile`）。
var declutterHiddenByUsKey: UInt8 = 0

func wasHiddenByUs(_ view: UIView) -> Bool {
    (objc_getAssociatedObject(view, &declutterHiddenByUsKey) as? NSNumber)?.boolValue == true
}

func markHiddenByUs(_ view: UIView) {
    objc_setAssociatedObject(
        view,
        &declutterHiddenByUsKey,
        NSNumber(value: true),
        .OBJC_ASSOCIATION_RETAIN_NONATOMIC
    )
}

func clearHiddenByUs(_ view: UIView) {
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
    /// 真机证据：
    /// `22.CoverArtTiltView@15,0,335,335` ← 封面
    /// `22.LyricsContainerView@0,335,366,120` ← 就在封面正下方
    /// `23.LyricsView@0,0,366,120,id=singalong-lyrics-view`
    ///
    /// 默认**关**：过那一行本身不是问题（他反馈的是"逐词歌词开、更好的逐词歌词关"
    /// 时逐行歌词挂错地方，已修在 `InlineLyricsHostLocator`）。这个开关只留作选择。
    ///
    /// 它已并入「修改Spotify听歌页布局」总开关 ⇒
    /// 实际生效值 = `nowPlayingLayout && hideSingalongLine`（总开关拨动时会把下面那颗键
    /// 一起写成同一个值；这道 `&&` 是给外部写回兜底的）。
    static var hideSingalongLine: Bool {
        UserDefaults.nowPlayingAnyLayout && UserDefaults.hideSingalongLine
    }

    // MARK: - 首页 / 播放器那一批真机树实证）
    //
    // 首页顶部那条（问候语 + 筛选胶囊）。
    //
    // 证据：`HomeHeaderView@0,0,414,50`，只在**首页**的转储里出现，
    // 运行期类名 `_TtC19Home_FunkisPageImplP33_297EC57FD07AE9FCEAA7B66079FC278C14HomeHeaderView`。
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

    /// **「封面下单行歌词」这个开关 = 两层，各管一段。**
    ///
    /// ## 三代现场（用户给的，逐字）
    ///
    /// ## 现在为什么能成
    ///
    /// ```
    /// 13.Primary@0,0,104,32,id=lyrics-npv-switch-button                 ← 那颗胶囊（一直有 id！）
    /// 13.Primary@0,0,26,32,hidden,id=nowplaying-npv-musicvideos-switch  ← 旁边那颗
    /// ```
    /// ⇒ 第三层的 flag（`lyrics_under_cover_art_enabled=false`）**已经把功能从根上拿掉了**，
    /// 所以这一轮不必再"替用户按"，只剩两件**没有副作用**的事：
    ///
    /// | 层 | 做什么 | 在哪 | 生效时机 |
    /// | ① **内容层**：那一行视图 `hidden` | `applySingalongLine`（本文件） | ≤0.3s |
    /// | ② **根上层**：`lyrics_under_cover_art_enabled=false` | `Premium/DynamicPremium+ModifyingFunctions.swift` | 下次启动 |
    /// | ③ **chrome 层**：那两颗胶囊 `alpha = 0` | `applyNowPlayingPills`（本文件） | 出现即隐藏（事件 hook） |
    ///
    /// 上一轮那套"找胶囊 + 按胶囊"**整块删掉**，理由见本文件 `nowPlayingPillIdentifiers` 上面那段注释。
    static func applySingalongLine(_ singalong: UIView) {
        guard !singalong.isHidden else { return }
        singalong.isHidden = true
        markHiddenByUs(singalong)
        reportOnce(
            "singalongLineHidden",
            "hid the sing-along line itself (the feature itself is off through"
                + " lyrics_under_cover_art_enabled=false; see the flag replacement)"
        )
    }

    /// 关掉开关时写回那一行（旧机制可能给它写过 `hidden`）。
    /// ⚠️ 那两颗胶囊的写回在 `apply(wantVanished:to:)` 里（走 `vanishedPills` 那张表）。
    private static func restoreSingalongIfNeeded(_ view: UIView) {
        // 旧机制（藏视图）留下的痕迹也要清掉，否则升级上来的用户会一直看不到那一行。
        if wasHiddenByUs(view) {
            view.isHidden = false
            clearHiddenByUs(view)
            writeDebugLog("[Declutter] singalongLine restored")
        }
    }

    // MARK: -听歌页那排胶囊—— **按 id 找，不再猜**
    //
    // 两颗胶囊的**无障碍 id**：
    //
    // ```
    // 13.Primary@0,0,26,32,hidden,id=nowplaying-npv-musicvideos-switch   ← 「切换至视频」
    // 13.Primary@0,0,104,32,id=lyrics-npv-switch-button                  ← 「显示 / 隐藏歌词」
    // ```
    //
    // ## 为什么这次一定能找到（前两轮为什么白绕）
    //
    // 上一轮为了"找到那颗显示/隐藏歌词的胶囊"，先按类名子串 `ShowLyricsButton`，
    // 又按无障碍**标签**「显示歌词 / 隐藏歌词」搜整窗 8000 个节点。
    // 而它其实**一直带着 id**：`lyrics-npv-switch-button`。
    // ⇒ 仓库规矩第 4 条（判据落在 `accessibilityIdentifier` 上）不是教条，是**省掉两轮**的那句话。
    //
    // ## 为什么是"藏"而不是"按"
    //
    // 上一轮还想"替用户按下它"（为了让 Spotify 自己的单行歌词功能整体关掉）。
    // `singalong-lyrics-view` **一个都没有** ⇒ `lyrics_under_cover_art_enabled=false`
    // 那条 flag（第三次层次）已经把功能从根上拿掉了。于是"按"只剩坏处：
    // 它是**切换**（按两次 = 又开回来，独立复核抓过这个 blocker），而且会**落盘用户偏好**。
    // ⇒ 现在只做两件不产生副作用的事：**藏**（`alpha = 0`）与**写回**。
    //
    // ## 为什么用 `alpha` 不用 `hidden`
    //
    // 这两颗是 `Encore.Button.Primary`，挂在 Encore 的栈里；pw 的文档写得最直白
    // （pw 的结论）：*"Setting `hidden` on views inside
    // Spotify's `OverflowStackView` or its Encore stacks crashes, so use alpha."*
    private static let lyricsPillIdentifier = "lyrics-npv-switch-button"
    private static let videoPillIdentifier = "nowplaying-npv-musicvideos-switch"
    private static let nowPlayingPillIdentifiers = [lyricsPillIdentifier, videoPillIdentifier]

    /// 我们写成了 `alpha = 0` 的那几颗（写回时只认这张表里的）。
    private static let vanishedPills = NSHashTable<UIView>.weakObjects()

    /// 事件 hook 递进来的那两颗。
    ///
    /// ⚠️ **必须是 `weak`**：这是 Spotify 的视图，页面走了它们就该能释放
    /// （写死强引用会把它连同整棵子树留在内存里，而且我们还会继续往一个不在屏上的视图写 `alpha`）。
    /// ⚠️ **不能用"字典 + 边遍历边删"**（第一版就是这么写的，那是 Swift 的独占性违规）——
    /// 两个 id 就两个槽位，最省事也最安全。
    private static weak var lyricsPill: UIView?
    private static weak var videoPill: UIView?

    /// 它已并入「修改Spotify听歌页布局」总开关 ⇒
    /// 实际生效值 = `nowPlayingLayout && hideNowPlayingPills`（理由同上面那颗）。
    static var hideNowPlayingPills: Bool {
        UserDefaults.nowPlayingAnyLayout && UserDefaults.hideNowPlayingPills
    }

    /// 事件 hook 用：这颗 `Primary` 按钮带着我们关心的 id 吗？
    /// 命中就记下来并**当场**处理 —— 胶囊出现的那一帧就没了，不用等 0.3s 的复查节拍。
    static func notePillIfOurs(_ view: UIView) {
        // ⚠️ 用 `if id == 常量`，不用 `switch case 常量:` —— 后者在 Swift 里是"表达式模式"，
        // 细节（Optional 提升 / 会不会被当成绑定）不值得赌，而这里就两个 id。
        let id = view.accessibilityIdentifier
        guard id == lyricsPillIdentifier || id == videoPillIdentifier else { return }
        if id == lyricsPillIdentifier {
            lyricsPill = view
        } else {
            videoPill = view
        }
        apply(wantVanished: hideNowPlayingPills, to: view)
    }

    /// 复查节拍那一条：把记住的那两颗重新施加一遍（Spotify 会自己把 `alpha` 写回来）。
    /// 只在开关开着、且有已记住的引用时才写；**没有引用时不走查**（走查交给事件 hook）。
    static func reconcileNowPlayingPills() {
        for view in [lyricsPill, videoPill].compactMap({ $0 }) where view.window != nil {
            apply(wantVanished: hideNowPlayingPills, to: view)
        }
    }

    /// **从听歌页自己的子树里**把这两颗胶囊认下来。
    ///
    /// 为什么单开这一条：整窗那条（`resolvePillsIfNeeded`）会在**启动瞬间**就打掉唯一那次
    /// 6 node(s)` —— 那时 App 刚起来，窗口里只有 6 个节点），而之后**再也没有一行**
    /// 说明它到底找没找到 ⇒ 下一次日志仍然读不出结论。
    /// 页面子树只有几百个节点、一定够用，而且调用点在"我们正在这一页上"的时刻。
    ///
    /// 仍然自带 1s 节流（这条每 0.3s 跑一次），并且**只在有槽位空着时**才走查。
    private static let pagePillScanInterval: CFAbsoluteTime = 1.0
    private static var lastPagePillScanAt: CFAbsoluteTime = 0
    private static var reportedPagePillMiss = false

    static func adoptNowPlayingPills(from page: UIView) {
        guard hideNowPlayingPills, lyricsPill == nil || videoPill == nil else { return }

        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastPagePillScanAt >= pagePillScanInterval else { return }
        lastPagePillScanAt = now

        var found = 0
        var visited = 0
        var queue: [UIView] = [page]

        while !queue.isEmpty, visited < maxScanNodes {
            let view = queue.removeFirst()
            visited += 1
            if let id = view.accessibilityIdentifier, nowPlayingPillIdentifiers.contains(id) {
                notePillIfOurs(view)
                found += 1
            }
            queue.append(contentsOf: view.subviews)
        }

        guard found == 0 else {
            // 找到了就把"没找到"的账清掉，方便下一次换歌 / 换页面时再报。
            reportedPagePillMiss = false
            return
        }
        guard !reportedPagePillMiss else { return }
        reportedPagePillMiss = true
        writeDebugLog(
            "[Declutter] the player page has no pill with id "
                + nowPlayingPillIdentifiers.joined(separator: " / ")
                + " (visited \(visited) node(s) of that page)"
        )
    }

    /// 兜底发现（独立复核提的缺口）：万一**事件 hook 没跑到**（类被改名 / Orion 拒装 /
    /// id 是在某次布局之后才写上去的），那就按 id 在窗口里找一遍。
    ///
    /// 只在"开关开着 + 有槽位是空的 + 1s 节流到了"时才走 ⇒ 常态零成本；
    /// 预算**自己一份**（`lastPillScanAt`，不跟 `resolveIDTargets` 共用 —— 仓库规矩 5：
    /// 判据的预算按通道分）。找不到时打一行带节点数的日志，好让下一份日志能区分
    /// "没找到"与"根本没找"。
    private static let pillScanInterval: CFAbsoluteTime = 1.0
    private static var lastPillScanAt: CFAbsoluteTime = 0
    private static var reportedPillScanMiss = false

    private static func resolvePillsIfNeeded(in root: UIView) {
        guard hideNowPlayingPills, lyricsPill == nil || videoPill == nil else { return }

        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastPillScanAt >= pillScanInterval else { return }
        lastPillScanAt = now

        var found = 0
        var visited = 0
        var queue: [UIView] = [root]

        while !queue.isEmpty, visited < maxScanNodes {
            let view = queue.removeFirst()
            visited += 1
            if let id = view.accessibilityIdentifier, nowPlayingPillIdentifiers.contains(id) {
                notePillIfOurs(view)
                found += 1
            }
            queue.append(contentsOf: view.subviews)
        }

        guard found == 0, !reportedPillScanMiss else { return }
        reportedPillScanMiss = true
        writeDebugLog(
            "[Declutter] no Now Playing pill found by id in the window ("
                + nowPlayingPillIdentifiers.joined(separator: " / ")
                + ") — visited \(visited) node(s)"
        )
    }

    /// 藏 / 写回，两个方向都幂等。判据是"这颗是不是被我们写成 0 的"。
    ///
    /// ⚠️ 日志**不能只打第一次**（独立复核指出）：Spotify 每换一次播放内容就可能重建这两颗，
    /// 长得一样。所以改成"第一次 + 每 20 次"。
    private static var pillsHiddenCount = 0

    private static func apply(wantVanished: Bool, to view: UIView) {
        if wantVanished {
            guard view.alpha > 0.01 else { return }
            view.alpha = 0
            vanishedPills.add(view)
            pillsHiddenCount += 1
            guard pillsHiddenCount == 1 || pillsHiddenCount % 20 == 0 else { return }
            writeDebugLog(
                "[Declutter] hid the Now Playing pill row ("
                    + nowPlayingPillIdentifiers.joined(separator: " / ")
                    + ") — hide #\(pillsHiddenCount)"
            )
            return
        }
        guard vanishedPills.contains(view) else { return }
        view.alpha = 1
        vanishedPills.remove(view)
        writeDebugLog("[Declutter] the Now Playing pills are visible again")
    }

    // **"找那颗胶囊"这一整套已经删掉。**
    //
    // 删掉的是：类名子串 `ShowLyricsButton` 判据、无障碍标签表（「显示歌词 / 隐藏歌词」）、
    // 8000 节点的整窗走查、2s 节流 + 3 次上限、`PillLookup` 三态、以及"替用户按下它"。
    //
    // 为什么整块删：
    // ① **那颗胶囊一直有 id**：`lyrics-npv-switch-button`（`[NPVTree]` 逐字，104×32）。
    // 按类名/标签猜了两轮，一头都没中 —— 判据落在 `accessibilityIdentifier` 上就不必猜；
    // **一个都没有** ⇒ 第三层（`lyrics_under_cover_art_enabled=false`）已经把
    // "封面下单行歌词"整个功能拿掉了；
    // ③ 而"按"本身有害：它是**切换**（按两次 = 又开回来，独立复核抓过这条 blocker），
    // 还会落盘用户偏好。
    // ⇒ 现在只剩**不产生副作用**的两件事：把那一行藏起来（内容层）、把两颗胶囊 `alpha = 0`（chrome 层）。
    //
    // 藏 / 撤销，两个方向都幂等。
    //
    // 关键区别在"谁藏的"：`isHidden == true` 可能是 Spotify 自己写的（没在播放时
    // 迷你条本来就不显示）。所以撤销只针对被我们打过标的那些视图。
    //
    // ## ⚠️**这里曾经试过 `soft: true`（用 `alpha` 代替 `hidden`），已撤回**
    //
    // > 那个功能确实会隐藏单行歌词，但是**不会阻止封面上抬**。所以在用户的视角来看是：
    // > 这个单行歌词里面没有单行歌词滚过，但**把封面往上抬的功能没有阻止**。
    //
    // ⇒ 真正的问题是"**只藏了文字、没有撤销布局后果**"，而 `alpha` 恰好**把那一格留着**，
    // 等于把那个后果**保下来** —— 方向反了。所以回到 `hidden`（它至少让 Encore 重排一次），
    // 并且**默认值保持「关」**、不改这一块的行为。
    // **下一步必须先问清"开着的时候你到底想让封面去哪"，再动这里**（见交接文档 §13）。
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
    //
    // ⚠️ 为什么必须有它
    //
    // 原来只有"目标类自己的 `layoutSubviews`"一个时机，两个后果：
    //
    // · **迷你播放条**：启动时没在播放，Spotify 把 `TouchPassthroughView` 设成 `hidden`，
    // 我们的 `apply` 走 `guard !view.isHidden` 直接返回（不标记、不上报）。等 Spotify
    // 而整份日志**一行 `[Declutter]` 都没有**。
    // 那边的表现就是"迷你条消失且无法恢复"。
    //
    // · **加号按钮**：它只能从 `ConnectButtonView` 的兄弟里找，而那颗按钮**已经被我们藏了**，
    // 被藏的视图不再收 layout 回合 → 那次扫描实际只跑过启动一次。
    //
    // 所以换成**常驻可见的宿主**（`MainWindow`，`_TtC30ContainerUI_RootUIInternalImpl10MainWindow`，
    // 每份真机转储里都在、每次布局都跑）做节流复查，另外两个时机也强制跑：
    // · 开关被手动切换（设置页 → `reconcileNow`，关掉要**当场**还回来）；
    // · App 回到前台（`didBecomeActive`，正是"划出 Spotify 再回来"那一步）。
    //
    // 复查是幂等的：开关开着就确保藏起来，关着就只撤回**我们**藏过的那一次。
    //
    // 解析结果的缓存。全窗口扫描不便宜，所以结果留着；视图被换掉时 `weak` 自动失效，
    // 下一轮重扫即可。
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
                // 只剩"藏那一行"。功能本身由 flag（`lyrics_under_cover_art_enabled=false`）
                // 在下次启动时从根上关掉；那两颗胶囊由 `reconcileNowPlayingPills` 管。
                applySingalongLine(view)
            } else {
                restoreSingalongIfNeeded(view)
            }
        }

        // 听歌页那排胶囊。**事件 hook 负责"出现即隐藏"**，
        // 这里做两件事：①兜底发现（万一 hook 没跑到）；②把 Spotify 写回来的 `alpha` 再按住。
        resolvePillsIfNeeded(in: root)
        reconcileNowPlayingPills()
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

        // 迷你条那条胶囊的"封面色底"守卫（`MiniBarGlass.swift`）——
        // Spotify 会在我们清完之后**再写回**封面色，而那个写回**不一定**伴随宿主的
        // 布局回合。
        // 这里就是"看一眼 + 幂等清"（一次属性读），开关关着 / 没迷你条时零开销；
        // 它自己还有一轮 50ms 级的短促重试负责首帧。
        // ⚠️ 刻意**不新开定时器** —— 蹭的就是这个既有的节拍（0.5s，且非前台不跑）。
        onMainThreadSync { MiniBarGlassPlate.reconcileCoverColor() }

        // 夜：听歌页那层"封面取色底"的**换歌/滚动**自愈
        // （`NowPlayingBackdrop.reconcile`）。
        // **一直待在听歌页**，Spotify 那层底色自己从 `bg=#E84838` 变成 `bg=#584860`、
        // 高度 896 变 1682，而这期间**没有第三次 `[NPVStyle]`**（`apply` 只在
        // `viewWillAppear`/`viewDidAppear` 跑）⇒ 换歌、滚动之后我们的层必然失配。
        // 没在听歌页时它的成本 = 两次 weak 读 + 一次 `window` 读；
        // 在听歌页时再加**一次 `backgroundColor` 读**（换色那一刻才问 metadata）。
        // 同一条纪律：**不新开定时器**，蹭这个节拍。
        onMainThreadSync { _ = NowPlayingBackdrop.reconcile() }

        // 夜：听歌页「一屏」的**重算节拍**（`NowPlayingOneScreen.reconcile`）。
        // 卡片是列表建好之后**才陆续到**的，每来一张都会把内容高度顶上去，而 `apply`
        // 只在进页面时跑一遍；`willDisplayCell` 那一刻的高度更是"一个 runloop 之后才定"
        // （pw 为此专门补了一枪 async）。同一条纪律：**不新开定时器**，蹭这个节拍；
        // 值没漂就一个字节都不写，没在听歌页时只是两次 weak 读。
        onMainThreadSync { _ = NowPlayingOneScreen.reconcile() }

        // 听歌页「**我们自己的覆盖层**」（`NowPlayingPageOverlay`）也要跟着重排：
        // Spotify 换帧会重排 subviews 把我们挤下去，换歌 / 转场之后底部锚的 frame 也会变。
        // 同一条纪律：**不新开定时器**，frame 没变就一个字节都不写。
        onMainThreadSync { _ = NowPlayingPageOverlay.reconcile() }

        // 「歌词进播放器」那一层也要跟着重排 + 驱动时间轴。
        // 它的位置来自底部那一坨（卡片折叠/换歌都会动），时间轴**刻意**就用这个节拍
        // （约 0.3s 一拍，不新开 CADisplayLink —— 行间移动本身带 SwiftUI 动画，
        // 肉眼与每帧没差别）。没开开关时成本 = 一次 bool 读。
        onMainThreadSync { _ = NowPlayingLyricsPlate.reconcile() }

        // 「iOS 27 听歌页」的重算节拍。开关关着时成本 = 一次 bool 读。
        onMainThreadSync { _ = NowPlayingIOS27.reconcile() }

        // 「队列页」（Spotify 自己的队列卡片 → MeloX 形状）。
        // 开关关着 / 没弹卡片时成本 = 一次 bool 读 + 一次 presented 链检查。
        onMainThreadSync { _ = QueuePage.reconcile() }

        // 「控制键换成本地字形」的保活（Spotify 换帧会重排那一排的 subviews）。
        // 没开开关时成本 = 一次 bool 读。
        onMainThreadSync { _ = NowPlayingControlsPlate.reconcile() }

        // 夜：**只读播放器状态探针**（`PlayerStateProbe`）—— 给「突然无法播放
        // 任何歌曲」那条线补现场判据。
        // 它自己先看「启用日志记录」，开关关着 = 一眼都不看；只在**换曲 / 卡住 / 恢复**
        // 时打，所以不刷屏。同一条纪律：**不新开定时器**。
        onMainThreadSync { PlayerStateProbe.tick() }

        // ⛔「标签栏那一行的纵向复核」（`TabBarGlassPlate.reconcileRowIfTransient`）
        // 已随**自绘胶囊**一起删除：那套复核是给"把四颗摆到我们画的胶囊中心"
        // 服务的，胶囊没了就没人再动那几颗的 transform，也就没有什么"暂时不齐"要复核。
        //
        // 「标签栏改用系统玻璃」也在这条节拍上兜一次 ——
        // 它要同步 item / 选中态 / 让高度，而**关掉菜单或切歌之后这条栏不一定再布局**。
        // 开关关着时开销 = 一次 bool 读。
        onMainThreadSync { TabBarSystemGlass.reapply() }
    }

    // MARK: 目标登记
    //
    // 五个"有专属类名"的目标：由各自的 hook 在 `layoutSubviews` 里登记自己。
    //
    // ⚠️ 为什么不在这里按类名去找：`NSStringFromClass` 对 Swift 类返回什么形式
    // （`_TtC…` 混淆名，还是别的写法）依 Swift 版本而异，拿它跟 `targetName` 比字符串
    // 是一场不必要的赌注；而 **hook 手里已经有实例了**，让它顺手登记一下最稳。
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

        // App 回到前台时强制复查一次。的"划出 Spotify（不是杀掉）再回来，
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

    // 听歌页那排胶囊 —— 按**无障碍 id** 按住（出现即隐藏）。
    if NSClassFromString(NowPlayingPillHideHook.targetName) != nil {
        HideNowPlayingPillsGroup().activate()
    } else {
        writeDebugLog(
            "[Declutter] missing \(NowPlayingPillHideHook.targetName)"
                + " — the Now Playing pills (lyrics/video switch) cannot be hidden event-driven"
        )
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
            + " npvPills=\(DeclutterChrome.hideNowPlayingPills ? "ON" : "OFF")"
            + " homeHeader=\(DeclutterChrome.hideHomeHeader ? "ON" : "OFF")"
            + " connectButton=\(DeclutterChrome.hideConnectButton ? "ON" : "OFF")"
            + " addToButton=\(DeclutterChrome.hideAddToButton ? "ON" : "OFF"))"
    )
}
