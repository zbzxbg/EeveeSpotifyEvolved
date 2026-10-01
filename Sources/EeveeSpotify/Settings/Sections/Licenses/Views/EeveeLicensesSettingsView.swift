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
        ]
    }

    var body: some View {
        List {
            Section(footer: Text("licenses_footer".localized)) {
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
        .listStyle(GroupedListStyle())
    }
}
