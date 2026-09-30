import Foundation

// 「日志脱敏」回归测试（2026-09-30）。
//
// 跑法（CI 里就是这么编的，见 .github/workflows/builddeb.yml）：
//   swiftc Sources/EeveeSpotify/Shared/Helpers/DebugLogSanitizer.swift \
//          Tests/DebugLogRedaction/main.swift -o /tmp/debug-log-redaction-tests
//
// 这里**只**依赖 DebugLogSanitizer.swift 本身（Foundation only）——
// 所以它不需要 Spotify、不需要 Orion，也不需要整个 tweak 能编过。

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError("FAIL: \(message)") }
}

// ── ① 凭证：任何形态都不能把值留下 ──────────────────────────────────────────

let bearer = DebugLogSanitizer.sanitize("[NET] Authorization=Bearer FAKEBearerTokenValue123")
require(!bearer.contains("FAKEBearerTokenValue123"), "Bearer token must be redacted, got: \(bearer)")
require(bearer.contains("<redacted>"), "Bearer line must carry the marker, got: \(bearer)")

require(
    !DebugLogSanitizer.sanitize("Cookie: sp_dc=AQBc1234567890").contains("AQBc1234567890"),
    "sp_dc cookie value must be redacted"
)
require(
    !DebugLogSanitizer.sanitize("request cookie sp_t=abcdef").contains("abcdef"),
    "sp_t cookie value must be redacted"
)
require(
    !DebugLogSanitizer.sanitize("__csrf=deadbeef").contains("deadbeef"),
    "__csrf must be redacted"
)
require(
    !DebugLogSanitizer.sanitize("[NetEase] Invalid URL for /api/x, csrf=9f8a7b").contains("9f8a7b"),
    "bare csrf must be redacted"
)
require(
    !DebugLogSanitizer.sanitize(#"{"userID":"AbC123xyz","service":"Spotify"}"#).contains("AbC123xyz"),
    "SponsorBlock userID (JSON form) must be redacted"
)

// ── ② 设备 / 账号标识 ───────────────────────────────────────────────────────

let deviceLine = "[TokenCapture] len=427 from "
    + "https://gae2-spclient.spotify.com:443"
    + "/social-connect/v2/devices/0123456789abcdef0123456789abcdef/jam_status?alt=protobuf"
let deviceSafe = DebugLogSanitizer.sanitize(deviceLine)
require(!deviceSafe.contains("01234567"), "device id must be redacted, got: \(deviceSafe)")
require(
    deviceSafe.contains("/devices/<device>/jam_status"),
    "device placeholder must keep the path readable, got: \(deviceSafe)"
)
require(
    !DebugLogSanitizer.sanitize("GET spotify:user:ngzhwm/x").contains("ngzhwm"),
    "spotify:user id must be redacted"
)

// ── ③ URL：只留 scheme+host+path ────────────────────────────────────────────

let scrollURL = URL(string: "https://gae2-spclient.spotify.com:443/scrollsita/v1/scroll/"
    + "spotify:track:2Fkzxa6EiI43U6s8RkLjht"
    + "?is_personalized_context=false"
    + "&timezone=Etc/GMT-9"
    + "&play_context_uri=spotify%3Aplaylist%3ATESTPLAYLISTID0000000")!
require(
    DebugLogSanitizer.logSafeURL(scrollURL)
        == "https://gae2-spclient.spotify.com/scrollsita/v1/scroll/spotify:track:2Fkzxa6EiI43U6s8RkLjht",
    "logSafeURL must drop the whole query, got: \(DebugLogSanitizer.logSafeURL(scrollURL))"
)
require(DebugLogSanitizer.logSafeURL(nil) == "<no url>", "nil url must stay readable")
require(
    DebugLogSanitizer.logSafeURLString("https://sponsor.ajay.app/api/voteOnSponsorTime?UUID=x&userID=y")
        == "https://sponsor.ajay.app/api/voteOnSponsorTime",
    "logSafeURLString must drop the SponsorBlock query"
)

// ── ④ 措辞与信息量：该保留的判据一个字都不能少 ──────────────────────────────

let flagsLine = "[Flags] lyrics flag — scope=ios-feature-lyrics name=lyrics_entry_point_enabled bool=false"
require(
    DebugLogSanitizer.sanitize(flagsLine) == flagsLine,
    "flag diagnostics must survive sanitize untouched, got: \(DebugLogSanitizer.sanitize(flagsLine))"
)

let initLine = "[INIT] card element inject: ON | official lyrics hidden: ON | lyrics feature disabled: OFF"
require(
    DebugLogSanitizer.sanitize(initLine) == initLine,
    "startup marker line must survive untouched"
)

// ── ⑤ 幂等：同一行被处理两次的结果必须和一次一样 ────────────────────────────

let composite = "Bearer abc.def sp_dc=xyz "
    + "/devices/0123456789abcdef0123456789abcdef/x "
    + "spotify:user:someuser \"userID\":\"q1w2e3\""
let once = DebugLogSanitizer.sanitize(composite)
let twice = DebugLogSanitizer.sanitize(once)
require(once == twice, "sanitize must be idempotent:\n once=\(once)\n twice=\(twice)")

// ── ⑥ token 轮换序号：能看出换过，但不含 token 片段 ─────────────────────────

let tokenA1 = SpotifyTokenOrdinal.label(for: "token-A-aaaa")
let tokenA2 = SpotifyTokenOrdinal.label(for: "token-A-aaaa")
let tokenB = SpotifyTokenOrdinal.label(for: "token-B-bbbb")
require(tokenA1 == tokenA2, "the same token must keep the same ordinal")
require(tokenA1 != tokenB, "a rotated token must get a different ordinal")
require(
    tokenA1.hasPrefix("token#") && !tokenA1.contains("token-A"),
    "the ordinal label must not embed the token, got: \(tokenA1)"
)

// ── ⑦ 导出：曲目/艺人/曲名假名化，但同一 id 必须映射到同一个假名 ────────────

let logSample = """
[2026-09-30 09:53:56 +0000] [Scrollsita] manifest track=spotify:track:2Fkzxa6EiI43U6s8RkLjht body=584B has5=false elements=[5{spotify:track:2Fkzxa6EiI43U6s8RkLjht,spotify:section:0JQ5DB6s3cssW5Bo6cGq21} 2{spotify:artist:7p59bvZexyLPxLprpZRV6L}]
[2026-09-30 09:54:01 +0000] [Scrollsita] manifest track=spotify:track:4GUHLhDe4dn3KVe8nazF9w body=585B has5=true
[2026-09-30 09:53:53 +0000] [NetEase] Fetching lyrics for "短夜の星" - shallm
[2026-09-30 09:53:54 +0000] [NetEase] Chosen[0]: 短夜の星 (id 2044457637)
[2026-09-30 09:54:14 +0000] [Artwork] fetching https://i.scdn.co/image/ab67616d00001e02de2d1cf763ed06e6874e1e91 for 2e1gUS6Wv8GS8ZT6FMeE1J
[2026-09-30 09:54:10 +0000] [NetEase] yrc raw head: {"t":0,"c":[{"tx":"作词: "},{"tx":"MIMI"}]}
[2026-09-30 09:53:53 +0000] [NPVModule] body path=/merch-npv-service/v1/merch/track/2Fkzxa6EiI43U6s8RkLjht 126B printable={"code":5,"message":"No artists with merch for track_id 2Fkzxa6EiI43U6s8RkLjht, album_id 00C345qa1C9et1uiN0yP1I"}
[2026-09-30 09:53:56 +0000] [ScrollProbe] path=/scrollsita/v1/scroll/spotify:track:2Fkzxa6EiI43U6s8RkLjht body=584B hex512B=0a9d040a7c5a4f0a2673706f746966793a747261636b3a32466b7a786136456949343355367338526b4c6a6874
[2026-09-30 09:53:57 +0000] [NPVModule] hex path=/spotify.liveeventdistribution.v1.EventCardInfoService/EventCardInfo 256B=0a4068747470733a2f2f692e7363646e2e636f2f696d6167652f61623637363138363030303036363065616634633937663433663163393037626533316233376631
"""

let shared = DebugLogSanitizer.redactForSharing(logSample)

// 该被抹掉的：
require(!shared.contains("2Fkzxa6EiI43U6s8RkLjht"), "track id must not survive export")
require(!shared.contains("4GUHLhDe4dn3KVe8nazF9w"), "second track id must not survive export")
require(!shared.contains("7p59bvZexyLPxLprpZRV6L"), "artist id must not survive export")
require(!shared.contains("短夜の星"), "title must not survive export")
require(!shared.contains("shallm"), "artist name must not survive export")
require(!shared.contains("2044457637"), "NetEase song id must not survive export")
require(!shared.contains("ab67616d00001e02de2d1cf763ed06e6874e1e91"), "artwork hash must not survive export")
require(!shared.contains("2e1gUS6Wv8GS8ZT6FMeE1J"), "bare track id must not survive export")
require(!shared.contains("00C345qa1C9et1uiN0yP1I"), "album id must not survive export")
require(!shared.contains("MIMI"), "raw response-body head must be dropped in the shared copy")
// hex dump 里的字节是可解码还原的（`73706f746966793a747261636b3a` = `spotify:track:`），
// 模式匹配看不见 —— 只能整段打掉。
require(
    !shared.contains("0a9d040a7c5a4f0a2673706f746966793a747261636b3a"),
    "hex dump must not survive export (ScrollProbe)"
)
require(
    !shared.contains("0a4068747470733a2f2f692e7363646e"),
    "hex dump must not survive export (NPVModule)"
)
// `printable=` 是同一类「原始服务端内容」：里面是裸的艺人名/场馆/城市，模式匹配盖不住。
require(
    !shared.contains("No artists with merch"),
    "printable= dumps must not survive export"
)
require(shared.contains("126B printable=<redacted>"), "printable= must degrade to a marker")

// 该留下的（否则日志没法读了）：
require(
    shared.contains("spotify:section:0JQ5DB6s3cssW5Bo6cGq21"),
    "section URI must survive — element type identification depends on it"
)
require(shared.contains("[2026-09-30 09:53:56 +0000]"), "timestamps must survive")
// ⚠️ 这一条是回归点：`body=584B` 是**字节数**，不能让"响应体片段"那条规则把它连整行吞掉 ——
// 那一行（manifest + elements 清单）是元素类型排查的唯一判据。
require(
    shared.contains("body=584B has5=false elements=[5{"),
    "the manifest byte-count line must survive, got: \(shared)"
)
require(
    shared.contains("hex512B=<hex-redacted>") && shared.contains("256B=<hex-redacted>"),
    "hex dumps must degrade to a marker, not vanish, got: \(shared)"
)
require(
    shared.contains("manifest track=spotify:track:t1"),
    "the first track must keep a readable alias, got: \(shared)"
)
require(
    shared.contains("manifest track=spotify:track:t2"),
    "a different track must get a different alias"
)
require(
    shared.contains("[NPVModule] body path=/merch-npv-service/v1/merch/track/t1"),
    "paths must survive and keep the same alias as the manifest line"
)

// ── ⑧ 假名一致性：同一 id 在同一份日志里必须始终是同一个假名 ────────────────

let firstAliasUses = shared.components(separatedBy: "spotify:track:t1").count - 1
require(
    firstAliasUses >= 2,
    "the same track id appeared twice in the sample and must map to one alias, got \(firstAliasUses)"
)

print("Debug log redaction tests passed")
