# Credits

The following projects shaped this one. Some of their code was modified to fit; some only provided the approach or a protocol detail — each entry says which, because the difference matters for licensing.

## The fork this is built on

- **[EeveeSpotifyReincarnated](https://github.com/SideloadLabs/EeveeSpotifyReincarnated)** supplies the Spicy Lyrics provider, the in-app logging and the log export. Several other pieces are ported or rewritten from it — the file comments name the source in each case:
  - `Pages/Theme.swift` → the AMOLED palette and accent colour (`Appearance/Theme.swift`);
  - `Player/PlayerDeclutter.x.swift` → the Now Playing card declutter (`Appearance/PlayerDeclutter.x.swift`);
  - `Shared/Helpers/PerfMeter.swift` → the layout-pass timing meter;
  - `Sources/EeveeSpotifyC/ColorSwap.m` → the theme colour swizzles, carried over as-is (its own header still says so);
  - `Flags/RemoteFlagsHooks.x.swift` → the remote-flag page, and the curated flag keys in `.spotify-ipa/flag-table.txt`;
  - the Lrclib transport hardening, and the "persist both copies" behaviour in `SpotifyResponsePatcher`;
  - the Premium unlock configuration, the anti-logout keys, the round-artwork switch and the Instagram destination experiment.
- The Settings page arrangement follows the upstream one where the source says so (`EeveeExtrasSettingsView`, `EeveeFlagBrowserView`).

## Lyrics

- Thanks to [whoeevee](https://github.com/whoeevee) for creating the original EeveeSpotify project.
- The Spicy Lyrics lyrics provider, as well as the logging and export functionality, comes from [SideloadLabs](https://github.com/SideloadLabs/EeveeSpotifyReincarnated).
- The AMLL source and the TTML pipeline the word-by-word renderer is built on follow [amll.dev](https://amll.dev) and the [amll-dev](https://github.com/amll-dev) projects. The TTML parser and mapper here are our own Swift (`AmllTtmlParser.swift`, `AmllLyricsMapper.swift`).
- The Apple Music official TTML source (Settings → Experiments) follows [apple-music-downloader](https://github.com/zhaarey/apple-music-downloader) for finding the web player's developer token (`internal/amp-api/token.go`), and [Manzana-Apple-Music-Lyrics](https://github.com/dropcreations/Manzana-Apple-Music-Lyrics) for the songs/lyrics endpoints (`api/api.py`).
- NetEase's lyric source search logic is based on the following projects:
  - [NeteaseCloudMusicApi](https://github.com/Binaryify/NeteaseCloudMusicApi)
  - [Lyricify Lyrics Helper](https://github.com/WXRIW/Lyricify-Lyrics-Helper)
  - [163MusicLyrics](https://github.com/jitwxs/163MusicLyrics)
- The QQ Music and KuGou endpoints (`Providers/Web/QQMusic`, `Providers/Web/KuGou`) follow [Lyricify Lyrics Helper](https://github.com/WXRIW/Lyricify-Lyrics-Helper).
- The KuGou (KRC) and QQ Music (QRC) decryption follows [LDDC](https://github.com/chenmozhijin/LDDC) (`core/decryptor/`) and [pyqdes](https://github.com/naiyQAQ/pyqdes) for the key bytes and the order of the DES steps. The KRC unpacking here is our own Swift (`KrcText.swift`).
- **QQ Music's `QrcDES.swift` is a Swift translation** of [L-1124/QQMusicApi](https://github.com/L-1124/QQMusicApi)'s `qqmusic_api/algorithms/tripledes.py` (GPL-3.0-only), which in turn documents its origin in the C# [WXRIW/QQMusicDecoder](https://github.com/WXRIW/QQMusicDecoder). QQ does **not** use standard 3DES: its S-box S4 has `10` where the standard table has `1`, and its PC-2 step indexes the D half from `- 27` instead of `- 28`. That is why CommonCrypto's `kCCAlgorithm3DES` never decrypts this data. The S-box table and the three position permutations were generated from that Python source by script rather than retyped.
- The BiniLyrics and Unison endpoints came to us by way of [Taurus](https://github.com/samj-exe/taurus); the implementations — candidate gates, response handling, parse path — are our own, written against each service's public API. See the note on PolyForm Strict below.
- PetitLyrics, Musixmatch, LRCLIB and Genius are spoken to over the services' own public endpoints.
- The inspiration for the karaoke lyrics and interludes came from [MeloX](https://github.com/youshen2/MeloX).

## Lock screen

- The moving artwork comes from the services' own data, never from a file we ship: Spotify's **Canvas** (the `canvas.url` in track metadata, which the player only fills while Spotify's `canvas_enabled` flag is on) and Apple Music's **editorial video** (the album-level `editorialVideo` objects from `amp-api.music.apple.com`, read with the same web-player developer token credited above — Apple hangs them on albums, so a single often has none).
- Everything that is drawn or muxed is ours: the local cover loop (`FillArtworkRenderer`), the per-line lyric clip (`LyricClipRenderer`), the crop/transcode step (`AnimatedArtworkVideo`) and the hand-rolled HLS reassembly (`HLSVideoDownloader`).
- How a lyric clip reaches the lock screen — one clip per line, a fresh `artworkID` per line, the quarter-second GCD tick, the clock derived from elapsed time and rate, and the now-playing rewrite on each line — follows Taurus, reimplemented from scratch. See below.

## Taurus (PolyForm Strict 1.0.0)

`Taurus` 0.60.6 is licensed under **PolyForm Strict 1.0.0**, which does not permit distributing modified or derivative versions. **No Taurus source code was copied or translated into this repository.** What was taken is the *approach*, reimplemented from scratch in Swift:

- which provider each of its lyrics sources talks to, and the "word timing first, then closest length" ordering behind the BiniLyrics pick (`BiniLyricsRepository.swift`);
- the "ask in order, keep the finest timing, stop once something is timed" walk behind **Auto Select** (`LyricsAutoSelect.swift`);
- how it finds a playlist page's header when the page has none of the usual landmarks — by the view controller's class name rather than by an accessibility id (`EntityPageHeader.playlistHeaderRoot`, `EntityPageHeaderHooks`);
- the pointer that `TranslationSession` has a public initializer from iOS 26, which is what makes on-device translation usable outside SwiftUI (`OnDeviceLyricsTranslation.swift`);
- the lock screen's delivery mechanism: the clip handed over through `MPMediaItemAnimatedArtwork`, the new `artworkID` per line (the system only re-fetches when the ID changes), the quarter-second GCD tick (a run-loop timer gets throttled once the screen locks), the clock built from `elapsedPlaybackTime` and the playback rate, and the now-playing rewrite on every line change (`LockScreenLyricsController.swift`, `LyricClipRenderer.swift`). Its `LockScreenLyrics/` files were read for the mechanism only;
- the sleep timer: a GCD countdown against an absolute deadline, pausing only when something is actually playing, and coexisting with Spotify's own episode timer (`Playback/SleepTimer.swift`);
- its full takeover of the player menu (`Redesigned/Player/PlayerMenu.x`) was read and deliberately **not** adopted; the lyrics-offset row is appended as a table footer instead (`PlayerMenuOffsetRow.x.swift`).

All of the above was read from a locally supplied copy for reference only. If a rights holder disagrees with this use, open an issue and it will be reworked or removed.

## Look and feel

- **[spoti.pw](https://spoti.pw)** — the liquid glass look, and the code several screens were built from: the Home header (`Redesigned/Home/HomeHeader.x`), library rows (`Redesigned/Library/LibraryRows.x`), the Home shortcut tiles (`Redesigned/Home/HomeTiles.m`), the album / playlist field (`Redesigned/Playlist/PlaylistHeader.x`, `PlaylistField.x`, whose `SGRField` constants gave us the "fade to black from 55%" recipe), and the Now Playing background on the iOS 27-style player (`Redesigned/Player/PlayerField.x`). Code from v0.21.1 and earlier is GPL-3.0 (© Vojtěch Škopek); the full notice is available in-app under "Licenses". v0.22.0+ is PolyForm Strict: none of its source code was read or reused.
- **[kumone](https://github.com/missuo/kumone)** — the Now Playing side, at the level of actual layout, not just inspiration: the backdrop recipe (colour field → white radial glow from the top-left → 35% black at the bottom, 0.8 s crossfade between tracks, `endRadius: 700`), the lyrics block's spacing and its clearance above the progress bar, and the bare-glyph transport controls (`Appearance/NowPlayingBackdrop.swift`, `NowPlayingMetrics.swift`, `NowPlayingLyricsPlate*.swift`). kumone is LGPL-3.0 / GPL-3.0, compatible with this repository's GPL-3.0.

## Design references (no code)

- **Apple Music (Apple Inc.)** is the *look* these screens aim at — the Now Playing page (the iOS 27 arrangement: full-bleed cover, title under its lower edge, progress right below), the artist page, the Home header and the Library. What was taken is the arrangement and the type scale; no Apple code is involved, and the implementations are either our own or the spoti.pw / kumone code named above.
