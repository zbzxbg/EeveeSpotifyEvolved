import Foundation

// MARK: - Apple Music 官方 TTML 的账号令牌（`media-user-token`）
//
// ## 为什么这一路需要用户自己粘令牌实测结论）
//
// Apple 没有公开的歌词 API。三条端点实测下来只有一条需要登录态：
// · `GET https://amp-api.music.apple.com/v1/catalog/{sf}/search` —— 只要网页播放器的
// developer token（我们自动抓）就能用；
// · `GET .../songs/{id}/lyrics` 与 `.../syllable-lyrics` —— **未登录返回 404**；
// · `GET .../v1/me/storefront` —— 未登录/令牌无效返回 **403**。
// 所以歌词那一步必须有**用户自己的 Apple Music 登录态**（浏览器 Cookie
// `media-user-token`）。同类能跑的项目（`dropcreations/Manzana-Apple-Music-Lyrics`、
// `zhaarey/apple-music-downloader`）也是让用户从浏览器里粘这一个值。
//
// 我们**不内置**任何令牌：
// 1. 它是**账号级**的凭据（绑 Apple ID），泄露等于把账号的歌词权限借给别人；
// 2. 内置一份就等于"所有人的歌词都挂在同一个账号上"，那个号一失效全员坏，
// 而且的是"歌词源坏了"而不是"我该填令牌"。
//
// ## 怎么拿（设置页那句说明就是这段）
//
// 浏览器登录 <https://music.apple.com> → 开发者工具（F12）→ Application → Storage →
// Cookies → `https://music.apple.com` → 复制 `media-user-token` 的值。
// ⚠️ 两个前提：**有 Apple Music 账号**，并且（实测）**订阅才给歌词**。
extension UserDefaults {
    private static let appleMusicMediaUserTokenKey = "ngzhwm_appleMusicMediaUserToken"

    /// 设置 → 实验里粘的 `media-user-token`（空 = 没填）。
    static var appleMusicMediaUserToken: String {
        get {
            (container.string(forKey: appleMusicMediaUserTokenKey) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        set (token) {
            container.set(
                token.trimmingCharacters(in: .whitespacesAndNewlines),
                forKey: appleMusicMediaUserTokenKey
            )
        }
    }

    /// 填过令牌没有。判据只此一处（别在调用点各写一份 `isEmpty`）。
    static var hasAppleMusicMediaUserToken: Bool { !appleMusicMediaUserToken.isEmpty }
}
