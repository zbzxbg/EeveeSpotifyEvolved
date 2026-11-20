import Foundation

struct ImportedLyricsFileRecord: Equatable {
    var name: String
    var url: URL
    var modifiedAt: Date?
}

/// 用户导入的歌词文件（只碰文件系统，不碰 UI / 网络）。
///
/// 目录固定为 `<Documents>/EeveeSpotifyLyrics/`：Spotify 的容器里 Documents 是唯一
/// 我们能安全写的位置，而"拷贝进来"而不是"每次从选择器读"的原因是——选择器给的 URL
/// 是临时授权，App 重启后就失效了。
///
/// 这一层不引 `LyricsError`（那是 App 层的类型），要编译成独立测试就用自己的错误。
enum ImportedLyricsStoreError: Error {
    case unsupportedFormat
}

final class ImportedLyricsStore {

    static let directoryName = "EeveeSpotifyLyrics"
    static let shared = ImportedLyricsStore()

    private let fileManager: FileManager
    let directory: URL

    init(directory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.directory = directory ?? ImportedLyricsStore.defaultDirectory(fileManager: fileManager)
    }

    static func defaultDirectory(fileManager: FileManager = .default) -> URL {
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return documents.appendingPathComponent(directoryName, isDirectory: true)
    }

    func prepareDirectory() throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// 目录里所有能被解析的文件，最近修改的在前。
    func list() -> [ImportedLyricsFileRecord] {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let urls = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls
            .filter { ImportedLyricsParser.detect(fileExtension: $0.pathExtension) != nil }
            .map { url in
                let modified = (try? url.resourceValues(forKeys: Set(keys)))?.contentModificationDate
                return ImportedLyricsFileRecord(name: url.lastPathComponent, url: url, modifiedAt: modified)
            }
            .sorted { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
    }

    /// 把选择器给的文件拷进目录。重名不覆盖，改成 `名字-2.lrc` 这样往下排。
    @discardableResult
    func importFile(at source: URL) throws -> ImportedLyricsFileRecord {
        let fileExtension = source.pathExtension.lowercased()
        guard ImportedLyricsParser.detect(fileExtension: fileExtension) != nil else {
            throw ImportedLyricsStoreError.unsupportedFormat
        }
        try prepareDirectory()

        let baseName = source.deletingPathExtension().lastPathComponent
        var name = "\(baseName).\(fileExtension)"
        var index = 2
        while fileManager.fileExists(atPath: directory.appendingPathComponent(name).path) {
            name = "\(baseName)-\(index).\(fileExtension)"
            index += 1
        }
        let destination = directory.appendingPathComponent(name)
        try fileManager.copyItem(at: source, to: destination)
        return ImportedLyricsFileRecord(name: name, url: destination, modifiedAt: Date())
    }

    func delete(_ record: ImportedLyricsFileRecord) throws {
        try fileManager.removeItem(at: record.url)
    }

    /// 读 + 解码 + 解析；文件坏了返回 nil（上层据此当"没匹配到"）。
    func load(_ record: ImportedLyricsFileRecord) -> ImportedLyrics? {
        guard let format = ImportedLyricsParser.detect(fileExtension: record.url.pathExtension),
              let data = try? Data(contentsOf: record.url),
              let text = ImportedLyricsDecoder.decode(data) else { return nil }
        return ImportedLyricsParser.parse(text: text, format: format)
    }

    /// 目录里每个文件解析一次，供匹配用。
    ///
    /// `[length:]` 不是每个格式都有（LRC / LYS 有，YRC 没有），没有时 `durationMs` 为 nil，
    /// 匹配器只能靠标题与歌手判断。
    func candidates() -> [(record: ImportedLyricsFileRecord, candidate: ImportedLyricsCandidate)] {
        list().compactMap { record in
            guard let lyrics = load(record) else { return nil }
            let candidate = ImportedLyricsCandidate(
                fileName: record.name,
                title: lyrics.metadata.title,
                artist: lyrics.metadata.artist,
                durationMs: lyrics.metadata.lengthMs
            )
            return (record, candidate)
        }
    }

    func match(title: String, artists: [String], durationMs: Int?) -> ImportedLyricsFileRecord? {
        let all = candidates()
        let candidates = all.map(\.candidate)
        guard let index = ImportedLyricsMatcher.bestMatch(
            candidates: candidates,
            title: title,
            artists: artists,
            durationMs: durationMs
        ) else { return nil }
        return all[index].record
    }
}
