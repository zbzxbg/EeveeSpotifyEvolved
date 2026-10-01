> Based on [EeveeSpotifyReincarnated](https://github.com/SideloadLabs/EeveeSpotifyReincarnated) and [EeveeSpotify-ng](https://github.com/zbzxbg/EeveeSpotify-ng).
>
> This repository is independently maintained by me and is not affiliated with whoeevee or SideloadLabs.

> [!IMPORTANT]
> After testing, this modded version can reliably display lyrics for every song on Spotify 9.1.86, including when the Genius fallback is enabled.

## Features

- **Core fix**: Fixes the missing lyrics module issue on Spotify 9.1.86 for some songs.
- **Word-by-word lyrics**: Karaoke-style word-by-word lyrics.
- **More lyrics sources**: NetEase, AMLL, and a multi-level fallback provider (`Musixmatch → PetitLyrics → LRCLIB → Genius`).
- **Per-language romanization**: Chinese, Korean, and Japanese can be configured separately. Upstream only has a single “Enable romanization” switch.
- **Disable lyrics**: Option to disable lyrics.
- **Cleaner lyrics**: Removes interlude symbols such as `♪`.
- **Future updates**: Not limited to Spotify 9.1.86; this project will continue to follow Spotify updates.

## Versions

| Channel | Version | Spotify |
| --- | --- | --- |
| Public release | `v0.1.0` | 9.1.76 |
| Development | `v1.0.0-beta.53` | 9.1.86 |

Development version last updated: `2026/10/01`.

> [!WARNING]
> Development versions are not made publicly available to users.

## Verified Environment

`iPhone 11` · `Spotify 9.1.86` · `iOS 27.0` · certificate-signed · `LCSign` · rootless DEB

The modified features in this fork have been verified to work in this environment.

> [!TIP]
> If there are unexpected issues on the Now Playing page, such as lyrics not showing or outdated song teaser cards, simply exit the Now Playing page and re-enter it to resolve the issue.

## Acknowledgements

- Thanks to [whoeevee](https://github.com/whoeevee) for the original EeveeSpotify project.
- Thanks to [SideloadLabs](https://github.com/SideloadLabs/EeveeSpotifyReincarnated) for creating the SpicyLyrics lyrics provider, as well as the logging and export functionality. The relevant code has been modified to fit this project.
- Thanks to the [MeloX](https://github.com/youshen2/MeloX) project for the inspiration behind this project's karaoke lyrics feature. The relevant code has been modified to fit this project.