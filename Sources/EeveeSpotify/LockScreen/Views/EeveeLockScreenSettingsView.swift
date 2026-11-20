import Foundation
import SwiftUI

/// 「锁屏」页：动态封面与锁屏歌词是同一条锁屏链上的两件事，所以合成一页。
///
/// 六节：封面四节（总开关 / Canvas / 本地渲染 / 已下载缓存）+ 歌词两节（开关 / 已渲染剪辑）。
///
/// 生效方式不一样，页脚各自写清楚：
/// · 封面与歌词的总开关**实时生效**（注入器每次写 now-playing 时重读）；
/// · Canvas 那颗改的是 Spotify 的远端配置，**重启后**才生效；
/// · 本地渲染那颗只在 Canvas 与 Apple Music 都拿不到动态封面时兜底
///   （见 `AnimatedArtworkSources`）。
///
/// 两份缓存各自独立：都按"每首一个目录"存，清一份不会动另一份。
struct EeveeLockScreenSettingsView: View {

    @State private var artworkCacheBytes = AnimatedArtworkCache.totalBytes()
    @State private var artworkCleared = false
    @State private var lyricsCacheBytes = LockScreenLyrics.totalBytes()
    @State private var lyricsCleared = false

    var body: some View {
        List {
            // ── 封面：总开关 + Canvas + 本地渲染 + 缓存
            Section(
                header: Text("lock_screen_artwork_title".localized),
                footer: Text("lock_screen_artwork_description".localized)
            ) {
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
                            fromByteCount: artworkCacheBytes,
                            countStyle: .file
                        )
                    )
                    .foregroundColor(.secondary)

                    Spacer()

                    Button(
                        artworkCleared
                            ? "lock_screen_artwork_cleared".localized
                            : "lock_screen_artwork_clear".localized
                    ) {
                        AnimatedArtworkCache.clear()
                        artworkCacheBytes = AnimatedArtworkCache.totalBytes()
                        artworkCleared = true
                    }
                    .disabled(artworkCacheBytes == 0)
                }
            }

            // ── 歌词：开关 + 缓存
            Section(
                header: Text("lock_screen_lyrics_title".localized),
                footer: Text("lock_screen_lyrics_description".localized)
            ) {
                Toggle(
                    "lock_screen_lyrics_enabled".localized,
                    isOn: Binding(
                        get: { UserDefaults.lockScreenLyrics },
                        set: { value in
                            UserDefaults.lockScreenLyrics = value
                            LockScreenLyricsController.shared.settingsDidChange()
                        }
                    )
                )
            }

            Section(header: Text("lock_screen_lyrics_cache".localized)) {
                HStack {
                    Text(
                        ByteCountFormatter.string(
                            fromByteCount: lyricsCacheBytes,
                            countStyle: .file
                        )
                    )
                    .foregroundColor(.secondary)

                    Spacer()

                    Button(
                        lyricsCleared
                            ? "lock_screen_lyrics_cleared".localized
                            : "lock_screen_lyrics_clear".localized
                    ) {
                        LockScreenLyricsController.shared.purgeCache()
                        lyricsCacheBytes = LockScreenLyrics.totalBytes()
                        lyricsCleared = true
                    }
                    .disabled(lyricsCacheBytes == 0)
                }
            }
        }
        // inset-grouped（胶囊卡片）—— 与设置里其它页一致。
        .listStyle(InsetGroupedListStyle())
        .onAppear {
            // 备份导入 / 别处清过缓存：进页面重新量一次大小，并把"已清除"的按钮文案复位。
            refreshCacheSizes()
            artworkCleared = false
            lyricsCleared = false
        }
    }

    /// 两份缓存的大小（`ByteCountFormatter` 用的是十进制单位，与设置里其它缓存行一致）。
    private func refreshCacheSizes() {
        artworkCacheBytes = AnimatedArtworkCache.totalBytes()
        lyricsCacheBytes = LockScreenLyrics.totalBytes()
    }
}
