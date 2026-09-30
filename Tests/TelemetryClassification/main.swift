import Foundation

// 上报端点分类的回归测试。
//
// 跑法（需要 Swift 工具链，Windows 上不可用）：
//   swiftc Tests/TelemetryClassification/main.swift \
//          Sources/EeveeSpotify/Privacy/TelemetryEndpointRules.swift \
//          -o /tmp/telemetry-tests && /tmp/telemetry-tests
//
// 这里只锁两件事：**该拦的拦住了**，以及**功能白名单压得住任何人**（包括用户自己
// 手写的关键词）—— 后者是"配置写错也不至于把 App 拦坏"的那道保险。

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError("FAIL: \(message)") }
}

private func url(_ value: String) -> URL {
    URL(string: value)!
}

// MARK: - 已知上报端点：拦

require(
    TelemetryEndpointRules.isTelemetry(url("https://log.spotify.com/int/v1/log")),
    "log.spotify.com must be classified as telemetry"
)
require(
    TelemetryEndpointRules.isTelemetry(url("https://spclient.wg.spotify.com/telemetry/v1/events")),
    "spotify reporting path must be classified as telemetry"
)
require(
    TelemetryEndpointRules.shouldBlock(
        url("https://log.spotify.com/int/v1/log"),
        extraKeywords: ""
    ),
    "known reporting endpoint must be blocked"
)

// MARK: - 真机 [Traffic] 日志里实际见过的上报端点

require(
    TelemetryEndpointRules.isTelemetry(
        url("https://spclient.wg.spotify.com/gabo-receiver-service/v3/events")
    ),
    "the gabo event receiver must be telemetry"
)
require(
    TelemetryEndpointRules.isTelemetry(
        url("https://gae2-spclient.spotify.com/gabo-receiver-service/public/v3/events")
    ),
    "the public gabo events path must be telemetry"
)
require(
    TelemetryEndpointRules.isTelemetry(
        url("https://spclient.wg.spotify.com/partner-userid/encrypted/crashlytics")
    ),
    "crashlytics attribution must be telemetry"
)
require(
    TelemetryEndpointRules.isTelemetry(
        url("https://spclient.wg.spotify.com/partner-userid/encrypted/branch")
    ),
    "branch attribution must be telemetry"
)
require(
    !TelemetryEndpointRules.shouldBlock(
        url("https://spclient.wg.spotify.com/partner-userid/encrypted/onetrust"),
        extraKeywords: ""
    ),
    "OneTrust consent must NOT be blocked (it is a compliance flow, not telemetry)"
)

// MARK: - 宽泛功能词不得遮住内置上报表
//
// 这是复审抓到的 push-blocking 缺陷的回归测试：早期把 `lyrics` / `shuffle` 这类
// 宽泛词和精确路径放在同一张白名单里，`shouldBlock` 会在白名单那一步就返回 false，
// 一批真实上报端点因此永远拦不到 —— 开关看上去打开了，其实什么都没做。

require(
    TelemetryEndpointRules.shouldBlock(
        url("https://spclient.wg.spotify.com/v1/log/shuffle-debug"),
        extraKeywords: ""
    ),
    "'shuffle' in a log path must not shadow the telemetry table"
)
require(
    TelemetryEndpointRules.shouldBlock(
        url("https://spclient.wg.spotify.com/analytics/lyrics-views"),
        extraKeywords: ""
    ),
    "'lyrics' in a reporting path must not shadow the telemetry table"
)
require(
    TelemetryEndpointRules.isCoreFunctional(
        url("https://spclient.wg.spotify.com/color-lyrics/v2/track/abc")
    ),
    "the precise allow-list must still protect the lyrics endpoint"
)

// …但宽泛功能词仍然拦得住"用户关键词把功能端点锁死"。
require(
    !TelemetryEndpointRules.shouldBlock(
        url("https://spclient.wg.spotify.com/nowplaying/lyrics-preview"),
        extraKeywords: "spclient.wg.spotify.com"
    ),
    "a user keyword must not be able to block a lyrics surface"
)

// MARK: - 功能端点：绝不拦（宁漏勿误）

require(
    !TelemetryEndpointRules.shouldBlock(
        url("https://spclient.wg.spotify.com/color-lyrics/v2/track/abc"),
        extraKeywords: ""
    ),
    "color-lyrics must never be blocked"
)
require(
    !TelemetryEndpointRules.shouldBlock(
        url("https://spclient.wg.spotify.com/collection/v1/library/items"),
        extraKeywords: ""
    ),
    "library endpoint must never be blocked"
)
require(
    !TelemetryEndpointRules.shouldBlock(
        url("https://apresolve.spotify.com/?type=accesspoint"),
        extraKeywords: ""
    ),
    "apresolve must never be blocked"
)

// 功能白名单优先级高于用户自定义关键词 —— 手滑把 "lyrics" 写进关键词也不该锁死歌词。
require(
    !TelemetryEndpointRules.shouldBlock(
        url("https://spclient.wg.spotify.com/color-lyrics/v2/track/abc"),
        extraKeywords: "color-lyrics, spclient.wg.spotify.com"
    ),
    "functional allow-list must outrank user keywords"
)
require(
    !TelemetryEndpointRules.shouldBlock(
        url("https://spclient.wg.spotify.com/v1/bootstrap"),
        extraKeywords: "bootstrap"
    ),
    "bootstrap must survive a user keyword that names it"
)

// MARK: - 拿不准：不拦

require(
    !TelemetryEndpointRules.isTelemetry(url("https://cdn.example.com/telemetry")),
    "telemetry path tokens must only apply to spotify domains"
)
require(
    !TelemetryEndpointRules.shouldBlock(url("https://example.com/telemetry"), extraKeywords: ""),
    "unknown third-party host must not be blocked without a keyword"
)

// MARK: - 用户自定义关键词

require(
    TelemetryEndpointRules.shouldBlock(
        url("https://spclient.wg.spotify.com/event/v1/batch"),
        extraKeywords: "event/v1"
    ),
    "user keyword must block a path that the default table does not cover"
)
require(
    TelemetryEndpointRules.shouldBlock(
        url("https://third.example.com/collect/v1"),
        extraKeywords: "third.example.com"
    ),
    "user keyword must be able to block a third-party host"
)
require(
    !TelemetryEndpointRules.shouldBlock(
        url("https://spclient.wg.spotify.com/event/v1/batch"),
        extraKeywords: "  "
    ),
    "blank keywords must not block anything"
)
require(
    TelemetryEndpointRules.parseUserKeywords(" a.com , b/c ;; d\n e ") == ["a.com", "b/c", "d", "e"],
    "keyword parsing must split on comma, semicolon, newline and blanks"
)

print("Telemetry classification regression tests passed")
