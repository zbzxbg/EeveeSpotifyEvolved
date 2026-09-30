import Foundation

// Off-by-default debug probe: dumps /casita/ and /browsita/ response bodies
// to the app tmp dir and logs the first 256 bytes as hex. Flip `enabled` to
// inspect new ad surfaces, then flip back before shipping.
//
// ⚠️ 2026-09-30：`enabled = false` 是默认值，**别在发布构建里打开**。打开时它会把
// 整份响应体（首页 feed 之类，含用户内容）原样写到 tmp —— 那些 `.bin` 文件**不经过**
// `DebugLogSanitizer`，脱敏只覆盖日志行。日志行本身走 `eeveeSanitizedNSLog`，
// 所以至少路径与 URL 是安全的。
enum CasitaResponseProbe {
    static var enabled: Bool = false

    private static let lock = NSLock()
    private static var buffers: [Int: Data] = [:]
    private static var dumpDirReady = false
    private static var sequence: Int = 0

    static func shouldProbe(_ url: URL) -> Bool {
        guard enabled else { return false }
        let p = url.path.lowercased()
        return p.contains("/casita/") || p.contains("/browsita/")
    }

    static func append(_ data: Data, for task: URLSessionTask) {
        lock.lock(); defer { lock.unlock() }
        buffers[task.taskIdentifier, default: Data()].append(data)
    }

    static func flush(_ task: URLSessionTask, url: URL) {
        lock.lock()
        let data = buffers.removeValue(forKey: task.taskIdentifier)
        sequence += 1
        let seq = sequence
        lock.unlock()
        guard let body = data, !body.isEmpty else {
            eeveeSanitizedNSLog("[CASITA] \(url.path) <no-body>")
            return
        }

        let dir = ensureDumpDir()
        let slug = url.path.replacingOccurrences(of: "/", with: "_")
        let filename = "\(String(format: "%03d", seq))\(slug).bin"
        let fullPath = (dir as NSString).appendingPathComponent(filename)
        do {
            try body.write(to: URL(fileURLWithPath: fullPath))
        } catch {
            eeveeSanitizedNSLog("[CASITA] write-failed \(fullPath): \(error)")
        }

        let hex = body.prefix(256).map { String(format: "%02x", $0) }.joined()
        eeveeSanitizedNSLog("[CASITA] \(url.path) size=\(body.count) dump=\(fullPath)")
        // ⚠️ 这一行是**响应体的 hex**，脱敏规则对它无能为力（本来也认不出内容）。
        // 它存在的唯一理由是"看清新广告位长什么样"，见文件头那段警告。
        eeveeSanitizedNSLog("[CASITA][HEX] \(hex)")
    }

    private static func ensureDumpDir() -> String {
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("eevee_casita")
        if !dumpDirReady {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            dumpDirReady = true
            eeveeSanitizedNSLog("[CASITA] dump dir = \(dir)")
        }
        return dir
    }
}
