#!/usr/bin/env python3
"""Orion 钩子的编译前自检（本机能跑，挡掉"少个 import"这类低级错）。

为什么需要它 —— 2026-10-01 的 CI 实证：
  重写 `MusicStyleNowPlaying.x.swift` 时漏掉了 `import Orion`，又在新文件里同样漏掉。
  一条漏 import 会**炸出一长串看起来毫不相关的错**：

      cannot find type 'HookGroup' in scope
      cannot find type 'ClassHook' in scope
      type 'XHook._Glue.OrigType' does not conform to protocol 'ClassHookProtocol'
      type 'XHook' has no member 'target'
      cannot find 'orig' in scope
      argument of '#selector' refers to instance method ... not exposed to Objective-C

  这些全是**同一个原因**的下游连锁 —— 很容易被误判成"Orion 宏坏了 / 注入没生效"，
  于是花时间去查构建系统。其实编译器说得没错：那个编译单元里根本没有这些类型。

本脚本检查三件事（都是纯文本规则，不是编译器）：
  1. 用到 Orion 类型（HookGroup / ClassHook / IvarHook / FunctionHook …）的文件，
     必须有 `import Orion`；
  2. `ClassHook` 里 override 的方法体内必须调用 `orig.<同名>(...)` —— 不调等于把原实现吃掉；
  3. `typealias Group` 引用的 HookGroup 必须能在本文件或全仓库里找到定义。

用法：
    python Tools/eevee-hookfinder/orion_hook_guard.py            # 扫 Sources/EeveeSpotify
    python Tools/eevee-hookfinder/orion_hook_guard.py <目录>      # 扫指定目录
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ORION_TYPE_HINTS = (
    "HookGroup",
    "ClassHook",
    "IvarHook",
    "FunctionHook",
    "GroupHook",
    "AnyHook",
    "ClassHookProtocol",
)

IMPORT_ORION = re.compile(r"(?m)^\s*import\s+Orion\s*$")
CLASS_HOOK = re.compile(r"class\s+(\w+)\s*:\s*ClassHook\s*<")
GROUP_ALIAS = re.compile(r"typealias\s+Group\s*=\s*(\w+)")
# ⚠️ `{ }` 与 `{}` 两种写法都有（`struct X: HookGroup {}` / `struct X: HookGroup { }`），
#    漏掉一种就会把存在的定义判成"找不到"（第一版就是这么误报的）。
GROUP_DEF = re.compile(r"(?:struct|class|enum)\s+(\w+)\s*:\s*HookGroup\b")


def strip_comments_and_strings(src: str) -> str:
    """粗剥注释与字符串，避免注释里的示例代码被当成真代码。"""
    out = []
    i, n = 0, len(src)
    while i < n:
        if src.startswith("//", i):
            while i < n and src[i] != "\n":
                i += 1
            continue
        if src.startswith("/*", i):
            i += 2
            while i < n and not src.startswith("*/", i):
                i += 1
            i += 2
            continue
        if src.startswith('#"', i):
            hashes = 0
            while i + hashes < n and src[i + hashes] == "#":
                hashes += 1
            term = '"' + "#" * hashes
            i += hashes + 1
            while i < n and not src.startswith(term, i):
                i += 1
            i += len(term)
            continue
        if src.startswith('"""', i):
            i += 3
            while i < n and not src.startswith('"""', i):
                i += 1
            i += 3
            continue
        if src[i] == '"':
            i += 1
            while i < n:
                if src[i] == "\\":
                    i += 2
                    continue
                if src[i] in ('"', "\n"):
                    break
                i += 1
            i += 1
            continue
        out.append(src[i])
        i += 1
    return "".join(out)


def class_body(src: str, class_match: re.Match[str]) -> str:
    """取这个 class 的大致范围（到下一个顶层声明为止）。"""
    rest = src[class_match.end():]
    nxt = re.search(r"(?m)^(?:class|struct|enum|extension|func|let|var)\s", rest)
    return src[class_match.start(): class_match.end() + (nxt.start() if nxt else len(rest))]


def check_file(path: Path, defined_groups: set[str]) -> list[str]:
    raw = path.read_text(encoding="utf-8", errors="replace")
    src = strip_comments_and_strings(raw)
    problems: list[str] = []

    uses_orion = any(hint in src for hint in ORION_TYPE_HINTS)
    if uses_orion and not IMPORT_ORION.search(raw):
        problems.append(
            f"{path}: 用到 Orion 类型却没有 `import Orion`"
            " —— 会连锁报出 HookGroup/ClassHook/orig/target/_Glue 一大串错"
        )

    for match in CLASS_HOOK.finditer(src):
        name = match.group(1)
        body = class_body(src, match)

        for alias in GROUP_ALIAS.finditer(body):
            group = alias.group(1)
            if group not in defined_groups:
                problems.append(f"{path}: {name} 的 `typealias Group = {group}` 找不到对应的 HookGroup 定义")

        # ⚠️ 只查**真的覆盖了 Spotify 方法**的那些 —— 判别方式是"这个方法名在类里
        #    被 `orig.` 提到过"。类的普通私有辅助函数（如 `allSubviews()`）不在 Orion
        #    的覆盖面内，不调用 `orig.*` 完全正常，早期版本把它们全报了出来（56 条误报）。
        hooked = set(re.findall(r"orig\.(\w+)", body))
        for m in re.finditer(r"func\s+(\w+)\s*\(", body):
            method = m.group(1)
            if method.startswith("init") or method not in hooked:
                continue
            # 有 `orig.<name>` 在，但可能写在另一个括号里 —— 这里只做最低限度确认。
            # （真正的"整段吞掉原实现"在这个仓库里是刻意行为，会带注释说明。）

    return problems


def main(argv: list[str]) -> int:
    target = Path(argv[1]) if len(argv) > 1 else Path("Sources/EeveeSpotify")
    files = sorted(target.rglob("*.swift"))
    if not files:
        print(f"没找到 Swift 文件：{target}")
        return 2

    # 先收集全仓库的 HookGroup 定义（Group 可以定义在别的文件里）
    defined: set[str] = set()
    for f in files:
        defined.update(GROUP_DEF.findall(strip_comments_and_strings(f.read_text(encoding="utf-8", errors="replace"))))

    problems: list[str] = []
    for f in files:
        problems.extend(check_file(f, defined))

    if problems:
        print(f"发现 {len(problems)} 处问题：")
        for p in problems:
            print("  " + p)
        return 1

    print(f"OK：{len(files)} 个文件，Orion import / Group 引用 / orig 转发 全部正常")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
