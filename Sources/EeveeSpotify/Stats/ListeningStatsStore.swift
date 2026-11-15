import Foundation

/// 「听歌统计」的磁盘层。
///
/// 只做一件事：把 `ListeningStatsData` 从 `Application Support/EeveeSpotify/listening-stats.json`
/// 读出来、合并增量、再原子地写回去。
///
/// 三条纪律：
/// · **所有磁盘 I/O 只在 `queue` 这一条串行队列上**：录音器每 30 秒就把增量丢进来，设置页
///   同时可能在读 —— 同一个文件不能有两个写者。串行队列同时也保证了「读 → 合并 → 写」
///   不会互相插队，增量不会丢。
/// · **写盘是原子的**（`Data.write(options: .atomic)`：先写同目录临时文件再 rename）。被
///   强杀时文件要么是旧内容、要么是新内容，不会出现半截 JSON。
/// · 内存里缓存一份，避免每次读写都摸磁盘；`clear` 会连缓存一起清掉。
///
/// 本文件同样是 Foundation-only（回归测试与 model 一起单独编译）。
final class ListeningStatsStore {

    static let shared = ListeningStatsStore()

    /// 文件名（固定，方便「清除数据」和排查时直接看）。
    static let fileName = "listening-stats.json"

    private let queue = DispatchQueue(label: "com.eevee.listening-stats.store", qos: .utility)
    private let fileURL: URL

    /// 只在 `queue` 上访问。
    private var cached: ListeningStatsData?

    /// - Parameter fileURL: 传 nil 用 `Application Support/EeveeSpotify/listening-stats.json`；
    ///   测试传临时目录里的路径，绝不碰 App 容器。
    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
    }

    private static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)

        return base
            .appendingPathComponent("EeveeSpotify", isDirectory: true)
            .appendingPathComponent(fileName)
    }

    // MARK: - 写

    /// 把一批增量排进队列（调用方在任意线程都行；磁盘工作在 `queue` 上）。
    func persist(_ entries: [ListeningStatsEntry]) {
        guard !entries.isEmpty else { return }
        queue.async { self.persistLocked(entries) }
    }

    /// 同步版本：只有测试与「进程即将结束时补一刀」会用到。**不要**在 `queue` 上调用。
    func persistSynchronously(_ entries: [ListeningStatsEntry]) {
        queue.sync { self.persistLocked(entries) }
    }

    private func persistLocked(_ entries: [ListeningStatsEntry]) {
        guard !entries.isEmpty else { return }

        var data = loadLocked()
        for entry in entries {
            data.add(entry)
        }
        data.prune()
        saveLocked(data)
    }

    // MARK: - 读

    /// 异步读一份快照；回调在主线程。
    func snapshot(_ completion: @escaping (ListeningStatsData) -> Void) {
        queue.async {
            let data = self.loadLocked()
            DispatchQueue.main.async { completion(data) }
        }
    }

    /// 同步读：只有测试会用到。**不要**在 `queue` 上调用。
    func loadSynchronously() -> ListeningStatsData {
        queue.sync { self.loadLocked() }
    }

    private func loadLocked() -> ListeningStatsData {
        if let cached { return cached }

        let exists = FileManager.default.fileExists(atPath: fileURL.path)
        guard exists else {
            let empty = ListeningStatsData()
            cached = empty
            return empty
        }

        do {
            let payload = try Data(contentsOf: fileURL)
            let data = try JSONDecoder().decode(ListeningStatsData.self, from: payload)
            cached = data
            return data
        } catch {
            // 文件坏了就按空数据处理并记一行；下一次写入会把它覆盖成一份干净的文件。
            ListeningStatsLog.write("[Stats] load failed: \(error.localizedDescription)")
            let empty = ListeningStatsData()
            cached = empty
            return empty
        }
    }

    // MARK: - 清除

    /// 删掉整份统计（文件 + 内存缓存）；回调在主线程。
    func clear(completion: @escaping () -> Void = {}) {
        queue.async { self.clearLocked(completion: completion) }
    }

    /// 同步清除：只有测试会用到。**不要**在 `queue` 上调用。
    func clearSynchronously() {
        queue.sync { self.clearLocked(completion: {}) }
    }

    private func clearLocked(completion: @escaping () -> Void) {
        cached = ListeningStatsData()

        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                try FileManager.default.removeItem(at: fileURL)
            } catch {
                ListeningStatsLog.write("[Stats] clear failed: \(error.localizedDescription)")
            }
        }

        ListeningStatsLog.write("[Stats] data cleared")

        DispatchQueue.main.async { completion() }
    }

    // MARK: - 落盘

    private func saveLocked(_ data: ListeningStatsData) {
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let payload = try encoder.encode(data)
            try payload.write(to: fileURL, options: .atomic)

            cached = data
        } catch {
            ListeningStatsLog.write("[Stats] flush failed: \(error.localizedDescription)")
        }
    }
}
