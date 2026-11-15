import Foundation

// 「听歌统计」的回归测试（Foundation-only，不需要 iOS SDK）。
//
// 跑法（需要 Swift 工具链）：
//   swiftc Tests/ListeningStats/main.swift \
//          Sources/EeveeSpotify/Stats/ListeningStatsModel.swift \
//          Sources/EeveeSpotify/Stats/ListeningStatsStore.swift \
//          -o /tmp/listening-stats-tests && /tmp/listening-stats-tests
//
// 钉的是「算得对不对」：30 秒才计一次播放、不足 30 秒照样记时长、一拍最多 3 秒、
// 暂停 / 拖进度条不算在听、按本地日历日分桶、按时间段聚合与排序、JSON 往返、剪枝。
// 录音器本身（UIKit / MediaPlayer）不在这里，它在真实播放器上才能验。

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError("FAIL: \(message)") }
}

private func entry(
    _ dayKey: String,
    _ trackID: String,
    _ title: String,
    _ artist: String,
    seconds: Double,
    plays: Int,
    durationSeconds: Int = 200,
    artworkURL: String? = nil
) -> ListeningStatsEntry {
    ListeningStatsEntry(
        dayKey: dayKey,
        trackID: trackID,
        title: title,
        artist: artist,
        durationSeconds: durationSeconds,
        artworkURL: artworkURL,
        seconds: seconds,
        plays: plays
    )
}

let calendar = Calendar.current
let now = calendar.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 12))!
let todayKey = ListeningStatsDayKey.key(for: now, calendar: calendar)
let yesterdayKey = ListeningStatsDayKey.key(
    for: calendar.date(byAdding: .day, value: -1, to: now)!,
    calendar: calendar
)

// MARK: - 播放次数：30 秒门槛

var counter = ListeningStatsPlayCounter()
var earnedPlays = 0

for _ in 0..<29 {
    if counter.add(1) { earnedPlays += 1 }
}
require(counter.seconds == 29, "29 s of playback must be recorded as 29 s")
require(earnedPlays == 0, "29 s must not count a play")
require(!counter.hasCountedPlay, "the play flag must stay false below the threshold")

if counter.add(1) { earnedPlays += 1 }
require(counter.seconds == 30, "the counter must keep accumulating seconds")
require(earnedPlays == 1, "30 s must count exactly one play")

for _ in 0..<300 {
    if counter.add(1) { earnedPlays += 1 }
}
require(earnedPlays == 1, "one session must count at most one play")
require(counter.seconds == 330, "seconds must keep accumulating after the play is counted")

var negativeCounter = ListeningStatsPlayCounter()
require(negativeCounter.add(0) == false && negativeCounter.seconds == 0, "a zero delta must be ignored")
require(negativeCounter.add(-5) == false && negativeCounter.seconds == 0, "a negative delta must be ignored")

// MARK: - 一拍的计秒规则

require(
    ListeningStatsPlaybackRules.tickCredit(rate: 1, position: 11, lastPosition: 10, wallSeconds: 1) == 1,
    "1 s of wall clock with the position advancing must credit 1 s"
)
require(
    ListeningStatsPlaybackRules.tickCredit(rate: 0, position: 11, lastPosition: 10, wallSeconds: 1) == 0,
    "a paused player must freeze accumulation even if the position moved"
)
require(
    ListeningStatsPlaybackRules.tickCredit(rate: 1, position: 10, lastPosition: 10, wallSeconds: 1) == 0,
    "a held position (buffering) must not count as listening"
)
require(
    ListeningStatsPlaybackRules.tickCredit(rate: 1, position: 70, lastPosition: 10, wallSeconds: 1) == 0,
    "a forward seek must not add the skipped distance"
)
require(
    ListeningStatsPlaybackRules.tickCredit(rate: 1, position: 20, lastPosition: 10, wallSeconds: 10) == 3,
    "one tick must be capped at 3 s (background timer coalescing)"
)
require(
    ListeningStatsPlaybackRules.tickCredit(rate: 1, position: 9, lastPosition: 10, wallSeconds: 1) == 0,
    "a backward seek must not credit anything"
)
require(
    ListeningStatsPlaybackRules.tickCredit(rate: 1, position: nil, lastPosition: 10, wallSeconds: 1) == 1,
    "when the position is unreadable the wall clock is the only signal left"
)
require(
    ListeningStatsPlaybackRules.tickCredit(rate: 1, position: 5, lastPosition: nil, wallSeconds: 1) == 0,
    "the first tick of a session only records the baseline"
)
require(
    ListeningStatsPlaybackRules.isTrackRestart(position: 0.4, lastPosition: 209),
    "a replay from the start must be treated as a restart"
)
require(
    !ListeningStatsPlaybackRules.isTrackRestart(position: 40, lastPosition: 120),
    "dragging back to 0:40 mid-track must not be treated as a restart"
)
require(
    !ListeningStatsPlaybackRules.isTrackRestart(position: 1, lastPosition: nil),
    "a restart needs a previous position"
)

// MARK: - 曲目标识

require(
    ListeningStatsTrackKey.identifier(
        trackID: "4uLU6hMCjMI75M1A2tKUQC",
        title: "Alpha",
        artist: "Ann",
        durationSeconds: 200
    ) == "4uLU6hMCjMI75M1A2tKUQC",
    "a non-empty track identifier must be used as-is"
)

let fallbackA = ListeningStatsTrackKey.identifier(trackID: "", title: "Alpha", artist: "Ann", durationSeconds: 200)
let fallbackB = ListeningStatsTrackKey.identifier(trackID: "", title: "Alpha", artist: "Ann", durationSeconds: 200)
let fallbackC = ListeningStatsTrackKey.identifier(trackID: "", title: "Alpha", artist: "Ann", durationSeconds: 201)
let fallbackD = ListeningStatsTrackKey.identifier(trackID: "   ", title: "Beta", artist: "Ann", durationSeconds: 200)

require(fallbackA == fallbackB, "the fallback identifier must be stable across calls")
require(fallbackA != fallbackC, "the fallback identifier must depend on the duration")
require(fallbackA != fallbackD, "the fallback identifier must depend on the title")
require(fallbackA.hasPrefix(ListeningStatsTrackKey.fallbackPrefix), "the fallback identifier must be marked")

require(
    ListeningStatsTrackKey.fnv1a("") == 0xcbf2_9ce4_8422_2325,
    "FNV-1a must start from the 64-bit offset basis"
)
require(
    ListeningStatsTrackKey.fnv1a("a") == 0xaf63_dc4c_8601_ec8c,
    "FNV-1a must stay byte-for-byte the reference algorithm"
)

// MARK: - 日桶键

// 固定用公历 + UTC 钉住「年月日怎么拼」；不依赖跑测试那台机器选的是哪种日历。
var gregorian = Calendar(identifier: .gregorian)
gregorian.timeZone = TimeZone(secondsFromGMT: 0)!
let fixedDate = gregorian.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 12))!
require(
    ListeningStatsDayKey.key(for: fixedDate, calendar: gregorian) == "2026-06-15",
    "the day key must be built from calendar components, not a locale formatter"
)
require(
    todayKey.count == 10 && todayKey.split(separator: "-").count == 3,
    "a day key must be a fixed-width yyyy-MM-dd string"
)
require(
    ListeningStatsDayKey.date(from: todayKey, calendar: calendar)
        .map { calendar.isDate($0, inSameDayAs: now) } == true,
    "a day key must round trip back to the same calendar day"
)
require(
    ListeningStatsDayKey.key(for: now, calendar: calendar) < ListeningStatsDayKey.key(
        for: calendar.date(byAdding: .day, value: 1, to: now)!,
        calendar: calendar
    ),
    "day keys must sort chronologically as plain strings"
)
require(
    ListeningStatsDayKey.cutoffKey(daysBack: 6, now: now, calendar: calendar)
        == ListeningStatsDayKey.key(
            for: calendar.date(byAdding: .day, value: -6, to: now)!,
            calendar: calendar
        ),
    "the cutoff key must point exactly 6 days back"
)

// MARK: - 分桶与合并

var bucket = ListeningStatsData()
bucket.add(entry(todayKey, "t1", "Alpha", "Ann", seconds: 20, plays: 0))
bucket.add(entry(todayKey, "t1", "Alpha", "Ann", seconds: 40, plays: 1))
require(bucket.days[todayKey]?["t1"]?.seconds == 60, "two sessions of the same song on one day must merge")
require(bucket.days[todayKey]?["t1"]?.plays == 1, "merged plays must add up")

bucket.add(entry(yesterdayKey, "t1", "Alpha", "Ann", seconds: 10, plays: 1))
require(bucket.days.count == 2, "the same song on two days must live in two buckets")
require(bucket.days[yesterdayKey]?["t1"]?.seconds == 10, "each day keeps its own seconds")
require(bucket.days[yesterdayKey]?["t1"]?.plays == 1, "each day keeps its own plays")

bucket.add(entry(todayKey, "t2", "Beta", "Bob", seconds: 0, plays: 0))
require(bucket.days[todayKey]?["t2"] == nil, "an empty increment must not create a record")

bucket.add(entry(todayKey, "", "", "", seconds: 0, plays: 0))
require(bucket.days[todayKey]?[""] == nil, "an empty id with no data must not create a record")

// MARK: - 聚合

let fortyDaysAgo = calendar.date(byAdding: .day, value: -40, to: now)!
let fortyDaysAgoKey = ListeningStatsDayKey.key(for: fortyDaysAgo, calendar: calendar)

var data = ListeningStatsData()
data.add(entry(todayKey, "t1", "Alpha", "Ann", seconds: 100, plays: 2, artworkURL: "https://example.com/alpha.jpg"))
data.add(entry(todayKey, "t2", "Beta", "Bob", seconds: 50, plays: 0))
data.add(entry(yesterdayKey, "t1", "Alpha", "Ann", seconds: 20, plays: 1))
data.add(entry(yesterdayKey, "t3", "Gamma", "Ann", seconds: 10, plays: 0))
data.add(entry(fortyDaysAgoKey, "t4", "Old", "Zed", seconds: 500, plays: 5))

let week = data.summary(period: .week, now: now, calendar: calendar)
require(week.totalSeconds == 180, "the 7-day window must sum only this week's seconds")
require(week.totalPlays == 3, "the 7-day window must sum this week's plays")
require(week.uniqueTracks == 3, "unique tracks must count each track once across days")
require(week.uniqueArtists == 2, "unique artists must dedupe the same artist across days")
require(week.topTracks.count == 3, "top tracks must be limited to what the period contains")
require(week.topTracks[0].trackID == "t1", "top tracks must be sorted by seconds")
require(week.topTracks[0].seconds == 120, "top tracks must sum the same track across days")
require(week.topTracks[0].plays == 3, "top tracks must sum the same track's plays")
require(week.topTracks[1].trackID == "t2", "top tracks must keep the descending order")
require(week.topTracks[2].trackID == "t3", "top tracks must include the tail")
require(week.topArtists[0].name == "Ann", "top artists must be sorted by seconds")
require(week.topArtists[0].seconds == 130, "top artists must sum every track of that artist")
require(week.topArtists[0].plays == 3, "top artists must sum every play of that artist")
require(week.topArtists[1].name == "Bob", "top artists must keep the descending order")

let month = data.summary(period: .month, now: now, calendar: calendar)
require(month.totalSeconds == 180, "the 30-day window must exclude the 40-day-old bucket")

let year = data.summary(period: .year, now: now, calendar: calendar)
require(year.totalSeconds == 680, "the 1-year window must include the 40-day-old bucket")
require(year.totalPlays == 8, "the 1-year window must sum every play")
require(year.uniqueTracks == 4, "the 1-year window must count every track")
require(year.uniqueArtists == 3, "the 1-year window must count every artist")

let all = data.summary(period: .all, now: now, calendar: calendar)
require(all.totalSeconds == year.totalSeconds, "all-time must match the 1-year window here")
require(all.topTracks.count == 4, "all-time must list every track")

let limited = data.summary(period: .all, now: now, calendar: calendar, limit: 2)
require(limited.topTracks.count == 2, "the limit must cap the top tracks")
require(limited.topArtists.count == 2, "the limit must cap the top artists")

let empty = ListeningStatsData().summary(period: .all, now: now, calendar: calendar)
require(empty.isEmpty, "an empty store must produce an empty summary")
require(empty.totalSeconds == 0 && empty.totalPlays == 0, "an empty summary must be all zeros")
require(empty.topTracks.isEmpty && empty.topArtists.isEmpty, "an empty summary must have no rankings")

// MARK: - 近 7 天逐日

let daily = data.dailyTotals(daysBack: 6, now: now, calendar: calendar)
require(daily.count == 7, "the chart must always get 7 points, empty days included")
require(daily.last?.dayKey == todayKey, "the last point must be today")
require(daily.last?.seconds == 150, "today's point must sum both songs")
require(daily[5].seconds == 30, "yesterday's point must sum both songs")
require(daily[0].seconds == 0, "a day without listening must be a zero bar")

// MARK: - 剪枝

var pruneData = ListeningStatsData()
let ancientKey = ListeningStatsDayKey.key(
    for: calendar.date(byAdding: .day, value: -401, to: now)!,
    calendar: calendar
)
let edgeKey = ListeningStatsDayKey.key(
    for: calendar.date(byAdding: .day, value: -399, to: now)!,
    calendar: calendar
)
pruneData.add(entry(ancientKey, "old", "Old", "Zed", seconds: 10, plays: 0))
pruneData.add(entry(edgeKey, "edge", "Edge", "Zed", seconds: 10, plays: 0))
pruneData.add(entry(todayKey, "today", "Today", "Zed", seconds: 10, plays: 0))

pruneData.prune(now: now, calendar: calendar)
require(pruneData.days[ancientKey] == nil, "a bucket older than the retention window must be pruned")
require(pruneData.days[edgeKey] != nil, "the oldest still-retained bucket must survive")
require(pruneData.days[todayKey] != nil, "today's bucket must never be pruned")

// MARK: - JSON 往返

let payload = try! JSONEncoder().encode(data)
let decoded = try! JSONDecoder().decode(ListeningStatsData.self, from: payload)
require(decoded == data, "the JSON round trip must be lossless")
require(
    decoded.days[todayKey]?["t1"]?.seconds == 100,
    "seconds must survive the JSON round trip"
)
require(
    decoded.days[todayKey]?["t1"]?.artworkURL == "https://example.com/alpha.jpg",
    "the artwork URL must survive the JSON round trip"
)

// MARK: - 磁盘（注入临时目录，绝不碰 App 容器）

let tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    .appendingPathComponent("eevee-listening-stats-tests-\(UUID().uuidString)", isDirectory: true)
try! FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

let fileURL = tempDirectory.appendingPathComponent(ListeningStatsStore.fileName)
let store = ListeningStatsStore(fileURL: fileURL)

require(store.loadSynchronously().days.isEmpty, "a fresh store must be empty")

store.persistSynchronously([
    entry(todayKey, "t1", "Alpha", "Ann", seconds: 30, plays: 1)
])
require(
    FileManager.default.fileExists(atPath: fileURL.path),
    "persisting must create the JSON file"
)

let reopened = ListeningStatsStore(fileURL: fileURL).loadSynchronously()
require(reopened.days[todayKey]?["t1"]?.seconds == 30, "a reopened store must read the seconds back")
require(reopened.days[todayKey]?["t1"]?.plays == 1, "a reopened store must read the plays back")
require(reopened.days[todayKey]?["t1"]?.title == "Alpha", "a reopened store must read the title back")

store.clearSynchronously()
require(!FileManager.default.fileExists(atPath: fileURL.path), "clearing must delete the file")
require(store.loadSynchronously().days.isEmpty, "clearing must empty the cached copy")

try? FileManager.default.removeItem(at: tempDirectory)

print("Listening stats regression tests passed")
