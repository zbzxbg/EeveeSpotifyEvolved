import SwiftUI

/// 「听歌页」——听歌页（Now Playing）上所有属于**我们自己的**开关。
///
/// ## 为什么单独一页（2026-10-13 用户：「设置页面有点乱了」，拍板方案 B）
///
/// 这些开关原来全塞在「扩展」那一页里（`EeveeExtrasSettingsView`，627 行、24 个开关 +
/// 8 个子页入口），而「扩展」在根页只占一行 ⇒ 想找"听歌页那一屏"要进两层、还要在
/// 一页里滚很久。现在按**页面**拆开：听歌页 / 标签栏与迷你条 / 首页与音乐库 /
/// 歌单与专辑页，四个都在根页上一步可达。
///
/// ## ★★ 2026-10-22（用户）：五件结构改动整合成一颗总开关
///
/// 用户原话：
/// > 整合以下功能：整页取色底，隐藏Spotify歌曲播放页模块/隐藏Spotify官方单行歌词/
/// > 隐藏两个胶囊，歌词进播放器。上述功能整合，名字为：修改Spotify听歌页布局，
/// > 放在歌曲播放页的最上面（默认开启）。
/// > 然后：展示音量条，展示（自画）单行歌词，展示罗马化歌词，展示歌词翻译，
/// > 未播放歌词行模糊化，控制键替换为本地 这些功能作为 修改Spotify听歌页布局 的二级菜单
/// > （除了展示音量条这个功能，其他的默认开启）。然后，展示音量条下面写一个：
/// > 该功能测试中，不推荐开启。
///
/// 于是本页三节：
///   · `now_playing_section` —— **听歌页样式三档选择**（Spotify 原生 / 沉浸式 / Apple Music 式）。
///     ★★ 2026-10-30（用户）：「选择沉浸式的那几个按键，全部写默认开启，相关本地化文件删掉」
///     ⇒ 原来的二级菜单（音量条 / 罗马化 / 译文 / 未播放行模糊 / 控制键字形）整块删除，
///     这些功能按默认开启落地；罗马化与译文仍可在「设置 → 歌词」里逐语言改。
///     ★★ 2026-10-25：两颗互斥的 Toggle 合成一个三档 `Picker`，见 `NowPlayingStyle`。
///   · **清爽** —— 按类名藏 Spotify 自己的 chrome（迷你条、传输条两颗按钮）。
///   · `player_cards_section` —— 听歌页**卡片类**清爽（一张卡一个键 + 一颗总开关）。
struct NowPlayingSettingsView: View {

    /// 本页所有开关的**影子值**。为什么需要、怎么用见 `settingsShadowBinding` 的文件头。
    @State private var shadow = Shadow()

    private struct Shadow {
        /// ★★ 2026-10-25（用户拍板 A 方案）：听歌页样式**三态**，取代原来那两颗互斥的 Toggle
        /// （「修改Spotify听歌页布局」+「iOS 27 听歌页」）。取值仍由那两个键推出，
        /// 见 `NowPlayingStyle` 的文件头。
        var style = UserDefaults.nowPlayingStyle
        // ── 清爽：不属于总开关，各占一行 ──
        var hideMiniPlayerBar = UserDefaults.hideMiniPlayerBar
        /// ★ 2026-10-17 从「首页与音乐库」搬来（传输条上那两颗按钮，见 declutter 那一节）。
        var hideConnectButton = UserDefaults.hideConnectButton
        var hideAddToButton = UserDefaults.hideAddToButton
        /// 听歌页卡片那批（总开关 + 一张卡一个键）。用一个字典装：加卡片不用改这里。
        var hidePlayerCards = PlayerCardsDeclutter.masterHidden
        var playerCards: [PlayerCard: Bool] = PlayerCardsDeclutter.snapshot()
    }

    var body: some View {
        List {
            Section(
                header: Text("now_playing_section".localized),
                // 「关掉即还原」和"官方单行歌词要重启"这两句放在节脚：它们说的是整页的行为，
                // 挂在标题下面会把第一行撑得过高。
                //
                // ★★ 2026-10-25：三档各自的语义写在这里（与「首页顶部样式」那条 footer 同一做法）。
                //   选项名只是三个短词，不放长句 —— `Picker` 行尾会显示当前选中值，
                //   414pt 上长名字会被截断（`home_header_style` 那次踩过，见那个文件头）。
                footer: VStack(alignment: .leading, spacing: 6) {
                    Text(styleDescriptionText)
                    Text("now_playing_layout_footer".localized)
                }
            ) {
                // ★★ 2026-10-25（用户：「给那两个修改的做成这样（类似艺人简介展示）的选择方式，
                //   三个选项：Spotify 原生 + 另外两个」）：**两颗互斥的 Toggle → 一个三态 Picker**。
                //
                // 为什么必须合成一个：两版布局在落地代码里是互斥的
                // （`NowPlayingLyricsPlate.isEnabled` 里那道 `!nowPlayingIOS27` 的门），
                // 两颗同时打开时新那版会**静默让位** —— 屏幕上看到的和开关说的不一致。
                // 这与 2026-10-14「首页顶部样式」把两颗 Toggle 合成三态是同一个教训。
                //
                // ⚠️ 存储一个字没变：仍然只写 `nowPlayingLayout` / `nowPlayingIOS27`
                //   （备份 / 导入 / 日志 / `normalizeNowPlayingLayoutKeys()` 全不受影响）。
                Picker(
                    selection: settingsShadowBinding($shadow.style) { value in
                        applyStyleChange(value)
                    }
                ) {
                    ForEach(NowPlayingStyle.allCases, id: \.self) { style in
                        Text(style.titleKey.localized).tag(style)
                    }
                } label: {
                    Text("now_playing_style".localized)
                }

                // ⛔ 2026-10-30（用户）：「选择沉浸式的那几个按键，全部写默认开启，
                //   相关本地化文件删掉」—— 二级菜单整块删除；音量条 / 未播放行模糊 /
                //   本地控制键字形 / 罗马化 / 译文现在都按默认开启落地
                //   （见 `NowPlayingPageOverlay.isEnabled` / `NowPlayingControlsPlate.isEnabled` /
                //   `AppleMusicLyricsPage` 的模糊判定 / `LyricLinesAdapter` 的 bit 16）。
                //   罗马化与译文仍可在「设置 → 歌词」里逐语言改，这里不再摆快捷开关。

                // 二级菜单已删除（2026-10-30，见上）。

                // ⛔「禁止回弹」已于 2026-10-03 夜删除（真机日志 41）：
                // 它把列表的 `alwaysBounceVertical` 关掉，用户实测**开了就划不掉播放器**
                // （下拉关闭是经过列表那一层接管的，那个属性是链条的一环）。
                // 列表拖拽时剩下的那点橡皮筋是"一屏"**无法消除**的残留 ——
                // 要碰它就得先有办法自己接管关闭手势。理由写在 `NowPlayingOneScreen` 文件头。
            }

            Section {
                // ⚠️ 这一颗属于「迷你播放条那一族」（五颗）：
                //    藏整条 = 本页；玻璃 + 圆封面 = 「标签栏与迷你条」页；
                //    设备按钮 + 加号 = **本页**（★ 2026-10-17 从「首页与音乐库」搬来，
                //    见下面那两颗的说明）。2026-10-14 那轮以"移动 Toggle 会改掉用户找开关的路径"
                //    为由拒绝搬家，2026-10-17 用户点名后**只搬了错位的那两颗**：
                //    它们管的是 `Components.ConnectButtonOutputSwitcher` / `Components.UI.AddToButton`
                //    —— 迷你条与播放器传输条共用的按钮，跟"首页与音乐库"没有任何关系。
                Toggle(
                    "hide_mini_player_bar".localized,
                    isOn: settingsShadowBinding($shadow.hideMiniPlayerBar) { value in
                        UserDefaults.hideMiniPlayerBar = value
                        // 藏过的 chrome 不一定再有 layout 回合 ⇒ 当场复查一遍（见 `DeclutterChrome`）。
                        DeclutterChrome.reconcileNow()
                    }
                )

                // ★ 2026-10-17（用户：「有些功能是不是有些该搬家了，比如前三个有关于外观的设置」）：
                //   这两颗原来摆在「首页与音乐库」页里，但它们藏的是**传输条上的两颗按钮**
                //   （设备/输出切换、加号）—— 迷你播放条和播放器共用同一套控件，跟首页无关。
                //   现在与上面那颗同处一节：同一套 `DeclutterChrome` 判据。
                //   ⚠️ 中文名「隐藏喜欢按钮」而代码认的是**加号**（`Components.UI.AddToButton`）——
                //   那是 l10n 的值问题（与 `entity_page_am_header_section` 的「（歌单）」同类），
                //   本次不动文案，只把开关搬到它真正管的那一屏对应的设置页。
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

            // ★ 2026-10-13（用户拍板）：听歌页**卡片类**清爽。
            //
            // 上游那套 `PlayerHideSettingsView` 一共 18 颗（含 6 颗按钮）；我们只取卡片，
            // 因为"藏掉按钮 = 功能没了"，而其中几颗（分享 / 队列 / Connect / 收藏）用户
            // 2026-10-11 亲手点名在用。判据、marker 表、缓存与"折成 0 高"的做法全写在
            // `Appearance/PlayerDeclutter.x.swift`，这里只摆开关。
            Section(
                header: Text("player_cards_section".localized)
            ) {
                Toggle(
                    "hide_player_cards".localized,
                    isOn: settingsShadowBinding($shadow.hidePlayerCards) { value in
                        PlayerCardsDeclutter.masterHidden = value
                        // 卡片是滚动列表的 cell，改完要让那一列重新问一次尺寸。
                        PlayerCardsDeclutter.refresh()
                    }
                )

                // 总开关开着就不再摆那 10 行（与上游一致）：既是省一屏，也免得两个入口
                // 看起来在互相打架。
                if !shadow.hidePlayerCards {
                    ForEach(PlayerCard.allCases, id: \.self) { card in
                        Toggle(
                            card.labelKey.localized,
                            isOn: settingsShadowBinding(cardBinding(card)) { value in
                                PlayerCardsDeclutter.setHidden(card, value)
                                PlayerCardsDeclutter.refresh()
                            }
                        )
                    }
                }
            }

            // ⛔「双击手势」整节已于 2026-10-04 删除（用户拍板：先删掉，之后再搞）。
            //   它不是"坏了"才删：切歌那条路日志 8/17 证明能用；删是因为 ——
            //   ① 手势挂在页面根视图上，**在播放键上方双击也会跳歌**（本该是播放/暂停）；
            //   ② 最该起作用的全屏歌词那一面默认关、从没验过；
            //   ③ 最近 8 份日志里它一次都没被用过。
            //   重做时的三条要求（控件上不认 / 单击让位 / 另选挂点）见
            //   `Tools/eevee-hookfinder/SESSION_2026-10-03_NIGHT.md` §10。
            //   ⇒ 上游 `Player/PlayerGestures.x.swift` 正是按这三条重写的，移植计划见
            //      本轮讨论（排在编译通过之后的第一件）。

            SettingsResetSection(
                keys: Self.ownedKeys,
                afterReset: {
                    // 先重同步影子值（否则选择器还显示旧档），再按**重置后**的那两个键落地。
                    shadow = Shadow()
                    applyStyleChange(UserDefaults.nowPlayingStyle)
                    // 卡片那批：让听歌页那列 cell 重新问一次尺寸（开关值已经删回默认了）。
                    PlayerCardsDeclutter.refresh()
                }
            )
        }
        .listStyle(InsetGroupedListStyle())
        // 每次进页重新同步一次：别处（Flag 页、重置、上一版遗留的存储）改了 UserDefaults 时
        // 影子值不该停在旧值上。
        .onAppear {
            // ★ 2026-10-22：那五颗结构键的唯一合法来源是总开关；备份导入 / 旧版本残留
            //   都可能把它们写歪 ⇒ 进页先按总开关归一，再读影子值（详见 `normalizeNowPlayingLayoutKeys`）。
            //   真的改到了东西（例如刚导入完旧备份）就当场重放一遍，别让听歌页停在旧状态。
            if UserDefaults.normalizeNowPlayingLayoutKeys() > 0 {
                applyStyleChange(UserDefaults.nowPlayingStyle)
            }
            shadow = Shadow()
        }
    }

    /// 三档各自的语义（节脚第一段）。
    ///
    /// ★★ 2026-10-25：选项名只是短词（`Picker` 行尾要显示它），**长句全部放这里** ——
    /// 与「首页顶部样式」那条 footer 同一做法（那边 2026-10-22 就是被 segmented 截断才改的）。
    ///
    /// ★ 2026-10-30：沉浸式二级菜单删除后，这段不再拼「包含：…」的五个功能名，
    /// 直接读一条完整说明（`now_playing_style_description` 里的 `%@` 也一并去掉）。
    private var styleDescriptionText: String {
        "now_playing_style_description".localized
    }

    /// ★★ 2026-10-25（用户拍板 A 方案）：三档选择器的「当场落地 / 还原」。
    ///
    /// 只做一件事：把选择器选中的那一档翻成那两个**已有**的键，然后复用两条老路
    /// （`applyIOS27Change` / `applyLayoutChange`）落地 —— 它们的写盘与重放顺序都是
    /// 真机调出来的（尤其是"新层与旧层的重放顺序，开着与关着不一样"那一条），
    /// 这里再抄一份就等于给自己加第二个真相。
    ///
    /// 三条转换的顺序都是有讲究的：
    ///   · → `.spotify`：先关新层（把封面 transform 写回原值），再关旧层；
    ///   · → `.immersive`：同样先关新层，再按旧总开关铺上；
    ///   · → `.appleMusic`：**先关旧总开关**（清掉 `nowPlayingLyricsInPlayer` 与那几颗结构键），
    ///     再开新层 —— 反过来会让旧层在新层已经接管之后又铺一遍。
    private func applyStyleChange(_ style: NowPlayingStyle) {
        switch style {
        case .spotify:
            applyIOS27Change(false)
            applyLayoutChange(false)
        case .immersive:
            applyIOS27Change(false)
            applyLayoutChange(true)
        case .appleMusic:
            applyLayoutChange(false)
            applyIOS27Change(true)
        }
    }

    /// 旧总开关（`.immersive` 那一档）的「当场落地 / 还原」。
    ///
    /// 先把那五颗旧键写成同一个值 —— 落地代码读的仍然是各自的键
    /// （取色底 / 一屏 / 隐藏官方单行歌词 / 两颗胶囊 / 歌词进播放器），
    /// 这样备份、导入、日志里的值与屏幕上的选择永远一致。
    ///
    /// 然后逐个叫"复查/重放"入口：**关掉时它们自己走还原分支** ——
    /// 每个入口的 `apply` 里都有 `guard isEnabled else { restore/remove }`，所以这里
    /// 不需要分两套分支，也不会漏掉"关总开关后屏幕上还留着"的东西。
    /// 音量条与控制键这两颗二级菜单项也在其中：它们的 `isEnabled` 带着总开关的门。
    private func applyLayoutChange(_ enabled: Bool) {
        UserDefaults.nowPlayingLayout = enabled
        // ★ 2026-10-23：这四颗结构键是两版布局**共用**的 ⇒ 写「任一布局开着」。
        //   （当年那五颗里的第五颗 `nowPlayingLyricsInPlayer` 仍只跟总开关 ——
        //    它是旧层的开关，新版布局不用它。）
        let structural = UserDefaults.nowPlayingAnyLayout
        UserDefaults.nowPlayingBackdrop = structural
        UserDefaults.nowPlayingOneScreen = structural
        UserDefaults.nowPlayingLyricsInPlayer = enabled
        UserDefaults.hideSingalongLine = structural
        UserDefaults.hideNowPlayingPills = structural

        refreshNowPlayingBackdrop()
        NowPlayingOneScreen.reapply()
        NowPlayingPageOverlay.reapply()
        NowPlayingControlsPlate.reapply()
        NowPlayingIOS27.reapply()
        // 歌词进播放器：`reapply()` 自己按总开关与子开关重建或回滚。
        NowPlayingLyricsPlate.reapply()
        // 官方单行歌词 + 两颗胶囊：藏过的 chrome 不一定再有 layout 回合 ⇒ 当场复查。
        DeclutterChrome.reconcileNow()
    }

    /// ★ 2026-10-23：「Apple Music 式」那一档（`nowPlayingIOS27`）的「当场落地 / 还原」。
    ///
    /// 两件事：
    ///   ① 把四颗**两版共用**的结构键按 `nowPlayingAnyLayout` 写一遍
    ///      （新版单开时，取色底 / 一屏 / 隐藏官方单行歌词 / 两颗胶囊 也要生效）；
    ///   ② 逐个叫重放入口：开着时新层上、旧层让位；关掉时新层自己还原、
    ///      旧层按它自己的总开关回来。
    private func applyIOS27Change(_ enabled: Bool) {
        UserDefaults.nowPlayingIOS27 = enabled

        let structural = UserDefaults.nowPlayingAnyLayout
        UserDefaults.nowPlayingBackdrop = structural
        UserDefaults.nowPlayingOneScreen = structural
        UserDefaults.hideSingalongLine = structural
        UserDefaults.hideNowPlayingPills = structural

        refreshNowPlayingBackdrop()
        NowPlayingOneScreen.reapply()
        NowPlayingPageOverlay.reapply()
        NowPlayingControlsPlate.reapply()

        // ⚠️ 这两层的顺序**开着与关着不一样**（写反了会互相覆盖 transform）：
        //   · 开：先让旧那层回滚（它会把封面缩回/写回 alpha），再让新层接管；
        //   · 关：先让新层还原（把封面 transform 写回原值），再让旧那层照它自己的开关铺上。
        if enabled {
            NowPlayingLyricsPlate.reapply()
            NowPlayingIOS27.reapply()
        } else {
            NowPlayingIOS27.reapply()
            NowPlayingLyricsPlate.reapply()
        }
        DeclutterChrome.reconcileNow()
    }

    /// 本页「重置本页」的作用范围。
    ///
    /// ★ 2026-10-30：沉浸式二级菜单删除后，`nowPlayingVolume` /
    /// `nowPlayingBlurUnplayedLyrics` / `nowPlayingControlGlyphs` 已从本页与 `ownedKeys` 移除；
    /// 罗马化 / 译文本来就不在本页重置（它们属于歌词页）。
    private static let ownedKeys = [
        // ★ 2026-10-23：新的「iOS 27 听歌页」。
        "nowPlayingIOS27",
        // ★ 2026-10-22：总开关 + 它写的那五颗旧键（总开关关掉时五颗一起写 false）。
        "nowPlayingLayout",
        "nowPlayingBackdrop",
        "nowPlayingOneScreen",
        "nowPlayingLyricsInPlayer",
        "hideMiniPlayerBar",
        "hideSingalongLine",
        "hideNowPlayingPills",
        // ★ 2026-10-17：从「首页与音乐库」搬来的两颗（传输条按钮）—— 它们的"当场落地"
        // 也是 `DeclutterChrome.reconcileNow()`，与上面几颗同一个 afterReset 分支。
        "hideConnectButton",
        "hideAddToButton",
    ]
    // 听歌页卡片那批（11 个键）由 `PlayerCard` / `PlayerCardsDeclutter` 自己拥有：
    // 加一张卡片只改那一处，这里跟着走 —— 本页的「重置本页」因此不会漏键。
    + PlayerCardsDeclutter.allKeys

    /// 某一张卡片的影子值绑定（键在 `PlayerCard.key`，值在 `Shadow.playerCards` 字典里）。
    private func cardBinding(_ card: PlayerCard) -> Binding<Bool> {
        Binding(
            get: { shadow.playerCards[card] ?? false },
            set: { shadow.playerCards[card] = $0 }
        )
    }
}
