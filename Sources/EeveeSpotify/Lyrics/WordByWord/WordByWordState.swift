// 逐字歌词模块的**全局状态**（「这一次取词走到哪一步」、当前 dto 属于哪一首）。
// 从 `LyricsWordByWord.x.swift` 原样拆出；模块总览见那个文件。
import Orion
import UIKit
import ObjectiveC
import SwiftUI

var currentLyricsDto: LyricsDto?
var currentLyricsVersion: Int = 0

/// `currentLyricsDto` 里**已经加进去**的歌词时间轴偏移（毫秒）。
///
/// 运行时改偏移时只补差值（`新偏移 - 已经加过的`），不去重新取词；
/// 写入点：`storeLyricsDto`（按实际来源）与 `resetWordByWordLyrics`（清零）。
var currentLyricsTimingOffsetAppliedMs: Int = 0

/// `currentLyricsDto` 是**哪个源**给的（`.genius` 时偏移一律不参与）。
///
/// 为什么不从 `currentLyricsProvider` 反推：那是**展示名**（"Spicy Lyrics" / "Apple Inc."），
/// 与 `LyricsSource` 不是一一对应，反查会出错。这里是 dto 落地时同刻写下的真值，
/// 供 `reapplyLyricsTimingOffset` 与设置页读取。
var currentLyricsSource: LyricsSource?

/// **这一次"取词"走到哪一步了。**
///
/// 为什么需要它：以前只有"有词 / 没词"两态，而"没词"其实是**三件不同的事** ——
/// **还在查** / **查完了没找到** / **源明确说是纯音乐**。
/// 三者被压成同一个"点了没反应"（那个歌词按钮是不是点不开），
/// 而用户要的是：**键随时能按**，按开之后在歌词的位置写清楚是哪一种。
///
/// 写入点（`CustomLyrics.x.swift`，只有三处）：
/// · 请求开始 / 切歌 ⇒ `.loading`；
/// · `storeLyricsDto` ⇒ `.found`（有数据；纯音乐那种看 `LyricsDto.isInstrumental`）；
/// · 取词失败 ⇒ `.failed`。
enum LyricsLookupState {
    case idle
    case loading
    case found
    case failed
}

var currentLyricsLookupState: LyricsLookupState = .idle

/// `currentLyricsDto` 这份数据**属于哪一首**（曲目 id）。
///
/// ── 为什么需要它
/// 切歌**不一定**伴随一次歌词请求：客户端命中自己的歌词存储 / 离线歌词时不会有
/// `color-lyrics` 请求，于是 `resetWordByWordLyrics` 根本不会被调用，
/// `currentLyricsDto` 还是上一首的。而壳上的曲名是每帧从播放器实时读的 ——
/// 于是出现那种状态：**壳写着新歌名、歌词内容还是上一首的**。
///
/// AM 层早就有这条判据（`AppleMusicLyricsOverlayHost.hasForeignLineModel` +
/// `currentModelTrackId`，每帧在 `tick` 里比对），旧层一直缺 —— 这份记录就是把它
/// 补成两层共用的一份。
///
/// 写入时机见 `CustomLyrics.storeLyricsDto`（与 dto 同刻写），清空见
/// `resetWordByWordLyrics`。
var currentLyricsDtoTrackId: String = ""

/// 最终生效的歌词背景色（ARGB），CustomLyrics 算完 colors 后写入，供 overlay 与原生模块同色。
var currentLyricsBackgroundColorARGB: UInt32 = 0
/// 歌词提供者文本（如 "PetitLyrics"；起不带 `(EeveeSpotify)` 后缀），
/// 用于 overlay 页脚、以及**播放器页歌手那一行的右边**（`歌手（提供商）`）。
var currentLyricsProvider: String = ""

/// 提供者站点（可点署名用）。目前只有 Spicy Lyrics 会给，其余源是 `nil`。
var currentLyricsProviderURL: URL? = nil

/// 社区贡献者（Spicy Lyrics 的社区同步才有）—— 见 `LyricsContributor`。
///
/// 用途只有一个：听歌页歌词区底沿那条**可点**署名（`NowPlayingLyricsPlate`）。
/// 条款 §6 要的"链接"就落在这里。
var currentLyricsContributors: [LyricsContributor] = []

/// 这一次取词**是不是**"用户选了 SpicyLyrics 但没填客户端密钥 → 自动改用 Musixmatch"。
///
/// 每首歌在 `CustomLyrics.loadCustomLyricsForCurrentTrack` 入口重算。
/// 唯一用途：挡住 Musixmatch 那条"令牌无效，请检查你的令牌"弹窗 —— 用户根本没选过 Musixmatch，
/// 弹了只会让他去改一个他没打算用的源。
var spicyLyricsKeyMissingFallback: Bool = false

/// 当前曲目时长（毫秒），由 `getLyricsDataForCurrentTrack` 在处理这次歌词请求时写入。
///
/// 用途：给**无时间轴**的 payload（占位文案、Genius 纯文本）合成行级时间轴 ——
/// 那三步的位置（`unavailableLyricsPayload` / `makeUnavailableLyrics` /
/// `unavailableLyricsBytes`）都拿不到 track 对象，但都需要时长才能把行铺开。
///
/// 为什么是全局变量而不是参数：这三个函数分别服务于"响应替换"与"字节兜底"两条
/// 独立的失败路径，串参数会一路污染签名；而它本质上是"这一次请求的曲目"的上下文，
/// 与 `currentLyricsDto` 同源同时刻写入，语义一致。
///
/// nil 表示时长未知（合成逻辑会按每行估时兜底）。
var currentTrackDurationMs: Int?
