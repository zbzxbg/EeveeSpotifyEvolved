import Foundation

/// 歌词时间轴偏移（**所有歌词源共用**，Genius 除外）。
///
/// 第一版只做网易云（理由是 UGC 时间轴参差），后来实测 Musixmatch / LRCLIB / Petit / AMLL / Spicy 也都有整首偏半秒的情况；只给网易云开口子，用户就得先判断"这次的词是哪个源给的、它能不能调"，这层认知负担不该由用户承担 ⇒ 改成全源生效。
///
/// 记录时**必须带上歌词源**：同一首歌换一个源就是另一份时间轴（网易云的词偏 0.3s、Musixmatch 的也许正好），所以存储键是「源 + 曲目 id」而不是只按曲目：
///
/// ```
/// 生效偏移 = 该 (源, 曲目) 的覆盖 ?? 0
/// ```
///
/// 设置页每一行也要把源名画出来。
///
/// **Genius 不参与**：它的词只有行、没有可信时间轴（见 `LyricsDto.toSpotifyLyricsData` 里"不给无时间轴的源合成时间轴"那段），挪时间戳没有意义 ⇒ `offsetMs` 对 Genius 恒返回 0、`setOffset` 直接不写、设置页遇到 Genius 只显示一句说明，不给 ± 按钮。
///
/// ⚠️ 施加点在 `CustomLyrics.storeLyricsDto`（**唯一**入口）：dto 一落地就先按「这一首 + 这个源」平移，注入给 Spotify 的 payload 与两个自绘 overlay 读到的都是同一份已经平移过的数据。
/// 键名与 `UserDefaults.ownedKeys` 的登记见本文件末尾。
enum LyricsTimingOffset {

    // MARK: - 键
    //
    // `["<源>|<曲目 id>": 毫秒]` 的 JSON 文本。
    //
    // 用 String 而不是 Data，是为了让它能走设置备份的“普通 `key=value`”路径
    // （`SettingsBackup` 只对 `flagOverrides` 这一个 Data 键做特殊处理）。
    static let offsetsKey = "ngzhwm_lyricsOffsetBySourceAndTrack"
    /// `["<源>|<曲目 id>": "歌名 — 歌手"]` 的 JSON 文本。
    ///
    /// 为什么要它：设置页把**每一条保存过的偏移**列出来，而键是曲目 id —— 没有名字
    /// 的话那一列全是十六进制，没法选。只在用户改这一条的偏移时顺手记下来；
    /// 老数据没有名字就显示「未知歌曲 + 短 id」，不猜。
    static let titlesKey = "ngzhwm_lyricsOffsetTrackTitles"

    /// 之前的旧键：只有网易云，键是**裸曲目 id**。只读一次做迁移。
    private static let legacyOffsetsKey = "ngzhwm_neteaseOffsetByTrack"
    private static let legacyTitlesKey = "ngzhwm_neteaseOffsetTrackTitles"
    /// 起就不再用（「默认偏移」），迁移时顺手删掉。
    private static let legacyDefaultOffsetKey = "ngzhwm_neteaseOffsetMs"

    /// 偏移的上下限（±5s）与步进（50ms）。
    static let maxOffsetMs = 5000
    static let stepMs = 50
    /// 最多保留多少条。超过就按 key 排序丢掉最早的几条 —— 没有时间戳可排序，
    /// 但至少行为是确定的，不会悄悄无限增长。
    ///
    /// 上限从 300 提到 1000。
    /// 现在一条 = 一首歌的一个源，同样 1000 条上限（JSON 也就几十 KB）。
    static let maxTrackOverrides = 1000

    /// 备份 / 全局重置 / 本页重置要认识的键（含旧键：重置时一起清掉）。
    static var ownedKeys: [String] {
        [offsetsKey, titlesKey] + legacyOwnedKeys
    }

    /// 迁移前的网易云键。单独留给 `UserDefaults.ownedKeys` 拼接用 ——
    /// 老备份里带的是这些键，不登记它们的话「导入备份」会把那批偏移静默丢掉。
    static let legacyOwnedKeys: [String] = [
        legacyOffsetsKey,
        legacyTitlesKey,
        legacyDefaultOffsetKey,
    ]

    // MARK: - 一条记录
    //
    // 设置页那一列的一行：`(曲目, 源) → 毫秒`。
    struct Entry {
        let trackId: String
        let source: LyricsSource
        let offsetMs: Int
        /// 存储键（设置页拿它判断"是不是当前播放这首"）。
        var key: String { LyricsTimingOffset.storageKey(trackId: trackId, source: source) }
    }

    // MARK: - 内存索引
    //
    // 运行期索引：**只解一次 JSON，之后按 key 哈希查找**。
    //
    // 取词时每首歌要问 1~2 次；歌多了就是反复解析几十 KB。所以把解码结果缓存起来：
    // · 首次读 → 解码一次；
    // · 我们自己的写入 → 原地更新缓存；
    // · 外部批量改键（备份导入 / 全局重置）→ 调 `invalidateCache`。
    //
    // 锁是必须的：读发生在取词队列（后台），写发生在设置页（主线程）。
    private static let cacheLock = NSLock()
    private static var cachedOffsets: [String: Int]?
    private static var cachedTitles: [String: String]?

    /// 备份导入 / 全局重置这类"绕过本类型直接写 UserDefaults"的操作之后叫一次。
    static func invalidateCache() {
        cacheLock.lock()
        cachedOffsets = nil
        cachedTitles = nil
        cacheLock.unlock()
    }

    static var trackOffsets: [String: Int] {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cachedOffsets { return cachedOffsets }
        let loaded = loadOffsetsLocked()
        cachedOffsets = loaded
        return loaded
    }

    /// 全部已保存的偏移（设置页那一列）。
    static var entries: [Entry] {
        trackOffsets.compactMap { entry -> Entry? in
            guard let parsed = parseStorageKey(entry.key) else { return nil }
            guard supportsOffset(source: parsed.source) else { return nil }
            return Entry(
                trackId: parsed.trackId,
                source: parsed.source,
                offsetMs: clamped(entry.value)
            )
        }
    }

    /// 一条记录的显示名（见 `titlesKey`）。老数据没有这一份 ⇒ nil。
    static func title(forTrackId trackId: String, source: LyricsSource) -> String? {
        trackTitles[storageKey(trackId: trackId, source: source)]
    }

    private static var trackTitles: [String: String] {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cachedTitles { return cachedTitles }
        let loaded = loadTitlesLocked()
        cachedTitles = loaded
        return loaded
    }

    /// 读取；新键不存在而旧键在 ⇒ 就地把网易云那批迁移成新格式。
    ///
    /// ⚠️ 调用方**已经持有** `cacheLock`（所以这里只碰 `persist…Locked`，不再加锁，
    /// 否则 `NSLock` 会自锁死）。
    private static func loadOffsetsLocked() -> [String: Int] {
        let defaults = UserDefaults.standard
        if let text = defaults.string(forKey: offsetsKey),
           let data = text.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String: Int].self, from: data) {
            return decoded
        }

        guard let text = defaults.string(forKey: legacyOffsetsKey),
              let data = text.data(using: .utf8),
              let legacy = try? JSONDecoder().decode([String: Int].self, from: data),
              !legacy.isEmpty else {
            return [:]
        }

        var migrated: [String: Int] = [:]
        for entry in legacy {
            let trackId = entry.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trackId.isEmpty else { continue }
            migrated[storageKey(trackId: trackId, source: .netease)] = clamped(entry.value)
        }
        persistOffsetsLocked(migrated)
        // 迁移完就把旧键删掉：新键从此是权威，别再走这一支。
        defaults.removeObject(forKey: legacyOffsetsKey)
        defaults.removeObject(forKey: legacyDefaultOffsetKey)
        return migrated
    }

    private static func loadTitlesLocked() -> [String: String] {
        let defaults = UserDefaults.standard
        if let text = defaults.string(forKey: titlesKey),
           let data = text.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            return decoded
        }

        guard let text = defaults.string(forKey: legacyTitlesKey),
              let data = text.data(using: .utf8),
              let legacy = try? JSONDecoder().decode([String: String].self, from: data),
              !legacy.isEmpty else {
            return [:]
        }

        var migrated: [String: String] = [:]
        for entry in legacy {
            let trackId = entry.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trackId.isEmpty else { continue }
            migrated[storageKey(trackId: trackId, source: .netease)] = entry.value
        }
        persistTitlesLocked(migrated)
        defaults.removeObject(forKey: legacyTitlesKey)
        return migrated
    }

    // MARK: - 查询 / 写入
    //
    // Genius 不参与歌词偏移（见文件头）。
    static func supportsOffset(source: LyricsSource) -> Bool {
        source != .genius
    }

    /// `"<源>|<曲目 id>"`。曲目 id 里不会有 `|`，所以按第一个 `|` 拆就够。
    static func storageKey(trackId: String, source: LyricsSource) -> String {
        "\(source.offsetStorageKey)|\(trackId.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    private static func parseStorageKey(_ key: String) -> (trackId: String, source: LyricsSource)? {
        guard let separator = key.firstIndex(of: "|") else { return nil }
        let sourcePart = String(key[key.startIndex..<separator])
        let trackId = String(key[key.index(after: separator)...])
        guard !trackId.isEmpty,
              let source = LyricsSource(offsetStorageKey: sourcePart) else {
            return nil
        }
        return (trackId, source)
    }

    /// 这一首在**这个源**下实际生效的偏移（覆盖 ?? 0）。
    static func offsetMs(forTrackId trackId: String, source: LyricsSource) -> Int {
        guard supportsOffset(source: source) else { return 0 }
        let trimmed = trackId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        guard let override = trackOffsets[storageKey(trackId: trimmed, source: source)] else {
            return 0
        }
        return clamped(override)
    }

    static func hasOverride(forTrackId trackId: String, source: LyricsSource) -> Bool {
        guard supportsOffset(source: source) else { return false }
        let trimmed = trackId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return trackOffsets[storageKey(trackId: trimmed, source: source)] != nil
    }

    /// 写一条覆盖。传 0 也照样存（0 也是一个明确的“这条不偏”），
    /// 想回到默认请用 `clearOverride`。
    ///
    /// - Parameter trackTitle: 这一条的显示名（`"歌名 — 歌手"`）。只在用户改当前播放这一首时传；
    /// 设置页的"已保存列表"里改别的歌时传 `nil`，保持已存的名字（没有就是没有）。
    static func setOffset(
        _ milliseconds: Int,
        forTrackId trackId: String,
        source: LyricsSource,
        trackTitle: String? = nil
    ) {
        let trimmed = trackId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, supportsOffset(source: source) else { return }
        let key = storageKey(trackId: trimmed, source: source)

        var offsets = trackOffsets
        offsets[key] = clamped(milliseconds)
        let saved = save(offsets)

        var titles = trackTitles
        if let trackTitle {
            let name = trackTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty {
                titles.removeValue(forKey: key)
            } else {
                titles[key] = String(name.prefix(120))
            }
        }
        // 只留还在偏移表里的名字（`save` 可能刚丢掉最老的那几条）。
        saveTitles(titles.filter { saved[$0.key] != nil })
    }

    static func clearOverride(forTrackId trackId: String, source: LyricsSource) {
        let trimmed = trackId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let key = storageKey(trackId: trimmed, source: source)

        var offsets = trackOffsets
        guard offsets.removeValue(forKey: key) != nil else { return }
        save(offsets)

        var titles = trackTitles
        titles.removeValue(forKey: key)
        saveTitles(titles)
    }

    /// 清掉全部覆盖（设置页那颗「清除全部」用这个）。
    static func clearAllOverrides() {
        cacheLock.lock()
        UserDefaults.standard.removeObject(forKey: offsetsKey)
        UserDefaults.standard.removeObject(forKey: titlesKey)
        cachedOffsets = [:]
        cachedTitles = [:]
        cacheLock.unlock()
    }

    /// 完整重置/排障用：覆盖全清，并顺手清掉旧版本留下的键。
    static func clearAll() {
        UserDefaults.standard.removeObject(forKey: legacyDefaultOffsetKey)
        UserDefaults.standard.removeObject(forKey: legacyOffsetsKey)
        UserDefaults.standard.removeObject(forKey: legacyTitlesKey)
        clearAllOverrides()
    }

    // MARK: - 归一化
    //
    // 夹到 ±5s，并吸附到 50ms 的整数倍（UI 的步进就是这个粒度）。
    static func clamped(_ milliseconds: Int) -> Int {
        // 先夹范围再换算成步数：直接 `Double(milliseconds)` 在异常大的存储值上
        // 转回 Int 会溢出（本键可能被手改/导入过）。
        let bounded = min(max(milliseconds, -maxOffsetMs), maxOffsetMs)
        let steps = (Double(bounded) / Double(stepMs)).rounded()
        return min(max(Int(steps) * stepMs, -maxOffsetMs), maxOffsetMs)
    }

    // MARK: - 落盘
    //
    // ⚠️ 下面两个 `persist…Locked` 都要求**调用方已持有 `cacheLock`**。

    @discardableResult
    private static func save(_ offsets: [String: Int]) -> [String: Int] {
        cacheLock.lock()
        defer { cacheLock.unlock() }

        var offsets = offsets
        if offsets.count > maxTrackOverrides {
            let overflow = offsets.count - maxTrackOverrides
            for key in offsets.keys.sorted().prefix(overflow) {
                offsets.removeValue(forKey: key)
            }
        }

        persistOffsetsLocked(offsets)
        // 写完**直接**把缓存换掉：读歌词那一侧不需要再解码一次。
        cachedOffsets = offsets
        return offsets
    }

    private static func persistOffsetsLocked(_ offsets: [String: Int]) {
        guard let data = try? JSONEncoder().encode(offsets),
              let text = String(data: data, encoding: .utf8) else { return }
        UserDefaults.standard.set(text, forKey: offsetsKey)
    }

    /// 写"显示名"那份小字典；空字典就把键删掉（备份/重置看到的是"没有"）。
    private static func saveTitles(_ titles: [String: String]) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        cachedTitles = titles
        persistTitlesLocked(titles)
    }

    private static func persistTitlesLocked(_ titles: [String: String]) {
        guard !titles.isEmpty else {
            UserDefaults.standard.removeObject(forKey: titlesKey)
            return
        }
        guard let data = try? JSONEncoder().encode(titles),
              let text = String(data: data, encoding: .utf8) else { return }
        UserDefaults.standard.set(text, forKey: titlesKey)
    }
}
