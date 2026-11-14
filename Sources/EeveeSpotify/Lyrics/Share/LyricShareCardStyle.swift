import CoreGraphics
import Foundation

/// 分享卡的三套模板。
///
/// · `native`   —— 照 Spotify 那张卡的结构：取色底 + 顶部小封面/曲名 + 大字歌词。
/// · `polaroid` —— 白框拍立得：照片窗口放封面，下方留白写歌词与曲名/歌手。
/// · `minimal`  —— 纯色/纯黑底，只留歌词与一行署名。
enum LyricShareCardTemplate: String, CaseIterable {
    case native
    case polaroid
    case minimal
}

/// 卡面背景来源。
///
/// `cover` 是 Spotify 下发的封面取色（播放页取色底同一个值）；`blurredCover` 是模糊封面铺底；
/// `black` 是纯黑，给 OLED 屏用。
enum LyricShareCardBackground: String, CaseIterable {
    case cover
    case blurredCover
    case black
}

/// 卡面文字颜色。`auto` 按背景亮度选黑白，`black` / `white` 手动钉死，
/// `custom` 用用户挑的那一档（`shareCardCustomInkHex`）。
enum LyricShareCardInk: String, CaseIterable {
    case auto
    case black
    case white
    case custom
}

/// 卡面画幅。三者都是 1080 宽；高度决定社媒预览里的裁切：
///
/// · `story`   9:16（1080×1920）—— 相册与主流社交 App 的整屏预览；
/// · `portrait` 4:5（1080×1350）—— Instagram 信息流那一档；
/// · `square`  1:1（1080×1080）—— 头像/正方形贴文。
///
/// 版式不是简单缩放：拍立得的相纸高度按画幅重新收，见渲染层。
enum LyricShareCardSize: String, CaseIterable {
    case story
    case portrait
    case square

    var canvasSize: CGSize {
        switch self {
        case .story:
            return CGSize(width: 1080, height: 1920)
        case .portrait:
            return CGSize(width: 1080, height: 1350)
        case .square:
            return CGSize(width: 1080, height: 1080)
        }
    }

    var aspectRatio: CGFloat {
        canvasSize.width / canvasSize.height
    }
}

// MARK: - 存储

/// 分享卡设置与备份白名单共用的键名。
///
/// 这三个键从分享卡功能第一天起就由本文件拥有；`size` / `customInk` 是后加的。
/// `UserDefaults.ownedKeys` 里通过 `LyricShareCardSettings.ownedKeys` 汇总，
/// 新增键只改这里一处。
enum LyricShareCardSettings {

    static let templateKey = "ngzhwm_shareCardTemplate"
    static let backgroundKey = "ngzhwm_shareCardBackground"
    static let inkKey = "ngzhwm_shareCardInk"
    static let sizeKey = "ngzhwm_shareCardSize"
    static let customInkKey = "ngzhwm_shareCardCustomInk"

    static let ownedKeys: [String] = [
        templateKey,
        backgroundKey,
        inkKey,
        sizeKey,
        customInkKey,
    ]

    /// 自定义文字色的兜底值。白字在三种背景上都至少能看见；用户挑过之后以盘上的值为准。
    static let defaultCustomInkHex = "#FFFFFF"
}

extension UserDefaults {

    static var shareCardTemplate: LyricShareCardTemplate {
        get {
            LyricShareCardTemplate(
                rawValue: UserDefaults.container.string(forKey: LyricShareCardSettings.templateKey) ?? ""
            ) ?? .native
        }
        set {
            UserDefaults.container.set(newValue.rawValue, forKey: LyricShareCardSettings.templateKey)
        }
    }

    static var shareCardBackground: LyricShareCardBackground {
        get {
            LyricShareCardBackground(
                rawValue: UserDefaults.container.string(forKey: LyricShareCardSettings.backgroundKey) ?? ""
            ) ?? .cover
        }
        set {
            UserDefaults.container.set(newValue.rawValue, forKey: LyricShareCardSettings.backgroundKey)
        }
    }

    static var shareCardInk: LyricShareCardInk {
        get {
            LyricShareCardInk(
                rawValue: UserDefaults.container.string(forKey: LyricShareCardSettings.inkKey) ?? ""
            ) ?? .auto
        }
        set {
            UserDefaults.container.set(newValue.rawValue, forKey: LyricShareCardSettings.inkKey)
        }
    }

    /// 默认 9:16。旧版本没有这个键，读不到时走 `.story`，与原来的固定画幅一致。
    static var shareCardSize: LyricShareCardSize {
        get {
            LyricShareCardSize(
                rawValue: UserDefaults.container.string(forKey: LyricShareCardSettings.sizeKey) ?? ""
            ) ?? .story
        }
        set {
            UserDefaults.container.set(newValue.rawValue, forKey: LyricShareCardSettings.sizeKey)
        }
    }

    /// 自定义文字色，`RRGGBB` / `#RRGGBB`。空值或解析失败由渲染层退回 `auto`。
    static var shareCardCustomInkHex: String {
        get {
            let stored = UserDefaults.container.string(forKey: LyricShareCardSettings.customInkKey) ?? ""
            let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? LyricShareCardSettings.defaultCustomInkHex : trimmed
        }
        set {
            UserDefaults.container.set(newValue, forKey: LyricShareCardSettings.customInkKey)
        }
    }
}
