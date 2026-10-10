import SwiftUI
import UIKit

struct EeveeUISettingsView: View {
    @State var lyricsColors = UserDefaults.lyricsColors

    // ★ 2026-10-13：主题（AMOLED 纯黑 + 强调色）。两颗都是**启动时读一次**，
    // 所以下面配了 `RestartSection`（改完出现「立即重启」）。
    @State private var amoledTheme = UserDefaults.amoledTheme
    @State private var accentRGB = UserDefaults.accentColorRGB

    var body: some View {
        List {
            // 主题：整页换色（Spotify 的 #121212 → 纯黑、品牌绿 → 你选的强调色）。
            // 机制在 `Sources/EeveeSpotifyC/ColorSwap.m`（颜色出生点换），说明见 `Theme`。
            Section(
                header: Text("theme_section".localized),
                footer: Text("theme_description".localized)
            ) {
                Toggle(
                    "amoled".localized,
                    isOn: Binding<Bool>(
                        get: { amoledTheme },
                        set: { amoledTheme = $0 }
                    )
                )
                .onChange(of: amoledTheme) { value in
                    UserDefaults.amoledTheme = value
                }

                HStack {
                    ColorPicker(
                        "accent_color".localized,
                        selection: Binding<Color>(
                            get: { Color(Theme.color(Theme.accentOrGreen(accentRGB))) },
                            set: { accentRGB = Theme.rgb(of: UIColor($0)) }
                        ),
                        supportsOpacity: false
                    )

                    // 设过强调色才显示还原键（`-1` = 不换色）。
                    if accentRGB >= 0 {
                        Button {
                            accentRGB = -1
                        } label: {
                            Image(systemName: "arrow.uturn.backward.circle.fill")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .onChange(of: accentRGB) { value in
                    UserDefaults.accentColorRGB = value
                }
            }

            RestartSection(
                visible: amoledTheme != Theme.launchAmoled || accentRGB != Theme.launchAccent
            )

            if UserDefaults.lyricsSource.isReplacingLyrics {
                Section(
                    header: Text("lyrics_background_color_section".localized),
                    footer: Text("lyrics_background_color_section_description".localized)
                ) {
                    Toggle(
                        "display_original_colors".localized,
                        isOn: $lyricsColors.displayOriginalColors
                    )
                    
                    Toggle(
                        "use_static_color".localized,
                        isOn: $lyricsColors.useStaticColor
                    )
                    
                    if lyricsColors.useStaticColor {
                        ColorPicker(
                            "static_color".localized,
                            selection: Binding<Color>(
                                get: { Color(hex: lyricsColors.staticColor) },
                                set: { lyricsColors.staticColor = $0.hexString }
                            ),
                            supportsOpacity: false
                        )
                    }
                    else {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("color_normalization_factor".localized)
                            
                            Slider(
                                value: $lyricsColors.normalizationFactor,
                                in: 0.2...0.8,
                                step: 0.1
                            )
                        }
                    }
                }
                .onChange(of: lyricsColors) { lyricsColors in
                    UserDefaults.lyricsColors = lyricsColors
                }
            }
            
            Section {
                // ⚠️ 2026-10-14 审计结论：这颗开关在 **Spotify 9.1.x 上点了没反应**。
                // 原因不在本页：`Tweak.x.swift` 的 9.1.x 分支在 `:782` 就 `return` 了，
                // 而唯一读它、唯一 activate 它的那两行在 `:789-791`（那个 return **之后**）
                // ⇒ `DarkPopUps` 这个组在 9.1.x 上从不激活（`DarkPopUps.x.swift`）。
                // 想让它真的生效，得把那两行挪进 v91 分支；但 `popUpContainerViewController`
                // 在 v91 下解析成 `UIView` 这条判据**没在真机上验过**，所以本次只记录、不改行为。
                // 详见 `.handoffs/AUDIT_2026-10-14_FEATURES.md`（A1）。
                Toggle(
                    "dark_popups".localized,
                    isOn: Binding<Bool>(
                        get: { UserDefaults.darkPopUps },
                        set: { UserDefaults.darkPopUps = $0 }
                    )
                )
            }
            
            SpacerView()
        }
        
                // ★ 2026-10-12：inset-grouped（胶囊卡片）—— 为什么、怎么做的见 `EeveeSettingsView` 顶部那段
        .listStyle(InsetGroupedListStyle())
        .animation(.default, value: lyricsColors)
    }
}
