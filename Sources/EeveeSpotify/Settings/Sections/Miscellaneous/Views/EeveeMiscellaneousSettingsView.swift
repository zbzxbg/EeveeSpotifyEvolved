import SwiftUI
import UIKit

/// 「杂项设定」页。
///
/// 两行，都是"改的是**行为**、不是某块界面"的开关：
///   · 移除追踪参数 —— 清掉分享链接里的 `si` 追踪码（`CleanShareLinks`，当场生效）；
///   · 阻止评分提示 —— 拦 App Store 的系统评分弹窗（`RatingPromptBlock`，**要重启**）。
///
/// 与「隐私与上报」的分工（别把两边搞混、也别合并）：
///   · 这里的「移除追踪参数」收拾的是**你发出去的链接**（字符串层面，不出网）；
///   · 那页的「拦截上报」收拾的是**应用自己发出的网络请求**（`TelemetryEndpointRules`）。
///   上游把"拦截上报"也塞在杂项里，本仓库 2026-10-13 重排时把它单独做成一页
///   （多了"只观察不拦截"、额外关键词、本次启动计数），杂项就只留这两行。
struct EeveeMiscellaneousSettingsView: View {

    @State private var cleanShareLinks = UserDefaults.cleanShareLinks
    @State private var blockRatingPrompts = UserDefaults.blockRatingPrompts

    var body: some View {
        List {
            Section(footer: Text("clean_share_links_description".localized)) {
                Toggle(
                    "clean_share_links".localized,
                    isOn: Binding<Bool>(
                        get: { cleanShareLinks },
                        set: { cleanShareLinks = $0 }
                    )
                )
                .onChange(of: cleanShareLinks) { value in
                    UserDefaults.cleanShareLinks = value
                }
            }

            Section(footer: Text("block_rating_prompts_description".localized)) {
                Toggle(
                    "block_rating_prompts".localized,
                    isOn: Binding<Bool>(
                        get: { blockRatingPrompts },
                        set: { blockRatingPrompts = $0 }
                    )
                )
                .onChange(of: blockRatingPrompts) { value in
                    UserDefaults.blockRatingPrompts = value
                }
            }

            // 评分提示拦截是"启动时按开关决定 hook 装不装"的 ⇒ 改完必须重启。
            // 拿当前值和启动快照比，不一样才显示这一行。
            RestartSection(visible: blockRatingPrompts != RatingPromptBlock.launchEnabled)

            SettingsResetSection(
                keys: Self.ownedKeys,
                afterReset: {
                    // 只回读两个影子值：这两行都没有"当场改屏幕"的副作用
                    // （链接清理在每次分享时读一次，评分拦截只影响下次启动）。
                    cleanShareLinks = UserDefaults.cleanShareLinks
                    blockRatingPrompts = UserDefaults.blockRatingPrompts
                }
            )
        }
                // ★ 2026-10-12：inset-grouped（胶囊卡片）—— 为什么、怎么做的见 `EeveeSettingsView` 顶部那段
        .listStyle(InsetGroupedListStyle())
    }

    /// 本页拥有的键（`SettingsResetSection` 只删这几个）。键名与 `UserDefaults` 属性同名。
    private static let ownedKeys = [
        "cleanShareLinks",
        "blockRatingPrompts",
    ]
}
