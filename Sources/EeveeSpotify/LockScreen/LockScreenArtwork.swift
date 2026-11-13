import CoreGraphics
import Foundation

/// 锁屏动态封面：把一段短视频交给系统的 Now Playing，锁屏（以及系统其它正在播放视图）
/// 用它替换静态专辑封面。
///
/// 与 Live Activity 的区别：这一层**不需要 appex、也不需要改 bundle id**。系统在
/// `MPNowPlayingInfoCenter.nowPlayingInfo` 里读到 `MPMediaItemAnimatedArtwork` 之后
/// 自己起播放器，我们只负责"这一首对应哪个本地文件"。
///
/// 数据来源三条，按顺序问：
/// 1. **Canvas** —— Spotify 自己给这首歌的循环短片。地址在 track metadata 的
///    `canvas.url` 里，只有在 Spotify 的 `ios-feature-canvas.canvas_enabled` 为真时
///    播放核心才会填它（见 `DynamicPremium+ModifyingFunctions.swift` 里那条替换）。
/// 2. **Apple Music editorial video** —— 用 Apple Music 网页播放器的 developer token
///    查目录（不需要用户登录），取 `editorialVideo` 里对应画幅的那段 HLS。
/// 3. **本地 Fill** —— 两条都没有时，用专辑封面渲染一段循环短片。只在缓存里没有这一首时
///    跑一次，之后和下载来的片段一样按文件缓存。
///
/// 三条都拿不到时什么都不做：系统继续用静态封面。
enum LockScreenArtwork {

    static let logTag = "LockArt"

    /// 系统的动态封面只认两种画幅，各有自己的 now-playing 键。素材必须和键的画幅一致，
    /// 差得多时系统会整份丢掉、退回静态封面。
    enum Aspect: String, CaseIterable {
        case square
        case tall

        var aspectRatio: CGFloat {
            switch self {
            case .square: return 1
            case .tall: return 3.0 / 4.0
            }
        }

        /// 渲染/转码的目标像素。锁屏那一格本来就不大，再高只是多占缓存和解码。
        var renderSize: CGSize {
            switch self {
            case .square: return CGSize(width: 720, height: 720)
            case .tall: return CGSize(width: 720, height: 960)
            }
        }

        var cacheKeySuffix: String { rawValue }
    }

    static var isEnabled: Bool { UserDefaults.lockScreenAnimatedArtwork }

    /// Canvas 那条源要不要参与。总开关关着时它也不该去动 Spotify 的 flag。
    static var wantsCanvas: Bool { isEnabled && UserDefaults.lockScreenAnimatedArtworkCanvas }

    /// 前两条源都没有时要不要本地渲染一段。关掉它不影响 Canvas / Apple Music。
    static var wantsFill: Bool { isEnabled && UserDefaults.lockScreenAnimatedArtworkFill }

    /// 缓存上限。锁屏短片都是十几秒的循环，单条通常 2–6 MB；给到 120 MB 是为了
    /// 让"最近听的一批歌"都能秒开，同时不至于把用户的 Caches 吃掉。
    static let cacheByteLimit: Int64 = 120 * 1024 * 1024

    /// 标题 / 艺人 / 时长 → 一个稳定的标识。系统拿 `artworkID` 判断"要不要重新请求素材"，
    /// 所以它必须**跟着歌走**，且同一首歌在两次播放之间保持不变。
    static func artworkID(title: String, artist: String, duration: Double) -> String {
        let seed = "\(title)|\(artist)|\(Int(duration.rounded()))"
        return "eevee.\(FNV1a.hex(seed))"
    }

    /// 比较两段文字是否指同一首歌 / 同一张专辑。Apple Music 的曲名常带 "(Remastered)"
    /// 之类的后缀，所以只要求"去掉装饰之后互相包含"。
    static func looksLikeSameSong(_ lhs: String, _ rhs: String) -> Bool {
        let a = normalized(lhs)
        let b = normalized(rhs)
        guard !a.isEmpty, !b.isEmpty else { return false }
        return a == b || a.contains(b) || b.contains(a)
    }

    static func normalized(_ text: String) -> String {
        let folded = text.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        return String(folded.filter { $0.isLetter || $0.isNumber })
    }
}

/// 只用来给文件名/artworkID 生成短哈希，不做任何安全用途。
enum FNV1a {
    static func hex(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return String(format: "%016llx", hash)
    }
}
