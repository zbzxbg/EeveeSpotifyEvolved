import Foundation
import SwiftUI

/// 「锁屏歌词」页：正在唱的那一行接管锁屏的整屏封面，下一行在下面压暗。
///
/// 每一行只画一次、按曲缓存（`LockScreenLyrics`），所以换行不产生网络请求。
/// 取词用的是与页内歌词同一个歌词源；开关实时生效，不需要重启 Spotify。
///
/// 与「锁屏封面」拆成两页：见那一页的说明。
struct EeveeLockScreenLyricsSettingsView: View {

    /// 本页拥有的键（写属性名即可 —— 本仓库的键名与属性名同名）。
    private static let ownedKeys = [
        "lockScreenLyrics",
    ]

    @State private var lyricsEnabled = UserDefaults.lockScreenLyrics
    @State private var cacheBytes = LockScreenLyrics.totalBytes()
    @State private var cleared = false

    var body: some View {
        List {
            Section(
                header: Text("lock_screen_lyrics_title".localized),
                footer: Text("lock_screen_lyrics_description".localizeWithFormat("requires_ios26".localized))
            ) {
                Toggle("lock_screen_lyrics_enabled".localized, isOn: $lyricsEnabled)
                    .onChange(of: lyricsEnabled) { value in
                        UserDefaults.lockScreenLyrics = value
                        LockScreenLyricsController.shared.settingsDidChange()
                    }
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
                        cleared
                            ? "lock_screen_lyrics_cleared".localized
                            : "clear_button".localized
                    ) {
                        LockScreenLyricsController.shared.purgeCache()
                        cacheBytes = LockScreenLyrics.totalBytes()
                        cleared = true
                    }
                    .disabled(cacheBytes == 0)
                }
            }

            SettingsResetSection(
                keys: Self.ownedKeys,
                afterReset: {
                    lyricsEnabled = UserDefaults.lockScreenLyrics
                    LockScreenLyricsController.shared.settingsDidChange()
                }
            )
        }
        // inset-grouped（胶囊卡片）—— 与设置里其它页一致。
        .listStyle(InsetGroupedListStyle())
        .onAppear {
            // 备份导入 / 别处清过缓存：进页面重新量一次大小，并把"已清除"的按钮文案复位。
            lyricsEnabled = UserDefaults.lockScreenLyrics
            cacheBytes = LockScreenLyrics.totalBytes()
            cleared = false
        }
    }
}
