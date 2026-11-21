import Foundation

/// 「听歌页样式」两态。
///
/// ## 历史：三档 → 两档
///
/// 这里原来有三档：`.spotify` / `.immersive` / `.appleMusic`。**沉浸式已删除。**
///
/// 沉浸式是旧总开关 `nowPlayingLayout` 那一套（版式照 kumone：标题在顶、封面居中、
/// 歌词占封面区）。它和 AM 档在落地代码里本来就互斥（`NowPlayingLyricsPlate.isEnabled`
/// 里挂着 `!nowPlayingIOS27`），而且从来不是默认选中的那一档 ⇒ 实际上只剩
/// "一套没人维护的档位 + 一批只在它下面生效的条件"。删掉它之后，用户盘上
/// `nowPlayingLayout = true`、`nowPlayingIOS27 = false` 的存量由
/// `normalizeNowPlayingLayoutKeys()` 迁到 `.appleMusic`。
///
/// ## 两档
///
/// | 选项 | 键 | 屏上看到的 |
/// |---|---|---|
/// | `.spotify` | `nowPlayingIOS27 = false` | Spotify 默认听歌页 |
/// | `.appleMusic` | `nowPlayingIOS27 = true` | 封面铺满上半屏、歌名压在封面下沿的过渡带 |
///
/// 两档**共用**的结构件（取色底 / 一屏 / 隐藏官方单行歌词 / 两颗胶囊）仍然看
/// `nowPlayingAnyLayout`，不随这道选择器变化。
///
/// ⚠️ 播客 / 有声书**不受这道选择影响**：Apple Music 式的几何是按音乐页算的，播客那行
/// 控件更多 ⇒ `NowPlayingPodcastFallback` 判出来之后整层让位回 Spotify 自己的布局。
///
/// ## 纪律
///
/// * **不新增存储键**：真值仍然只在 `nowPlayingIOS27` 上，`nowPlayingStyle` 只是推导。
/// * 设置页 Picker、备份、日志说的永远是同一件事。
enum NowPlayingStyle: Int, CaseIterable, Hashable {

    /// Spotify 默认。
    case spotify
    /// 封面铺满上半屏 + AM 的控制条（原来叫「iOS 27 听歌页」）。
    case appleMusic

    /// 显示名的 l10n 键。
    ///
    /// ⚠️ 写成键、由视图调 `.localized`（而不是在这里直接翻）—— `Tools/l10n_lint.py` 只认
    /// 「字面量直接跟 `.localized`」的形状；在 enum 里翻会让这两个键被误报成未使用。
    var titleKey: String {
        switch self {
        case .spotify:
            return "now_playing_style_spotify"
        case .appleMusic:
            return "now_playing_style_apple_music"
        }
    }
}

extension UserDefaults {

    /// 当前听歌页样式 —— **从 `nowPlayingIOS27` 推出来**（见 `NowPlayingStyle` 的"纪律"）。
    static var nowPlayingStyle: NowPlayingStyle {
        nowPlayingIOS27 ? .appleMusic : .spotify
    }
}
