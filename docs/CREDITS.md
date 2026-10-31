# Credits

The following projects shaped this one. Some of their code was modified to fit; some only provided the approach or a protocol detail — each entry says which, because the difference matters for licensing.

## The fork this is built on

- **[EeveeSpotifyReincarnated](https://github.com/SideloadLabs/EeveeSpotifyReincarnated)** supplies the Spicy Lyrics provider, the in-app logging and the log export. Several other pieces are ported or rewritten from it — the file comments name the source in each case:
  - `Pages/Theme.swift` → the AMOLED palette and accent colour (`Appearance/Theme.swift`);
  - `Player/PlayerDeclutter.x.swift` → the Now Playing card declutter (`Appearance/PlayerDeclutter.x.swift`);
  - `Shared/Helpers/PerfMeter.swift` → the layout-pass timing meter;
  - `EncoreBridge.m` (`Sources/EeveeSpotifyC`) → our C bridge;
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
- The KuGou (KRC) and QQ Music (QRC) decryption follows [LDDC](https://github.com/chenmozhijin/LDDC) (`core/decryptor/`) and [pyqdes](https://github.com/naiyQAQ/pyqdes) for the key bytes and the order of the DES steps. The implementation here is our own Swift (`KrcText.swift`, `QrcText.swift`) — no code was copied.
- The BiniLyrics and Unison endpoints, and the rules for picking a candidate (title, artist, length), follow [Taurus](https://github.com/samj-exe/taurus) — see the note on PolyForm Strict below.
- PetitLyrics, Musixmatch, LRCLIB and Genius are spoken to over the services' own public endpoints.
- The inspiration for the karaoke lyrics and interludes came from [MeloX](https://github.com/youshen2/MeloX).

### Taurus (PolyForm Strict 1.0.0)

`Taurus` 0.60.5 is licensed under **PolyForm Strict 1.0.0**, which does not permit distributing modified or derivative versions. **No Taurus source code was copied or translated into this repository.** What was taken is the *approach*, reimplemented from scratch in Swift:

- which provider each of its lyrics sources talks to, and how a candidate is matched (`LyricsMatch.swift`);
- the "ask in order, keep the finest timing, stop once something is timed" walk behind **Auto Select** (`LyricsAutoSelect.swift`);
- how it finds a playlist page's header when the page has none of the usual landmarks — by the view controller's class name rather than by an accessibility id (`EntityPageHeader.playlistHeaderRoot`, `EntityPageHeaderHooks`);
- its full takeover of the player menu (`Redesigned/Player/PlayerMenu.x`) was read and deliberately **not** adopted; the lyrics-offset row is appended as a table footer instead (`PlayerMenuOffsetRow.x.swift`).

All of the above was read from a locally supplied copy for reference only. If a rights holder disagrees with this use, open an issue and it will be reworked or removed.

## Look and feel

- The liquid glass-related design was inspired by [spoti.pw](https://spoti.pw). Code from v0.21.1 and earlier (GPL-3.0, © Vojtěch Škopek) is used; the full notice is available in-app under "Licenses". v0.22.0+ is PolyForm Strict: none of its source code was read or reused.
- The layout design of the Now Playing page and the main pages was inspired by [kumone](https://github.com/missuo/kumone). The Now Playing backdrop — a colour field, a white radial glow from the top-left and 35% black at the bottom, with a 0.8 s crossfade between tracks and `endRadius: 700` — comes from its `NowPlayingView.backdrop` (`Appearance/NowPlayingBackdrop.swift`). kumone is LGPL-3.0 / GPL-3.0, compatible with this repository's GPL-3.0.
- The artist page design was inspired by Apple Music from Apple Inc.
