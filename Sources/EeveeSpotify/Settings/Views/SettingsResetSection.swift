import SwiftUI

/// 设置页页脚的「重置本页」：只把**这一页拥有的**几个 `UserDefaults` 键删掉，让它们回到
/// 代码里的默认值（别的页面的设置、以及 Spotify 自己的偏好一个都不碰）。
///
/// 与「设置与关于 → 备份与重置」里那颗**全局**重置的分工：
///   · 全局那颗 = `SettingsBackup.resetToStock()`，删掉白名单里的全部键；
///   · 这颗 = 传进来哪几个键就只删哪几个（`SettingsBackup.resetToStock(_:)`）。
///
/// ⚠️ `afterReset` 是**必填**的，不是装饰。这些开关背后大多有"当场生效"的副作用：
/// 撤掉玻璃、把 inset 写回、把藏过的 chrome 放回来、重建歌词容器……**只删键不改屏幕**，
/// 用户看到的就是"重置没生效，得重启才变"。所以每一页都要在闭包里做两件事：
///   1. 重同步本页的影子值（`shadow = Shadow()`，否则开关还显示旧状态）；
///   2. 把这一页管得到的东西重新落地一次。
struct SettingsResetSection: View {

    /// 本页拥有的 `UserDefaults` 键（写属性名即可 —— 本仓库的键名与属性名同名）。
    let keys: [String]

    /// 重置之后：重同步影子值 + 把状态落回屏幕。见类型说明。
    let afterReset: () -> Void

    /// 上一句 footer 被替换成结果（"已重置 N 项"）—— 只在这次进页面后显示。
    @State private var result: String?

    var body: some View {
        Section(footer: Text(result ?? "settings_reset_page_footer".localized)) {
            Button {
                let removed = SettingsBackup.resetToStock(keys)
                afterReset()
                result = "settings_reset_page_done".localizeWithFormat(removed)
                writeDebugLog("[Settings] reset this page — \(removed) key(s) removed: \(keys.joined(separator: ", "))")
            } label: {
                Label("settings_reset_page".localized, systemImage: "arrow.counterclockwise")
            }
        }
    }
}
