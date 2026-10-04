import Foundation
import UIKit

/// 「屏蔽的艺人」：名单、规范化、匹配。
///
/// 参照 spoti.pw 的 *Blocked artists*（来源、许可与改动见「开源许可」页）：
/// 被屏蔽的艺人**一开始播就跳到下一首**。它**做不到**的事也写在这里，避免误解：
///
///   · **不会**把歌从歌单/搜索/首页里删掉或藏起来 —— 那要改 Spotify 的列表数据，
///     代价大一个量级；
///   · 只在曲目**开头**跳（靠 1 秒一次的轮询发现换歌，见 `BlockedArtistSkip`）；
///   · 匹配是**包含**式的（不区分大小写），所以能命中 "MIMI, 可不" 这种多艺人串，
///     代价是**同名/子串艺人会一起误伤** —— 页面脚注里写清了。
///
/// 为什么名单里存的是**艺人名**而不是 URI：名字手动就能加，URI 只有从艺人页/正在播放页
/// 一键添加时才拿得到。我们这一版不做那个一键入口（要 hook 艺人页的上下文菜单，
/// 风险和收益不成比例），所以名字是唯一可用的键。
enum BlockedArtists {

    /// 名单。存用户输入时的原样（只去掉首尾空白），**匹配时才转小写** ——
    /// 这样设置页里显示的是 "MIMI" 而不是 "mimi"，读起来正常。
    static var names: [String] {
        get { UserDefaults.blockedArtists }
        set { UserDefaults.blockedArtists = newValue }
    }

    static var isEnabled: Bool {
        get { UserDefaults.blockedArtistsEnabled }
        set { UserDefaults.blockedArtistsEnabled = newValue }
    }

    static var count: Int { names.count }

    private static func trimmed(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 加一条。空串忽略；**大小写不同视为同一条**（"MIMI" 与 "mimi" 只留先加的那个）。
    static func add(_ name: String) {
        let value = trimmed(name)
        guard !value.isEmpty else { return }

        let key = value.lowercased()
        guard !names.contains(where: { $0.lowercased() == key }) else { return }

        // 保持插入顺序：设置页里的顺序跟用户添加的顺序一致，读起来稳定。
        names = names + [value]
    }

    static func remove(_ name: String) {
        let key = trimmed(name).lowercased()
        names = names.filter { $0.lowercased() != key }
    }

    static func removeAll() {
        names = []
    }

    /// 这首歌命中名单了吗？命中则返回**名单里那一条**（没开 / 没命中返回 nil）。
    ///
    /// 返回命中的那一条而不是 Bool：日志里要打出来，误伤时一眼能看出是哪条规则干的。
    ///
    /// 两个字段都看：`artistName()` 是主艺人，`artistTitle()` 在多艺人/合辑时是一长串。
    static func match(artistName: String?, artistTitle: String?) -> String? {
        guard isEnabled else { return nil }

        let blocked = names
        guard !blocked.isEmpty else { return nil }

        let haystacks = [artistName, artistTitle]
            .compactMap { $0?.lowercased() }
            .filter { !$0.isEmpty }
        guard !haystacks.isEmpty else { return nil }

        return blocked.first { key in
            let needle = key.lowercased()
            return haystacks.contains { $0.contains(needle) }
        }
    }
}
