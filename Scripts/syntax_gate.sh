#!/usr/bin/env bash
# 语法门：对每个 Swift 源文件单独跑 `swiftc -parse`（只做语法分析、**不解析 import**），
# 所以带 UIKit / Orion 的视图文件也能过一遍 —— 那批文件在本机（Windows）永远编不了，
# 这里是它们唯一的自动反馈。
#
# 为什么单独成脚本：原来是 `tests.yml` 里一段 while 循环，**串行** spawn 500 次
# `swiftc`，是那条工作流里最大的一段固定开销（每个进程启动 + 解析 ≈ 0.3–1s）。
# 这里改成按批并行（批大小 = CPU 数），语义保持一模一样：
#   · **逐个文件**跑 —— 一个文件的错不会掩盖别的，输出里直接写明是哪个文件；
#   · 失败明细逐条打印（`---- PARSE FAIL: <path>` + 前 6 行）；
#   · 末尾 `total > 200` 是**防空跑**：`find` 要是因为路径写错返回空集，
#     这个脚本会"全过"（`fails` 恒为 0）—— 那种绿比红还坏。
#
# 用法：Scripts/syntax_gate.sh [扫描根目录…]（默认 `Sources Tests`）
# 退出码：0 = 全过；1 = 有解析失败或扫描到 0 个文件。
#
# ⚠️ 只用 bash 3.2 也支持的语法（macOS 自带的 /bin/bash 就是 3.2）：
#    没有 `wait -n`、没有关联数组；并行用"分批 + 整批 wait"实现。

set -uo pipefail

ROOTS=("$@")
if [ "${#ROOTS[@]}" -eq 0 ]; then
    ROOTS=(Sources Tests)
fi

JOBS=$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)
case "$JOBS" in
    ''|*[!0-9]*) JOBS=4 ;;
esac
[ "$JOBS" -ge 1 ] || JOBS=1

TMP=$(mktemp -d "${TMPDIR:-/tmp}/syntax-gate.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

FILES=()
while IFS= read -r -d '' f; do
    FILES+=("$f")
done < <(find "${ROOTS[@]}" -name '*.swift' -print0 2>/dev/null)

TOTAL=${#FILES[@]}
if [ "$TOTAL" -eq 0 ]; then
    echo "::error::no Swift files found under: ${ROOTS[*]} — refusing to report a green run"
    exit 1
fi

echo "syntax gate: $TOTAL file(s), $JOBS in parallel"

FAILS=0
INDEX=0
while [ "$INDEX" -lt "$TOTAL" ]; do
    BATCH=("${FILES[@]:$INDEX:$JOBS}")
    SLOT=0
    for f in "${BATCH[@]}"; do
        (
            if swiftc -parse -suppress-warnings "$f" > "$TMP/$SLOT.out" 2>&1; then
                :
            else
                printf '%s' "$f" > "$TMP/$SLOT.fail"
            fi
        ) &
        SLOT=$((SLOT + 1))
    done
    wait
    SLOT=0
    for f in "${BATCH[@]}"; do
        if [ -f "$TMP/$SLOT.fail" ]; then
            FAILS=$((FAILS + 1))
            echo "---- PARSE FAIL: $(cat "$TMP/$SLOT.fail")"
            head -6 "$TMP/$SLOT.out"
        fi
        # 槽位跨批复用 ⇒ 每批读完必须清掉标记，否则上一批的失败会被算到下一批头上。
        rm -f "$TMP/$SLOT.fail" "$TMP/$SLOT.out"
        SLOT=$((SLOT + 1))
    done
    INDEX=$((INDEX + JOBS))
done

echo "parsed $TOTAL file(s), failures: $FAILS"

# 防空跑：真跑过一轮的话文件数远超 200。
# `MIN_FILES` 只是给"验证这个脚本自己"用的（拿几个假文件跑控制流），CI 里不要设。
MIN_FILES="${MIN_FILES:-200}"
[ "$TOTAL" -gt "$MIN_FILES" ] || { echo "::error::only $TOTAL file(s) scanned (threshold $MIN_FILES) — the find pattern is probably wrong"; exit 1; }
[ "$FAILS" -eq 0 ]
