import Foundation

struct PetitLyricsLine: Codable {
    var linestring: String
    var words: [PetitLyricsWord]
    /// ★ 2026-10-30：这一行的词时间已经被我们换算成**绝对毫秒**（合并短句时做过一次）。
    ///
    /// 不加这个标记的话，合并后的行会再被 `isCentiseconds` 按"原始 Petit 单位"判一次，
    /// 某些 40ms 间隔的行会被二次 ×10。它不参与解码（`CodingKeys` 里没有），默认 false。
    var isNormalized: Bool = false

    enum CodingKeys: String, CodingKey {
        case linestring
        case words = "word"
    }
}
