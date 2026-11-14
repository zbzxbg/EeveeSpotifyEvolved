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

    /// 片段**画法**的版本。画布朝向、字号这类"同一行文字但像素不同"的改动必须进哈希：
    /// 文件名与 `artworkID` 只由它和文案决定，不换版本就会继续复用按老画法渲好的文件。
    private static let clipFormat = "v3"

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

    /// 一段片子画的其实是"这一行 + 压暗的下一行 + 底沿署名"。换歌词来源之后文案会变，
    /// 而 trackKey 不变；封面缺失时渲出来的是深色底，补到封面之后也应该重渲一份 ——
    /// 所以帧的内容（含有没有封面、以及 `clipFormat`）都要进文件名/ID。
    static func frameHash(
        line: String?,
        next: String?,
        credit: String,
        hasCover: Bool,
        textScale: Double,
        spacingScale: Double
    ) -> String {
        FNV1a.hex(
            "\(clipFormat)|\(line ?? "")|\(next ?? "")|\(credit)|\(hasCover ? "c" : "n")"
                + "|\(scaleKey(textScale))|\(scaleKey(spacingScale))"
        )
    }

    /// 倍率进哈希时的小数口径：两位小数足够区分设置页的可选档位（0.05 一档），
    /// 也不会因为浮点尾数把同一档算成两个名字。
    private static func scaleKey(_ value: Double) -> String {
        String(format: "%.2f", value)
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

    /// 只留**当前这首 + 最近用过的两首**的目录。
    ///
    /// 为什么不"除当前这首全删"：① 系统手里的视频 URL 在 artwork 还挂在 now-playing 上时
    /// 必须有效，刚被替换掉的那一版可能还在用；② 正在写的片段会被删；③ A→B→A 会整首重渲。
    static func trimCache(keeping trackKey: String) {
        DispatchQueue.global(qos: .utility).async {
            let root = cacheDirectory
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: []
            ) else {
                return
            }
            let sorted = entries.sorted { left, right in
                let leftDate = (try? left.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? Date.distantPast
                let rightDate = (try? right.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? Date.distantPast
                return leftDate > rightDate
            }
            var keptOthers = 0
            var kept: [URL] = [root.appendingPathComponent(trackKey, isDirectory: true)]
            for entry in sorted where entry.lastPathComponent != trackKey {
                keptOthers += 1
                if keptOthers > 2 {
                    try? FileManager.default.removeItem(at: entry)
                } else {
                    kept.append(entry)
                }
            }

            // 崩溃/中断留下的临时片段（写成功会改名，没改名的一律作废）。
            for directory in kept {
                guard let files = try? FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: nil,
                    options: []
                ) else { continue }
                for file in files where file.lastPathComponent.hasPrefix("writing-") {
                    try? FileManager.default.removeItem(at: file)
                }
            }
        }
    }

    /// 设置页的"清除"：全删。调用方（`LockScreenLyricsController.purgeCache`）会同时撤掉
    /// 已经装出去的 artwork，所以不存在"系统还指着一个被删掉的文件"。
    static func clearCache() {
        try? FileManager.default.removeItem(at: cacheDirectory)
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
}

/// 一行带时间轴的歌词。时间戳是整首歌的毫秒数，与 `LyricsLineDto` 同一口径。
struct LockScreenLyricLine: Equatable {
    var startMs: Int
    /// 这一句**唱完**的时刻（没有 `endOffsetMs` 时用下一行的起点兜底）。
    var endMs: Int
    var text: String
}
