import Foundation

/// 四个选项对应 `ArtistBioSheet` 里那条取值链：
///
/// | 选项 | 取值 | 代价 |
/// | `.automatic`（**默认**） | **Spotify 原生优先**（跟着 app 语言、不联网），读不到才退 Genius | 原生那份可能被截断（读的是界面上的文字） |
/// | `.spotify` | 只用原生 | 读不到就只剩一句说明 + 维基百科链接 |
/// | `.genius` | 只用 Genius | **英文**；卡片要署名「简介来自 Genius」 |
/// | `.wikipedia` | 只用维基百科**首段** | **CC BY-SA** ⇒ 卡片要署名「来自维基百科 · CC BY-SA」+ 许可链接；日系独立艺人命中率低 |
///
/// 为什么默认 `.automatic`：原生那份是**唯一跟着 app 语言**的（Genius 基本是英文、维基对我们常听的那批
/// 日系独立艺人常常没有条目），而且它**不联网** ✓。
///
/// ⚠️ 与 `LyricsSource` 同一条纪律：**新分支只往末尾加**（`rawValue` 会进 UserDefaults，
/// 改了会让已存设置错位）。
enum ArtistBioSourceKind: Int, CaseIterable, CustomStringConvertible {

    case automatic
    case spotify
    case genius
    case wikipedia

    var description: String {
        switch self {
        case .automatic:
            return "artist_bio_source_automatic".localized
        case .spotify:
            // 专有名词，不本地化（与 `LyricsSource` 里的 `Genius` / `LRCLIB` 一样）。
            return "Spotify"
        case .genius:
            return "Genius"
        case .wikipedia:
            return "Wikipedia"
        }
    }

    /// 这个选项要不要**读 Spotify 原生那一块**（`automatic` / `spotify` 要）。
    ///
    /// ⚠️ 这**不是**"要不要滚到「关于艺人」那一块"：那一块是懒加载的，只有用户自己滑到它才建得出来
    /// **与来源选择无关**。
    var readsSpotifyNative: Bool { self == .automatic || self == .spotify }
}

extension UserDefaults {
    private static let artistBioSourceKey = "artistBioSource"

    /// 见 `ArtistBioSourceKind`。缺省 = `.automatic`（没有这个键时**不写盘**，读出来就是默认值 ——
    /// 与 `lyricsSource` 同一条做法）。
    static var artistBioSource: ArtistBioSourceKind {
        get {
            if let raw = container.object(forKey: artistBioSourceKey) as? Int,
               let kind = ArtistBioSourceKind(rawValue: raw) {
                return kind
            }
            return .automatic
        }
        set (kind) {
            container.set(kind.rawValue, forKey: artistBioSourceKey)
        }
    }
}
