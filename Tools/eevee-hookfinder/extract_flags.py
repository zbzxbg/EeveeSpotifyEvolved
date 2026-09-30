#!/usr/bin/env python3
"""从解密后的 Spotify IPA 里抽 **UCS / remote-config flag 表**（只读，不改 IPA）。

为什么需要它
------------
`Sources/EeveeSpotify/Flags/KnownFlagCatalog.swift` 里那 41 条 flag 是**从真机日志**攒出来的：
`DynamicPremium+ModifyingFunctions.swift` 只会走「歌词」和「NPV」两组 flag，
所以那两条链路之外的 flag（尤其是 Spotify 自己新设计的那几个）**在日志里永远不出现**。

spoti.pw 的 `docs/tweaks.md` 给了路线情报：它的玻璃重设计建立在
「强制 Spotify 自己的新设计 flag」之上（玻璃导航栏 / 新播放器滑块 / sheet 式播放器 /
queue 与 Connect sheet / 重设计播放器头 / 睡眠定时器选项 sheet）。
那几个 flag 名只能从 app 二进制里拿 —— 这个脚本就是干这个的。

它做什么
--------
1. 列 IPA 条目，挑出「主二进制 + 可能装 flag 表的 plist/json」；
2. 用 `--probe` 给的一个**已知** flag 名/scope 去定位 flag 表到底在哪个条目里；
3. 在那个条目里抽出
     · 全部 `ios-…` 形态的 **scope**
     · 全部 `*_enabled` / `*_disabled` 形态的 **flag 名**
     · 设计相关的 scope 附近 `--context` 字节的原文（二进制里 flag 名通常就和 scope 挨着）
4. `-o DIR` 时把它们落盘成 `flag-scopes.txt` / `flag-names.txt`（可复用，像 `make flags`）。

用法
----
    python Tools/eevee-hookfinder/extract_flags.py "<ipa 路径>"
    python Tools/eevee-hookfinder/extract_flags.py "<ipa>" -o .spotify-ipa --context 600
    python Tools/eevee-hookfinder/extract_flags.py "<ipa>" --probe ios-feature-canvas

注意：只读 `zipfile`，不会写出 IPA、不会解包整个包（8MB 分块流式扫描）。
"""

from __future__ import annotations

import argparse
import io
import os
import re
import sys
import zipfile

# 我们已知存在的一条 scope / flag，用来定位「flag 表在哪个条目」。
DEFAULT_PROBES = ["ios-feature-canvas", "lyrics_on_canvas_enabled"]

# `ios-feature-canvas` / `ios-nowplaying-contentlayers-impl` 这种形态。
SCOPE_RE = re.compile(rb"\bios-[a-z0-9]+(?:-[a-z0-9]+){0,6}\b")

# flag 名：仓库目录里绝大多数是 `*_enabled`，另有少量 `*_disabled`。
FLAG_SUFFIX_RE = re.compile(rb"\b[a-z][a-z0-9_]{3,60}_(?:enabled|disabled)\b")

# **最有用的形态**：二进制里 flag key 常常是字面量 `<scope>.<name>`
# （真机日志 `[Flags] … flag — scope=… name=…` 与之对应）。
# 例：`ios-reprise-liquid-glass-override.mode`、`ios-feature-sleeptimer.use_options_sheet`。
PAIR_RE = re.compile(
    rb"(ios-[a-z0-9]+(?:-[a-z0-9]+){0,7})\.([a-z0-9_]{2,60})"
)

# 设计/外观相关的关键词（用于把「可能跟新外观有关」的东西挑出来先看）。
DESIGN_KEYWORDS = [
    "glass", "design", "redesign", "liquid", "ui", "uikit", "navbar", "nav_bar",
    "tabbar", "tab_bar", "player", "slider", "sheet", "sleep", "timer", "queue",
    "connect", "header", "hero", "card", "artwork", "canvas", "theme", "dark",
    "animation", "transition", "morph", "layout",
]

CHUNK = 8 * 1024 * 1024
OVERLAP = 4096


def open_ipa(path: str) -> zipfile.ZipFile:
    if not os.path.isfile(path):
        sys.exit(f"找不到 IPA: {path}")
    return zipfile.ZipFile(path)


def list_candidates(zf: zipfile.ZipFile) -> list[tuple[str, int]]:
    """主二进制 + 名字像 flag 表的条目，按大小降序。"""
    out: list[tuple[str, int]] = []
    for info in zf.infolist():
        if info.is_dir():
            continue
        name = info.filename
        base = os.path.basename(name).lower()

        is_main_binary = (
            name.startswith("Payload/")
            and name.count("/") == 2
            and "." not in base  # Payload/X.app/X
        )
        looks_like_table = any(
            k in base for k in ("flag", "ucs", "remoteconfig", "remote_config", "config", "experiment")
        ) and info.file_size < 40 * 1024 * 1024

        if is_main_binary or looks_like_table:
            out.append((name, info.file_size))

    out.sort(key=lambda item: item[1], reverse=True)
    return out


def scan_for_probes(zf: zipfile.ZipFile, entries: list[tuple[str, int]], probes: list[str]) -> list[str]:
    """返回「命中 probe」的条目名（按扫描顺序）。"""
    hits: list[str] = []
    needle = [p.encode() for p in probes]

    for name, size in entries:
        if size > 400 * 1024 * 1024:
            continue
        found = False
        try:
            with zf.open(name) as fh:
                while True:
                    chunk = fh.read(CHUNK)
                    if not chunk:
                        break
                    if any(n in chunk for n in needle):
                        found = True
                        break
        except Exception as exc:  # 加密/损坏/不支持的压缩方式
            print(f"  [跳过] {name}: {exc}", file=sys.stderr)
            continue
        if found:
            hits.append(name)
    return hits


def extract_from(zf: zipfile.ZipFile, entry: str) -> tuple[set[str], set[str], set[tuple[str, str]]]:
    scopes: set[str] = set()
    flags: set[str] = set()
    pairs: set[tuple[str, str]] = set()

    with zf.open(entry) as fh:
        carry = b""
        while True:
            chunk = fh.read(CHUNK)
            if not chunk:
                break
            buf = carry + chunk
            for m in SCOPE_RE.finditer(buf):
                scopes.add(m.group().decode("ascii", "ignore"))
            for m in FLAG_SUFFIX_RE.finditer(buf):
                flags.add(m.group().decode("ascii", "ignore"))
            for m in PAIR_RE.finditer(buf):
                pairs.add(
                    (
                        m.group(1).decode("ascii", "ignore"),
                        m.group(2).decode("ascii", "ignore"),
                    )
                )
            carry = buf[-OVERLAP:]  # 只留尾部，跨块边界不漏

    return scopes, flags, pairs


def design_hits(names: set[str]) -> list[str]:
    return sorted(
        n for n in names if any(k in n for k in DESIGN_KEYWORDS)
    )


def contexts(zf: zipfile.ZipFile, entry: str, scopes: set[str], width: int, per_scope: int = 2) -> None:
    """把「设计相关 scope」附近的原文打出来 —— flag 名通常就在 scope 旁边。

    ⚠️ 这里**不缓存整个二进制**：流式再扫一遍，只对命中的位置取上下文。
    """
    if width <= 0:
        return

    interesting = [s for s in sorted(scopes) if any(k in s for k in DESIGN_KEYWORDS)]
    print(f"\n=== 设计相关 scope 附近的原文（±{width} 字节，每个最多 {per_scope} 处） ===")
    if not interesting:
        print("（没有设计相关的 scope）")
        return

    needles = {s: s.encode() for s in interesting}
    remaining = {s: per_scope for s in interesting}
    carry = b""

    with zf.open(entry) as fh:
        while True:
            chunk = fh.read(CHUNK)
            if not chunk:
                break
            buf = carry + chunk
            for scope, needle in needles.items():
                if remaining[scope] <= 0:
                    continue
                start = 0
                while remaining[scope] > 0:
                    pos = buf.find(needle, start)
                    if pos < 0:
                        break
                    lo = max(0, pos - width)
                    hi = min(len(buf), pos + len(needle) + width)
                    text = "".join(
                        chr(b) if 32 <= b < 127 else "·" for b in buf[lo:hi]
                    )
                    text = re.sub(r"·{2,}", " · ", text)
                    print(f"\n--- {scope} ---")
                    print(text)
                    remaining[scope] -= 1
                    start = pos + len(needle)
            carry = buf[-OVERLAP:]


def main() -> int:
    ap = argparse.ArgumentParser(description="从解密 Spotify IPA 抽 UCS flag 表（只读）")
    ap.add_argument("ipa", help="解密后的 .ipa 路径")
    ap.add_argument("-o", "--out-dir", default=None, help="把 scopes/flags 落盘到这个目录")
    ap.add_argument("--probe", action="append", default=None,
                    help=f"用于定位 flag 表的已知字符串（可多次；默认 {DEFAULT_PROBES}）")
    ap.add_argument("--context", type=int, default=400,
                    help="设计相关 scope 附近打印多少字节原文（0 = 不打印）")
    ap.add_argument("--list-only", action="store_true", help="只列候选条目就退出")
    args = ap.parse_args()

    probes = args.probe or DEFAULT_PROBES

    with open_ipa(args.ipa) as zf:
        entries = list_candidates(zf)
        print(f"=== IPA 候选条目（{len(entries)} 个，按大小降序） ===")
        for name, size in entries:
            print(f"{size/1024/1024:10.1f} MB  {name}")

        if args.list_only:
            return 0

        print(f"\n=== 用 probe 定位 flag 表：{probes} ===")
        hits = scan_for_probes(zf, entries, probes)
        if not hits:
            print("没有任何条目命中 probe —— 换一个 probe 或者这不是解密过的 IPA。")
            return 2
        for name in hits:
            print(f"  命中: {name}")

        # 取命中里最大的那个当 flag 表（通常就是主二进制）。
        target = max(hits, key=lambda n: zf.getinfo(n).file_size)
        print(f"\n=== 从 {target} 抽取 ===")
        scopes, flags, pairs = extract_from(zf, target)
        print(f"scope（ios-…）: {len(scopes)} 个")
        print(f"flag（*_enabled/_disabled）: {len(flags)} 个")
        print(f"**scope.name 配对**: {len(pairs)} 条")

        d_scopes = design_hits(scopes)
        d_flags = design_hits(flags)
        d_pairs = sorted(
            (s, n) for (s, n) in pairs
            if any(k in s or k in n for k in DESIGN_KEYWORDS)
        )
        print(f"其中「设计相关」: scope {len(d_scopes)} 个 / flag {len(d_flags)} 个 / 配对 {len(d_pairs)} 条")

        print("\n=== 设计相关 scope ===")
        for s in d_scopes:
            print("  " + s)
        print("\n=== 设计相关 flag 名 ===")
        for f in d_flags:
            print("  " + f)
        print("\n=== 设计相关 scope.name 配对 ===")
        for s, n in d_pairs:
            print(f"  {s}  ->  {n}")

        contexts(zf, target, scopes, args.context)

        if args.out_dir:
            os.makedirs(args.out_dir, exist_ok=True)
            with open(os.path.join(args.out_dir, "flag-scopes.txt"), "w", encoding="utf-8") as fh:
                fh.write("\n".join(sorted(scopes)) + "\n")
            with open(os.path.join(args.out_dir, "flag-names.txt"), "w", encoding="utf-8") as fh:
                fh.write("\n".join(sorted(flags)) + "\n")
            with open(os.path.join(args.out_dir, "flag-table.txt"), "w", encoding="utf-8") as fh:
                fh.write("# scope\tname（从 IPA 二进制里抽出的字面量，非结论）\n")
                for s, n in sorted(pairs):
                    fh.write(f"{s}\t{n}\n")
            with open(os.path.join(args.out_dir, "flag-design.txt"), "w", encoding="utf-8") as fh:
                fh.write("# 设计相关（关键词过滤，非结论）\n\n[scope]\n")
                fh.write("\n".join(d_scopes) + "\n\n[flag]\n")
                fh.write("\n".join(d_flags) + "\n\n[scope.name]\n")
                for s, n in d_pairs:
                    fh.write(f"{s}\t{n}\n")
            print(f"\n已写出: {args.out_dir}/flag-scopes.txt, flag-names.txt, flag-table.txt, flag-design.txt")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
