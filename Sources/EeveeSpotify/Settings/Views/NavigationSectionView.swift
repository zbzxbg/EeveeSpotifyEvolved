import SwiftUI

struct NavigationSectionView: View {
    var color: Color
    var title: String
    var imageSystemName: String
    /// 第二行灰色小字：这一行进去有什么。★ 2026-10-13 加 —— 根页重排后一行只有名字时
    /// 根本看不出「扩展」里装了什么（那个杂物袋就是这么长出来的）。传 nil = 不显示。
    var subtitle: String? = nil

    var body: some View {
        HStack(spacing: 15) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .foregroundColor(color)
                
                Image(systemName: imageSystemName)
                    .foregroundColor(.white)
                    .font(.system(size: 16, weight: .medium))
            }
            .frame(width: 30, height: 30)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundColor(.white)

                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }
            
            Spacer()
            
            ChevronRightView()
        }
    }
}
