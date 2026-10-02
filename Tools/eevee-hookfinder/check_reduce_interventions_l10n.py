#!/usr/bin/env python3
"""核对「减少打扰」页会拼出来的 l10n 键，是否都在词典里。

背景：那一页的标签键不是字面量，而是
`reduce_interventions_flag_<shortName>` —— `shortName` 由 `KnownFlagCatalog` 里
每条 flag 的**名字**推出来（去掉 `enable_message_` 前缀）。名字改了而词典没跟上，
界面上就会出现**裸键名**（本仓库已知的一种事故形状），而且只会在真机上看见。

所以这个脚本做的事很机械、也只该这么做：
  1. 从 `KnownFlagCatalog.swift` 里抠出「减少打扰」那组（scope =
     `ios-messaging-reduceinterventions-impl`）的 flag 名字；
  2. 按视图里的规则算键（含两个被合并进"演唱会"那行的特例）；
  3. 逐条在 en / zh-CN 的 `Localizable.strings` 里找 `key =`；
  4. 报缺。

用法：
    python Tools/eevee-hookfinder/check_reduce_interventions_l10n.py
"""

import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
CATALOG = REPO / "Sources/EeveeSpotify/Flags/KnownFlagCatalog.swift"
STRINGS = {
    "en": REPO / "layout/Library/Application Support/EeveeSpotify.bundle/en.lproj/Localizable.strings",
    "zh-CN": REPO / "layout/Library/Application Support/EeveeSpotify.bundle/zh-CN.lproj/Localizable.strings",
}

SCOPE = "ios-messaging-reduceinterventions-impl"

# 与 `EeveeReduceInterventionsView.shortName(of:)` 保持一致
MERGED_INTO = {
    "enable_message_live_events_event_entity_safe_tooltip":
        "live_events_concert_notifications_tooltip",
    "enable_message_live_events_event_entity_venuename_header_too":
        "live_events_concert_notifications_tooltip",
}

# 视图里**写死**的几个键（不是拼出来的）
FIXED_KEYS = [
    "reduce_interventions_title",
    "reduce_interventions_master",
    "reduce_interventions_master_description",
    "reduce_interventions_master_footer",
    "reduce_interventions_tips_section",
    "reduce_interventions_tips_footer",
]


def flags_in_scope(source: str):
    """抠出 scope == SCOPE 的 (name, type) 列表。

    ⚠️ 目录里绝大多数 `KnownFlag(...)` 是**跨行**写的（名字一行、scope 一行、
    `.int` 与 `observed:` 再一行），所以不能用"一行一个 flag"的解析法 ——
    第一版就是这么写的，结果只抓到同在一行的那两条。这里先按括号配对切出整块，再解析。
    """
    out = []
    for m in re.finditer(r"KnownFlag\(", source):
        start = m.end()
        depth = 1
        i = start
        while i < len(source) and depth:
            if source[i] == "(":
                depth += 1
            elif source[i] == ")":
                depth -= 1
            i += 1
        block = source[start:i - 1]

        names = re.findall(r'"([^"]+)"', block)
        if len(names) < 2:
            continue
        name, scope = names[0], names[1]
        if scope != SCOPE:
            continue
        is_int = re.search(r"(?:^|,)\s*\.int\s*,", block) is not None
        out.append((name, "int" if is_int else "bool"))
    return out


def short_name(name: str) -> str:
    if name in MERGED_INTO:
        return MERGED_INTO[name]
    if name.startswith("enable_message_"):
        return name[len("enable_message_"):]
    return name


def keys_in(strings_path: Path):
    text = strings_path.read_text(encoding="utf-8", errors="replace")
    return set(re.findall(r"(?m)^\s*([A-Za-z0-9_]+)\s*=", text))


def main() -> int:
    catalog = CATALOG.read_text(encoding="utf-8", errors="replace")
    flags = flags_in_scope(catalog)
    if not flags:
        print(f"[FAIL] no flag with scope={SCOPE} found in {CATALOG.name} -- parser needs updating")
        return 2

    master = [n for n, _ in flags if n == "enabled"]
    tips = [(n, t) for n, t in flags if n != "enabled" and t == "bool"]

    # 视图只给 bool 的提示行；int 那条（max_account_age_days）不进这一页
    wanted = []
    if master:
        wanted += ["reduce_interventions_master", "reduce_interventions_master_description"]
    wanted += FIXED_KEYS
    for name, _ in tips:
        s = short_name(name)
        wanted += [f"reduce_interventions_flag_{s}", f"reduce_interventions_flag_{s}_description"]

    seen, ordered = set(), []
    for k in wanted:
        if k not in seen:
            seen.add(k)
            ordered.append(k)

    dicts = {lang: keys_in(path) for lang, path in STRINGS.items()}

    print(f"scope={SCOPE}: {len(flags)} flag(s) total (master {len(master)}, bool tips {len(tips)})")
    for name, kind in flags:
        print(f"  - {name}  [{kind}]")
    print(f"\nthe view will use {len(ordered)} key(s):")

    failed = False
    for key in ordered:
        missing = [lang for lang, keys in dicts.items() if key not in keys]
        mark = "OK      " if not missing else "MISSING "
        if missing:
            failed = True
        print(f"  {mark} {key}" + (f"   <- missing in: {','.join(missing)}" if missing else ""))

    print()
    if failed:
        print("[FAIL] missing keys -- the device UI would show raw key names")
        return 1
    print("[OK] every key exists in en / zh-CN")
    return 0


if __name__ == "__main__":
    sys.exit(main())
