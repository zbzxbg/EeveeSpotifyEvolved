import Foundation

enum LyricsError: Error, CustomStringConvertible {
    case noCurrentTrack
    case trackMismatch
    case musixmatchRestricted
    case invalidMusixmatchToken
    /// SpicyLyrics 官方 API 的 key 被拒（401/403）。与 `noSuchSong` 分开：
    /// "key 坏了"和"这首歌没词"是两件事，混在一起用户只会去换来源。
    case invalidSpicyKey
    /// **没填** SpicyLyrics 的客户端密钥。
    ///
    /// ⚠️ 正常流程下这条**不该出现**：`CustomLyrics` 在取词入口就会把"没 key 的 SpicyLyrics"
    /// 换成 Musixmatch（见 `loadCustomLyricsForCurrentTrack` 里那一段）。留着它是防御性的 ——
    /// 用户中途把 key 清空、或将来有人直接从仓库层调用时，必须得到一句能读懂的原因，
    /// 而不是一个 401。
    case missingSpicyKey
    case decodingError
    case noSuchSong
    case unknownError
    case invalidSource
    
    // swift 5.8 compatible
    var description: String {
        switch self {
        case .noSuchSong:
            return "no_such_song".localized
        case .musixmatchRestricted:
            return "musixmatch_restricted".localized
        case .invalidMusixmatchToken:
            return "invalid_musixmatch_token".localized
        case .invalidSpicyKey:
            return "spicylyrics_key_invalid".localized
        case .missingSpicyKey:
            return "spicylyrics_key_missing".localized
        case .decodingError:
            return "decoding_error".localized
        case .unknownError:
            return "unknown_error".localized
        // 以前这三个 case 掉进 default 返回空串，日志里会打印成「failed: 」什么都看不到。
        case .noCurrentTrack:
            return "no_current_track"
        case .trackMismatch:
            return "track_mismatch"
        case .invalidSource:
            return "invalid_source"
        }
    }
}
