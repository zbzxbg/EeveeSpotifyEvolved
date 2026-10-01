#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""审计：仓库里**每一个 hook 目标 / 运行时类名字面量**，在目标版本的 Spotify 里还在不在。

为什么需要它
------------
Spotify 每个版本都会搬类、改名、删实验。仓库里 `static let targetName = "..."` 这类
字面量一旦指向一个**不存在的类**，Orion 的 hook 会静默不装（我们自己的 `activateXxx`
多半只打一行 `missing`，有的甚至只在系统控制台 `NSLog`），功能就成了"假开关"：
设置页还在、用户点了没反应。

三份真相来源（**可信度不一样，报告里分开标**）
------------------------------------------------
1. `dump-<版本>.txt` 的 `[classes]` —— **只覆盖 Swift 类**（16930 条，全是 `_TtC…`）。
   命中它 = 权威。
2. `.spotify-ipa/objc-classnames-by-image.txt` —— ObjC 类名，但实测**只覆盖 2 个镜像**
   （`Spotify` / `SpotifyShared`，5837 条），连真机上明明存在的 `SPTEncoreLabel`、
   `SPTNowPlayingBar` 都没有 → **只当线索，不能当"不存在"的证据**。
3. `--ipa <解密 IPA>` —— 逐条把类名当**字节串**在包内所有二进制里搜一遍。
   注意：搜到 ≠ 一定定义在此包（可能是引用），但**搜不到 = 这个名字在整个 App 里都不出现**
   → 这条足够判"过时"。

和 `Scripts/diff-symbol-dumps.py` 的分工（别搞混）
----------------------------------------------
· `Scripts/diff-symbol-dumps.py`：CI `binary-diff.yml` 用的那个 —— **dump 对 dump** 的版本对比，
  **只看 Swift**（它自己文档里写了点号写法的子串匹配会漏报），要有"上一次的 dump"当基线。
· 本脚本：**时点核对**（不需要基线）+ **ObjC 目标** + **IPA 字节级判定**。
  换新版 Spotify 时两条都值得跑：先看 CI 那份 CRITICAL，再用本脚本收 ObjC 这半。

用法
----
    python Tools/eevee-hookfinder/audit_stale_targets.py                     # 快（只读两份清单）
    python Tools/eevee-hookfinder/audit_stale_targets.py --ipa "<ipa 路径>"  # 慢一点，权威
    python Tools/eevee-hookfinder/audit_stale_targets.py --show-ok          # 连命中的也列出来

判读
----
    [✓ Swift]      命中 9.1.86 的 Swift 类表（权威）
    [✓ ObjC]       命中 ObjC 线索清单（说明这份清单里有，正常）
    [✓ IPA]        名字在 IPA 里出现过（定义或引用）→ 正常
    [✗ 过时]       给出 --ipa 后才可能有这个结论：整个 IPA 里都没有这个名字
    [? 待核]       没给 --ipa 时的"两份清单都没命中"，**只是嫌疑**
    [· 系统/私有]  系统框架 / 私有类（CarPlay、NSURLSessionTask、UIGlassEffect…），正常
"""

import argparse
import os
import re
import sys
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))

SRC_ROOTS = [os.path.join(REPO, "Sources")]

RE_TARGET = re.compile(r'static\s+let\s+targetName\s*=\s*"([^"]+)"')
RE_CLASS_FROM_STRING = re.compile(r'NSClassFromString\(\s*"([^"]+)"\s*\)')
RE_KNOWN_FLAG = re.compile(r'KnownFlag\(\s*"([^"]+)"\s*,\s*"([^"]+)"', re.S)

# 系统 / 私有前缀：本来就不该出现在 App 的类表里
SYSTEM_PREFIXES = (
    "NS", "UI", "CA", "CG", "CP", "_UI", "_NS", "ART", "WK", "AV", "MP", "SK",
    "CL", "MK", "PK", "QL", "SF", "UN", "WC", "HM", "IN", "EK", "CN", "GK",
)

CHUNK = 8 << 20      # 8MB
CARRY = 64           # 跨块边界时留一点尾巴，防止名字被切断


def demangle_swift(raw):
    """`_TtC23NavigationUI_TabBarImpl10TabBarView` → `NavigationUI_TabBarImpl.TabBarView`。"""
    m = re.match(r"^_TtC+(\d+)(.*)$", raw)
    if not m:
        return None
    mod_len = int(m.group(1))
    rest = m.group(2)
    if len(rest) < mod_len:
        return None
    module, tail = rest[:mod_len], rest[mod_len:]

    parts, i = [], 0
    while i < len(tail):
        j = i
        while j < len(tail) and tail[j].isdigit():
            j += 1
        if j == i:
            return None
        n = int(tail[i:j])
        name = tail[j:j + n]
        if len(name) != n:
            return None
        parts.append(name)
        i = j + n
    if not parts:
        return None
    return module + "." + ".".join(parts)


def load_dump_classes(path):
    """[classes] 桶 → (原始名集合, 去混淆后的点号名集合)。**只覆盖 Swift。**"""
    raw, dotted = set(), set()
    if not os.path.isfile(path):
        return raw, dotted
    bucket = None
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if line.startswith("["):
                bucket = line.split("]")[0][1:].strip()
                continue
            if bucket != "classes" or not line or line.startswith("#"):
                continue
            raw.add(line)
            d = demangle_swift(line)
            if d:
                dotted.add(d)
    return raw, dotted


def load_ipa_classes(path):
    """`镜像名<TAB>类名` → {类名: 镜像名}。实测只覆盖 2 个镜像。"""
    table = {}
    if not os.path.isfile(path):
        return table
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.rstrip("\n")
            if not line or "\t" not in line:
                continue
            image, cls = line.split("\t", 1)
            table.setdefault(cls.strip(), image.strip())
    return table


BINARY_HINT = ("/Spotify", ".framework/", ".dylib", ".appex/", "/PlugIns/")


def ipa_scan(ipa_path, names):
    """把 `names` 当字节串在 IPA 内所有二进制里搜一遍 → {名字: [镜像名…]}。"""
    hits, remaining = {}, set(names)
    if not remaining:
        return hits
    total = 0
    with zipfile.ZipFile(ipa_path) as zf:
        entries = [i for i in zf.infolist()
                   if i.file_size > 64 * 1024
                   and (any(h in i.filename for h in BINARY_HINT) or "/" not in i.filename)]
        for info in entries:
            if not remaining:
                break
            total += info.file_size
            short = info.filename.rsplit("/", 1)[-1]
            try:
                with zf.open(info) as fh:
                    carry = b""
                    while remaining:
                        chunk = fh.read(CHUNK)
                        if not chunk:
                            break
                        buf = carry + chunk
                        for n in list(remaining):
                            if n.encode("utf-8") in buf:
                                hits.setdefault(n, []).append(short)
                                remaining.discard(n)
                        carry = buf[-CARRY:]
            except Exception as exc:                      # 坏条目不该让整轮审计崩掉
                print("   ! %s: %s" % (short, exc), file=sys.stderr)
            print("   扫过 %-40s 累计 %6.1f MB" % (short[:40], total / 1048576.0), file=sys.stderr)
    return hits


def iter_sources():
    for root in SRC_ROOTS:
        for dirpath, _dirnames, filenames in os.walk(root):
            for fn in filenames:
                if fn.endswith(".swift"):
                    yield os.path.join(dirpath, fn)


def collect_literals():
    rows, seen = [], set()
    for path in iter_sources():
        rel = os.path.relpath(path, REPO)
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            for lineno, line in enumerate(fh, 1):
                for rx in (RE_TARGET, RE_CLASS_FROM_STRING):
                    for lit in rx.findall(line):
                        key = (lit, rel, lineno)
                        if key in seen:
                            continue
                        seen.add(key)
                        rows.append((lit, "%s:%d" % (rel, lineno)))
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dump", default=r"C:\dsh\ipa\dump-9.1.86.txt")
    ap.add_argument("--ipa-classes",
                    default=os.path.join(REPO, ".spotify-ipa", "objc-classnames-by-image.txt"))
    ap.add_argument("--flag-table",
                    default=os.path.join(REPO, ".spotify-ipa", "flag-table.txt"))
    ap.add_argument("--ipa", default=None,
                    help="解密 IPA；给了就把'两份清单都没命中'的名字做字节级核对（慢）")
    ap.add_argument("--show-ok", action="store_true")
    args = ap.parse_args()

    dump_raw, dump_dotted = load_dump_classes(args.dump)
    ipa_classes = load_ipa_classes(args.ipa_classes)
    images = sorted({v for v in ipa_classes.values()})
    print("来源① Swift 类表 : %d 条（去混淆 %d）   ← %s"
          % (len(dump_raw), len(dump_dotted), args.dump))
    print("来源② ObjC 线索  : %d 条 / 只覆盖镜像 %s"
          % (len(ipa_classes), ", ".join(images) or "—"))
    print("来源③ IPA 字节核对: %s" % (args.ipa or "未启用（--ipa 打开）"))

    counts = {"swift": 0, "objc": 0, "system": 0, "ipa": 0, "stale": 0, "todo": 0}
    rows = []
    for lit, where in collect_literals():
        leaf = lit.split(".")[-1]
        if lit in dump_raw or lit in dump_dotted:
            counts["swift"] += 1
            rows.append(("✓ Swift", lit, where))
        elif lit in ipa_classes or leaf in ipa_classes:
            counts["objc"] += 1
            rows.append(("✓ ObjC(%s)" % (ipa_classes.get(lit) or ipa_classes.get(leaf)), lit, where))
        elif lit.startswith(SYSTEM_PREFIXES):
            counts["system"] += 1
            rows.append(("· 系统/私有", lit, where))
        else:
            counts["todo"] += 1
            rows.append(("? 待核", lit, where))

    pending = sorted({r[1] for r in rows if r[0] == "? 待核"})

    if args.ipa and pending:
        print("\n对 %d 个'待核'名字做 IPA 字节核对（这是唯一能判'过时'的一步）…" % len(pending))
        hits = ipa_scan(args.ipa, pending)
        resolved = []
        for label, lit, where in rows:
            if label != "? 待核":
                resolved.append((label, lit, where))
            elif lit in hits:
                counts["todo"] -= 1
                counts["ipa"] += 1
                resolved.append(("✓ IPA(%s)" % ",".join(sorted(set(hits[lit]))[:2]), lit, where))
            else:
                counts["todo"] -= 1
                counts["stale"] += 1
                resolved.append(("✗ 过时", lit, where))
        rows = resolved

    print("\n==== 1) hook 目标 / 运行时类名（共 %d 处字面量）====" % len(rows))
    print("Swift 命中 %d ｜ ObjC 线索命中 %d ｜ IPA 字节命中 %d ｜ 系统私有 %d ｜ **过时 %d** ｜ 待核 %d"
          % (counts["swift"], counts["objc"], counts["ipa"], counts["system"],
             counts["stale"], counts["todo"]))

    for label, title in (("✗ 过时", "✗ 判定过时（整个 IPA 里都没有这个名字）"),
                         ("? 待核", "? 待核（两份清单都没命中；加 --ipa 才能定性）"),
                         ("· 系统/私有", "· 系统/私有（正常）")):
        group = [r for r in rows if r[0] == label]
        print("\n-- %s --" % title)
        if not group:
            print("   （无）")
        for _st, lit, where in sorted(group, key=lambda r: r[1]):
            print("  %-58s %s" % (lit, where))

    if args.show_ok:
        print("\n-- ✓ 命中 --")
        for st, lit, where in sorted(rows, key=lambda r: r[1]):
            if st.startswith("✓"):
                print("  %-14s %-58s %s" % (st, lit, where))

    # ---------- 2) KnownFlagCatalog vs 9.1.86 的字面量表 ----------
    table = set()
    if os.path.isfile(args.flag_table):
        with open(args.flag_table, "r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                parts = line.rstrip("\n").split("\t")
                if len(parts) >= 2:
                    table.add((parts[0].strip(), parts[1].strip()))
    cat_path = os.path.join(REPO, "Sources", "EeveeSpotify", "Flags", "KnownFlagCatalog.swift")
    catalog = []
    if os.path.isfile(cat_path):
        with open(cat_path, "r", encoding="utf-8", errors="replace") as fh:
            catalog = RE_KNOWN_FLAG.findall(fh.read())

    if table and catalog:
        gone = [(n, s) for (n, s) in catalog if (s, n) not in table]
        print("\n==== 2) KnownFlagCatalog（%d 条）vs 9.1.86 字面量表（%d 条）===="
              % (len(catalog), len(table)))
        if gone:
            print("-- ✗ 表里没有的名字（可能已改名/已下线）--")
            for n, s in gone:
                print("  %s.%s" % (s, n))
        else:
            print("-- 全部命中 --")
    return 0


if __name__ == "__main__":
    sys.exit(main())
