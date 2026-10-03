import Foundation
import UIKit

/// 把「屏蔽的艺人」接到播放上：曲目**一开始**就跳到下一首。
///
/// ── 为什么用轮询，而不是新增 hook ───────────────────────────────────────────
/// 换歌的信号在这套代码里有几条路（歌词模块的 track changed、SponsorBlock 的播放器
/// 观察者…），但它们各自都带着"只在某个功能开着时才装"的前提；而新增 Orion hook 在
/// **注入工具进程**里解析不到目标时有 SIGTRAP 的先例（见
/// `CustomLyrics+AllTracksLyrics.x.swift` 顶部那段）。轮询只用已经验证可用的原语：
///
///   · 曲目：`statefulPlayer.currentTrack()`（`AppleMusicLyricsPlaybackControl` 已经在用
///     同一个调用读时长、`CustomLyrics` 用它读 `trackIdentifier`，两条都在真机跑过）；
///   · 艺人 / 标题：**每个都先 `responds(to:)` 探一下再调** —— `SPTPlayerTrack` 是我们手写的
///     `@objc protocol`，声明了不等于这版对象实现了（`artistTitle()` 就不是；
///     2026-10-01 的崩溃正是它）。探测写在共用扩展里：`SPTPlayerTrack.string(ifResponding:)`；
///   · 位置：`WordByWordPositionResolver.shared.currentPositionSeconds()`（内部自带探测）；
///   · 跳歌：`WordByWordPlaybackControl.skipToNext()`
///     —— 日志 8 已证明它可用（`[Shell] skipToNext via statefulPlayer.skipToNextTrack()`）。
///
/// 1 秒一次、只读几个字段，代价可以忽略。
///
/// ⚠️ **这里刻意没有"熄屏就不跑"的 guard**（`DeclutterChrome` 的复查有那条）：
/// 屏蔽艺人恰恰要在锁屏/后台放歌时也生效 —— Spotify 放音频时进程不会被挂起。
/// 「暂停时不动」是靠位置判断自然得到的：暂停时不会换歌。
enum BlockedArtistSkip {

    private static let interval: TimeInterval = 1.0

    /// 连续跳过多少首就先停下并打一行警告。
    ///
    /// 为什么需要护栏：如果一张歌单/电台整张都是被屏蔽的艺人，没有它会一路跳到底，
    /// 用户看到的是"歌一直在闪、什么都听不到"。停下比乱跳好 —— 而且日志里会说明原因。
    private static let maxConsecutiveSkips = 5

    /// 位置超过这个秒数就不再跳（只在"刚开头"动手）。
    private static let startWindow: Double = 3

    private static var timer: Timer?
    /// 已经判过的曲目：同一首只判一次，跳不动时（比如队列只有一首）不会反复试。
    /// 存的是 `trackIdentifier`（`spotify:track:<id>` 里的 id），不是整条 URI —— 见 tick 里的说明。
    private static var lastSeenTrackID: String?
    private static var consecutiveSkips = 0
    private static var didWarnMissingPlayer = false

    static func start() {
        guard timer == nil else { return }

        let timer = Timer(timeInterval: interval, repeats: true) { _ in tick() }
        timer.tolerance = 0.3
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private static func tick() {
        guard BlockedArtists.isEnabled, BlockedArtists.count > 0 else { return }

        guard let track = statefulPlayer?.currentTrack() else {
            // 不开歌词时 `statefulPlayer` 抓不到（它挂在 BaseLyricsGroup 上）。
            // 打一次就够了 —— 否则每秒一行会把日志刷爆。
            if !didWarnMissingPlayer {
                didWarnMissingPlayer = true
                writeDebugLog("[BlockArtist] statefulPlayer.currentTrack() unavailable - blocked artists are inactive for now (this happens when the lyrics module is off)")
            }
            return
        }

        // ⚠️ 这里**不能**写 `track.URI()?.absoluteString`：
        //   · `SPTPlayerTrack.URI()` 返回的是**非可选**的 `any SPTURL`；
        //   · 而 `SPTURL` 是我们手写的 `@objc protocol`（真身是 NSURL，见那个头文件），
        //     声明里只有 `spt_trackIdentifier()` / `isPlaylistURL()`，**没有** `absoluteString`
        //     —— 编译期直接报 "has no member 'absoluteString'"（2026-10-01 CI 就这么挂的）。
        // 仓库里既有的读法是扩展 `trackIdentifier`
        // （`SPTPlayerTrack+Extension.swift`，内部就是 `URI().spt_trackIdentifier()`），
        // 拿到 `spotify:track:<id>` 里的 id —— 用它判断"换歌了没有"正好，比整条 URI 还稳。
        let trackKey = track.trackIdentifier
        guard !trackKey.isEmpty else { return }
        // 同一首只判一次：跳不动（比如队列就一首）时不会反复试。
        guard trackKey != lastSeenTrackID else { return }
        lastSeenTrackID = trackKey

        let artistName = track.string(ifResponding: "artistName")
        let artistTitle = track.string(ifResponding: "artistTitle")
        reportGettersOnce(track)

        guard let hit = BlockedArtists.match(artistName: artistName, artistTitle: artistTitle) else {
            consecutiveSkips = 0   // 这一首没命中 → 连续跳过的计数重来
            return
        }

        // 只在**开头**跳：轮询晚到了、或者用户已经听进去了，就别动它。
        if let position = WordByWordPositionResolver.shared.currentPositionSeconds(),
           position > startWindow {
            writeDebugLog("[BlockArtist] hit '\(hit)', but already \(Int(position))s in - not skipping (we only skip at the start)")
            consecutiveSkips = 0
            return
        }

        consecutiveSkips += 1
        guard consecutiveSkips <= maxConsecutiveSkips else {
            writeDebugLog("[BlockArtist] skipped \(maxConsecutiveSkips) tracks in a row, stopping - this queue may be all blocked artists")
            consecutiveSkips = 0
            return
        }

        writeDebugLog("[BlockArtist] hit '\(hit)' - skipping '\(track.string(ifResponding: "trackTitle") ?? "<unknown>")' (artist '\(artistTitle ?? artistName ?? "")')")
        WordByWordPlaybackControl.skipToNext()
    }

    private static var didReportGetters = false

    /// 第一次拿到曲目时，把这台设备上 `SPTPlayerTrack` 实际实现了哪些 getter 写进日志。
    private static func reportGettersOnce(_ track: SPTPlayerTrack) {
        guard !didReportGetters else { return }
        didReportGetters = true

        let object = track as AnyObject
        let responds: (String) -> String = { name in
            ((object as? NSObject)?.responds(to: Selector(name)) ?? false) ? "Y" : "N"
        }

        writeDebugLog(
            "[BlockArtist] SPTPlayerTrack getters:"
                + " artistName=\(responds("artistName"))"
                + " artistTitle=\(responds("artistTitle"))"
                + " trackTitle=\(responds("trackTitle"))"
        )
    }
}
