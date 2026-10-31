import Foundation

// MARK: - 「拿一批歌词行，但最多等 N 秒」
//
// 现在只有一处用它：「SpicyLyrics 交叉验证」—— 去问未打码的源要歌词，
// 用来补回被和谐的词。之前「NetEase 交叉验证」也走这里，那个实验已整体撤掉。）
//
// 为什么必须有墙钟预算：仓库里的取词都是**同步阻塞**的，而且
// `SpicyLyricsRepository` 对 503（同步还在生成）是 `Thread.sleep` 退避重试
// （2 / 3 / 4.5 / 6.75 / 10s，最坏约 26s）。这两个功能都挂在取词热路径上，
// 不能让它们把一次正常取词拖到几十秒。
//
// 超时按"没拿到"处理，**不取消原路径**：后台那次请求会自己跑完、结果被丢弃，
// 代价是一个线程最多再忙二十几秒（这两个功能都只在少数情况下触发，可接受）。

enum LyricsLinesBudget {

    /// 跑请求的**专用并发队列**。
    ///
    /// ⚠️ 不用 `DispatchQueue.global`：调用方（`CustomLyrics`）本身就在
    /// `DispatchQueue.global(qos: .userInitiated).async` 里，而这里会在**外面**再等一个
    /// 信号量 —— 两层都占全局池的线程，多首并发时会互相挤。
    private static let queue = DispatchQueue(
        label: "eevee.lyrics.fetch-budget",
        qos: .userInitiated,
        attributes: .concurrent
    )

    /// 在 `budget` 秒内拿到歌词行；超时 / 抛错 / 空文本都返回 `nil`。
    static func lines(_ budget: TimeInterval, _ work: @escaping () throws -> [String]) -> [String]? {
        let semaphore = DispatchSemaphore(value: 0)
        let box = Box()

        queue.async {
            box.lines = try? work()
            semaphore.signal()
        }

        if semaphore.wait(timeout: .now() + budget) == .timedOut {
            return nil
        }

        guard let lines = box.lines, !lines.isEmpty else { return nil }
        return lines
    }

    /// 为什么用一个 class 装结果、而不是捕获一个 `var`：闭包在别的队列上写、这里读，
    /// 捕获列表里的 `var` 在开启严格并发检查的 Swift 版本上会被判成数据竞争。
    private final class Box {
        var lines: [String]?
    }
}
