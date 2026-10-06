import Foundation

/// 热路径成本计量：按"每 N 次报一次"的节奏写一行调试日志（N 指数增长，不刷屏）。
///
/// 移植自上游 `Shared/Helpers/PerfMeter.swift`（32 行），只把日志出口换成本仓库的
/// `writeDebugLog`（自带脱敏，且只在「启用日志记录」打开时才写）。
///
/// 用途与纪律：
///   · 只给**每帧 / 每次布局都会跑到**的路径用（听歌页卡片判定、玻璃复查那一类）——
///     那些地方不能每次调用都写日志，否则日志本身就变成开销；
///   · 报的是**累计**耗时与平均值：单次测量在手机上噪声太大，没有参考价值；
///   · 用 `mach_absolute_time()`（单调时钟，不受系统时间调整影响）。
///
/// ⚠️ 不是线程安全的：`measure` 会改内部计数。只从主线程（布局/交互）调用。
final class PerfMeter {

    private let tag: String
    private var passes = 0
    private var ticks: UInt64 = 0
    /// 下一次报告的次数门槛（每次报告后 ×4 ⇒ 50 / 200 / 800 …）。
    private var nextReport = 50

    private static let msPerTick: Double = {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return Double(timebase.numer) / Double(timebase.denom) / 1_000_000
    }()

    init(_ tag: String) {
        self.tag = tag
    }

    @discardableResult
    func measure<T>(_ body: () -> T) -> T {
        let start = mach_absolute_time()
        let result = body()
        ticks &+= mach_absolute_time() &- start
        passes += 1

        if passes == nextReport {
            nextReport *= 4
            let total = Double(ticks) * Self.msPerTick
            writeDebugLog(String(
                format: "[Perf][%@] %d passes, %.2f ms total, %.3f ms avg",
                tag, passes, total, total / Double(passes)
            ))
        }
        return result
    }
}
