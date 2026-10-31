import Foundation

/// 「听歌页样式」三态方案 A）。
///
/// ## 为什么合并
///
/// 原来这里是**两颗各自独立的 Toggle**（「修改Spotify听歌页布局」+「iOS 27 听歌页（满屏封面）」），
/// 而它们在落地代码里本来就是**互斥**的 —— `NowPlayingLyricsPlate.isEnabled` 里挂着
/// `!nowPlayingIOS27`，两颗同时打开时新那版静默让位。这与「首页顶部样式」
/// 那次是同一个教训（两颗 Toggle 互相打架 ⇒ 合成一个三态选择，见 `HomeHeaderStyle`），
/// 拍板照做。
///
/// ## 三档
///
/// | 选项 | 键 | 屏上看到的 |
/// | `.spotify` | 两个键都 false | Spotify 默认听歌页 |
/// | `.immersive` | `nowPlayingLayout = true`、`nowPlayingIOS27 = false` | 整页取色底 + 藏官方模块/单行歌词/两颗胶囊 + 歌词进播放器 |
/// | `.appleMusic` | `nowPlayingIOS27 = true`（`nowPlayingLayout` 的值**被忽略**） | 封面铺满上半屏、歌名压在封面下沿的过渡带，照 iOS 27 的 Apple Music 做的那一版 |
///
/// 「听歌页样式那里，默认改成 Apple Music」⇒ `nowPlayingIOS27` 的
/// 默认值改为 `true`，新装/没动过这颗键的用户直接落在 `.appleMusic`。
///
/// ## 纪律
///
/// * **不新增存储键**：底下的 `nowPlayingLayout` / `nowPlayingIOS27` 保持原样，
/// 备份 / 导入 / 日志 / `normalizeNowPlayingLayoutKeys` 全都不受影响，也不需要写迁移
/// （与 `HomeHeaderStyle` 用 `homeLargeTitle` + `hideHomeHeader` 推出三态是同一做法）。
/// * 取值的**唯一真相仍在那两个键上**（`UserDefaults.nowPlayingStyle` 只是推导），
/// 所以设置页的 Picker、备份、日志永远说的是同一件事。
/// * 选项名不带版本号（iOS 27只留在说明文字里，
/// 明年系统换代时不用改选项名。
enum NowPlayingStyle: Int, CaseIterable, Hashable {

    /// Spotify 默认。
    case spotify
    /// 旧那套（原「修改Spotify听歌页布局」总开关）：整页取色底 + 歌词进播放器。
    case immersive
    /// 新那套（原「iOS 27 听歌页」）：满屏封面 + AM 的控制条。
    case appleMusic

    /// 显示名的 l10n 键。
    ///
    /// ⚠️ 写成键、由视图调 `.localized`（而不是在这里直接翻）—— `Tools/l10n_lint.py` 只认
    /// 「字面量直接跟 `.localized`」的形状；在 enum 里翻会让这三个键被误报成未使用。
    var titleKey: String {
        switch self {
        case .spotify:
            return "now_playing_style_spotify"
        case .immersive:
            return "now_playing_style_immersive"
        case .appleMusic:
            return "now_playing_style_apple_music"
        }
    }
}

extension UserDefaults {

    /// 当前听歌页样式 —— **从原来那两个键推出来**（见 `NowPlayingStyle` 的"纪律"）。
    ///
    /// 优先级：`nowPlayingIOS27` 开着就是 `.appleMusic`（此时旧总开关的值被忽略，
    /// 与落地代码里 `NowPlayingLyricsPlate.isEnabled` 那道门一致）。
    static var nowPlayingStyle: NowPlayingStyle {
        if nowPlayingIOS27 { return .appleMusic }
        if nowPlayingLayout { return .immersive }
        return .spotify
    }
}
