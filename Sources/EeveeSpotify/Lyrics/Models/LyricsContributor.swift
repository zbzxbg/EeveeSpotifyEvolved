import Foundation

/// 一条歌词署名里的贡献者（目前只有 Spicy Lyrics 的**社区同步**会带）。
///
/// ## 为什么是结构体，而不是只拼一个字符串
///
/// Spicy Lyrics 的服务条款把署名定成**使用条件**（§6，`/docs/attribution` 是条款的一部分）：
/// `source == "spicy_lyrics"` 时要 *"credit **and link** the uploader, and the maker where
/// one is given. Use the `url` on each contributor as the link target."*
///
/// 纯字符串在**注入给 Spotify 的 `providedBy`** 那条路上够用（那一行是纯文本、点不动），
/// 但在**我们自己画的页面**上必须能点 —— 所以名字与链接分开存。
///
/// ⚠️ 本文件**故意**保持 Foundation-only、不碰 `.localized`：
/// 它会被 CI（`Tests/SpicyLyricsJsonMapping`）直接编译。展示用的角色名在
/// `LyricsContributor+Display.swift` 里。
struct LyricsContributor: Equatable {

    enum Role: String {
        case uploader
        case maker

        /// l10n 键（与上游同名）。要显示的中文/英文在 `LyricsContributor+Display.swift`。
        var localizationKey: String {
            switch self {
            case .uploader: return "lyrics_uploaded_by"
            case .maker:    return "lyrics_made_by"
            }
        }
    }

    let role: Role
    let name: String
    /// contributor 自己的页面（条款要求用它当链接目标）。上游偶尔不给 ⇒ `nil`。
    let url: URL?
}
