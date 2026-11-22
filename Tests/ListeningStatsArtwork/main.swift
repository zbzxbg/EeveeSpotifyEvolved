import Foundation

// MARK: - 「听歌统计」封面补全的**纯逻辑**
//
// 为什么要有这个测试：`ListeningStatsArtwork` 是"导入的历史没有封面"的补丁，只在用户翻
// 「听歌统计」页时才触发 —— 出错的代价是"导入的歌永远灰底"，而本机没有 Swift 工具链
// （只有 Windows + iPhone），这个文件在打包之前**没有任何东西**编译过它。这里把两件最
// 容易写错的事钉死：
//
// ① **曲目 id 的判定** —— `fnv1a:` 兜底 id / 本地文件 / 长度不对的值不能被当成曲目 id
//    拿去查（拿歌名去搜会把别的版本的封面贴上来，比没有封面更糟）；
// ② **JSON 里 `null` 的容错** —— `GET /v1/tracks?ids=` 对查不到的 id 回 `null`，整份
//    `tracks` 数组里就夹着 `null`。若整份转成 `[[String: Any]]` 会**整批失败**（一个
//    查不到的 id 就让同一批 50 首全没有封面）。
//
// 跑法（CI 里就是这条）：
//   swiftc Sources/EeveeSpotify/Stats/ListeningStatsModel.swift \
//          Sources/EeveeSpotify/Stats/ListeningStatsArtwork.swift \
//          Tests/ListeningStatsArtwork/main.swift -o listening-stats-artwork-tests

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fatalError("FAIL: \(message)")
    }
}

private let trackID = "4uLU6hMCjMI75M1A2tKUQC"

// MARK: - 1. 曲目 id 判定

require(
    ListeningStatsArtwork.spotifyID(from: trackID) == trackID,
    "a bare 22-character base62 id is what the Web API wants"
)
require(
    ListeningStatsArtwork.spotifyID(from: "spotify:track:" + trackID) == trackID,
    "the URI prefix is stripped (old rows may still carry it)"
)
require(
    ListeningStatsArtwork.spotifyID(from: "  \(trackID)\n") == trackID,
    "surrounding whitespace is not part of the id"
)
require(
    ListeningStatsArtwork.spotifyID(from: "fnv1a:0123456789abcdef") == nil,
    "the FNV-1a fallback id is not a Spotify track id"
)
require(
    ListeningStatsArtwork.spotifyID(from: "Artist|Title|215") == nil,
    "a local file id (spotify:local: remainder) is not a Spotify track id"
)
require(
    ListeningStatsArtwork.spotifyID(from: "spotify:track:tooshort") == nil,
    "a wrong-length id is refused"
)
require(
    ListeningStatsArtwork.spotifyID(from: "4uLU6hMCjMI75M1A2tKUQ-") == nil,
    "a 22-character value with a non-base62 character is refused"
)
require(
    ListeningStatsArtwork.spotifyID(from: "") == nil,
    "an empty id is refused"
)

// MARK: - 2. `/v1/tracks` 的 JSON：`null` 不能毒掉整批

/// 三条曲目：第一首 640/300/64 三档封面、第二首被查成 `null`、第三首只有 64px。
private let tracksJSON = """
{"tracks":[
 {"id":"\(trackID)","name":"One",
  "album":{"images":[
    {"url":"https://i.scdn.co/image/640","width":640,"height":640},
    {"url":"https://i.scdn.co/image/300","width":300,"height":300},
    {"url":"https://i.scdn.co/image/64","width":64,"height":64}
  ]}},
 null,
 {"id":"1uLU6hMCjMI75M1A2tKUQD","name":"Two",
  "album":{"images":[{"url":"https://i.scdn.co/image/small","width":64,"height":64}]}}
]}
"""

let tracks = ListeningStatsArtwork.artworkURLs(in: Data(tracksJSON.utf8))
require(tracks.count == 2, "the null entry is skipped, the other two are kept")
require(
    tracks[trackID] == "https://i.scdn.co/image/300",
    "44pt rows want the smallest image at least 160px wide, not the 640px one"
)
require(
    tracks["1uLU6hMCjMI75M1A2tKUQD"] == "https://i.scdn.co/image/small",
    "when nothing reaches 160px the largest available one is used"
)

// 坏 JSON / 空对象都不许崩、也不许造出封面。
require(
    ListeningStatsArtwork.artworkURLs(in: Data("not json".utf8)).isEmpty,
    "a malformed body yields no covers"
)
require(
    ListeningStatsArtwork.artworkURLs(in: Data("{}".utf8)).isEmpty,
    "an empty body yields no covers"
)
require(
    ListeningStatsArtwork.artworkURLs(in: Data("{\"tracks\":null}".utf8)).isEmpty,
    "`tracks: null` yields no covers"
)

// MARK: - 3. 播客单集：封面直接挂在条目上（没有 album）

/// 单集接口的形状：`images` 与曲目的 `album.images` 同级不同处。
private let episodesJSON = """
{"episodes":[
 {"id":"3uLU6hMCjMI75M1A2tKUQE","name":"Episode",
  "images":[
    {"url":"https://i.scdn.co/image/ep640","width":640,"height":640},
    {"url":"https://i.scdn.co/image/ep300","width":300,"height":300}
  ]}
]}
"""

let episodes = ListeningStatsArtwork.artworkURLs(in: Data(episodesJSON.utf8))
require(
    episodes["3uLU6hMCjMI75M1A2tKUQE"] == "https://i.scdn.co/image/ep300",
    "an episode's own `images` are read (same picking rule)"
)

print("Listening stats artwork tests passed")
