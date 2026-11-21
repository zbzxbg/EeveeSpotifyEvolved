#!/usr/bin/env python3
"""核对「Spotify 功能」页会显示/写入的每个键，是否都在词典里。

背景：那一页的行不是手写的 —— 数据在
`Sources/EeveeSpotify/Flags/SpotifyFeaturesCatalog.swift`（`key` / `labelKey` /
`titleKey`），视图只负责渲染。键名改了而词典没跟上，界面上就是**裸键名**
（本仓库已知的事故形状），而且只有真机上看得见。

这个脚本查两件事：

1. **词典覆盖**：数据里出现的每个 `labelKey` / `titleKey`，以及视图里写死的键，
   是否都在 `en.lproj`（必需）与 `zh-CN.lproj`（提示，缺了会回落英文）里。
2. **flag 键形态**：每个 `key` 必须是 `<scope>.<name>`，且
   `scope + "." + name` 能还原回去。scope 里没有点 —— 视图与这个脚本都靠这条规则切分，
   键写错时表现出来的是"写了一条永远不会命中的覆盖"（不报错、点了没反应）。

用法：
    python3 Tools/eevee-hookfinder/check_spotify_features_l10n.py
"""

import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
CATALOG = REPO / "Sources/EeveeSpotify/Flags/SpotifyFeaturesCatalog.swift"
VIEW = REPO / "Sources/EeveeSpotify/Settings/Sections/Flags/Views/SpotifyFeaturesView.swift"
STRINGS = {
    "en": REPO / "layout/Library/Application Support/EeveeSpotify.bundle/en.lproj/Localizable.strings",
    "zh-CN": REPO / "layout/Library/Application Support/EeveeSpotify.bundle/zh-CN.lproj/Localizable.strings",
}

# 视图里**写死**的键（不是从数据来的）。
FIXED_KEYS = [
    "flags_auto",
    "flag_override_mode_on",
    "flag_override_mode_off",
    "restart_is_required_description",
    "spotify_features_section_content",
    "spotify_features_hide_ai_badges",
    "spotify_features_hide_ai_badges_footer",
    "spotify_features_reset",
    "spotify_features_reset_footer",
]

DATA_KEY_RE = re.compile(r'\b(?:labelKey|titleKey|footerKey)\s*:\s*"([^"]+)"')
FLAG_KEY_RE = re.compile(r'\bkey\s*:\s*"([a-z0-9][a-z0-9.\-]+\.[a-z0-9_]+)"')
# 「隐藏 AI 徽章」那一组是 `[String]` 数组（一条开关写多条 flag），单独取。
AI_GROUP_RE = re.compile(r"aiBadgeFlags:\s*\[String\]\s*=\s*\[(.*?)\]", re.S)


def keys_in(strings_path: Path) -> set:
    text = strings_path.read_text(encoding="utf-8", errors="replace")
    return set(re.findall(r"(?m)^\s*([A-Za-z0-9_]+)\s*=", text))


def main() -> int:
    source = CATALOG.read_text(encoding="utf-8", errors="replace")
    view = VIEW.read_text(encoding="utf-8", errors="replace")

    l10n_keys = sorted(set(DATA_KEY_RE.findall(source)))
    flag_keys = sorted(set(FLAG_KEY_RE.findall(source)))

    ai_block = AI_GROUP_RE.search(source)
    ai_keys = sorted(set(re.findall(r'"([^"]+)"', ai_block.group(1)))) if ai_block else []
    all_flag_keys = sorted(set(flag_keys + ai_keys))

    problems = []

    if not l10n_keys:
        problems.append("解析不到任何 labelKey/titleKey —— 目录结构变了，先更新这个脚本")
    if not flag_keys:
        problems.append("解析不到任何 flag key —— 目录结构变了，先更新这个脚本")
    if not ai_keys:
        problems.append("解析不到 aiBadgeFlags —— 目录结构变了，先更新这个脚本")

    # ① flag 键形态（含 AI 那一组）
    for key in all_flag_keys:
        scope, _, name = key.partition(".")
        if not scope or not name:
            problems.append(f"{key}: 不是 <scope>.<name>")
            continue
        if "." in scope:
            problems.append(f"{key}: scope 里含点（scope 只允许小写字母/数字/连字符）")
        if "." in name:
            problems.append(f"{key}: name 里含点")

    # 两组之间不能撞键：撞了就是两个开关争同一条覆盖。
    overlap = sorted(set(flag_keys) & set(ai_keys))
    if overlap:
        problems.append("同一批行里重复的 flag: " + ", ".join(overlap))

    # ② 视图里写死的键，必须真的出现在视图源码里（防脚本与视图脱节）
    for key in FIXED_KEYS:
        if key in ("flags_auto", "flag_override_mode_on", "flag_override_mode_off"):
            continue  # 这些是「Flag 覆盖」页的公共键，不一定出现在本页源码里
        if key not in view:
            problems.append(f"{key}: 脚本要求了它，但视图里没用到 —— 脚本与视图脱节")

    # ③ 词典
    dicts = {lang: keys_in(path) for lang, path in STRINGS.items()}
    en_missing = [k for k in l10n_keys + FIXED_KEYS if k not in dicts["en"]]
    zh_missing = [k for k in l10n_keys + FIXED_KEYS if k not in dicts["zh-CN"]]

    print(f"flag keys : {len(flag_keys)} rows + {len(ai_keys)} in the AI group")
    print(f"l10n keys : {len(l10n_keys)} from data + {len(FIXED_KEYS)} fixed")

    for key in l10n_keys:
        note = ""
        if key not in dicts["zh-CN"]:
            note = "   (missing zh-CN -> falls back to en)"
        print(f"  {key}{note}")

    if en_missing:
        problems.append("en.lproj 缺键: " + ", ".join(sorted(en_missing)))

    print()
    if zh_missing:
        print(f"提示: zh-CN 缺 {len(zh_missing)} 个键（会回落英文，按单点提供政策不算错）")
    if problems:
        print("[FAIL]")
        for problem in problems:
            print("  - " + problem)
        return 1
    print(f"[OK] {len(all_flag_keys)} 个 flag 键形态正确，{len(l10n_keys) + len(FIXED_KEYS)} 个文案键都在 en")
    return 0


if __name__ == "__main__":
    sys.exit(main())
