import Foundation
import SwiftUI

/// 「歌词来源顺序」页 —— 拖动手柄调整「自动优选」询问歌词源的先后。
///
/// ── 为什么要有它
/// 「我记得金牛座那边是不是可以自己排序歌词来源的？如果可以，默认排序这样：
/// amll - sl - pl - 网易云 - qq - 酷狗 - un - mxm - bini - gen」
///
/// Taurus 的排序页除了拖拽还能把源**关掉**；这里只做排序 —— 想只用某一个源，
/// 上一页的单源选择器已经能做到，不必再发明一套开关。
///
/// ── 为什么常开编辑模式
/// 这个页面挂在 `UIHostingController` + `UINavigationController` 上。
/// `EditButton` 依赖 SwiftUI 自己的导航栏环境，拿不到时它**不报错、只是不出现** ——
/// 会以为"这个页面拖不动"，而且没有任何日志能看出来。
/// 所以直接用 `.environment(\.editMode, .constant(.active))`：拖拽手柄常显，没有隐藏状态。
struct LyricsSourceOrderView: View {

    @State private var order: [LyricsSource] = LyricsSourceOrder.current

    var body: some View {
        List {
            // Section 头那句「按这个顺序询问」
            // 已删（键 `lyrics_source_order_section` 一并删掉）—— 页标题就叫「歌词来源顺序」，
            // 头里再写一遍是重复；规则只留 footer 一句。
            Section {
                ForEach(order, id: \.self) { source in
                    HStack {
                        Text(source.description)
                        Spacer()
                        Text(timingLabel(for: source))
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }
                .onMove { indices, destination in
                    order.move(fromOffsets: indices, toOffset: destination)
                    // 每拖一次就落盘：这一页没有"保存"按钮，用户拖完就会退出。
                    LyricsSourceOrder.current = order
                    writeDebugLog(
                        "[Lyrics] source order changed: "
                            + order.map(\.description).joined(separator: " → ")
                    )
                }
            } footer: {
                Text("lyrics_source_order_description".localized)
            }

            Section {
                Button("lyrics_source_order_reset".localized) {
                    LyricsSourceOrder.reset()
                    order = LyricsSourceOrder.current
                    writeDebugLog("[Lyrics] source order reset to the default")
                }
            }
            NonIPadSpacerView()
        }
        .listStyle(InsetGroupedListStyle())
        .environment(\.editMode, .constant(.active))
        .navigationTitle("lyrics_source_order".localized)
    }

    /// 右侧那个小标签：这个源**最多**能给到多细。
    ///
    /// ⚠️ 这只是"能力"，不是"这一首一定会给"。写成"逐字"的源遇到没有逐字的曲子
    /// 仍然会给行级 —— 排序页不该假装知道那一首的结果。
    private func timingLabel(for source: LyricsSource) -> String {
        switch source {
        case .genius:
            return "lyrics_timing_plain".localized
        case .lrclib:
            return "lyrics_timing_line".localized
        default:
            return "lyrics_timing_word".localized
        }
    }
}
