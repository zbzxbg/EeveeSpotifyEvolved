/// 一个 GitHub release。
///
/// ⚠️ 除 `tagName` 之外**全部可选**：版本检查（`GitHubHelper.getLatestRelease`）只认 `tagName`，
/// 不能因为某个 release 少写了一个字段，就把"有没有新版"这件事弄坏。
/// 下面这些是 2026-10-02 给「更新日志」页加的（那边会自己兜底空值）。
struct GitHubRelease: Decodable {
    var tagName: String

    /// release 标题（常常就是版本号，也可能为空）。
    var name: String?

    /// changelog 正文（Markdown 原文；我们只当纯文本展示，不做渲染）。
    var body: String?

    /// 网页地址 —— 点一下用系统浏览器打开。
    var htmlUrl: String?

    /// ISO8601 发布时间，原样展示前 10 位（`yyyy-MM-dd`）。
    var publishedAt: String?

    /// 预发布（beta）标记：列表里会标一下。
    var prerelease: Bool?
}
