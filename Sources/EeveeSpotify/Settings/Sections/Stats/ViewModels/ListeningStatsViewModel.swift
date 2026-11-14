import Combine
import Foundation

/// 「听歌统计」页的数据侧。
///
/// 只做三件事：从 store 读一份快照、在**后台队列**上算聚合、回到主线程发布。
/// 视图的 `body` 里只读算好的 `summary` / `dailyTotals` —— 聚合不能出现在渲染路径上
/// （`days` 里的记录会随听歌不断变多，塞进 body 会让滚动掉帧）。
final class ListeningStatsViewModel: ObservableObject {

    /// 当前时间范围的聚合结果。
    @Published private(set) var summary: ListeningStatsSummary = .empty

    /// 近 7 天逐日总秒数（柱子）。
    @Published private(set) var dailyTotals: [ListeningStatsDayTotal] = []

    @Published private(set) var isLoading = false

    private let store: ListeningStatsStore
    private let aggregationQueue = DispatchQueue(
        label: "com.eevee.listening-stats.aggregate",
        qos: .userInitiated
    )

    /// 当前选中的时间范围。清除后要按同一范围重读。
    private var period: ListeningStatsPeriod = .week

    /// 只认最后一次请求的结果：快速连点时间范围时，先发出的那次可能后回来。
    private var requestGeneration = 0

    init(store: ListeningStatsStore = .shared) {
        self.store = store
    }

    func reload(period: ListeningStatsPeriod) {
        self.period = period
        requestGeneration &+= 1
        let generation = requestGeneration
        let now = Date()
        let calendar = Calendar.current
        let queue = aggregationQueue

        isLoading = true

        store.snapshot { [weak self] data in
            queue.async {
                let summary = data.summary(period: period, now: now, calendar: calendar)
                let dailyTotals = data.dailyTotals(now: now, calendar: calendar)

                DispatchQueue.main.async {
                    guard let self, self.requestGeneration == generation else { return }
                    self.summary = summary
                    self.dailyTotals = dailyTotals
                    self.isLoading = false
                }
            }
        }
    }

    /// 清除全部统计（文件 + 内存），然后按当前范围重读。
    func clear() {
        store.clear { [weak self] in
            guard let self else { return }
            self.summary = .empty
            self.dailyTotals = []
            self.reload(period: self.period)
        }
    }
}
