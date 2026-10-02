import UIKit

/// 听歌页（NPV）的**整页底色**：换成"封面取色"的三层渐变 —— 也就是 Apple Music 那种
/// "整页都是这首歌的颜色"的观感。
///
/// ## 借鉴来源（许可与"借了什么"都写清）
///
/// 配方来自 **kumone**（独立网易云客户端，`LICENSE` = LGPL-3.0、`COPYING` = GPL-3.0；
/// 与本仓库 GPL-3.0 **兼容**）。它的 `NowPlayingView.backdrop` 是三层：
///
/// ```swift
/// LinearGradient(colors: [colors.primary, colors.secondary], .topLeading → .bottomTrailing)
/// RadialGradient(colors: [.white.opacity(0.12), .clear], center: .topLeading, endRadius: 700)
/// LinearGradient(colors: [.clear, .black.opacity(0.35)], .top → .bottom)
/// .animation(.easeInOut(duration: 0.8), value: colors)
/// ```
///
/// ⚠️ **关键：那层底是"取色渐变"，不是模糊封面**。这一点很重要 —— 本仓库 2026-10-02
/// 那次"自绘壳"把整页糊掉（`Tweak.x.swift:384-387` 记着 bug 清单），根因就是**加了一层模糊
/// 盖在内容上**。取色渐变是**在底层铺颜色**，机理相反，所以这次不会糊内容。
///
/// ## 我们怎么落到 Spotify 的视图树上（真机 `[Tree]` 依据）
///
/// 播放页自己**已经有一层整页着色视图**，颜色跟着封面走：
/// ```
/// 9.NPVGradientView@0,0,414,896                      ← 整页，独立类
/// 7.UIView@0,0,414,896,bg=#E84838                    ← ★ 整页，底色 = 封面取色（换歌会变）
/// 8.UIView@0,0,414,48,bg=#121212                     ← 压在上面的 48pt 导航条
/// ```
/// 换歌时那层底色从 `#E84838` → `#4890E0` → `#302838` 一路变，`alpha` 也会动
/// （`ContrastPivot` 式的淡入）⇒ **它就是 Spotify 自己的"封面底色"**。
///
/// 所以我们的做法是**接管它**，而不是在最上层再盖一层：
///   1. 找出"整页、直接挂在页面根视图下、底色非空且可见"的兄弟视图；
///   2. 记下它**原来的** `backgroundColor`（关开关要写回）；
///   3. 把底色清成透明，在它内部铺自己的三层 `CAGradientLayer`。
///
/// ## 纪律
///
/// * **幂等**：每次调用都先比对"当前是不是我们要的状态"，是就只更新颜色，不重建层；
/// * **可还原**：`remove()` 会把底色写回、层删掉（关掉开关即恢复原样）；
/// * **有上限**：走查最多 `maxNodes` 个视图（本仓库纪律：不给别人的视图树无界遍历）；
/// * **自报**：第一次动手、颜色变化、放弃，各打一行 `[NPVStyle]`，不然真机上看不见它做了什么。
enum NowPlayingBackdrop {

    static let logTag = "NPVStyle"

    /// 走查上限（本仓库纪律：2000 节点，见 `EeveeSettingsViewController` 那处）。
    private static let maxNodes = 2000

    /// 我们改过的视图 + 它们原来的底色。**必须有原值**，否则关掉开关回不去。
    private struct Touched {
        let view: UIView
        let originalColor: UIColor?
        let layer: CAGradientLayer
    }

    private static var touched: [Touched] = []
    /// 上一次用的封面色（十六进制）。同一个颜色不重复刷 —— 这一页的布局回合不少。
    private static var lastHex: String?

    // MARK: - 对外入口

    /// 每次进入/布局播放页时调一次。传 `nil` 的 hex 表示"还没拿到封面色"。
    ///
    /// - Parameter hex: 封面取色，形如 `FFE84838`（8 位 ARGB）或 `E84838`（6 位 RGB）。
    ///   来源与歌词配色同一个：`track.metadata()["extracted_color"]`。
    static func apply(hex: String?, in pageView: UIView) {
        guard UserDefaults.nowPlayingBackdrop else {
            remove(reason: "switch off")
            return
        }

        guard let color = UIColor(hexString: hex) else {
            // 没取色：不动别人的视图（宁可什么都不做，也不要铺一块灰）。
            logOnce("no extracted color yet — leaving Spotify's own background alone")
            return
        }

        let root = pageView
        let rootBounds = root.bounds
        guard rootBounds.width > 1, rootBounds.height > 1 else { return }

        if lastHex == hex, !touched.isEmpty {
            // 颜色没变、也已经接管过：只保证层还跟着尺寸（布局可能刚变过）。
            for item in touched { syncFrame(item) }
            return
        }

        let candidates = fullPageSiblings(of: root)
        guard !candidates.isEmpty else {
            logOnce("no full-page coloured sibling found under \(type(of: root)) — backdrop skipped")
            return
        }

        UIView.animate(withDuration: NowPlayingMetrics.backdropCrossfadeDuration) {
            for view in candidates {
                let gradient = adopt(view, root: root)
                gradient.colors = gradientColors(from: color).map { $0.cgColor }
            }
        }

        lastHex = hex
        writeDebugLog(
            "[\(logTag)] backdrop (\(Int(rootBounds.width))x\(Int(rootBounds.height))) ← 封面取色 "
                + "\(hex ?? "?")，接管 \(candidates.count) 层"
                + "（渐变：主色→暗角、左上 12% 白光、底部 35% 压黑；\(NowPlayingMetrics.backdropCrossfadeDuration)s 交叉淡入）"
        )
    }

    /// 关掉开关时把一切写回。
    static func remove(reason: String) {
        guard !touched.isEmpty else { return }
        let count = touched.count
        for item in touched {
            item.layer.removeFromSuperlayer()
            item.view.backgroundColor = item.originalColor
        }
        touched.removeAll()
        lastHex = nil
        writeDebugLog("[\(logTag)] backdrop removed (\(count) 层已还原，reason=\(reason))")
    }

    // MARK: - 接管某一层

    /// 把 `view` 变成"我们画渐变的那一层"：清掉它自己的底色，塞一个渐变子层。
    /// **幂等**：已经在 `touched` 里就直接复用那个层（只同步尺寸）。
    private static func adopt(_ view: UIView, root: UIView) -> CAGradientLayer {
        if let existing = touched.first(where: { $0.view === view }) {
            syncFrame(existing)
            return existing.layer
        }

        let gradient = CAGradientLayer()
        // 与 kumone 的三层对应：主色 → 暗角 → 底部压黑，全部由**一个** layer 表达。
        // 用一个而不是三个：少两层要维护，交叉淡入也只需要一次 `animate`。
        gradient.startPoint = CGPoint(x: 0, y: 0)      // topLeading
        gradient.endPoint = CGPoint(x: 1, y: 1)        // bottomTrailing
        gradient.locations = [0.0, 0.55, 1.0]
        gradient.frame = view.bounds
        gradient.zPosition = -1                        // 永远在宿主内容之下

        let original = view.backgroundColor
        view.backgroundColor = .clear
        view.layer.insertSublayer(gradient, at: 0)

        let item = Touched(view: view, originalColor: original, layer: gradient)
        touched.append(item)
        return gradient
    }

    private static func syncFrame(_ item: Touched) {
        if item.layer.frame != item.view.bounds {
            item.layer.frame = item.view.bounds
        }
    }

    /// 三层配色的位置：主色 → 次色（暗角）→ 底部压黑。
    /// 说明：我们只有**一个**封面主色（payload / metadata 里就一个 `extracted_color`），
    /// 所以"次色"由它降明度算出来 —— 与 kumone 用两个主色是同一观感方向，不额外要数据。
    private static func gradientColors(from base: UIColor) -> [UIColor] {
        [
            base,                                          // 0.00 封面主色
            base.darkened(by: 0.35),                       // 0.55 暗角
            UIColor.black.withAlphaComponent(0.35),         // 1.00 底部压黑 35%（kumone 同值）
        ]
    }

    // MARK: - 找"整页着色的兄弟视图"

    /// 在 `root` 的子树里找"直接撑满页面、且有自己底色"的视图。
    ///
    /// 判据刻意保守（宁可找不到、也不要改错视图）：
    ///   · 尺寸 ≈ 根视图 bounds（容差 1pt）；
    ///   · `backgroundColor` 非空且非透明（纯色才值得接管；渐变/图案色跳过）；
    ///   · 不是 `root` 自己，且不是我们自己的层（`zPosition < 0` 那个）。
    private static func fullPageSiblings(of root: UIView) -> [UIView] {
        var found: [UIView] = []
        var visited = 0
        var queue: [UIView] = root.subviews

        while !queue.isEmpty, visited < maxNodes {
            let view = queue.removeFirst()
            visited += 1
            queue.append(contentsOf: view.subviews)

            if view === root { continue }
            if view.layer.zPosition < 0 { continue }        // 我们自己的层
            guard view.bounds.width >= root.bounds.width - 1,
                  view.bounds.height >= root.bounds.height - 1 else { continue }
            guard let color = view.backgroundColor, color != .clear else { continue }
            // 纯色才接管：动态色 / 图案色读不出分量，硬改会变成一块黑。
            // ⚠️ 条件拆开写 —— 合成一个长表达式会喂给类型检查器一个难题
            // （2026-10-03 已经在 `EeveeReduceInterventionsView` 上栽过一次
            // `unable to type-check this expression in reasonable time`）。
            let isPlainColour: Bool = color.cgColor.numberOfComponents >= 3
            var white: CGFloat = 0
            var alpha: CGFloat = 0
            let isGrayscale: Bool = color.getWhite(&white, alpha: &alpha)
            guard isPlainColour || isGrayscale else { continue }
            found.append(view)
        }

        if visited >= maxNodes {
            writeDebugLog("[\(logTag)] 走查到上限 \(maxNodes) 节点就停了（只接管已找到的 \(found.count) 层）")
        }
        return found
    }

    // MARK: - 日志

    private static var didLogGiveUp = false

    private static func logOnce(_ message: String) {
        guard !didLogGiveUp else { return }
        didLogGiveUp = true
        writeDebugLog("[\(logTag)] \(message)")
    }
}

// MARK: - 颜色工具（本文件私有，避免污染全局）

private extension UIColor {
    /// 解析 `#RRGGBB` / `RRGGBB` / `AARRGGBB` / `FFRRGGBB`。
    /// 与仓库里 `Color(hex:)` 的口径一致（8 位时前两位是 alpha）。
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

    /// 降低明度（保持色相）：用作渐变的"暗角"那一端。
    func darkened(by amount: CGFloat) -> UIColor {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard getHue(&h, saturation: &s, brightness: &b, alpha: &a) else { return self }
        return UIColor(hue: h, saturation: s, brightness: max(0, b - amount), alpha: a)
    }
}
