import Foundation

// MARK: - 「歌名 - 歌手」页眉行（`LyricsCreditLine.isTitleArtistHeader`）
//
// 跑法（CI 里就是这条，见 `.github/workflows/tests.yml`）：
//   swiftc Sources/EeveeSpotify/Lyrics/Models/LyricsMatch.swift \
//          Sources/EeveeSpotify/Lyrics/Repositories/LyricsMarkers.swift \
//          Tests/LyricsHeaderLine/main.swift -o lyrics-header-line-tests
//
// 酷狗 / QQ 的歌词文件第一行常是「歌名 - 歌手」或「歌手 - 歌名」——
// 它不是歌词，却带着时间戳，前面几道过滤器都接不住。
//
// 这里钉住四件事：
//   ① 两种顺序都要删（只认一种时另一种会原样留在第一行）；
//   ② 破折号两侧**必须**分别是歌名与歌手，真歌词里的破折号不能误伤；
//   ③ 没有 `[ti:]` / `[ar:]` 文件头时不动（认不出就不猜）；
//   ④ 只命中一侧时不动（宁可留一行垃圾，也不删掉真歌词）。

func writeDebugLog(_ message: String) {}

extension String {
    var localized: String { self }
}

var failures = 0

func require(_ condition: Bool, _ message: String) {
    if condition {
        print("  ok   \(message)")
    } else {
        failures += 1
        print("  FAIL \(message)")
    }
}

let title = "夏霞"
let artist = "あたらよ"

// MARK: - ① 两种顺序

require(
    LyricsCreditLine.isTitleArtistHeader("夏霞 - あたらよ", title: title, artist: artist),
    "title - artist is dropped"
)
require(
    LyricsCreditLine.isTitleArtistHeader("あたらよ - 夏霞", title: title, artist: artist),
    "artist - title is dropped"
)

// MARK: - ② 只认"两侧分别是歌名与歌手"

require(
    !LyricsCreditLine.isTitleArtistHeader("夜に駆ける - 夏霞", title: title, artist: artist),
    "a lyric line with a dash is kept when neither side is the artist"
)
require(
    !LyricsCreditLine.isTitleArtistHeader("夏霞 - 夜に駆ける", title: title, artist: artist),
    "a lyric line with the title on one side is kept when the other side is not the artist"
)
require(
    !LyricsCreditLine.isTitleArtistHeader("夏霞-あたらよ", title: title, artist: artist),
    "no spaces around the dash means it is not the header form"
)

// MARK: - ③ 没有文件头 → 不动

require(
    !LyricsCreditLine.isTitleArtistHeader("夏霞 - あたらよ", title: nil, artist: artist),
    "no [ti:] tag means nothing is dropped"
)
require(
    !LyricsCreditLine.isTitleArtistHeader("夏霞 - あたらよ", title: title, artist: nil),
    "no [ar:] tag means nothing is dropped"
)

// MARK: - ④ 括注后缀（`[ti:夏霞 (Instrumental)]` 这类写法）

require(
    LyricsCreditLine.isTitleArtistHeader("夏霞 (Instrumental) - あたらよ", title: title, artist: artist),
    "a bracketed suffix on the title still matches"
)

// MARK: - ⑤ 没有文件头时，用**曲目元数据**判（酷狗常给空 `[ti:]` / `[ar:]`）

require(
    LyricsCreditLine.isTitleArtistHeader(
        "独自 (DJ版) - 王晗General/造梦师DreamMaker",
        titleCandidates: ["独自"],
        artists: ["王晗General", "造梦师DreamMaker"]
    ),
    "artist roster split on the slash matches the header written in the body"
)
require(
    LyricsCreditLine.isTitleArtistHeader(
        "DUSTCELL - 独自",
        titleCandidates: ["独自"],
        artists: ["DUSTCELL"]
    ),
    "artist - title in the body matches the track metadata"
)
require(
    !LyricsCreditLine.isTitleArtistHeader(
        "夜に駆ける - あたらよ",
        titleCandidates: ["独自"],
        artists: ["DUSTCELL"]
    ),
    "a lyric line with a dash is kept when neither side is this track's title or artist"
)
require(
    !LyricsCreditLine.isTitleArtistHeader(
        "独自 - 夜に駆ける",
        titleCandidates: ["独自"],
        artists: ["DUSTCELL"]
    ),
    "the title alone is not enough - the other side must be the artist"
)
require(
    !LyricsCreditLine.isTitleArtistHeader(
        "独自 - 王晗General",
        titleCandidates: [],
        artists: ["王晗General"]
    ),
    "no title candidates means nothing is dropped"
)
require(
    !LyricsCreditLine.isTitleArtistHeader(
        "独自 - 王晗General",
        titleCandidates: ["独自"],
        artists: []
    ),
    "no artist names means nothing is dropped"
)

if failures == 0 {
    print("LyricsHeaderLine: all assertions passed")
} else {
    print("LyricsHeaderLine: \(failures) failure(s)")
    exit(1)
}
