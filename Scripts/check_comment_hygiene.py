#!/usr/bin/env python3
"""注释卫生检查：禁止把「调试日记」写进代码。

这个仓库的注释曾经大量引用只存在于作者电脑里的材料（截图编号、日志编号、
dump 出来的符号表行号），复述与用户的对话，记录试错轮次和日期戳。
读者既无法核对，也用不上。这个脚本把这些模式挡在门外。

用法：
    python3 Scripts/check_comment_hygiene.py            # 检查，有违规时退出码 1
    python3 Scripts/check_comment_hygiene.py --stat     # 只看统计
    python3 Scripts/check_comment_hygiene.py --max 20   # 每类最多列 20 条

豁免：
    单行末尾加 `# noqa: comment-hygiene`（Swift 用 `// noqa: comment-hygiene`）
    文件首行加 `// comment-hygiene: off` 可整文件跳过。
"""

import argparse
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE_DIRS = ("Sources", "modules")
SKIP_DIR_PARTS = ("Dependencies", "Generated", "swiftprotobuf")
SUFFIXES = (".swift", ".m", ".mm", ".h", ".xm", ".c", ".cpp")

COMMENT_PREFIXES = ("//", "/*", "*", "*/")

CHECKS = [
    (
        "外部引用",
        "引用了仓库里不存在的截图/日志/符号表，读者无从核对",
        re.compile(
            r"(?:照片|截图|图片)\s*\d+(?:\s*/\s*\d+)*"
            r"|日志\s*\d+(?:\s*/\s*\d+)*"
            r"|日志(?:里|中|显示|表明|摘录)"
            r"|dump-[\w.\-]+\.txt"
            r"|符号表"
        ),
    ),
    (
        "本机路径",
        "引用了作者电脑上的路径，别人打不开",
        re.compile(r"(?:[A-Za-z]:\\|\.spotify-ipa/|/Users/\w|/home/\w)"),
    ),
    (
        "对话复述",
        "把与用户的对话搬进注释，属于开发过程而非代码说明",
        re.compile(
            r"用户\s*[：:]\s*[「『\"]"
            r"|用户(?:拍板|要求|反馈|诊断|原话|特别点出|说)"
            r"|用户\s*20\d\d-"
        ),
    ),
    (
        "日期戳",
        "注释里记录日期属于变更日志，代码不该承担这个职责",
        re.compile(r"20\d\d-\d\d-\d\d"),
    ),
    (
        "星标",
        "★ 标记是私人重点记号，对读者没有含义",
        re.compile(r"★"),
    ),
    (
        "试错叙事",
        "记录的是作者当时的思考过程，不是代码现在的行为",
        re.compile(r"我先判|我以为|我们一开始|一开始我|后来才(?:发现|知道)|事后才|原来我|第[一二三四五]轮"),
    ),
]


DOC_REF = re.compile(r"[A-Za-z0-9_./\\-]+\.md\b")
DOC_CACHE = {}
TRACKED = None


def tracked_files():
    """仓库里被 git 跟踪的文件名集合 —— 读者 clone 下来能看到的就只有这些。"""
    global TRACKED
    if TRACKED is None:
        TRACKED = set()
        try:
            out = subprocess.run(
                ["git", "ls-files"], cwd=ROOT, capture_output=True, text=True, timeout=60
            ).stdout
            for line in out.splitlines():
                TRACKED.add(line.strip().replace("\\", "/"))
                TRACKED.add(os.path.basename(line.strip()))
        except (OSError, subprocess.SubprocessError):
            TRACKED = None
            return None
    return TRACKED


def missing_doc(ref):
    """注释里点名的 .md 在仓库里存不存在（只看 git 跟踪的文件）。"""
    if ref in DOC_CACHE:
        return DOC_CACHE[ref]
    known = tracked_files()
    if known is None:
        DOC_CACHE[ref] = False
        return False
    name = ref.replace("\\", "/").lstrip("./")
    gone = name not in known and os.path.basename(name) not in known
    DOC_CACHE[ref] = gone
    return gone


def iter_files():
    for base in SOURCE_DIRS:
        root = os.path.join(ROOT, base)
        if not os.path.isdir(root):
            continue
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames[:] = [d for d in dirnames if d not in SKIP_DIR_PARTS]
            for name in sorted(filenames):
                if name.endswith(SUFFIXES):
                    yield os.path.join(dirpath, name)


def is_comment(line):
    return line.lstrip().startswith(COMMENT_PREFIXES)


def scan(path):
    try:
        with open(path, encoding="utf-8", errors="ignore") as fh:
            lines = fh.read().replace("\r\n", "\n").split("\n")
    except OSError:
        return []
    if lines and "comment-hygiene: off" in lines[0]:
        return []

    hits = []
    in_block = False
    in_fence = False
    for number, line in enumerate(lines, 1):
        stripped = line.strip()
        if stripped.startswith("/*"):
            in_block = True
        if not (in_block or is_comment(line)):
            continue
        # 围栏里的内容（视图树、示例代码）是逐字材料，不做文字风格检查
        if stripped.lstrip("/*").strip().startswith("```"):
            in_fence = not in_fence
            if stripped.endswith("*/"):
                in_block = False
            continue
        if in_fence:
            if stripped.endswith("*/"):
                in_block = False
            continue
        if "noqa: comment-hygiene" in line:
            if stripped.endswith("*/"):
                in_block = False
            continue
        for label, _why, pattern in CHECKS:
            match = pattern.search(line)
            if match:
                hits.append((number, label, match.group(0)))
                break
        else:
            for ref in DOC_REF.findall(line):
                if missing_doc(ref):
                    hits.append((number, "失效文档引用", ref))
                    break
        if stripped.endswith("*/"):
            in_block = False
    return hits


def main():
    parser = argparse.ArgumentParser(description="注释卫生检查")
    parser.add_argument("--stat", action="store_true", help="只输出统计")
    parser.add_argument("--max", type=int, default=12, help="每类最多列出的条数")
    args = parser.parse_args()

    by_file = {}
    by_label = {}
    for path in iter_files():
        hits = scan(path)
        if hits:
            rel = os.path.relpath(path, ROOT).replace(os.sep, "/")
            by_file[rel] = hits
            for _number, label, _text in hits:
                by_label[label] = by_label.get(label, 0) + 1

    total = sum(by_label.values())
    if not total:
        print("注释卫生：通过，没有发现调试日记式的注释。")
        return 0

    if args.stat:
        print(f"违规 {total} 处，分布在 {len(by_file)} 个文件")
        for label, count in sorted(by_label.items(), key=lambda kv: -kv[1]):
            print(f"  {label}: {count}")
        return 1

    reasons = {label: why for label, why, _ in CHECKS}
    reasons["失效文档引用"] = "点名的文档不在仓库里，读者打不开"
    for label, count in sorted(by_label.items(), key=lambda kv: -kv[1]):
        print(f"\n{label}（{count} 处）—— {reasons[label]}")
        shown = 0
        for rel, hits in sorted(by_file.items()):
            for number, hit_label, text in hits:
                if hit_label != label:
                    continue
                if shown >= args.max:
                    break
                print(f"  {rel}:{number}  {text}")
                shown += 1
            if shown >= args.max:
                remaining = count - shown
                if remaining > 0:
                    print(f"  …另有 {remaining} 处")
                break

    print(f"\n合计 {total} 处，涉及 {len(by_file)} 个文件。")
    print("说明：注释应当解释代码现在做什么、为什么这样做、有什么坑；")
    print("      截图编号、日志编号、与用户的对话、日期和试错过程不属于注释。")
    return 1


if __name__ == "__main__":
    sys.exit(main())
