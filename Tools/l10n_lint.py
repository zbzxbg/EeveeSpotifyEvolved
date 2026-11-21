#!/usr/bin/env python3
r"""
l10n_lint.py — Localization key linter for EeveeSpotifyReincarnated.

Cross-checks every *.lproj/Localizable.strings against the English baseline and
optionally against keys actually referenced in Swift sources.

Checks:
  1. Untranslated   — key exists in en.lproj but not in locale X (**informational**, not an error).
                      ★ 2026-10-11 政策变更（用户拍板）：英文只由 `en.lproj` **单点提供** ——
                      缺键会自动回落到它（`BundleHelper.localizedString` 里那道
                      `enBundle` 兜底；bundle 的 `CFBundleDevelopmentRegion` 也是 English）。
                      所以这里**不再要求**每个 locale 把英文抄一份，只报"还没翻多少条"。
  2. Extra keys     — key exists in locale X but not in en.lproj (error, usually stale)
  3. Duplicate keys — the same key defined twice in one file (error). ★ 2026-10-11 新增：
                      `.strings` 里**后写的生效**，重复键 = 悄悄盖掉前一条（真机上就是这么
                      把一份意译、以及用户自己改写的中文盖住的）。
  4. Verbatim copy  — value is byte-identical to the English baseline (warning).
                      ★ 2026-10-11 新增：按上面的"单点提供"政策，这种行是**冗余**的
                      （删掉不改变任何显示），留着只会让 en 改文案时要跟着改 N 份文件。
  5. Unused keys    — key defined in en.lproj but never referenced in Swift code
                      (warning; .strings values are used dynamically so review
                      each hit manually before deleting)
                      ★ 2026-10-14 修好误报：旧版只认 4 种字面量形状，看不见
                      「键当实参传」与「前缀 + 运行时拼接」，于是把 **112 条活键**
                      报成 unused（真死键只有 8 条）。现在：
                        · `…Key:` / `title:` / `subtitle:` / `note:` / `footer:` 等
                          实参位置上的字面量算可达；
                        · 源码里存在 `"prefix_" +` / `"prefix_\("` 形状时，**该前缀下的
                          键整体算可达**（拼接能生成哪些键静态不可枚举，宁可漏报不误报）；
                        · 「算出键名再返回」的 computed property 体内的 `return "…"` 也算。
                      ⇒ 修完实测 **UNUSED = 0 条**。
                      ⚠️ 历史提醒：`Cancel` / `Done` / `OK` / `Loading` 曾经长期被报为
                      unused（它们走 `.uiKitLocalized`，查的是宿主 Spotify 的 bundle，
                      不是本 bundle）；那 4 条已于 2026-10-14 从词典删除，所以**不会再出现**。
                      若将来又有这类"只给系统控件用"的键，判断依据仍是：
                      `".localized"` 还是 `".uiKitLocalized"` —— 后者读不到本 bundle。
  6. Format args    — key uses %@ / %d style placeholders but the locale's
                      value has a different number of them (**warning**).
                      ★ 2026-10-11 从 error 降级：**基线不是可靠代理** ——
                      `patching_description` 就是活例子：en（以及 bg / de-CH / ko / pt-BR / zh-CN）
                      把"需要重启"那句**写死在正文里**，另 21 个语言用 `%@` 代入
                      （调用点是 `localizeWithFormat`）。两种都**正确**，但基线数 0 vs 1 会被
                      当成不一致 ⇒ 全语言假红。真正的危险方向（某个语言的占位符比调用点**实参**多
                      ⇒ `String(format:)` 读到不存在的参数）**本脚本量不出来**：那要靠调用点的实参
                      个数，这里不做（宁可漏，不误报）。

  7. English-only keys — `Tools/l10n_notranslate.txt` 里列的键**不计入**未翻译数量，
     单独报成 `skipped`。这些键刻意留在英文：值里带标识符、日志语法、示例值或许可
     署名的散文，译了反而对不上屏幕和日志。清单**不禁止**翻译（locale 文件里有条目
     就照常用），它只决定"贡献者默认要处理哪些"。清单中已不在 en.lproj 的条目会作为
     stale 报出来，避免清单自己腐烂。

  `--since REV` 打印 en.lproj 相对 REV 的**新增 / 删除 / 改写**键。改写那组是静默
  腐烂的来源：英文值变了，已有译文不会跟着变，未翻译数量也不动。配合 `--locale xx`
  还会报其中有多少条在该语种里缺失。

Usage:
  python3 Tools/l10n_lint.py                 # lint all locales
  python3 Tools/l10n_lint.py --locale ko     # lint a single locale
  python3 Tools/l10n_lint.py --no-usage      # skip the Swift cross-reference
  python3 Tools/l10n_lint.py --quiet         # only print problems (exit code)
  python3 Tools/l10n_lint.py --list-untranslated   # 逐条列出未翻译的键（默认只报数量）
  python3 Tools/l10n_lint.py --since v2.3.0  # 只关心自该版本以来 en.lproj 的变化
  python3 Tools/l10n_lint.py --no-notranslate      # 忽略 Tools/l10n_notranslate.txt

Exit code is 1 when **errors** (extra / duplicate / missing file) are found, 0 otherwise.
Warnings (unused keys, verbatim English copies, format-arg count differences) and the
untranslated count do not fail the run.
"""

import argparse
import re
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
BUNDLE_DIR = REPO_ROOT / "layout" / "Library" / "Application Support" / "EeveeSpotify.bundle"
SOURCES_DIR = REPO_ROOT / "Sources"

BASELINE = "en"

# Keys shipped in English on purpose. The linter subtracts them from the per-locale
# "untranslated" count and reports them separately; the file itself states the criteria.
# If it is missing, every baseline key counts as translatable.
NOTRANSLATE_PATH = REPO_ROOT / "Tools" / "l10n_notranslate.txt"

# One .strings entry: key = "value";  (value may contain escaped quotes)
ENTRY_RE = re.compile(r'^\s*(?P<key>"(?:[^"\\]|\\.)*"|[\w.\-]+)\s*=\s*"(?P<value>(?:[^"\\]|\\.)*)"\s*;', re.M)
COMMENT_RE = re.compile(r"/\*.*?\*/", re.S)
LINE_COMMENT_RE = re.compile(r"^\s*//.*$", re.M)

# Format specifiers that must match across translations: %@, %1$@, %d, %ld, %lu...
FORMAT_SPEC_RE = re.compile(r"%\d+\$[@dDuUxXoOfeEgGcCsS]|%[@dDuUxXoOfeEgGcCsS]")


def parse_strings_text(text: str) -> dict[str, str]:
    """Parse .strings content into an ordered {key: value} dict."""
    text = COMMENT_RE.sub("", text)
    text = LINE_COMMENT_RE.sub("", text)
    entries = {}
    for m in ENTRY_RE.finditer(text):
        key = m.group("key").strip('"')
        entries[key] = m.group("value")
    return entries


def parse_strings_file(path: Path) -> dict[str, str]:
    """Parse a .strings file into an ordered {key: value} dict."""
    return parse_strings_text(path.read_text(encoding="utf-8"))


def load_notranslate() -> set[str]:
    """Read Tools/l10n_notranslate.txt: one key per line, `#` starts a comment."""
    if not NOTRANSLATE_PATH.is_file():
        return set()
    keys = set()
    for raw in NOTRANSLATE_PATH.read_text(encoding="utf-8").splitlines():
        key = raw.split("#", 1)[0].strip()
        if key:
            keys.add(key)
    return keys


def git_file_at(rev: str, path: Path) -> str:
    """Return the content of `path` at `rev`; RuntimeError when git cannot produce it."""
    try:
        rel = path.resolve().relative_to(REPO_ROOT).as_posix()
    except ValueError:
        rel = path.as_posix()
    proc = subprocess.run(
        ["git", "-C", str(REPO_ROOT), "show", f"{rev}:{rel}"],
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.strip() or f"git show {rev}:{rel} failed")
    return proc.stdout


def report_since(rev, baseline_path, baseline, notranslate, locale_entries, locale):
    """Print what changed in the baseline since `rev`: added / removed / rewritten keys.

    The rewritten group is the one that ages silently: an existing translation keeps its
    old wording after the English value changes, and the untranslated count does not move.
    """
    old = parse_strings_text(git_file_at(rev, baseline_path))
    added = [k for k in baseline if k not in old]
    removed = [k for k in old if k not in baseline]
    edited = [k for k in baseline if k in old and old[k] != baseline[k]]
    todo = [k for k in added if k not in notranslate]
    kept_english = [k for k in added if k in notranslate]

    print(f"=== changes in {BASELINE}.lproj since {rev} ===")
    print(f"  keys now: {len(baseline)} (then: {len(old)})")
    print(f"  added:     {len(added)} new keys")
    print(f"  removed:   {len(removed)} keys")
    print(
        f"  rewritten: {len(edited)} English values changed — any existing translation "
        "of these is now stale"
    )
    if todo:
        print("  new keys worth translating:")
        for key in todo:
            print(f"    + {key}")
    if kept_english:
        print(f"  new keys that stay English ({NOTRANSLATE_PATH.name}):")
        for key in kept_english:
            print(f"    . {key}")
    if edited:
        print("  rewritten values (re-read the English, then the translation):")
        for key in edited:
            print(f"    ~ {key}")
    if removed:
        print("  removed keys (a locale entry for these can be deleted):")
        for key in removed:
            print(f"    - {key}")

    if locale is not None:
        if locale_entries is None:
            print(f"  {locale}: no Localizable.strings to compare against")
        else:
            missing = [k for k in todo + edited if k not in locale_entries]
            stale = [k for k in edited if k in locale_entries]
            print(f"  in {locale}: {len(missing)} of the added/rewritten keys are missing")
            if stale:
                print(
                    f"  in {locale}: {len(stale)} rewritten key(s) have a translation "
                    "that no longer matches the English"
                )
    print()


def duplicate_keys(path: Path) -> list[str]:
    """同一个键在**一个文件里**出现多次的（去重、保序）。

    ⚠️ 必须单独扫一遍：`parse_strings_file` 用的是 dict，重复键会被**静默吃掉**
    （`.strings` 的规则是后写的生效），于是"某条翻译/某次改写其实没生效"这种问题
    在 lint 里完全看不见 —— 2026-10-11 就是靠一次手工审计才发现的。
    """
    text = path.read_text(encoding="utf-8")
    text = COMMENT_RE.sub("", text)
    text = LINE_COMMENT_RE.sub("", text)
    seen: dict[str, int] = {}
    order: list[str] = []
    for m in ENTRY_RE.finditer(text):
        key = m.group("key").strip('"')
        if key in seen:
            seen[key] += 1
        else:
            seen[key] = 1
            order.append(key)
    return [k for k in order if seen[k] > 1]


def source_key_fragments() -> tuple[set[str], set[str]]:
    """扫描 Swift 源码，返回 `(字面量键集合, 拼接前缀集合)`。

    ★ 2026-10-14 重写（起因：一次审计发现旧版报出的 114 条 "unused" 里，
    **只有 8 条是真死键，106 条是误报** —— 而误报清单被当成清理依据时，
    删下去就是 106 条文案当场变回裸键名）。

    旧版只认 4 种**字面量形状**（`"k".localized` 等），看不见仓库里两种主流写法：

      ① 「键当实参传，由被调方 `.localized`」——
         `settingsRow(title: "lyrics", subtitle: "settings_sub_lyrics")`
         （`EeveeSettingsView.swift`，一行一个设置入口）；
         `KnownFlag(titleKey:/footerKey:/noteKey:)`（`KnownFlagCatalog.swift`）；
         `detailKey:` / `labelKey:` / `descriptionKey:` 同理。
      ② 「键名前缀 + 运行时拼接」——
         `"player_card_\\(rawValue)"`（`PlayerDeclutter.x.swift:78`）、
         `"reduce_interventions_flag_" + shortName(of: flag)`（`EeveeReduceInterventionsView.swift:332`）。
         拼接能生成哪些键**静态不可枚举**，所以这里退而求其次：**只要源码里存在
         `"prefix_" +` 或 `"prefix_\\("` 这种形状，就认为该前缀下的键可达**（宁可漏报，
         不可再误报 —— 删错键的代价是用户界面掉文案，漏报的代价只是少一条提示）。
      ③ 「算出键名再返回」的 computed property ——
         `var localizedKey: String { switch self { case .on: return "flag_override_mode_on" … } }`
         （`FlagOverride.swift:31-39`）、`var localizationKey: String { … }`
         （`LyricsContributor.swift:24-29`）。这种字面量既不跟 `.localized` 也不在实参位置，
         按"属性体里的 return"收 —— 属性名含 `Key` 或 `localized` 时才算。

    ★ 效果（2026-10-14 实测，`python Tools/l10n_lint.py` 全量）：
      `UNUSED in Swift` 从 **114 条降到 0 条**。降下来的全是**活键**；
      真死键是那次审计逐条人工定性的 8 条（已从词典里删掉）。

    ⚠️ 留作历史注记：`Cancel` / `Done` / `OK` / `Loading` 曾经长期被报成 unused
    （它们靠 `.uiKitLocalized` 查**宿主 App（Spotify）的 bundle**，不走 `BundleHelper`，
    所以本 bundle 里的同名条目确实读不到）。这 4 条已于 2026-10-14 从词典删除，
    因此**不会再出现在 UNUSED 里**。将来若要判断某个键是不是这一类，看调用点是
    `".localized"` 还是 `".uiKitLocalized"` 即可 —— 后者读不到本 bundle。
    """
    keys: set[str] = set()
    prefixes: set[str] = set()
    if not SOURCES_DIR.exists():
        return keys, prefixes
    swift_files = list(SOURCES_DIR.rglob("*.swift"))

    # ① 直接查表：`"key".localized` / `.localizeWithFormat` / `localizedString("key")` / 裸表查找
    direct = [
        re.compile(r'"([A-Za-z0-9_.\-]+)"\s*\.\s*localized'),
        re.compile(r'"([A-Za-z0-9_.\-]+)"\s*\.\s*localizeWithFormat'),
        re.compile(r'localizedString\(\s*"([A-Za-z0-9_.\-]+)"'),
        re.compile(r'table:\s*[^,]+,\s*value:\s*"([A-Za-z0-9_.\-]+)"'),
    ]
    # ② 键当实参：`…Key: "k"`、`title:`、`subtitle:`、`note:`、`footer:`、`header:`…
    #    实参名以 `Key` 结尾的一律收（titleKey/footerKey/noteKey/detailKey/labelKey/
    #    descriptionKey/…），另加设置页那几个把键直接当文案用的标签。
    #    `title:` 会顺带收进 `UIAlertController(title: "SponsorBlock segment")` 这类
    #    **非 l10n** 字符串 —— 无害：它只是让"看起来像键"的字面量算作可达。
    argument = re.compile(
        r'\b(?:[A-Za-z]+Key|title|subtitle|note|footer|header|message|placeholder)\s*:\s*'
        r'"([A-Za-z0-9_.\-]+)"'
    )
    # ②b 「算出键名再返回」的 computed property —— 例如
    #     `var localizedKey: String { switch self { case .on: return "flag_override_mode_on" } }`
    #     （`FlagOverride.swift:31-39`，5 条）与
    #     `var localizationKey: String { … return "lyrics_uploaded_by" … }`
    #     （`LyricsContributor.swift:24-29`，2 条）。
    #     这些字面量既不跟 `.localized` 也不在实参位置，按"属性体里的 return"收。
    #     ⚠️ 必须**分成两步**（先在源码里切出属性体、再收体内所有 return）：
    #        写成单条 `…\{[^{}]*?\breturn "…"` 是**够不到**的 —— 属性体里第一个 `{`
    #        属于 `switch`，而 `[^{}]*?` 不能跨 `{`；就算换成 `[^}]*?`，`findall`
    #        每段也只吐**第一个** return（5 条里只命中 1 条）。2026-10-14 由 teammate
    #        用真实源码 mini-repro 定位后改成现在这样。
    #     ⚠️ 故意收得宽：属性名含 `Key` / `localized` 时，体内 `return "…"` 一律算可达 ——
    #        误收的代价只是"少报一条 unused"，漏收的代价是"删掉活键、界面掉文案"。
    key_property = re.compile(
        r'\b(?:var|let)\s+([A-Za-z_][A-Za-z0-9_]*)\s*(?::[^={\n]+)?\s*\{(?P<body>[^}]*)\}',
        re.S,
    )
    key_return = re.compile(r'\breturn\s+"([A-Za-z0-9_.\-]+)"')
    # ③ 拼接/插值前缀：`"prefix_" + …` 与 `"prefix_\(…)`（Swift 字符串插值）。
    #    ⚠️ 两条形态的**闭引号位置不同**，必须分开写：
    #      拼接  = `"prefix_"` +  → 前缀后面有**闭引号**
    #      插值  = `"prefix_\(`   → 前缀后面**直接**是 `\(`，没有闭引号
    #    第一版把两者合成 `"([...]*_)"\s*(?:\+|\\\()`，那个闭引号要求让插值那一路
    #    永远匹配不到 ⇒ 10 条 `player_card_*` 仍被误报（2026-10-14 修）。
    concat_prefix = re.compile(r'"([A-Za-z][A-Za-z0-9_.\-]*_)"\s*\+|"([A-Za-z][A-Za-z0-9_.\-]*_)\\\(')

    for sf in swift_files:
        try:
            text = sf.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        for pat in direct:
            keys.update(pat.findall(text))
        keys.update(argument.findall(text))
        for prop_name, body in key_property.findall(text):
            if "Key" in prop_name or "localized" in prop_name.lower():
                keys.update(key_return.findall(body))
        for concat_hit, interp_hit in concat_prefix.findall(text):
            prefix = concat_hit or interp_hit
            if prefix:
                prefixes.add(prefix)

    return keys, prefixes


def reachable_keys(baseline_keys: set[str]) -> set[str]:
    """基线里**确实能到达**的键：字面量可见的 + 由拼接前缀生成出来的。

    `baseline_keys` 要传进来，是因为"前缀能不能生成某个键"必须拿真实键名去比。
    """
    literal, prefixes = source_key_fragments()
    reachable = set(baseline_keys) & literal
    for prefix in prefixes:
        reachable |= {k for k in baseline_keys if k.startswith(prefix)}
    return reachable


def count_format_specs(value: str) -> int:
    return len(FORMAT_SPEC_RE.findall(value))


def locale_dirs() -> list[Path]:
    return sorted(p for p in BUNDLE_DIR.glob("*.lproj") if p.is_dir())


def main() -> int:
    parser = argparse.ArgumentParser(description="Lint .strings localization files")
    parser.add_argument("--locale", help="lint only this locale code (e.g. ko, zh-CN)")
    parser.add_argument("--no-usage", action="store_true", help="skip unused-key check against Swift sources")
    parser.add_argument("--quiet", action="store_true", help="only print locales with problems")
    parser.add_argument(
        "--list-untranslated",
        action="store_true",
        help="print every untranslated key instead of just the count",
    )
    parser.add_argument(
        "--no-notranslate",
        action="store_true",
        help="ignore Tools/l10n_notranslate.txt and count every baseline key",
    )
    parser.add_argument(
        "--since",
        metavar="REV",
        help="also report keys added/removed/rewritten in the baseline since REV",
    )
    args = parser.parse_args()

    if not BUNDLE_DIR.exists():
        print(f"error: bundle dir not found: {BUNDLE_DIR}", file=sys.stderr)
        return 2

    baseline_path = BUNDLE_DIR / f"{BASELINE}.lproj" / "Localizable.strings"
    if not baseline_path.exists():
        print(f"error: baseline file not found: {baseline_path}", file=sys.stderr)
        return 2

    baseline = parse_strings_file(baseline_path)
    # 刻意留在英文的键：从待办里摘走，但仍是可用键（locale 里有条目就用条目）。
    notranslate = set() if args.no_notranslate else load_notranslate()
    if not args.no_notranslate:
        stale_entries = sorted(notranslate - set(baseline))
        if stale_entries:
            noun = "entry" if len(stale_entries) == 1 else "entries"
            print(
                f"{NOTRANSLATE_PATH.name}: {len(stale_entries)} {noun} no longer in "
                f"{BASELINE}.lproj (stale, delete them):"
            )
            for key in stale_entries:
                print(f"  - {key}")
            print()

    if args.since:
        locale_entries = None
        if args.locale:
            candidate = BUNDLE_DIR / f"{args.locale}.lproj" / "Localizable.strings"
            if candidate.is_file():
                locale_entries = parse_strings_file(candidate)
        try:
            report_since(
                args.since,
                baseline_path,
                baseline,
                notranslate,
                locale_entries,
                args.locale,
            )
        except RuntimeError as exc:
            print(
                f"error: cannot read {BASELINE}.lproj at {args.since}: {exc}",
                file=sys.stderr,
            )
            return 2
        # 只问"改了什么"的时候不打印 27 个语种的整份报告。
        if not args.locale:
            return 0

    # 「能不能到达」必须拿真实键名去比前缀，所以这里就把基线键集算好。
    usage = set() if args.no_usage else reachable_keys(set(baseline))

    locales = locale_dirs()
    if not locales:
        print("error: no *.lproj directories found", file=sys.stderr)
        return 2

    had_errors = False
    summary: list[str] = []

    for loc_dir in locales:
        loc = loc_dir.name.replace(".lproj", "")
        if loc == BASELINE:
            continue
        if args.locale and loc != args.locale:
            continue
        strings_path = loc_dir / "Localizable.strings"
        if not strings_path.exists():
            summary.append(f"{loc}: MISSING Localizable.strings")
            had_errors = True
            continue

        entries = parse_strings_file(strings_path)
        baseline_keys = set(baseline)
        loc_keys = set(entries)

        # ① 未翻译：**不再是错误**（英文由 en.lproj 单点提供，缺键自动回落）。
        #    刻意留在英文的键（Tools/l10n_notranslate.txt）单独计数，不算贡献者的待办。
        missing = baseline_keys - loc_keys
        untranslated = sorted(missing - notranslate)
        skipped = len(missing & notranslate)
        extra = sorted(loc_keys - baseline_keys)
        dups = duplicate_keys(strings_path)
        # ④ 与基线逐字相同的行：按"单点提供"政策是冗余的（删掉不改变显示）。
        copies = sorted(
            k for k in sorted(baseline_keys & loc_keys) if entries[k] == baseline[k]
        )

        # Format-specifier mismatches for keys present in both
        fmt_bad = []
        for key in sorted(baseline_keys & loc_keys):
            n_base = count_format_specs(baseline[key])
            n_loc = count_format_specs(entries[key])
            if n_base != n_loc:
                fmt_bad.append(f"{key} (en has {n_base}, {loc} has {n_loc})")

        unused = sorted(k for k in baseline_keys if k not in usage)

        # `--quiet` 只留**真错误**（extra / duplicate）；未翻译与各类 warning 不再刷屏。
        if args.quiet and not (extra or dups):
            continue

        print(f"=== {loc} ===")
        print(f"  total keys: {len(loc_keys)} (baseline has {len(baseline_keys)})")
        print(
            f"  UNTRANSLATED: {len(untranslated)} required"
            + (f" (+{skipped} skipped by {NOTRANSLATE_PATH.name})" if skipped else "")
            + " [informational — these fall back to English, nothing to fix]"
        )
        if untranslated and args.list_untranslated:
            for k in untranslated:
                print(f"    - {k}")
        if extra:
            print(f"  EXTRA / stale ({len(extra)}) [error]:")
            for k in extra:
                print(f"    - {k}")
        if dups:
            print(f"  DUPLICATE KEYS ({len(dups)}) [error — the later one silently wins]:")
            for k in dups:
                print(f"    - {k}")
        if copies:
            print(
                f"  VERBATIM ENGLISH COPIES ({len(copies)})"
                " [warning — redundant, delete them; en.lproj is the single source of English]:"
            )
            for k in copies:
                print(f"    - {k}")
        if fmt_bad:
            print(
                f"  FORMAT-ARG COUNT DIFFERS FROM EN ({len(fmt_bad)})"
                " [warning — both styles can be correct, see the docstring]:"
            )
            for k in fmt_bad:
                print(f"    - {k}")
        if unused and not args.no_usage:
            print(f"  UNUSED in Swift code ({len(unused)}) [warning, review before deleting]:")
            for k in unused:
                print(f"    - {k}")
        if not (untranslated or extra or dups or copies or fmt_bad or unused):
            if skipped:
                print(
                    "  OK — every translatable key is present "
                    f"({skipped} English-only key(s) skipped)"
                )
            else:
                print("  OK — fully in sync")
        print()

        if extra or dups:
            had_errors = True
        summary.append(
            f"{loc}: {len(loc_keys)} keys, {len(untranslated)} untranslated"
            + (f", {skipped} English-only" if skipped else "")
            + f", {len(extra)} extra"
            + (f", {len(dups)} duplicate" if dups else "")
            + (f", {len(fmt_bad)} format count differs (warning)" if fmt_bad else "")
        )

    if not args.quiet and summary:
        print("---- summary ----")
        for line in summary:
            print(line)

    return 1 if had_errors else 0


if __name__ == "__main__":
    sys.exit(main())
