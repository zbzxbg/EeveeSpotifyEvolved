# EeveeSpotifyEvolved

A Spotify iOS tweak: fixed lyrics on Spotify 9.1.88, word-by-word karaoke lyrics, more lyrics sources, and a liquid-glass UI.

## A derivative work based on [EeveeSpotifyReincarnated](https://github.com/SideloadLabs/EeveeSpotifyReincarnated) and [EeveeSpotify-ng](https://github.com/zbzxbg/EeveeSpotify-ng).

> [!IMPORTANT]
> After testing, this modified version can reliably display lyrics for every song on Spotify 9.1.88, including when the Genius fallback is enabled.

## Features

- Fixed the issue of missing lyrics modules for some songs on Spotify 9.1.88.
- Word-by-word lyrics: karaoke-style word-by-word lyrics.
- More lyrics sources: NetEase Cloud Music, AMLL, and multi-level fallback (`Musixmatch → PetitLyrics → LRCLIB → Genius`).
- Chinese, Korean, and Japanese can be configured separately to show or hide romanization.

## Versions

| Channel | Version | Spotify |
| --- | --- | --- |
| Public release | `v0.1.0` | 9.1.76 |
| Development | `v1.0.0-beta.103` | 9.1.88 |

Development version last updated: `2026/10/05`.

> [!WARNING]
> Development versions are not publicly distributed to users.

## System Requirements

- Minimum: iOS 16.1
- Recommended: iOS 26 or later

## Verified Environment

`iPhone 11` · `Spotify 9.1.88` · `iOS 27.0.1` · certificate-signed · `LCSign` · rootless DEB

Some of the modified features in this fork have been verified to work in this environment. (Because there are quite a few features, I can't test them all by myself.)

> [!TIP]
> If unexpected issues occur on the Now Playing page, such as lyrics not showing or outdated song teaser cards, simply exit the Now Playing page and re-enter it to resolve the issue. (This only applies to users who have not enabled "Hide Spotify song Now Playing modules".)

## Reverse-engineered Data and Takedowns

This project interoperates with Spotify's iOS client, which means parts of it were derived from a locally decrypted copy of that client. So that there is no ambiguity about what is (and is not) included in this repository:

**What is here.** Derived *technical identifiers* needed to attach to the client's own extension points: Swift/ObjC class names, feature-flag names and scopes, gRPC service paths, view-hierarchy inventories, and a few resolver-configuration snapshots (`.bnk`) — plus the reverse-engineering notes and scripts used to derive them (`Tools/eevee-hookfinder/`). All of it can be regenerated from a copy you supply yourself — see `Scripts/dump-spotify-symbols.py`.

**What is not here, and will not be added.**

- No audio, no streams, no decryption keys, and nothing that decrypts Spotify's binary — you supply your own decrypted copy (see below).
- No lyrics files: lyrics are fetched at runtime by the user's device from third-party providers, and none of their content is bundled.
- No Spotify account credentials, tokens, or captured traffic.
- No Spotify application binary and no decrypted `.ipa` — `*.ipa`, `Decrypted IPA/` and `Tweaked IPA/` are intentionally ignored by git.

**If you are a rights holder** and want something removed, open an issue or contact the maintainer directly and it will be removed — no need for a formal takedown notice. The same applies to third-party projects credited in this document.

> This is not legal advice. It is a statement of what the repository does and does not contain, which is the part a maintainer can actually control.

## Acknowledgements

(The code from the following projects has been modified to fit this project.)

- Thanks to [whoeevee](https://github.com/whoeevee) for creating the original EeveeSpotify project.
- Thanks to [SideloadLabs](https://github.com/SideloadLabs/EeveeSpotifyReincarnated) for creating the SpicyLyrics lyrics provider, as well as the logging and export functionality.
- Thanks to the [MeloX](https://github.com/youshen2/MeloX) project for the inspiration behind this project's karaoke lyrics feature.
- Thanks to [spoti.pw](https://spoti.pw) for the liquid glass pages. Code and design from **v0.21.1 and earlier** (GPL-3.0, © Vojtěch Škopek) are **reused and modified** here (2026-10-03 onward) — full notice in-app under "Licenses". v0.22.0+ is PolyForm Strict: none of its source was read or reused.
- [kumone](https://github.com/missuo/kumone) — source of layout ideas for the Now Playing page and main pages.
- The app icons under `Assets/AppIcon/` are not my work: they come from upstream [EeveeSpotifyReincarnated](https://github.com/SideloadLabs/EeveeSpotifyReincarnated) and are re-distributed unchanged. Several are fan-made derivatives of third-party logos or characters; rights holders can open an issue and they will be removed.

<details>
    
<summary>Building an IPA with this tweak</summary>
 
If you only need the .deb (or if you're jailbroken), just download the latest release. This section is a guide to building a Spotify IPA with the tweak baked in. You supply your own decrypted Spotify IPA; this repository never ships one or says where to get one (see Reverse-engineered Data and Takedowns above).
 
### Which artifact?
 
Both pipelines build the same tweak; the difference is whether zxPluginsInject.dylib is LC-injected. That dylib is a sideload shim — keychain access-group rebind, iCloud entitlement neutering, app-group group.* stubs — all of which only break when an app is re-signed by a different team.

| Install method | Artifact | Why |
| --- | --- | --- |
| TrollStore | `-patched.ipa` | Not re-signed, entitlements intact; the shim is harmless and the Safari appex stays |
| Paid certificate (1 year) | `-patched.ipa` | The profile covers the extra bundles, and the shim covers what re-signing breaks |
| SideStore / AltStore / Sideloadly / leaked enterprise certificate (for free) | `.ipa` (no patch) | Those profiles usually have no wildcard, so the Watch app and native appex have to be stripped (`Tools/strip-ipa.sh`) |
| LiveContainer | `.ipa` (no patch) | LiveContainer virtualises keychain, app groups and preferences itself; the shim on top conflicts |
| Jailbroken | the `.deb` | `make package FINALPACKAGE=1` |

If a sideloaded build misbehaves around login or keychain, try the patched one — that is what the shim is for.
 
> [!NOTE]
> **Orion runtime.** The `.deb` does not bundle `Orion.framework` — it declares `Depends: dev.theos.orion`, which your package manager resolves from <https://repo.theos.dev/> (add that repo, or the install fails with an unmet dependency). The IPA pipelines bundle the framework into the app instead, since a sideloaded app has no package manager to satisfy a dependency.

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