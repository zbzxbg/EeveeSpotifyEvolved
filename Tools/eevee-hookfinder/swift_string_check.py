#!/usr/bin/env python3
"""swift_string_check.py —— 抓「字面量被内层 ASCII 双引号截断」这一类**只有 CI 才会炸**的错。

为什么需要它（2026-10-05 的真实事故）
────────────────────────────────────
    noteSkip("拿不到那张封面（缩略图与"藏起原生封面"都做不了）—— 不展开")

四个 ASCII 双引号 ⇒ 引号数**是偶数** ⇒ `swift_brace_check.py`（只数配平）**放行**，
但编译器一次报三处：

    expected ',' separator            （第 387 行 60 列）
    cannot find '藏起原生封面' in scope
    extra argument in call

本机没有 Swift 工具链，这类错只能等 CI —— 所以把它变成一条本机自检。

判据
────
Swift 里一个字面量的**闭合引号**后面，只允许出现：

  · 运算符 / 标点：`, ) ] } . + - * / ? : ; = < > ! & | % ~ ^ {`（以及空白）
  · 关键字：`as is in where async await else return continue break case default if for while`
    `let var guard throw throws try catch switch do repeat defer init self super true false nil`
    `some any actor class struct enum extension protocol func import typealias static final`
    `public private internal open fileprivate mutating override convenience required lazy`
    `weak unowned indirect dynamic optional nonmutating prefix postfix infix`
  · 行尾

凡不是这些的（字母、汉字、全角标点…）⇒ 那个引号就是被当成了「内层引号」——
也就是上面那个 bug。**报错退出**。

会处理：字符串插值 `\\( … )`（含嵌套字面量）、原始字符串 `#"…"#`、行注释 `//`、
        **多行字符串 `\"\"\"…\"\"\"`**（按行整段跳过，不会误报）。

用法
────
    python Tools/eevee-hookfinder/swift_string_check.py
"""
import pathlib
import re
import sys

# 多行字符串：整段跳过（里面的引号是字面内容，不适用本检查器的规则）
TRIPLE_RE = re.compile(r'"""[\s\S]*?"""')


def triple_quoted_lines(text):
    """返回被 `\"\"\"…\"\"\"` 覆盖的 1-based 行号集合。"""
    spans = set()
    for match in TRIPLE_RE.finditer(text):
        first = text.count("\n", 0, match.start()) + 1
        last = text.count("\n", 0, match.end()) + 1
        for number in range(first, last + 1):
            spans.add(number)
    return spans

# 闭合引号后面允许出现的字符
LEGAL_PUNCT = set(',)]}.+-*/?:;=<>!&|%~^{')

# 闭合引号后面允许出现的关键字（Swift）
KEYWORDS = set("""
as is in where async await else return continue break case default if for while
let var guard throw throws try catch switch do repeat defer init self super true false nil
some any actor class struct enum extension protocol func import typealias operator subscript
static final public private internal open fileprivate mutating override convenience required
lazy weak unowned indirect dynamic optional nonmutating prefix postfix infix
""".split())

WORD_RE = re.compile(r"[A-Za-z]+")

# 自查用的"已知坏行"：扫描器必须抓到它，否则说明检查器本身坏了
SELF_TEST_BAD_LINE = (
    '    noteSkip("\u62ff\u4e0d\u5230\u90a3\u5f20\u5c01\u9762\uff08\u7f29\u7565\u56fe\u4e0e"'
    '\u85cf\u8d77\u539f\u751f\u5c01\u9762"\u90fd\u505a\u4e0d\u4e86\uff09\u2014\u2014 '
    '\u4e0d\u5c55\u5f00")'
)


def scan_line(line):
    """返回 [(列号, 该行文本)]：本行里"闭合引号后面跟了非法字符"的位置。"""
    hits = []
    i, n = 0, len(line)
    mode = "code"          # code | str
    escaped = False
    interp = 0             # `\\( … )` 里的括号深度
    raw = 0                # 原始字符串的 `#` 个数（0 = 普通字面量）
    stack = []             # 从插值回到字符串时用

    while i < n:
        ch = line[i]

        if mode == "str":
            if raw:
                # 原始字符串：闭合是 `"` + raw 个 `#`
                if ch == '"' and line[i + 1:i + 1 + raw] == "#" * raw:
                    mode = "code"
                    i += 1 + raw
                    continue
                i += 1
                continue
            if escaped:
                escaped = False
            elif ch == "\\":
                if i + 1 < n and line[i + 1] == "(":
                    stack.append(("str", raw))
                    mode, interp = "code", 1
                    i += 2
                    continue
                escaped = True
            elif ch == '"':
                k = i + 1
                while k < n and line[k] in " \t":
                    k += 1
                bad = False
                if k < n:
                    nxt = line[k]
                    if nxt in LEGAL_PUNCT:
                        bad = False
                    elif nxt.isalpha():
                        word = WORD_RE.match(line[k:])
                        bad = not (word and word.group(0) in KEYWORDS)
                    else:
                        bad = True
                if bad:
                    hits.append((i + 1, line.rstrip()))
                mode = "code"
        else:
            if interp > 0:
                if ch == '"':
                    mode, escaped, raw = "str", False, 0
                elif ch == "(":
                    interp += 1
                elif ch == ")":
                    interp -= 1
                    if interp == 0:
                        mode, raw = stack.pop()
            else:
                if ch == "#":
                    j = i
                    while j < n and line[j] == "#":
                        j += 1
                    if j < n and line[j] == '"':
                        raw = j - i
                        i = j + 1
                        mode, escaped = "str", False
                        continue
                    i = j
                    continue
                if ch == '"':
                    mode, escaped, raw = "str", False, 0
                elif ch == "/" and i + 1 < n and line[i + 1] == "/":
                    break
        i += 1

    return hits


def main():
    # ── 自查：扫描器必须抓得住那次真实事故的那一行 ──
    if not scan_line(SELF_TEST_BAD_LINE):
        print("FAIL：检查器自身失效（抓不到已知的坏行）—— 别信它的结论")
        return 1

    root = pathlib.Path("Sources")
    if not root.is_dir():
        print("FAIL：在 %s 下没找到 Sources/（请在仓库根目录跑）" % pathlib.Path.cwd())
        return 1

    files = 0
    lines = 0
    hits = []
    skipped_files = []

    for path in sorted(root.rglob("*.swift")):
        # 第三方源码（XMLCoder）不归我们管
        if "Dependencies" in path.parts:
            continue
        files += 1
        text = path.read_text(encoding="utf-8", errors="replace")
        skipped = triple_quoted_lines(text)
        if skipped:
            skipped_files.append(str(path))
        for number, line in enumerate(text.splitlines(), 1):
            lines += 1
            if number in skipped:
                continue
            for column, source in scan_line(line):
                hits.append((str(path), number, column, source))

    if skipped_files:
        print("提示：%d 个文件含多行字符串 \"\"\"（按行跳过，不参与判定）" % len(skipped_files))

    if hits:
        print("FAIL：%d 处字面量的闭合引号后面跟了非法字符" % len(hits))
        print("      ——典型原因是**在字符串里又写了 ASCII 双引号**（中文强调请改用「」或单引号）")
        for path, number, column, source in hits:
            print("  %s:%d:%d" % (path, number, column))
            print("      %s" % source)
        return 1

    print("OK：%d 个文件 / %d 行：字面量闭合引号全部合法" % (files, lines))
    return 0


if __name__ == "__main__":
    sys.exit(main())
