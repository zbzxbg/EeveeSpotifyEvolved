import Combine
import Foundation

/// 「听歌统计」页的数据侧。
///
/// 只做三件事：从 store 读一份快照、在**后台队列**上算聚合、回到主线程发布。
/// 视图的 `body` 里只读算好的 `summary` / `buckets` —— 聚合不能出现在渲染路径上
/// （`days` 里的记录会随听歌不断变多，塞进 body 会让滚动掉帧）。
final class ListeningStatsViewModel: ObservableObject {

    /// 当前时间范围的聚合结果。
    @Published private(set) var summary: ListeningStatsSummary = .empty

    /// 当前时间范围的柱子。粒度随范围变：7/30 天按日、一年按月、全部按年。
    @Published private(set) var buckets: [ListeningStatsBucket] = []
    @Published private(set) var bucketUnit: ListeningStatsBucketUnit = .day

    /// 库里最早的一天（`yyyy-MM-dd`）；没有数据时为 nil。
    ///
    /// 页面上显示成「数据自 … 起」：30 天 / 一年 / 全部 三档在**只有最近几天数据**时
    /// 和 7 天档的数字完全一样，没有这一行就只能靠猜。
    @Published private(set) var firstDayKey: String?

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
                let chart = data.buckets(for: period, now: now, calendar: calendar)
                let firstDayKey = data.oldestDayKey

                DispatchQueue.main.async {
                    guard let self, self.requestGeneration == generation else { return }
                    self.summary = summary
                    self.buckets = chart.buckets
                    self.bucketUnit = chart.unit
                    self.firstDayKey = firstDayKey
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
            self.buckets = []
            self.reload(period: self.period)
        }
    }
}
