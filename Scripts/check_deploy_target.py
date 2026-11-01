#!/usr/bin/env python3
"""检查「iOS 最低部署版本」在六个地方是否一致。

为什么要单独查这一项
--------------------
这个值分散在构建链的 6 处，任何一处落后都会造成**静默失效**而不是显式报错：

· 根 `Makefile` 的 `TARGET`、`modules/zxPluginsInject/Makefile` 的 `TARGET`
  —— dylib 按它编译（`LC_BUILD_VERSION.minos`）。
· `control` 的 `firmware` —— deb 的安装门槛。
· 三个构建脚本的 `cyan -m` —— 盖输出 IPA 的 `MinimumOSVersion`。

写低了会怎样：安装器只看 IPA 的 `MinimumOSVersion` 说"能装"，装完启动时 dyld 才发现
dylib 要更高的系统 —— `Translation.framework` 是强链接，低版本系统上连框架都不存在，
于是 App 起不来。表现往往只是一句 dlerror，很难定位。

用法
----
    python3 Scripts/check_deploy_target.py            # 不一致时退出码 1
"""

import io
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

TARGET_RE = re.compile(r"^TARGET\s*:=\s*iphone:clang:latest:([0-9]+\.[0-9]+)", re.M)
CONTROL_RE = re.compile(r"firmware\s*\(>=\s*([0-9]+\.[0-9]+)\s*\)")
CYAN_M_RE = re.compile(r"cyan\s+-i.*?-m\s+([0-9]+\.[0-9]+)", re.S)

CYAN_FILES = (
    "build-ipa-local.sh",
    ".github/workflows/build-ipa-with-orion.yml",
    ".github/workflows/build-ipa-with-orion-patched.yml",
)


def read(rel):
    with io.open(os.path.join(ROOT, rel), "r", encoding="utf-8", errors="replace") as f:
        return f.read()


def main():
    checks = []  # (where, what, version)

    for rel in ("Makefile", os.path.join("modules", "zxPluginsInject", "Makefile")):
        m = TARGET_RE.search(read(rel))
        checks.append((rel.replace(os.sep, "/"), "TARGET", m.group(1) if m else None))

    m = CONTROL_RE.search(read("control"))
    checks.append(("control", "firmware", m.group(1) if m else None))

    for rel in CYAN_FILES:
        # 命令在 workflow 里是跨行续写的，先把 "\\\n" 接回去再看
        text = re.sub(r"\\\s*\n\s*", " ", read(rel))
        versions = set()
        for mm in re.finditer(r"cyan\s+-i", text):
            mv = re.search(r"-m\s+([0-9]+\.[0-9]+)", text[mm.end():mm.end() + 400])
            if mv:
                versions.add(mv.group(1))
        checks.append((rel, "cyan -m", ",".join(sorted(versions)) if versions else None))

    expected = checks[0][2]
    print("deploy target (from root Makefile): %s" % (expected or "<missing>"))

    bad = 0
    for where, what, got in checks:
        if got is None:
            status = "MISSING"
            bad += 1
        elif got == expected:
            status = "ok"
        else:
            status = "MISMATCH"
            bad += 1
        print("  %-46s %-10s %-8s %s" % (where, what, got or "-", status))

    if bad:
        print("\n%d place(s) disagree with %s — fix them together, all six move as one."
              % (bad, expected))
        return 1
    print("\nall six places agree on iOS %s." % expected)
    return 0


if __name__ == "__main__":
    sys.exit(main())
