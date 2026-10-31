import Compression
import Foundation

/// zlib 流的解压 —— 酷狗 KRC 与 QQ 音乐 QRC 共用。
///
/// ── 为什么不用 `zlib.h`
/// Theos 的 Swift 构建没有桥接头，`#import <zlib.h>` 用不了。`Compression` 是系统框架，
/// `import Compression` 即可（本仓库已经在用 `CommonCrypto`，同样是系统框架）。
///
/// ── 一个必须知道的坑
/// Apple 的 `COMPRESSION_ZLIB` 吃的是**裸 DEFLATE**（RFC 1951），
/// 而这两家给的都是**带 zlib 头尾的**流（RFC 1950：2 字节头 + DEFLATE + 4 字节 adler32）。
/// 所以要先剥掉头尾，否则 `compression_decode_buffer` 永远返回 0。
/// 头两字节的判断：CMF 的低 4 位是压缩方法（8 = deflate），且 `(CMF << 8 | FLG) % 31 == 0`。
enum ZlibInflate {

    /// 解压上限。歌词只有几 KB，超过这个数的一律当坏数据 —— 防止一个畸形响应把内存打满。
    static let defaultLimit = 1 << 20

    /// 输入是 zlib 流（有无头都能处理），输出是原始字节。失败返回 nil。
    static func inflate(_ stream: [UInt8], limit: Int = defaultLimit) -> Data? {
        guard stream.count > 6 else { return nil }

        let looksZlib = (stream[0] & 0x0F) == 8
            && ((Int(stream[0]) << 8) | Int(stream[1])) % 31 == 0
        let body = looksZlib ? Array(stream.dropFirst(2).dropLast(4)) : stream
        guard !body.isEmpty else { return nil }

        // 输出缓冲从小往大试：`compression_decode_buffer` 返回 0 既可能是"出错"，
        // 也可能是"装不下"，所以只有**严格小于容量**的返回值才算成功。
        var capacity = 64 * 1024
        while capacity <= limit {
            var output = [UInt8](repeating: 0, count: capacity)
            let written = body.withUnsafeBufferPointer { inputBuffer -> Int in
                output.withUnsafeMutableBufferPointer { outputBuffer -> Int in
                    compression_decode_buffer(
                        outputBuffer.baseAddress!, outputBuffer.count,
                        inputBuffer.baseAddress!, inputBuffer.count,
                        nil, COMPRESSION_ZLIB
                    )
                }
            }
            if written > 0, written < capacity {
                return Data(output[0..<written])
            }
            if written < capacity { return nil }
            capacity *= 4
        }
        return nil
    }

    static func inflate(_ stream: Data, limit: Int = defaultLimit) -> Data? {
        inflate([UInt8](stream), limit: limit)
    }
}
