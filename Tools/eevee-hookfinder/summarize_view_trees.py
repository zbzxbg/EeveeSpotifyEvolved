#!/usr/bin/env python3
"""把设备日志里的 `[Tree]` 转储清点成**逐屏的类名清单**。

背景：`ViewTreeDumper` 每次结构变化打一份树（一行一个节点，带 depth / 类名 / frame /
bg / hidden / id）。日志攒起来之后，"哪一屏有哪些类、哪一层画了底色"全都在里面 ——
但人眼看几千行不现实，所以用这个脚本清点。

它能回答的问题：
  · 每一屏（`vc=` 那一串）里出现了哪些**非系统类**；
  · 每个类第一次出现在第几层、有没有带底色（`bg=`）、有没有 id；
  · 哪些类**跨屏**存在（那种是"外壳"，适合做全局开关），哪些只属于某一屏。

用法：
    python Tools/eevee-hookfinder/summarize_view_trees.py <log> [<log> ...] [-o 输出文件]
"""

import argparse
import re
import sys
from collections import OrderedDict
from pathlib import Path

BEGIN_RE = re.compile(r"\[Tree\] #(\d+) begin vc=(\S+) nodes=(\d+)")
NODE_RE = re.compile(r"\[Tree\] #(\d+) (\d+)\.([^@]+)@([^\s|]*)(.*)$")

# 系统/框架类前缀：不是 Spotify 自己的东西，清点时略过
SYSTEM_PREFIXES = (
    "UI", "_UI", "NS", "CA", "AV", "SPT", "WK", "MK", "CL", "PHPicker", "TUI",
    "OBJC_ONLY_", "SwiftUI", "Core", "OS_", "TI", "AP", "GK", "SCN", "VK",
)
# 但 SPT 是 Spotify 的 ObjC 前缀，要留 —— 单列出来
KEEP_PREFIXES = ("SPT", "SP", "Encore", "Home", "Lyrics", "NowPlaying", "Nav", "Tab",
                 "Main", "Root", "Cover", "Canvas", "ElementView", "ElementContent",
                 "Stack", "Touch", "Layout", "Limited", "Jam", "Watch", "Card",
                 "Player", "Browse", "Search", "Library", "Playlist", "Album", "Artist")


def interesting(cls: str) -> bool:
    if any(cls.startswith(p) for p in KEEP_PREFIXES):
        return True
    return not any(cls.startswith(p) for p in SYSTEM_PREFIXES)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("logs", nargs="+")
    parser.add_argument("-o", "--out", default=None)
    args = parser.parse_args()

    dumps = []          # 按出现顺序的转储列表
    current = None      # 解析指针：节点行总是跟在它自己的 begin 行后面

    for log in args.logs:
        path = Path(log)
        if not path.is_file():
            print(f"skip (no such file): {path}", file=sys.stderr)
            continue

        current = None

        with path.open("r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                match = BEGIN_RE.search(line)
                if match:
                    # ⚠️ `#N` 每次启动都从 1 重数，所以不能只用编号当键 ——
                    # 合并多份日志时按出现顺序存列表，节点靠 `current` 归属。
                    current = {
                        "number": int(match.group(1)),
                        "vc": match.group(2),
                        "declared": int(match.group(3)),
                        "classes": OrderedDict(),   # cls -> [minDepth, bg?, id?]
                        "count": 0,
                        "source": path.name,
                    }
                    dumps.append(current)
                    continue

                match = NODE_RE.search(line)
                if not match or current is None:
                    continue
                if int(match.group(1)) != current["number"]:
                    continue

                depth = int(match.group(2))
                cls = match.group(3).strip()
                tail = match.group(5)

                current["count"] += 1

                if not interesting(cls):
                    continue

                info = current["classes"].setdefault(cls, [depth, False, False])
                info[0] = min(info[0], depth)
                if "bg=" in tail:
                    info[1] = True
                if "id=" in tail:
                    info[2] = True

    lines = []
    for entry in dumps:
        header = (f"# Tree #{entry['number']}  [{entry['source']}]  vc={entry['vc']}  "
                  f"nodes={entry['count']}/{entry['declared']}")
        lines.append("")
        lines.append(header)
        lines.append("-" * len(header))

        for cls, (depth, has_bg, has_id) in sorted(
            entry["classes"].items(), key=lambda item: (item[1][0], item[0])
        ):
            marks = []
            if has_bg:
                marks.append("bg")
            if has_id:
                marks.append("id")
            suffix = f"  [{','.join(marks)}]" if marks else ""
            lines.append(f"  d{depth:<3} {cls}{suffix}")

    # 跨屏汇总：出现在 >= 2 份转储里的类 = 外壳/常驻
    seen_in = {}
    for index, entry in enumerate(dumps):
        for cls in entry["classes"]:
            seen_in.setdefault(cls, []).append(index)

    lines.append("")
    lines.append("=" * 60)
    lines.append("跨屏常驻类（出现在 >=2 份转储里 —— 适合做全局开关）：")
    for cls, numbers in sorted(seen_in.items(), key=lambda item: -len(item[1])):
        if len(numbers) >= 2:
            lines.append(f"  {len(numbers):<3} {cls}")

    text = "\n".join(lines) + "\n"
    print(text if args.out is None else f"written: {args.out}")

    if args.out:
        Path(args.out).write_text(text, encoding="utf-8")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
