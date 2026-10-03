# Translating EeveeSpotify

Thank you for helping translate EeveeSpotify! All UI strings live in `.strings` files inside the tweak's bundle, and every locale is community-maintained. This guide explains the layout, the rules, and how to check your work before opening a PR.

---

## Where translations live

```
layout/Library/Application Support/EeveeSpotify.bundle/<locale>.lproj/Localizable.strings
```

Examples:

- `layout/Library/Application Support/EeveeSpotify.bundle/en.lproj/Localizable.strings` — the **baseline** every locale is checked against
- `layout/Library/Application Support/EeveeSpotify.bundle/uk.lproj/Localizable.strings`
- `layout/Library/Application Support/EeveeSpotify.bundle/zh-CN.lproj/Localizable.strings`

The `<locale>` folder name is a standard Apple language ID: a language code, optionally with a region/script suffix (`pt-BR`, `zh-TW`, `ar-EG`). Use an existing folder if one matches your language; otherwise create a new `<locale>.lproj` directory containing one `Localizable.strings` file.

> Note: some locales appear with different region suffixes (e.g. `pt` and `pt-BR`). If both exist, pick the more general one (`pt`) unless your translation genuinely differs by region.

---

## Adding a new locale

1. Copy the baseline as your starting point:

   ```bash
   mkdir -p "layout/Library/Application Support/EeveeSpotify.bundle/xx.lproj"
   cp "layout/Library/Application Support/EeveeSpotify.bundle/en.lproj/Localizable.strings" \
      "layout/Library/Application Support/EeveeSpotify.bundle/xx.lproj/Localizable.strings"
   ```

2. Translate the **value** on the right of each `=`. **Never change the key** on the left.

3. **Delete the rows you left in English.** English lives in `en.lproj` only — an untranslated
   key falls back to it automatically, so a copied English row is pure duplication (the linter
   warns about it). Your file should end up containing *only the strings you actually translated*.

4. Run the linter (see below) and fix anything it reports.

5. Open a PR with your locale code in the title, e.g. `Add xx-XX localization`.

---

## How the fallback works (why "missing" is fine)

`BundleHelper.localizedString` looks a key up in the bundle's **device-language table** first and
then in **`en.lproj`**; only if neither has it does the app show the raw key. The bundle's
`CFBundleDevelopmentRegion` is `English` as well, so iOS itself falls back the same way.

Consequences:

- A locale file with **only your translations** is complete. Partial locales are first-class.
- The fallback is **English**, not "the nearest related language". A Traditional Chinese device
  whose language list is `[zh-Hant-TW, en-US]` gets English for anything untranslated; if the list
  also contains Simplified Chinese (`[zh-Hant-TW, zh-Hans-CN, …]`), iOS may serve a missing key
  from `zh-CN` **before** English — that is system behaviour, not something the files control.

---

## The rules (enforced by the linter)

### 1. Keys are immutable

The key (`left side`) is what the code looks up:

```
reset_data = "Скинути дані";      ✅ correct
"reset_data" = "Скинути дані";    ❌ no — key changed
reset_dataDescription = "...";    ❌ no — key renamed
```

### 2. Keep format placeholders working

Strings used with `.localizeWithFormat(...)` contain placeholders like `%@`, `%d`, or positional
`%1$@`. Two styles are both correct, and English itself mixes them:

```
# style A — let the placeholder carry the sentence (what most locales do)
patching_description = "… und ändert die Parameter in Echtzeit.\n\n%@";

# style B — inline the sentence and ignore the argument (what en.lproj and zh-CN do)
patching_description = "… and modifies the parameters in real-time.\n\nApp restart is required after changing.";
```

✅ Either is fine. ❌ What is **not** fine is inventing a placeholder the call site does not supply:
`String(format:)` with a placeholder and no matching argument reads garbage (and can crash). So
never add a `%@`/`%d` that isn't in the English string *unless* you know the call site passes it —
safest is to match English's count, or inline like English does.

The linter reports a placeholder-count difference from English as a **warning** for review, not an
error — because (as `patching_description` shows) a difference can be entirely legitimate.

Keep the placeholder in the position that reads naturally in your language; for multiple
placeholders, keep the same order (or use positional ones like `%1$@` / `%2$@` if the grammar
requires reordering).

### 3. Escape quotes and keep newlines

Inside values, escape double quotes as `\"` and keep literal line breaks as written in English (multi-line values are fine and intentional).

```
lyrics_additional_info = "... you'll see a \"Couldn't load the lyrics for this song\" message ...";
```

### 4. Escape sequences and special characters carry over

If the English value contains `\n`, `\t`, or similar, your translation must too.

### 5. Don't translate brand names or proper nouns

Keep these as-is: `EeveeSpotify`, `Spotify`, `Musixmatch`, `PetitLyrics`, `LRCLIB`, `Genius`, `SponsorBlock`, `TrollStore`, `SideStore`, `CarPlay`, `Siri`, `Jam`, `AI DJ`.

### 6. Rules about keys

- **A key defined twice in one file is an error.** `.strings` keeps the **last** one, so the earlier
  entry is silently dead — this has already hidden a finished translation and a maintainer's rewrite.
- **Missing keys are fine** (informational): they fall back to English, so a partial file is valid.
- **Extra keys are errors**: a key that isn't in `en.lproj` can never be reached (stale leftover).
- **Verbatim English rows are warnings**: they do nothing (English already comes from `en.lproj`)
  and they mean every future English edit has to touch your file too. Delete them.
- Key order doesn't matter to the app, but keeping the same order as `en.lproj` makes diffs reviewable.
- Renaming or "fixing" a key is never right: the key is what the code looks up.

### 7. Content style

- Keep it short — settings rows truncate long text.
- Use the tone of the English original: friendly, direct, no slang.
- Don't add disclaimers, credit lines, or URLs that aren't in the English source.
- Section comments (`/* MARK: ... */`, `// ...`) in the file are for humans; you can keep or translate them, the app ignores them.

---

## Checking your work

A linter ships in this repo; it compares your locale against the English baseline and the Swift sources:

```bash
python3 Tools/l10n_lint.py --locale xx      # only your locale
python3 Tools/l10n_lint.py                  # all locales (full report)
python3 Tools/l10n_lint.py --quiet          # only locales with real errors
python3 Tools/l10n_lint.py --locale xx --list-untranslated   # list what's still untranslated
```

What it reports:

| Check | Severity | Meaning |
|---|---|---|
| Untranslated | informational | Key exists in `en.lproj` but not yours — the app shows English |
| Extra keys | **error** | Key not in `en.lproj` — stale/renamed leftover, unreachable |
| Duplicate keys | **error** | Same key twice in one file — the last one silently wins |
| Verbatim English copies | warning | Redundant rows; delete them (English comes from `en.lproj`) |
| Format-arg count differs from en | warning | Both styles can be correct — see rule 2 |
| Unused keys | warning | Defined but never referenced in Swift — ask before removing |

Your PR should introduce **zero new errors** for your locale. Warnings are for review, and the
untranslated count is just information — a file with 40 translated strings and 370 untranslated
ones is perfectly valid and welcome.

No local Python? Note in your PR that you couldn't run it, and a maintainer will run it for you.

---

## Updating an existing locale

New strings appear whenever features are added; locales drift behind the baseline over time. To catch up:

1. Run `python3 Tools/l10n_lint.py --locale xx --list-untranslated` to get the exact list of keys
   that still fall back to English (without the flag you only get the count).
2. Find each key in `en.lproj` and add a translated entry (English rows are not copied over — see
   the fallback section above).
3. Re-run the linter until your locale has **no errors** (warnings are fine to leave).
4. Partial updates are welcome — even a PR that fills in one section (e.g. all SponsorBlock strings) helps.

---

## Registering the locale (one extra step)

The tweak's bundle ships an `Info.plist`. New `.lproj` folders are picked up by iOS automatically in most cases, but if your language doesn't show up in testing, add your locale to `CFBundleLocalizations` in:

```
layout/Library/Application Support/EeveeSpotify.bundle/Info.plist
```

---

## Questions

- General usage and install questions: see [common_issues.md](common_issues.md) or the [Telegram channel](https://t.me/zbzxbg).
- For anything about this guide itself, open an issue or PR against this file.
