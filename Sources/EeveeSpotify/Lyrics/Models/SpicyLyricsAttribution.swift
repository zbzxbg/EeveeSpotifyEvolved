import Foundation

/// Spicy Lyrics 的**署名规则**（服务条款 §6 里可机器化的那一半）。
///
/// ## 为什么单开一个文件
///
/// 它是"条款合规"里最容易悄悄改坏的一块（哪个 `source` 要署谁、URL 取哪个字段、
/// 没有 `source` 时说什么），而它原来住的 `SpicyLyricsRepository` 带一堆仓库依赖
/// （`LyricsDto` / `writeDebugLog` / `LyricsUncensorFill`…），**进不了 CI**。
/// 放成 Foundation-only 之后，`Tests/SpicyLyricsJsonMapping` 就能直接编译它并用
/// **真实响应的形状**钉住行为。
///
/// ⚠️ 这个文件**不许**引入 `.localized`（那会把 `String+Extension` 拖进来，
/// 而它带着 UIKit）。需要展示的角色名在 `LyricsContributor+Display.swift` 里。
enum SpicyLyricsAttribution {

    /// `/docs/attribution` 里那个"回答的 provider"。
    static let providerName = "Spicy Lyrics"

    /// 署名的 provider 那一环点它。
    static let providerURL = URL(string: "https://spicylyrics.org")

    /// 从响应的 `UploadAttribution` 取贡献者（`Maker` / `Uploader`）。
    ///
    /// 条款 §6 要的是 *"credit **and link** the uploader, and the maker where one is given.
    /// Use the `url` on each contributor as the link target."*
    /// 所以 `username` 用来显示、`url` 用来当点击目标（实测形如 `https://spicylyrics.org/uid/…`）。
    ///
    /// 上游偶尔只给其一 ⇒ **缺什么就少什么，不编造**；`apple_music` / `spotify` 两个商业源
    /// 根本没有这个节点，本来就该只有 provider。
    static func contributors(attribution: SLObjPackValue?) -> [LyricsContributor] {
        var result: [LyricsContributor] = []

        func append(_ node: SLObjPackValue?, role: LyricsContributor.Role) {
            guard let node = node else { return }
            let name = node["username"]?.stringValue ?? ""
            guard !name.isEmpty else { return }
            let raw = node["url"]?.stringValue ?? ""
            // 只认 http(s)：这个地址会被 `UIApplication.open` 直接打开，
            // 上游给什么就开什么是错的。
            let url = URL(string: raw).flatMap { candidate -> URL? in
                guard let scheme = candidate.scheme?.lowercased(),
                      scheme == "https" || scheme == "http" else { return nil }
                return candidate
            }
            result.append(LyricsContributor(role: role, name: name, url: url))
        }

        append(attribution?["Maker"], role: .maker)
        append(attribution?["Uploader"], role: .uploader)
        return result
    }
}
