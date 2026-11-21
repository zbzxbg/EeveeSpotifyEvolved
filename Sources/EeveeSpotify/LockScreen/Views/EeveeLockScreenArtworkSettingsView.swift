import Foundation
import SwiftUI

/// 「锁屏封面」页：now-playing 的封面换成一段循环短片（iOS 26+）。
///
/// 三颗开关 + 一份缓存：
/// · **动态封面**：总开关，实时生效（注入器每次写 now-playing 时重读）；
/// · **Canvas**：用 Spotify 的 Canvas 当片源，改的是远端配置，**重启后**才生效；
/// · **本地渲染**：Canvas 与 Apple Music 都拿不到时才用封面自己生成一段，兜底用；
/// · **已下载缓存**：按"每首一个目录"存，与锁屏歌词的剪辑缓存互不影响。
///
/// 与「锁屏歌词」拆成两页：同一块屏幕上，但一个换的是封面、一个是把歌词画成新封面，
/// 生效链路和缓存都不同，合并只会让两边都变长。
struct EeveeLockScreenArtworkSettingsView: View {

    /// 本页拥有的键（写属性名即可 —— 本仓库的键名与属性名同名）。
    private static let ownedKeys = [
        "lockScreenAnimatedArtwork",
        "lockScreenAnimatedArtworkCanvas",
        "lockScreenAnimatedArtworkFill",
    ]

    @State private var artworkEnabled = UserDefaults.lockScreenAnimatedArtwork
    @State private var canvasEnabled = UserDefaults.lockScreenAnimatedArtworkCanvas
    @State private var fillEnabled = UserDefaults.lockScreenAnimatedArtworkFill
    @State private var cacheBytes = AnimatedArtworkCache.totalBytes()
    @State private var cleared = false

    var body: some View {
        List {
            Section(
                header: Text("lock_screen_artwork_title".localized),
                footer: Text("lock_screen_artwork_description".localized)
            ) {
                Toggle("lock_screen_artwork_enabled".localized, isOn: $artworkEnabled)
                    .onChange(of: artworkEnabled) { value in
                        UserDefaults.lockScreenAnimatedArtwork = value
                    }
            }

            Section(footer: Text("lock_screen_artwork_canvas_description".localized)) {
                Toggle("lock_screen_artwork_canvas".localized, isOn: $canvasEnabled)
                    .onChange(of: canvasEnabled) { value in
                        UserDefaults.lockScreenAnimatedArtworkCanvas = value
                    }
                    .disabled(!artworkEnabled)
            }

            Section(footer: Text("lock_screen_artwork_fill_description".localized)) {
                Toggle("lock_screen_artwork_fill".localized, isOn: $fillEnabled)
                    .onChange(of: fillEnabled) { value in
                        UserDefaults.lockScreenAnimatedArtworkFill = value
                    }
                    .disabled(!artworkEnabled)
            }

            Section(header: Text("lock_screen_artwork_cache".localized)) {
                HStack {
                    Text(
                        ByteCountFormatter.string(
                            fromByteCount: cacheBytes,
                            countStyle: .file
                        )
                    )
                    .foregroundColor(.secondary)

                    Spacer()

                    Button(
                        cleared
                            ? "lock_screen_artwork_cleared".localized
                            : "lock_screen_artwork_clear".localized
                    ) {
                        AnimatedArtworkCache.clear()
                        cacheBytes = AnimatedArtworkCache.totalBytes()
                        cleared = true
                    }
                    .disabled(cacheBytes == 0)
                }
            }

            SettingsResetSection(
                keys: Self.ownedKeys,
                afterReset: {
                    artworkEnabled = UserDefaults.lockScreenAnimatedArtwork
                    canvasEnabled = UserDefaults.lockScreenAnimatedArtworkCanvas
                    fillEnabled = UserDefaults.lockScreenAnimatedArtworkFill
                }
            )
        }
        // inset-grouped（胶囊卡片）—— 与设置里其它页一致。
        .listStyle(InsetGroupedListStyle())
        .onAppear {
            // 备份导入 / 别处清过缓存：进页面重新量一次大小，并把"已清除"的按钮文案复位。
            artworkEnabled = UserDefaults.lockScreenAnimatedArtwork
            canvasEnabled = UserDefaults.lockScreenAnimatedArtworkCanvas
            fillEnabled = UserDefaults.lockScreenAnimatedArtworkFill
            cacheBytes = AnimatedArtworkCache.totalBytes()
            cleared = false
        }
    }
}
