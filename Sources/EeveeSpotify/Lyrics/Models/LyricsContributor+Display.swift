import Foundation

// MARK: - 署名里"要显示的那一半"
//
// 为什么与 `LyricsContributor.swift` 分开：那个文件是 Foundation-only、要被 CI 直接编译
// （见它文件头的说明），而这里的角色名要 `String.localized`（那把 `String+Extension`
// 及其 UIKit 依赖拖进来），两边诉求冲突，所以拆开。

extension LyricsContributor.Role {
    /// 展示用角色名（`上传者` / `制作者`）。l10n 键与上游同名。
    var label: String { localizationKey.localized }
}

/// 一条**显示用**的署名：短名 + 社区贡献者，形如 `Spicy Lyrics · 上传者 X · 制作者 Y`。
///
/// 听歌页歌词区底沿那条（`NowPlayingLyricsPlate`）与自绘歌词页页脚（`AppleMusicLyricsPage`）
/// **共用这一份** —— 两处各拼一份的话，将来条款相关的那半只会有一处跟着改。
///
/// 读的是全局状态（`currentLyricsProvider` / `currentLyricsContributors`），
/// 它们与"当前渲染的那份 dto"同源同时刻写入（见 `CustomLyrics.storeLyricsDto`）。
func currentLyricsCreditText() -> String {
    var parts: [String] = []
    let provider = currentLyricsProvider.trimmingCharacters(in: .whitespacesAndNewlines)
    if !provider.isEmpty { parts.append(provider) }
    for contributor in currentLyricsContributors {
        parts.append(contributor.role.label + " " + contributor.name)
    }
    return parts.joined(separator: " · ")
}
