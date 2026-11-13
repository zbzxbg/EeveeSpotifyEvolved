import CoreGraphics
import Foundation

/// 锁屏全屏封面区的逐行歌词。
///
/// 锁屏那一块画面是**系统**画的，App 没有任何机会往上挂子视图；唯一能交给它的东西是
/// Now Playing 里的「动态封面」—— 一个本地视频文件（见 `LockScreenArtwork`）。所以这里的
/// 做法是**一行一段片子**：换行就换文件、换 `artworkID`，系统会重新来要素材。
///
/// 这一层只管"一行是什么、文件放哪、键叫什么"；画由 `LyricClipRenderer` 做，
/// 调度由 `LockScreenLyricsController` 做。
enum LockScreenLyrics {

    static let logTag = "LockLyrics"

    /// 一句唱完之后这么久、且下一句还远，就只留压暗的下一行（间奏/换段）。
    /// 不留的话，间奏里上一句会一直钉在锁屏上。
    static let breakMs: Int = 4000

    /// 单行片子的时长。单帧编码与时长无关（文件里只有一帧），给足时间只是为了
    /// 系统不循环播放时也不会在句中被抽走：换行本来由定时器负责。
    static let longestClipSeconds: Double = 30
    static let shortestClipSeconds: Double = 6

    static var isEnabled: Bool { UserDefaults.lockScreenLyrics }

    // MARK: - 缓存

    static var cacheDirectory: URL {
        FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EeveeLockScreenLyrics", isDirectory: true)
    }

    static func cacheDirectory(for trackKey: String) -> URL {
        cacheDirectory.appendingPathComponent(trackKey, isDirectory: true)
    }

    /// 一首歌的稳定标识。标题 / 艺人 / 时长一起哈希 —— 切走再切回来时还能命中
    /// 上一次渲染好的片段，也不会和别的歌撞车。
    static func trackKey(title: String, artist: String, duration: Double) -> String {
        FNV1a.hex("\(title)|\(artist)|\(Int(duration.rounded()))")
    }

    /// 一段片子画的其实是"这一行 + 压暗的下一行"。换歌词来源之后同一首歌同一行的文案会变，
    /// 而 trackKey 不变 —— 所以帧的内容也要进文件名/ID，否则会把旧文案的片段再拿出来。
    static func frameHash(line: String?, next: String?) -> String {
        FNV1a.hex("\(line ?? "")|\(next ?? "")")
    }

    /// 一段片子的文件名。画幅与"间奏态"都要进来：同一行的两种形态是两份文件。
    static func clipFileName(
        lineIndex: Int,
        resting: Bool,
        aspect: LockScreenArtwork.Aspect,
        frameHash: String
    ) -> String {
        "\(lineIndex)\(resting ? "r" : "")-\(aspect.rawValue)-\(frameHash).mp4"
    }

    /// 系统拿 `artworkID` 判断"这个素材我是不是已经有"，所以它必须**跟着行**变，
    /// 又必须在同一行同一文案上稳定。带上画幅与帧哈希：方版与竖版是两个文件，
    /// 文案变了就是另一份素材。
    static func artworkID(
        trackKey: String,
        lineIndex: Int,
        resting: Bool,
        aspect: LockScreenArtwork.Aspect,
        frameHash: String
    ) -> String {
        "eevee.lyrics.\(trackKey).\(lineIndex)\(resting ? "r" : "")-\(frameHash).\(aspect.rawValue)"
    }

    /// 只留当前这一首的目录。一行一段、一轨几十上百段，不清理的话会一直堆在 Caches 里。
    static func trimCache(keeping trackKey: String) {
        DispatchQueue.global(qos: .utility).async {
            let root = cacheDirectory
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil,
                options: []
            ) else {
                return
            }
            for entry in entries where entry.lastPathComponent != trackKey {
                try? FileManager.default.removeItem(at: entry)
            }
        }
    }

    static func totalBytes() -> Int64 {
        let root = cacheDirectory
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.fileSizeKey],
            options: []
        ) else {
            return 0
        }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]) else {
                continue
            }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    static func clearCache() {
        try? FileManager.default.removeItem(at: cacheDirectory)
    }
}

/// 一行带时间轴的歌词。时间戳是整首歌的毫秒数，与 `LyricsLineDto` 同一口径。
struct LockScreenLyricLine: Equatable {
    var startMs: Int
    /// 这一句**唱完**的时刻（没有 `endOffsetMs` 时用下一行的起点兜底）。
    var endMs: Int
    var text: String
}
