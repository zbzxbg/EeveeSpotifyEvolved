import Foundation
import UIKit

/// 锁屏短片的磁盘缓存。
///
/// 系统只接受**本地文件 URL**，而且同一个 `artworkID` 的素材它会反复要（锁屏进出、
/// 切到别的 App 再回来）。所以下载一次就落盘，第二次直接给路径。
///
/// 目录在 `Caches` 下：系统清缓存时跟着走，不进 iCloud 备份，也不占用户的存储配额。
/// 每条缓存是一段 mp4 + 一张首帧 jpg；两者共用同一个 key，清理时一起算。
enum AnimatedArtworkCache {

    private static let folderName = "EeveeLockScreenArtwork"
    private static let videoExtension = "mp4"
    private static let previewExtension = "jpg"

    static var directory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appendingPathComponent(folderName, isDirectory: true)
    }

    /// 一首歌 + 时长 + 一个画幅 = 一条缓存。时长进 key 是为了把同名不同版本（Live /
    /// Remaster）分开；不含来源：同一首歌的 Canvas 和 Apple Music 短片都满足"锁屏上
    /// 动起来"，谁先拿到就用谁，没必要各存一份。
    static func key(
        title: String,
        artist: String,
        duration: Double,
        aspect: LockScreenArtwork.Aspect
    ) -> String {
        let seed = "\(title)|\(artist)|\(Int(duration.rounded()))|\(aspect.cacheKeySuffix)"
        return FNV1a.hex(seed)
    }

    static func existing(key: String) -> URL? {
        let url = directory.appendingPathComponent(key).appendingPathExtension(videoExtension)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              size.int64Value > 0 else {
            return nil
        }
        touch(url)
        return url
    }

    /// 把下载/渲染好的临时文件挪进缓存目录。同一 key 已存在时以新文件为准。
    static func store(_ temporaryURL: URL, key: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(key).appendingPathExtension(videoExtension)
        if FileManager.default.fileExists(atPath: destination.path) {
            try? FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        return destination
    }

    static func preview(key: String) -> UIImage? {
        let url = directory.appendingPathComponent(key).appendingPathExtension(previewExtension)
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        touch(url)
        return image
    }

    static func storePreview(_ image: UIImage, key: String) {
        guard let data = image.jpegData(compressionQuality: 0.9) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(key).appendingPathExtension(previewExtension)
        try? data.write(to: url, options: .atomic)
    }

    static func totalBytes() -> Int64 {
        entries().reduce(into: Int64(0)) { $0 += $1.size }
    }

    /// 超上限时按"最久没被系统要过"删。每次命中都会刷新修改时间，所以它近似于 LRU。
    static func trimIfNeeded() {
        let files = entries()
        var total = files.reduce(into: Int64(0)) { $0 += $1.size }
        guard total > LockScreenArtwork.cacheByteLimit else { return }

        for entry in files.sorted(by: { $0.date < $1.date }) {
            guard total > LockScreenArtwork.cacheByteLimit else { break }
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.size
        }

        writeDebugLog(
            "[\(LockScreenArtwork.logTag)] cache trimmed to \(total / 1024 / 1024) MB"
        )
    }

    static func clear() {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - 工具

    private static func touch(_ url: URL) {
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: url.path
        )
    }

    private static func entries() -> [(url: URL, size: Int64, date: Date)] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return files.compactMap { url in
            guard let values = try? url.resourceValues(
                forKeys: [.fileSizeKey, .contentModificationDateKey]
            ) else {
                return nil
            }
            return (
                url: url,
                size: Int64(values.fileSize ?? 0),
                date: values.contentModificationDate ?? .distantPast
            )
        }
    }
}
