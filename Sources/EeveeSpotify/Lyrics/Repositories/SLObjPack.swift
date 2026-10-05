import Foundation

// MARK: - SLObjPack decoder
//
// Swift port of the SLObjPack unpack() function from
// spicetify-extension-main/src/utils/objpack.ts
//
// Wire format: the JSON-decoded value is a two-element array:
//   [ valuesList: [primitive...], stream: [number...] ]
//
// Opcodes in stream:
//   n >= 0  → pointer into valuesList (returns a primitive)
//   -1      → object:  next slot = key count N, then N key pointers, then N decoded values
//   -2      → array:   next slot = item count N, then N decoded values
//   -3      → schema array: next slot = item count N, next = key count K,
//              then K key pointers, then N*K decoded values (batch of same-schema objects)
//   -4      → empty array []
//   -5      → single-element array: [ decode() ]
//   -6      → empty object {}

enum SLObjPackValue {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([SLObjPackValue])
    case object([String: SLObjPackValue])
}

enum SLObjPackError: Error {
    case invalidPayloadStructure
    case invalidValuesList
    case nonFiniteNumber
    case unexpectedEndOfStream
    case invalidPointer
    case keyMustBeString
    case forbiddenKey
    case invalidCount
    case streamOverflow
    case maxDepthExceeded
    case invalidOpcode
    case trailingData
}

struct SLObjPack {

    private static let maxDepth      = 512
    private static let maxArrayLen   = 1 << 20
    private static let maxObjectKeys = 1 << 16
    private static let maxStreamLen  = 1 << 24
    private static let maxValuesLen  = 1 << 22
    private static let maxDecodeOps  = 1 << 22

    private static let forbiddenKeys: Set<String> = ["__proto__", "constructor", "prototype"]

    /// Entry point: pass the already-JSON-decoded top-level value from the API response's
    /// `data` field (which must be a two-element array as described above).
    static func unpack(_ raw: Any) throws -> SLObjPackValue {
        guard
            let outer = raw as? [Any],
            outer.count == 2,
            let valuesRaw = outer[0] as? [Any],
            let streamRaw = outer[1] as? [Any]
        else {
            throw SLObjPackError.invalidPayloadStructure
        }

        guard valuesRaw.count <= maxValuesLen else { throw SLObjPackError.invalidPayloadStructure }
        guard streamRaw.count <= maxStreamLen  else { throw SLObjPackError.invalidPayloadStructure }

        // Validate and convert valuesList entries (must be primitives)
        var valuesList = [SLObjPackValue?]()
        valuesList.reserveCapacity(valuesRaw.count)
        for v in valuesRaw {
            switch v {
            case is NSNull:
                valuesList.append(.null)
            case let b as Bool:
                valuesList.append(.bool(b))
            case let n as NSNumber:
                let d = n.doubleValue
                guard d.isFinite else { throw SLObjPackError.nonFiniteNumber }
                valuesList.append(.number(d))
            case let s as String:
                valuesList.append(.string(s))
            default:
                throw SLObjPackError.invalidValuesList
            }
        }

        // Convert stream to Int array (all entries must be integers)
        var stream = [Int]()
        stream.reserveCapacity(streamRaw.count)
        for entry in streamRaw {
            guard let n = entry as? NSNumber else { throw SLObjPackError.invalidPayloadStructure }
            let i = n.intValue
            stream.append(i)
        }

        var cursor = 0
        let streamLen  = stream.count
        let valuesLen  = valuesList.count

        func readStream() throws -> Int {
            guard cursor < streamLen else { throw SLObjPackError.unexpectedEndOfStream }
            defer { cursor += 1 }
            return stream[cursor]
        }

        func resolvePointer(_ ptr: Int) throws -> SLObjPackValue {
            guard ptr >= 0, ptr < valuesLen, let v = valuesList[ptr] else {
                throw SLObjPackError.invalidPointer
            }
            return v
        }

        func readKey() throws -> String {
            let ptr  = try readStream()
            let val  = try resolvePointer(ptr)
            guard case .string(let s) = val else { throw SLObjPackError.keyMustBeString }
            guard !forbiddenKeys.contains(s)  else { throw SLObjPackError.forbiddenKey }
            return s
        }

        func validateCount(_ n: Int, max: Int) throws {
            guard n >= 0, n <= max else { throw SLObjPackError.invalidCount }
        }

        func requireStream(_ min: Int) throws {
            guard min <= streamLen - cursor else { throw SLObjPackError.streamOverflow }
        }

        func decode(depth: Int) throws -> SLObjPackValue {
            guard depth <= maxDepth else { throw SLObjPackError.maxDepthExceeded }

            let op = try readStream()

            // Positive or zero → value pointer
            if op >= 0 {
                return try resolvePointer(op)
            }

            switch op {
            case -1: // object
                let numKeys = try readStream()
                try validateCount(numKeys, max: maxObjectKeys)
                try requireStream(numKeys * 2)
                var keys = [String]()
                keys.reserveCapacity(numKeys)
                for _ in 0 ..< numKeys { keys.append(try readKey()) }
                var obj = [String: SLObjPackValue]()
                for key in keys { obj[key] = try decode(depth: depth + 1) }
                return .object(obj)

            case -2: // generic array
                let numItems = try readStream()
                try validateCount(numItems, max: maxArrayLen)
                try requireStream(numItems)
                var arr = [SLObjPackValue]()
                arr.reserveCapacity(numItems)
                for _ in 0 ..< numItems { arr.append(try decode(depth: depth + 1)) }
                return .array(arr)

            case -3: // schema array (all items share the same keys)
                let numItems = try readStream()
                try validateCount(numItems, max: maxArrayLen)
                let numKeys  = try readStream()
                try validateCount(numKeys,  max: maxObjectKeys)
                guard numItems * numKeys <= maxDecodeOps else { throw SLObjPackError.invalidCount }
                try requireStream(numKeys + numItems * numKeys)
                var keys = [String]()
                keys.reserveCapacity(numKeys)
                for _ in 0 ..< numKeys { keys.append(try readKey()) }
                var arr = [SLObjPackValue]()
                arr.reserveCapacity(numItems)
                for _ in 0 ..< numItems {
                    var obj = [String: SLObjPackValue]()
                    for key in keys { obj[key] = try decode(depth: depth + 1) }
                    arr.append(.object(obj))
                }
                return .array(arr)

            case -4: return .array([])          // empty array
            case -5: return .array([try decode(depth: depth + 1)])  // single-element array
            case -6: return .object([:])         // empty object

            default:
                throw SLObjPackError.invalidOpcode
            }
        }

        let result = try decode(depth: 0)

        guard cursor == streamLen else { throw SLObjPackError.trailingData }

        return result
    }
}

// MARK: - Convenience accessors

extension SLObjPackValue {
    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
    var doubleValue: Double? {
        if case .number(let d) = self { return d }
        return nil
    }
    var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }
    var arrayValue: [SLObjPackValue]? {
        if case .array(let a) = self { return a }
        return nil
    }
    var objectValue: [String: SLObjPackValue]? {
        if case .object(let o) = self { return o }
        return nil
    }
    subscript(key: String) -> SLObjPackValue? {
        objectValue?[key]
    }
    subscript(index: Int) -> SLObjPackValue? {
        guard let arr = arrayValue, index < arr.count else { return nil }
        return arr[index]
    }
}

// MARK: - Plain JSON → SLObjPackValue

extension SLObjPackValue {
    /// 把**普通 JSON** 树搬成 `SLObjPackValue`。
    ///
    /// 为什么需要它：官方 v1 API（`GET /v1/lyrics/<id>`）返回的是普通 JSON，
    /// 而旧 `/query` 的内层是 SLObjPack 打包格式（见上面的 `unpack`）。三条歌词解析路径
    /// （Syllable / Line / Static）都吃 `SLObjPackValue`，所以在这一层做一次转换，
    /// 而不是为 v1 再写第二套解析器。
    static func fromJSON(_ raw: Any) -> SLObjPackValue {
        switch raw {
        case is NSNull:
            return .null
        case let value as [Any]:
            return .array(value.map(fromJSON))
        case let value as [String: Any]:
            return .object(value.mapValues(fromJSON))
        case let value as String:
            return .string(value)
        case let value as NSNumber:
            // ⚠️ JSON 的 `true` / `false` 在 Darwin 上也是 NSNumber（`__NSCFBoolean`，
            // objCType 是 "c"）。不区分的话有两个方向的错：把 `IsPartOfWord: 1` 当成
            // 数字（逐词断句全错），或者把 `StartTime: 1` 这种整数值当成布尔
            // （`doubleValue` 拿到 nil，那一行就丢了时间轴）。用 objCType 分开。
            let objcType = String(cString: value.objCType)
            if objcType == "c" || objcType == "B" {
                return .bool(value.boolValue)
            }
            return .number(value.doubleValue)
        default:
            return .null
        }
    }
}
