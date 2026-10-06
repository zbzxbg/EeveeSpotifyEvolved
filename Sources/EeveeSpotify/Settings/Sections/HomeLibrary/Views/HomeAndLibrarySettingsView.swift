import SwiftUI
import UIKit

/// 「首页与音乐库」——首页 / 音乐库两页的"AM 化"（大标题贴左 + 收掉灰纱），
/// 外加首页与播放器上那几颗 Spotify 自己的 chrome 的藏与放。
///
/// 拆页背景见 `NowPlayingSettingsView` 的文件头。
///
/// ⚠️ 中间那一节的标题是 `declutter_home_player_section`（"Home and player"）：三颗开关里
///    `hide_connect_button` / `hide_add_to_button` 其实管的是**听歌页**上那两颗键
///    （设备联动、收藏）。它们最初就是与 `hide_home_header` 一起加的，l10n 也只有这一个
///    分节标题可用 ⇒ 保持原样成组放在这里，不为了排版好看去拆散它们（拆了要么新造键、
///    要么让那两句已翻译的文案变成孤儿）。
struct HomeAndLibrarySettingsView: View {

    @State private var shadow = Shadow()

    private struct Shadow {
        var hideHomeHeader = UserDefaults.hideHomeHeader
        var hideConnectButton = UserDefaults.hideConnectButton
        var hideAddToButton = UserDefaults.hideAddToButton
        var libraryLargeTitle = UserDefaults.libraryLargeTitle
        var homeLargeTitle = UserDefaults.homeLargeTitle
        var homeTileTint = UserDefaults.homeTileTint
    }

    var body: some View {
        List {
            Section(
                header: Text("declutter_home_player_section".localized),
                footer: Text("declutter_home_player_description".localized)
            ) {
                Toggle(
                    "hide_home_header".localized,
                    isOn: settingsShadowBinding($shadow.hideHomeHeader) { value in
                        UserDefaults.hideHomeHeader = value
                        // 藏过的 chrome 不一定再有 layout 回合 ⇒ 当场复查一遍（见 `DeclutterChrome`）。
                        DeclutterChrome.reconcileNow()
                    }
                )

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

            // 音乐库：**改原生**的第一批（不是加壳）—— 大标题左对齐 + 收掉顶部渐隐灰纱。
            Section(
                header: Text("library_section".localized),
                footer: Text("library_large_title_description".localized)
            ) {
                Toggle(
                    "library_large_title".localized,
                    isOn: settingsShadowBinding($shadow.libraryLargeTitle) { value in
                        UserDefaults.libraryLargeTitle = value
                    }
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
                    isOn: settingsShadowBinding($shadow.homeLargeTitle) { value in
                        UserDefaults.homeLargeTitle = value
                    }
                )
            }

            // ★ 2026-10-13（用户看 pw 的截图：「那几个小模块是经过处理的（喜欢的歌曲那几个小方框），
            //   底部的颜色会跟着封面的样子跑」）：把那排小卡片的底色改成**从它自己的封面取色**
            //   （普通 Spotify 那边这几格是一片灰）。出处 spoti.pw **v0.21.1** 的
            //   `Redesigned/Home/HomeTiles.m`（GPL-3.0）："a dark surface tinted faintly towards
            //   the cover's dominant colour"。做法、认形状的判据与"为什么这次是靠日志而不是转储"
            //   见 `Appearance/HomeShortcutTiles.x.swift` 文件头。
            Section(
                header: Text("home_tile_tint_section".localized),
                footer: Text("home_tile_tint_description".localized)
            ) {
                Toggle(
                    "home_tile_tint".localized,
                    isOn: settingsShadowBinding($shadow.homeTileTint) { value in
                        // "下一次布局生效"的语义（卡片自己那一拍会读到它）⇒ 不需要当场落地。
                        UserDefaults.homeTileTint = value
                    }
                )
            }

            SettingsResetSection(
                keys: Self.ownedKeys,
                afterReset: {
                    shadow = Shadow()
                    // 大标题那两颗是"下一次布局生效"（原页也没有当场落地），
                    // 需要当场复查的只有 `DeclutterChrome` 管的那三颗。
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
