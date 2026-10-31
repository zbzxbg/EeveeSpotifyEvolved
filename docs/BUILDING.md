# Building an IPA

You supply your own decrypted Spotify IPA. This repository never ships one and never says where to get one — see [LEGAL.md](LEGAL.md).

Two paths: **CI** (nothing installed locally) and **a local build on macOS**. Both take a decrypted Spotify 9.1.88 IPA and produce an unsigned `-patched.ipa` / `.ipa` to sign yourself.

> [!WARNING]
> While `main` is under active development, the `Build .deb` step in the IPA and deb release workflows can fail. That is a known problem in the source at that moment, not something you did wrong. Wait a few hours, pull the latest repository and run the workflow again, or investigate and fix it (pull requests are welcome).

## CI (nothing installed locally)

Actions → **Build IPA — patched (Orion.framework + zxPluginsInject)** or **Build IPA — no patch (Orion.framework)** → Run workflow.

| Input | Meaning |
| --- | --- |
| `ipa_url` | **Required.** Direct download URL of your decrypted Spotify IPA. It must return the `.ipa` itself, e.g. `https://example.com/abc.ipa`. Do not use cloud-drive share pages, login-gated links, or links that redirect to a preview page. |
| `orion_url` | The bundled `Orion.zip`. Defaults to this project's own mirror; leave it alone unless it 404s. |
| `upload_method` | Where the finished IPA(s) go: `artifacts` (default), `filebin`, or `both`. |
| `liquid_glass` | On by default. Removes `UIDesignRequiresCompatibility` so iOS 26+ gets the new design language; set it to false to keep Spotify's own compatibility-mode look. |

There is no "compile the tweak only" mode; an empty `ipa_url` fails the download step. A third workflow, **Binary Symbol Diff**, also takes an `ipa_url`, but it diffs a Spotify build against the tracked symbol baseline instead of producing an IPA.

## Locally (macOS)

```
./setup-build-ipa.sh /path/to/Spotify-vanilla.ipa
```

`setup-build-ipa.sh` only installs the toolchain (Homebrew packages, `cyan`, `ipapatch`, Theos) and then hands off to `build-ipa-local.sh`, which does the actual work. To run the build directly once the toolchain is in place:

```
ALLOW_LIQUID_GLASS=0 ./build-ipa-local.sh /path/to/Spotify-vanilla.ipa
```

`ALLOW_LIQUID_GLASS` is the local equivalent of the CI `liquid_glass` input and defaults to `1` (on); set it to `0` to keep Spotify's compatibility-mode look.

## What ends up in the IPA

- **The tweak itself** is built from `Sources/EeveeSpotify` with Theos and injected with [cyan](https://github.com/asdfzxcvbn/pyzule-rw).
- **`Orion.framework`** is bundled into the app, because a sideloaded app has no package manager to resolve the `dev.theos.orion` dependency the `.deb` declares. The pipeline pulls a prebuilt copy (the `orion_url` input, which defaults to this project's mirror) — it is not compiled by the runner.
- **Patched builds** additionally inject `zxPluginsInject.dylib`, a sideload shim: keychain access-group rebind, iCloud entitlement neutering, app-group `group.*` stubs. It fixes what breaks when an app is re-signed by a different team, so if a sideloaded build misbehaves around login or keychain, try the patched one.
- **Free profiles** usually have no wildcard, so the Watch app and the native appex have to be stripped (`Tools/strip-ipa.sh`). That is also why the patched builds are smaller.
- `ALLOW_LIQUID_GLASS` / `liquid_glass` only decides whether `UIDesignRequiresCompatibility` stays in the app's `Info.plist`.

## Symbol baseline

`Tools/dump-spotify-symbols.py` dumps the classes, selectors, methods and flags of a Spotify build; `Tools/diff-symbol-dumps.py` diffs two dumps or a dump against the tracked baseline (`.spotify-ipa/`). The **Binary Symbol Diff** workflow wraps the two, which is what catches "Spotify renamed a class and the tweak silently stopped hooking it" before a release.

---

Back to the [README](../README.md) · [Contributing](../CONTRIBUTING.md) · [Credits](CREDITS.md)
