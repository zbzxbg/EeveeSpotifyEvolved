<div align="center">

# EeveeSpotifyEvolved

Spotify, arranged like Apple Music.

[![iOS](https://img.shields.io/badge/iOS-17.4%2B-000000?style=for-the-badge&logo=ios&logoColor=white)](#requirements)
[![Spotify](https://img.shields.io/badge/Spotify-9.2.0-1ED760?style=for-the-badge&logo=spotify&logoColor=white)](#requirements)
[![License](https://img.shields.io/badge/License-GPL--3.0-2C6EDB?style=for-the-badge)](LICENSE)

[Download](https://github.com/zbzxbg/EeveeSpotifyEvolved/releases) · [Features](#features) · [Install](#install) · [Build](docs/BUILDING.md) · [Credits](#credits)

</div>

> [!NOTE]
> Tested on Spotify 9.2.0, and Local Premium is restored.

<p align="center">
  <img src="docs/screenshots/player.webp" width="15%" alt="Now Playing, immersive layout">
  <img src="docs/screenshots/lyrics.webp" width="15%" alt="Word-by-word lyrics with romanization and translation, credit line showing QQ Music">
  <img src="docs/screenshots/album.webp" width="15%" alt="Apple Music–style album page with a blurred backdrop">
  <img src="docs/screenshots/artist.webp" width="15%" alt="Apple Music–style artist page">
  <img src="docs/screenshots/home.webp" width="15%" alt="Home, with the liquid-glass tab bar">
  <img src="docs/screenshots/lock.webp" width="15%" alt="Lock screen, where the animated artwork and the sung line are drawn">
</p>

> *Make EeveeSpotify Great Again* — the slogan is a jest; the pages, the player and the lock screen below are not.

A derivative work based on [EeveeSpotifyReincarnated](https://github.com/SideloadLabs/EeveeSpotifyReincarnated) and [EeveeSpotify-ng](https://github.com/zbzxbg/EeveeSpotify-ng).

## Features

### Lyrics

- **12 sources** — Spicy Lyrics (needs your own client key), AMLL, PetitLyrics, NetEase, QQ Music, KuGou, Unison, Musixmatch, BiniLyrics, LRCLIB, Genius, plus an experimental Apple Music source.
- **Auto Select** — asks the sources in an order you choose and keeps the best answer: word-by-word beats line-by-line, which beats plain text; within the same tier it prefers the answer that also has the translation, official romanization or word-level romanization your settings ask for. A plain-text answer never ends the search.
- **Word-by-word karaoke** — real word timing, long-tone emphasis and interlude handling.

### Look and feel

- Apple Music–style album, playlist and artist pages.
- A single cover for playlists instead of the four-up mosaic.
- Liquid-glass tab bar and mini player.
- **Animated lock screen** (iOS 26+) — a short looping video in place of the still cover: Spotify's Canvas when the track has one, Apple Music's editorial video otherwise. A third source, rendering a loop from the cover itself, is a separate switch and off by default. Settings → Animated lock screen.
- **Lock screen lyrics** (iOS 26+) — the line being sung takes over the lock screen's full-screen artwork, with the next line dimmed under it. Every line is drawn once as a short clip and cached per track, so changes cost no network. Uses the same lyrics source as the in-app views. Settings → Lock screen lyrics.
- **Listening stats** — plays and listening time are recorded on the device, with 7-day, 30-day, 1-year and all-time views plus top songs and artists. A play counts after 30 seconds; history starts when the feature first runs. Settings → Listening stats.

<details>
<summary>Lyrics source details</summary>

- The default order is `AMLL → Spicy Lyrics → PetitLyrics → KuGou → NetEase → QQ Music → Unison → Musixmatch → BiniLyrics → LRCLIB → Genius`. Drag to reorder it under Settings → Lyrics → Lyrics Source Order.
- Spicy Lyrics is **skipped without being asked** when no client key is set (Settings → Lyrics), so a fresh install starts the chain at AMLL instead of waiting on a source that cannot answer.
- An answer that reports the track as **instrumental** ends the chain on the spot: no later source can carry lyrics for that track.
- The order only decides **who is asked first**; it never decides who wins. A word-by-word answer always beats a line-by-line one, which always beats plain text. Among answers with the same timing tier, the one that also carries a translation, official romanization, or word-level romanization (whichever switch asks for it) wins; a tie keeps the first arrival.
- With word-by-word lyrics on, Auto Select may keep asking until 4 seconds after the chain started — to upgrade a line-timed answer to a word-timed one, or to find one that also has the translation / romanization the current settings ask for. That cap exists so the lyrics card is not delayed past the point where it can still be built. It stops earlier when the best answer so far is line-timed and no source left in the chain can produce word timing.
- Auto Select is only offered when the now-playing style is **Immersive** or **Apple Music**. With Spotify's own layout the lyrics go straight into Spotify's card, so a single source is used instead.
- Word-timed sources: Spicy Lyrics, AMLL, PetitLyrics, NetEase (yrc), QQ Music (QRC), KuGou (KRC), Unison, Musixmatch (richsync), BiniLyrics, Apple Music TTML. LRCLIB is line-timed, Genius is plain text.
- The Apple Music official TTML source is under Settings → Experiments. It needs your own `media-user-token`, because Apple has no public lyrics API.

</details>

### Playback

- **Sleep timer** — pauses playback when the time is up, 1 to 90 minutes, and keeps counting with the screen off. Settings → Playback → Sleep timer.

### Audio

- **Cover pulse** — on the iOS 27 player the artwork breathes with the bass (low-band envelope, up to 2% scale) and the blurred backdrop follows it. Only animates while the player page is visible. Settings → Advanced features → Cover pulse.
- **Beat haptics** — kick and snare transients become light taps. Taps are throttled to one per 90 ms and step themselves down after 30 seconds of continuous triggering; strength has three steps. Settings → Advanced features → Beat haptics.
- Both read the decoded PCM through a read-only tap: the audio itself is never altered. If a track is already playing when you turn them on, pause and resume once so the tap attaches.
- **Audio effects** — a 10-band graphic equalizer (31.5 Hz to 16 kHz, ±12 dB) plus a preamp, inserted between Spotify's own source unit and the output unit. The first time you switch it on, restart Spotify so the tap can wrap the output callback; after that the sliders apply live. Lower the preamp if loud tracks start clipping. Settings → Advanced features → Audio Effects.

### Gestures

- **Head gestures** — nod once for the next track, shake once for the previous one. Reads the head-attitude stream that AirPods Pro / AirPods Max expose through Core Motion, so it needs headphones with motion sensors. Detection is deliberately conservative (two opposite swings, 1.5 s cooldown) and the switch is off by default. Settings → Advanced features → Head Gestures.
- The IPA build adds `NSMotionUsageDescription` to Spotify's Info.plist for the head gestures; the switch is inert when that string is missing.

## Install

| Your setup | Download |
| --- | --- |
| Jailbroken | `.deb` (rootless and roothide variants) |
| TrollStore | `-patched.ipa` |
| Paid developer certificate (1 year) | `-patched.ipa` |
| SideStore / AltStore / Sideloadly / free or enterprise certificate | `.ipa` (no patch) |
| LiveContainer | `.ipa` (no patch) |

Get everything from [Releases](https://github.com/zbzxbg/EeveeSpotifyEvolved/releases). Building it yourself — from your own decrypted Spotify 9.2.0 (or 9.1.88) IPA, with GitHub Actions or on a Mac — is covered in **[docs/BUILDING.md](docs/BUILDING.md)**.

> [!IMPORTANT]
> **Jailbroken users:** the `.deb` depends on `dev.theos.orion`. Add <https://repo.theos.dev/> to your package manager first, otherwise the install fails with an unmet dependency.

<details>
<summary>Why two IPAs? (pick one, not both)</summary>

- **`.ipa` (no patch)** — the plain build. Right for free and enterprise certificates, SideStore, AltStore and Sideloadly.
- **`-patched.ipa`** — the same build plus `zxPluginsInject.dylib`, a sideload shim that rebinds the keychain access group, neuters iCloud entitlements and stubs app groups. Pick it when a re-signed app misbehaves around login or the keychain. TrollStore doesn't re-sign, so the shim isn't strictly needed there.
- **LiveContainer** — it virtualises keychain, app groups and preferences itself, so the shim would conflict; use the unpatched `.ipa`.

Free profiles usually have no wildcard, so both builds ship without the Watch app and the native appex. How each file is produced: [docs/BUILDING.md](docs/BUILDING.md).

</details>

## Troubleshooting

Common issues, a longer FAQ, and why some Premium features stay locked: **[common_issues.md](common_issues.md)**.

## Requirements

- iOS 17.4 or later (iOS 26+ recommended for the liquid-glass look)
- Spotify 9.2.x (the baseline) or 9.1.x — current public release: [`v2.2.0`](https://github.com/zbzxbg/EeveeSpotifyEvolved/releases)

| Spotify | How far it has been checked |
|---|---|
| **9.2.0** | The baseline. Verified on iPhone 11 · iOS 27.0.1, certificate-signed (LCSign) and rootless deb, premium patching included: 9.2.0 split the account configuration response in two and the patcher handles both |
| **9.1.88** | Verified on iPhone 11 · iOS 27.0.1, certificate-signed (LCSign) and rootless deb. Shares the same hook set, so every hook target and UI identifier still resolves; premium patching uses the 9.1.88 configuration snapshot |
| **9.1.94** | Static check only: every hook target, `@objc` method list and runtime UI identifier still resolves; the on-device look-and-feel has not been re-calibrated |
| other **9.1.x / 9.2.x** | Untested, same code path |

## Credits

- [whoeevee](https://github.com/whoeevee) — the original EeveeSpotify project.
- [SideloadLabs](https://github.com/SideloadLabs/EeveeSpotifyReincarnated) — the Spicy Lyrics provider, logging and export.
- [LDDC](https://github.com/chenmozhijin/LDDC) and [pyqdes](https://github.com/naiyQAQ/pyqdes) — the key bytes and step order for the KuGou (KRC) and QQ Music (QRC) lyric decryption.
- [Taurus](https://github.com/samj-exe/taurus) — the provider list and the "ask in order, keep the finest timing" idea, the lock screen's clip-per-line delivery, and the sleep timer's countdown. Taurus is PolyForm Strict: **no code was copied**; see [docs/CREDITS.md](docs/CREDITS.md).

Full list of credits and licensing notes: [docs/CREDITS.md](docs/CREDITS.md).

## Legal

This repository contains derived technical identifiers and the scripts that regenerate them. It contains no Spotify binary, no decrypted `.ipa`, no audio or lyrics files, and no account credentials. Details, and how to request removal: [docs/LEGAL.md](docs/LEGAL.md).

## License

GPL-3.0, see [LICENSE](LICENSE). Not affiliated with, endorsed by, or connected to Spotify.
