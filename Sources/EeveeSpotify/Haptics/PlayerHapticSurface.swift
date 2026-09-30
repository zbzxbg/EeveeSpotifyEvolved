import UIKit

/// 「这个控件算不算播放器界面」的判定。
///
/// 为什么不把 Spotify 的控件类名写死：9.1.x 的私有类名逐版本在变（本仓库已经吃过
/// `ProfileSettingsSection` 在 9.1.44 消失的亏），写死等于给自己埋一颗定时炸弹。
/// 这里改成**关键词匹配**：控件自身或祖先的类名 / accessibilityIdentifier 里出现
/// 关键词才算命中；关键词存在偏好里，用户能在设置页改，不必重新编译。
///
/// 代价是"关键词没对上就什么都不震"——所以设置页另有一个「记录被点控件的类名」
/// 开关：打开、点一遍播放器，日志里就有真名可抄。宁可静默，也不要乱震。
enum PlayerHapticSurface {

    /// 一条控件链最多向上看几层。看得太深会把整个页面算进来，等于全 App 都命中。
    private static let maxDepth = 8

    private static let lock = NSLock()
    private static let logCap = 60
    private static var loggedChains: Set<String> = []

    private static var keywords: [String] {
        UserDefaults.hapticsSurfaceKeywords
            .split(whereSeparator: {
                $0 == "," || $0 == ";" || $0 == "\n" || $0 == " " || $0 == "\t"
            })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
    }

    static func matches(_ control: UIView) -> Bool {
        let needles = keywords
        guard !needles.isEmpty else { return false }

        var view: UIView? = control
        var depth = 0

        while let current = view, depth < maxDepth {
            // 描述串每层只算一次（类名 + accessibility 标识），别按关键词重复构造。
            let haystack = describe(current)
            if needles.contains(where: { haystack.contains($0) }) { return true }

            view = current.superview
            depth += 1
        }

        return false
    }

    /// 设置页开着「记录被点控件的类名」时调用：把整条控件链打一遍（去重、封顶）。
    static func logChainIfRequested(_ control: UIView) {
        guard UserDefaults.hapticsLogControls else { return }

        var names: [String] = []
        var view: UIView? = control
        var depth = 0

        while let current = view, depth < maxDepth {
            names.append(className(current))
            view = current.superview
            depth += 1
        }

        let chain = names.joined(separator: " < ")

        lock.lock()
        var isNew = false
        if loggedChains.count < logCap {
            isNew = loggedChains.insert(chain).inserted
        }
        lock.unlock()

        guard isNew else { return }
        writeDebugLog("[Haptics] tapped chain: \(chain)")
    }

    private static func className(_ view: UIView) -> String {
        // 保留全名（含 `_TtC...` / 模块前缀）：关键词是子串匹配，全名同时覆盖
        // Swift 与 ObjC 两种命名。
        String(describing: type(of: view))
    }

    private static func describe(_ view: UIView) -> String {
        var text = className(view).lowercased()

        if let identifier = view.accessibilityIdentifier, !identifier.isEmpty {
            text += " \(identifier.lowercased())"
        }

        return text
    }
}
