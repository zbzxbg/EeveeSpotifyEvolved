import Foundation

/// `LockArtworkMatch` 的断言程序（纯 Foundation，CI 跑；见 `.github/workflows/tests.yml`）。
///
/// 为什么钉这一份：锁屏动效封面是按**专辑**找的（Apple 的 `editorialVideo` 挂在专辑上），
/// 而"这张专辑是不是这一首的"一旦判错，锁屏上放的就是**别人的封面** —— 用户看着像 bug，
/// 而我们此前只打 `apple square yes / tall yes`，日志里根本查不出来。
///
/// 现场（2026-11-27）：`REVIVE` / `NXRTHSTXR` 的锁屏是 IVE《REVIVE+》的画面。
/// 当时的比较是"归一化后互相包含"：`revive` ⊂ `revive+`，于是同名专辑串台，
/// 艺人一个字都没看。这一份把修好之后的判据固定下来。

var failures = 0

func require(_ condition: Bool, _ message: String) {
    if condition {
        print("  ok   \(message)")
    } else {
        failures += 1
        print("  FAIL \(message)")
    }
}

// MARK: - 专辑名：后缀可以不同，名字本身必须相同

require(LockArtworkMatch.albumNameKey("REVIVE+") == "revive+",
        "the plus survives normalisation")
require(LockArtworkMatch.sameAlbumName("REVIVE+", "REVIVE") == false,
        "REVIVE+ is not REVIVE (the IVE case)")
require(LockArtworkMatch.sameAlbumName("REVIVE", "REVIVE+") == false,
        "the IVE case is not symmetric-pass either")
require(LockArtworkMatch.sameAlbumName("REVIVE - EP", "REVIVE"),
        "the release suffix is not part of the name")
require(LockArtworkMatch.sameAlbumName("REVIVE - EP", "revive - ep"),
        "case does not matter")
require(LockArtworkMatch.sameAlbumName("REVIVE+", "REVIVE+"),
        "the same name still matches itself")
require(LockArtworkMatch.sameAlbumName("夜に駆ける", "夜に駆ける (Remastered)"),
        "a bracketed edition marker is dropped")
require(LockArtworkMatch.sameAlbumName("群青", "群青 - Single"),
        "CJK titles keep working with a suffix")
require(LockArtworkMatch.sameAlbumName("", "REVIVE") == false,
        "an empty name never matches")
require(LockArtworkMatch.sameAlbumName("   ", "REVIVE") == false,
        "a whitespace-only name never matches")
require(LockArtworkMatch.sameAlbumName("Revive", "Revive"),
        "plain equality still holds")

// MARK: - 艺人：至少一个词相同

require(LockArtworkMatch.sharesArtistName("NXRTHSTXR & MHMX", "NXRTHSTXR"),
        "the Spotify name is one of Apple's two artists")
require(LockArtworkMatch.sharesArtistName("NXRTHSTXR, MHMX", "MHNX") == false,
        "a near-miss spelling is not a shared word")
require(LockArtworkMatch.sharesArtistName("IVE", "NXRTHSTXR") == false,
        "IVE is not NXRTHSTXR")
require(LockArtworkMatch.sharesArtistName("A feat. B", "B"),
        "a feat. credit still shares the second artist")
require(LockArtworkMatch.sharesArtistName("feat.", "A") == false,
        "a bare connector has no tokens")
require(LockArtworkMatch.sharesArtistName("米津玄師", "米津玄師"),
        "CJK artist names tokenise as one word")

require(LockArtworkMatch.artistTokens("NXRTHSTXR & MHMX") == ["nxrthstxr", "mhmx"],
        "separators split the artists")
require(LockArtworkMatch.artistTokens("feat. ft. with and the").isEmpty,
        "connectors are not artists")

// MARK: - 一起用：IVE 那张专辑在这两关都过不去

let album = "REVIVE"
let iveAlbum = "REVIVE+"
let iveArtist = "IVE"
require(
    !(LockArtworkMatch.sameAlbumName(iveAlbum, album)
      && LockArtworkMatch.sharesArtistName(iveArtist, "NXRTHSTXR")),
    "the strict pair rejects IVE's REVIVE+ for this track"
)

// 正主那张要过：Apple 的 `REVIVE - EP` by `NXRTHSTXR & MHMX`。
require(
    LockArtworkMatch.sameAlbumName("REVIVE - EP", album)
        && LockArtworkMatch.sharesArtistName("NXRTHSTXR & MHMX", "NXRTHSTXR"),
    "the right album still passes both gates"
)

if failures > 0 {
    print("\n\(failures) failure(s)")
    exit(1)
}
print("\nall lock-art match assertions passed")
