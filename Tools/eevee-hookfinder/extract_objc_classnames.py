#!/usr/bin/env python3
"""从解密的 Spotify IPA 里抽取 **Objective-C 类名**。

为什么要单独抽 ObjC：
    `dump-9.1.86.txt`（`Tools/eevee-hookfinder` 那套）只覆盖 **Swift 类**（16930 个，全是
    `_TtC…` 名字）。而 Spotify 里一大批关键类恰恰是 ObjC 的 —— `SPNavigationBar`、
    `SPTNowPlayingBar`、`SPTDataLoaderService`、`NPVScrollViewController` …
    写 hook 时要能"搜到候选类"，这一半不能缺。

做法：直接读 Mach-O 的 `__objc_classname` 段（`otool -v -s __TEXT __objc_classname` 的等价物），
不靠 `strings` 全盘扫描（那会混进几百万条无关字符串）。

用法：
    python Tools/eevee-hookfinder/extract_objc_classnames.py <decrypted.ipa> [-o 输出目录]

产物：
    <输出目录>/objc-classnames.txt        每行一个类名（去重排序）
    <输出目录>/objc-classnames-by-image.txt    `<二进制名>\t<类名>`，能看出类住在哪个 image
"""

import argparse
import re
import sys
import zipfile
from pathlib import Path

MH_MAGIC_64 = 0xFEEDFACF
FAT_MAGIC = 0xCAFEBABE
FAT_MAGIC_64 = 0xCAFEBABF
LC_SEGMENT_64 = 0x19
CPU_TYPE_ARM64 = 0x0100000C

# Spotify 自己的类名长这样：ObjC 前缀 + 字母数字下划线，允许 `.`（Swift 嵌套的 ObjC 名）
NAME_RE = re.compile(rb"^[A-Za-z_][A-Za-z0-9_$.]{2,}$")

# 用户自己注入的东西，不属于 Spotify，不抽
SKIP_IMAGE_RE = re.compile(r"(EeveeSpotify|Orion|zxPluginsInject|EeveeSwiftProtobuf|CydiaSubstrate)", re.I)
# 太小的二进制一般没有 ObjC 类表
MIN_BINARY_BYTES = 256 * 1024


def slices(blob: bytes):
    """把 fat / thin Mach-O 统一成"待解析的 Mach-O 切片"列表。"""
    if len(blob) < 8:
        return []

    magic_be = int.from_bytes(blob[:4], "big")
    magic_le = int.from_bytes(blob[:4], "little")

    if magic_be in (FAT_MAGIC, FAT_MAGIC_64):
        is64 = magic_be == FAT_MAGIC_64
        entry_size = 32 if is64 else 20
        nfat = int.from_bytes(blob[4:8], "big")
        out = []
        for i in range(nfat):
            base = 8 + i * entry_size
            if base + entry_size > len(blob):
                break
            cputype = int.from_bytes(blob[base:base + 4], "big")
            if is64:
                offset = int.from_bytes(blob[base + 8:base + 16], "big")
                size = int.from_bytes(blob[base + 16:base + 24], "big")
            else:
                offset = int.from_bytes(blob[base + 8:base + 12], "big")
                size = int.from_bytes(blob[base + 12:base + 16], "big")
            if cputype == CPU_TYPE_ARM64 and size:
                out.append(blob[offset:offset + size])
        return out

    if magic_le == MH_MAGIC_64:
        return [blob]

    return []


def objc_classnames(blob: bytes):
    """读一个 Mach-O 切片里的 `__objc_classname` 段。"""
    names = set()

    for macho in slices(blob):
        if len(macho) < 32:
            continue
        if int.from_bytes(macho[:4], "little") != MH_MAGIC_64:
            continue

        ncmds = int.from_bytes(macho[16:20], "little")
        pos = 32
        for _ in range(ncmds):
            if pos + 8 > len(macho):
                break
            cmd = int.from_bytes(macho[pos:pos + 4], "little")
            cmdsize = int.from_bytes(macho[pos + 4:pos + 8], "little")
            if cmdsize < 8 or pos + cmdsize > len(macho):
                break

            if cmd == LC_SEGMENT_64:
                nsects = int.from_bytes(macho[pos + 64:pos + 68], "little")
                sect = pos + 72
                for _ in range(nsects):
                    if sect + 80 > len(macho):
                        break
                    sectname = macho[sect:sect + 16].split(b"\0")[0]
                    offset = int.from_bytes(macho[sect + 48:sect + 52], "little")
                    size = int.from_bytes(macho[sect + 40:sect + 48], "little")
                    if sectname == b"__objc_classname" and size and offset:
                        chunk = macho[offset:offset + size]
                        for raw in chunk.split(b"\0"):
                            if raw and NAME_RE.match(raw):
                                names.add(raw.decode("ascii", "ignore"))
                    sect += 80

            pos += cmdsize

    return names


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("ipa", help="解密后的 Spotify .ipa")
    parser.add_argument("-o", "--out", default=".spotify-ipa", help="输出目录")
    args = parser.parse_args()

    ipa = Path(args.ipa)
    if not ipa.is_file():
        print(f"no such ipa: {ipa}", file=sys.stderr)
        return 1

    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)

    all_names = set()
    per_image = []
    pair_lines = []

    with zipfile.ZipFile(ipa) as zf:
        candidates = []
        for info in zf.infolist():
            if info.is_dir() or info.file_size < MIN_BINARY_BYTES:
                continue

            filename = info.filename
            if not filename.startswith("Payload/Spotify.app/"):
                continue
            if SKIP_IMAGE_RE.search(filename):
                continue

            name = Path(filename).name
            is_main = filename == f"Payload/Spotify.app/{name}"
            is_framework_binary = (
                ".framework/" in filename and filename.endswith("/" + name)
            )
            is_dylib = filename.endswith(".dylib")

            if is_main or is_framework_binary or is_dylib:
                candidates.append((info, name))

        print(f"scanning {len(candidates)} binaries ...")
        for info, name in candidates:
            try:
                blob = zf.read(info)
            except Exception as exc:  # noqa: BLE001
                print(f"  ! read failed {info.filename}: {exc}", file=sys.stderr)
                continue

            names = objc_classnames(blob)
            if not names:
                continue

            per_image.append((name, len(names)))
            all_names |= names
            pair_lines.extend(f"{name}\t{cls}" for cls in names)

    (out_dir / "objc-classnames.txt").write_text(
        "\n".join(sorted(all_names)) + "\n", encoding="utf-8"
    )
    (out_dir / "objc-classnames-by-image.txt").write_text(
        "\n".join(sorted(pair_lines)) + "\n", encoding="utf-8"
    )

    print(f"\ntotal: {len(all_names)} unique ObjC class names "
          f"from {len(per_image)} binaries")
    print("top images:")
    for name, count in sorted(per_image, key=lambda item: -item[1])[:10]:
        print(f"  {count:6d}  {name}")
    print(f"written: {out_dir / 'objc-classnames.txt'}")

    for probe in ("SPNavigationBar", "SPTNowPlayingBar", "SPTDataLoaderService",
                  "NPVScrollViewController", "SPTSnackbarAnimationView"):
        print(f"  probe {probe}: {'FOUND' if probe in all_names else 'missing'}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
