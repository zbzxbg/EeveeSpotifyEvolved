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

        store.snapshot { data in
            // ⚠️ 外层的 snapshot 闭包**不抓 self**：它只活一个回调。会活到网络回来的那一层
            // 在下面统一 weak 抓、进门就 unwrap —— 免得嵌套 `[weak self]` 把 self 变成
            // `Self??` 那种写法。
            queue.async { [weak self] in
                guard let self else { return }

                var summary = data.summary(period: period, now: now, calendar: calendar)
                let chart = data.buckets(for: period, now: now, calendar: calendar)
                let firstDayKey = data.oldestDayKey

                // 封面：先用本地缓存补一遍（同步、零网络），缺的再去问 Web API。
                // 为什么必须在这一层补：导入的历史只带曲目 id，`artworkURL` 是 nil
                // （见 `ListeningStatsArtwork`）—— 不补就是灰底音符占位。
                summary = Self.applyingArtwork(
                    ListeningStatsArtwork.cachedURLs(for: summary.topTracks.map(\.trackID)),
                    to: summary
                )

                DispatchQueue.main.async {
                    guard self.requestGeneration == generation else { return }
                    self.summary = summary
                    self.buckets = chart.buckets
                    self.bucketUnit = chart.unit
                    self.firstDayKey = firstDayKey
                    self.isLoading = false
                }

                let missing = summary.topTracks
                    .filter { ($0.artworkURL ?? "").isEmpty }
                    .map(\.trackID)
                guard !missing.isEmpty else { return }

                // 回调在主队列（`ListeningStatsArtwork` 的契约）。令牌在这时取一次：
                // 它是 `DataLoaderServiceHooks` 从 Spotify 自己的请求里抓下来的那个。
                ListeningStatsArtwork.resolve(
                    trackIDs: missing,
                    token: spotifyAccessTokenSnapshot()
                ) { urls in
                    guard !urls.isEmpty else { return }
                    // 先写回统计文件：下次打开这一页就不需要联网了（连负缓存都不用）。
                    self.store.backfillArtwork(urls)
                    guard self.requestGeneration == generation else { return }
                    self.summary = Self.applyingArtwork(urls, to: self.summary)
                }
            }
        }
    }

    /// 把「曲目 id → 封面 URL」贴到榜单上（只补空的，不覆盖已有值）。
    private static func applyingArtwork(
        _ urls: [String: String],
        to summary: ListeningStatsSummary
    ) -> ListeningStatsSummary {
        guard !urls.isEmpty else { return summary }

        var updated = summary
        for index in updated.topTracks.indices {
            let trackID = updated.topTracks[index].trackID
            guard let url = urls[trackID] else { continue }
            guard (updated.topTracks[index].artworkURL ?? "").isEmpty else { continue }
            updated.topTracks[index].artworkURL = url
        }
        return updated
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
