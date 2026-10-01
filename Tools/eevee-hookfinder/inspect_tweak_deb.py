#!/usr/bin/env python3
"""只读地摊开一个 Theos tweak 的 `.deb`（用来清点**用户可见功能**，不是读实现）。

为什么需要它：缺口的对照对象（spoti.pw）是 PolyForm Strict，本仓库的规矩是
**只看思路、代码全部自己写**。所以这个脚本刻意只抽"用户能看到的东西"：
  · `control`（包元数据：版本/描述/依赖）
  · 任何 `*.bundle/**/Localizable.strings`（设置页里那些开关的名字与说明）
  · `*.plist`（偏好设置键名 = 一份功能清单）
  · 随包的 `.md` / `README`
**不反汇编、不读二进制里的实现**（二进制只在需要时用 `strings` 粗看一眼类名，且不落盘）。

deb 就是个 ar 归档：`!<arch>\n` + 若干成员（`debian-binary` / `control.tar.*` / `data.tar.*`），
成员之间以 2 字节对齐。Windows 上没有 `ar`，所以这里自己解析。

⚠️ **别把导出结果提交进仓库**：`--strings` / `--out` 落下来的是**被检查对象自己的产物**
（本例里 spoti.pw 是 PolyForm Strict 1.0.0），只用于当面对照，用完即删。
仓库里只留这个脚本与**结论**（结论写在 `SPOTIPW_GAP.md`）。

用法：
    python Tools/eevee-hookfinder/inspect_tweak_deb.py <deb> [--out 目录]
    python Tools/eevee-hookfinder/inspect_tweak_deb.py <deb> --list          # 只列文件，不解包
    python Tools/eevee-hookfinder/inspect_tweak_deb.py <deb> --strings out.txt
"""
from __future__ import annotations

import argparse
import io
import lzma
import os
import re
import sys
import tarfile
import gzip


def read_ar_members(blob: bytes) -> list[tuple[str, bytes]]:
    """解析 ar 归档 → [(name, payload)]。"""
    if not blob.startswith(b"!<arch>\n"):
        raise SystemExit("这不是 ar 归档（deb 应该以 !<arch> 开头）")

    members: list[tuple[str, bytes]] = []
    offset = 8
    while offset + 60 <= len(blob):
        header = blob[offset:offset + 60]
        name = header[0:16].decode("utf-8", "replace").strip()
        size_field = header[48:58].decode("utf-8", "replace").strip()
        if not size_field.isdigit():
            break
        size = int(size_field)
        start = offset + 60
        members.append((name.rstrip("/"), blob[start:start + size]))
        offset = start + size + (size % 2)  # 2 字节对齐
    return members


def decompress(name: str, payload: bytes) -> bytes | None:
    """按扩展名解压 control/data 成员。"""
    try:
        if name.endswith(".tar.gz") or name.endswith(".tgz"):
            return gzip.decompress(payload)
        if name.endswith(".tar.xz") or name.endswith(".tar.lzma"):
            return lzma.decompress(payload)
        if name.endswith(".tar.zst"):
            try:
                import zstandard  # type: ignore
            except ImportError:
                print("  ⚠️ 这个 deb 用 zstd，本机没有 zstandard 模块 —— 跳过解包", file=sys.stderr)
                return None
            return zstandard.ZstdDecompressor().decompress(payload)
        if name.endswith(".tar"):
            return payload
    except Exception as error:  # noqa: BLE001 - 只读工具，出错就报出来
        print(f"  ⚠️ 解压 {name} 失败：{error}", file=sys.stderr)
    return None


def iter_tar(blob: bytes) -> list[tuple[str, bool, int, bytes]]:
    """→ [(name, is_file, size, payload)]，内容**一次读完**（别把打开的 tar 交出去）。"""
    out: list[tuple[str, bool, int, bytes]] = []
    with tarfile.open(fileobj=io.BytesIO(blob)) as tar:
        for member in tar.getmembers():
            payload = b""
            if member.isfile():
                handle = tar.extractfile(member)
                payload = handle.read() if handle else b""
            out.append((member.name, member.isfile(), member.size, payload))
    return out


def printable_strings(blob: bytes, minimum: int = 5) -> list[str]:
    """把二进制里的**可见字符串**捞出来（ASCII + UTF-16LE 两种编码）。

    ⚠️ 这是本工具的**边界**：只捞"字符串"（设置页上那些文案、偏好键、URL），
    **不反汇编、不读方法实现** —— 对照对象的许可是 PolyForm Strict，本仓库的规矩是
    只看思路、代码全部自己写。
    """
    found: list[str] = []

    for match in re.finditer(rb"[\x20-\x7e]{%d,}" % minimum, blob):
        found.append(match.group().decode("ascii", "replace"))

    # UTF-16LE（ObjC/Clang 里中文文案常见这个编码）：
    #   ASCII 宽字符 = `[\x20-\x7e]\x00`；CJK（U+4E00–U+9FFF）= 低字节任意 + 高字节 `[\x4e-\x9f]`
    wide = re.compile(
        b"(?:(?:[\x20-\x7e]\x00)|(?:[\x00-\xff][\x4e-\x9f])){%d,}" % minimum
    )
    for match in wide.finditer(blob):
        try:
            text = match.group().decode("utf-16-le")
        except UnicodeDecodeError:
            continue
        if text.strip():
            found.append(text)

    return found


INTERESTING = re.compile(
    r"(Localizable\.strings|\.plist|\.md$|README|LICENSE|\.json$|\.stringsdict$)", re.I
)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("deb")
    parser.add_argument("--out", default=None, help="把这些文本文件落到哪个目录（默认不落盘）")
    parser.add_argument("--list", action="store_true", help="只列出所有文件")
    parser.add_argument(
        "--strings",
        metavar="输出文件",
        default=None,
        help="把 data.tar 里每个二进制的**可见字符串**去重后写到这个文件（只看文案/键名，不看实现）",
    )
    args = parser.parse_args(argv[1:])

    blob = open(args.deb, "rb").read()
    members = read_ar_members(blob)
    print(f"deb: {os.path.basename(args.deb)}（{len(blob)} 字节，{len(members)} 个 ar 成员）")

    for name, payload in members:
        print(f"\n== {name}（{len(payload)} 字节）")
        if name == "control":
            print(payload.decode("utf-8", "replace"))
            continue
        if name == "debian-binary":
            continue

        raw = decompress(name, payload)
        if raw is None:
            continue

        members_in_tar = list(iter_tar(raw))
        print(f"   {len(members_in_tar)} 个文件")

        if args.strings:
            collected: set[str] = set()
            for name, is_file, _size, payload in members_in_tar:
                if is_file:
                    collected.update(printable_strings(payload))
            with open(args.strings, "w", encoding="utf-8", newline="\n") as handle:
                for text in sorted(collected):
                    handle.write(text + "\n")
            print(f"   可见字符串 {len(collected)} 条 → {args.strings}")

        for name, is_file, size, payload in members_in_tar:
            if args.list:
                print(f"     {name}  ({size})")
                continue
            if not is_file:
                continue
            if not INTERESTING.search(name):
                continue
            if args.out:
                target = os.path.join(args.out, name.lstrip("./").replace("/", os.sep))
                os.makedirs(os.path.dirname(target), exist_ok=True)
                with open(target, "wb") as handle:
                    handle.write(payload)
                print(f"     落盘：{target}")
            else:
                print(f"     {name}  ({size})")

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
