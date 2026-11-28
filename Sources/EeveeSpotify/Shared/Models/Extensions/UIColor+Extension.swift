import SwiftUI
import UIKit

extension UIColor {
    func mix(with target: UIColor, amount: CGFloat) -> Self {
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0

        self.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        target.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)

        return Self(
            red: r1 * (1.0 - amount) + r2 * amount,
            green: g1 * (1.0 - amount) + g2 * amount,
            blue: b1 * (1.0 - amount) + b2 * amount,
            alpha: a1 * (1.0 - amount) + a2 * amount
        )
    }

    func lighter(by amount: CGFloat = 0.2) -> Self { mix(with: .white, amount: amount) }
    func darker(by amount: CGFloat = 0.2) -> Self { mix(with: .black, amount: amount) }

    /// 解析 `#RRGGBB` / `RRGGBB` / `AARRGGBB` / `FFRRGGBB`。
    ///
    /// 与仓库里 `Color(hex:)` 的口径一致（8 位时前两位是 alpha）。
    /// 放在这里而不是各文件私有：播放页的底色、动效封面的 Apple 配色都要把
    /// Spotify / Apple 给的十六进制字符串还原成 `UIColor`。
    convenience init?(hexString: String?) {
        guard var hex = hexString?.trimmingCharacters(in: .whitespacesAndNewlines), !hex.isEmpty else {
            return nil
        }
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6 || hex.count == 8,
              let value = UInt64(hex, radix: 16) else { return nil }

        let r, g, b, a: CGFloat
        if hex.count == 8 {
            a = CGFloat((value >> 24) & 0xFF) / 255
            r = CGFloat((value >> 16) & 0xFF) / 255
            g = CGFloat((value >> 8) & 0xFF) / 255
            b = CGFloat(value & 0xFF) / 255
        } else {
            a = 1
            r = CGFloat((value >> 16) & 0xFF) / 255
            g = CGFloat((value >> 8) & 0xFF) / 255
            b = CGFloat(value & 0xFF) / 255
        }
        self.init(red: r, green: g, blue: b, alpha: a)
    }
}
