import Foundation

/// `SpotifyCanvasProto` 的断言程序（纯 Foundation，CI 跑；见 `.github/workflows/tests.yml`）。
///
/// 为什么必须钉这一份：`canvaz-cache` 的字段号写错时接口照样 200，只是**静默解析不出 URL**，
/// 表现是"锁屏动态封面突然没有 Canvas 了" —— 没有任何报错可查。本机没有 Swift 工具链，
/// 所以这里就是这段编解码唯一的自动判据。
///
/// 钉两件事：
/// ① 请求体必须逐字节等于 `EntityCanvazRequest{ entities:{ entity_uri } }` 的编码；
/// ② 响应体必须是 `EntityCanvazResponse{ canvases:{ id, url, file_id, type } }` 的形状，
///    并且 `type` 只有 1...3 才算视频。

var failures = 0

func require(_ condition: Bool, _ message: String) {
    if condition {
        print("  ok   \(message)")
    } else {
        failures += 1
        print("  FAIL \(message)")
    }
}

// MARK: - ① 请求体

let uri = "spotify:track:abc"
let body = SpotifyCanvasProto.requestBody(entityURI: uri)
// 外层：0A <len> 里层：0A <len> <uri>
//   "spotify:track:abc" = 17 字节 = 0x11 ⇒ 里层 19 字节 = 0x13
let expected = Data([0x0A, 0x13, 0x0A, 0x11] + Array(uri.utf8))
require(body == expected, "request body is EntityCanvazRequest{ entities:{ entity_uri } }")
require(body.count == 21, "request body length matches the nested lengths")

// MARK: - ② 响应体

func lengthDelimited(_ number: Int, _ payload: Data) -> Data {
    var data = Data([UInt8(number << 3 | 2)])
    var count = payload.count
    while true {
        var byte = UInt8(count & 0x7F)
        count >>= 7
        if count != 0 {
            byte |= 0x80
            data.append(byte)
            continue
        }
        data.append(byte)
        break
    }
    data.append(payload)
    return data
}

func stringField(_ number: Int, _ text: String) -> Data {
    lengthDelimited(number, Data(text.utf8))
}

let url = "https://a.b/c.mp4"
var canvaz = Data()
canvaz.append(stringField(1, "id1"))
canvaz.append(stringField(2, url))
canvaz.append(stringField(3, "f1"))
canvaz.append(contentsOf: [0x20, 0x01]) // type = 1（视频）
let response = lengthDelimited(1, canvaz)

let parsed = SpotifyCanvasProto.parseResponse(response)
require(parsed?.url == url, "response url is read from field 2")
require(parsed?.identifier == "id1", "response id prefers field 1")
require(parsed?.isVideo == true, "type 1 is a video")

// 没有 id、只有 file_id 时用 file_id 当标识（缓存/日志都靠它）。
var withoutID = Data()
withoutID.append(stringField(2, url))
withoutID.append(stringField(3, "f9"))
withoutID.append(contentsOf: [0x20, 0x02])
let fallback = SpotifyCanvasProto.parseResponse(lengthDelimited(1, withoutID))
require(fallback?.identifier == "f9", "file_id is used when id is missing")
require(fallback?.isVideo == true, "type 2 is a video")

// type 0 / 4 不是视频：IMAGE / GIF 交给系统播放器会立刻失败，必须挡掉。
var stillImage = Data()
stillImage.append(stringField(2, url))
stillImage.append(contentsOf: [0x20, 0x00])
let image = SpotifyCanvasProto.parseResponse(lengthDelimited(1, stillImage))
require(image?.isVideo == false, "type 0 is not a video")

var unknownType = Data()
unknownType.append(stringField(2, url))
unknownType.append(contentsOf: [0x20, 0x04])
let unknown = SpotifyCanvasProto.parseResponse(lengthDelimited(1, unknownType))
require(unknown?.isVideo == false, "type 4 is not a video")

// MARK: - ③ 坏数据

require(SpotifyCanvasProto.parseResponse(Data()) == nil, "empty body parses to nil")
require(
    SpotifyCanvasProto.parseResponse(Data([0x0A, 0x05, 0x0A])) == nil,
    "truncated body parses to nil instead of reading past the end"
)
var noURL = Data()
noURL.append(stringField(1, "id1"))
noURL.append(contentsOf: [0x20, 0x01])
require(SpotifyCanvasProto.parseResponse(lengthDelimited(1, noURL)) == nil,
        "a canvas without a url is ignored")

print("")
if failures == 0 {
    print("SpotifyCanvasProto: all checks passed")
} else {
    print("SpotifyCanvasProto: \(failures) check(s) failed")
    exit(1)
}
