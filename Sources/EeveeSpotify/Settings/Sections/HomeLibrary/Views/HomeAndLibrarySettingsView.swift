import SwiftUI
import UIKit

/// 「首页与音乐库」——首页 / 音乐库两页的"AM 化"（大标题贴左 + 收掉灰纱），
/// 外加首页与播放器上那几颗 Spotify 自己的 chrome 的藏与放。
///
/// 拆页背景见 `NowPlayingSettingsView` 的文件头。
///
/// ── ★ 2026-10-14 结构改动（用户拍板）────────────────────────────────────────────
/// · **首页头部三态化**：原来 `hide_home_header` 与 `home_large_title` 两颗 Toggle
///   同时开时会"静默让位"（用户看到两颗都开着、实际一颗不生效、灰纱还留着 —— 见下 ①）。
///   现在合成一个**三段选择器**：原样 / Apple Music 式 / 隐藏。**两个键都保留**、
///   **不写迁移**、**不新增任何 l10n 文案**（三个段标签复用现成键）。
/// · **两处「AM 式」并成一节**：原来它们是两个 Section（标题分别是 `library_section`
///   与 `home_section`，footer 在 zh-CN 里是同一句话）。现在并成**一节**、
///   标题 `home_and_library_title`，两颗子项与三态选择器都在里面。
///   代价是 `library_section` 这个 l10n 键暂时没有 UI 引用了（键保留、不删 —— 用户要求
///   本地化文件一个字不动）。这样"同一族的两次实现"在界面上终于挨在一起。
enum HomeHeaderStyle: Hashable {
    /// Spotify 原样（两颗都关）。
    case system
    /// 我们自绘的 AM 式页头（`homeLargeTitle == true`）。
    case amStyle
    /// 藏掉整个页头（`hideHomeHeader == true`）。
    case hidden
}

/// ⚠️ 中间那一节的标题是 `declutter_home_player_section`（"Home and player"）：三颗开关里
///    `hide_connect_button` / `hide_add_to_button` 其实管的是**听歌页**上那两颗键
///    （设备联动、收藏）。它们最初就是与 `hide_home_header` 一起加的，l10n 也只有这一个
///    分节标题可用 ⇒ 保持原样成组放在这里，不为了排版好看去拆散它们（拆了要么新造键、
///    要么让那两句已翻译的文案变成孤儿）。
///
/// ── 本页开关之间的关系（2026-10-14 复核：**只写说明，不改行为**）────────────────────
///
/// ① **首页那两颗"打架"，而且是静默让位**：`hide_home_header`（第一节、默认**关**）打开后
///    **接管整个页头**，`home_large_title`（第三节、默认**开**）随即让位 ——
///    `Appearance/HomeHeaderAppearance.x.swift` 的 `apply` 里那句
///    `guard !UserDefaults.hideHomeHeader` 直接 `return`（只在日志里说一次 `standing down`），
///    共享的存储一个字节都不写。用户两颗都开时看到的是**"顶部条没了"**，
///    而不是"AM 式大标题"。⚠️ 还有个真机复核过的细节：那句 `return` 在
///    `layout(...)` 里的 `clearScrim(...)` **之前** ⇒ **灰纱也不收**；而灰纱不在
///    `DeclutterChrome` 藏的那颗 `HomeHeaderView` 里（它是**同级兄弟**，见 `DeclutterChrome.x.swift:81-92`
///    与 `HomeHeaderAppearance.x.swift` 文件头）⇒ "顶部条没了、灰纱还在"是当前的实现结果，不是 bug。
///    这两句本该写在两颗的 footer 里，但 footer 是 l10n（`declutter_home_player_description` /
///    `home_large_title_description`），用户明确要求 `layout/**` 一个字都不动 ⇒ 写在这里。
///
/// ② **`home_large_title` 与 `library_large_title` 是同一套 AM 化的两次实现，不是一颗开关**：
///    前者在 `HomeHeaderAppearance.x.swift`（首页，头部随滚动动 ⇒ 挂在页面 VC 上），
///    后者在 `LibraryAppearance.x.swift`（音乐库，头部静止 + 0.5s 复查节拍）。**各管一页、互不影响**
///    （两颗都默认开）。两节的 footer 在 zh-CN 里是**同一句**「效果可能不明显。」——
///    那句是 l10n、不能动 ⇒ "它们是一组"这件事同样只能写在这里。
///    两节在**本页里已经相邻**（音乐库 → 主页），所以"排到一起"这一条**不需要改代码**；
///    真要并成同一个 Section 就得扔掉 `library_section` / `home_section` 两个已翻译标题里的一个，
///    那是结构批，本批不做。
///
/// ③ `home_tile_tint` 的"要不要重启"见第四节上面的那段注释（**启动时为"关"的那种情况，
///    关→开必须重启**；默认值是开，所以多数人察觉不到这一条）。
struct HomeAndLibrarySettingsView: View {

    @State private var shadow = Shadow()

    private struct Shadow {
        var hideHomeHeader = UserDefaults.hideHomeHeader
        var hideConnectButton = UserDefaults.hideConnectButton
        var hideAddToButton = UserDefaults.hideAddToButton
        var libraryLargeTitle = UserDefaults.libraryLargeTitle
        var homeLargeTitle = UserDefaults.homeLargeTitle
        var homeTileTint = UserDefaults.homeTileTint

        /// 首页头部三态 —— **派生值**，不落盘（真值仍是上面两个键）。
        ///
        /// ⚠️ 这是本页唯一一处"两个键映到一个 UI 控件"的地方，所以它**不参与 `settingsShadowBinding`**
        ///    （那套是"一进一出"的）：读走 `homeHeaderStyle`、写走下面 `homeHeaderStyleBinding` 的 set。
        var homeHeaderStyle: HomeHeaderStyle {
            if hideHomeHeader { return .hidden }
            return homeLargeTitle ? .amStyle : .system
        }
    }

    /// 三态选择器的绑定：读 = 派生态；写 = **落到两个既有键**上（见 `Shadow.homeHeaderStyle` 的说明）。
    ///
    /// ⚠️ 落盘与副作用**必须写在这里**，不能写成 `.onChange(of: shadow.homeHeaderStyle)` ——
    ///    那是**派生**属性（`hideHomeHeader` / `homeLargeTitle` 算出来的），`onChange` 观察不到它。
    ///
    /// ⚠️ 为什么 `shadow` 与 `UserDefaults` 都要写：`Picker` 的段选中态由 SwiftUI 按 `selection`
    ///    求值决定，而"写 UserDefaults 不会让 SwiftUI 失效重绘"是本仓库踩过的坑
    ///    （见 `SettingsShadowBinding.swift` 文件头）—— 所以两者都要写。
    private var homeHeaderStyleBinding: Binding<HomeHeaderStyle> {
        Binding(
            get: { shadow.homeHeaderStyle },
            set: { style in
                switch style {
                case .system:
                    shadow.homeLargeTitle = false
                    shadow.hideHomeHeader = false
                    UserDefaults.homeLargeTitle = false
                    UserDefaults.hideHomeHeader = false
                case .amStyle:
                    shadow.homeLargeTitle = true
                    shadow.hideHomeHeader = false
                    UserDefaults.homeLargeTitle = true
                    UserDefaults.hideHomeHeader = false
                case .hidden:
                    shadow.hideHomeHeader = true
                    UserDefaults.hideHomeHeader = true
                    // `homeLargeTitle` 的值在"隐藏"态下**被忽略**（见文件头），刻意不动它 ——
                    // 用户从"隐藏"切回"AM 式/原样"时再由上面两个分支写准。
                }

                // 藏过的 chrome 不一定再有 layout 回合 ⇒ 当场复查一遍（见 `DeclutterChrome`）。
                DeclutterChrome.reconcileNow()
                // ⚠️ AM 式那半边**不在这里补推**：它的入口是 `HomeHeaderAppearance.apply(to:)`，
                //    需要一个**页面对象**，而设置页手上没有（硬凑会写错页面）。它靠首页自己的
                //    `viewDidLayoutSubviews` 那一拍落地 —— 关掉设置页回到首页时必然发生。
                //    "隐藏 ↔ AM 式"因此可能有一拍延迟，这是刻意的：宁可晚半拍，不猜页面。
            }
        )
    }

    var body: some View {
        List {
            // 「迷你播放条那一族」共五颗，**散布在三页**（清单与分布见
            // `Settings/Sections/TabBar/Views/TabBarAndMiniBarSettingsView.swift` 文件头）——
            // 本页占两颗（`hide_connect_button` / `hide_add_to_button`），它们管的是
            // **迷你条与播放器传输条共用的**设备按钮与加号。
            // 2026-10-14 拍板：**不搬家**（移动 Toggle 会改掉用户找开关的路径），只把族属写清。
            Section(
                // ⚠️ 这一节**故意不带 header**：`declutter_home_player_section` 这个键现在给下面那颗
                //    三态选择器当**标签**用了（分段控件必须有个标签，否则一列片段看不出在选什么）。
                //    同一键既当分节标题又当控件标签会在一屏里重复出现两次 ⇒ 去掉 header。
                //    这一节的分组语义由那行标签（"首页与播放器"）+ 下面的 footer 承担。
                footer: Text("declutter_home_player_description".localized)
            ) {
                // ── ★ 2026-10-14（用户拍板）：首页头部**三态化**，替掉原来那两颗互相打架的 Toggle ──
                //    原来：`hide_home_header`（藏整个页头）与 `home_large_title`（自绘 AM 式页头）
                //    各是一颗，同时开时后者**静默让位**（见文件头 ①）⇒ 用户看到两颗都"开着"、
                //    实际一颗不生效，而且灰纱还会留着（让位那句 return 在 `clearScrim` 之前）。
                //    现在合成一个三态选择，**两个键都保留**（存储语义不变、老值继续有效、不写迁移）：
                //        · 原样     = `homeLargeTitle == false && hideHomeHeader == false`
                //        · AM 式    = `homeLargeTitle == true  && hideHomeHeader == false`
                //        · 隐藏     = `hideHomeHeader == true`（此时 `homeLargeTitle` 的值**被忽略**）
                //    ⚠️ 第四象限（`homeLargeTitle == false && hideHomeHeader == true`）是可能存在的
                //       历史值 —— 它归入「隐藏」；用户一旦再选「原样」/「AM 式」，`hideHomeHeader`
                //       就会被写回 false，从此三态与键一一对应。
                //    ⚠️ 三个段标签**全部复用现成 l10n 键**，没有新增任何文案
                //       （`home_section` 原本正是被合并进下面那节的标题）：
                //         原样 = `home_section`（"主页"）、AM 式 = `home_large_title`、隐藏 = `hide_home_header`。
                //    ⚠️ 选择器自己的**标签也是复用**的（`declutter_home_player_section` = "首页与播放器"）：
                //       分段控件必须有个标签，否则一列片段看不出在选什么。这个键原先正是**本节的分节标题**
                //       （所以它名副其实），现在让它只当控件标签、Section 不带 header
                //       —— 否则同一个字符串会在一屏里出现两次。
                Picker(
                    "declutter_home_player_section".localized,
                    selection: homeHeaderStyleBinding
                ) {
                    Text("home_section".localized).tag(HomeHeaderStyle.system)
                    Text("home_large_title".localized).tag(HomeHeaderStyle.amStyle)
                    Text("hide_home_header".localized).tag(HomeHeaderStyle.hidden)
                }
                .pickerStyle(.segmented)
                // ⚠️ 这里**故意没有 `.onChange`**：落盘与副作用都写在 `homeHeaderStyleBinding` 的
                //    set 里。写成 `.onChange(of: shadow.homeHeaderStyle)` 是无效的 ——
                //    那是**派生**属性（由 `hideHomeHeader` / `homeLargeTitle` 算出来），观察不到。

                // ⚠️ `hide_connect_button` / `hide_add_to_button` 是**有意保留的例外**：
                //    `Tweak.x.swift:425` 写死的"按钮类（shuffle/repeat/addTo/queue/share/connect）
                //    **故意不做** —— 藏了功能就没了"说的是**卡片类清爽**那条路
                //    （`activatePlayerCardsDeclutter()` 只折卡片，不碰按钮）。这两颗走的是另一条路
                //    （`DeclutterChrome`：设备按钮 `Components.ConnectButtonOutputSwitcher`、
                //    加号 `Components.UI.AddToButton`，`DeclutterChrome.x.swift:81-92`）；
                //    它们**默认关**（`UserDefaults.hideConnectButton` / `hideAddToButton`），
                //    用户自己开才算数 ⇒ 保留 UI、不删键，只把这条政策边界写清楚。
                //    （顺带一笔：zh-CN 显示名是「隐藏喜欢按钮」，而代码认的是**加号**
                //      `Components.UI.AddToButton`；名字差异只记在这里，l10n 键不动。）
                Toggle(
                    "hide_connect_button".localized,
                    isOn: settingsShadowBinding($shadow.hideConnectButton) { value in
                        UserDefaults.hideConnectButton = value
                        DeclutterChrome.reconcileNow()
                    }
                )

                Toggle(
                    "hide_add_to_button".localized,
                    isOn: settingsShadowBinding($shadow.hideAddToButton) { value in
                        UserDefaults.hideAddToButton = value
                        DeclutterChrome.reconcileNow()
                    }
                )
            }

            // ── ★ 2026-10-14（用户拍板）：两处「AM 式」**并成一节** ──────────────────────
            //    原来它们是**两个 Section**（标题分别是 `library_section` 与 `home_section`，
            //    两句 footer 在 zh-CN 里还是**同一句话**）—— 用户看到的是"两个地方各有一颗、
            //    看不出是一组"。现在并成一节、标题用现成的 `home_and_library_title`（"首页与音乐库"），
            //    这正是根页那一行的副标题，语义比原来的两个分节标题更准。
            //    ⚠️ 代价：`library_section` 这个 l10n 键**暂时没有 UI 引用了**（键保留、不删 ——
            //       用户要求 `layout/**` 一个字不动；将来若要还原分节，直接把它加回 header 即可）。
            //    ⚠️ 两节的 footer 也不同（`library_large_title_description` /
            //       `home_large_title_description`），而一个 Section 只有一条 footer ⇒
            //       这里**只保留音乐库那条**（它对应"一颗管七件事"的复杂那半），主页那句
            //       由下面那颗自己的注释承担。若哪天要两句都露，得新造一个合并键。
            Section(
                header: Text("home_and_library_title".localized),
                footer: Text("library_large_title_description".localized)
            ) {
                // 音乐库：**改原生**的第一批（不是加壳）—— 大标题左对齐 + 收掉顶部渐隐灰纱。
                //
                // ★ 这一颗 `library_large_title` **一颗管三片、七件事**（闸门只有
                //   `LibraryAppearance.isEnabled` 一处，另外两片直接读它：
                //   `LibraryRowsAppearance.x.swift:51-52`、`LibrarySearchAppearance.x.swift:34-35`，
                //   关掉各自精确还原）：
                //     ① 标题字号 ×1.25、上限 40pt（`LibraryAppearance.x.swift:224-228`）；
                //     ② 标题挪到左沿 16pt（用 transform 位移，**不改** `textAlignment` —— 改过，等于没改）
                //        `LibraryAppearance.x.swift:305-310`；
                //     ③ 头像 + recents/search/plus 三颗按钮一起贴右沿打包、头像最右
                //        `LibraryAppearance.x.swift:312-329`；
                //     ④ 顶部灰纱 alpha 归零（只在自己那一拍写、不进 0.5s 节拍）
                //        `LibraryAppearance.x.swift:367-383`；
                //     ⑤ **右侧那条"快速滚动条"整条从父视图里拿走**（不是 alpha=0；连"可拖动"一起关掉，
                //        关开关时按原位放回）`LibraryAppearance.x.swift:423-455`；
                //     ⑥ 列表行/网格封面连续圆角 + 行内发丝线 `LibraryRowsAppearance.x.swift:93-100`；
                //     ⑦ 库内搜索的搜索框与 Cancel 变胶囊 + 同一份灰纱判据
                //        `LibrarySearchAppearance.x.swift:59-77`。
                //   这七件事**没有各自的开关**（2026-10-14 拍板：不动结构，只把说明写清）；
                //   "拆成两颗"这件事**已勘察但本轮主动推迟**（原因：`LibraryAppearance` 597 行 +
                //   两条独立还原路径，必须可编译 + 真机验证才敢动），详见
                //   `.handoffs/AUDIT_2026-10-14_FIXES.md`。
                Toggle(
                    "library_large_title".localized,
                    isOn: settingsShadowBinding($shadow.libraryLargeTitle) { value in
                        UserDefaults.libraryLargeTitle = value
                    }
                )

                // 主页：与音乐库**同一套"AM 化"**（大标题贴左 + 头像靠右 + 收 pills 与灰纱），
                // 但那一页的头**随滚动动**，所以实现挂在页面 VC 上（见 `HomeHeaderAppearance` 文件头）。
                //
                // ⚠️ 与上面那颗是**同一族的两次实现、各管一页**（键、实现文件、生效页面全都不一样，
                //    别当成同一颗开关的两种叫法）；两颗**都默认开**。
                // ⚠️ 本项在**上面那个三态选择器选中「隐藏」时不生效**（静默让位 —— 见文件头 ①）。
                //    三态选择器写的是同一批键（`homeLargeTitle` / `hideHomeHeader`），所以这里必须
                //    **互斥置灰**：否则用户在"隐藏"态下把这颗打开，会得到一个"开着但不生效"的开关
                //    ——正是本次要根治的那种困惑（`.disabled` 只关 UI，键与行为都不变）。
                Toggle(
                    "home_large_title".localized,
                    isOn: settingsShadowBinding($shadow.homeLargeTitle) { value in
                        UserDefaults.homeLargeTitle = value
                    }
                )
                .disabled(shadow.hideHomeHeader)

                // ⚠️ 合并成节之后，主页那颗的 footer（`home_large_title_description`）**没有地方显示**了
                //    —— 一个 Section 只有一条 footer，而那条给了音乐库那句（见本节抬头）。
                //    这里用该键补一行小字，让"这颗是干什么的"不丢，同时该键不变成死键。
                Text("home_large_title_description".localized)
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }

            // ★ 2026-10-13（用户看 pw 的截图：「那几个小模块是经过处理的（喜欢的歌曲那几个小方框），
            //   底部的颜色会跟着封面的样子跑」）：把那排小卡片的底色改成**从它自己的封面取色**
            //   （普通 Spotify 那边这几格是一片灰）。出处 spoti.pw **v0.21.1** 的
            //   `Redesigned/Home/HomeTiles.m`（GPL-3.0）："a dark surface tinted faintly towards
            //   the cover's dominant colour"。做法、认形状的判据与"为什么这次是靠日志而不是转储"
            //   见 `Appearance/HomeShortcutTiles.x.swift` 文件头。
            // ⚠️ 生效时机（2026-10-14 复核；原来那句只说对了一半，已改写）：
            //   · **关 → 开：要看"启动时它是开着还是关着"。** 钩子是**启动时按当时的值**决定装不装的
            //     —— `Tweak.x.swift:447` 调 `activateHomeShortcutTiles()`，里面第一句就是
            //     `guard HomeTileTint.launchEnabled else { return }`（`HomeShortcutTiles.x.swift` 文末），
            //     而 `HomeShortcutTilesGroup().activate()` 只在那一次跑。
            //     ⇒ 启动时是**关**的：这一场整个 hook group 都不在，之后再怎么翻都收不到那些布局
            //       回合，**必须重启**；启动时是**开**的（这颗**默认就是开**）：后来关掉再开回来
            //       **不用**重启 —— 钩子一直在。
            //   · **开 → 关：钩子还在，但每一拍都提前返回**（`apply` / `applyToCard` /
            //     `applyToGrid` 三处 `guard isEnabled`）⇒ 新出现/被复用的卡片不再上色、封面也不再
            //     内缩。**已经上过色的那几格不会当场还原** —— 这条路没有 restore，
            //     要等卡片自己重建。所以"不需要当场落地"这个说法只描述了"值会被读到"，
            //     没提"钩子根本没装"这一层。
            //   ⇒ ★ 2026-10-14（用户批准：「改」）：**现在露出重启提示了** ——
            //     给 `HomeTileTint` 补了一个**真正的启动快照** `launchEnabled`
            //     （`HomeShortcutTiles.x.swift`，`static let` 惰性求值 + 启动那次 `activate` 先读它，
            //     所以拿到的是启动值）；判据因此与 `RestartSection` 的契约一致：
            //        可见 = 当前值 ≠ 启动值
            //     这正好命中唯一需要重启的分支（**启动时是关的、现在被打开了**），
            //     而不是"只要开着就显示"（那是它的文件头点名禁止的写法）。
            //   ⇒ 用户可见的 footer 一个字都没加（`home_tile_tint_description` 仍是原 l10n），
            //     重启提示走的是**按钮行**（`restart_now`），与「杂项」页那颗评分拦截同款。
            Section(
                header: Text("home_tile_tint_section".localized),
                footer: Text("home_tile_tint_description".localized)
            ) {
                Toggle(
                    "home_tile_tint".localized,
                    isOn: settingsShadowBinding($shadow.homeTileTint) { value in
                        // ⚠️ 见上面那段：**只有"启动时是关的"那种情况**，关→开才需要重启；
                        //    开→关当场就不再上色，但已上色的格子要等重建才回原样。
                        UserDefaults.homeTileTint = value
                    }
                )
            }

            // 「立即重启」：只在**当前值 ≠ 启动快照**时出现 —— 也就是"启动时是关的、现在打开了"
            // 那一种（见上面那段）。默认开的人永远不会看到这一行。
            RestartSection(visible: UserDefaults.homeTileTint != HomeTileTint.launchEnabled)

            SettingsResetSection(
                keys: Self.ownedKeys,
                afterReset: {
                    shadow = Shadow()
                    // 大标题那两颗是"下一次布局生效"（原页也没有当场落地），
                    // 需要当场复查的只有 `DeclutterChrome` 管的那几颗（含三态选择器里的"隐藏"）。
                    //
                    // ⚠️ 本页现在**有** `RestartSection` 了（`home_tile_tint` 那颗，2026-10-14 加），
                    //    但它不进 `ownedKeys`、也不改「重置本页」的作用面 —— 它只是读一下
                    //    `HomeTileTint.launchEnabled` 与当前值。
                    //    （一个已知边角：`home_tile_tint` 被重置后回到默认的**开**，若这一场启动时
                    //      它是关的，那么 `homeTileTint != launchEnabled` 成立 ⇒ 重启提示会现身，
                    //      这正是我们想要的提示。）
                    DeclutterChrome.reconcileNow()
                }
            )
        }
        .listStyle(InsetGroupedListStyle())
        .onAppear { shadow = Shadow() }
    }

    private static let ownedKeys = [
        "hideHomeHeader",
        "hideConnectButton",
        "hideAddToButton",
        "libraryLargeTitle",
        "homeLargeTitle",
        "homeTileTint",
    ]
}
