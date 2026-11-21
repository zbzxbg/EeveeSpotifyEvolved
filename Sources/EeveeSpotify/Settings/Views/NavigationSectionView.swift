import SwiftUI

struct NavigationSectionView: View {
    var color: Color
    var title: String
    var imageSystemName: String
    /// 第二行灰色小字：这一行进去有什么。加 —— 根页重排后一行只有名字时
    /// 根本看不出「扩展」里装了什么（那个杂物袋就是这么长出来的）。传 nil = 不显示。
    var subtitle: String? = nil
    /// 行尾状态（"已启用""未启用"）。只在副标题右侧、箭头左侧显示一行小字，
    /// 用来回答"这个开关到底开没开"，而不是等用户点进去看。
    var status: String? = nil

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

            if let status {
                Text(status)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            ChevronRightView()
        }
    }
}
