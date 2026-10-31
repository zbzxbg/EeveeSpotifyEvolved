"""`swift_member_check.py` 的假阳性回归。

两种写法是**绑定**而不是引用，必须不报：

  · 带返回类型的闭包参数：`items.map { candidate -> Int in … }`
  · `case` 模式里的绑定：`case let (.left(existing?), .right(candidate?))`

同时，真·跨文件裸引用（另一个文件里的 `private static` 名字）必须照旧报出来 ——
否则这条 guard 会开始吞真问题。

不需要 Swift 工具链：把夹具写进临时目录，对检查脚本跑一次，看它的退出码与输出。
"""

import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
CHECKER = ROOT / "Tools" / "eevee-hookfinder" / "swift_member_check.py"

FIXTURES = {
    # 声明方：`alphaName` 是本文件里的 private static。
    "holder.swift": """enum Holder {
    private static let alphaName = 1
    func f() { _ = alphaName }
}
""",
    # 绑定方 ①：带返回类型的闭包参数。
    "closure_param.swift": """func g(_ items: [Int]) {
    let mapped = items.map { alphaName -> Int in alphaName + 1 }
    _ = mapped
}
""",
    # 绑定方 ②：`case let` 模式绑定。
    "case_binding.swift": """enum Pair { case left(Int?), right(Int?) }
func h(_ x: Pair, _ y: Pair) {
    switch (x, y) {
    case let (.left(existing?), .right(alphaName?)):
        _ = alphaName + existing!
    default:
        break
    }
}
""",
    # 真问题：另一个文件里裸引用那个 private static 名字。
    "real_reference.swift": """func k(_ n: Int) {
    let value = alphaName + n
    _ = value
}
""",
}


def main() -> int:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        for name, source in FIXTURES.items():
            (root / name).write_text(source, encoding="utf-8")
        done = subprocess.run(
            [sys.executable, str(CHECKER), str(root)],
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
        )

    output = done.stdout or ""
    failures = []

    if done.returncode != 1:
        failures.append(f"期望报出 1 处真问题（退出码 1），实际退出码 {done.returncode}")
    if "real_reference.swift:2" not in output:
        failures.append("真·跨文件裸引用没有被报出来（real_reference.swift:2）")
    for leaked in ("closure_param.swift", "case_binding.swift", "holder.swift"):
        if leaked in output:
            failures.append(f"绑定的写法被误报：{leaked}")

    if failures:
        print("\n".join(f"FAIL: {line}" for line in failures))
        print("--- checker stdout ---")
        print(output)
        print("--- checker stderr ---")
        print(done.stderr or "")
        return 1

    print("OK：闭包参数（带返回类型）与 case 绑定不再误报，真·跨文件裸引用仍然报出")
    return 0


if __name__ == "__main__":
    sys.exit(main())
