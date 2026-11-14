import Foundation

/// Spotify `canvaz-cache` 接口的最小 protobuf 编解码。
///
/// 只覆盖这条接口用到的三层：
/// · 请求 `EntityCanvazRequest { repeated Entity entities = 1; }`，`Entity { string entity_uri = 1; }`
/// · 响应 `EntityCanvazResponse { repeated Canvaz canvases = 1; }`
/// · `Canvaz { string id = 1; string url = 2; string file_id = 3; int32 type = 4; }`
///
/// 为什么单独一个文件、不引用任何 App 内类型：这条链路的唯一失败模式是**字段号写错**，
/// 而写错时接口照样 200、只是解析不出 URL（静默没动态封面）。把编解码隔离成纯 Foundation，
/// CI 就能在没有 UIKit / Theos 的机器上直接编译它，并用固定字节钉住形状。
enum SpotifyCanvasProto {

    struct Canvas {
        let identifier: String
        let url: String
        /// `1...3` 是视频；`0` 表示接口没给（按非视频处理）。
        let type: Int

        var isVideo: Bool { (1...3).contains(type) }
    }

    // MARK: - 请求

    static func requestBody(entityURI: String) -> Data {
        let entity = Data()
            .appending(field: 1, string: entityURI)
        return Data()
            .appending(field: 1, message: entity)
    }

    // MARK: - 响应

    static func parseResponse(_ data: Data) -> Canvas? {
        // `canvases` 是 repeated：取第一条能解析出 url 的。
        for field in fields(in: data) where field.number == 1 && field.wire == 2 {
            guard let canvas = parseCanvas(field.payload) else { continue }
            return canvas
        }
        return nil
    }

    private static func parseCanvas(_ data: Data) -> Canvas? {
        var identifier = ""
        var url = ""
        var fileID = ""
        var type = 0
        for field in fields(in: data) {
            switch field.number {
            case 1: identifier = String(decoding: field.payload, as: UTF8.self)
            case 2: url = String(decoding: field.payload, as: UTF8.self)
            case 3: fileID = String(decoding: field.payload, as: UTF8.self)
            case 4: type = Int(field.varint)
            default: break
            }
        }
        guard !url.isEmpty else { return nil }
        return Canvas(
            identifier: identifier.isEmpty ? fileID : identifier,
            url: url,
            type: type
        )
    }
}

// MARK: - 最小 protobuf 原语

private struct ParsedField {
    let number: Int
    let wire: Int
    let varint: UInt64
    let payload: Data
}

private func fields(in data: Data) -> [ParsedField] {
    var result: [ParsedField] = []
    var index = data.startIndex
    while index < data.endIndex {
        guard let (tag, afterTag) = readVarint(data, from: index) else { return result }
        index = afterTag
        let number = Int(tag >> 3)
        let wire = Int(tag & 0x07)
        switch wire {
        case 0:
            guard let (value, after) = readVarint(data, from: index) else { return result }
            index = after
            result.append(
                ParsedField(number: number, wire: wire, varint: value, payload: Data())
            )
        case 2:
            guard let (length, after) = readVarint(data, from: index),
                  length <= UInt64(data.distance(from: after, to: data.endIndex)) else {
                return result
            }
            let end = data.index(after, offsetBy: Int(length))
            result.append(
                ParsedField(number: number, wire: wire, varint: 0, payload: data[after..<end])
            )
            index = end
        case 1:
            guard data.distance(from: index, to: data.endIndex) >= 8 else { return result }
            index = data.index(index, offsetBy: 8)
        case 5:
            guard data.distance(from: index, to: data.endIndex) >= 4 else { return result }
            index = data.index(index, offsetBy: 4)
        default:
            // 3/4 是已废弃的 group 编码，这条接口不用；遇到就停，避免读串。
            return result
        }
    }
    return result
}

private func readVarint(_ data: Data, from start: Data.Index) -> (UInt64, Data.Index)? {
    var value: UInt64 = 0
    var shift: UInt64 = 0
    var index = start
    while index < data.endIndex {
        let byte = data[index]
        value |= UInt64(byte & 0x7F) << shift
        index = data.index(after: index)
        if byte & 0x80 == 0 { return (value, index) }
        shift += 7
        if shift > 63 { return nil }
    }
    return nil
}

private func varintBytes(_ value: UInt64) -> Data {
    var value = value
    var out = Data()
    repeat {
        var byte = UInt8(value & 0x7F)
        value >>= 7
        if value != 0 { byte |= 0x80 }
        out.append(byte)
    } while value != 0
    return out
}

private extension Data {
    /// 追加一个 length-delimited 字段：`tag = (number << 3) | 2`。
    func appending(field number: Int, string: String) -> Data {
        var data = self
        let text = Data(string.utf8)
        data.append(contentsOf: varintBytes(UInt64(number << 3 | 2)))
        data.append(contentsOf: varintBytes(UInt64(text.count)))
        data.append(text)
        return data
    }

    func appending(field number: Int, message: Data) -> Data {
        var data = self
        data.append(contentsOf: varintBytes(UInt64(number << 3 | 2)))
        data.append(contentsOf: varintBytes(UInt64(message.count)))
        data.append(message)
        return data
    }
}
