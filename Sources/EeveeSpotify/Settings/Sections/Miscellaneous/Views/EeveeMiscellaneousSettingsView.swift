import SwiftUI
import UIKit

/// 「杂项设定」页。
///
/// 三行，都是"改的是**行为**、不是某块界面"的开关：
/// · 移除追踪参数 —— 清掉分享链接里的 `si` 追踪码（`CleanShareLinks`，当场生效）；
/// · 分享到 LiveContainer —— 分享面板里**打不开的目标**改走 LC 的深链，失败把 URL 复制到剪贴板
/// （`LiveContainerSharing.x.swift`，当场生效）。**从「实验」页搬来**：
/// 它的行为早已定性，没定性的只是 LC 那一侧的私有深链 ⇒ 按「实验」页文件头的准入三条，
/// 它不该占实验位（见 `EeveeExperimentsSettingsView`）；
/// · 阻止评分提示 —— 拦 App Store 的系统评分弹窗（`RatingPromptBlock`，**要重启**）。
///
/// 与「隐私与上报」的分工（别把两边搞混、也别合并）：
/// · 这里的「移除追踪参数」收拾的是**你发出去的链接**（字符串层面，不出网）；
/// · 那页的「拦截上报」收拾的是**应用自己发出的网络请求**（`TelemetryEndpointRules`）。
/// 上游把"拦截上报"也塞在杂项里，本仓库重排时把它单独做成一页
/// （多了"只观察不拦截"、额外关键词、本次启动计数）。「分享到 LiveContainer」
/// 也从「实验」页搬来 ⇒ 本页现在是三行。
struct EeveeMiscellaneousSettingsView: View {

    @State private var cleanShareLinks = UserDefaults.cleanShareLinks
    @State private var blockRatingPrompts = UserDefaults.blockRatingPrompts
    /// 「分享到 LiveContainer」的值住在 `experimentsOptions` 那个 Codable struct 里（另外三个实验也住那儿），
    /// 所以这一行是"读字段 / 写回整个 struct"，不是普通 Bool 键 —— 见下面的 `onChange` 与重置闭包。
    @State private var liveContainerSharing = UserDefaults.experimentsOptions.liveContainerSharing

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

            // 「分享到 LiveContainer」：与上面「移除追踪参数」同属"你分享出去的东西"这条线
            // （那一条收拾链接串，这一条收拾分享面板里打不开的目标），所以放一块。
            // ⚠️ 值不在独立键里 —— 它在 `experimentsOptions`（Codable struct，与实验页共用），
            // 写的时候必须整体写回，别改成普通单键 set。
            Section(footer: Text("livecontainer_sharing_description".localized)) {
                Toggle(
                    "livecontainer_sharing".localized,
                    isOn: Binding<Bool>(
                        get: { liveContainerSharing },
                        set: { liveContainerSharing = $0 }
                    )
                )
                .onChange(of: liveContainerSharing) { value in
                    var options = UserDefaults.experimentsOptions
                    options.liveContainerSharing = value
                    UserDefaults.experimentsOptions = options
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
                    // 只回读影子值：这三行都没有"当场改屏幕"的副作用
                    // （链接清理在每次分享时读一次、LC 那一条在每次 openURL 时读一次，
                    // 评分拦截只影响下次启动）。
                    cleanShareLinks = UserDefaults.cleanShareLinks
                    blockRatingPrompts = UserDefaults.blockRatingPrompts

                    // ⚠️ 「分享到 LiveContainer」的键（`experimentsOptions`）**不在** `ownedKeys` 里
                    // —— 那一个键装着四个字段，整个删掉会把实验页那三个也一起重置。
                    // 所以这里按**值**把它写回默认（true），让"重置本页"对三行都成立；
                    // 「已重置 N 项」那个数字只数被删掉的键，不数这一行。
                    var options = UserDefaults.experimentsOptions
                    options.liveContainerSharing = true
                    UserDefaults.experimentsOptions = options
                    liveContainerSharing = true
                }
            )
        }
                // inset-grouped（胶囊卡片）—— 为什么、怎么做的见 `EeveeSettingsView` 顶部那段
        .listStyle(InsetGroupedListStyle())
    }

    /// 本页拥有的键（`SettingsResetSection` 只删这几个）。键名与 `UserDefaults` 属性同名。
    ///
    /// ⚠️ **不要**把 `experimentsOptions` 加进来：它装着四个实验字段（Instagram 分享位 /
    /// PetitLyrics 回退 NetEase / AMLL 模糊搜索 / 本页的 LiveContainer），删键会把四个一起重置。
    /// 本页那一行由上面 `afterReset` 按值写回默认。
    private static let ownedKeys = [
        "cleanShareLinks",
        "blockRatingPrompts",
    ]
}
