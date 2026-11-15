# Reverse-engineered Data and Takedowns

This project interoperates with Spotify's iOS client, which means parts of it were derived from a locally decrypted copy of that client. So that there is no ambiguity about what is (and is not) included in this repository:

**In short:** this repository contains derived *technical identifiers* and the scripts that regenerate them. It contains no Spotify binary, no decrypted `.ipa`, no audio or lyrics files, and no account credentials.

## What is here

Derived *technical identifiers* needed to attach to the client's own extension points: Swift/ObjC class names, feature-flag names and scopes, gRPC service paths, view-hierarchy inventories, and a few resolver-configuration snapshots (`.bnk`), plus the reverse-engineering notes and scripts used to derive them (`Tools/eevee-hookfinder/`). All of it can be regenerated from a copy you supply yourself; see `Scripts/dump-spotify-symbols.py`.

## What is not here, and will not be added

- No audio, no streams, no decryption keys, and nothing that decrypts Spotify's binary. You supply your own decrypted copy.
- No lyrics files: lyrics are fetched at runtime by the user's device from third-party providers, and none of their content is bundled.
- No Spotify account credentials, tokens, or captured traffic.
- No Spotify application binary and no decrypted `.ipa`. `*.ipa`, `Decrypted IPA/` and `Tweaked IPA/` are intentionally ignored by git.

## Rights holders

If you are the rights holder and wish to have certain content removed, please submit an issue or contact the developer directly at ‘yuanhainigu@outlook.com’; the relevant content will be removed. There is no need to submit a formal takedown notice. This provision also applies to third-party projects where the source is credited in [CREDITS.md](CREDITS.md).

> This is not legal advice. It is a statement of what the repository does and does not contain, which is the part a maintainer can actually control.
