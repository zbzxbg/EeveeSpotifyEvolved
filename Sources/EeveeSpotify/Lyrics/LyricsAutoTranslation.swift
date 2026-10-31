import Foundation

/// 「歌词自动翻译」的调度层：决定**这一首要不要翻**、翻过没有、翻完了怎么塞回去。
///
/// 引擎在 `OnDeviceLyricsTranslation`（Apple 的 `Translation` 框架，纯本地）。
/// 这一份只做四件事：
///
/// 1. **该不该翻**：开关打开、系统支持、这一首有行、不是纯音乐、**源自己没给译文**；
/// 2. **对齐**：只处理"每行都有时间轴、且已经按时间升序"的歌词 —— 渲染层
/// （`LyricLinesAdapter.toAppleMusicLyricLines`）取译文时用的是
/// **"过滤掉无时间轴的行、再按时间排序"之后的下标**，只有在这种歌词上，
/// 那个下标才和 `dto.lines` 的下标一一对应。对不上的宁可翻不了，也不要串行；
/// 3. **缓存**：按「曲目 + 目标语言」记住结果，来回切歌不重复翻；
/// 4. **回写**：翻完写进 `currentLyricsDto.translation` 并把 `currentLyricsVersion`
/// 加一 —— 两个 overlay 层都是盯着这个版本号重建的，不用另外通知。
///
/// ⚠️ 全程主线程读写 `currentLyricsDto` / `currentLyricsVersion`（与 `CustomLyrics` 同一条纪律）；
/// 只有 `OnDeviceLyricsTranslation.translate` 那一段在后台。
enum LyricsAutoTranslation {

    /// 歌词刚落地时叫一次（`CustomLyrics` 在 `currentLyricsVersion += 1` 之后）。
    static func considerAfterLoad() {
        guard UserDefaults.lyricsAutoTranslate else { return }
        guard OnDeviceLyricsTranslation.isAvailable else { return }
        guard let dto = currentLyricsDto, !dto.lines.isEmpty, !dto.isInstrumental else { return }
        // 源自己带了译文（网易云 `tlrc` 之类）⇒ 那是人家的官方译文，不动它。
        guard dto.translation == nil else { return }
        // 只有"每行都有时间轴、且已按时间升序"时才保证下标对得上（见文件头第 2 条）。
        guard isAligned(dto) else {
            writeDebugLog("[Lyrics] system translation skipped — the lines are not fully time-sorted")
            return
        }
        let trackId = currentLyricsDtoTrackId
        guard !trackId.isEmpty else { return }

        let language = OnDeviceLyricsTranslation.targetLanguageTag()
        let key = "\(trackId)|\(language)"
        if let cached = cache[key] {
            apply(cached, for: trackId, language: language)
            return
        }
        guard !running.contains(key) else { return }
        running.insert(key)

        let texts = dto.lines.map(\.content)
        Task.detached(priority: .utility) {
            let result = await OnDeviceLyricsTranslation.translate(texts, to: language)
            await MainActor.run {
                running.remove(key)
                guard let translated = result.lines else {
                    writeDebugLog("[Lyrics] system translation skipped — \(result.message ?? "unknown reason")")
                    return
                }
                cache[key] = translated
                apply(translated, for: trackId, language: language)
            }
        }
    }

    /// 每行都有时间轴、且非递减 —— 只有这样渲染层那个下标才等于 `dto.lines` 的下标。
    private static func isAligned(_ dto: LyricsDto) -> Bool {
        var previous = Int.min
        for line in dto.lines {
            guard let offset = line.offsetMs, offset >= previous else { return false }
            previous = offset
        }
        return true
    }

    /// 写回当前 dto。**只在"还是同一首"时写** —— 翻译跑在后台，回来时用户可能已经切歌。
    private static func apply(_ translated: [String], for trackId: String, language: String) {
        guard currentLyricsDtoTrackId == trackId, var dto = currentLyricsDto else { return }
        guard dto.translation == nil, dto.lines.count == translated.count else { return }
        dto.translation = LyricsTranslationDto(languageCode: language, lines: translated)
        currentLyricsDto = dto
        currentLyricsVersion += 1
        writeDebugLog(
            "[Lyrics] system translation applied — \(translated.filter { !$0.isEmpty }.count)"
                + "/\(translated.count) line(s) into \(language)"
        )
    }

    /// 曲目 + 语言 → 译文（只在内存里；重启要重新翻，与"纯本地、不留痕"一致）。
    private static var cache: [String: [String]] = [:]
    /// 正在翻的（同一首连点两次歌词按钮不重复跑）。
    private static var running: Set<String> = []
}
