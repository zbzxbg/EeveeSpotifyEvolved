import Foundation

/// 给锁屏现取一份"带时间轴的行"。
///
/// 为什么不直接调 `CustomLyrics.loadCustomLyricsForCurrentTrack`：那条路会改全局的
/// `lyricsState`、弹"令牌无效"这类配置错误的窗，而且只在歌词页请求时才跑。锁屏要的是一份
/// 安静的数据 —— 给一个 `LyricsSearchQuery`，拿行；失败就返回 nil，界面退回动态封面。
///
/// 来源选择仍是用户自己那一套：`UserDefaults.lyricsSource` 选单源，`.autoSelect` 走
/// `LyricsAutoSelect.chain()` 的顺序。锁屏不需要"逐字优先"这类质量档 —— 每一行只取一次
/// 文本，谁先给出**行级时间轴**就用谁。
enum LockScreenLyricsFetcher {

    struct Result {
        let lines: [LockScreenLyricLine]
        let source: LyricsSource
    }

    /// 同步执行（调用方负责放到后台队列）。`deadline` 是"整次取词"的预算：
    /// 每个源之间查一次，过了就不再问下一个。
    static func lines(
        for query: LyricsSearchQuery,
        trackId: String,
        deadline: Date
    ) -> Result? {
        // 「实验 → 启用 Apple Music 官方 TTML 歌词」是**忽略其它所有歌词设置**的总覆盖
        // （见 `CustomLyrics.loadCustomLyricsForCurrentTrack` 顶部）：它连"禁用歌词替换"
        // 也压过去。锁屏这一层必须同样处理，否则开关打开后两边可能拿到不同的词。
        let officialOverride = UserDefaults.experimentsOptions.appleMusicOfficialTtml
        let setting = UserDefaults.lyricsSource
        if !officialOverride {
            guard setting.isReplacingLyrics else { return nil }
        }

        let candidates: [LyricsSource] = officialOverride
            ? [.appleMusicOfficialTtml]
            : (setting == .autoSelect ? LyricsAutoSelect.chain() : [setting])
        let options = UserDefaults.lyricsOptions

        for candidate in candidates {
            guard Date() < deadline else {
                writeDebugLog("[\(LockScreenLyrics.logTag)] out of time before \(candidate.description)")
                break
            }
            let source = substituteIfNeeded(candidate)
            guard let repository = repository(for: source) else { continue }

            let started = Date()
            do {
                var dto = try repository.getLyrics(query, options: options)
                if LyricsTimingOffset.supportsOffset(source: source) {
                    dto = dto.applyingTimingOffset(
                        LyricsTimingOffset.offsetMs(forTrackId: trackId, source: source)
                    )
                }
                guard let lines = convert(dto) else {
                    writeDebugLog(
                        "[\(LockScreenLyrics.logTag)] \(source.description) gave no timed lines"
                            + " — \(took(started))"
                    )
                    continue
                }
                writeDebugLog(
                    "[\(LockScreenLyrics.logTag)] \(lines.count) line(s) from"
                        + " \(source.description) — \(took(started))"
                )
                return Result(lines: lines, source: source)
            } catch {
                writeDebugLog(
                    "[\(LockScreenLyrics.logTag)] \(source.description) failed — \(error) (\(took(started)))"
                )
            }
        }
        return nil
    }

    /// 内存里已经加载过这一首时直接转，不发网络请求。
    /// 只有 `currentLyricsDtoTrackId` 对得上才可信 —— 否则那是上一首的词。
    static func convert(_ dto: LyricsDto) -> [LockScreenLyricLine]? {
        guard dto.timeSynced, !dto.isInstrumental else { return nil }

        // 只保留有起点、且有文字的行。纯文本源（Genius）本来就没有时间轴，这里自然被筛掉。
        var timed: [(start: Int, end: Int?, text: String)] = []
        for line in dto.lines {
            guard let start = line.offsetMs else { continue }
            let text = line.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            timed.append((start, line.endOffsetMs, text))
        }
        guard timed.count >= 2 else { return nil }
        timed.sort { $0.start < $1.start }

        var lines: [LockScreenLyricLine] = []
        lines.reserveCapacity(timed.count)
        for (index, item) in timed.enumerated() {
            let nextStart = index + 1 < timed.count ? timed[index + 1].start : nil
            // 源给了"唱完的时刻"就用它（AMLL 的 `<p end>`）；没有就退回下一行的起点。
            let end = item.end ?? nextStart ?? (item.start + LockScreenLyrics.breakMs)
            lines.append(
                LockScreenLyricLine(
                    startMs: item.start,
                    endMs: max(end, item.start),
                    text: item.text
                )
            )
        }
        return lines
    }

    // MARK: - 来源

    /// 没填 Spicy Lyrics 密钥时用 Musixmatch 顶上（与歌词页那条路一致：
    /// 不走被条款禁止的内部接口）。
    private static func substituteIfNeeded(_ source: LyricsSource) -> LyricsSource {
        if source == .spicy, !UserDefaults.hasSpicyLyricsApiKey {
            return .musixmatch
        }
        return source
    }

    /// 与 `CustomLyrics` 里那份映射同义。那边是 fileprivate，这里是锁屏自己的入口。
    private static func repository(for source: LyricsSource) -> LyricsRepository? {
        switch source {
        case .genius: return GeniusLyricsRepository()
        case .lrclib: return LrclibLyricsRepository.shared
        case .musixmatch: return MusixmatchLyricsRepository.shared
        case .petit: return PetitLyricsRepository()
        case .spicy: return SpicyLyricsRepository.shared
        case .netease: return NeteaseLyricsRepository.shared
        case .amllTtml: return AmllTtmlLyricsRepository.shared
        case .bini: return BiniLyricsRepository.shared
        case .unison: return UnisonLyricsRepository.shared
        case .qqMusic: return QQMusicLyricsRepository.shared
        case .kugou: return KuGouLyricsRepository.shared
        case .appleMusicOfficialTtml: return AppleMusicOfficialTtmlLyricsRepository.shared
        case .notReplaced, .autoSelect: return nil
        }
    }

    private static func took(_ started: Date) -> String {
        "\(Int(Date().timeIntervalSince(started) * 1000)) ms"
    }
}
