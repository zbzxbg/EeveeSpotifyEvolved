import SwiftUI

/// 15 段图形均衡的曲线：一条可以拖着走的折线。
///
/// 拖到哪个频点就改哪一段，**不做插值** —— 图形均衡的语义就是"每段一个增益"，
/// 插值会让拖一个点带走两边，和下面按段排的频点对不上。
///
/// 竖直方向是 ±12 dB：中线 0 dB，底 −12、顶 +12。
struct EeveeGraphicEQCurveView: View {

    @Binding var gains: [Double]

    private let range: Double = AudioDSPGraphicEQ.maxGainDb
    private let pointSize: CGFloat = 7

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: size.height / 2))
                    path.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                }
                .stroke(Color.secondary.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

                curve(in: size)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineJoin: .round))

                ForEach(0..<AudioDSPGraphicEQ.count, id: \.self) { index in
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: pointSize, height: pointSize)
                        .position(point(at: index, in: size))
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        update(at: value.location, in: size)
                    }
            )
        }
        .frame(height: 150)
        .accessibilityElement()
        .accessibilityLabel(Text("audio_effects_graphic_eq".localized))
    }

    // MARK: - 几何

    private func point(at index: Int, in size: CGSize) -> CGPoint {
        let count = AudioDSPGraphicEQ.count
        let step = count > 1 ? size.width / CGFloat(count - 1) : size.width
        let gain = index < gains.count ? gains[index] : 0
        let ratio = CGFloat(min(max(gain, -range), range) / range)
        return CGPoint(x: step * CGFloat(index), y: size.height / 2 - ratio * size.height / 2)
    }

    private func curve(in size: CGSize) -> Path {
        Path { path in
            for index in 0..<AudioDSPGraphicEQ.count {
                let position = point(at: index, in: size)
                if index == 0 {
                    path.move(to: position)
                } else {
                    path.addLine(to: position)
                }
            }
        }
    }

    // MARK: - 拖动

    private func update(at location: CGPoint, in size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let count = AudioDSPGraphicEQ.count
        guard count > 1 else { return }

        let step = size.width / CGFloat(count - 1)
        let index = min(max(Int((location.x / step).rounded()), 0), count - 1)
        let ratio = Double((size.height / 2 - location.y) / (size.height / 2))
        let gain = min(max(ratio * range, -range), range)

        guard index < gains.count else { return }
        if abs(gains[index] - gain) < 0.01 { return }
        gains[index] = (gain * 20).rounded() / 20
    }
}
