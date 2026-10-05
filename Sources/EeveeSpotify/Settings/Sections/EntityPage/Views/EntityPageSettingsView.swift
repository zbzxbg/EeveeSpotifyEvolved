import SwiftUI
import UIKit

/// 「歌单与专辑页」——歌单封面与专辑/歌单页的"AM 化"。
///
/// 拆页背景见 `NowPlayingSettingsView` 的文件头。
///
/// 两节：
///   · `playlist_cover_section` —— 封面「四宫格 → 单张」；
///   · `entity_page_section` —— 取色底 + 封面下缘溶解 + 藏掉 Spotify 自带的那些按键。
struct EntityPageSettingsView: View {

    @State private var shadow = Shadow()

    private struct Shadow {
        var playlistSingleCover = UserDefaults.playlistSingleCover
        var entityPageDissolve = UserDefaults.entityPageDissolve
        var entityPageHideChrome = UserDefaults.entityPageHideChrome
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
            //   两颗各自独立、**默认都开**；关掉即完全还原（清过的底色逐个写回原色）。
            Section(
                header: Text("entity_page_section".localized),
                footer: Text("entity_page_description".localized)
            ) {
                // ★ 2026-10-13（用户：「有些选项可以改改或者删掉了」）：这里原来还有一颗
                //   「封面取色底」—— 已经**并进下面这一颗**（两者本来就是同一件事的两半：
                //   都拿封面的颜色铺底），页面那一栏因此从**三颗减到两颗**。
                //   代码里"整页取色底"与"模糊封面底"两条路径仍各管各的（排查时能只关一半）。
                Toggle(
                    "entity_page_dissolve".localized,
                    isOn: settingsShadowBinding($shadow.entityPageDissolve) { value in
                        UserDefaults.entityPageDissolve = value
                    }
                )
                // ★ 2026-10-13（用户看完真机）：「spotify 本身的那些按键都还在，**看起来不咋地**」
                //   ⇒ 每行的「+」「…」、头部的下载 / 加入 / 菜单 / 观看信息一律藏掉（AM 上没有它们）。
                //   **play / shuffle 不动** —— 那是真功能，AM 自己也有。
                Toggle(
                    "entity_page_hide_chrome".localized,
                    isOn: settingsShadowBinding($shadow.entityPageHideChrome) { value in
                        UserDefaults.entityPageHideChrome = value
                    }
                )
            }

            // ⛔「顶部大标题」（旧"样品"开关）已于 2026-10-02 删除：
            // 壳自己会画顶栏标题（`header=ON` 时），那条是**另一套**标题 —— 两个都开就会画两遍。

            SettingsResetSection(
                keys: Self.ownedKeys,
                afterReset: {
                    shadow = Shadow()
                    // 这三颗都是"下一次进那个页面时读一次"的语义（原页也没有当场落地），
                    // 所以重置后不需要额外把状态推回屏幕。
                }
            )
        }
        .listStyle(InsetGroupedListStyle())
        .onAppear { shadow = Shadow() }
    }

    private static let ownedKeys = [
        "playlistSingleCover",
        "entityPageField",
        "entityPageDissolve",
        "entityPageHideChrome",
    ]
}
