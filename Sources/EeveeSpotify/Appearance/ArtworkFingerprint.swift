// 封面指纹：8×8 灰度的 aHash（64 位）+ 汉明距离。
//
// 用途只有一个：**核对两张封面是不是同一张图**。
//
// Apple 目录里那首歌的封面不一定等于 Spotify 正在播的封面 —— 版本 / 母带 / 地区店面 /
// 单曲 vs 专辑 / 合辑 / explicit-clean 双封面都会不一样。而 Apple 的 `bgColor` 是按
// **它那张封面**算出来的：一旦封面不是同一张，拿它的配色就是主动搞错（绿色封面配红色底）。
//
// 这个指纹就是那道闸：都缩到 8×8 灰度，各自与自己的均值比大小得到 64 位，汉明距离
// 在 `matchThreshold` 以内才认。压缩、加角标、轻微裁切都在这个量级内，整张换掉一定超。
//
// 纯本地、无穷举、几十微秒一张（8×8 一次 CGContext 绘制），可以在取色的同一条路上同步跑。
import UIKit

enum ArtworkFingerprint {

    /// 64 位里最多差这么多位就认为是同一张。
    ///
    /// 10 位 ≈ 16%：能容忍重新压过的 JPEG、加一圈描边、稍微裁掉一点边；整张封套换掉
    /// （哪怕同一个乐队）通常差 20 位以上。
    static let matchThreshold = 10

    /// 8×8 灰度 aHash。
    static func hash(of image: UIImage) -> UInt64? {
        guard let cgImage = image.cgImage else { return nil }
        let side = 8
        var pixels = [UInt8](repeating: 0, count: side * side)
        guard let context = CGContext(
            data: &pixels,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        context.interpolationQuality = .low
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))

        let total = pixels.reduce(0) { $0 + Int($1) }
        let average = total / pixels.count
        var hash: UInt64 = 0
        for (index, value) in pixels.enumerated() where Int(value) >= average {
            hash |= (UInt64(1) << UInt64(index))
        }
        return hash
    }

    /// 两个指纹差了几位。
    static func distance(_ lhs: UInt64, _ rhs: UInt64) -> Int {
        (lhs ^ rhs).nonzeroBitCount
    }

    /// 两张图是不是同一张封面。
    static func matches(_ lhs: UIImage, _ rhs: UIImage) -> Bool? {
        guard let a = hash(of: lhs), let b = hash(of: rhs) else { return nil }
        return distance(a, b) <= matchThreshold
    }
}
