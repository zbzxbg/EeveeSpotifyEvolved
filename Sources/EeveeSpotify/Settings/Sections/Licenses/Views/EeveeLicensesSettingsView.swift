import SwiftUI
import UIKit

/// 「开源许可」页 —— 这一页只写**仓库里查得到的事实**，不编许可证名。
///
/// 为什么要有它：本仓库是 fork + 内置了第三方源码，用户（和仓库维护者）需要一眼看到
/// "这是什么许可、用了什么"。凡是仓库里没有随附许可文件的组件，这里**照实说没有**，
/// 不去猜一个 SPDX 名字填上去。
struct EeveeLicensesSettingsView: View {

    /// 一条许可/组件记录。
    private struct Entry: Identifiable {
        let id = UUID()
        let title: String
        let detailKey: String
        let symbol: String
        let color: Color
    }

    private var entries: [Entry] {
        [
            Entry(
                title: "licenses_this_repo".localized,
                detailKey: "licenses_this_repo_detail",
                symbol: "doc.text",
                color: Color(hex: "#30D158")
            ),
            Entry(
                title: "licenses_upstream".localized,
                detailKey: "licenses_upstream_detail",
                symbol: "arrow.triangle.branch",
                color: Color(hex: "#0A84FF")
            ),
            Entry(
                title: "licenses_bundled".localized,
                detailKey: "licenses_bundled_detail",
                symbol: "shippingbox",
                color: Color(hex: "#FF9F0A")
            ),
            Entry(
                title: "licenses_inspiration".localized,
                detailKey: "licenses_inspiration_detail",
                symbol: "lightbulb",
                color: Color(hex: "#BF5AF2")
            ),
            // 2026-10-03：听歌页那层"整页取色底"的配方借自 kumone（LGPL-3.0 / GPL-3.0，
            // 与本仓库 GPL-3.0 兼容）。这类**兼容许可**的借用必须署名，所以单列一条；
            // 上面那条 spoti.pw 属于同一类（v0.21.1 = GPL-3.0，已复用并修改），只是来路不同。
            Entry(
                title: "licenses_kumone".localized,
                detailKey: "licenses_kumone_detail",
                symbol: "music.note.house",
                color: Color(hex: "#FF375F")
            ),
            // 2026-10-20：网易云歌词源的搜索/匹配思路参考了下面三个项目。
            // NeteaseCloudMusicApi 的仓库现在只剩 README、没有许可文件，所以这里**照实写没有**，
            // 不猜 SPDX；Lyricify 与 163MusicLyrics 的许可来自各自仓库的 LICENSE / README。
            Entry(
                title: "licenses_netease_api".localized,
                detailKey: "licenses_netease_api_detail",
                symbol: "cloud",
                color: Color(hex: "#FF453A")
            ),
            Entry(
                title: "licenses_lyricify".localized,
                detailKey: "licenses_lyricify_detail",
                symbol: "text.magnifyingglass",
                color: Color(hex: "#64D2FF")
            ),
            Entry(
                title: "licenses_163musiclyrics".localized,
                detailKey: "licenses_163musiclyrics_detail",
                symbol: "music.note.list",
                color: Color(hex: "#FFD60A")
            ),
            // 2026-10-31：酷狗 KRC / QQ 音乐 QRC 的解密算法来源。
            // LDDC 是 GPL-3.0-only、pyqdes 是 MIT —— 都只取了"密钥字节 + 步骤顺序"这个事实，
            // Swift 实现是自己写的（`KrcText` / `QrcText`），没有搬运代码。
            Entry(
                title: "licenses_lddc".localized,
                detailKey: "licenses_lddc_detail",
                symbol: "lock.open",
                color: Color(hex: "#5E5CE6")
            ),
            // 2026-10-31：歌词源清单与「自动优选」的调度规则来自 Taurus。
            // ⚠️ Taurus 是 **PolyForm Strict 1.0.0**（不允许衍生作品）——
            //   这一条必须写清楚"没有复制代码"，否则看起来像在它的许可下分发。
            Entry(
                title: "licenses_taurus".localized,
                detailKey: "licenses_taurus_detail",
                symbol: "square.stack.3d.up",
                color: Color(hex: "#AC8E68")
            ),
        ]
    }

    var body: some View {
        List {
            Section {
                ForEach(entries) { entry in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: entry.symbol)
                            .foregroundColor(.white)
                            .frame(width: 28, height: 28)
                            .background(entry.color)
                            .cornerRadius(6)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.title)
                                .font(.subheadline)
                                .bold()

                            Text(entry.detailKey.localized)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
                // ★ 2026-10-12：inset-grouped（胶囊卡片）—— 为什么、怎么做的见 `EeveeSettingsView` 顶部那段
        .listStyle(InsetGroupedListStyle())
    }
}
