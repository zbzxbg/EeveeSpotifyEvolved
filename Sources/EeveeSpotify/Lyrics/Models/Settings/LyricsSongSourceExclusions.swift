import Foundation

/// 「这首歌不用某些歌词源」—— 按曲目记一组被排除的源。
///
/// 与 `LyricsSourceOrder`（全局询问顺序）的分工：顺序改一次影响所有歌；这一份只作用于
/// **一首歌**。碰到的场景是"某首的 QQ / 酷狗 落成了翻唱版"或"某个源的词跟这一首对不上" ——
/// 为了它去调全局顺序，会把其它歌一起改坏。
///
/// 生效点只有一处：`CustomLyrics.autoSelectLyrics` 建链之后。**只对自动优先生效**：
/// 用户自己点名选了某个源时，点名优先于排除（那是显式选择，不是"随便挑一个"）。
///
/// 存储：
/// - `lyricsSongSourceExclusions`：`{"<曲目 id>": ["qqmusic", "kugou"]}` 的 JSON 文本。
///   用 String 而不是 Data，是为了走设置备份的普通 `key=value` 路径
///   （`SettingsBackup` 只对 `flagOverrides` 那一个 Data 键做特殊处理）。
/// - `lyricsSongSourceExclusionTitles`：`{"<曲目 id>": "歌名 — 歌手"}`，只给设置页列陈用；
///   老数据没有名字就显示「未知歌曲 + 短 id」，不猜。
/// - `lyricsSongSourceExclusionsRevision`：每次写入 +1。它进 `LyricsResponseCache.currentSignature`，
///   否则改完排除项、60 秒内重听同一首，交出去的还是那份旧 payload（看起来像"设置没生效"）。
///
/// 刻意**不做内存缓存**：一份几十条记录的 JSON，每首歌取词时解一次，成本可以忽略；
/// 而缓存要跟着"备份导入 / 全局重置"失效，那两个入口今天并没有通知机制
/// （`LyricsTimingOffset` 的缓存就有这个尾巴）。
enum LyricsSongSourceExclusions {

    static let exclusionsKey = "lyricsSongSourceExclusions"
    static let titlesKey = "lyricsSongSourceExclusionTitles"
    static let revisionKey = "lyricsSongSourceExclusionsRevision"

    /// 备份 / 全局重置要认识的键。
    static var ownedKeys: [String] { [exclusionsKey, titlesKey, revisionKey] }

    /// 上限：一首歌一条。超了按曲目 id 排序丢几条 —— 没有时间戳可排，
    /// 但至少行为是确定的，不会悄悄无限增长。
    static let maxEntries = 500

    /// 设置页那一列的一行。
    struct Entry {
        let trackId: String
        let sources: [LyricsSource]
        let title: String?
    }

    // MARK: - 读

    static func sources(forTrackId trackId: String) -> Set<LyricsSource> {
        let key = normalized(trackId)
        guard !key.isEmpty else { return [] }
        return Set(decoded()[key] ?? [])
    }

    static func title(forTrackId trackId: String) -> String? {
        let key = normalized(trackId)
        guard !key.isEmpty else { return nil }
        return decodedTitles()[key]
    }

    /// 已保存的排除项（设置页那一列），按名字排序。
    static var entries: [Entry] {
        let titles = decodedTitles()
        return decoded()
            .map { trackId, sources in
                Entry(trackId: trackId, sources: sources, title: titles[trackId])
            }
            .sorted { lhs, rhs in
                let byTitle = (lhs.title ?? lhs.trackId).localizedStandardCompare(rhs.title ?? rhs.trackId)
                if byTitle != .orderedSame { return byTitle == .orderedAscending }
                return lhs.trackId < rhs.trackId
            }
    }

    // MARK: - 写

    static func setSources(
        _ sources: Set<LyricsSource>,
        forTrackId trackId: String,
        title: String? = nil
    ) {
        let key = normalized(trackId)
        guard !key.isEmpty else { return }

        var map = decoded()
        let storable = sources.filter(isStorable)
        if storable.isEmpty {
            map.removeValue(forKey: key)
        } else {
            map[key] = storable.sorted { $0.offsetStorageKey < $1.offsetStorageKey }
        }
        persist(trimmed(map))
        if let title, !sources.isEmpty {
            var titles = decodedTitles()
            let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedTitle.isEmpty {
                titles.removeValue(forKey: key)
            } else {
                titles[key] = trimmedTitle
            }
            persistTitles(titles)
        } else if sources.isEmpty {
            var titles = decodedTitles()
            if titles.removeValue(forKey: key) != nil {
                persistTitles(titles)
            }
        }
        bumpRevision()
    }

    static func clear(trackId: String) {
        let key = normalized(trackId)
        guard !key.isEmpty else { return }
        var map = decoded()
        guard map.removeValue(forKey: key) != nil else { return }
        persist(map)
        var titles = decodedTitles()
        if titles.removeValue(forKey: key) != nil {
            persistTitles(titles)
        }
        bumpRevision()
    }

    static func clearAll() {
        UserDefaults.standard.removeObject(forKey: exclusionsKey)
        UserDefaults.standard.removeObject(forKey: titlesKey)
        bumpRevision()
    }

    // MARK: - 生效（链过滤）

    /// 纯函数：从询问链里去掉被排除的源。
    ///
    /// **全被排除时返回原链**：让一首歌彻底没歌词，比"用了一个不喜欢的源"更糟。
    static func resolve(
        chain: [LyricsSource],
        excluding withheld: Set<LyricsSource>
    ) -> [LyricsSource] {
        guard !withheld.isEmpty else { return chain }
        let allowed = chain.filter { !withheld.contains($0) }
        return allowed.isEmpty ? chain : allowed
    }

    /// 取词链的入口：按曲目 id 排掉被排除的源，并把"这一次实际跳过了谁"写进日志
    /// （真机上判断"排除有没有生效"就看这一行）。
    static func resolvedChain(_ chain: [LyricsSource], trackId: String) -> [LyricsSource] {
        let withheld = sources(forTrackId: trackId)
        guard !withheld.isEmpty else { return chain }

        let resolved = resolve(chain: chain, excluding: withheld)
        if resolved.count == chain.count {
            writeDebugLog(
                "[Lyrics] per-song exclusions for \(shortened(trackId)) cover every source — ignoring them"
            )
        } else {
            let skipped = withheld.map(\.offsetStorageKey).sorted().joined(separator: ", ")
            writeDebugLog(
                "[Lyrics] per-song exclusions for \(shortened(trackId)): skipping \(skipped)"
            )
        }
        return resolved
    }

    // MARK: - 编解码（纯逻辑，CI 里直接测）

    /// 解一份存储文本。未知键 / 不可排除的源 / 空列表一律丢掉。
    static func decode(_ text: String?) -> [String: [LyricsSource]] {
        guard let text,
              let data = text.data(using: .utf8),
              let raw = try? JSONDecoder().decode([String: [String]].self, from: data) else {
            return [:]
        }

        var result: [String: [LyricsSource]] = [:]
        for (trackId, keys) in raw {
            let key = normalized(trackId)
            guard !key.isEmpty else { continue }
            var sources: [LyricsSource] = []
            for rawKey in keys {
                guard let source = LyricsSource(offsetStorageKey: rawKey),
                      isStorable(source),
                      !sources.contains(source) else { continue }
                sources.append(source)
            }
            guard !sources.isEmpty else { continue }
            result[key] = sources.sorted { $0.offsetStorageKey < $1.offsetStorageKey }
        }
        return result
    }

    static func encode(_ map: [String: [LyricsSource]]) -> String? {
        guard !map.isEmpty else { return nil }
        let raw = map.mapValues { $0.map(\.offsetStorageKey) }
        guard let data = try? JSONEncoder().encode(raw) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - 内部

    /// 能作为"排除项"的源：链上真实存在的那几个。
    ///
    /// `autoSelect` 是这一整条链本身、`notReplaced` 是"不替换"、`imported` 是用户自己的文件、
    /// `appleMusicOfficialTtml` 是实验总覆盖 —— 它们都不在 `LyricsAutoSelect.chain()` 里，
    /// 存进来也不会有任何效果，只会在设置页里多出几行永远不生效的开关。
    private static func isStorable(_ source: LyricsSource) -> Bool {
        switch source {
        case .autoSelect, .notReplaced, .imported, .appleMusicOfficialTtml:
            return false
        default:
            return true
        }
    }

    private static func normalized(_ trackId: String) -> String {
        trackId.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 设置页那一列显示的短 id：日志与"未知歌曲"里用，前后各留一截。
    static func shortened(_ trackId: String) -> String {
        let key = normalized(trackId)
        guard key.count > 10 else { return key }
        return String(key.prefix(4)) + "…" + String(key.suffix(4))
    }

    private static func trimmed(_ map: [String: [LyricsSource]]) -> [String: [LyricsSource]] {
        guard map.count > maxEntries else { return map }
        let kept = map.keys.sorted().suffix(maxEntries)
        return map.filter { kept.contains($0.key) }
    }

    private static func decoded() -> [String: [LyricsSource]] {
        decode(UserDefaults.standard.string(forKey: exclusionsKey))
    }

    private static func decodedTitles() -> [String: String] {
        guard let text = UserDefaults.standard.string(forKey: titlesKey),
              let data = text.data(using: .utf8),
              let raw = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return raw.filter { !$0.key.isEmpty && !$0.value.isEmpty }
    }

    private static func persist(_ map: [String: [LyricsSource]]) {
        if let text = encode(map) {
            UserDefaults.standard.set(text, forKey: exclusionsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: exclusionsKey)
        }
    }

    private static func persistTitles(_ titles: [String: String]) {
        if titles.isEmpty {
            UserDefaults.standard.removeObject(forKey: titlesKey)
            return
        }
        guard let data = try? JSONEncoder().encode(titles) else { return }
        UserDefaults.standard.set(String(data: data, encoding: .utf8), forKey: titlesKey)
    }

    private static func bumpRevision() {
        let current = UserDefaults.standard.integer(forKey: revisionKey)
        UserDefaults.standard.set(current + 1, forKey: revisionKey)
    }

    /// 设置签名用：改过任何一条排除项，这个数就变（见文件头那段说明）。
    static var revision: Int {
        UserDefaults.standard.integer(forKey: revisionKey)
    }
}
