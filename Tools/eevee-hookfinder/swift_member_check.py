#!/usr/bin/env python3
"""Swift 静态成员/作用域粗检（本机能跑，挡掉"成员插错类型"这类编译错）。

为什么需要它 —— 2026-10-01 的 CI 实证：
  写"吸顶头让位"时，我把两个 `static` 成员和一个 `static func` 插进了
  `final class NowPlayingShellView`，而引用它们的是 `enum NowPlayingShell`。
  编译期报：

      type 'NowPlayingShell' has no member 'yieldedTintView'
      type 'NowPlayingShell' has no member 'firstTintedAncestor'

  同一批还有一条纯语法错：`guard let target = f()`，而 `f()` 返回**非 Optional**。
  这两类都**不需要编译器**就能查出来 —— 本脚本就干这个，省一次 CI。

它检查三件事：
  1. **静态成员是否存在**：`Type.member` 这种写法里，`Type` 若是本仓库声明的类型，
     那 `member` 必须在它（或它的 extension）里声明过；
  2. **`guard let x = expr` 里 expr 是不是明显非 Optional**：只查"本地声明的函数
     返回类型不带 `?`/`!`"这一种确定情形（保守，宁漏不误报）；
  3. 顺带列出**未被引用的 private/static 成员**（只提示，不判错）。

用法：
    python Tools/eevee-hookfinder/swift_member_check.py            # 扫 Sources/EeveeSpotify
    python Tools/eevee-hookfinder/swift_member_check.py <目录>
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

# Swift 关键字里能当类型名用、但显然不是我们声明的
BUILTIN_TYPES = {
    "Self", "String", "Int", "Double", "Float", "Bool", "Data", "Date", "Array",
    "Dictionary", "Set", "Optional", "Result", "Error", "URL", "UUID", "Selector",
    "NSObject", "NSString", "NSLock", "NSError", "IndexPath", "NSRange",
    "UIView", "UILabel", "UIColor", "UIFont", "UIImage", "UIButton", "UIStackView",
    "UIViewController", "UIWindow", "UIScreen", "UIScrollView", "UIVisualEffectView",
    "UIBlurEffect", "UIVisualEffect", "CALayer", "CAGradientLayer", "CATransaction",
    "Timer", "RunLoop", "DispatchQueue", "NSLayoutConstraint", "CGSize", "CGRect",
    "CGPoint", "CGFloat", "URLSession", "UserDefaults", "Bundle", "FileManager",
    "NotificationCenter", "NSNotification", "CADisplayLink", "NSTextAlignment",
    "BundleHelper", "ProcessInfo", "CFAbsoluteTime", "MainActor", "Task",
    "UIApplication", "UIScene", "UIWindowScene", "UIEvent", "UITraitCollection",
    # SwiftUI / Foundation 里那些"看起来像我们自己的类型"的 SDK 类型
    "Color", "Locale", "UIDevice", "UIScreen", "Font", "Text", "Image",
    "View", "AnyView", "Environment", "EdgeInsets", "Animation", "Binding",
    "Published", "ObservableObject", "GeometryProxy", "UnitPoint", "Angle",
    # 再补几个常被当成"我们自己的类型"的 SDK 类型
    "CharacterSet", "StringProtocol", "CodingKeys",
}

# 明知会误报的（正则认不出实现形式的）—— 写在这里，别让它们淹掉真问题。
KNOWN_FALSE_POSITIVES = {
    # 定义在 extension 里 / 用了别的声明形式，本脚本的方法正则抓不到
    ("WordByWordHost", "isVisibleOnScreen"),
    # Swift 的 `with` 写法（对 proto 消息做原地修改），不是本仓库的类型成员
    ("Lyrics", "with"),
    ("LyricsData", "with"),
    ("LyricsLine", "with"),
    ("LyricsTranslation", "with"),
    ("LyricsColors", "with"),
}

# 会被正则误判成"类型.成员"的成员名：
#   · `X.allCases` —— `CaseIterable` 的**合成**成员，源码里没有这一行；
#   · `LrclibURLState.default` —— 嵌套类型里的成员，本脚本把它们当顶层类型处理；
#   · `X.self` / `X.Type` 这类语言级写法。
SYNTHESIZED_OR_NESTED_MEMBERS = {"allCases", "default", "self", "Type", "init"}

# 局部变量名挡板：这些名字在本仓库里到处都是（循环变量、闭包参数、别处的属性），
# 同一个文件里很可能既有 `let item: Foo = …` 又有别的 `item.something`。
# 认了它们只会制造误报 —— 规则②b 宁可漏，也不要把真问题淹掉。
LOCAL_NAME_MUFFLE = {
    "item", "line", "view", "cell", "index", "value", "result", "data", "node",
    "first", "last", "element", "component", "target", "source", "current",
}

TRIVIA = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


def strip_comments_and_strings(src: str) -> str:
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


def type_body(src: str, start: int) -> str:
    """从 `start` 处开始、按花括号配平取出这个类型/扩展的完整主体。"""
    brace = src.find("{", start)
    if brace < 0:
        return ""
    depth = 0
    i = brace
    while i < len(src):
        if src[i] == "{":
            depth += 1
        elif src[i] == "}":
            depth -= 1
            if depth == 0:
                return src[brace:i + 1]
        i += 1
    return src[brace:]


DECL = re.compile(
    r"(?:^|\n)\s*(?:@\w+(?:\([^)]*\))?\s*)*"
    r"(?:(?:public|internal|private|fileprivate|open|final|static|class|override|mutating|lazy|weak|unowned)\s+)*"
    r"(?:var|let|func)\s+([A-Za-z_][A-Za-z0-9_]*)"
)

# 枚举 case 也是成员（`case foo` / `case foo = "x"` / 一行多个用逗号隔开）。
# 不认它会把 `Color.clear`、`LyricsError.noCurrentTrack` 这类**正确**的引用全判成错。
ENUM_CASE = re.compile(r"(?:^|\n)\s*case\s+([A-Za-z_][A-Za-z0-9_]*(?:\s*,\s*[A-Za-z_][A-Za-z0-9_]*)*)")

TYPE_DECL = re.compile(r"(?:class|struct|enum|extension|protocol)\s+([A-Za-z_][A-Za-z0-9_]*)")

# 第三方/生成代码目录：不是我们写的，误报只会淹掉真问题。
SKIP_DIR_PARTS = (
    "/Dependencies/",
    "/vendor/",
    "/Generated/",
    "Protobuf/",          # protoc 生成的
    "EeveeSwiftProtobuf",
)


def members_of(body: str) -> set[str]:
    names = set(DECL.findall(body))
    for m in ENUM_CASE.finditer(body):
        for part in m.group(1).split(","):
            name = part.strip()
            if TRIVIA.match(name):
                names.add(name)
    return names


def main(argv: list[str]) -> int:
    root = Path(argv[1]) if len(argv) > 1 else Path("Sources/EeveeSpotify")
    files = [
        f for f in sorted(root.rglob("*.swift"))
        if not any(part in str(f).replace("\\", "/") for part in SKIP_DIR_PARTS)
    ]
    if not files:
        print(f"没找到 Swift 文件：{root}")
        return 2

    # 建立"类型 → 成员集合"（含 extension）
    members: dict[str, set[str]] = {}
    declared_types: set[str] = set()
    per_file_src: dict[Path, str] = {}

    for f in files:
        src = strip_comments_and_strings(f.read_text(encoding="utf-8", errors="replace"))
        per_file_src[f] = src
        for m in TYPE_DECL.finditer(src):
            name = m.group(1)
            declared_types.add(name)
            members.setdefault(name, set()).update(members_of(type_body(src, m.start())))

    problems: list[str] = []

    # ① 静态成员引用：Type.member
    for f, src in per_file_src.items():
        for m in re.finditer(r"\b([A-Z][A-Za-z0-9_]*)\.([a-z_][A-Za-z0-9_]*)\b", src):
            type_name, member = m.group(1), m.group(2)
            if type_name in BUILTIN_TYPES or type_name not in declared_types:
                continue
            if type_name not in members:
                continue
            known = members[type_name]
            if not known:
                continue
            if member not in known and member not in SYNTHESIZED_OR_NESTED_MEMBERS:
                if (type_name, member) in KNOWN_FALSE_POSITIVES:
                    continue
                line = src[:m.start()].count("\n") + 1
                problems.append(
                    f"{f}:{line}: `{type_name}.{member}` —— 类型 `{type_name}` 里没有这个成员"
                    "（这类错编译期报 no member，通常是成员插错了作用域）"
                )

    # ②b 局部变量上的成员：`let flag: KnownFlag = …` 之后写 `flag.id`
    #
    # 2026-10-03 加（CI 实证）：写「减少打扰」页时我写了 `flag.id` ——
    # `KnownFlag` 有 `name` / `scope` / `type` / `observedValue` / `noteKey`，
    # **没有 `id`**（有 `id` 的是 `FlagOverride`）。编译期报
    # `value of type 'KnownFlag' has no member 'id'`，同一条语句还连带
    # `the compiler is unable to type-check this expression in reasonable time`。
    # 上面那条规则（①）只认 `Type.member`，抓不到"变量.成员"。
    #
    # ⚠️ **只校验 struct / enum**（不做 class）：
    # 类的成员可能来自父类（UIKit 的 `superview` / `window` / `layer` …），
    # 本脚本看不到继承链 ⇒ 校验类必然误报（第一版就在
    # `LyricsWordByWord.x.swift` 上误报 `overlay.superview`）。struct / enum 没有继承，
    # 成员集合就是全部，所以"表里没有"= 真的没有。这条规则的价值也正在此：
    # 本仓库栽过的两次（`SPTPlayerTrack.artistTitle()`、今天的 `flag.id`）都是值/协议形态。
    #
    # 其余保守约定：只认显式标注类型的局部声明；类型必须与使用处**同文件**声明。
    value_types: set[str] = set()
    for f, src in per_file_src.items():
        for m in re.finditer(r"\b(?:struct|enum)\s+([A-Za-z_][A-Za-z0-9_]*)", src):
            value_types.add(m.group(1))

    for f, src in per_file_src.items():
        local_decls: dict[str, str] = {}
        for m in re.finditer(
            r"\b(?:let|var)\s+([a-z_][A-Za-z0-9_]*)\s*:\s*([A-Z][A-Za-z0-9_]*)\b", src
        ):
            var, type_name = m.group(1), m.group(2)
            if var in LOCAL_NAME_MUFFLE:
                continue
            if type_name not in value_types:
                continue
            # 类型必须在本文件里声明过，否则成员表可能不全（跨文件的 extension）。
            if not re.search(r"\b(?:struct|enum)\s+" + re.escape(type_name) + r"\b", src):
                continue
            local_decls[var] = type_name

        for var, type_name in local_decls.items():
            known = members.get(type_name, set())
            if not known:
                continue
            for m in re.finditer(r"\b" + re.escape(var) + r"\.([a-z_][A-Za-z0-9_]*)\b", src):
                member = m.group(1)
                if member in known or member in SYNTHESIZED_OR_NESTED_MEMBERS:
                    continue
                line = src[:m.start()].count("\n") + 1
                problems.append(
                    f"{f}:{line}: `{var}.{member}` —— `{var}` 是 `{type_name}`（struct/enum），"
                    f"该类型里没有 `{member}`（编译期报 has no member）"
                )

    # ② guard let 绑非 Optional（只查本地函数返回类型确定不带 ? 的情形）
    for f, src in per_file_src.items():
        non_optional_funcs: set[str] = set()
        for m in re.finditer(r"func\s+([A-Za-z_][A-Za-z0-9_]*)\s*\([^)]*\)\s*(?:->\s*([^{]+))?\{", src):
            name, ret = m.group(1), m.group(2)
            if ret and "?" not in ret and "!" not in ret:
                non_optional_funcs.add(name)

        for m in re.finditer(r"guard\s+let\s+\w+\s*=\s*([A-Za-z_][A-Za-z0-9_]*)\s*\(", src):
            called = m.group(1)
            if called in non_optional_funcs:
                line = src[:m.start()].count("\n") + 1
                problems.append(
                    f"{f}:{line}: `guard let … = {called}(…)` —— 该函数返回类型不带 `?`，"
                    "不是 Optional，不能这样绑（编译期报 conditional binding）"
                )

    # ② 裸引用的 `static` 成员（少写类型前缀）—— **故意没做**。
    #
    # 2026-10-01 试过两版，全部失败：从"整个类型体里找名字"（误报 246 条）收紧到
    # "只在函数体里、且本函数没声明过"（仍误报 110 条）—— `label` / `name` / `key` /
    # `session` / `time` 这些**局部变量、参数、闭包捕获**和别处的 static 同名太常见，
    # 纯正则分不出"裸用成员"和"就是个局部变量"。要真判对得做作用域分析，不值得。
    #
    # 记在最前面那句 total 里：这条**只靠人来守**（搬代码时，新位置引用的每个
    # `static` 名字都补全类型前缀）。

    if problems:
        # 去重（同一处可能被两条规则各命中一次）
        seen = set()
        uniq = []
        for p in problems:
            if p in seen:
                continue
            seen.add(p)
            uniq.append(p)
        print(f"发现 {len(uniq)} 处问题：")
        for p in uniq:
            print("  " + p)
        return 1

    print(f"OK：{len(files)} 个文件，静态成员引用与 guard-let 形态未发现问题")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
