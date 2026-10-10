import SwiftUI
import UIKit

/// 「歌单与专辑页」——歌单封面与专辑/歌单页的"AM 化"。
///
/// 拆页背景见 `NowPlayingSettingsView` 的文件头。
///
/// 三节：
///   · `playlist_cover_section` —— 封面「四宫格 → 单张」；
///   · `entity_page_section` —— 取色底 + 封面下缘溶解 + 藏掉 Spotify 自带的那些按键；
///   · `entity_page_am_header_section` —— 自绘 AM 式页头。
///
/// ⚠️ ★ 2026-10-14（整合审计）：本页**不是一个"只管专辑/歌单页"的页**。
///   · `playlist_single_cover` 挂在图片请求层（`Appearance/PlaylistSingleCover.x.swift`），
///     凡是走 `mosaic.scdn.co` 的封面都被改 ⇒ **音乐库网格里的歌单封面、以及首页那几个模块**同样受影响
///     （该文件头 `:25` 自述"实体那条路（歌单页 / 音乐库）"，`:30-43` 还提到首页那三个模块）。
///     所以它是本仓库**唯一真正跨页**的开关，而它长在「歌单封面」这个小标题下、名字也只提歌单。
///   · `entity_page_am_header` 管的是**专辑 / 歌单 / 艺人三个页面**（hook 挂点见
///     `Appearance/EntityPageHeader.x.swift:1181-1189` 与 `:1193-1201`），不只是歌单页。
///   这两条是本页"该改名 / 该换分区 / 该写清影响面"的依据（文案在 l10n 里，用户要求先别动本地化文件）。
struct EntityPageSettingsView: View {

    @State private var shadow = Shadow()

    private struct Shadow {
        var playlistSingleCover = UserDefaults.playlistSingleCover
        var entityPageDissolve = UserDefaults.entityPageDissolve
        var entityPageHideChrome = UserDefaults.entityPageHideChrome
        var entityPageAMHeader = UserDefaults.entityPageAMHeader
    }

    var body: some View {
        List {
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
                    isOn: settingsShadowBinding($shadow.playlistSingleCover) { value in
                        UserDefaults.playlistSingleCover = value
                    }
                )
            }

            // ★ 2026-10-13（用户：「我就一个要求：**看起来像 Apple Music**」）：专辑页 / 歌单页的 AM 化。
            //   ① 取色底：页面最底层铺"封面取色 → 向下渐隐成 `#121212`"的竖直渐变
            //      （**必须先清掉 list / 每个 cell 画的 `#121212` 底色**，否则那层完全看不见 ——
            //       机制与证据见 `Appearance/EntityPageAppearance.x.swift` 文件头，与 pw 的 `AlbumField` 同路）；
            //   ② 封面下缘溶解：封面底部压一条渐变，让它"溶"进那片颜色（AM 的招牌动作）。
            //   ★ 2026-10-14 审计改正：本行原写「两颗各自独立、**默认都开**」，与代码不符 ——
            //     ① 取色底那条路径（老键 `entityPageField`，已删）已被并进 `entityPageDissolve`，
            //        且 `EntityPageAppearance.x.swift:317` 读的也是 `entityPageDissolve`
            //        ⇒ 用户侧只有一颗在管；
            //     ② `entityPageDissolve` 的默认值是 **false**（`UserDefaults+Extension.swift:813`）。
            //   ③ 另：打开它之后，"清掉 #121212 底色"（`EntityPageRepaint.x.swift:175`）与
            //      "状态栏字色翻转"（`EntityPageStatusBar.x.swift:183`）是**启动时**按开关决定装不装的
            //      ⇒ **要重启 Spotify 才完全生效**，而本页没有 RestartSection。
            Section(
                header: Text("entity_page_section".localized),
                footer: Text("entity_page_description".localized)
            ) {
                // ★ 2026-10-13（用户：「有些选项可以改改或者删掉了」）：这里原来还有一颗
                //   「封面取色底」—— 已经**并进下面这一颗**（两者本来就是同一件事的两半：
                //   都拿封面的颜色铺底），页面那一栏因此从**三颗减到两颗**。
                //   ★ 2026-10-14 收口：`entityPageField` 这个键**已删除** ——
                //   `EntityPageAppearance.x.swift:317` 读的也是 `entityPageDissolve`，
                //   且 `:173` 的 `isEnabled` 是整条入口的闸门，改回老键也救不回
                //   ⇒ 键、`UserDefaults.ownedKeys`、本页「重置本页」白名单三处已同步去掉。
                //
                //   ⚠️ 名字与内容不符（本次审计最值得改文案的一条）：这一颗内部其实装了
                //   **11 件事**，而且其中 1–8、10 是**有先后的流水线**（清原生底色 → 铺取色底 →
                //   文字反色 → 状态栏字色 → 模糊封面底 → veil → 下缘溶解 → 藏原生 wash），
                //   拆开只会让用户拼不出正确组合 ⇒ **不建议拆**。唯一有独立价值的是
                //   「艺人页照片铺满 + 顶部色带」（`EntityPageAppearance.x.swift:347` 的 `if sharp`
                //   分支，主体在 `ensureHero` / `ensureSharpHero` / `ensureScrim` 三处），
                //   将来若要拆，只拆这一件。
                //   而 zh 的标题说"替换Spotify的官方歌曲底色"、en 说的是"full-bleed cover
                //   dissolving into the page colour" —— 两种语言在说两件事，且都不全
                //   （footer 文案在 l10n 里，用户要求本地化文件先别动，故此处只记录）。
                Toggle(
                    "entity_page_dissolve".localized,
                    isOn: settingsShadowBinding($shadow.entityPageDissolve) { value in
                        UserDefaults.entityPageDissolve = value
                    }
                )
                // ★ 2026-10-13（用户看完真机）：「spotify 本身的那些按键都还在，**看起来不咋地**」
                //   ⇒ 每行的「+」「…」、头部的下载 / 加入 / 菜单 / 观看信息一律藏掉（AM 上没有它们）。
                //   **play / shuffle 不动** —— 那是真功能，AM 自己也有。
                //   ★ 2026-10-14：下面那颗「AM 式页头」默认开，而它**会自己重画这一批按钮**
                //   ⇒ 两者同时开时，本颗常常"看上去什么都没做"（AM 页头已经把那一列整列藏掉了）。
                //   所以 AM 页头开着时把本颗**置灰**，避免"点了没反应"的困惑。
                //   ⚠️ 置灰只是 UI 层，**键与行为都不变**（关掉 AM 页头后本颗的值照样生效）。
                Toggle(
                    "entity_page_hide_chrome".localized,
                    isOn: settingsShadowBinding($shadow.entityPageHideChrome) { value in
                        UserDefaults.entityPageHideChrome = value
                    }
                )
                .disabled(shadow.entityPageAMHeader)
            }

            // ★ 2026-10-13（用户：「我们的观感不好，我想让这些页面看起来像 Apple Music」）：
            //   把**页头**换成 AM 形态 —— 标题 / 创建者 / 长度居中，下面一行 shuffle + **白色 Play 胶囊**
            //   + 尾随按钮。做法与"为什么不是摆 Spotify 的控件"见 `Appearance/EntityPageHeader.swift`：
            //   Spotify 那一列**整列藏掉**（改 layer 的 hidden + 空 mask，一次钉死）、我们自己画，
            //   三颗按钮**镜像**它的字形并**转发**点击 ⇒ 动作/状态/语言都留在 Spotify 那边。
            //   **默认开**；★ 2026-10-14 更正：它管的是**三个页面**，不只是歌单页 ——
            //   专辑挂点与艺人挂点都真的装着（`Appearance/EntityPageHeader.x.swift:1181-1189`（专辑）、
            //   `:1193-1201`（艺人））。原先"v1 只作用于歌单页"的说法与 l10n 里的「(歌单)」都已过时。
            //   ⚠️ **关掉不可逆**：全仓没有 `eeveeReveal`、也没有把 `EntityPageHeaderView`
            //   `removeFromSuperview` 的路径 ⇒ 关掉之后 Spotify 原页头**不会**回来，
            //   要离开这一页再进（或重启 App）。这颗是本次审计里唯一"关掉回不去"的开关。
            Section(
                header: Text("entity_page_am_header_section".localized),
                footer: Text("entity_page_am_header_description".localized)
            ) {
                Toggle(
                    "entity_page_am_header".localized,
                    isOn: settingsShadowBinding($shadow.entityPageAMHeader) { value in
                        UserDefaults.entityPageAMHeader = value
                        // 页头是**启动时**装的那一组 hook（`EntityPageHeader`），开关值在**下一次进页面**时读到
                        // ⇒ 不需要当场落地。⚠️ 但"关"这一侧回不来（见上），别把它当可反复试的开关。
                    }
                )
            }

            // ⛔「顶部大标题」（旧"样品"开关）已于 2026-10-02 删除：
            // 壳自己会画顶栏标题（`header=ON` 时），那条是**另一套**标题 —— 两个都开就会画两遍。

            SettingsResetSection(
                keys: Self.ownedKeys,
                afterReset: {
                    shadow = Shadow()
                    // ★ 2026-10-14 更正（原注释写"这三颗都是下一次进那个页面时读一次"，不准确）：
                    //   · `entityPageDissolve` / `entityPageHideChrome`：页面在屏时由
                    //     `EntityPageAppearance` 的 0.6s 节拍**每拍重读**（`tick()`），
                    //     所以下一次节拍就落地 —— 但"清原生底色"（`EntityPageRepaint.x.swift:175`）
                    //     与"状态栏字色"（`EntityPageStatusBar.x.swift:183`）是**启动期** guard，
                    //     这两件要**重启 Spotify** 才跟着变；
                    //   · `entityPageAMHeader`：页头 hook 是启动时装的那一组，值在**下一次进页面**时读到；
                    //   · `playlistSingleCover`：挂在图片请求层，**下一次取图**生效（有缓存，可能要滚一下）。
                    //   ⇒ 重置后不强制刷新屏幕是对的，但"都要等下一次进页面"这个说法不对，已改。
                }
            )
        }
        .listStyle(InsetGroupedListStyle())
        .onAppear { shadow = Shadow() }
    }

    /// 本页「重置本页」的作用范围。
    ///
    /// ★ 2026-10-14：**删掉了 `entityPageField`**。它曾被称为"本页的隐藏半边"，但实测它
    /// **已经没有读取端**：`Appearance/EntityPageAppearance.x.swift:317` 那行读的是
    /// `entityPageDissolve`（和下一行同键），而且整条入口的闸门
    /// `EntityPageAppearance.isEnabled`（同文件 `:173`）读的也是 `entityPageDissolve`
    /// ⇒ 把那行改回 `entityPageField` 也救不回。所以它既不该留在重置白名单里、
    /// 也不该留在 `UserDefaults.ownedKeys` 里（两处已同步删除）。
    /// "只重置一半会留下怪状态"那条担心因此**不再成立**：现在三颗看得见的键就是全部。
    private static let ownedKeys = [
        "playlistSingleCover",
        "entityPageDissolve",
        "entityPageHideChrome",
        "entityPageAMHeader",
    ]
}
