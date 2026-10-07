<div align="center">

# EeveeSpotifyEvolved

**Lyrics that actually work on Spotify 9.1.88** — word-by-word karaoke, seven sources with multi-level fallback, an Apple Music–style lyrics page, and a liquid-glass look.

[![iOS](https://img.shields.io/badge/iOS-16.1%2B-000000?style=for-the-badge&logo=ios&logoColor=white)](#system-requirements)
[![Spotify](https://img.shields.io/badge/Spotify-9.1.88-1ED760?style=for-the-badge&logo=spotify&logoColor=white)](#versions)
[![Swift](https://img.shields.io/badge/Swift-F05138?style=for-the-badge&logo=swift&logoColor=white)](#)
[![License](https://img.shields.io/badge/License-GPL--3.0-2C6EDB?style=for-the-badge)](LICENSE)

</div>

<!--
  Screenshot strip. Deliberately empty for now — the layout slot is reserved.

  When the photos exist, drop them in docs/screenshots/ and uncomment this block:

  <p align="center">
    <img src="docs/screenshots/now-playing.webp" width="16%" alt="Word-by-word lyrics on the Now Playing page">
    <img src="docs/screenshots/playlist.webp" width="16%" alt="Playlist page with the Apple Music style header">
    <img src="docs/screenshots/lyrics-settings.webp" width="16%" alt="Lyrics settings">
    <img src="docs/screenshots/album.webp" width="16%" alt="Album page">
    <img src="docs/screenshots/home.webp" width="16%" alt="Home, with the glass tab bar and mini player">
    <img src="docs/screenshots/queue.webp" width="16%" alt="Queue">
  </p>

  Shot list (6): (1) Now Playing with word-by-word lyrics and the provider credit line,
  (2) playlist page — AM header + single cover, (3) Lyrics settings with the Spicy Lyrics key row,
  (4) album page with the blurred backdrop, (5) Home — glass tab bar + mini bar capsule, (6) queue.

  Do NOT reuse C:\dsh\readpicture\*.jpg: those are 591x1280 debug captures, they still carry a
  personal playlist name in the nav title, and at least one of them shows a gray-band layout bug
  that has since been fixed. Re-shoot on device at native resolution and crop the status bar off
  the top (~60 px) before exporting.
-->

A derivative work based on [EeveeSpotifyReincarnated](https://github.com/SideloadLabs/EeveeSpotifyReincarnated) and [EeveeSpotify-ng](https://github.com/zbzxbg/EeveeSpotify-ng).

> [!IMPORTANT]
> After testing, this modified version can reliably display lyrics for every song on Spotify 9.1.88, including when the Genius fallback is enabled.


### Lyrics

- **Seven sources** — Spicy Lyrics, NetEase, AMLL, Musixmatch, PetitLyrics, LRCLIB and Genius.
- You can also choose a **lyrics fallback chain**: `Musixmatch → PetitLyrics → LRCLIB → Genius`.
- **Word-by-word karaoke** — real word timing, long-tone emphasis and interlude handling, not just line sync.
- **Apple Music–style lyrics page** — spring-driven line focus, glow reveal and its own typography pass.
- **Romanization** — Chinese, Korean and Japanese can be shown or hidden independently.

### Look and feel

- In one sentence: make Spotify look like Apple Music (this feature is under development…)

> [!TIP]
> If unexpected issues occur on the Now Playing page, such as lyrics not showing or outdated song teaser cards, simply exit the Now Playing page and re-enter it to resolve the issue. (This only applies to users who have not enabled "Hide Spotify song Now Playing modules".)

## Versions

| Channel | Version | Spotify |
| --- | --- | --- |
| Public release | [`v1.0.0`](https://github.com/zbzxbg/EeveeSpotifyEvolved/releases) | 9.1.88 |

Development last updated: `2026/10/06`(build 137).

> [!WARNING]
> Development versions are not publicly distributed to users.

## System Requirements

- Minimum: iOS 16.1
- Recommended: iOS 26 or later

## Install

Download the latest `.deb` from [Releases](https://github.com/zbzxbg/EeveeSpotifyEvolved/releases) if you are jailbroken, or build your own IPA below.

| Install method | Artifact | Why |
| --- | --- | --- |
| Jailbroken | the `.deb` | `make package FINALPACKAGE=1`; rootless and RootHide variants are both published |
| TrollStore | `-patched.ipa` | Not re-signed, entitlements intact; the shim is harmless and the Safari appex stays |
| Paid certificate (1 year) | `-patched.ipa` | The profile covers the extra bundles, and the shim covers what re-signing breaks |
| SideStore / AltStore / Sideloadly / leaked enterprise certificate (for free) | `.ipa` (no patch) | Those profiles usually have no wildcard, so the Watch app and native appex have to be stripped (`Tools/strip-ipa.sh`) |
| LiveContainer | `.ipa` (no patch) | LiveContainer virtualises keychain, app groups and preferences itself; the shim on top conflicts |

Both IPA pipelines build the same tweak; the difference is whether `zxPluginsInject.dylib` is LC-injected. That dylib is a sideload shim — keychain access-group rebind, iCloud entitlement neutering, app-group `group.*` stubs — all of which only break when an app is re-signed by a different team. If a sideloaded build misbehaves around login or keychain, try the patched one — that is what the shim is for.

> [!NOTE]
> **Orion runtime.** The `.deb` does not bundle `Orion.framework` — it declares `Depends: dev.theos.orion`, which your package manager resolves from <https://repo.theos.dev/> (add that repo, or the install fails with an unmet dependency). The IPA pipelines bundle the framework into the app instead, since a sideloaded app has no package manager to satisfy a dependency.

## Building an IPA with this tweak

<details>
<summary>CI (nothing installed locally), or a local build on macOS</summary>

You supply your own decrypted Spotify IPA; this repository never ships one or says where to get one (see Reverse-engineered data and takedowns below).

### CI (nothing installed locally)

Actions → **Build IPA — patched (Orion.framework + zxPluginsInject)** or **Build IPA — no patch (Orion.framework)** → Run workflow.

| Input | Meaning |
| --- | --- |
| `ipa_url` | **Required.** Direct download URL of your decrypted Spotify IPA. It must return the `.ipa` itself — e.g. `https://example.com/abc.ipa`. Do not use cloud-drive share pages, login-gated links, or links that redirect to a preview page. |
| `orion_url` | The bundled `Orion.zip`. Defaults to this project's own mirror — leave it alone unless it 404s. |
| `upload_method` | Where the finished IPA(s) go: `artifacts` (default), `filebin`, or `both`. |
| `liquid_glass` | On by default. Removes `UIDesignRequiresCompatibility` so iOS 26+ gets the new design language; set it to false to keep Spotify's own compatibility-mode look. |

There is no "compile the tweak only" mode — an empty `ipa_url` fails the download step. A third workflow, **Binary Symbol Diff**, also takes an `ipa_url`, but it diffs a Spotify build against the tracked symbol baseline instead of producing an IPA.

### Locally (macOS)

```
./setup-build-ipa.sh /path/to/Spotify-vanilla.ipa
```

`setup-build-ipa.sh` only installs the toolchain (Homebrew packages, `cyan`, `ipapatch`, Theos) and then hands off to `build-ipa-local.sh`, which does the actual work. To run the build directly once the toolchain is in place:

```
ALLOW_LIQUID_GLASS=0 ./build-ipa-local.sh /path/to/Spotify-vanilla.ipa
```

`ALLOW_LIQUID_GLASS` is the local equivalent of the CI `liquid_glass` input and defaults to `1` (on) — set it to `0` to keep Spotify's compatibility-mode look. It works through either entry point, since the environment is inherited.

</details>

## Verified Environment

`iPhone 11` · `Spotify 9.1.88` · `iOS 27.0.1` · certificate-signed · `LCSign` · rootless DEB

Some of the modified features in this fork have been verified to work in this environment. (Because there are quite a few features, I can't test them all by myself.)


## Acknowledgements

(The code from the following projects has been modified to fit this project.)

- Thanks to [whoeevee](https://github.com/whoeevee) for creating the original EeveeSpotify project.
- Thanks to [SideloadLabs](https://github.com/SideloadLabs/EeveeSpotifyReincarnated) for creating the SpicyLyrics lyrics provider, as well as the logging and export functionality.
- Thanks to the [MeloX](https://github.com/youshen2/MeloX) project for the inspiration behind this project's karaoke lyrics feature.
- Thanks to [spoti.pw](https://spoti.pw) for the liquid glass pages. Code and design from **v0.21.1 and earlier** (GPL-3.0, © Vojtěch Škopek) are **reused and modified** here (2026-10-03 onward) — full notice in-app under "Licenses". v0.22.0+ is PolyForm Strict: none of its source was read or reused.
- [kumone](https://github.com/missuo/kumone) — source of layout ideas for the Now Playing page and main pages.
- The app icons under `Assets/AppIcon/` are not my work: they come from upstream [EeveeSpotifyReincarnated](https://github.com/SideloadLabs/EeveeSpotifyReincarnated) and are re-distributed unchanged. Several are fan-made derivatives of third-party logos or characters; rights holders can open an issue and they will be removed.

## Reverse-engineered Data and Takedowns

This project interoperates with Spotify's iOS client, which means parts of it were derived from a locally decrypted copy of that client. So that there is no ambiguity about what is (and is not) included in this repository:

**What is here.** Derived *technical identifiers* needed to attach to the client's own extension points: Swift/ObjC class names, feature-flag names and scopes, gRPC service paths, view-hierarchy inventories, and a few resolver-configuration snapshots (`.bnk`) — plus the reverse-engineering notes and scripts used to derive them (`Tools/eevee-hookfinder/`). All of it can be regenerated from a copy you supply yourself — see `Scripts/dump-spotify-symbols.py`.

**What is not here, and will not be added.**

- No audio, no streams, no decryption keys, and nothing that decrypts Spotify's binary — you supply your own decrypted copy (see above).
- No lyrics files: lyrics are fetched at runtime by the user's device from third-party providers, and none of their content is bundled.
- No Spotify account credentials, tokens, or captured traffic.
- No Spotify application binary and no decrypted `.ipa` — `*.ipa`, `Decrypted IPA/` and `Tweaked IPA/` are intentionally ignored by git.

**If you are a rights holder** and want something removed, open an issue or contact the maintainer directly and it will be removed — no need for a formal takedown notice. The same applies to third-party projects credited in this document.

> This is not legal advice. It is a statement of what the repository does and does not contain, which is the part a maintainer can actually control.

## License

GPL-3.0 — see [LICENSE](LICENSE). Not affiliated with, endorsed by, or connected to Spotify.
