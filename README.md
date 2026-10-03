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
| Development | `v1.0.0-beta.83` | 9.1.88 |

Development version last updated: `2026/10/03`.

> [!WARNING]
> Development versions are not publicly distributed to users.

## System Requirements

- Minimum: iOS 16
- Recommended: iOS 26 or later

## Verified Environment

`iPhone 11` · `Spotify 9.1.88` · `iOS 27.0.1` · certificate-signed · `LCSign` · rootless DEB

Some of the modified features in this fork have been verified to work in this environment. (Because there are quite a few features, I can't test them all by myself.)

> [!TIP]
> If unexpected issues occur on the Now Playing page, such as lyrics not showing or outdated song teaser cards, simply exit the Now Playing page and re-enter it to resolve the issue. (This only applies to users who have not enabled "Hide Spotify song Now Playing modules".)

## Reverse-engineered Data and Takedowns

This project interoperates with Spotify's iOS client, which means parts of it were derived from a locally decrypted copy of that client. So that there is no ambiguity about what is (and is not) included in this repository:

**What is here.** Only derived *technical identifiers* needed to attach to the client's own extension points: Swift/ObjC class names, feature-flag names and scopes, gRPC service paths, view-hierarchy inventories, and a few resolver-configuration snapshots (`.bnk`). All of it can be regenerated from a copy you supply yourself — see `Scripts/dump-spotify-symbols.py` and `Tools/eevee-hookfinder/`.

**What is not here, and will not be added.**

- No audio, no streams, no decryption keys, no DRM circumvention.
- No lyrics files: lyrics are fetched at runtime by the user's device from third-party providers, and none of their content is bundled.
- No Spotify account credentials, tokens, or captured traffic.
- No Spotify binary, no decrypted `.ipa`, no bundled assets of any kind — `*.ipa`, `Decrypted IPA/` and `Tweaked IPA/` are intentionally ignored by git.

**If you are a rights holder** and want something removed, open an issue or contact the maintainer directly and it will be removed — no need for a formal takedown notice. The same applies to third-party projects credited in this document.

> This is not legal advice. It is a statement of what the repository does and does not contain, which is the part a maintainer can actually control.

## Acknowledgements

(The code from the following projects has been modified to fit this project.)

- Thanks to [whoeevee](https://github.com/whoeevee) for creating the original EeveeSpotify project.
- Thanks to [SideloadLabs](https://github.com/SideloadLabs/EeveeSpotifyReincarnated) for creating the SpicyLyrics lyrics provider, as well as the logging and export functionality.
- Thanks to the [MeloX](https://github.com/youshen2/MeloX) project for the inspiration behind this project's karaoke lyrics feature.
- Thanks to [spoti.pw](https://spoti.pw) for providing reference ideas for implementing the liquid glass pages in this repository. The referenced versions are v0.21.1 and earlier. (Because v0.21.1 and earlier are GPL-3.0, the same license as this repository, those versions have been read and their ideas reused; v0.22.0 and later are PolyForm Strict 1.0.0, and no source code from them has been read, disassembled, or reused.)
- [kumone](https://github.com/missuo/kumone) — source of layout ideas for the Now Playing page and main pages.

<details>
    
<summary>Building an IPA with this tweak</summary>
 
You do not need this to use the tweak — take a release. This section is for building a Spotify IPA with the tweak baked in. You supply your own decrypted Spotify IPA; this repository never ships one or says where to get one (see Reverse-engineered Data and Takedowns above).
 
### Which artifact?
 
Both pipelines build the same tweak; the difference is whether zxPluginsInject.dylib is LC-injected. That dylib is a sideload shim — keychain access-group rebind, iCloud entitlement neutering, app-group group.* stubs — all of which only break when an app is re-signed by a different team.

| Install method | Artifact | Why |
| --- | --- | --- |
| TrollStore | `-patched.ipa` | Not re-signed, entitlements intact; the shim is harmless and the Safari appex stays |
| Paid certificate (1 year) | `-patched.ipa` | The profile covers the extra bundles, and the shim covers what re-signing breaks |
| SideStore / AltStore / Sideloadly / free enterprise certificate | `.ipa` (no patch) | Those profiles usually have no wildcard, so the Watch app and native appex have to be stripped (`Tools/strip-ipa.sh`) |
| LiveContainer | `.ipa` (no patch) | LiveContainer virtualises keychain, app groups and preferences itself; the shim on top conflicts |
| Jailbroken | the `.deb` | `make package FINALPACKAGE=1` |

If a sideloaded build misbehaves around login or keychain, try the patched one — that is what the shim is for.
 
### CI (nothing installed locally)
 
Actions → Build IPA — patched or Build IPA — no patch → Run workflow: put the URL of your decrypted IPA in ipa_url (leave it empty to compile the tweak only). Note: The URL must be a direct download link to an .ipa file — opening or requesting the link returns the .ipa file directly, e.g. https://example.com/abc.ipa. Do not use cloud-drive share pages, login-gated links, or links that redirect to a preview page. Leave liquid_glass on unless you want Spotify's original look back — it removes UIDesignRequiresCompatibility, which is what puts iOS 26+ into compatibility mode.
 
### Locally (macOS)

```bash
./setup-build-ipa.sh /path/to/Spotify-vanilla.ipa

</details>