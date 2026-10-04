#!/usr/bin/env python3
r"""把真机抓到的 customize 响应体（base64）转成可随包的 .bnk 种子。

为什么需要它
────────────
`SpotifyResponsePatcher.seedCustomizeDataIfNeeded` 用的种子是
`EeveeSpotify.bundle/resolveconfiguration*.bnk` —— 也就是
**`ResolveConfiguration` 这一个 message 的序列化字节**。

而设置页「转储 customize 响应体」抓下来的是**整份 `CustomizeMessage`**，
它比种子多包了两层：

    CustomizeMessage          field 1 (response, length-delimited)
      └ UcsResponse           field 1 (resolve,  length-delimited)
          └ ResolveResponse   field 1 (configuration, length-delimited)
              └ ResolveConfiguration   ← 这一层的字节才是 .bnk

本脚本就做那两刀。它**不做任何猜测**：找不到期望的结构就报错退出，
绝不产出一个"看起来像"的文件（错的种子会让 flag 全错，比没有更糟）。

用法
────
    # 1) 从日志里取出 base64（两行标记之间）
    #
    #    ⚠️ 2026-10-12 修正：日志每一行前面都有 `[时间] ` 前缀，而且**载荷那一行没有
    #    `[CustomizeBody]` 标签**（只有 `[2026-10-04 13:57:55 +0000] CoTGBgq…`）。
    #    旧版这条命令按"载荷独占一行"来写 ⇒ 前缀没被剥掉 ⇒ 脚本报
    #    `base64 解码失败：Only base64 data is allowed`。下面这条是**真机验证过的**：
    pwsh -Command "$t=Get-Content .\eeveespotify_debug_shared.log -Raw; `
      $m=[regex]::Match($t,'(?s)\[CustomizeBody\] base64-begin\r?\n(.*?)\r?\n\[[^\]]+\] \[CustomizeBody\] base64-end'); `
      $b64=(($m.Groups[1].Value -split \"\r?\n\") | ForEach-Object { $_ -replace '^\[[^\]]+\]\s*','' }) -join ''; `
      Set-Content -Encoding ascii custom.b64 $b64"

    # 2) 转成 .bnk
    python Tools/eevee-hookfinder/bnk_from_customize_dump.py custom.b64 -o new.bnk

    # 3) 核对（会打印 flag 条数，与日志里 [CustomizeSeed] 那行对得上才算成功）
    python Tools/eevee-hookfinder/bnk_from_customize_dump.py --inspect new.bnk

    # 4) 装进 bundle（**留着旧文件做回退**），并同步两处契约：
    #    · `Sources/EeveeSpotify/Premium/Helpers/BundledConfigurationPolicy.swift`
    #      —— 加一个 `spotify91XXResourceName` + 版本门槛（9.1.88 就是这么加的）；
    #    · `Tests/ResolveConfigurationSnapshot/test.py`
    #      —— 加一条 `inspect(...)`，填**新文件的 sha256 与 assignment 条数**（CI 会核对）。
    copy new.bnk "layout\Library\Application Support\EeveeSpotify.bundle\resolveconfiguration_9_1_88.bnk"

⚠️ 抓到的 body 里**没有**账号私有信息之外的东西（就是配置），但它含你的
账号所属的 A/B 分组；提交进仓库前自己判断一下要不要用它（本地自用则无所谓）。
"""

from __future__ import annotations

import argparse
import base64
import re
import sys
from pathlib import Path

# ── 最小 protobuf wire-format 读取 ───────────────────────────────────────────
# 只需要 length-delimited(field 1) 与 varint，不引第三方库（CI/沙箱里也能跑）。

WIRE_VARINT = 0
WIRE_I64 = 1
WIRE_LEN = 2
WIRE_I32 = 5


def read_varint(buf: bytes, pos: int) -> tuple[int, int]:
    result = 0
    shift = 0
    while True:
        if pos >= len(buf):
            raise ValueError(f"varint 越界 @{pos}")
        byte = buf[pos]
        pos += 1
        result |= (byte & 0x7F) << shift
        if not byte & 0x80:
            return result, pos
        shift += 7
        if shift > 63:
            raise ValueError("varint 过长")


def iter_fields(buf: bytes):
    """产出 (field_number, wire_type, payload_start, payload_end, value_start)。"""
    pos = 0
    while pos < len(buf):
        key, pos = read_varint(buf, pos)
        field_no = key >> 3
        wire_type = key & 0x07

        if wire_type == WIRE_VARINT:
            _, pos = read_varint(buf, pos)
            continue
        if wire_type == WIRE_LEN:
            length, pos = read_varint(buf, pos)
            start = pos
            end = pos + length
            if end > len(buf):
                raise ValueError(f"length-delimited 越界 @{start} len={length}")
            yield field_no, wire_type, start, end
            pos = end
            continue
        if wire_type == WIRE_I64:
            pos += 8
            continue
        if wire_type == WIRE_I32:
            pos += 4
            continue
        raise ValueError(f"未知 wire type {wire_type} @{pos}")


def field_bytes(buf: bytes, field_no: int) -> bytes:
    """取某个 length-delimited 字段的内容；缺失/重复都报错（宁可炸不要猜）。"""
    hits = [buf[s:e] for no, wt, s, e in iter_fields(buf) if no == field_no and wt == WIRE_LEN]
    if not hits:
        raise ValueError(f"找不到 field {field_no}（length-delimited）")
    if len(hits) > 1:
        raise ValueError(f"field {field_no} 出现 {len(hits)} 次，预期 1 次")
    return hits[0]


def unwrap_customize_message(raw: bytes) -> bytes:
    """CustomizeMessage → ResolveConfiguration 的字节。"""
    ucs = field_bytes(raw, 1)          # CustomizeMessage.response (UcsResponse)
    resolve = field_bytes(ucs, 1)      # UcsResponse.resolve    (ResolveResponse)
    return field_bytes(resolve, 1)     # ResolveResponse.configuration (ResolveConfiguration)


def count_assigned_values(configuration: bytes) -> int:
    """数 ResolveConfiguration 里的 assignedValues 条数（field 3，repeated）。"""
    return sum(
        1
        for no, wt, _s, _e in iter_fields(configuration)
        if no == 3 and wt == WIRE_LEN
    )


# ── CLI ─────────────────────────────────────────────────────────────────────

B64_BLOCK = re.compile(
    r"\[CustomizeBody\] base64-begin\s*\n(.*?)\n\s*\[CustomizeBody\] base64-end",
    re.S,
)


def load_body(path: Path) -> bytes:
    text = path.read_text(encoding="utf-8", errors="replace")

    # 直接给日志文件也行：自动把标记之间的那一段抠出来。
    match = B64_BLOCK.search(text)
    if match:
        text = match.group(1)

    compact = re.sub(r"\s+", "", text)
    try:
        return base64.b64decode(compact, validate=True)
    except Exception as exc:  # noqa: BLE001 - 报错信息要原样给用户看
        raise SystemExit(f"base64 解码失败：{exc}\n（确认给的是 base64 文本，不是 .bnk 二进制）")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("input", type=Path, help="base64 文本，或含 base64-begin/end 标记的日志文件")
    ap.add_argument("-o", "--output", type=Path, help="输出的 .bnk 路径")
    ap.add_argument("--inspect", action="store_true", help="只看结构、不写文件（对 .bnk 或 dump 都行）")
    args = ap.parse_args()

    if not args.input.exists():
        raise SystemExit(f"输入不存在：{args.input}")

    raw = args.input.read_bytes()

    # 允许 --inspect 直接吃 .bnk（二进制）：那就跳过 base64 解码。
    looks_like_text = all(b < 0x80 or b in (0x0A, 0x0D) for b in raw[:64])
    if looks_like_text:
        message = load_body(args.input)
        print(f"输入：base64 解码后 {len(message)} 字节（CustomizeMessage）")
        configuration = unwrap_customize_message(message)
    else:
        configuration = raw
        print(f"输入：当作 .bnk 直接使用，{len(configuration)} 字节（ResolveConfiguration）")

    n = count_assigned_values(configuration)
    print(f"ResolveConfiguration：{len(configuration)} 字节，assignedValues {n} 条")

    if n == 0:
        print("⚠️ assignedValues 是 0 条 —— 这份种子对 flag 改写没有意义，先别替换。")
        return 2

    if args.inspect:
        print("（--inspect：没有写文件）")
        return 0

    if not args.output:
        raise SystemExit("要写文件就加 -o/--output；只看结构请加 --inspect")

    args.output.write_bytes(configuration)
    print(f"已写出：{args.output}（{len(configuration)} 字节）")
    print("下一步：把它复制到 EeveeSpotify.bundle 下替换同名 .bnk（先备份旧文件）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
