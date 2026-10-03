#!/usr/bin/env python3
"""
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
  6. Format args    — key uses %@ / %d style placeholders but the locale's
                      value has a different number of them (**warning**).
                      ★ 2026-10-11 从 error 降级：**基线不是可靠代理** ——
                      `patching_description` 就是活例子：en（以及 bg / de-CH / ko / pt-BR / zh-CN）
                      把"需要重启"那句**写死在正文里**，另 21 个语言用 `%@` 代入
                      （调用点是 `localizeWithFormat`）。两种都**正确**，但基线数 0 vs 1 会被
                      当成不一致 ⇒ 全语言假红。真正的危险方向（某个语言的占位符比调用点**实参**多
                      ⇒ `String(format:)` 读到不存在的参数）**本脚本量不出来**：那要靠调用点的实参
                      个数，这里不做（宁可漏，不误报）。

Usage:
  python3 Tools/l10n_lint.py                 # lint all locales
  python3 Tools/l10n_lint.py --locale ko     # lint a single locale
  python3 Tools/l10n_lint.py --no-usage      # skip the Swift cross-reference
  python3 Tools/l10n_lint.py --quiet         # only print problems (exit code)
  python3 Tools/l10n_lint.py --list-untranslated   # 逐条列出未翻译的键（默认只报数量）

Exit code is 1 when **errors** (extra / duplicate / missing file) are found, 0 otherwise.
Warnings (unused keys, verbatim English copies, format-arg count differences) and the
untranslated count do not fail the run.
"""

import argparse
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
BUNDLE_DIR = REPO_ROOT / "layout" / "Library" / "Application Support" / "EeveeSpotify.bundle"
SOURCES_DIR = REPO_ROOT / "Sources"

BASELINE = "en"

# One .strings entry: key = "value";  (value may contain escaped quotes)
ENTRY_RE = re.compile(r'^\s*(?P<key>"(?:[^"\\]|\\.)*"|[\w.\-]+)\s*=\s*"(?P<value>(?:[^"\\]|\\.)*)"\s*;', re.M)
COMMENT_RE = re.compile(r"/\*.*?\*/", re.S)
LINE_COMMENT_RE = re.compile(r"^\s*//.*$", re.M)

# Format specifiers that must match across translations: %@, %1$@, %d, %ld, %lu...
FORMAT_SPEC_RE = re.compile(r"%\d+\$[@dDuUxXoOfeEgGcCsS]|%[@dDuUxXoOfeEgGcCsS]")


def parse_strings_file(path: Path) -> dict[str, str]:
    """Parse a .strings file into an ordered {key: value} dict."""
    text = path.read_text(encoding="utf-8")
    text = COMMENT_RE.sub("", text)
    text = LINE_COMMENT_RE.sub("", text)
    entries = {}
    for m in ENTRY_RE.finditer(text):
        key = m.group("key").strip('"')
        entries[key] = m.group("value")
    return entries


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


def referenced_keys() -> set[str]:
    """Collect localization keys referenced anywhere in Swift sources."""
    keys: set[str] = set()
    if not SOURCES_DIR.exists():
        return keys
    swift_files = list(SOURCES_DIR.rglob("*.swift"))
    # Match: "key".localized / .localizeWithFormat / String(localized:) style usage,
    # plus raw table lookups. Keys are [a-zA-Z0-9_.-]+ quoted strings.
    patterns = [
        re.compile(r'"([A-Za-z0-9_.\-]+)"\s*\.\s*localized'),
        re.compile(r'"([A-Za-z0-9_.\-]+)"\s*\.\s*localizeWithFormat'),
        re.compile(r'localizedString\(\s*"([A-Za-z0-9_.\-]+)"'),
        re.compile(r'table:\s*[^,]+,\s*value:\s*"([A-Za-z0-9_.\-]+)"'),
    ]
    for sf in swift_files:
        try:
            text = sf.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        for pat in patterns:
            keys.update(pat.findall(text))
    return keys


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
    args = parser.parse_args()

    if not BUNDLE_DIR.exists():
        print(f"error: bundle dir not found: {BUNDLE_DIR}", file=sys.stderr)
        return 2

    baseline_path = BUNDLE_DIR / f"{BASELINE}.lproj" / "Localizable.strings"
    if not baseline_path.exists():
        print(f"error: baseline file not found: {baseline_path}", file=sys.stderr)
        return 2

    baseline = parse_strings_file(baseline_path)
    usage = set() if args.no_usage else referenced_keys()

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
        untranslated = sorted(baseline_keys - loc_keys)
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
            f"  UNTRANSLATED: {len(untranslated)}"
            " [informational — these fall back to English, nothing to fix]"
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
            print("  OK — fully in sync")
        print()

        if extra or dups:
            had_errors = True
        summary.append(
            f"{loc}: {len(loc_keys)} keys, {len(untranslated)} untranslated, {len(extra)} extra"
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
