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

它检查四件事：
  1. **静态成员是否存在**：`Type.member` 这种写法里，`Type` 若是本仓库声明的类型，
     那 `member` 必须在它（或它的 extension）里声明过；
  2. **`guard let x = expr` 里 expr 是不是明显非 Optional**：只查"本地声明的函数
     返回类型不带 `?`/`!`"这一种确定情形（保守，宁漏不误报）；
  3. 顺带列出**未被引用的 private/static 成员**（只提示，不判错）；
  4. ★ 2026-10-11 新增：**`UIControl` 专有方法被调在 `UIView` 类型的变量上**
     （CI 实证：`value of type 'UIView' has no member 'sendActions'` +
     `cannot infer contextual base in reference to member 'touchUpInside'`）。
     它会把"声明成 `UIView` 的名字"顺着 `guard let a = b` 这类**纯标识符赋值**传播两三跳，
     再看这些名字头上有没有 `sendActions` / `addTarget` / `removeTarget`；
     `… as? UIControl` 那种写法**不会**被算进来（那正是修好之后的样子）。

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

# 规则 ③ 用的挡板：这些名字在我们自己的 `private static` 里出现纯属巧合（SDK / 语言级 / 太泛）。
SWIFT_KEYWORDS = {
    "self", "Self", "super", "init", "deinit", "true", "false", "nil", "new", "old",
    "result", "value", "count", "size", "frame", "bounds", "center", "alpha", "hidden",
    "tag", "text", "image", "color", "title", "name", "key", "data", "index", "type",
    "first", "last", "next", "previous", "current", "empty", "isEmpty", "description",
    "isEnabled", "isHidden", "isSelected", "isHighlighted", "state", "window", "layer",
    "target", "action", "duration", "delay", "options", "completion", "handler",
    "interval", "timeout", "limit", "max", "min", "width", "height", "x", "y", "z",
}


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

    # ③ 裸引用"**别的文件**里的 private static 成员" —— 2026-10-11 加（CI 实证）。
    #
    # 实证：`DeclutterChrome.x.swift` 里写了 `visited < maxNodes`，而那个文件里的常量叫
    # `maxScanNodes` —— `maxNodes` 是**另外五个文件各自的 private static**（800 / 2000 / 400）。
    # 编译期报 `error: cannot find 'maxNodes' in scope`。
    #
    # 这一条是上面那段"裸引用 static **故意不做**"里**唯一能判准**的一种：
    # 那名字在别的文件里是 `private`（文件级可见性），所以从本文件裸引用它
    # **永远不可能**解析成功 —— 不是"可能错"，是**必然错**。
    #
    # 保守约定（当年那两版之所以误报 246 / 110 条，是因为把局部变量也算进来了）：
    #   · 只查"仓库里确实有人用 `private` / `fileprivate` 声明过"的名字（我们自己的常量风格）；
    #   · 本文件里**声明过 / 当参数或局部标注用过**同名标识符 ⇒ 整份文件跳过；
    #   · 仓库里只要有**顶层（非 private）**同名声明 ⇒ 跳过（那才是合法的跨文件引用）；
    #   · 同一个名字最多报 3 处。
    private_names_by_file: dict[Path, set[str]] = {}
    global_names: set[str] = set()

    for f, src in per_file_src.items():
        privates: set[str] = set()
        for m in re.finditer(
            r"(?:^|\n)([ \t]*)((?:@\w+(?:\([^)]*\))?\s*)*"
            r"(?:(?:public|internal|private|fileprivate|open|final|static|class|override|mutating|lazy|weak|unowned)\s+)*"
            r"(?:var|let|func)\s+([A-Za-z_][A-Za-z0-9_]*))",
            src,
        ):
            indent, decl_line, name = m.group(1), m.group(2), m.group(3)
            if "private" in decl_line or "fileprivate" in decl_line:
                privates.add(name)
            elif indent == "":
                # 顶层（没有缩进）= 全局，别的文件可以合法裸引用。
                global_names.add(name)
        private_names_by_file[f] = privates

    candidate_names = set().union(*private_names_by_file.values()) - global_names
    candidate_names -= SWIFT_KEYWORDS
    candidate_names -= {"newValue", "oldValue"}   # 隐式 setter 参数，不是常量
    #
    # ⚠️ 性能：第一版是"每个候选名 × 每个文件"都跑几条全文件正则 —— 仓库里有上千个
    #    private 名字、三百多个文件 ⇒ 上百万次扫描，**脚本直接跑不完**（2026-10-11 实测）。
    #    改成：每个文件先做**一次**标识符扫描，取交集；再为这个文件拼**一条** alternation
    #    正则扫一遍。
    for f, src in per_file_src.items():
        present = set(re.findall(r"[A-Za-z_][A-Za-z0-9_]*", src))
        suspects = sorted((candidate_names & present) - private_names_by_file[f])
        if not suspects:
            continue

        live: list[str] = []
        for name in suspects:
            # 本文件声明过 / 当参数或标注用过 ⇒ 极可能是个局部名字，跳过（宁可漏，不误报）。
            if re.search(r"\b(?:let|var|func|case|class|struct|enum|protocol|typealias)\s+"
                         + re.escape(name) + r"\b", src):
                continue
            if re.search(r"\b" + re.escape(name) + r"\s*[:=]", src):
                continue
            # 本文件里**绑过这个名字**（闭包参数 / for 模式）⇒ 跳过。
            # 纯正则分不出"这一处是绑定、那一处是值"，而误报会淹掉真问题（仓库老规矩：宁可漏）。
            if re.search(r"\{\s*" + re.escape(name) + r"\s+in\b", src):
                continue
            if re.search(r"\bfor\s*\(?[^)\n]*\b" + re.escape(name) + r"\b[^)\n]*\)?\s+in\b", src):
                continue
            live.append(name)

        if not live:
            continue

        pattern = re.compile(
            r"(?<![\w.])(?P<name>" + "|".join(re.escape(n) for n in live) + r")(?![\w])"
        )
        per_name_hits: dict[str, int] = {}
        for m in pattern.finditer(src):
            name = m.group("name")
            if per_name_hits.get(name, 0) >= 3:
                continue
            # ⚠️ **只认"值位置"的用法**（第一版就是在这里误报 17 条的，全部是别的形态）：
            #   · 闭包 / for 的绑定名 —— `map { content in` / `for (className, …) in`；
            #   · 调用的方法名 —— `contains(where:` / `setupBindings()`；
            #   · 成员访问 —— `titleLabel?.font`。
            # 这些后面紧跟的字符分别是 `in` / `(` `.` `?` `,` `)`，而**常量**在值位置上
            # 后面跟的是 `{`、换行… ⇒ 用"后一个字符"作判据：命中的一律跳过。
            # 代价是 `min(a, maxNodes)` 这种也会漏 —— 按本仓库那条老规矩：宁可漏，不可误报。
            tail = src[m.end():m.end() + 12].lstrip()
            if tail[:2] == "in" and (len(tail) == 2 or not tail[2].isalnum()):
                continue
            if tail[:1] in ("(", ".", "?", ":", ",", ")", "!", "=", "[", '"', "'"):
                continue
            line = src[:m.start()].count("\n") + 1
            problems.append(
                f"{f}:{line}: 裸引用了 `{name}` —— 这个名字在本仓库里只有 "
                "`private` / `fileprivate` 声明（可能在别的文件里），从本文件引用解析不到"
                "（编译期报 cannot find in scope）。要么补类型前缀，要么用本文件自己的那个名字"
            )
            per_name_hits[name] = per_name_hits.get(name, 0) + 1

    # ② 裸引用的 `static` 成员（少写类型前缀）—— **其余情形仍然故意不做**。
    #
    # 2026-10-01 试过两版，全部失败：从"整个类型体里找名字"（误报 246 条）收紧到
    # "只在函数体里、且本函数没声明过"（仍误报 110 条）—— `label` / `name` / `key` /
    # `session` / `time` 这些**局部变量、参数、闭包捕获**和别处的 static 同名太常见，
    # 纯正则分不出"裸用成员"和"就是个局部变量"。要真判对得做作用域分析，不值得。
    # 上面那条 ③ 只做**能判准**的那一小块（跨文件 + private ⇒ 必然错）。

    # ④ `UIControl` 专有的方法被调在 `UIView` 类型的变量上 —— **必然编译错**（本机就能挡）。
    #
    # 2026-10-11 的 CI 实证（`NowPlayingLyricsPlate.relayShareTap`）：
    #
    #     private static weak var bandShareButton: UIView?
    #     …
    #     guard let button = bandShareButton else { return }
    #     button.sendActions(for: .touchUpInside)
    #
    #   ⇒ `value of type 'UIView' has no member 'sendActions'`
    #     + `cannot infer contextual base in reference to member 'touchUpInside'`（后一条是连锁）。
    #
    # 判据（**只做能判准的那一小块**，宁可漏、不误报 —— 与上面几条同一条纪律）：
    #   · 先收集"声明成 `UIView`（含 `UIView?` / `weak var`）"的名字；
    #   · 再顺着 `guard let a = b` / `let a = b` 这种**纯标识符赋值**把类型传播两三跳
    #     —— 注意 `guard let a = b as? UIControl` 的右边**不是**裸标识符，所以**不会**被算进来
    #     （那正是修好之后的写法）；
    #   · 同一个文件里这个名字还当过 `UIControl` 的声明/参数 ⇒ 整名跳过（同名遮蔽那一类误报）。
    CONTROL_ONLY_METHODS = ("sendActions", "addTarget", "removeTarget")
    for f, src in per_file_src.items():
        view_names = set(re.findall(
            r"\b(?:let|var)\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*UIView\??(?![\w.])", src))
        view_names = {n for n in view_names
                      if not re.search(r"\b" + re.escape(n) + r"\s*:\s*UIControl", src)}
        if not view_names:
            continue

        for _ in range(3):
            for lhs, rhs in re.findall(
                r"\b(?:let|var)\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*"
                r"([A-Za-z_][A-Za-z0-9_]*)\s*(?:else|\n|$|\{)", src):
                if rhs in view_names:
                    view_names.add(lhs)

        for name in sorted(view_names):
            for method in CONTROL_ONLY_METHODS:
                for m in re.finditer(
                    r"(?<![\w.])" + re.escape(name) + r"\??\s*\.\s*" + method + r"\s*\(", src
                ):
                    line = src[:m.start()].count("\n") + 1
                    problems.append(
                        f"{f}:{line}: `{name}.{method}(…)` —— `{name}` 是 `UIView` 类型，"
                        f"而 `{method}` 是 `UIControl` 的方法（编译期报 has no member）。"
                        "先用 `x as? UIControl` 接一下再调"
                    )

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
