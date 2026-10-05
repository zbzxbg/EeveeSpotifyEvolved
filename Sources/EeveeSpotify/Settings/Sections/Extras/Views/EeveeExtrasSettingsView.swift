import SwiftUI
import UIKit

/// 「扩展功能」—— 后加的这批（来路见「开源许可」页）集中在一页。
///
/// 为什么这样放：EeveeSpotify 根页原来因为每加一个功能就多一行，涨到了 18 行——
/// 用户反馈"页面臃肿"。spoti.pw 的结构正好相反：**根页只放分类，功能各进自己的页**。
/// 这里照同样的做法，根页只多一行。
///
/// 里面四项：深色栏底色（`amoled`，就地开关）、隐私与上报、触感、Flag 覆盖。
/// 深色栏刻意**不**做成子页——它只有一个开关，为它单开一页反而是另一种臃肿。
struct EeveeExtrasSettingsView: View {

    let navigationController: UINavigationController

    /// 本页所有开关与选择的**影子值**。理由见 `Shadow`。
    @State private var shadow = Shadow()

    /// ⚠️ 为什么每个控件都要一个本地影子值（2026-10-01 用户报的 bug）
    ///
    /// 原来每个控件直接绑一个**读 UserDefaults 的临时 Binding**：
    /// `Binding(get: { UserDefaults.xxx }, set: { UserDefaults.xxx = $0 })`。
    /// 写 `UserDefaults` **不会**让 SwiftUI 失效重绘 ——
    ///   · `Toggle` 自己会重绘，所以看不出问题；
    ///   · `Picker` 的标签是**父视图求值**出来的，于是「双击手势 → 动作」选完仍显示旧值，
    ///     要等页面被重建（重启 Spotify）才更新。用户报的正是这一条。
    ///
    /// 对照本仓库里没这个毛病的两页：`SponsorBlockSettingsView` 用 `@State options`、
    /// Flag 覆盖页用 `@State newMode` —— 它们先改本地状态（触发重绘）再落盘。
    /// 这里照同一套做法：`set` 里**先改影子值，再写 UserDefaults**。
    private struct Shadow {
        var hideMiniPlayerBar = UserDefaults.hideMiniPlayerBar
        var hideSingalongLine = UserDefaults.hideSingalongLine
        var hideNowPlayingPills = UserDefaults.hideNowPlayingPills
        var hideHomeHeader = UserDefaults.hideHomeHeader
        var hideConnectButton = UserDefaults.hideConnectButton
        var hideAddToButton = UserDefaults.hideAddToButton

        var libraryLargeTitle = UserDefaults.libraryLargeTitle
        var homeLargeTitle = UserDefaults.homeLargeTitle
        var tabBarSystemGlass = UserDefaults.tabBarSystemGlass
        var tabBarHideLabels = UserDefaults.tabBarHideLabels
        var tabBarHideCreate = UserDefaults.tabBarHideCreate
        var miniBarGlass = UserDefaults.miniBarGlass
        // ★ 2026-10-13：歌单封面的「四宫格 → 单张」（第 5 轮那个问题）。
        // ★ 2026-10-13：专辑页 / 歌单页的 AM 化（取色底 + 封面下缘溶解）。
        var entityPageField = UserDefaults.entityPageField
        var entityPageDissolve = UserDefaults.entityPageDissolve
        var nowPlayingBackdrop = UserDefaults.nowPlayingBackdrop
        var nowPlayingOneScreen = UserDefaults.nowPlayingOneScreen
        var nowPlayingVolume = UserDefaults.nowPlayingVolume
        var nowPlayingLyricsInPlayer = UserDefaults.nowPlayingLyricsInPlayer
        var nowPlayingSingleLyric = UserDefaults.nowPlayingSingleLyric
        // ★ 2026-10-12（用户）：下面这两颗是**歌词那两档的总开关**（见 `body` 里那一段），
        //   读的是**同一批 UserDefaults 键** ⇒ 与 设置 → 歌词 里那几颗两面同步。
        var showRomanizedLyrics = NgzhwmSettingsViewModel.anyRomanizationEnabled
        var showLyricsTranslation = !NgzhwmSettingsViewModel.isNeteaseHideTranslationEnabled
        var nowPlayingBlurUnplayedLyrics = UserDefaults.nowPlayingBlurUnplayedLyrics
        var nowPlayingControlGlyphs = UserDefaults.nowPlayingControlGlyphs
    }

    var body: some View {
        List {
            // ⛔「深色栏底色」(AMOLED) 已于 2026-10-02 删除：
            // 新设计语言下它每次布局都主动让位，是个纯空操作（见 `Tweak.x.swift` 里那段说明）。

            Section(footer: Text("declutter_description".localized)) {
                Toggle(
                    "hide_mini_player_bar".localized,
                    isOn: declutterBinding(
                        \.hideMiniPlayerBar,
                        persist: { UserDefaults.hideMiniPlayerBar = $0 }
                    )
                )

                Toggle(
                    "hide_singalong_line".localized,
                    isOn: declutterBinding(
                        \.hideSingalongLine,
                        persist: { UserDefaults.hideSingalongLine = $0 }
                    )
                )

                // ★ 2026-10-10（照片 63）：听歌页那排胶囊（「切换至视频」+「显示 / 隐藏歌词」）。
                //   判据是**无障碍 id**（日志 54 的 `[NPVTree]`）：`lyrics-npv-switch-button` /
                //   `nowplaying-npv-musicvideos-switch`；关掉开关即当场写回 `alpha`。
                Toggle(
                    "hide_npv_pills".localized,
                    isOn: declutterBinding(
                        \.hideNowPlayingPills,
                        persist: { UserDefaults.hideNowPlayingPills = $0 }
                    )
                )
            }

            Section(
                header: Text("declutter_home_player_section".localized),
                footer: Text("declutter_home_player_description".localized)
            ) {
                Toggle(
                    "hide_home_header".localized,
                    isOn: declutterBinding(
                        \.hideHomeHeader,
                        persist: { UserDefaults.hideHomeHeader = $0 }
                    )
                )

                Toggle(
                    "hide_connect_button".localized,
                    isOn: declutterBinding(
                        \.hideConnectButton,
                        persist: { UserDefaults.hideConnectButton = $0 }
                    )
                )

                Toggle(
                    "hide_add_to_button".localized,
                    isOn: declutterBinding(
                        \.hideAddToButton,
                        persist: { UserDefaults.hideAddToButton = $0 }
                    )
                )
            }

            // ⛔「双击手势」整节已于 2026-10-04 删除（用户拍板：先删掉，之后再搞）。
            //   它不是"坏了"才删：切歌那条路日志 8/17 证明能用；删是因为 ——
            //   ① 手势挂在页面根视图上，**在播放键上方双击也会跳歌**（本该是播放/暂停）；
            //   ② 最该起作用的全屏歌词那一面默认关、从没验过；
            //   ③ 最近 8 份日志里它一次都没被用过。
            //   重做时的三条要求（控件上不认 / 单击让位 / 另选挂点）见
            //   `Tools/eevee-hookfinder/SESSION_2026-10-03_NIGHT.md` §10。

            // ⛔ 听歌页那一整节（自绘壳 / 自绘顶栏 / 顶栏玻璃）已于 2026-10-02 **整节删除**：
            // 那几版 bug 太多（糊底、两颗 ⌄、与原生吸顶头打架……），先放一边，
            // 等导航栏这条线收干净再重做。

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
                    isOn: shadowBinding(
                        \.tabBarHideLabels,
                        persist: { UserDefaults.tabBarHideLabels = $0 }
                    )
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
                    isOn: shadowBinding(
                        \.tabBarHideCreate,
                        persist: { value in
                            UserDefaults.tabBarHideCreate = value
                            // 栏的布局回合不常有 ⇒ 改完当场落地（下一次布局还会再走一遍）。
                            TabBarGlassPlate.refreshCreateTabVisibility()
                        }
                    )
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
                    isOn: shadowBinding(
                        \.tabBarSystemGlass,
                        persist: { value in
                            UserDefaults.tabBarSystemGlass = value
                            if value {
                                TabBarSystemGlass.reapply()
                            } else {
                                TabBarSystemGlass.remove(reason: "switch off")
                            }
                        }
                    )
                )
            }

            // 迷你播放条：用户 2026-10-02 点名要的（照片 33：那条实心封面色底太扎眼）。
            // 与上面那条**同高同材质**，宽度贴它自己的内容 —— 两条胶囊之间的间隙保持不动。
            Section(
                header: Text("mini_bar_glass_section".localized),
                footer: Text("mini_bar_glass_description".localized)
            ) {
                Toggle(
                    "mini_bar_glass".localized,
                    isOn: shadowBinding(
                        \.miniBarGlass,
                        persist: { value in
                            UserDefaults.miniBarGlass = value
                            // 迷你条的布局回合不常有：改完当场落地（撤玻璃/还原底色都在这一句里）。
                            MiniBarGlassPlate.reconcileNow()
                        }
                    )
                )
            }

            // 听歌页（NPV）：仿 Apple Music 的**整页取色渐变底**。
            // 借鉴来源与"为什么不模糊"写在 `NowPlayingBackdrop` 的文件头。
            Section(
                header: Text("now_playing_section".localized),
                footer: Text("now_playing_section_description".localized)
            ) {
                Toggle(
                    "now_playing_backdrop".localized,
                    isOn: shadowBinding(
                        \.nowPlayingBackdrop,
                        persist: { value in
                            UserDefaults.nowPlayingBackdrop = value
                            // 关掉要**当场**还原（不用等下一次进听歌页）；
                            // 打开就顺手刷一次，用户可以在听歌页里立刻看到。
                            if value {
                                refreshNowPlayingBackdrop()
                            } else {
                                NowPlayingBackdrop.remove(reason: "switch off")
                            }
                        }
                    )
                )

                // 一屏：把播放器下面那些卡片折起来 + 把列表钉在它的顶部
                // （kumone / Music app 那种"一屏一首歌、滚不动"）。
                // 思路与算法借自 spoti.pw v0.21.1（GPL-3.0），写在 `NowPlayingOneScreen` 文件头。
                // ★ 2026-10-12（用户问「那个一屏的介绍换成什么了来着」）：那段说明原本挂在
                //   分区的 footer 上，分区改成通用说明之后就**没地方显示了** —— 现在挂回
                //   **这一颗开关自己**：写成标签里的第二行小字（同 Section 里还有别的开关，
                //   不能只为它加 Section footer；iOS 14 也支持 Toggle 的 label ViewBuilder）。
                Toggle(
                    isOn: shadowBinding(
                        \.nowPlayingOneScreen,
                        persist: { value in
                            UserDefaults.nowPlayingOneScreen = value
                            // 关掉要**当场**把 inset 写回（不用等下一次进听歌页）；
                            // 打开就顺手落地一次。
                            if value {
                                NowPlayingOneScreen.reapply()
                            } else {
                                NowPlayingOneScreen.restore()
                            }
                        }
                    )
                ) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("now_playing_one_screen".localized)
                        Text("now_playing_one_screen_description".localized)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                // 底部音量条：kumone 播放页下半屏的那一条（Apple Music 没有）。
                // 落在**我们自己的透明覆盖层**上（`NowPlayingPageOverlay`），不碰 Spotify 属性。
                Toggle(
                    "now_playing_volume".localized,
                    isOn: shadowBinding(
                        \.nowPlayingVolume,
                        persist: { value in
                            UserDefaults.nowPlayingVolume = value
                            // 打开就当场落地（页面还挂着的话），关掉当场把那一层拿走。
                            if value {
                                NowPlayingPageOverlay.reapply()
                            } else {
                                NowPlayingPageOverlay.remove(reason: "switch off")
                            }
                        }
                    )
                )

                // 歌词进播放器：把**我们自己的**逐词歌词画进播放器中段
                // （`npv.bottomStackView` 之上那块），这样「一屏」折掉卡片后页面上仍有歌词。
                // 渲染复用内嵌那一档（背景透明），宿主是 `NowPlayingLyricsPlate` 自己的一份。
                Toggle(
                    "now_playing_lyrics_in_player".localized,
                    isOn: shadowBinding(
                        \.nowPlayingLyricsInPlayer,
                        persist: { value in
                            UserDefaults.nowPlayingLyricsInPlayer = value
                            // 打开就当场落地（页面还挂着的话），关掉当场把我们的容器拿走。
                            if value {
                                NowPlayingLyricsPlate.reapply()
                            } else {
                                NowPlayingLyricsPlate.remove(reason: "switch off")
                            }
                        }
                    )
                )

                // ★ 2026-10-04（用户建议的第二条）：收起歌词那一屏，在**大封面与歌词键之间**
                // 画一行居中的当前歌词（"类似 Spotify 的单行歌词，但这行歌词我们自己画"）。
                // 落点是封面底边与控件条上沿的中点，做法见 `NowPlayingLyricsPlate.applySingleLyric`。
                Toggle(
                    "now_playing_single_lyric".localized,
                    isOn: shadowBinding(
                        \.nowPlayingSingleLyric,
                        persist: { value in
                            UserDefaults.nowPlayingSingleLyric = value
                            // 开/关都当场生效（页面还挂着的话）：关掉就是当场把它收起来。
                            NowPlayingLyricsPlate.reapply()
                        }
                    )
                )

                // ★ 2026-10-12（用户）：「我觉得有人不会用这个东西，去用正常的去了」——
                // 所以把歌词那两档也在这里给一颗**总开关**，不用先去歌词页翻逐语言那三颗。
                // ⚠️ 与 设置 → 歌词 里那几颗**是同一批键**（不是新造的一套）：两面永远同步。
                //   · 罗马化：日/中/韩三颗里**有一颗开着**就算开；关掉则三颗全关；
                //   · 译文：与歌词页那颗「隐藏译文」互为反相（键只有一个）。
                Toggle(
                    "show_romanized_lyrics".localized,
                    isOn: shadowBinding(
                        \.showRomanizedLyrics,
                        persist: { value in
                            NgzhwmSettingsViewModel.setAllRomanization(value)
                            // 这个指纹进过宿主的 `isCurrent` ⇒ 下一拍就重建，不用等换歌。
                            NowPlayingLyricsPlate.reapply()
                        }
                    )
                )

                Toggle(
                    "show_lyrics_translation".localized,
                    isOn: shadowBinding(
                        \.showLyricsTranslation,
                        persist: { value in
                            NgzhwmSettingsViewModel.setHideTranslation(!value)
                            NowPlayingLyricsPlate.reapply()
                        }
                    )
                )

                // ★ 2026-10-12（用户）：「现在是未播放歌词行是模糊不清的，加个功能叫
                // **未播放歌词行模糊化**。关闭之后，未当前播放歌词行不模糊化，**默认关闭**」。
                // 关着 = 非当前行只变淡、不发糊；翻开 = 回到改动前那条公式。
                Toggle(
                    "now_playing_blur_unplayed_lyrics".localized,
                    isOn: shadowBinding(
                        \.nowPlayingBlurUnplayedLyrics,
                        persist: { value in
                            UserDefaults.nowPlayingBlurUnplayedLyrics = value
                            // 这个开关进了宿主那条指纹 ⇒ 下一拍就重建，不用等换歌。
                            NowPlayingLyricsPlate.reapply()
                        }
                    )
                )
                // 控制键换成本地字形：原生按钮留着（动作/状态/无障碍全在），
                // 只把按钮里的原生图标设成透明、叠一个我们自己的 SF Symbol 字形。
                // 做法照 pw v0.21.1 的 `PlayerControls.x`（GPL-3.0）：见 `NowPlayingControlsPlate` 文件头。
                Toggle(
                    "now_playing_control_glyphs".localized,
                    isOn: shadowBinding(
                        \.nowPlayingControlGlyphs,
                        persist: { value in
                            UserDefaults.nowPlayingControlGlyphs = value
                            if value {
                                NowPlayingControlsPlate.reapply()
                            } else {
                                NowPlayingControlsPlate.restore()
                            }
                        }
                    )
                )

                // ⛔「禁止回弹」已于 2026-10-03 夜删除（真机日志 41）：
                // 它把列表的 `alwaysBounceVertical` 关掉，用户实测**开了就划不掉播放器**
                // （下拉关闭是经过列表那一层接管的，那个属性是链条的一环）。
                // 列表拖拽时剩下的那点橡皮筋是"一屏"**无法消除**的残留 ——
                // 要碰它就得先有办法自己接管关闭手势。理由写在 `NowPlayingOneScreen` 文件头。
            }

            // 音乐库：**改原生**的第一批（不是加壳）—— 大标题左对齐 + 收掉顶部渐隐灰纱。
            Section(
                header: Text("library_section".localized),
                footer: Text("library_large_title_description".localized)
            ) {
                Toggle(
                    "library_large_title".localized,
                    isOn: shadowBinding(
                        \.libraryLargeTitle,
                        persist: { UserDefaults.libraryLargeTitle = $0 }
                    )
                )
            }

            // 主页：与音乐库同一套"AM 化"（大标题贴左 + 头像靠右 + 收 pills 与灰纱），
            // 但那一页的头**随滚动动**，所以实现挂在页面 VC 上（见 `HomeHeaderAppearance` 文件头）。
            Section(
                header: Text("home_section".localized),
                footer: Text("home_large_title_description".localized)
            ) {
                Toggle(
                    "home_large_title".localized,
                    isOn: shadowBinding(
                        \.homeLargeTitle,
                        persist: { UserDefaults.homeLargeTitle = $0 }
                    )
                )
            }

            // ★ 2026-10-13（用户第 5 轮问的）：「Spotify 的歌单封面默认是歌单里前四首歌的专辑
            //   封面拼成的一张，有没有办法让它变成一张？」——**默认开**（就是他要的结果）。
            //   那个四宫格**不是视图层拼的**（视图拿到的就是一张成品图）：地址里串着四张图的 id
            //   （`https://mosaic.scdn.co/<size>/<id1><id2><id3><id4>`），截到第一个 id 之后
            //   服务端回的就是正常单张封面 ⇒ 改写点在图片请求上，不在视图上。
            //   完整证据链与"为什么不能写 `setURL:`"见 `Appearance/PlaylistSingleCover.x.swift` 文件头。
            Section(
                header: Text("playlist_cover_section".localized),
                footer: Text("playlist_single_cover_description".localized)
            ) {
                Toggle(
                    "playlist_single_cover".localized,
                    isOn: shadowBinding(
                        \.playlistSingleCover,
                        persist: { UserDefaults.playlistSingleCover = $0 }
                    )
                )
            }

            // ★ 2026-10-13（用户：「我就一个要求：**看起来像 Apple Music**」）：专辑页 / 歌单页的 AM 化。
            //   ① 取色底：页面最底层铺"封面取色 → 向下渐隐成 `#121212`"的竖直渐变
            //      （**必须先清掉 list / 每个 cell 画的 `#121212` 底色**，否则那层完全看不见 ——
            //       机制与证据见 `Appearance/EntityPageAppearance.x.swift` 文件头，与 pw 的 `AlbumField` 同路）；
            //   ② 封面下缘溶解：封面底部压一条渐变，让它"溶"进那片颜色（AM 的招牌动作）。
            //   两颗各自独立、**默认都开**；关掉即完全还原（清过的底色逐个写回原色）。
            Section(
                header: Text("entity_page_section".localized),
                footer: Text("entity_page_description".localized)
            ) {
                Toggle(
                    "entity_page_field".localized,
                    isOn: shadowBinding(
                        \.entityPageField,
                        persist: { UserDefaults.entityPageField = $0 }
                    )
                )
                Toggle(
                    "entity_page_dissolve".localized,
                    isOn: shadowBinding(
                        \.entityPageDissolve,
                        persist: { UserDefaults.entityPageDissolve = $0 }
                    )
                )
            }

            // ⛔「顶部大标题」（旧"样品"开关）已于 2026-10-02 删除：
            // 壳自己会画顶栏标题（`header=ON` 时），那条是**另一套**标题 —— 两个都开就会画两遍。

            Section(footer: Text("extras_description".localized)) {
                Button {
                    push(with: EeveePrivacySettingsView(), title: "privacy_title")
                } label: {
                    NavigationSectionView(
                        color: Color(hex: "#30B0C7"),
                        title: "privacy_title".localized,
                        imageSystemName: "hand.raised.fill"
                    )
                }

                Button {
                    push(with: EeveeHapticsSettingsView(), title: "haptics_title")
                } label: {
                    NavigationSectionView(
                        color: Color(hex: "#FF375F"),
                        title: "haptics_title".localized,
                        imageSystemName: "waveform"
                    )
                }

                Button {
                    push(
                        with: EeveeFlagOverrideSettingsView(
                            navigationController: navigationController
                        ),
                        title: "flag_override_title"
                    )
                } label: {
                    NavigationSectionView(
                        color: Color(hex: "#5E5CE6"),
                        title: "flag_override_title".localized,
                        imageSystemName: "slider.horizontal.3"
                    )
                }

                Button {
                    push(with: EeveeBlockedArtistsSettingsView(), title: "blocked_artists_title")
                } label: {
                    NavigationSectionView(
                        color: Color(hex: "#FF9F0A"),
                        title: "blocked_artists_title".localized,
                        imageSystemName: "person.slash.fill"
                    )
                }

                // 「减少打扰」：把 Spotify 自己的提示/推广/新功能气泡逐条关掉。
                // 做法是写 flag 覆盖（`FlagOverrideStore`），**不隐藏视图、不碰布局** ——
                // 原料（`ios-messaging-reduceinterventions-impl` 那批 flag）早在
                // `KnownFlagCatalog` 里，这一页只把它变成人话开关。
                Button {
                    push(with: EeveeReduceInterventionsView(), title: "reduce_interventions_title")
                } label: {
                    NavigationSectionView(
                        color: Color(hex: "#FF6482"),
                        title: "reduce_interventions_title".localized,
                        imageSystemName: "bell.slash.fill"
                    )
                }
            }

            // 设置本身的维护 + 关于（2026-10-02 新增）。
            // 三页全是"离线/只读"性质：备份与重置只碰我们自己的键、许可页是静态、
            // 更新日志只读 GitHub —— 都不需要新 hook，也不需要新取证。
            Section(header: Text("maintenance_section".localized)) {
                Button {
                    push(with: EeveeBackupSettingsView(), title: "backup_title")
                } label: {
                    NavigationSectionView(
                        color: Color(hex: "#64D2FF"),
                        title: "backup_title".localized,
                        imageSystemName: "externaldrive.badge.timemachine"
                    )
                }

                Button {
                    push(with: EeveeUpdatesSettingsView(), title: "updates_title")
                } label: {
                    NavigationSectionView(
                        color: Color(hex: "#32ADE6"),
                        title: "updates_title".localized,
                        imageSystemName: "clock.arrow.circlepath"
                    )
                }

                Button {
                    push(with: EeveeLicensesSettingsView(), title: "licenses_title")
                } label: {
                    NavigationSectionView(
                        color: Color(hex: "#8E8E93"),
                        title: "licenses_title".localized,
                        imageSystemName: "doc.badge.ellipsis"
                    )
                }
            }
        }
                // ★ 2026-10-12：inset-grouped（胶囊卡片）—— 为什么、怎么做的见 `EeveeSettingsView` 顶部那段
        .listStyle(InsetGroupedListStyle())
        // 每次进页重新同步一次：别处（Flag 页、重置、上一版遗留的存储）改了 UserDefaults 时
        // 影子值不该停在旧值上。与 Flag 覆盖页的 `.onAppear` 同一套做法。
        .onAppear { shadow = Shadow() }
    }

    // MARK: - 绑定

    /// 影子值 + 落盘：`set` 里**先改影子值**（让 SwiftUI 失效重绘），再写 UserDefaults。
    private func shadowBinding<Value>(
        _ keyPath: WritableKeyPath<Shadow, Value>,
        persist: @escaping (Value) -> Void
    ) -> Binding<Value> {
        Binding(
            get: { shadow[keyPath: keyPath] },
            set: { value in
                shadow[keyPath: keyPath] = value
                persist(value)
            }
        )
    }

    /// 清爽开关：在影子绑定的基础上多一步**当场复查**。
    ///
    /// 为什么需要：这些开关是运行期读的，撤销本来只在"目标视图下一次 layout"时生效 ——
    /// 而被我们藏过的视图不一定再有 layout 回合，用户那边的表现就是"关掉开关它也不回来"。
    /// `reconcileNow()` 会当场把当前窗口复查一遍（见 `DeclutterChrome`），
    /// 所以关掉开关的瞬间那条 chrome 就回来了，不用等布局、也不用重启。
    private func declutterBinding(
        _ keyPath: WritableKeyPath<Shadow, Bool>,
        persist: @escaping (Bool) -> Void
    ) -> Binding<Bool> {
        shadowBinding(keyPath) { value in
            persist(value)
            DeclutterChrome.reconcileNow()
        }
    }

    /// 与根页 `EeveeSettingsView.pushSettingsController` 同一套做法：把 SwiftUI 页塞进
    /// 一个 `EeveeSettingsViewController`，再推上 Spotify 自己的导航栈。
    private func push(with view: any View, title: String) {
        let viewController = EeveeSettingsViewController(
            navigationController.view.frame,
            settingsView: AnyView(view),
            navigationTitle: title.localized
        )

        navigationController.pushViewController(viewController, animated: true)
    }
}
