import Foundation
import SwiftUI

/// 「锁屏动态封面」页。
///
/// 两颗开关的生效方式不一样，页脚分开写清楚：
/// · 总开关**实时生效**（hook 每次写 now-playing 时读它）；
/// · Canvas 那颗改的是 Spotify 的远端配置，**重启后**才生效。
struct EeveeLockScreenArtworkSettingsView: View {

    @State private var cacheBytes = AnimatedArtworkCache.totalBytes()
    @State private var didClear = false

    var body: some View {
        List {
            Section(footer: Text("lock_screen_artwork_description".localized)) {
                Toggle(
                    "lock_screen_artwork_enabled".localized,
                    isOn: Binding(
                        get: { UserDefaults.lockScreenAnimatedArtwork },
                        set: { UserDefaults.lockScreenAnimatedArtwork = $0 }
                    )
                )
            }

            Section(footer: Text("lock_screen_artwork_canvas_description".localized)) {
                Toggle(
                    "lock_screen_artwork_canvas".localized,
                    isOn: Binding(
                        get: { UserDefaults.lockScreenAnimatedArtworkCanvas },
                        set: { UserDefaults.lockScreenAnimatedArtworkCanvas = $0 }
                    )
                )
                .disabled(!UserDefaults.lockScreenAnimatedArtwork)
            }

            Section(footer: Text("lock_screen_artwork_fill_description".localized)) {
                Toggle(
                    "lock_screen_artwork_fill".localized,
                    isOn: Binding(
                        get: { UserDefaults.lockScreenAnimatedArtworkFill },
                        set: { UserDefaults.lockScreenAnimatedArtworkFill = $0 }
                    )
                )
                .disabled(!UserDefaults.lockScreenAnimatedArtwork)
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
                        didClear
                            ? "lock_screen_artwork_cleared".localized
                            : "lock_screen_artwork_clear".localized
                    ) {
                        AnimatedArtworkCache.clear()
                        cacheBytes = AnimatedArtworkCache.totalBytes()
                        didClear = true
                    }
                    .disabled(cacheBytes == 0)
                }
            }
        }
        // inset-grouped（胶囊卡片）—— 与设置里其它页一致。
        .listStyle(InsetGroupedListStyle())
        .onAppear {
            cacheBytes = AnimatedArtworkCache.totalBytes()
            didClear = false
        }
    }
}
