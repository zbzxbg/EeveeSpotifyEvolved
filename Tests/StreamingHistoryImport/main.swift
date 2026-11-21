import Foundation

// 「导入 Spotify 流媒体历史」的回归测试（Foundation + Compression，不需要 iOS SDK）。
//
// 跑法（需要 Swift 工具链）：
//   swiftc Tests/StreamingHistoryImport/main.swift \
//          Sources/EeveeSpotify/Stats/ListeningStatsModel.swift \
//          Sources/EeveeSpotify/Stats/ListeningStatsStore.swift \
//          Sources/EeveeSpotify/Stats/StreamingHistoryImport.swift \
//          -o /tmp/streaming-history-tests && /tmp/streaming-history-tests
//
// 钉的是「认不认得出、算得对不对、会不会重复算」：
// · ZIP 中央目录 + 裸 DEFLATE 能读（fixture 里一条 stored、一条 deflated）；
// · 扩展历史与旧的 `StreamingHistory0.json` 都认；
// · 30 秒才算一次播放、单条封顶 12 小时、负的 `ms_played` 丢掉；
// · 按**本地**日历日分桶（这里固定 UTC+8，所以 UTC 的下午会落到第二天）；
// · 同一份文件再导入整份跳过；文件变长时只补覆盖之后的记录；
// · 坏文件报成 failure，不静默产出半份数据。
//
// 设置页那一层（文档选择器 / 文案 / 进度）要在真机上验，这里不涉及。

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError("FAIL: \(message)") }
}

// MARK: - 环境

/// 固定 UTC+8：分桶结果不跟着跑 CI 的机器时区变。
let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? TimeZone(secondsFromGMT: 8 * 3600)!
    return calendar
}()

let now = calendar.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 12))!

let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    .appendingPathComponent("eevee-streaming-history-tests-\(UUID().uuidString)", isDirectory: true)
try! FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

// MARK: - 时间戳解析

require(
    StreamingHistoryTimestamp.seconds(from: "2020-01-01T12:34:56Z") == 1577882096,
    "the extended timestamp must parse as UTC"
)
require(
    StreamingHistoryTimestamp.seconds(from: "2020-01-01 12:34") == 1577882040,
    "the legacy timestamp (no seconds) must parse as UTC"
)
require(
    StreamingHistoryTimestamp.seconds(from: "2020-01-01T12:34:56.500Z") == 1577882096.5,
    "fractional seconds must be kept"
)
require(
    StreamingHistoryTimestamp.seconds(from: "2020-01-01T14:34:56+02:00") == 1577882096,
    "an explicit offset must be subtracted"
)
require(
    StreamingHistoryTimestamp.seconds(from: "2020-01-01T12:34:56+0200") == nil,
    "an offset without a colon is not part of the export format"
)
require(
    StreamingHistoryTimestamp.seconds(from: "not a date") == nil,
    "garbage must not parse into a timestamp"
)
require(
    StreamingHistoryTimestamp.seconds(from: "2020-13-01T12:34:56Z") == nil,
    "an impossible month must be rejected"
)

// MARK: - 曲目标识

require(
    StreamingHistoryRecordParser.trackIdentifier(fromURI: "spotify:track:alpha1") == "alpha1",
    "a track URI must be reduced to the bare id (same as the recorder)"
)
require(
    StreamingHistoryRecordParser.trackIdentifier(fromURI: "spotify:episode:ep1") == "ep1",
    "an episode URI must be reduced to the bare id"
)
require(
    StreamingHistoryRecordParser.trackIdentifier(fromURI: "") == "",
    "no URI must stay empty"
)

// MARK: - ZIP 读取（fixture 由 Python 的 zipfile 生成：一条 stored PDF + 一条 deflated JSON）

let zipBase64 = """
UEsDBBQAAAAAAAAAIQAkyfknDgAAAA4AAAAkAAAAU3BvdGlmeSBBY2NvdW50IERhdGEvUmVhZE1lRmlyc3QucGRmJVBERi0xLjQKZmFrZQpQSw
MEFAAAAAgAAAAhAGsmLuEKAQAAEwQAAD0AAABTcG90aWZ5IEFjY291bnQgRGF0YS9TdHJlYW1pbmdfSGlzdG9yeV9BdWRpb18yMDE5LTIwMjBf
MC5qc29uzZLLasMwEEV/pcw6BdnuI2jXQLPNol61FDGuFSKqh5FkSij5905cJSVEbrwpVBjJvnM1Op7RyyfEABxKVrJrVtBTF/e8YpyxZ5hBpz
GunTfkUC6QYIIgbStb4MWc0SAJQ5ReGBmxxYgienx7FxaNpF0PutsgnJtQN70R6KMK8ei1dtw5zMm4VD5EsobORbXephN7ryiWND5oHPfHF2SV
nQqulSmD7bX+0cLGfZwEDnkPhiHzPrSb/V6uv6/O5F/Oos6J8xy1vL1MuiB1IujCNZNAG0qS4yxrVmU5K3a5pKedTUSP359XKysh23Z4oncYaf
wRO6m0jmDfZLHv/ttFqOoBM3NnCXT3+gVQSwECFAAUAAAAAAAAACEAJMn5Jw4AAAAOAAAAJAAAAAAAAAAAAAAAgAEAAAAAU3BvdGlmeSBBY2Nv
dW50IERhdGEvUmVhZE1lRmlyc3QucGRmUEsBAhQAFAAAAAgAAAAhAGsmLuEKAQAAEwQAAD0AAAAAAAAAAAAAAIABUAAAAFNwb3RpZnkgQWNjb3
VudCBEYXRhL1N0cmVhbWluZ19IaXN0b3J5X0F1ZGlvXzIwMTktMjAyMF8wLmpzb25QSwUGAAAAAAIAAgC9AAAAtQEAAAAA
"""

let zipURL = tempRoot.appendingPathComponent("my_spotify_data.zip")
let zipData = Data(base64Encoded: zipBase64, options: .ignoreUnknownCharacters)!
try! zipData.write(to: zipURL)

let zipEntries = try! StreamingHistoryZipReader.entries(at: zipURL)
require(zipEntries.count == 2, "the archive must expose both entries")

let pdfEntry = zipEntries.first { $0.path.hasSuffix(".pdf") }
require(pdfEntry != nil, "the pdf entry must be listed")
require(pdfEntry?.method == 0, "the pdf entry must be stored uncompressed")
if let pdfEntry {
    let pdf = try! StreamingHistoryZipReader.data(for: pdfEntry, at: zipURL)
    require(pdf.count == 14, "a stored entry must come back byte for byte")
}

let jsonEntry = zipEntries.first { $0.path.hasSuffix(".json") }
require(jsonEntry?.method == 8, "the JSON entry must be deflated")
require(jsonEntry?.uncompressedSize == 1043, "the central directory must carry the real size")

// MARK: - 第一次导入（zip）

let first = StreamingHistoryImporter.parse(urls: [zipURL], known: [:], calendar: calendar)

require(first.failures.isEmpty, "a valid export must not report failures")
require(first.filesRead == 1, "only the JSON entry is a source")
require(first.filesSkipped == 0, "nothing was imported before")
require(first.records == 5, "five records carry a title (the sixth has none)")
require(first.duplicates == 1, "the repeated record must be dropped")
require(first.additions.count == 1, "the archive must produce exactly one source")
require(first.plays == 3, "Alpha twice plus the episode is three plays")
require(first.earliestDay == "2020-01-02", "UTC evening plus 8 h lands on the next day")
require(first.latestDay == "2020-01-02", "every record of this fixture is on one local day")
require(
    first.additions[0].name == "Streaming_History_Audio_2019-2020_0.json",
    "the source is keyed by the bare file name"
)
require(
    first.additions[0].latestTimestamp
        == StreamingHistoryTimestamp.seconds(from: "2020-01-02T04:00:00Z")!,
    "the coverage watermark must be the newest record in the file"
)

let entries = first.additions[0].entries
require(entries.count == 3, "three tracks on that day (Alpha, Beta, the episode)")
require(entries.map { $0.trackID } == ["alpha1", "beta1", "ep1"], "entries must be sorted by id")

let alpha = entries[0]
require(alpha.title == "Alpha" && alpha.artist == "Ann", "the title and artist must survive")
require(alpha.seconds == 240, "two Alpha records on the same day must sum")
require(alpha.plays == 2, "two full-length Alpha plays")
require(alpha.dayKey == "2020-01-02", "the bucket must be the local calendar day")

let beta = entries[1]
require(beta.seconds == 25, "a 25 s record still counts its time")
require(beta.plays == 0, "under 30 s must not count as a play")

let episode = entries[2]
require(episode.title == "Episode One", "podcast records use the episode name")
require(episode.artist == "Show", "podcast records use the show name")
require(episode.seconds == 300, "the episode length must be kept")
require(episode.plays == 1, "a five minute episode is one play")

// MARK: - 同一份文件再导入：整份跳过

let known: [String: ListeningStatsImportedSource] = [
    first.additions[0].name: ListeningStatsImportedSource(
        fingerprint: first.additions[0].fingerprint,
        latestTimestamp: first.additions[0].latestTimestamp
    )
]

let repeated = StreamingHistoryImporter.parse(urls: [zipURL], known: known, calendar: calendar)
require(repeated.filesSkipped == 1, "an unchanged file must be skipped without parsing")
require(repeated.filesRead == 0, "a skipped file must not count as read")
require(repeated.additions.isEmpty, "re-importing the same export must add nothing")
require(repeated.records == 0, "a skipped file must not even be scanned")

// MARK: - 文件变长（导出包在增长）：只补覆盖之后的记录

let grown: [String: ListeningStatsImportedSource] = [
    first.additions[0].name: ListeningStatsImportedSource(
        fingerprint: "1-deadbeefdeadbeef",
        latestTimestamp: StreamingHistoryTimestamp.seconds(from: "2020-01-01T18:00:00Z")!
    )
]

let appended = StreamingHistoryImporter.parse(urls: [zipURL], known: grown, calendar: calendar)
require(appended.filesSkipped == 0, "a changed fingerprint must be parsed again")
require(appended.additions.count == 1, "the grown file is still one source")
require(appended.records == 5, "every record is scanned again")
require(appended.duplicates == 3, "the three already-covered records must be skipped")
require(appended.plays == 2, "only the episode and the later Alpha remain")
require(
    appended.additions[0].entries.map { $0.trackID } == ["alpha1", "ep1"],
    "the remaining records are the ones past the watermark"
)
require(
    appended.additions[0].entries[0].seconds == 60,
    "only the part after the watermark is added for the repeated track"
)

// MARK: - 文件夹：旧格式 + 一个坏文件

let folder = tempRoot.appendingPathComponent("Spotify Account Data", isDirectory: true)
try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

let legacyJSON = """
[
  {"endTime":"2019-05-05 10:00","artistName":"Cee","trackName":"Gamma","msPlayed":120000},
  {"endTime":"2019-05-05 10:05","artistName":"Cee","trackName":"Gamma","msPlayed":20000}
]
"""
try! legacyJSON.write(to: folder.appendingPathComponent("StreamingHistory0.json"), atomically: true, encoding: .utf8)

// 截断的 JSON：一个完整对象都没有。必须报出来，而不是安静地"什么都没加"。
let brokenJSON = "[{\"endTime\": \"2019-05-05 10:00\", \"trackName\": \"Broken\""
try! brokenJSON.write(to: folder.appendingPathComponent("broken.json"), atomically: true, encoding: .utf8)

// 不该被当成历史的文件：直接忽略，不算失败。
try! "not history".write(
    to: folder.appendingPathComponent("notes.txt"),
    atomically: true,
    encoding: .utf8
)

let folderBatch = StreamingHistoryImporter.parse(urls: [folder], known: [:], calendar: calendar)
require(folderBatch.filesRead == 2, "both JSON files are read")
require(folderBatch.failures.count == 1, "only the truncated file is a failure")
require(folderBatch.failures[0].name == "broken.json", "the failure must name the file")
require(folderBatch.additions.count == 1, "the truncated file must not be recorded as a source")

let legacy = folderBatch.additions[0]
require(legacy.name == "StreamingHistory0.json", "the legacy file keeps its name")
require(legacy.entries.count == 1, "the two legacy records merge into one track")
require(legacy.entries[0].title == "Gamma", "the legacy title field must be read")
require(legacy.entries[0].artist == "Cee", "the legacy artist field must be read")
require(legacy.entries[0].dayKey == "2019-05-05", "the legacy date is UTC, the bucket is local")
require(legacy.entries[0].seconds == 140, "small legacy records still sum their time")
require(legacy.entries[0].plays == 1, "only the 120 s record clears the play threshold")
require(
    legacy.entries[0].trackID.hasPrefix(ListeningStatsTrackKey.fallbackPrefix),
    "the legacy format has no URI, so the track falls back to the title/artist hash"
)

// MARK: - 单个 JSON 文件：单条封顶与坏长度

let singleJSON = """
[
  {"ts":"2021-03-01T00:00:00Z","ms_played":43200000,
   "master_metadata_track_name":"Long","master_metadata_album_artist_name":"Zed",
   "spotify_track_uri":"spotify:track:long1"},
  {"ts":"2021-03-01T01:00:00Z","ms_played":-500,
   "master_metadata_track_name":"Neg","master_metadata_album_artist_name":"Zed",
   "spotify_track_uri":"spotify:track:neg1"}
]
"""
let singleURL = tempRoot.appendingPathComponent("Streaming_History_Audio_2021_0.json")
try! singleJSON.write(to: singleURL, atomically: true, encoding: .utf8)

let single = StreamingHistoryImporter.parse(urls: [singleURL], known: [:], calendar: calendar)
require(single.failures.isEmpty, "a valid file must not report failures")
require(single.additions.count == 1, "one file, one source")
require(single.additions[0].entries.count == 1, "the negative record must be dropped")
require(
    single.additions[0].entries[0].seconds == StreamingHistoryRecordParser.maxRecordSeconds,
    "one record is capped at 12 h"
)

// MARK: - 记账：空来源也要记住指纹

var bookkeeping = ListeningStatsData()
let emptyAddition = ListeningStatsImportAddition(
    name: "duplicate-of-another-export.json",
    fingerprint: "2-cafecafecafecafe",
    latestTimestamp: 1_600_000_000,
    entries: []
)
bookkeeping.mergeImported([emptyAddition])
require(
    bookkeeping.importedSources?["duplicate-of-another-export.json"] != nil,
    "a source whose records were all deduped must still be remembered"
)
require(bookkeeping.days.isEmpty, "an empty source must not create a day bucket")

// MARK: - 剪枝：导入的老日子不被 400 天保留期削掉

var importedData = ListeningStatsData()
importedData.mergeImported([first.additions[0]])
require(importedData.oldestImportedDay == "2020-01-02", "the oldest imported day must be recorded")
require(importedData.days["2020-01-02"]?["alpha1"]?.seconds == 240, "the import must land in the bucket")

importedData.prune(now: now, calendar: calendar)
require(
    importedData.days["2020-01-02"] != nil,
    "pruning must keep imported days that are older than the retention window"
)

var plainData = ListeningStatsData()
plainData.add(
    ListeningStatsEntry(
        dayKey: "2020-01-02",
        trackID: "t1",
        title: "Alpha",
        artist: "Ann",
        durationSeconds: 0,
        artworkURL: nil,
        seconds: 10,
        plays: 0
    )
)
plainData.prune(now: now, calendar: calendar)
require(plainData.days.isEmpty, "a recorded day that old is still pruned")

// MARK: - 磁盘：整条链路落到 store

let storeURL = tempRoot.appendingPathComponent(ListeningStatsStore.fileName)
let store = ListeningStatsStore(fileURL: storeURL)

let written = store.importStreamingHistorySynchronously(first.additions)
require(written == 3, "three buckets-tracks are written")
require(FileManager.default.fileExists(atPath: storeURL.path), "importing must create the store file")

let reopened = ListeningStatsStore(fileURL: storeURL).loadSynchronously()
require(reopened.days["2020-01-02"]?["alpha1"]?.seconds == 240, "the seconds must survive a reopen")
require(reopened.days["2020-01-02"]?["alpha1"]?.plays == 2, "the plays must survive a reopen")
require(reopened.oldestImportedDay == "2020-01-02", "the watermark must survive a reopen")
require(
    reopened.importedSources?[first.additions[0].name]?.fingerprint == first.additions[0].fingerprint,
    "the source fingerprint must survive a reopen"
)

try? FileManager.default.removeItem(at: tempRoot)

print("Streaming history import regression tests passed")
