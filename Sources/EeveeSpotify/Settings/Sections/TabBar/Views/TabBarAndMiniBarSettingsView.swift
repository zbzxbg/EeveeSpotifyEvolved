import SwiftUI
import UIKit

/// 「标签栏与迷你条」——底部标签栏那条玻璃 + 迷你播放条那条玻璃。
///
/// 拆页背景见 `NowPlayingSettingsView` 的文件头（用户 2026-10-13「设置页面有点乱了」，
/// 方案 B：把「扩展」那个 627 行的杂物袋按页面拆成四页）。
///
/// 两节：
///   · `tab_bar_glass_section` —— 藏文字 / 藏「创建」/ 改用系统玻璃；
///   · `mini_bar_glass_section` —— 迷你条玻璃（与上面那条同高同材质）。
///
/// ── 「迷你播放条那一族」五颗开关的分布（2026-10-14 登记族属，**不搬家**）──────────────
///
/// 这一族管的是同一条迷你播放条（以及它和播放器共用的那几颗控件），但五颗**分散在三页**：
///   · `hide_mini_player_bar`   —— **听歌页** `declutter_description` 那一节（藏整条）；
///   · `mini_bar_glass`         —— **本页**第二节（那条胶囊换玻璃）；
///   · `mini_bar_round_artwork` —— **本页**第二节（左边封面改圆形，**独立于**玻璃那颗）；
///   · `hide_connect_button`    —— **首页与音乐库页**第一节（藏设备/输出切换按钮 ——
///     它**迷你条与播放器共用**，所以是"所有传输条上都不显示"）；
///   · `hide_add_to_button`     —— 同一节（藏加号，与设备按钮同级）。
///
/// 分散**不是**因为功能分家，而是因为 l10n 里能用的分节标题只有那三个
/// （`mini_bar_glass_section` / `declutter_description` / `declutter_home_player_section`）。
/// 要真正归到一处，要么**跨页搬 Toggle**、要么**新造/合并分节标题**：前者会改掉用户找开关的
/// 路径、后者要动键，两样都不在这一批里（2026-10-14 用户批的是"说明 / 分区 / 注释"）。
/// ⇒ 本批**不动 Toggle 的位置**，只把族属与各自的落点写清楚。
struct TabBarAndMiniBarSettingsView: View {

    @State private var shadow = Shadow()

    private struct Shadow {
        var tabBarHideLabels = UserDefaults.tabBarHideLabels
        var tabBarHideCreate = UserDefaults.tabBarHideCreate
        var tabBarSystemGlass = UserDefaults.tabBarSystemGlass
        var miniBarGlass = UserDefaults.miniBarGlass
        var miniBarRoundArtwork = UserDefaults.miniBarRoundArtwork
    }

    var body: some View {
        List {
            // 底部标签栏：内容与玻璃都由「标签栏改用系统玻璃」那条路负责（见 TabBarSystemGlass）。
            //
            // ⛔「**标签用液态玻璃**」那颗开关（我们把整条栏铺一条自绘胶囊）已于 2026-10-13
            //   **按用户要求删除**（"这个功能可以删掉了"）：它整盘被系统玻璃那条路取代
            //   （iOS 26 自己画的玻璃有折射/镜片/明暗自适应，我们自绘的只是 UIVisualEffectView）。
            //   自绘那套代码同时从 `TabBarGlass.x.swift` 删掉；那个文件现在只剩
            //   **共用的几何判据 + 标签内容的取舍**（藏文字 / 藏「创建」）。
            Section(
                header: Text("tab_bar_glass_section".localized),
                footer: Text("tab_bar_glass_description".localized)
            ) {
                // 照片 21/23/25 里那条栏是**没有文字**的。
                // 来自 spoti.pw 的「Hide labels」（来源、许可与改动见「开源许可」页）。
                Toggle(
                    "tab_bar_hide_labels".localized,
                    isOn: settingsShadowBinding($shadow.tabBarHideLabels) { value in
                        // 与原「扩展」页逐字一致：只落盘（栏的下一次布局会读到它）。
                        // 不要在这里顺手加 `refreshCreateTabVisibility()` —— 那是行为改动，
                        // 这次拆页只搬位置、不改行为。
                        UserDefaults.tabBarHideLabels = value
                    }
                )

                // ★ 2026-10-13（用户）：「有个按键在音乐库的右边，叫创建歌单。能不能不要这个功能了。
                //   即液态玻璃只显示主页，搜索，音乐库三个按键」——**默认开**（就是他要的结果）。
                //   做法：**保住「创建」在 stack 里的槽位、只把内容藏起来**（`alpha = 0` + 点不到）
                //   ⇒ 那一块收不到点击（入口真没了），而玻璃/迷你条的**宽度不变**
                //   （用户第二条要求："关掉创建之后玻璃宽度不变"；`isHidden` 那种写法会让
                //   另外三颗平分整条栏，玻璃从 360 缩到 274）。
                //   关掉即恢复（原来的 `alpha` 与交互开关精确写回）。
                Toggle(
                    "tab_bar_hide_create".localized,
                    isOn: settingsShadowBinding($shadow.tabBarHideCreate) { value in
                        UserDefaults.tabBarHideCreate = value
                        // 栏的布局回合不常有 ⇒ 改完当场落地（下一次布局还会再走一遍）。
                        TabBarGlassPlate.refreshCreateTabVisibility()
                    }
                )

                // ⛔ 这里本来有一颗「拖动胶囊切换标签」（2026-10-13 当天加、当天删）：
                //   那个交互是**原生 iOS 26 标签栏自带的**（手指贴上玻璃就能横向滑，镜片立刻跟手、
                //   松手选中手指下那一颗 —— 见 `TabBarSystemGlass.x.swift` 第五片的两处外部来源），
                //   我们自己装 pan 是重复实现、还会把触摸从系统手里抢走 ⇒ 不该有这颗开关。

                // ★ 2026-10-12（用户看出 pw 那条栏"像果冻、还能滑"）：改用**系统 `UITabBar`** ——
                //   Spotify 的栏内容藏掉，上面叠一条系统栏 ⇒ iOS 26 自己画真·液态玻璃
                //   （选中气泡会滑、折射、明暗自适应）。
                //   ⚠️ 2026-10-13 起它是**唯一**一条玻璃的路：自绘那盘（"标签用液态玻璃"）已删除，
                //   "互斥"这件事自然不存在了；按住那条栏横滑跟手是 **iOS 26 系统栏自带的**，
                //   不用我们装手势（见 `TabBarSystemGlass.x.swift` 第五片）。
                Toggle(
                    "tab_bar_system_glass".localized,
                    isOn: settingsShadowBinding($shadow.tabBarSystemGlass) { value in
                        UserDefaults.tabBarSystemGlass = value
                        if value {
                            TabBarSystemGlass.reapply()
                        } else {
                            TabBarSystemGlass.remove(reason: "switch off")
                        }
                    }
                )
            }

            // 迷你播放条：用户 2026-10-02 点名要的（照片 33：那条实心封面色底太扎眼）。
            // 与上面那条**同高同材质**，宽度贴它自己的内容 —— 两条胶囊之间的间隙保持不动。
            //
            // 本节两颗是"迷你播放条那一族"的五分之二（完整清单见文件头）：
            //   · 两颗**互不影响** —— `mini_bar_round_artwork` 关掉玻璃也照样是圆的；
            //   · **两颗默认都开**（默认值在 `UserDefaults+Extension.swift` 的
            //     `miniBarGlass` / `miniBarRoundArtwork`，都是 `nil ⇒ true`）；
            //     想"回到 Spotify 原样"得各自关一次（或走下面那颗「重置本页」）。
            Section(
                header: Text("mini_bar_glass_section".localized),
                footer: Text("mini_bar_glass_description".localized)
            ) {
                Toggle(
                    "mini_bar_glass".localized,
                    isOn: settingsShadowBinding($shadow.miniBarGlass) { value in
                        UserDefaults.miniBarGlass = value
                        // 迷你条的布局回合不常有：改完当场落地（撤玻璃/还原底色都在这一句里）。
                        MiniBarGlassPlate.reconcileNow()
                    }
                )

                // ★ 2026-10-13（用户看 pw 的截图：「底下迷你播放器的歌曲是圆形的，不是方形的。
                //   我记得上游有这个东西」）：**上游确实有** —— `LiquidGlassOptions.roundArtwork`
                //   （设置行 `npb_round_artwork`，图标 `circle.fill`），实现就一行：
                //   `options.roundArtwork ? artwork.bounds.width / 2 : 12`（`GlassNowPlayingBar.x.swift:97`）。
                //   这里的做法、认图的结构判据与"原值写回"见 `Appearance/MiniBarArtwork.swift`。
                //   它**独立于上面那条玻璃开关**（关掉玻璃也照样是圆的）。
                Toggle(
                    "mini_bar_round_artwork".localized,
                    isOn: settingsShadowBinding($shadow.miniBarRoundArtwork) { value in
                        UserDefaults.miniBarRoundArtwork = value
                        // 当场落地：关掉要把圆角**原样写回**，不用等迷你条下一次布局。
                        MiniBarGlassPlate.reconcileNow()
                    }
                )
            }

            SettingsResetSection(
                keys: Self.ownedKeys,
                afterReset: {
                    shadow = Shadow()

                    // 顺序有讲究：先把内容取舍跑一遍（藏/放「创建」），再按当前值落地玻璃。
                    TabBarGlassPlate.refreshCreateTabVisibility()
                    if UserDefaults.tabBarSystemGlass {
                        TabBarSystemGlass.reapply()
                    } else {
                        TabBarSystemGlass.remove(reason: "reset this page")
                    }
                    MiniBarGlassPlate.reconcileNow()
                }
            )
        }
        .listStyle(InsetGroupedListStyle())
        .onAppear { shadow = Shadow() }
    }

    private static let ownedKeys = [
        "tabBarSystemGlass",
        "tabBarHideLabels",
        "tabBarHideCreate",
        "miniBarGlass",
        "miniBarRoundArtwork",
    ]
}
