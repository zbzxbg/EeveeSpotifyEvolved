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

/// 拼一条**显示用**的署名：提供商 + 社区贡献者，形如 `Spicy Lyrics · 上传者 X · 制作者 Y`。
///
/// 自绘歌词页的**页脚**用这一份（那一页没有歌手行，提供商必须自己写出来）。
///
/// 读的是全局状态（`currentLyricsProvider` / `currentLyricsContributors`），
/// 它们与"当前渲染的那份 dto"同源同时刻写入（见 `CustomLyrics.storeLyricsDto`）。
func currentLyricsCreditText() -> String {
    lyricsCreditText()
}

/// 听歌页歌词区**底沿那行**专用的署名文本（`NowPlayingLyricsPlate.ensureCreditLabel` 用）。
///
/// ★ 2026-10-13（用户拍板「方案 1」）：**这一行不再重复提供商**。
///
/// 为什么：提供商的名字已经贴在**歌手那一行**了（`NowPlayingLyricsPlate.providerSuffix()`
/// → `歌手（Spicy Lyrics）`，那是用户特意选的位置）⇒ 底沿再写一遍只是视觉重复。
/// 条款 §6 要的两件事在两行里各占一半，仍然都在屏幕上：
///   · *"Always name the provider"* → 歌手那一行；
///   · *"credit **and link** the uploader, and the maker"* → **这一行**（可点，
///     链接见 `NowPlayingLyricsPlate.creditLinks()`）。
///
/// 所以这一行的形态是：
///   · 有社区署名 → `上传者 X · 制作者 Y`；
///   · 没有社区署名、且提供商是 Spicy Lyrics → 那句彩蛋 `Thx,Spicy Lyrics!`（用户要的）；
///   · 没有社区署名、且是别的源 → **空**（整条不出现：那些源本来也没有 uploader/maker
///     可署，而提供商在歌手行上）。
///
/// ⚠️ 自绘歌词页页脚走的是**不带这层规则**的 `currentLyricsCreditText()`。
func currentLyricsPlateCreditText() -> String {
    let roles = lyricsRoleText()
    if !roles.isEmpty { return roles }

    let provider = currentLyricsProvider.trimmingCharacters(in: .whitespacesAndNewlines)
    return provider == SpicyLyricsAttribution.providerName ? SpicyLyricsAttribution.plateEasterEgg : ""
}

/// 「上传者 X · 制作者 Y」这一半（没有社区署名时是空串）。
///
/// 单独抽出来是因为它现在有两个去处：完整署名（`lyricsCreditText`）与底沿那条
/// （`currentLyricsPlateCreditText`）—— 两处各拼一份的话，将来条款相关的措辞只会改一处。
private func lyricsRoleText() -> String {
    currentLyricsContributors
        .map { $0.role.label + " " + $0.name }
        .joined(separator: " · ")
}

/// 上面两个入口共用的拼接。
///
/// - Parameter providerOverride: 覆盖"提供商"那一节的显示文本（nil = 用 `currentLyricsProvider`）。
private func lyricsCreditText(providerOverride: String? = nil) -> String {
    var parts: [String] = []

    let provider = (providerOverride ?? currentLyricsProvider)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    if !provider.isEmpty { parts.append(provider) }

    let roles = lyricsRoleText()
    if !roles.isEmpty { parts.append(roles) }

    return parts.joined(separator: " · ")
}
