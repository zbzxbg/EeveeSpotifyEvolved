import SwiftUI
import UIKit

/// 「页面与音乐库」设置页：首页、音乐库，以及专辑 / 歌单 / 艺人页的外观。
///
/// 原来「外观」下是两页（`HomeAndLibrarySettingsView` + `EntityPageSettingsView`），各只有 3~4 颗开关却各占一个入口；而 AM 式页头与取色底本来就同时作用于专辑、歌单、艺人三页，"艺人页"被藏在「专辑 / 歌单页」这个名字后面。现在并成一页，按"管哪一页"重排：首页头部三态 → 音乐库 → 首页小卡片 → 歌单封面（`mosaic.scdn.co` 四宫格转单张，跨页生效）→ 专辑/歌单/艺人页（取色底 + 隐藏原生按键）→ AM 式页头（三页共用）→ 艺人页标签栏 → 艺人介绍卡片。
///
/// ⚠️ 没有新增任何 `UserDefaults` 键，只动 UI 与文案，设备上已有的值原样有效；「重置本页」的白名单是两页的并集（`ownedKeys`），重置范围只变宽。
///
/// 开关之间的关系：
/// ① `hide_home_header` 打开后接管整个页头，`home_large_title` 随即让位（`HomeHeaderAppearance.apply` 里直接 return，共享存储一个字节都不写）。灰纱不在 `DeclutterChrome` 藏的那颗 `HomeHeaderView` 里 ⇒ "顶部条没了、灰纱还在"是当前实现结果，不是 bug。
/// ② 两颗 AM 化各管一页：`home_large_title` 在 `HomeHeaderAppearance.x.swift`（头部随滚动动），`library_large_title` 在 `LibraryAppearance.x.swift`（头部静止 + 0.5s 复查节拍）。
/// ③ `library_large_title` 一颗管七件事（标题字号位置、三颗按钮贴右、灰纱、快速滚动条、行圆角与发丝线、库内搜索胶囊）。七件事共享同一条节拍与两条还原路径，拆开就要各自建"关掉时精确写回"的状态机 ⇒ 刻意保持一颗。
/// ④ `playlist_single_cover` 挂在图片请求层，凡走 `mosaic.scdn.co` 的封面都被改 ⇒ 音乐库网格与首页那几个模块同样受影响，不只是歌单页。
/// ⑤ `entityPageDissolve` 内部装了 11 件事（清原生底色 → 铺取色底 → 文字反色 → 状态栏字色 → 满幅照片含顶纱 → 下缘溶解 → 藏原生 wash），其中 1–8、10 是有先后的流水线 ⇒ 不建议拆。
enum HomeHeaderStyle: Hashable {
    /// Spotify 原样（两颗都关）。
    case system
    /// 我们自绘的 AM 式页头（`homeLargeTitle == true`）。
    case amStyle
    /// 藏掉整个页头（`hideHomeHeader == true`）。
    case hidden
}

struct PagesAppearanceSettingsView: View {

    @State private var shadow = Shadow()

    private struct Shadow {
        var hideHomeHeader = UserDefaults.hideHomeHeader
        var libraryLargeTitle = UserDefaults.libraryLargeTitle
        var homeLargeTitle = UserDefaults.homeLargeTitle
        var homeTileTint = UserDefaults.homeTileTint
        var playlistSingleCover = UserDefaults.playlistSingleCover
        var entityPageDissolve = UserDefaults.entityPageDissolve
        var entityPageHideChrome = UserDefaults.entityPageHideChrome
        var entityPageAMHeader = UserDefaults.entityPageAMHeader
        /// 艺人页那两格（见 `EntityPageHeaderManager.applyToArtistPage`）。
        var artistHideListeners = UserDefaults.artistHideListeners
        var artistHideTabs = UserDefaults.artistHideTabs
        var artistBioSource = UserDefaults.artistBioSource

        /// 首页头部三态 —— **派生值**，不落盘（真值仍是上面两个键）。
        ///
        /// ⚠️ 这是本页唯一一处"两个键映到一个 UI 控件"的地方，所以它**不参与**
        /// `settingsShadowBinding`：读走 `homeHeaderStyle`、写走下面 `homeHeaderStyleBinding` 的 set。
        var homeHeaderStyle: HomeHeaderStyle {
            if hideHomeHeader { return .hidden }
            return homeLargeTitle ? .amStyle : .system
        }
    }

    /// 三态选择器的绑定：读 = 派生态；写 = **落到两个既有键**上（见 `Shadow.homeHeaderStyle` 的说明）。
    ///
    /// ⚠️ 落盘与副作用**必须写在这里**，不能写成 `.onChange(of: shadow.homeHeaderStyle)` ——
    /// 那是**派生**属性（`hideHomeHeader` / `homeLargeTitle` 算出来的），`onChange` 观察不到它。
    ///
    /// ⚠️ 为什么 `shadow` 与 `UserDefaults` 都要写：`Picker` 的段选中态由 SwiftUI 按 `selection`
    /// 求值决定，而"写 UserDefaults 不会让 SwiftUI 失效重绘"是本仓库踩过的坑
    /// （见 `SettingsShadowBinding.swift` 文件头）—— 所以两者都要写。
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
                    // 从"隐藏"切回"AM 式/原样"时再由上面两个分支写准。
                }

                // 藏过的 chrome 不一定再有 layout 回合 ⇒ 当场复查一遍（见 `DeclutterChrome`）。
                DeclutterChrome.reconcileNow()
                // ⚠️ AM 式那半边**不在这里补推**：它的入口是 `HomeHeaderAppearance.apply(to:)`，
                // 需要一个**页面对象**，而设置页手上没有（硬凑会写错页面）。它靠首页自己的
                // `viewDidLayoutSubviews` 那一拍落地 —— 关掉设置页回到首页时必然发生。
                // "隐藏 ↔ AM 式"因此可能有一拍延迟，这是刻意的：宁可晚半拍，不猜页面。
            }
        )
    }

    var body: some View {
        List {
            // ── 主页头部：三态（原样 / Apple Music 式 / 隐藏）
            //
            // 原来 `hide_home_header` 与 `home_large_title` 是两颗
            // 各自独立的 Toggle，同时打开时后者**静默让位** ⇒ 合成一个三态选择。三个状态的键值对应：
            // · 原样 = `homeLargeTitle == false && hideHomeHeader == false`
            // · AM 式 = `homeLargeTitle == true && hideHomeHeader == false`
            // · 隐藏 = `hideHomeHeader == true`（此时 `homeLargeTitle` 的值**被忽略**）
            // **两个键都保留**（存储语义不变、老值继续有效、不写迁移）。
            //
            // ⚠️（没看懂这个是干嘛的
            // `Apple Music...`）：**不要再用 segmented**。三段式在 414pt 上放不下
            // 「Apple Music 式主页」，而且段标签只有状态名、没有"这是在设置什么"的说明。
            // 改成带标签的 Picker（列表里一行，点开才选三个状态）+ footer 解释三档语义。
            // （感觉这三个没用了，代码和本地化都删掉）：那句 footer
            // （`home_header_style_description`）连同键一起删了 —— 三个选项名本身
            // （Spotify原生 / Apple Music 式主页 / 隐藏首页顶部条）已经说清了各自是什么。
            Section {
                Picker(selection: homeHeaderStyleBinding) {
                    Text("home_header_original".localized).tag(HomeHeaderStyle.system)
                    Text("home_large_title".localized).tag(HomeHeaderStyle.amStyle)
                    Text("hide_home_header".localized).tag(HomeHeaderStyle.hidden)
                } label: {
                    Text("home_header_style".localized)
                }
            }

            // ── 音乐库
            //
            // 音乐库：**改原生**的第一批（不是加壳）—— 大标题左对齐 + 收掉顶部渐隐灰纱。
            // 这一颗管七件事，清单与"为什么不拆"写在文件头 ③。
            Section(header: Text("library_section".localized)) {
                Toggle(
                    "library_large_title".localized,
                    isOn: settingsShadowBinding($shadow.libraryLargeTitle) { value in
                        UserDefaults.libraryLargeTitle = value
                    }
                )
            }

            // ── 首页小卡片
            // （那几个小模块是经过处理的……底部的颜色会跟着封面的样子跑）：
            // 把那排小卡片的底色改成**从它自己的封面取色**（普通 Spotify 那边这几格是一片灰）。
            // ⚠️ 生效时机：钩子是**启动时按当时的值**决定装不装的 —— 启动时是**关**的必须重启；
            // 默认就是开，所以多数人察觉不到。`RestartSection` 因此只命中"启动时关、现在打开"。
            Section(
                header: Text("home_tile_tint_section".localized),
                footer: Text("home_tile_tint_description".localized)
            ) {
                Toggle(
                    "home_tile_tint".localized,
                    isOn: settingsShadowBinding($shadow.homeTileTint) { value in
                        UserDefaults.homeTileTint = value
                    }
                )
            }

            // ── 歌单封面
            // （Spotify 的歌单封面默认是歌单里前四首歌的专辑
            // 封面拼成的一张，有没有办法让它变成一张？——**默认开**（就是他要的结果）。
            // 那个四宫格**不是视图层拼的**（视图拿到的就是一张成品图）：地址里串着四张图的 id
            // （`https://mosaic.scdn.co/<size>/<id1><id2><id3><id4>`），截到第一个 id 之后
            // 服务端回的就是正常单张封面 ⇒ 改写点在图片请求上，不在视图上。
            // 完整证据链与"为什么不能写 `setURL:`"见 `Appearance/PlaylistSingleCover.x.swift` 文件头。
            Section(
                header: Text("playlist_cover_section".localized),
                footer: Text("playlist_single_cover_description".localized)
            ) {
                Toggle(
                    "playlist_single_cover".localized,
                    isOn: settingsShadowBinding($shadow.playlistSingleCover) { value in
                        UserDefaults.playlistSingleCover = value
                    }
                )
            }

            // ── 专辑 / 歌单 / 艺人页
            // （我就一个要求：**看起来像 Apple Music**）：取色底 + 封面下缘溶解。
            // ⚠️ `entityPageDissolve` 默认是 **false**；打开后"清原生底色"与"状态栏字色"是
            // **启动期** guard ⇒ 要重启 Spotify 才完全生效。
            // 「spotify 本身的那些按键都还在，**看起来不咋地**」
            // ⇒ 每行的「+」「…」、头部的下载 / 加入 / 菜单 / 观看信息一律藏掉（AM 上没有它们）。
            // **play / shuffle 不动** —— 那是真功能，AM 自己也有。
            // ⚠️ AM 页头会自己重画这一批按钮 ⇒ 同时开时本颗常常"看上去什么都没做"，
            // 所以 AM 页头开着时把本颗**置灰**（只改 UI，键与行为不变）。
            Section(header: Text("entity_page_section".localized)) {
                Toggle(
                    "entity_page_dissolve".localized,
                    isOn: settingsShadowBinding($shadow.entityPageDissolve) { value in
                        UserDefaults.entityPageDissolve = value
                    }
                )
                Toggle(
                    "entity_page_hide_chrome".localized,
                    isOn: settingsShadowBinding($shadow.entityPageHideChrome) { value in
                        UserDefaults.entityPageHideChrome = value
                    }
                )
                .disabled(shadow.entityPageAMHeader)
            }

            // ── Apple Music 式页头（三页共用）
            // （我们的观感不好，我想让这些页面看起来像 Apple Music）：
            // 把**页头**换成 AM 形态 —— 标题 / 创建者 / 长度居中，下面一行 shuffle + **白色 Play 胶囊**
            // + 尾随按钮。Spotify 那一列**整列藏掉**（改 layer 的 hidden + 空 mask，一次钉死）、
            // 我们自己画，三颗按钮**镜像**它的字形并**转发**点击 ⇒ 动作/状态/语言都留在 Spotify 那边。
            // **默认开**；管的是**专辑 / 歌单 / 艺人三个页面**。
            // ⚠️ **关掉不可逆**（见文件头 ⑥），别把它当可反复试的开关。
            Section(header: Text("entity_page_am_header_section".localized)) {
                Toggle(
                    "entity_page_am_header".localized,
                    isOn: settingsShadowBinding($shadow.entityPageAMHeader) { value in
                        UserDefaults.entityPageAMHeader = value
                        // 页头是**启动时**装的那一组 hook（`EntityPageHeader`），开关值在**下一次进页面**时读到
                        // ⇒ 不需要当场落地。⚠️ 但"关"这一侧回不来（见上），别把它当可反复试的开关。
                    }
                )
            }

            // ── 艺人页
            // （把那些分散的/未添加的艺人页的部分加上）：
            // 「每月听众」与 Music / Video / Merch 标签栏原来都**没有开关**（前者硬画在页头里、
            // 后者在起被无条件藏掉）⇒ 现在收进这一节。
            // · 标签栏默认**开**（= 保持现有观感）；关掉会在下一拍/当场把原 alpha、点击、
            // 分页滚动位置写回（`EntityPageHeaderManager.restoreArtistStrip`）。
            // · 月听众默认**关**（保留信息）；打开后下一拍页头就不再画那一行。
            Section(
                header: Text("artist_page_section".localized),
                footer: Text("artist_page_description".localized)
            ) {
                Toggle(
                    "artist_hide_listeners".localized,
                    isOn: settingsShadowBinding($shadow.artistHideListeners) { value in
                        UserDefaults.artistHideListeners = value
                        EntityPageHeaderManager.reapplyArtistPageAppearance()
                    }
                )
                Toggle(
                    "artist_hide_tabs".localized,
                    isOn: settingsShadowBinding($shadow.artistHideTabs) { value in
                        UserDefaults.artistHideTabs = value
                        // 关掉时**当场**还原（设置页盖在艺人页上，那一页不一定会再布局一次）。
                        if !value { EntityPageHeaderManager.restoreArtistStrip() }
                        EntityPageHeaderManager.reapplyArtistPageAppearance()
                    }
                )
            }

            // ⚠️ 它**只影响点 `i` 弹出来的那张卡片**：列表里 Spotify 自己那段「关于艺人」在任何选项下
            // 都会被折成 0 高（`EntityPageSectionDrop.aboutArtistFragment`）—— 那是"把它去掉"那件事，
            // 与来源选择无关。
            // ⚠️ 读取时机：**每次点 `i` 时读一次**（`ArtistBioSheet.present`）⇒ 选完立刻生效，不用重启。
            Section(
                header: Text("artist_bio_section".localized),
                footer: Text("artist_bio_description".localized)
            ) {
                Picker(
                    "artist_bio_source".localized,
                    selection: Binding(
                        get: { shadow.artistBioSource },
                        set: { value in
                            shadow.artistBioSource = value
                            UserDefaults.artistBioSource = value
                        }
                    )
                ) {
                    ForEach(ArtistBioSourceKind.allCases, id: \.self) { kind in
                        Text(kind.description).tag(kind)
                    }
                }
            }

            // 「立即重启」：只在**当前值 ≠ 启动快照**时出现 —— 也就是"启动时是关的、现在打开了"
            // 那一种（见上面的说明）。默认开的人永远不会看到这一行。
            RestartSection(visible: UserDefaults.homeTileTint != HomeTileTint.launchEnabled)

            SettingsResetSection(
                keys: Self.ownedKeys,
                afterReset: {
                    shadow = Shadow()
                    // 大标题那两颗是"下一次布局生效"（原页也没有当场落地），
                    // 需要当场复查的只有 `DeclutterChrome` 管的那几颗（含三态选择器里的"隐藏"）。
                    //
                    // ⚠️ 本页有 `RestartSection`（`home_tile_tint` 那颗），但它不进 `ownedKeys`、
                    // 也不改「重置本页」的作用面 —— 它只是读一下 `HomeTileTint.launchEnabled`
                    // 与当前值。（已知边角：`home_tile_tint` 被重置后回到默认的**开**，
                    // 若这一场启动时它是关的，那么 `homeTileTint != launchEnabled` 成立
                    // ⇒ 重启提示会现身，这正是我们想要的提示。）
                    DeclutterChrome.reconcileNow()
                }
            )
        }
        .listStyle(InsetGroupedListStyle())
        .onAppear { shadow = Shadow() }
    }

    /// 本页「重置本页」的作用范围 —— **原两页白名单的并集**。
    ///
    /// ⚠️ `home_tile_tint` 在并集里，但它自己的`RestartSection`不参与；见上面 `afterReset` 的说明。
    /// ⚠️ `hideConnectButton` / `hideAddToButton` 仍然不在本页 —— 它们属于「歌曲播放页」。
    private static let ownedKeys = [
        "hideHomeHeader",
        "libraryLargeTitle",
        "homeLargeTitle",
        "homeTileTint",
        "playlistSingleCover",
        "entityPageDissolve",
        "entityPageHideChrome",
        "entityPageAMHeader",
        // 艺人页那两格（合并后新增的键，别忘了重置/备份）。
        "artistHideListeners",
        "artistHideTabs",
        "artistBioSource",
    ]
}
