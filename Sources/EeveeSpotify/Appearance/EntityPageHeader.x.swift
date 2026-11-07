import Foundation
import Orion
import UIKit
import ObjectiveC.runtime

/// 关联对象的键。**必须放在文件作用域**：`&变量` 取到的地址要稳定且唯一
/// （同 `DeclutterChrome.x.swift` 的 `declutterHiddenByUsKey`）。
var entityPageHeaderKey: UInt8 = 0

/// 上一拍量"封面压没压到文字"时这个页头的高度。
///
/// `probeCoverOverlap` 会改我们那一块的高度（`header.bounds.height + coverDrop`），而滚动中页头
/// 每帧都在变高变矮 ⇒ 量到的重叠每帧不同，`coverDrop` 就在 0 / 4 / 6 之间来回翻，按钮跟着上下跳。
/// 只在页头高度**稳定**时量一次，滚动中途保持上一次的值。
var coverProbeHeightKey: UInt8 = 0

/// 页头替换：找到歌单页头、藏掉 Spotify 那一列、把 `EntityPageHeaderView` 摆上去。
///
/// 挂 `HeaderContentLayout`：它是那一块的布局视图，每一拍折叠/展开都走 `layoutSubviews`
/// ⇒ 一个挂点覆盖"首次出现 / 滚动折叠 / 内容晚到"三种时机。`SPTFreeTierPlaylistEncoreHeaderViewController`
/// 在 9.1.88 上已不存在（歌单头改由 `ListUXPlatform_FreeTierPlaylistImpl` 的 slot/element 拼出来），
/// 故不用它；计数器晚到由"每一拍重读文本"覆盖。
///
/// 作用域只到歌单页，但**`PL.Header` 只是其中一族**：普通歌单有它，官方编辑歌单 / This Is /
/// 电台是 slot 插件拼的、没有这个 id ⇒ `playlistHeaderRoot` 还要退到最近的 cell、
/// `HeaderContentLayout` 自己、responder chain 上的 VC view（每一档都先过 `isPlaylistPage`）。
/// 专辑页共用同一个 `HeaderContentLayout`，但头部结构与控件 id 都不同 ⇒ 走 `applyToAlbumPage`
/// 那条独立的路。
///
/// 安全阀：认不出标题就整块不动（`apply` 早退，一个视图都不藏）。任何一环失配 = "没生效"，
/// 而不是"歌单页坏了"。
///
/// ── 文件分工（2026-11-08 从单个 3735 行文件拆出来）
/// · `EntityPageHeader.x.swift`：本文件 —— 状态/缓存、查找工具、`apply` 入口
/// · `+Playlist` / `+Album` / `+Artist`：三条页面各自的路
/// · `+Release`：艺人页的"最新发布"卡片
/// · `+Layout`：文字块识别、满幅封面、取色渐变
/// · `+Hooks`：`activateEntityPageHeader()` 挂点
enum EntityPageHeaderManager {
    static var isEnabled: Bool { UserDefaults.entityPageAMHeader }

    static var applying = false
    static var logged = Set<String>()

    /// 每一拍的耗时（50 / 200 / 800 拍各报一次）。
    static let meter = PerfMeter("EntityPageHeader")

    /// 尾部按钮的兜底字形：**做成常量** —— 这一拍在折叠的每一帧都会走到，
    /// 每拍 `UIImage(systemName:)` 造一张新的没有意义（与"字形只取一次"同一条纪律）。
    static let plusGlyph = UIImage(systemName: "plus")
    static let downloadGlyph = UIImage(systemName: "arrow.down")

    /// 先看缓存（**还要在原来那棵树里、还在窗口上**），没有再搜。
    static func find(_ identifier: String, in root: UIView, cache: inout UIView?) -> UIView? {
        if let cached = cache, cached.window != nil, cached.isDescendant(of: root) { return cached }
        let found = eeveeFindView(root, identifier: identifier)
        cache = found
        return found
    }

    /// 同 `find`，但**钻到真正能响应点击的那颗控件**上。
    ///
    /// 按 id 找到的往往是 `ElementView<URL, Any, Any>` 那层**包装** —— 转发打在包装上就是没反应，
    /// `isSelected` 也恒假（永远不变绿）。所以 play / shuffle / follow 这些都必须走这条，
    /// 否则就是"日志说转发成功、界面一动不动"。
    ///
    /// 两条纪律：
    /// · **钻不到就退回原来那个**（宁可保持原样，也不要因为钻而把东西丢掉）；
    /// · 钻过一次**把钻到的那个写回缓存** —— 否则每拍都要在包装层里再走一趟子树。
    static func findControl(_ identifier: String, in root: UIView, cache: inout UIView?) -> UIView? {
        let found = find(identifier, in: root, cache: &cache)
        guard let found, !(found is UIControl) else { return found }
        guard let control = firstControl(in: found) else { return found }
        cache = control
        return control
    }

    /// 只进日志：这颗控件**是什么类、是不是 `UIControl`** —— "有没有钻到真控件"就是这一行的答案。
    static func describe(_ control: UIView?) -> String {
        guard let control else { return "missing" }
        let kind = NSStringFromClass(type(of: control))
        let tag = control is UIControl ? "UIControl" : "wrapper"
        return "\(kind)[\(tag)]"
    }

    // MARK: - 入口
    //
    // 从 `HeaderContentLayout` 的 `layoutSubviews` 调用 —— **快速滑动时每一帧一次**，
    // 所以整段用 `PerfMeter` 记着（50 / 200 / 800 拍各报一次耗时），性能回归才有判据。
    static func apply(in layout: UIView) {
        meter.measure { applyOnce(in: layout) }
    }

    /// 沿 superview 链往上找带某个 accessibility id 的祖先（含自己）。
    static func ancestor(of view: UIView, identifier: String) -> UIView? {
        var node: UIView? = view
        var level = 0
        while let current = node, level < 40 {
            level += 1
            if current.accessibilityIdentifier == identifier { return current }
            node = current.superview
        }
        return nil
    }

    /// 这是不是**我们接管的那两种页面**里的视图：歌单页判 `PL.Header`（以及生成歌单那条类名判据），
    /// 专辑页判页面 root 的 id 或它的头容器 —— 都在祖先链上，走一次就够。
    static func isEntityPage(of view: UIView) -> Bool {
        if isPlaylistPage(of: view) { return true }
        var node: UIView? = view
        var level = 0
        while let current = node, level < 24 {
            level += 1
            if let identifier = current.accessibilityIdentifier,
               identifier == "CreativeWorkPlatform.CreativeWorkTemplateView"
                || identifier == "CreativeWorkPlatform.Components.UI.CreativeWorkHeader" {
                return true
            }
            node = current.superview
        }
        return false
    }

    /// 从 `root` 往下找**第一个真正的控件**（`UIControl`，含自身）。
    ///
    /// 按 id 找到的往往是**外面那层 `ElementView<…>` 包装**，而不是能响应 `sendActions` /
    /// `handleTap` 的那颗按钮：转发打在包装上 = 没反应；`(source as? UIControl)?.isSelected`
    /// 也恒为假 ⇒ 永远不变绿（随机播放 / 播放键 / Follow 三处都是这个根因）。
    static func firstControl(in root: UIView) -> UIView? {
        if root is UIControl { return root }
        var queue: [UIView] = root.subviews
        var visited = 0
        while !queue.isEmpty, visited < 400 {
            let view = queue.removeFirst()
            visited += 1
            if view is UIControl { return view }
            queue.append(contentsOf: view.subviews)
        }
        return nil
    }

    /// 那两颗浮动控件是**页面的直接子视图、48pt 上下**，而头、wash、列表都是整页宽 ——
    /// 只搜"小尺寸的直接子视图"，免得每一拍走一整棵树。
    static func findFloating(_ identifier: String, in page: UIView, cache: inout UIView?) -> UIView? {
        if let cached = cache, cached.window != nil, cached.isDescendant(of: page) { return cached }
        var found: UIView?
        for sub in page.subviews where sub.bounds.width <= 120 {
            if let hit = eeveeFindView(sub, identifier: identifier) {
                // 钻到真正的控件（见 `firstControl`）：命中的若是包装层，点了就是没反应。
                // 缓存里存的**也是钻过之后的那一个**，所以每拍不会重走这一趟。
                found = firstControl(in: hit) ?? hit
                break
            }
        }
        cache = found
        return found
    }

    /// 子树里**类名**含某一段的第一个视图（不认 accessibility id —— 生成歌单的插件元素没有 id）。
    static func firstView(withClassName marker: String, in root: UIView) -> UIView? {
        var found: UIView?
        forEachView(root) { view in
            guard found == nil else { return }
            if NSStringFromClass(type(of: view)).contains(marker) { found = view }
        }
        return found
    }

    static func forEachView(_ root: UIView, _ body: (UIView) -> Void) {
        var queue: [UIView] = [root]
        var visited = 0
        while !queue.isEmpty, visited < 1500 {
            let view = queue.removeFirst()
            visited += 1
            body(view)
            queue.append(contentsOf: view.subviews)
        }
    }

    /// HTML 描述（`<a>` 链接与 `&amp;` 之类的实体）→ 纯文本。
    static func plainText(_ html: String?) -> String? {
        guard let html, !html.isEmpty else { return nil }
        var text = html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let entities = ["&amp;": "&", "&quot;": "\"", "&#x27;": "'", "&#39;": "'",
                        "&lt;": "<", "&gt;": ">", "&nbsp;": " "]
        for (entity, replacement) in entities {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - 读 view model（能找到就用，找不到算了）
    //
    // 沿 responder 链找页面的 view model：先问 `defaultHeaderViewModel` / `headerViewModel`，
    // 再问 `headerController` 要一个。**每个 selector 都先 `responds(to:)`**。
    static func viewModel(from view: UIView) -> AnyObject? {
        var responder: UIResponder? = view
        var guardCount = 0
        while let current = responder, guardCount < 40 {
            guardCount += 1
            if let object = current as? NSObject {
                for name in ["defaultHeaderViewModel", "headerViewModel"] {
                    if let value = performObject(object, name) { return value }
                }
                if let controller = performObject(object, "headerController") as? NSObject,
                   let value = performObject(controller, "defaultHeaderViewModel") {
                    return value
                }
            }
            responder = current.next
        }
        return nil
    }

    static func performObject(_ object: NSObject, _ name: String) -> AnyObject? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector), let value = object.perform(selector) else { return nil }
        return value.takeUnretainedValue()
    }

    static func modelString(_ model: AnyObject, _ name: String) -> String? {
        guard let object = model as? NSObject,
              let value = performObject(object, name) as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func logOnce(_ key: String, _ message: @autoclosure () -> String) {
        guard logged.insert(key).inserted else { return }
        writeDebugLog("[EntityPageHeader] \(message())")
    }
}
