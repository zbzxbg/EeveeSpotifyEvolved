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

## Versions

| Channel | Version | Spotify |
| --- | --- | --- |
| Public release | `v0.1.0` | 9.1.76 |
| Development | `v1.0.0-beta.63` | 9.1.88 |

Development version last updated: `2026/10/02`.

> [!WARNING]
> Development versions are not made publicly available to users.

## Verified Environment

`iPhone 11` · `Spotify 9.1.88` · `iOS 27.0` · certificate-signed · `LCSign` · rootless DEB

The modified features in this fork have been verified to work in this environment.

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
projects credited above.

> This is not legal advice. It is a statement of what the repository does and does not contain,
> which is the part a maintainer can actually control.

## Acknowledgements

- Thanks to [whoeevee](https://github.com/whoeevee) for the original EeveeSpotify project.
- Thanks to [SideloadLabs](https://github.com/SideloadLabs/EeveeSpotifyReincarnated) for creating the SpicyLyrics lyrics provider, as well as the logging and export functionality. The relevant code has been modified to fit this project.
- Thanks to the [MeloX](https://github.com/youshen2/MeloX) project for the inspiration behind this project's karaoke lyrics feature. The relevant code has been modified to fit this project.