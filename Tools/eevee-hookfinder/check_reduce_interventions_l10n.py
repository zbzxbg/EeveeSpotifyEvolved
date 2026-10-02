#!/usr/bin/env python3
"""核对「减少打扰」页会拼出来的 l10n 键，是否都在词典里。

背景：那一页的标签键不是字面量，而是按 `KnownFlagCatalog` 里每条 flag 的
scope/name 拼出来的（规则见 `EeveeReduceInterventionsView.labelKey(for:)`）：

  * scope == `ios-messaging-reduceinterventions-impl` → `reduce_interventions_flag_<去掉 enable_message_ 前缀的名字>`
  * 其它 scope                                        → `reduce_interventions_flag_<scope 末段>_<flag 名>`

名字改了而词典没跟上，界面上就会出现**裸键名**（本仓库已知的一种事故形状），
而且只会在真机上看见。这个脚本就是把"这一页会拼出来的每个键"拿去词典里找一遍。

它覆盖**两组**：
  · `flag_group_interventions`（Spotify 自己的"减少打扰"模块）
  · `flag_group_hints`（2026-10-03 第二批：别的 scope 里的同类提示）

用法：
    python Tools/eevee-hookfinder/check_reduce_interventions_l10n.py
"""

import re
import sys
from collections import OrderedDict
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
CATALOG = REPO / "Sources/EeveeSpotify/Flags/KnownFlagCatalog.swift"
STRINGS = {
    "en": REPO / "layout/Library/Application Support/EeveeSpotify.bundle/en.lproj/Localizable.strings",
    "zh-CN": REPO / "layout/Library/Application Support/EeveeSpotify.bundle/zh-CN.lproj/Localizable.strings",
}

MAIN_SCOPE = "ios-messaging-reduceinterventions-impl"

# 与 `EeveeReduceInterventionsView.curatedHints` 保持一致：第二批**只显示这些行**。
# 这是刻意的白名单 —— 组里还有没写文案的 flag，渲染整组会让它们显示裸键名。
CURATED_HINTS = {
    "ios-feature-connectnotifications|disable_connect_nudges",
    "ios-feature-sleeptimer|nudge_on_audiobooks",
    "ios-device-predictability|is_smart_control_nudge_enabled",
    "ios-feature-yourlibaryx|enable_euterpe_tooltip",
    "ios-feature-yourlibaryx|show_new_episodes_offboarding_card",
    "ios-feature-yourlibaryx|pin_more_items_banner_enabled",
}

# 与 `EeveeReduceInterventionsView.shortName(of:)` 保持一致
MERGED_INTO = {
    "enable_message_live_events_event_entity_safe_tooltip":
        "live_events_concert_notifications_tooltip",
    "enable_message_live_events_event_entity_venuename_header_too":
        "live_events_concert_notifications_tooltip",
}

# 视图里**写死**的键（不是拼出来的）
FIXED_KEYS = [
    "reduce_interventions_title",
    "reduce_interventions_master",
    "reduce_interventions_master_description",
    "reduce_interventions_master_footer",
    "reduce_interventions_tips_section",
    "reduce_interventions_tips_footer",
]


def groups(source: str):
    """{titleKey: [(name, scope, type), …]} —— 按 `KnownFlagGroup(` 切块再解析。

    ⚠️ 目录里绝大多数 `KnownFlag(...)` 是**跨行**写的，所以先按括号配对切出整块再解析
    （第一版按"一行一个 flag"解析，只抓到同在一行的那几条）。
    """
    result = OrderedDict()
    for gm in re.finditer(r"KnownFlagGroup\(", source):
        start = gm.end()
        depth, i = 1, start
        while i < len(source) and depth:
            if source[i] == "(":
                depth += 1
            elif source[i] == ")":
                depth -= 1
            i += 1
        block = source[start:i - 1]

        title = re.search(r'titleKey:\s*"([^"]+)"', block)
        if not title:
            continue
        title_key = title.group(1)

        flags = []
        for m in re.finditer(r"KnownFlag\(", block):
            s = m.end()
            d, j = 1, s
            while j < len(block) and d:
                if block[j] == "(":
                    d += 1
                elif block[j] == ")":
                    d -= 1
                j += 1
            inner = block[s:j - 1]

            names = re.findall(r'"([^"]+)"', inner)
            if len(names) < 2:
                continue
            name, scope = names[0], names[1]
            is_int = re.search(r"(?:^|,)\s*\.int\s*,", inner) is not None
            flags.append((name, scope, "int" if is_int else "bool"))

        result[title_key] = flags
    return result


def last_scope_segment(scope: str) -> str:
    return scope.split("-")[-1]


def short_name(name: str, scope: str) -> str:
    if name in MERGED_INTO and scope == MAIN_SCOPE:
        base = MERGED_INTO[name]
    elif scope == MAIN_SCOPE and name.startswith("enable_message_"):
        base = name[len("enable_message_"):]
    else:
        base = name

    if scope == MAIN_SCOPE:
        return base
    return last_scope_segment(scope) + "_" + base


def keys_in(strings_path: Path):
    text = strings_path.read_text(encoding="utf-8", errors="replace")
    return set(re.findall(r"(?m)^\s*([A-Za-z0-9_]+)\s*=", text))


def main() -> int:
    catalog = CATALOG.read_text(encoding="utf-8", errors="replace")
    all_groups = groups(catalog)

    main_flags = all_groups.get("flag_group_interventions")
    hint_flags = all_groups.get("flag_group_hints")
    if main_flags is None:
        print("[FAIL] parser found no flag_group_interventions -- update this script")
        return 2
    if hint_flags is None:
        print("[FAIL] parser found no flag_group_hints -- update this script")
        return 2

    wanted = list(FIXED_KEYS)
    master = [f for f in main_flags if f[0] == "enabled"]
    if master:
        wanted += ["reduce_interventions_master", "reduce_interventions_master_description"]
    # ⚠️ 与视图一致：这里也**只认主 scope**。`flag_group_interventions` 里混着 6 条别的
    # scope 的 flag，视图不渲染它们（否则会显示裸键名），脚本当然也不该要求它们的键。
    skipped_main = []
    for name, scope, kind in main_flags:
        if name == "enabled" or kind != "bool" or scope != MAIN_SCOPE:
            if scope != MAIN_SCOPE:
                skipped_main.append(f"{scope}.{name}")
            continue
        s = short_name(name, scope)
        wanted += [f"reduce_interventions_flag_{s}", f"reduce_interventions_flag_{s}_description"]

    hint_scopes = []
    for name, scope, kind in hint_flags:
        if kind != "bool":
            continue
        if (scope + "|" + name) not in CURATED_HINTS:
            continue
        if scope not in hint_scopes:
            hint_scopes.append(scope)
        s = short_name(name, scope)
        wanted += [f"reduce_interventions_flag_{s}", f"reduce_interventions_flag_{s}_description"]
    for scope in hint_scopes:
        seg = last_scope_segment(scope)
        wanted += [f"reduce_interventions_scope_{seg}", f"reduce_interventions_scope_{seg}_footer"]

    seen, ordered = set(), []
    for k in wanted:
        if k not in seen:
            seen.add(k)
            ordered.append(k)

    dicts = {lang: keys_in(path) for lang, path in STRINGS.items()}

    print(f"main scope : {len(main_flags)} flag(s) in flag_group_interventions"
          f" (page renders only scope=={MAIN_SCOPE}; skipped {len(skipped_main)})")
    if skipped_main:
        for item in skipped_main:
            print(f"    skipped: {item}")
    print(f"hints      : {len(hint_flags)} flag(s) in flag_group_hints,"
          f" {len(CURATED_HINTS)} curated, scopes={hint_scopes}")
    print(f"the view will use {len(ordered)} key(s):")

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
