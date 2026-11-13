import CoreGraphics
import Foundation

/// 把一条 HLS（`.m3u8`）拉成一个本地文件。
///
/// 为什么需要它：系统给锁屏只认**本地文件 URL**，而 Apple Music 的 `editorialVideo`
/// 给的是 HLS。这里只处理这两家实际会遇到的形态：点播、未加密、fMP4（有 `EXT-X-MAP`）
/// 或单码率分片。遇到加密（`EXT-X-KEY`）直接失败 —— 那种素材本来也放不进锁屏。
enum HLSVideoDownloader {

    struct Failure: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    static func download(
        playlist: URL,
        to destination: URL,
        session: URLSession,
        targetWidth: CGFloat
    ) async throws {
        let master = try await text(playlist, session: session)

        let mediaURL: URL
        let mediaText: String
        if master.contains("#EXT-X-STREAM-INF") {
            mediaURL = try variant(in: master, base: playlist, targetWidth: targetWidth)
            mediaText = try await text(mediaURL, session: session)
        } else {
            mediaURL = playlist
            mediaText = master
        }

        try await assemble(mediaText, base: mediaURL, to: destination, session: session)
    }

    // MARK: - 主播放列表

    /// 从主列表里挑一路码率：优先"宽度不超过目标、且最接近目标"的那路；都比目标宽就挑最窄的。
    private static func variant(in playlist: String, base: URL, targetWidth: CGFloat) throws -> URL {
        let lines = playlist
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        var candidates: [(url: URL, width: CGFloat)] = []
        for (index, line) in lines.enumerated() where line.hasPrefix("#EXT-X-STREAM-INF:") {
            let uriIndex = index + 1
            guard uriIndex < lines.count else { continue }
            let uri = lines[uriIndex]
            guard !uri.isEmpty, !uri.hasPrefix("#"),
                  let url = URL(string: uri, relativeTo: base)?.absoluteURL else {
                continue
            }
            let attributes = attributes(of: line)
            let width = attributes["RESOLUTION"]
                .flatMap { $0.split(separator: "x").first }
                .flatMap { Double($0) }
                .map { CGFloat($0) } ?? 0
            candidates.append((url, width))
        }

        guard !candidates.isEmpty else {
            throw Failure(reason: "the master playlist lists no variant")
        }

        let capped = candidates.filter { $0.width > 0 && $0.width <= targetWidth }
        if let best = capped.max(by: { $0.width < $1.width }) {
            return best.url
        }
        if let smallest = candidates.filter({ $0.width > 0 }).min(by: { $0.width < $1.width }) {
            return smallest.url
        }
        return candidates[0].url
    }

    // MARK: - 媒体播放列表

    private static func assemble(
        _ playlist: String,
        base: URL,
        to destination: URL,
        session: URLSession
    ) async throws {
        var initSegment: (url: URL, range: Range<Int>?)?
        var segments: [(url: URL, range: Range<Int>?)] = []
        var pendingRange: Range<Int>?
        var lastRangeEnd = 0

        for raw in playlist.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("#EXT-X-KEY") {
                let method = attributes(of: line)["METHOD"]?.uppercased() ?? ""
                if !method.isEmpty, method != "NONE" {
                    throw Failure(reason: "encrypted playlist (\(method))")
                }
                continue
            }

            if line.hasPrefix("#EXT-X-MAP:") {
                let attributes = attributes(of: line)
                if let uri = attributes["URI"],
                   let url = URL(string: uri, relativeTo: base)?.absoluteURL {
                    let range = byteRange(attributes["BYTERANGE"], start: lastRangeEnd)
                    initSegment = (url, range)
                    if let range { lastRangeEnd = range.upperBound }
                }
                continue
            }

            if line.hasPrefix("#EXT-X-BYTERANGE:") {
                pendingRange = byteRange(
                    String(line.dropFirst("#EXT-X-BYTERANGE:".count)),
                    start: lastRangeEnd
                )
                if let pendingRange { lastRangeEnd = pendingRange.upperBound }
                continue
            }

            if line.hasPrefix("#") { continue }

            guard let url = URL(string: line, relativeTo: base)?.absoluteURL else { continue }
            segments.append((url, pendingRange))
            pendingRange = nil
        }

        guard !segments.isEmpty else {
            throw Failure(reason: "the media playlist has no segment")
        }

        // 目标路径按 UUID 生成，正常不会存在；这里只是保证写的时候是空文件。
        try? FileManager.default.removeItem(at: destination)
        _ = FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }

        if let initSegment {
            try await append(initSegment.url, range: initSegment.range, to: handle, session: session)
        }
        for segment in segments {
            if Task.isCancelled {
                throw Failure(reason: "cancelled")
            }
            try await append(segment.url, range: segment.range, to: handle, session: session)
        }
    }

    /// `"length@offset"` 或 `"length"`（offset 接着上一段）。
    private static func byteRange(_ text: String?, start: Int) -> Range<Int>? {
        guard let text, !text.isEmpty else { return nil }
        let parts = text.split(separator: "@")
        guard let length = parts.first.flatMap({ Int($0) }), length > 0 else { return nil }
        let offset = parts.count > 1 ? (Int(parts[1]) ?? start) : start
        return offset..<(offset + length)
    }

    private static func append(
        _ url: URL,
        range: Range<Int>?,
        to handle: FileHandle,
        session: URLSession
    ) async throws {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        if let range {
            request.setValue(
                "bytes=\(range.lowerBound)-\(range.upperBound - 1)",
                forHTTPHeaderField: "Range"
            )
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw Failure(reason: "segment \(url.lastPathComponent) failed")
        }
        guard !data.isEmpty else {
            throw Failure(reason: "segment \(url.lastPathComponent) is empty")
        }
        try handle.write(contentsOf: data)
    }

    // MARK: - 工具

    private static func text(_ url: URL, session: URLSession) async throws -> String {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw Failure(reason: "playlist \(url.lastPathComponent) failed")
        }
        guard let text = String(data: data, encoding: .utf8), text.contains("#EXTM3U") else {
            throw Failure(reason: "playlist \(url.lastPathComponent) is not HLS")
        }
        return text
    }

    /// 解析 `KEY=VALUE,KEY="VALUE,WITH,COMMAS"`。只服务本文件的三种标签。
    private static func attributes(of line: String) -> [String: String] {
        var body = line
        if let colon = body.firstIndex(of: ":") {
            body = String(body[body.index(after: colon)...])
        }

        var result: [String: String] = [:]
        var key = ""
        var value = ""
        var inQuotes = false
        var readingKey = true

        for character in body {
            if character == "\"" {
                inQuotes.toggle()
                continue
            }
            if character == "=" && !inQuotes && readingKey {
                readingKey = false
                continue
            }
            if character == "," && !inQuotes {
                if !key.isEmpty {
                    result[key.trimmingCharacters(in: .whitespaces)] = value
                }
                key = ""
                value = ""
                readingKey = true
                continue
            }
            if readingKey {
                key.append(character)
            } else {
                value.append(character)
            }
        }

        if !key.isEmpty {
            result[key.trimmingCharacters(in: .whitespaces)] = value
        }
        return result
    }
}
