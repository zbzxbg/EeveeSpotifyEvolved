import Foundation
import SwiftUI

/// 「锁屏歌词」页。
///
/// 一颗开关 + 缓存。开关**实时生效**：调度器每次写 now-playing 前都会重读它
/// （见 `LockScreenLyricsController`），不需要重启；短片的缓存按"每首一个目录"清。
struct EeveeLockScreenLyricsSettingsView: View {

    @State private var cacheBytes = LockScreenLyrics.totalBytes()
    @State private var didClear = false

    var body: some View {
        List {
            Section(footer: Text("lock_screen_lyrics_description".localized)) {
                Toggle(
                    "lock_screen_lyrics_enabled".localized,
                    isOn: Binding(
                        get: { UserDefaults.lockScreenLyrics },
                        set: { UserDefaults.lockScreenLyrics = $0 }
                    )
                )
            }

            Section(header: Text("lock_screen_lyrics_cache".localized)) {
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
                            ? "lock_screen_lyrics_cleared".localized
                            : "lock_screen_lyrics_clear".localized
                    ) {
                        LockScreenLyrics.clearCache()
                        cacheBytes = LockScreenLyrics.totalBytes()
                        didClear = true
                    }
                    .disabled(cacheBytes == 0)
                }
            }
        }
        // inset-grouped（胶囊卡片）—— 与设置里其它页一致。
        .listStyle(InsetGroupedListStyle())
        .onAppear {
            cacheBytes = LockScreenLyrics.totalBytes()
            didClear = false
        }
    }
}
