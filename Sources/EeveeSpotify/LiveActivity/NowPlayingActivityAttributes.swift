import ActivityKit
import Foundation

/// 「实时活动」的共享契约：**WidgetKit 扩展与主 App 都编这一份文件**（`Scripts/build-live-activity-appex.sh`
/// 直接把同一个源文件喂给两个编译目标）。所以它是两者之间唯一的类型边界 —— 只放**两边都要看**的东西。
///
/// 约束（ActivityKit 自己的规矩，踩了就是运行期报错或卡片不刷新）：
/// · `ContentState` 必须 `Codable` + `Hashable`；整个 payload 上限 4KB，所以这里**不放图**、
///   不放歌词，只放"画一条进度条和两行字"需要的最小字段；
/// · 进度**不要靠高频 update 刷**：`startedAt + duration` 交给 Widget 的 `Text(timerInterval:)`
///   自己走，App 只在换歌 / 播放暂停时更新一次；
/// · 字段改名等于协议变更：旧的活动实例解码会失败，换字段时要把版本号带上或直接结束旧活动。
struct NowPlayingActivityAttributes: ActivityAttributes {

    struct ContentState: Codable, Hashable {
        var title: String
        var artist: String
        var isPlaying: Bool
        /// 这一首的起始时刻（`now - elapsed`）。暂停时仍保留，恢复播放时 App 会重算一次。
        var startedAt: Date
        /// 这一首的总时长（秒）。0 = 时长未知，Widget 就只画一个静止的进度点。
        var duration: Double
    }

    /// 曲目 id：只用来判断"是不是同一首"，不参与渲染。
    var trackId: String
}
