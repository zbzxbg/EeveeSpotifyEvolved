import Orion

/// 目标类在本仓支持的 Spotify 版本上已不存在的 hook 的隔离组。
///
/// `Lyrics_NPVCommunicatorImpl.LyricsOnlyViewController` / `.ScrollProvider` /
/// `.ErrorViewController`、以及 `provideScrollViewControllerWithDependencies:` 这些目标，
/// 已由 9.1.74 主二进制类名/选择器扫描确认不存在。Orion 在激活组时会去解析目标类，
/// 解析失败会走错误路径：在 App 里表现为一条 `[ORION ERROR]`，但在**注入工具进程**里
/// 加载同一个 dylib 时会直接 SIGTRAP 崩掉工具本身。
///
/// 因此这些 hook 单独放进来，并且**该组在任何版本上都不激活** —— 组内 hook 的源码保留，
/// 等定位到 9.1.x 上的替代类后再逐个迁回可用组。
struct V91UnavailableLyricsGroup: HookGroup { }
