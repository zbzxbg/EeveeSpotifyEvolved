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

/// 卡面文字颜色。`auto` 按背景亮度选黑白，另外两个是手动钉死。
enum LyricShareCardInk: String, CaseIterable {
    case auto
    case black
    case white
}

// MARK: - 存储

extension UserDefaults {

    private static let shareCardTemplateKey = "ngzhwm_shareCardTemplate"
    private static let shareCardBackgroundKey = "ngzhwm_shareCardBackground"
    private static let shareCardInkKey = "ngzhwm_shareCardInk"

    static var shareCardTemplate: LyricShareCardTemplate {
        get {
            LyricShareCardTemplate(
                rawValue: UserDefaults.standard.string(forKey: shareCardTemplateKey) ?? ""
            ) ?? .native
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: shareCardTemplateKey)
        }
    }

    static var shareCardBackground: LyricShareCardBackground {
        get {
            LyricShareCardBackground(
                rawValue: UserDefaults.standard.string(forKey: shareCardBackgroundKey) ?? ""
            ) ?? .cover
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: shareCardBackgroundKey)
        }
    }

    static var shareCardInk: LyricShareCardInk {
        get {
            LyricShareCardInk(
                rawValue: UserDefaults.standard.string(forKey: shareCardInkKey) ?? ""
            ) ?? .auto
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: shareCardInkKey)
        }
    }
}
