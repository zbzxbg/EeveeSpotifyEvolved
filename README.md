> Based on [EeveeSpotifyReincarnated](https://github.com/SideloadLabs/EeveeSpotifyReincarnated) and [EeveeSpotify-ng](https://github.com/zbzxbg/EeveeSpotify-ng).
>
> This repository is independently maintained by me and is not affiliated with whoeevee or SideloadLabs.

> [!IMPORTANT]
> After testing, this modded version can reliably display lyrics for every song on Spotify 9.1.88, including when the Genius fallback is enabled.

## Features

- **Core fix**: Fixes the missing lyrics module issue on Spotify 9.1.88 for some songs.
- **Word-by-word lyrics**: Karaoke-style word-by-word lyrics.
- **More lyrics sources**: NetEase, AMLL, and a multi-level fallback provider (`Musixmatch → PetitLyrics → LRCLIB → Genius`).
- **Per-language romanization**: Chinese, Korean, and Japanese can be configured separately. Upstream only has a single “Enable romanization” switch.
- **Disable lyrics**: Option to disable lyrics.
- **Cleaner lyrics**: Removes interlude symbols such as `♪`.
- **Future updates**: Not limited to Spotify 9.1.88; this project will continue to follow Spotify updates.

### Interface

- **Now Playing page, Apple Music style**: a cover-coloured gradient backdrop; an optional *one screen*
  layout that folds every card away and pins the list so it cannot be scrolled; an optional volume
  slider along the bottom.
- **Liquid glass** on the mini player bar and the tab bar, plus cleaner-chrome switches for the mini
  player bar, the sing-along line, the home header and the Connect / add-to buttons.
- **Player gestures**: double tap to skip tracks or seek 15 seconds, switchable per surface.
- **Library**: large title aligned left.
- **Blocked artists**: skip at the start of a track, with a managed list.
- **SponsorBlock**: categories, automatic and manual skipping, voting and submitting.
- **Flag overrides** with a catalogue measured on a real device, and a **reduce-interventions** page
  that turns Spotify's own messaging flags into plain switches.

## Versions

| Channel | Version | Spotify |
| --- | --- | --- |
| Public release | `v0.1.0` | 9.1.76 |
| Development | `v1.0.0-beta.72` | 9.1.88 |

Development version last updated: `2026/10/02`.

> [!WARNING]
> Development versions are not made publicly available to users.

## Verified Environment

`iPhone 11` · `Spotify 9.1.88` · `iOS 27.0.1` · certificate-signed · `LCSign` · rootless DEB

The modified features in this fork have been verified to work in this environment.

> [!NOTE]
> The two most recent Now Playing switches are the exception: the **one-screen layout** and the
> **bottom volume slider** are new and are still being verified on the device listed above.

> [!TIP]
> If there are unexpected issues on the Now Playing page, such as lyrics not showing or outdated song teaser cards, simply exit the Now Playing page and re-enter it to resolve the issue.

## Reverse-engineered data, and takedowns

This project interoperates with Spotify's iOS client, which means parts of it were derived from
a locally decrypted copy of that client. So that there is no ambiguity about what is (and is not)
in this repository:

**What is here.** Only derived *technical identifiers* needed to attach to the client's own
extension points: Swift/ObjC class names, feature-flag names and scopes, gRPC service paths,
view-hierarchy inventories, and a few resolver-configuration snapshots (`.bnk`). All of it is
regenerable from a copy you supply yourself — see `Scripts/dump-spotify-symbols.py` and
`Tools/eevee-hookfinder/`.

**What is not here, and will not be added.**

* No audio, no streams, no decryption keys, no DRM circumvention.
* No lyrics files: lyrics are fetched at runtime from third-party providers by the user's device,
  and none of their content is bundled.
* No Spotify account credentials, tokens, or captured traffic.
* No Spotify binary, no decrypted `.ipa`, no bundled assets of any kind — `*.ipa`,
  `Decrypted IPA/` and `Tweaked IPA/` are ignored by git on purpose.

**If you are a rights holder** and want something removed, open an issue or contact the maintainer
directly and it will be removed — no need for a formal takedown. The same applies to third-party
projects credited in this document.

> This is not legal advice. It is a statement of what the repository does and does not contain,
> which is the part a maintainer can actually control.

## Acknowledgements

- Thanks to [whoeevee](https://github.com/whoeevee) for the original EeveeSpotify project.
- Thanks to [SideloadLabs](https://github.com/SideloadLabs/EeveeSpotifyReincarnated) for creating the SpicyLyrics lyrics provider, as well as the logging and export functionality. The relevant code has been modified to fit this project.
- Thanks to the [MeloX](https://github.com/youshen2/MeloX) project for the inspiration behind this project's karaoke lyrics feature. The relevant code has been modified to fit this project.

Two more projects shaped this fork.

- [spoti.pw](https://spoti.pw) — **roadmap reference, and up to `v0.21.1` a licence-compatible source.**
  `v0.21.1` and earlier are **GPL-3.0**, the same licence as this repository, so those tags were read
  and their approach reused; `v0.22.0` and later are **PolyForm Strict 1.0.0** and **no source from
  them was read, disassembled or reused**. What has been taken so far is the Now Playing page's
  one-screen layout — `Redesigned/Player/PlayerCards.x` + `PlayerScroll.x`, reimplemented here in
  Swift and credited in the file headers. The port assessment, including which of its hook targets
  still exist on Spotify 9.1.88, is
  [SPOTIPW_0211_PORT_ASSESSMENT.md](Tools/eevee-hookfinder/SPOTIPW_0211_PORT_ASSESSMENT.md); the
  feature-gap comparison is [SPOTIPW_GAP.md](Tools/eevee-hookfinder/SPOTIPW_GAP.md).
- [kumone](https://github.com/missuo/kumone) — [**source of layout ideas for the Now Playing page and main pages**](Tools/eevee-hookfinder/KUMONE_REFERENCE.md).

Neither project endorses this fork, and neither is affiliated with it.