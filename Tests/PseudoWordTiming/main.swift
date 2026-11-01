import Foundation

/// `PseudoWordTiming` 的断言程序（纯逻辑，CI 跑；见 `.github/workflows/tests.yml`）。
///
/// 为什么必须钉这一份：伪逐字是**在编时间**（行内分布是估的），它的三条不变量一旦破掉，
/// 表现是"填充前沿整体漂移 / 空格处卡顿 / 填到下一句已经开口" —— 全是肉眼难定位的那种。
/// 而本机（Windows）没有 Swift 工具链，这里就是它唯一的自动判据。
///
/// 三条不变量：
/// ① 拼回来的文本必须**逐字等于**原行（渲染层按字符下标记时）；
/// ② 第一片从行起点开始，最后一片**不越过下一行**，且总时长不超过估算值；
/// ③ 空格不占时间，但**必须留在列表里**（否则后面的字符下标前移）。

var failures = 0

func require(_ condition: Bool, _ message: String) {
    if condition {
        print("  ok   \(message)")
    } else {
        failures += 1
        print("  FAIL \(message)")
    }
}

let epsilon = 0.0001

// MARK: - ① 文本逐字相等

let japanese = "沈むように溶けてゆくように"
let japanesePieces = PseudoWordTiming.pieces(for: japanese, startTime: 10, nextStartTime: 20)
require(japanesePieces.map(\.text).joined() == japanese,
        "CJK line round-trips character for character")
require(japanesePieces.count == Array(japanese).count,
        "one piece per character")

let latin = "hello big world"
let latinPieces = PseudoWordTiming.pieces(for: latin, startTime: 0, nextStartTime: 30)
require(latinPieces.map(\.text).joined() == latin,
        "latin line with spaces round-trips too")
require(latinPieces.count == Array(latin).count,
        "spaces still get a piece (index alignment)")

// MARK: - ② 时间：起点对齐、不越过下一行、不超估算

if let first = japanesePieces.first, let last = japanesePieces.last {
    require(abs(first.startTime - 10) < epsilon, "first piece starts at the line's real start")
    require(last.endTime <= 20 + epsilon, "fill ends before the next line starts")

    let estimate = LyricVocalDurationEstimator.estimatedDuration(for: japanese)
    let fill = (last.endTime - first.startTime)
    require(fill <= estimate + epsilon, "fill never exceeds the vocal estimate")
    require(abs(fill - min(estimate, 10)) < epsilon,
            "fill uses min(estimate, time to the next line)")

    // 单调不减：填充前沿只能往前走。
    var monotonic = true
    var previous = first.startTime
    for piece in japanesePieces {
        if piece.startTime < previous - epsilon || piece.endTime < piece.startTime - epsilon {
            monotonic = false
            break
        }
        previous = piece.startTime
    }
    require(monotonic, "piece times are monotonic")
}

// 夹取：下一行只给 1 秒，就只铺 1 秒。
let clipped = PseudoWordTiming.pieces(for: "一二三四五六七八九十", startTime: 5, nextStartTime: 6)
require(abs((clipped.last?.endTime ?? 0) - 6) < epsilon,
        "fill is clipped to the time available before the next line")

// 末行没有下一行：按估算值铺（10 个可见字 → 3.2 秒）。
let lastLine = PseudoWordTiming.pieces(for: "一二三四五六七八九十", startTime: 0, nextStartTime: nil)
require(abs((lastLine.last?.endTime ?? 0) - 3.2) < epsilon,
        "last line falls back to the vocal estimate")

// MARK: - ③ 空格不占时间，但留在列表里

let spacePieces = latinPieces.filter { $0.text == " " }
require(spacePieces.count == 2, "two spaces in \"hello big world\"")
require(spacePieces.allSatisfy { $0.startTime == $0.endTime },
        "whitespace pieces are zero-length")

// MARK: - 退化输入

require(PseudoWordTiming.pieces(for: "", startTime: 0, nextStartTime: 5).isEmpty,
        "empty text produces no pieces")
require(PseudoWordTiming.pieces(for: "   ", startTime: 0, nextStartTime: 5).isEmpty,
        "whitespace-only text produces no pieces")
require(PseudoWordTiming.pieces(for: "abc", startTime: 3, nextStartTime: 3).isEmpty,
        "a zero-length window produces no pieces")

// MARK: - 结果

if failures == 0 {
    print("PseudoWordTiming: all assertions passed")
} else {
    print("PseudoWordTiming: \(failures) assertion(s) FAILED")
    exit(1)
}
