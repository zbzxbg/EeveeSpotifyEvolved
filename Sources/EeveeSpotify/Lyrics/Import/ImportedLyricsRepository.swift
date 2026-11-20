import Foundation

/// 把目录里匹配到的那个文件交给歌词管线。
///
/// 只在这一首**确实有用户的文件**时被调用（匹配在 `getLyrics` 里做），所以它不需要
/// 兜底链：找不到就抛 `noSuchSong`，由 `CustomLyrics` 决定要不要回退到网络源。
final class ImportedLyricsRepository: LyricsRepository {

    static let shared = ImportedLyricsRepository(store: .shared)

    let store: ImportedLyricsStore

    init(store: ImportedLyricsStore) {
        self.store = store
    }

    func getLyrics(_ query: LyricsSearchQuery, options: LyricsOptions) throws -> LyricsDto {
        guard let dto = matchingDto(for: query) else {
            throw LyricsError.noSuchSong
        }
        return dto
    }

    /// 匹配上就返回管线 DTO，没匹配上返回 nil。
    ///
    /// 取词链最前面那一步用它：有文件就用文件，没有就静默地走正常链路 ——
    /// 不能抛错，否则"用户没给这首歌导文件"会被当成一次失败（还会弹提示）。
    func matchingDto(for query: LyricsSearchQuery) -> LyricsDto? {
        let artists = query.artistNames.isEmpty ? [query.primaryArtist] : query.artistNames
        guard let record = store.match(
            title: query.title,
            artists: artists,
            durationMs: query.durationMs
        ), let imported = store.load(record) else {
            return nil
        }
        writeDebugLog(
            "[Lyrics] imported file matched: \(record.name) — \(imported.lines.count) line(s),"
                + " \(imported.format.rawValue)"
        )
        return Self.dto(from: imported)
    }

    /// 导入文件 → 管线 DTO。
    ///
    /// 逐词/行级由格式自己决定（有 `words` 就是逐词），歌词偏移沿用行首时间；
    /// 译文按行对齐（没有译文的位置填空串），语言码未知时写 `und`。
    static func dto(from imported: ImportedLyrics) -> LyricsDto {
        let lines = imported.lines.map { line in
            LyricsLineDto(
                content: line.text,
                offsetMs: line.startMs,
                endOffsetMs: line.endMs,
                words: line.words?.map { word in
                    LyricsWordDto(text: word.text, startMs: word.startMs, endMs: word.endMs)
                }
            )
        }
        var dto = LyricsDto(lines: lines, timeSynced: true, romanization: .original)
        let translations = imported.lines.map { $0.translation ?? "" }
        if translations.contains(where: { !$0.isEmpty }) {
            dto.translation = LyricsTranslationDto(languageCode: "und", lines: translations)
        }
        return dto
    }
}
