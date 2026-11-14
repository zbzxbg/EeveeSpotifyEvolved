import Foundation

// 「听歌统计」的数据层：**纯 Foundation**，不 import UIKit / MediaPlayer / Orion。
//
// 为什么单独拆出来：`Tests/ListeningStats/main.swift` 只编这一份 + `ListeningStatsStore.swift`，
// 所以本文件里不能出现任何只在 App 进程里存在的东西（`writeDebugLog` 也不行，日志走
// `ListeningStatsLog.sink`，由应用侧接上）。
//
// 这里固定三件事：
// · 一首歌怎么编号（Spotify 曲目 id 优先，拿不到时用稳定哈希兜底）；
// · 按「本地日历日」分桶的桶键；
// · 一拍算多少秒、什么时候算一次播放 —— 这是整个功能最容易写错的地方，放在这里才能被
//   回归测试钉住。

// MARK: - 曲目标识

/// 统计里的一首歌怎么编号。
///
/// 优先用 Spotify 自带的 `trackIdentifier`（`URI` 里的曲目 id）。本地文件 / 播客片段等
/// 场景拿不到它，或者它暂时为空 —— 这时用「标题 + 艺人 + 时长」的 FNV-1a 哈希兜底。
///
/// ⚠️ 不能用 `String.hashValue` 兜底：那个值每个进程都不同，写进文件之后下次启动就对不上，
/// 同一首歌会被拆成两条。
enum ListeningStatsTrackKey {

    /// 兜底 hash 的前缀，一眼能看出这条 id 不是 Spotify 的曲目 id。
    static let fallbackPrefix = "fnv1a:"

    static func identifier(
        trackID: String,
        title: String,
        artist: String,
        durationSeconds: Int
    ) -> String {
        let trimmed = trackID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty else { return trimmed }

        let seed = "\(title)|\(artist)|\(durationSeconds)"
        return fallbackPrefix + String(format: "%016llx", fnv1a(seed))
    }

    /// FNV-1a 64 位。取值与实现都由测试钉住（换算法等于换 id，旧数据会断成两份）。
    static func fnv1a(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }
}

// MARK: - 日桶键

/// 「本地日历日」的桶键：`yyyy-MM-dd`。
///
/// 刻意用 `Calendar` 的 year / month / day 分量自己拼，不用 `DateFormatter` —— 后者受
/// locale 影响（同一台机器换语言就可能换个分隔符 / 换套数字），桶键一旦变，历史数据就静默
/// 分成两堆。`yyyy-MM-dd` 定宽，字典序就是时间序，所以「比截止日新」可以直接用字符串比较。
enum ListeningStatsDayKey {

    static func key(for date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func date(from key: String, calendar: Calendar = .current) -> Date? {
        let parts = key.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]) else {
            return nil
        }

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        return calendar.date(from: components)
    }

    /// 「往前 `daysBack` 天」那一天的桶键（含当天，所以 7 天窗口传 6）。
    static func cutoffKey(daysBack: Int, now: Date = Date(), calendar: Calendar = .current) -> String {
        let today = calendar.startOfDay(for: now)
        let cutoff = calendar.date(byAdding: .day, value: -max(0, daysBack), to: today) ?? today
        return key(for: cutoff, calendar: calendar)
    }
}

// MARK: - 时间范围

/// 设置页那四档时间范围。
///
/// 只用桶键比较来筛，所以「近 7 天」= 今天 + 往前 6 天（含当天），不是「最近 7×24 小时」——
/// 与统计按自然日分桶的口径一致，跨天时数字不会来回跳。
enum ListeningStatsPeriod: Int, CaseIterable, Hashable {
    case week
    case month
    case year
    case all

    /// 窗口要往前回溯多少天；`nil` = 不限。
    var daysBack: Int? {
        switch self {
        case .week: return 6
        case .month: return 29
        case .year: return 364
        case .all: return nil
        }
    }

    func cutoffKey(now: Date = Date(), calendar: Calendar = .current) -> String? {
        guard let daysBack else { return nil }
        return ListeningStatsDayKey.cutoffKey(daysBack: daysBack, now: now, calendar: calendar)
    }
}

// MARK: - 一拍的计秒规则

/// 「这一拍到底算不算在听」的判定。
///
/// 三条前提一起成立才记秒：
/// 1. 播放器自报 `rate > 0`（暂停就是 0，累计当场冻结）；
/// 2. 播放位置比上一拍前进了（位置不动 = 卡住 / 缓冲，不能算成在听）；
/// 3. 前进了多少**不超过**墙钟走过的时间太多 —— 超了就是拖了进度条，拖过去的距离不算听过。
///
/// 另外一拍最多记 3 秒：后台的定时器会被系统合并、推迟，位置差可能一次跳十几秒，
/// 不设上限的话一次卡顿就能灌进几十秒。
enum ListeningStatsPlaybackRules {

    static let maxTickSeconds: Double = 3

    /// 位置比墙钟多走了这么多秒以上 ⇒ 认定是向前拖动。
    static let seekTolerance: Double = 1.5

    /// 判定「同一首重新开始」时，位置至少往回退这么多秒。
    static let restartBacktrack: Double = 1

    /// 重新开始时位置必须落在这个范围内（拖回开头不算重新开始，那只是往回拖）。
    static let restartWindow: Double = 2

    /// 这一拍应当记入多少秒。0 表示这一拍不算在听。
    ///
    /// - Parameters:
    ///   - rate: 播放速率，0 表示暂停。
    ///   - position: 当前播放位置（秒）；读不到传 nil。
    ///   - lastPosition: 上一拍的位置；会话第一拍传 nil。
    ///   - wallSeconds: 距上一拍真实过去的时间。
    static func tickCredit(
        rate: Double,
        position: Double?,
        lastPosition: Double?,
        wallSeconds: Double
    ) -> Double {
        guard rate > 0, wallSeconds > 0 else { return 0 }

        let cappedWall = min(wallSeconds, maxTickSeconds)

        // 位置读不到时只能信墙钟：暂停已经被 rate 挡住了，不会把暂停算成在听。
        guard let position else { return cappedWall }

        // 会话第一拍只记基准点，不记秒。
        guard let lastPosition else { return 0 }

        let advanced = position - lastPosition
        guard advanced > 0 else { return 0 }
        guard advanced <= wallSeconds + seekTolerance else { return 0 }

        return min(advanced, cappedWall)
    }

    /// 同一首是否**从头又放了一遍**（单曲循环、手动重播）。
    ///
    /// 只在位置明显往回退、并且落在开头附近时才成立；从 2:00 拖回 0:40 不算重新开始。
    static func isTrackRestart(position: Double?, lastPosition: Double?) -> Bool {
        guard let position, let lastPosition else { return false }
        guard lastPosition - position >= restartBacktrack else { return false }
        return position <= restartWindow
    }
}

// MARK: - 播放次数

/// 一次曲目会话的播放计数：累计到 30 秒才算**一次**播放，之后不再计。
///
/// 计秒与会话是一个整体：不足 30 秒的那段照样要记时长，只是播放次数保持 0。
struct ListeningStatsPlayCounter: Equatable {

    static let playThresholdSeconds: Double = 30

    /// 本次会话累计的播放秒数。
    private(set) var seconds: Double = 0

    /// 本次会话是否已经记过一次播放。
    private(set) var hasCountedPlay = false

    /// 计入一段播放秒数；`true` 表示这一下刚好跨过 30 秒、应当记一次播放。
    @discardableResult
    mutating func add(_ delta: Double) -> Bool {
        guard delta > 0 else { return false }

        seconds += delta
        guard !hasCountedPlay, seconds >= Self.playThresholdSeconds else { return false }

        hasCountedPlay = true
        return true
    }
}

// MARK: - 一条记录

/// 一个桶（一天）里的一首歌。
///
/// `days` 的内层字典已经用曲目 id 作键，所以这里不再存 id —— 文件小一点。
struct ListeningStatsTrackRecord: Codable, Equatable {
    var title: String
    var artist: String
    var durationSeconds: Int
    var artworkURL: String?
    var seconds: Double
    var plays: Int
}

/// 写进 store 的一次增量。
///
/// 录音器只把「还没落盘的那一段」交给 store，所以同一首歌的增量会被反复追加，
/// 由 `ListeningStatsData.add` 累加进当天那一条。
struct ListeningStatsEntry: Equatable {
    var dayKey: String
    var trackID: String
    var title: String
    var artist: String
    var durationSeconds: Int
    var artworkURL: String?
    var seconds: Double
    var plays: Int
}

// MARK: - 汇总结果

struct ListeningStatsTrackStat: Equatable, Identifiable {
    var trackID: String
    var title: String
    var artist: String
    var durationSeconds: Int
    var artworkURL: String?
    var seconds: Double
    var plays: Int

    var id: String { trackID }
}

struct ListeningStatsArtistStat: Equatable, Identifiable {
    var name: String
    var seconds: Double
    var plays: Int

    var id: String { name }
}

struct ListeningStatsSummary: Equatable {
    var totalSeconds: Double = 0
    var totalPlays: Int = 0
    var uniqueTracks: Int = 0
    var uniqueArtists: Int = 0
    var topTracks: [ListeningStatsTrackStat] = []
    var topArtists: [ListeningStatsArtistStat] = []

    static let empty = ListeningStatsSummary()

    /// 整段时间里一条记录都没有。
    var isEmpty: Bool { totalSeconds <= 0 && totalPlays == 0 }
}

/// 近 7 天柱状图的一根柱子。
struct ListeningStatsDayTotal: Equatable, Identifiable {
    /// `yyyy-MM-dd`。
    var dayKey: String
    /// 这一天的零点（本地时区）。视图用它取星期缩写。
    var date: Date
    var seconds: Double

    var id: String { dayKey }
}

// MARK: - 落盘的整体结构

/// 落盘的整份数据：`dayKey -> 曲目 id -> 那一天的记录`。
///
/// 分两层是刻意的：日桶负责「这台机器上哪一天听了多久」，聚合时再按曲目 id 合并 ——
/// 同一首歌跨天出现很多次不会把文件撑大（一天内同一首只有一条）。
struct ListeningStatsData: Codable, Equatable {

    /// 保留多少天。比「近一年」那档多留一点，免得用户切到「全部」时刚好少一截。
    static let retentionDays = 400

    var days: [String: [String: ListeningStatsTrackRecord]] = [:]

    init() {}

    // MARK: 写

    /// 把一次增量并进对应的日桶。标题 / 艺人 / 封面只会被**补全**，不会被后写的空值冲掉。
    mutating func add(_ entry: ListeningStatsEntry) {
        let seconds = max(0, entry.seconds)
        let plays = max(0, entry.plays)
        guard seconds > 0 || plays > 0 else { return }

        var dayMap = days[entry.dayKey] ?? [:]
        var record = dayMap[entry.trackID] ?? ListeningStatsTrackRecord(
            title: entry.title,
            artist: entry.artist,
            durationSeconds: entry.durationSeconds,
            artworkURL: entry.artworkURL,
            seconds: 0,
            plays: 0
        )

        if record.title.isEmpty { record.title = entry.title }
        if record.artist.isEmpty { record.artist = entry.artist }
        if record.durationSeconds <= 0 { record.durationSeconds = entry.durationSeconds }
        if record.artworkURL == nil, let url = entry.artworkURL, !url.isEmpty {
            record.artworkURL = url
        }

        record.seconds += seconds
        record.plays += plays

        dayMap[entry.trackID] = record
        days[entry.dayKey] = dayMap
    }

    /// 丢掉比 `retentionDays - 1` 天前更早的桶（写盘前调用，文件不会无限长）。
    mutating func prune(now: Date = Date(), calendar: Calendar = .current) {
        let cutoff = ListeningStatsDayKey.cutoffKey(
            daysBack: Self.retentionDays - 1,
            now: now,
            calendar: calendar
        )
        days = days.filter { $0.key >= cutoff }
    }

    // MARK: 读

    /// 按时间范围聚合。
    ///
    /// 排序规则固定为「时长降序 → 播放次数降序 → 名称升序」，这样同一份数据的榜单永远一致，
    /// 测试也才能钉住顺序。
    func summary(
        period: ListeningStatsPeriod,
        now: Date = Date(),
        calendar: Calendar = .current,
        limit: Int = 10
    ) -> ListeningStatsSummary {
        let cutoff = period.cutoffKey(now: now, calendar: calendar)

        var tracks: [String: ListeningStatsTrackStat] = [:]
        var artists: [String: ListeningStatsArtistStat] = [:]
        var totalSeconds: Double = 0
        var totalPlays = 0

        for (dayKey, dayMap) in days {
            if let cutoff, dayKey < cutoff { continue }

            for (trackID, record) in dayMap {
                totalSeconds += record.seconds
                totalPlays += record.plays

                var stat = tracks[trackID] ?? ListeningStatsTrackStat(
                    trackID: trackID,
                    title: record.title,
                    artist: record.artist,
                    durationSeconds: record.durationSeconds,
                    artworkURL: record.artworkURL,
                    seconds: 0,
                    plays: 0
                )
                stat.seconds += record.seconds
                stat.plays += record.plays
                if stat.title.isEmpty { stat.title = record.title }
                if stat.artist.isEmpty { stat.artist = record.artist }
                if stat.artworkURL == nil { stat.artworkURL = record.artworkURL }
                if stat.durationSeconds <= 0 { stat.durationSeconds = record.durationSeconds }
                tracks[trackID] = stat

                let artistName = record.artist.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !artistName.isEmpty else { continue }

                let artistKey = artistName.lowercased()
                var artist = artists[artistKey] ?? ListeningStatsArtistStat(
                    name: artistName,
                    seconds: 0,
                    plays: 0
                )
                artist.seconds += record.seconds
                artist.plays += record.plays
                artists[artistKey] = artist
            }
        }

        let topTracks = tracks.values.sorted { lhs, rhs in
            if lhs.seconds != rhs.seconds { return lhs.seconds > rhs.seconds }
            if lhs.plays != rhs.plays { return lhs.plays > rhs.plays }
            return lhs.title < rhs.title
        }

        let topArtists = artists.values.sorted { lhs, rhs in
            if lhs.seconds != rhs.seconds { return lhs.seconds > rhs.seconds }
            if lhs.plays != rhs.plays { return lhs.plays > rhs.plays }
            return lhs.name < rhs.name
        }

        return ListeningStatsSummary(
            totalSeconds: totalSeconds,
            totalPlays: totalPlays,
            uniqueTracks: tracks.count,
            uniqueArtists: artists.count,
            topTracks: Array(topTracks.prefix(max(0, limit))),
            topArtists: Array(topArtists.prefix(max(0, limit)))
        )
    }

    /// 近 `daysBack + 1` 天逐日的总秒数（**补齐空白天**，柱子不会塌成一根）。
    func dailyTotals(
        daysBack: Int = 6,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [ListeningStatsDayTotal] {
        let today = calendar.startOfDay(for: now)
        var result: [ListeningStatsDayTotal] = []
        result.reserveCapacity(daysBack + 1)

        for offset in stride(from: daysBack, through: 0, by: -1) {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            let key = ListeningStatsDayKey.key(for: date, calendar: calendar)
            let seconds = (days[key] ?? [:]).values.reduce(0) { $0 + $1.seconds }
            result.append(ListeningStatsDayTotal(dayKey: key, date: date, seconds: seconds))
        }

        return result
    }
}

// MARK: - 日志出口

/// 日志出口。
///
/// model / store 是 Foundation-only（回归测试单独编译它们，那里没有 `writeDebugLog`），
/// 所以这里只留一个闭包槽：应用侧在 `ListeningStatsRecorder.start()` 里接上
/// `writeDebugLog`，测试里保持 nil。
enum ListeningStatsLog {
    static var sink: ((String) -> Void)?

    static func write(_ message: String) {
        sink?(message)
    }
}
