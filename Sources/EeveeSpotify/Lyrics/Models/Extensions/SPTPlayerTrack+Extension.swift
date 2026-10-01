// ⚠️ 这个文件原来**没有任何 import**（此前只调协议自己的方法，不需要）。
// 加了 `string(ifResponding:)` 之后就用到了 `NSObject` / `Selector` / `perform` ——
// 它们来自 Foundation（ObjectiveC 由 Foundation 再导出），**必须显式 import**
// （2026-10-01 CI：`cannot find type 'NSObject' in scope` / `cannot find 'Selector' in scope`）。
import Foundation
import ObjectiveC.runtime

extension SPTPlayerTrack {
    var trackIdentifier: String {
        self.URI().spt_trackIdentifier()
    }

    /// 探测式调用：只在这个对象**真的实现了**该方法时才调，否则返回 nil。
    ///
    /// ⚠️ 为什么必须有它（2026-10-01 的崩溃换来的）：
    /// `SPTPlayerTrack` 是我们**手写**的 `@objc protocol`，里面列了
    /// `trackTitle()` / `artistTitle()` / `artistName()` —— 但**声明 ≠ 实现**。
    /// 同一份 9.1.86 上 `artistTitle()` 就不存在（仓库里它只在
    /// `hookTarget == .lastAvailableiOS14` 那一支被调用过，9.1.x 从没调过），
    /// 于是屏蔽艺人的轮询一发歌就
    /// `NSInvalidArgumentException · unrecognized selector` 崩在 `__NSFireTimer` 里。
    ///
    /// `perform` 只在这些方法**返回对象**时可用（这几个 getter 都返回 String，所以可以）。
    func string(ifResponding selectorName: String) -> String? {
        guard let object = self as? NSObject,
              object.responds(to: Selector(selectorName)) else { return nil }

        return object.perform(Selector(selectorName))?.takeUnretainedValue() as? String
    }

    /// 从 Spotify 的 metadata 字典提取歌曲时长（毫秒）。
    /// 键名在不同版本/平台可能是 duration / duration_ms / durationMs 等，
    /// 值可能是毫秒或秒字符串。取不到返回 nil（本地文件等），调用方应跳过时长校验。
    var trackDurationMilliseconds: Int? {
        for key in ["duration", "duration_ms", "durationMs", "durationInMilliseconds"] {
            guard let raw = metadata()[key] else { continue }
            // Int(raw) 处理整数串；Double(raw) 兜底小数串（如 "210.0"）。
            let value = Int(raw) ?? Int(Double(raw) ?? 0)
            guard value > 0 else { continue }
            // 小于 60000 视为秒（毫秒值的正常歌曲 ≥ 60s），换算成毫秒。
            // 若设备端实测值单位与假设不符，改这里即可。
            return value < 60000 ? value * 1000 : value
        }
        return nil
    }
}
