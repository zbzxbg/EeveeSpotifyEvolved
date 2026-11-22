import Compression
import Foundation

// 「导入 Spotify 流媒体历史」的解析层：**纯 Foundation + Compression**。
//
// 输入是用户在「设置 → 听歌统计」里挑的那个导出（`my_spotify_data.zip`、里面那个文件夹，
// 或者直接挑几个 `.json`）；输出是一批可以交给 `ListeningStatsStore` 的
// `ListeningStatsImportAddition`。不联网、不写盘、不碰 UIKit —— 所以这一整套
// 在 CI 的 macOS runner 上能被 `swiftc` 编一遍并真跑一遍（本机没有 Swift 工具链）。
//
// 三个刻意的设计：
//
// 1. **一次只装一个文件**。导出包本身不读进内存：ZIP 从中央目录拿到条目表，逐个条目
//    读 + 解压 + 解析 + 丢掉。单个 JSON 仍要整份读（Foundation 没有流式 JSON 解析），
//    但解对象是**逐条**的（见 `StreamingHistoryRecordScanner`），不会出现「文件大小 × 十几倍」。
//
// 2. **两种历史都认**。扩展历史（`Streaming_History_Audio_*.json`，字段 `ts` /
//    `master_metadata_*` / `spotify_track_uri`）与旧的账户数据（`StreamingHistory0.json`，
//    字段 `endTime` / `trackName` / `artistName` / `msPlayed`）。用户从哪个入口下载的都行。
//
// 3. **去重分两层**。同一个导出里重复出现的同一条记录（多设备同步、包被合并）在**这一次**
//    导入里按「时间戳 + 曲目 + 时长」去掉；跨次导入按文件名 + 内容指纹判断
//    （`ListeningStatsImportedSource`），同一份文件再导入一遍不会翻倍。

// MARK: - 结果

/// 一次导入解析出来的东西。
struct StreamingHistoryImportBatch {

    /// 要并进 store 的来源（每个文件一条），顺序与用户的选择一致。
    var additions: [ListeningStatsImportAddition] = []

    /// 真正读了一遍的文件数。
    var filesRead = 0

    /// 指纹没变、整份跳过的文件数。
    var filesSkipped = 0

    /// 解析出的记录总数（含后面被去重丢掉的）。
    var records = 0

    /// 被去重丢掉的记录数（同一次导入内的重复 + 已被上次导入覆盖的部分）。
    var duplicates = 0

    /// 读不成/认不出的东西，一条一件。给设置页翻成人话。
    var failures: [StreamingHistoryFailure] = []

    /// 这批记录覆盖的日桶范围（`yyyy-MM-dd`，只统计真正并进去的条目）。
    var earliestDay: String?
    var latestDay: String?

    var isEmpty: Bool { additions.isEmpty }

    /// 并进去的播放次数（按 30 秒门槛，与录音器同一把尺子）。
    var plays: Int {
        additions.reduce(0) { total, addition in
            total + addition.entries.reduce(0) { $0 + $1.plays }
        }
    }

    var seconds: Double {
        additions.reduce(0) { total, addition in
            total + addition.entries.reduce(0) { $0 + $1.seconds }
        }
    }
}

/// 一个读不成/认不出的来源。`kind` 由设置页映射成本地化文案 —— 解析层不碰 l10n。
struct StreamingHistoryFailure {
    enum Kind {
        /// 不是合法的 ZIP。
        case unreadableArchive
        /// 是 ZIP，但用了不支持的特性（ZIP64 / 加密 / 非 deflate 压缩）。
        case unsupportedArchive
        /// 文件读不出来，或者里面找不到一条能认的记录。
        case unreadableFile
        /// 目录/压缩包里根本没有 JSON 文件。
        case noHistoryFile
    }

    var kind: Kind
    var name: String
}

// MARK: - 入口

enum StreamingHistoryImporter {

    /// 读一遍用户选中的东西，汇总成一批可以直接并进 store 的来源。
    ///
    /// - Parameters:
    ///   - urls: 用户选的 `.zip` / 文件夹 / `.json`。文件夹与压缩包内部会被递归展开。
    ///   - known: 之前导入过的来源（文件名 → 指纹 + 覆盖到的时间），来自 store。同一个文件
    ///     指纹没变就整份跳过；变了（导出包在变长）就只补比 `latestTimestamp` 更新的记录。
    ///   - calendar: 决定「按哪个时区分日桶」。测试传固定时区。
    static func parse(
        urls: [URL],
        known: [String: ListeningStatsImportedSource],
        calendar: Calendar = .current
    ) -> StreamingHistoryImportBatch {
        var batch = StreamingHistoryImportBatch()

        // 选择器给的是安全作用域 URL（`asCopy: false`），读之前必须开、读完关。
        // 解析全程都在这个作用域里，所以放在最外层一次开合。
        let scoped = urls.map { ($0, $0.startAccessingSecurityScopedResource()) }
        defer {
            for (url, opened) in scoped where opened {
                url.stopAccessingSecurityScopedResource()
            }
        }

        var pending: [StreamingHistoryPendingFile] = []
        var names = Set<String>()

        for url in urls {
            for file in StreamingHistorySourceDiscovery.files(at: url, failures: &batch.failures) {
                // 同一个 JSON 可能既在压缩包里、又在用户顺手一起选的文件夹里：只取先到的那份。
                guard names.insert(file.name.lowercased()).inserted else { continue }
                pending.append(file)
            }
        }

        // 这一次导入内已经算过的记录（跨文件）。只活在这一趟里，不落盘。
        var seenEvents = Set<UInt64>()

        for file in pending {
            let data: Data
            do {
                data = try file.read()
            } catch {
                batch.failures.append(
                    StreamingHistoryFailure(kind: .unreadableFile, name: file.displayPath)
                )
                continue
            }

            let fingerprint = StreamingHistoryFingerprint.of(data)
            let previous = known[file.name]

            if let previous, previous.fingerprint == fingerprint {
                batch.filesSkipped += 1
                continue
            }

            batch.filesRead += 1

            var accumulator = StreamingHistoryAccumulator()
            var latest = previous?.latestTimestamp ?? 0
            var covered = 0
            var duplicate = 0

            let summary = StreamingHistoryRecordScanner.scan(data) { record in
                batch.records += 1
                if record.timestampSeconds > latest {
                    latest = record.timestampSeconds
                }

                // 这份文件上次已经算到这一刻：重叠的部分不再加一遍。
                if record.timestampSeconds <= (previous?.latestTimestamp ?? 0) {
                    covered += 1
                    return
                }

                let trackID = ListeningStatsTrackKey.identifier(
                    trackID: record.trackIdentifier,
                    title: record.title,
                    artist: record.artist,
                    durationSeconds: 0
                )

                let event = StreamingHistoryFingerprint.event(
                    timestampSeconds: record.timestampSeconds,
                    trackID: trackID,
                    msPlayed: record.msPlayed
                )
                guard seenEvents.insert(event).inserted else {
                    duplicate += 1
                    return
                }

                let dayKey = ListeningStatsDayKey.key(
                    for: Date(timeIntervalSince1970: record.timestampSeconds),
                    calendar: calendar
                )
                accumulator.add(
                    dayKey: dayKey,
                    trackID: trackID,
                    title: record.title,
                    artist: record.artist,
                    seconds: record.seconds,
                    plays: record.countsAsPlay ? 1 : 0
                )
            }

            // 一条记录都认不出来：合法但空的历史（`[]`）不算错；截断/乱码的文件要报出来，
            // 否则用户看到的只是「什么都没加」，不知道该换一份导出。
            if summary.records == 0, !isWholeFileJSON(data) {
                batch.failures.append(
                    StreamingHistoryFailure(kind: .unreadableFile, name: file.displayPath)
                )
                continue
            }

            batch.duplicates += covered + duplicate

            let entries = accumulator.entries()
            // 空文件也要记账：不记的话，下次导入会重新解析它 —— 而这次丢掉的那些记录
            // 已经算在别的文件里了，重放会把它们加第二遍。
            batch.additions.append(
                ListeningStatsImportAddition(
                    name: file.name,
                    fingerprint: fingerprint,
                    latestTimestamp: max(latest, previous?.latestTimestamp ?? 0),
                    entries: entries
                )
            )

            for entry in entries {
                updateDayRange(&batch, dayKey: entry.dayKey)
            }
        }

        return batch
    }

    private static func updateDayRange(_ batch: inout StreamingHistoryImportBatch, dayKey: String) {
        if let earliest = batch.earliestDay {
            if dayKey < earliest { batch.earliestDay = dayKey }
        } else {
            batch.earliestDay = dayKey
        }

        if let latest = batch.latestDay {
            if dayKey > latest { batch.latestDay = dayKey }
        } else {
            batch.latestDay = dayKey
        }
    }

    /// 整份文件能不能当成一个 JSON 文档解出来。
    ///
    /// 只在「一条记录都没认出来」时才用：用来区分「合法但空的历史」与「截断/乱码」。
    /// 逐条扫描那一层刻意不做整体解析（几十 MB 的对象树），所以这条兜底是单独一次。
    private static func isWholeFileJSON(_ data: Data) -> Bool {
        (try? JSONSerialization.jsonObject(with: data)) != nil
    }
}

// MARK: - 来源发现

/// 待读的一个 JSON：名字（跨次去重的键）、给人看的路径、以及真正去读它的动作。
///
/// 用闭包而不是 `Data`，是为了让压缩包条目**按需**读：一次只有一个文件在内存里。
struct StreamingHistoryPendingFile {
    var name: String
    var displayPath: String
    var read: () throws -> Data
}

enum StreamingHistorySourceDiscovery {

    static func files(
        at url: URL,
        failures: inout [StreamingHistoryFailure]
    ) -> [StreamingHistoryPendingFile] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            failures.append(StreamingHistoryFailure(kind: .unreadableFile, name: url.lastPathComponent))
            return []
        }

        if isDirectory.boolValue {
            return folderFiles(at: url, failures: &failures)
        }

        switch url.pathExtension.lowercased() {
        case "zip":
            return archiveFiles(at: url, failures: &failures)
        case "json":
            return [jsonFile(at: url)]
        default:
            failures.append(StreamingHistoryFailure(kind: .unreadableFile, name: url.lastPathComponent))
            return []
        }
    }

    private static func jsonFile(at url: URL) -> StreamingHistoryPendingFile {
        StreamingHistoryPendingFile(
            name: url.lastPathComponent,
            displayPath: url.lastPathComponent,
            read: { try Data(contentsOf: url) }
        )
    }

    /// 文件夹：递归收 `.json`（隐藏文件跳过 —— `.DS_Store` 之类）。
    private static func folderFiles(
        at url: URL,
        failures: inout [StreamingHistoryFailure]
    ) -> [StreamingHistoryPendingFile] {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            failures.append(StreamingHistoryFailure(kind: .unreadableFile, name: url.lastPathComponent))
            return []
        }

        var files: [StreamingHistoryPendingFile] = []
        for case let child as URL in enumerator {
            guard child.pathExtension.lowercased() == "json" else { continue }
            files.append(
                StreamingHistoryPendingFile(
                    name: child.lastPathComponent,
                    displayPath: child.lastPathComponent,
                    read: { try Data(contentsOf: child) }
                )
            )
        }

        if files.isEmpty {
            failures.append(StreamingHistoryFailure(kind: .noHistoryFile, name: url.lastPathComponent))
        }
        return files
    }

    /// `.zip`：从中央目录拿条目表，只把 `.json` 收进来（`ReadMeFirst.pdf` 之类直接不看）。
    private static func archiveFiles(
        at url: URL,
        failures: inout [StreamingHistoryFailure]
    ) -> [StreamingHistoryPendingFile] {
        let entries: [StreamingHistoryZipEntry]
        do {
            entries = try StreamingHistoryZipReader.entries(at: url)
        } catch StreamingHistoryZipError.unsupportedArchive {
            failures.append(StreamingHistoryFailure(kind: .unsupportedArchive, name: url.lastPathComponent))
            return []
        } catch {
            failures.append(StreamingHistoryFailure(kind: .unreadableArchive, name: url.lastPathComponent))
            return []
        }

        var files: [StreamingHistoryPendingFile] = []
        for entry in entries where entry.path.lowercased().hasSuffix(".json") {
            files.append(
                StreamingHistoryPendingFile(
                    name: (entry.path as NSString).lastPathComponent,
                    displayPath: entry.path,
                    read: { try StreamingHistoryZipReader.data(for: entry, at: url) }
                )
            )
        }

        if files.isEmpty {
            failures.append(StreamingHistoryFailure(kind: .noHistoryFile, name: url.lastPathComponent))
        }
        return files
    }
}

// MARK: - 指纹

enum StreamingHistoryFingerprint {

    /// 文件内容指纹：长度 + FNV-1a。
    ///
    /// 这里要的是「这是不是同一份文件」，不是抗碰撞 —— 长度已经排掉绝大多数误判，
    /// 剩下的交给 64 位散列。用系统自带的密码学摘要也能做，但那要多一条 CryptoKit 依赖，
    /// 而且几十 MB 的数据走一遍 SHA-256 比这慢得多。
    static func of(_ data: Data) -> String {
        "\(data.count)-" + String(format: "%016llx", fnv1a(data))
    }

    /// 一条记录的身份：`时间戳|曲目|时长`。
    static func event(timestampSeconds: Double, trackID: String, msPlayed: Int) -> UInt64 {
        fnv1a("\(Int(timestampSeconds.rounded()))|\(trackID)|\(msPlayed)")
    }

    static func fnv1a(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }

    static func fnv1a(_ data: Data) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }
}

// MARK: - ZIP 读取

/// ZIP 中央目录里的一条。
struct StreamingHistoryZipEntry {
    var path: String
    var method: UInt16
    var flags: UInt16
    var compressedSize: Int
    var uncompressedSize: Int
    var localHeaderOffset: Int
}

enum StreamingHistoryZipError: Error {
    case notAnArchive
    case unsupportedArchive
    case corruptArchive
}

/// 只读的 ZIP 读取器（`PK\x03\x04` 家族，够读 Spotify 的导出包）。
///
/// 不支持、并且会明确报出来的：ZIP64、加密条目、deflate 以外的压缩方法。这些在导出包里
/// 都不会出现 —— 真出现了就给人话提示，而不是静默产出半份数据。
enum StreamingHistoryZipReader {

    private static let endOfDirectorySignature: UInt32 = 0x0605_4b50
    private static let directorySignature: UInt32 = 0x0201_4b50
    private static let localHeaderSignature: UInt32 = 0x0403_4b50

    /// 单个条目解压后的上限。导出包里最大的那份（几年的历史 / ReadMe PDF）也就几十 MB。
    static let maxEntrySize = 512 * 1024 * 1024

    /// 中央目录里最多认这么多条目（防一个畸形文件把循环拖死）。
    private static let maxEntryCount = 100_000

    static func entries(at url: URL) throws -> [StreamingHistoryZipEntry] {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }

        let size = Int(try file.seekToEnd())
        guard size > 22 else { throw StreamingHistoryZipError.notAnArchive }

        // 尾注（EOCD）在文件末尾，后面可能跟最多 64 KB 的注释；从后往前找签名。
        let tailLength = min(size, 66_000)
        try file.seek(toOffset: UInt64(size - tailLength))
        guard let tailData = try file.read(upToCount: tailLength) else {
            throw StreamingHistoryZipError.corruptArchive
        }
        let tail = [UInt8](tailData)

        var endOffset = -1
        var cursor = tail.count - 22
        while cursor >= 0 {
            if uint32(tail, cursor) == endOfDirectorySignature,
               cursor + 22 + Int(uint16(tail, cursor + 20)) <= tail.count {
                endOffset = cursor
                break
            }
            cursor -= 1
        }
        guard endOffset >= 0 else { throw StreamingHistoryZipError.notAnArchive }

        let entryCount = Int(uint16(tail, endOffset + 10))
        let directorySize = Int(uint32(tail, endOffset + 12))
        let directoryOffset = Int(uint32(tail, endOffset + 16))

        if entryCount == 0xFFFF || directorySize == 0xFFFF_FFFF || directoryOffset == 0xFFFF_FFFF {
            throw StreamingHistoryZipError.unsupportedArchive
        }
        guard directorySize > 0,
              directoryOffset >= 0,
              directoryOffset + directorySize <= size else {
            throw StreamingHistoryZipError.corruptArchive
        }

        try file.seek(toOffset: UInt64(directoryOffset))
        guard let directoryData = try file.read(upToCount: directorySize) else {
            throw StreamingHistoryZipError.corruptArchive
        }
        let directory = [UInt8](directoryData)

        var entries: [StreamingHistoryZipEntry] = []
        var index = 0
        while index + 46 <= directory.count,
              uint32(directory, index) == directorySignature,
              entries.count < maxEntryCount {
            let flags = uint16(directory, index + 8)
            let method = uint16(directory, index + 10)
            let compressedSize = Int(uint32(directory, index + 20))
            let uncompressedSize = Int(uint32(directory, index + 24))
            let nameLength = Int(uint16(directory, index + 28))
            let extraLength = Int(uint16(directory, index + 30))
            let commentLength = Int(uint16(directory, index + 32))
            let localOffset = Int(uint32(directory, index + 42))

            if compressedSize == 0xFFFF_FFFF
                || uncompressedSize == 0xFFFF_FFFF
                || localOffset == 0xFFFF_FFFF {
                throw StreamingHistoryZipError.unsupportedArchive
            }

            let nameStart = index + 46
            let nameEnd = nameStart + nameLength
            guard nameEnd <= directory.count else {
                throw StreamingHistoryZipError.corruptArchive
            }

            let name = String(decoding: directory[nameStart..<nameEnd], as: UTF8.self)
            entries.append(
                StreamingHistoryZipEntry(
                    path: name,
                    method: method,
                    flags: flags,
                    compressedSize: compressedSize,
                    uncompressedSize: uncompressedSize,
                    localHeaderOffset: localOffset
                )
            )

            index = nameEnd + extraLength + commentLength
        }

        guard !entries.isEmpty else { throw StreamingHistoryZipError.notAnArchive }
        return entries
    }

    static func data(for entry: StreamingHistoryZipEntry, at url: URL) throws -> Data {
        // 加密条目（通用标志位 0）不支持 —— 导出包不会加密。
        guard entry.flags & 0x0001 == 0 else { throw StreamingHistoryZipError.unsupportedArchive }
        guard entry.uncompressedSize >= 0,
              entry.uncompressedSize <= maxEntrySize,
              entry.compressedSize >= 0,
              entry.compressedSize <= maxEntrySize else {
            throw StreamingHistoryZipError.unsupportedArchive
        }

        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }

        // 本地文件头的名字/额外字段长度可能与中央目录不同，必须从本地头重新读。
        try file.seek(toOffset: UInt64(entry.localHeaderOffset))
        guard let headerData = try file.read(upToCount: 30), headerData.count == 30 else {
            throw StreamingHistoryZipError.corruptArchive
        }
        let header = [UInt8](headerData)
        guard uint32(header, 0) == localHeaderSignature else {
            throw StreamingHistoryZipError.corruptArchive
        }

        let nameLength = Int(uint16(header, 26))
        let extraLength = Int(uint16(header, 28))
        let dataOffset = entry.localHeaderOffset + 30 + nameLength + extraLength

        try file.seek(toOffset: UInt64(dataOffset))
        let readCount = entry.compressedSize
        let payload: Data
        if readCount == 0 {
            payload = Data()
        } else {
            guard let raw = try file.read(upToCount: readCount), raw.count == readCount else {
                throw StreamingHistoryZipError.corruptArchive
            }
            payload = raw
        }

        switch entry.method {
        case 0:
            return payload
        case 8:
            guard let inflated = inflateRaw(payload, expected: entry.uncompressedSize) else {
                throw StreamingHistoryZipError.corruptArchive
            }
            return inflated
        default:
            throw StreamingHistoryZipError.unsupportedArchive
        }
    }

    /// 裸 DEFLATE（RFC 1951）解压。
    ///
    /// ZIP 条目里的 deflate 流**没有 zlib 头尾**，所以直接喂 `COMPRESSION_ZLIB`
    /// （Apple 这个算法吃的就是裸 DEFLATE），不能复用 `ZlibInflate` —— 那个会按
    /// RFC 1950 去剥头两字节。
    private static func inflateRaw(_ compressed: Data, expected: Int) -> Data? {
        guard expected > 0 else { return Data() }
        let input = [UInt8](compressed)
        guard !input.isEmpty else { return nil }

        // 中央目录给的解压后大小是权威的，但有些打包器会写 0/写错，所以从 expected 起、
        // 不够就翻倍再试。
        var capacity = max(expected, 64 * 1024)
        while capacity <= maxEntrySize {
            var output = [UInt8](repeating: 0, count: capacity)
            let written = input.withUnsafeBufferPointer { inputBuffer -> Int in
                output.withUnsafeMutableBufferPointer { outputBuffer -> Int in
                    compression_decode_buffer(
                        outputBuffer.baseAddress!, outputBuffer.count,
                        inputBuffer.baseAddress!, inputBuffer.count,
                        nil, COMPRESSION_ZLIB
                    )
                }
            }

            if written > 0, written <= expected {
                return Data(output[0..<written])
            }
            if written > 0, written < capacity {
                return Data(output[0..<written])
            }
            capacity *= 2
        }
        return nil
    }

    private static func uint16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= bytes.count else { return 0 }
        return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func uint32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= bytes.count else { return 0 }
        return UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }
}

// MARK: - 一条记录

struct StreamingHistoryRecord {
    /// Unix 时间（秒）。
    var timestampSeconds: Double
    /// `spotify:track:` / `spotify:episode:` 里的 id；旧格式拿不到，空串。
    var trackIdentifier: String
    var title: String
    var artist: String
    var msPlayed: Int

    /// 这一条算多少秒。上限见 `StreamingHistoryRecordParser.maxRecordSeconds`。
    var seconds: Double {
        min(Double(msPlayed) / 1000, StreamingHistoryRecordParser.maxRecordSeconds)
    }

    /// 与录音器同一把尺子：满 30 秒才算一次播放。
    var countsAsPlay: Bool {
        seconds >= ListeningStatsPlayCounter.playThresholdSeconds
    }
}

// MARK: - 逐条扫描

struct StreamingHistoryScanSummary {
    var objects = 0
    var records = 0
    var malformed = 0
}

enum StreamingHistoryRecordScanner {

    /// 扫出一段 JSON 里的每一个**顶层对象**，逐个解、逐个交出去。
    ///
    /// 为什么不是 `JSONSerialization` 整份文件：一份跨几年的导出有几十 MB，整份解成对象树
    /// 是文件大小的十几倍 —— 在手机上直接被系统杀掉。这里先按大括号配对切区间（字符串与
    /// 转义都算进去），再一条一条地解，峰值内存就是「文件 + 一条记录」。
    ///
    /// 兼容三种壳：顶层数组（`[{…},{…}]`）、每行一个对象（NDJSON）、单个对象。
    static func scan(
        _ data: Data,
        _ body: (StreamingHistoryRecord) -> Void
    ) -> StreamingHistoryScanSummary {
        var summary = StreamingHistoryScanSummary()

        guard let ranges = topLevelObjectRanges(in: data), !ranges.isEmpty else {
            return summary
        }

        for range in ranges {
            guard let object = try? JSONSerialization.jsonObject(with: data.subdata(in: range)),
                  let dictionary = object as? [String: Any] else {
                summary.malformed += 1
                continue
            }

            summary.objects += 1
            guard let record = StreamingHistoryRecordParser.record(from: dictionary) else { continue }

            summary.records += 1
            body(record)
        }

        return summary
    }

    private static func topLevelObjectRanges(in data: Data) -> [Range<Int>]? {
        var ranges: [Range<Int>] = []

        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)

            var depth = 0
            var start = -1
            var inString = false
            var escaped = false
            var index = 0

            while index < bytes.count {
                let byte = bytes[index]

                if inString {
                    if escaped {
                        escaped = false
                    } else if byte == 0x5C {
                        escaped = true
                    } else if byte == 0x22 {
                        inString = false
                    }
                    index += 1
                    continue
                }

                switch byte {
                case 0x22:
                    inString = true
                case 0x7B:
                    if depth == 0 { start = index }
                    depth += 1
                case 0x7D:
                    if depth > 0 {
                        depth -= 1
                        if depth == 0, start >= 0 {
                            ranges.append(start..<(index + 1))
                            start = -1
                        }
                    }
                default:
                    break
                }

                index += 1
            }
        }

        return ranges
    }
}

// MARK: - 记录字段

enum StreamingHistoryRecordParser {

    /// 单条记录最多算 12 小时。
    ///
    /// 导出里的 `ms_played` 并不总是可信：有负值，也有大到「一整天」那种值。照抄会把某一天的
    /// 时长直接拉爆，而这些值没有任何办法还原成真实播放时间。12 小时比最长的播客还长，
    /// 正常记录碰不到这条线。
    static let maxRecordSeconds: Double = 12 * 3600

    static func record(from dictionary: [String: Any]) -> StreamingHistoryRecord? {
        // 扩展历史：`Streaming_History_Audio_*.json`
        let extendedTimestamp = StreamingHistoryValue.string(dictionary["ts"])
        if !extendedTimestamp.isEmpty,
           let timestamp = StreamingHistoryTimestamp.seconds(from: extendedTimestamp) {
            return make(
                timestamp: timestamp,
                track: StreamingHistoryValue.string(dictionary["master_metadata_track_name"]),
                episode: StreamingHistoryValue.string(dictionary["episode_name"]),
                trackArtist: StreamingHistoryValue.string(dictionary["master_metadata_album_artist_name"]),
                show: StreamingHistoryValue.string(dictionary["episode_show_name"]),
                trackURI: StreamingHistoryValue.string(dictionary["spotify_track_uri"]),
                episodeURI: StreamingHistoryValue.string(dictionary["spotify_episode_uri"]),
                msPlayed: StreamingHistoryValue.int(dictionary["ms_played"])
            )
        }

        // 旧格式：账户数据里的 `StreamingHistory*.json`
        let legacyTimestamp = StreamingHistoryValue.string(dictionary["endTime"])
        if !legacyTimestamp.isEmpty,
           let timestamp = StreamingHistoryTimestamp.seconds(from: legacyTimestamp) {
            return make(
                timestamp: timestamp,
                track: StreamingHistoryValue.string(dictionary["trackName"]),
                episode: StreamingHistoryValue.string(dictionary["episodeName"]),
                trackArtist: StreamingHistoryValue.string(dictionary["artistName"]),
                show: StreamingHistoryValue.string(dictionary["showName"]),
                trackURI: "",
                episodeURI: "",
                msPlayed: StreamingHistoryValue.int(dictionary["msPlayed"])
            )
        }

        return nil
    }

    /// `spotify:track:<id>` / `spotify:episode:<id>` → `<id>`。
    ///
    /// 与录音器同一把尺子：那边存的也是 id 而不是整条 URI（`SPTURL.spt_trackIdentifier`），
    /// 所以导入过的歌与之后播放的同一首会合成同一行统计。
    static func trackIdentifier(fromURI uri: String) -> String {
        for prefix in ["spotify:track:", "spotify:episode:", "spotify:local:"]
        where uri.hasPrefix(prefix) {
            return String(uri.dropFirst(prefix.count))
        }
        return uri
    }

    private static func make(
        timestamp: Double,
        track: String,
        episode: String,
        trackArtist: String,
        show: String,
        trackURI: String,
        episodeURI: String,
        msPlayed: Int
    ) -> StreamingHistoryRecord? {
        guard msPlayed > 0 else { return nil }

        let title = firstNonEmpty(track, episode)
        guard !title.isEmpty else { return nil }

        return StreamingHistoryRecord(
            timestampSeconds: timestamp,
            trackIdentifier: trackIdentifier(fromURI: firstNonEmpty(trackURI, episodeURI)),
            title: title,
            artist: firstNonEmpty(trackArtist, show),
            msPlayed: msPlayed
        )
    }

    private static func firstNonEmpty(_ values: String...) -> String {
        for value in values where !value.isEmpty {
            return value
        }
        return ""
    }
}

/// JSON 值的宽取：导出里的 `ms_played` 有时是数字、有时是字符串。
enum StreamingHistoryValue {

    static func string(_ value: Any?) -> String {
        if let text = value as? String {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return ""
    }

    static func int(_ value: Any?) -> Int {
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let parsed = Int(trimmed) { return parsed }
            return Int(Double(trimmed) ?? 0)
        }
        return 0
    }
}

// MARK: - 时间戳

enum StreamingHistoryTimestamp {

    /// 解析 `2020-01-01T12:34:56Z`（扩展格式）与 `2020-01-01 12:34`（旧格式，UTC）。
    ///
    /// 不用 `ISO8601DateFormatter` / `DateFormatter`：前者每次建实例都很贵（一次导入要建
    /// 几十万条），后者受 locale 影响。这里只面对
    /// `yyyy-MM-dd[ T]HH:mm[:ss][.SSS][Z|±hh:mm]` 这一族，手写解析既快又不会随语言变。
    static func seconds(from text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 16 else { return nil }

        guard let separator = trimmed.firstIndex(where: { $0 == "T" || $0 == " " }) else {
            return nil
        }

        let datePart = trimmed[trimmed.startIndex..<separator]
        let timeAndZone = trimmed[trimmed.index(after: separator)...]

        let datePieces = datePart.split(separator: "-", omittingEmptySubsequences: false)
        guard datePieces.count == 3,
              let year = Int(datePieces[0]),
              let month = Int(datePieces[1]),
              let day = Int(datePieces[2]),
              (1900...2200).contains(year),
              (1...12).contains(month),
              (1...31).contains(day) else {
            return nil
        }

        let timeEnd = timeAndZone.firstIndex { !"0123456789:.".contains($0) } ?? timeAndZone.endIndex
        let timePart = timeAndZone[timeAndZone.startIndex..<timeEnd]
        let zonePart = timeAndZone[timeEnd...]

        let timePieces = timePart.split(separator: ":", omittingEmptySubsequences: false)
        guard timePieces.count >= 2,
              let hour = Int(timePieces[0]),
              let minute = Int(timePieces[1]),
              (0...23).contains(hour),
              (0...59).contains(minute) else {
            return nil
        }

        var second = 0
        var fraction = 0.0
        if timePieces.count >= 3 {
            let secondPart = timePieces[2]
            if let dot = secondPart.firstIndex(of: ".") {
                second = Int(secondPart[secondPart.startIndex..<dot]) ?? 0
                let digits = secondPart[secondPart.index(after: dot)...]
                fraction = Double("0." + String(digits)) ?? 0
            } else {
                second = Int(secondPart) ?? 0
            }
        }
        guard (0...59).contains(second) else { return nil }

        guard let offset = zoneOffsetSeconds(zonePart) else { return nil }

        guard let utc = TimeZone(secondsFromGMT: 0) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second

        guard let date = calendar.date(from: components) else { return nil }
        return date.timeIntervalSince1970 + fraction - Double(offset)
    }

    /// `Z` / 空 / `±hh:mm` / `±hhmm` → 相对 UTC 的秒数；认不出返回 nil。
    private static func zoneOffsetSeconds(_ text: Substring) -> Int? {
        if text.isEmpty { return 0 }
        if text == "Z" || text == "z" { return 0 }

        guard let sign = text.first, sign == "+" || sign == "-" else { return nil }
        let body = text.dropFirst()

        let hours: Int
        let minutes: Int
        if body.contains(":") {
            let pieces = body.split(separator: ":")
            guard pieces.count == 2,
                  let parsedHours = Int(pieces[0]),
                  let parsedMinutes = Int(pieces[1]) else { return nil }
            hours = parsedHours
            minutes = parsedMinutes
        } else {
            // `+0200`（ISO 8601 基本格式）也认：前两位小时、后两位分钟。
            guard body.count == 4,
                  let parsedHours = Int(body.prefix(2)),
                  let parsedMinutes = Int(body.suffix(2)) else { return nil }
            hours = parsedHours
            minutes = parsedMinutes
        }

        guard (0...23).contains(hours), (0...59).contains(minutes) else { return nil }
        let value = hours * 3600 + minutes * 60
        return sign == "-" ? -value : value
    }
}

// MARK: - 聚合

/// 把一个文件里的记录压成「一天一首一条」。
///
/// 同一天里同一首歌被听了很多次（单曲循环、一整天都在听）只会有一条记录，秒数与次数相加 ——
/// 与 `ListeningStatsData.add` 的口径一致，所以导入的数据与录音器写的数据在界面上没有区别。
struct StreamingHistoryAccumulator {

    private struct Track {
        var title: String
        var artist: String
        var seconds: Double
        var plays: Int
    }

    private var byDay: [String: [String: Track]] = [:]

    mutating func add(
        dayKey: String,
        trackID: String,
        title: String,
        artist: String,
        seconds: Double,
        plays: Int
    ) {
        guard seconds > 0 || plays > 0 else { return }

        var day = byDay[dayKey] ?? [:]
        var track = day[trackID] ?? Track(title: title, artist: artist, seconds: 0, plays: 0)
        if track.title.isEmpty { track.title = title }
        if track.artist.isEmpty { track.artist = artist }
        track.seconds += max(0, seconds)
        track.plays += max(0, plays)
        day[trackID] = track
        byDay[dayKey] = day
    }

    /// 摊平成写进 store 的条目。顺序固定（天 → 曲目 id），同样输入永远产出同一份结果。
    func entries() -> [ListeningStatsEntry] {
        var result: [ListeningStatsEntry] = []

        for dayKey in byDay.keys.sorted() {
            guard let day = byDay[dayKey] else { continue }
            for trackID in day.keys.sorted() {
                guard let track = day[trackID] else { continue }
                result.append(
                    ListeningStatsEntry(
                        dayKey: dayKey,
                        trackID: trackID,
                        title: track.title,
                        artist: track.artist,
                        durationSeconds: 0,
                        seconds: track.seconds,
                        plays: track.plays
                    )
                )
            }
        }

        return result
    }
}
