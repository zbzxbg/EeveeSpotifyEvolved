#!/usr/bin/env python3
"""设置目录的静态检查。

`Sources/EeveeSpotify/Settings/Views/SettingsCatalog.swift` 是设置根页的唯一数据源，
里面的字符串键一旦拼错，运行时不会崩，只会把原始 key 显示在界面上。这个脚本把它
需要的键与 `Localizable.strings` 对一遍，顺带检查 id 唯一、每行都有 destination。

用法（仓库根目录）：
    python3 Scripts/check_settings_catalog.py
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CATALOG = ROOT / "Sources/EeveeSpotify/Settings/Views/SettingsCatalog.swift"
BUNDLE = ROOT / "layout/Library/Application Support/EeveeSpotify.bundle"

# 只有 en 是权威表；zh-CN 是主要翻译语言，缺键也要报出来。
REQUIRED_LOCALES = ["en.lproj", "zh-CN.lproj"]
# 其余语言缺键会回退到 en，所以只提示不失败。
FALLBACK_LOCALES = ["zh-TW.lproj"]


def parse_catalog(text: str):
    entries = []
    for block in re.split(r"SettingsEntry\(", text)[1:]:
        entry_id = re.search(r'id:\s*"([^"]+)"', block)
        group = re.search(r"group:\s*\.(\w+)", block)
        title = re.search(r'titleKey:\s*"([^"]+)"', block)
        # 副标题已从根页去掉，所以是可选的；哪天加回来，缺键照样报。
        subtitle = re.search(r'subtitleKey:\s*"([^"]+)"', block)
        if not (entry_id and group and title):
            continue
        entries.append(
            {
                "id": entry_id.group(1),
                "group": group.group(1),
                "title": title.group(1),
                "subtitle": subtitle.group(1) if subtitle else None,
                "has_destination": "destination:" in block,
            }
        )

    groups = re.findall(r'case \.(\w+): return "(settings_group_[^"]+)"', text)
    return entries, groups


def parse_keys(path: Path):
    keys = set()
    for line in path.read_text(encoding="utf-8").splitlines():
        match = re.match(r'^([A-Za-z0-9_.]+)\s*=\s*"', line)
        if match:
            keys.add(match.group(1))
    return keys


def main():
    text = CATALOG.read_text(encoding="utf-8")
    entries, groups = parse_catalog(text)

    problems = []

    ids = [entry["id"] for entry in entries]
    duplicates = sorted({item for item in ids if ids.count(item) > 1})
    if duplicates:
        problems.append(f"重复的 id: {', '.join(duplicates)}")

    for entry in entries:
        if not entry["has_destination"]:
            problems.append(f"{entry['id']}: 没有 destination")

    declared_groups = {name for name, _ in groups}
    for entry in entries:
        if entry["group"] not in declared_groups:
            problems.append(f"{entry['id']}: 分组 {entry['group']} 不在 SettingsGroup 里")

    for entry in entries:
        if not any(item["group"] == entry["group"] for item in entries):
            problems.append(f"{entry['id']}: 分组为空")

    # 搜索页与根页里直接写死、不经过目录的键。
    needed = {
        "settings_search_title",
        "settings_search_placeholder",
        "settings_search_empty",
    }
    needed.update(key for _, key in groups)
    needed.update(entry["title"] for entry in entries)
    needed.update(entry["subtitle"] for entry in entries if entry["subtitle"])

    for locale in REQUIRED_LOCALES:
        path = BUNDLE / locale / "Localizable.strings"
        if not path.exists():
            problems.append(f"缺少 {locale}/Localizable.strings")
            continue
        missing = sorted(needed - parse_keys(path))
        if missing:
            problems.append(f"{locale} 缺键: {', '.join(missing)}")

    for locale in FALLBACK_LOCALES:
        path = BUNDLE / locale / "Localizable.strings"
        if not path.exists():
            continue
        missing = sorted(needed - parse_keys(path))
        if missing:
            print(f"提示: {locale} 缺 {len(missing)} 个键（会回退到 en）")

    if problems:
        print("设置目录检查失败：")
        for problem in problems:
            print(f"  - {problem}")
        return 1

    print(f"设置目录 OK：{len(entries)} 行，{len(groups)} 组，{len(needed)} 个字符串键。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
