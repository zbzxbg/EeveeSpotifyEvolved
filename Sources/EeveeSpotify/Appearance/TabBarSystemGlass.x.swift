import Foundation
import UIKit
import ObjectiveC.runtime

/// 标签栏：**把 Spotify 那条栏的内容藏起来，在它上面叠一条系统 `UITabBar`** ——
/// iOS 26 会把它画成**真·液态玻璃**（选中气泡、折射、明暗自适应），**一行玻璃 API 都不用我们写**。
///
/// ## 做法照 pw（`Redesigned/Navbar/TabBar.x`，GPL-3.0；**思路复用、代码自己写**）四步
///
///   ① Spotify 的栏**留着**（frame 不动 ⇒ 页面 inset / 迷你播放器都还在原位），但它的**内容不可见**；
///   ② 叠一条**系统栏**，item 从 Spotify 那几颗同步（顺序跟着；隐藏的、自建的都一起）；
///   ③ **选中态**：系统栏的选中项跟着"Spotify 把哪一颗标成选中"走 —— 气泡因此会**滑过去/形变**；
///   ④ **让高度**：系统栏比 Spotify 的栏高，把差额写进 `TabBarContainerImpl` 的
///      `additionalSafeAreaInsets.bottom` ⇒ Spotify 自己把栏 / 迷你播放器 / 页面**一起让开**。
///
/// pw 的文件头原话（它凭什么能这样）：*"UIKit draws that bar as real Liquid Glass
/// (selection bubble, lensing, light/dark adaptation) with no glass API of ours."*
///
/// ## ★ 这一片：**视觉先到位**（2026-10-12 第一片）
///
/// 系统栏**不吃触摸**（`isUserInteractionEnabled = false`）⇒ 手指点下去照样落到 **Spotify 自己那条栏**上
/// （它只是**内容不可见**，交互一点没动）⇒ **点击行为与今天完全一致**，
/// 不会出现"标签栏看着在、点了没反应"那种最坏结果。
///
/// 「按下回弹」那种**果冻感**要求系统栏**接管触摸**，那是**第二片**：接管之后必须把点击**转发**给
/// Spotify 那一颗（pw 用 objc runtime 读手势识别器的 target/action），而"哪条入口真能触发"
/// 只能靠真机日志确认（控制点 → 无障碍激活 → runtime 两条），所以**不混进这一片**。
///
/// ## 开关
///
/// 设置 → 扩展功能 → 标签栏 → 「**标签栏改用系统玻璃**」，**默认关**（这条路我看不到真机，先当实验品）。
/// 关掉 = 系统栏移除 + Spotify 栏内容**恢复原 alpha** + `additionalSafeAreaInsets` **写回原值**。
/// 日志 tag：`[TabBarSystem]`。
///
/// ⚠️ 这个文件里**一律不标 `@MainActor`**：两个调用点（`TabBarPlateHook` 的 `onMainThreadSync` 里、
///    设置页 `persist` 闭包里）都不带主 actor 隔离，标了就会在那边报隔离不匹配；
///    而这两条路本来就在主线程（仓库 `NowPlayingControlsPlate` 那一套是另一种写法，别混）。
enum TabBarSystemGlass {

    static let logTag = "TabBarSystem"

    /// Spotify 自己那一行的高度（真机树里 `UIStackView(0,0 414x49)`）。
    private static let stockRowHeight: CGFloat = 49
    /// `TabBarContainerImpl` 的类名（pw 也是按名字找它：它是 Spotify 那条栏的容器 VC）。
    private static let containerClassName = "_TtC23NavigationUI_TabBarImpl19TabBarContainerImpl"

    static var isEnabled: Bool { UserDefaults.tabBarSystemGlass }

    // MARK: - 状态（全部挂在**别人的对象**上：关联对象 / 弱注册表）

    private static var systemBarKey: UInt8 = 0
    private static var roomKey: UInt8 = 0

    /// 被我们按成透明的内容视图（**弱引用**，页面走了它自己就没了）+ 它们各自的**原 alpha**。
    ///
    /// ⚠️ 必须记"每一个自己的原值"，不能一律写 1：Spotify 自己也会把某些颗按掉
    /// （仓库在封面那条路上已经踩过"统一写回 1 = 永久错"的坑，见 `NowPlayingLyricsPlate.hideCoverView`）。
    private static let hiddenContent = NSHashTable<UIView>.weakObjects()
    private static var hiddenContentAlphas: [ObjectIdentifier: CGFloat] = [:]

    /// 系统栏量出来的高度**只量一次**：让出高度之后 `sizeThatFits` 会要得更多（pw 的注释里点了这件事）。
    private static var measuredGlassHeight: CGFloat = 0

    private static var lastBar: UIView?
    private static var lastSkipReason = ""
    private static var lastSelectionIndex = -1
    private static var didLogLayout = false

    // MARK: - 对外入口

    /// 幂等。由 `TabBarPlateHook.layoutSubviews`（栏自己每次布局）与复查节拍调用。
    static func apply(to bar: UIView) {
        lastBar = bar

        guard isEnabled else {
            remove(reason: "switch off", in: bar)
            return
        }
        guard bar.bounds.width > 1, bar.bounds.height > 1 else { return }
        guard let stack = TabBarGlassPlate.findTabsStack(in: bar) else {
            noteSkipOnce("no tabs stack yet")
            return
        }

        let items = stack.subviews
        guard !items.isEmpty else { return }

        // ① 藏掉 Spotify 自己的内容（**栏本身不动**：frame / 交互 / inset 全都不碰）。
        hideStockContent(items)

        // ② 系统栏 + 它的 item（顺序、图标、文字都从 Spotify 那几颗来）。
        let systemBar = ensureBar(in: bar)
        syncItems(on: systemBar, from: items)

        // ③ 选中态：气泡要跟着 Spotify 走。
        syncSelection(on: systemBar, items: items)

        // ④ 让高度（放在最后：量高度要用**还没让过高度**的那次结果）。
        makeRoom(for: bar, systemBar: systemBar)

        logLayoutOnce(bar: bar, stack: stack, systemBar: systemBar, items: items)
    }

    /// 设置页切开关 / 复查节拍用：手里那次记下的栏还在窗口里就当场重来一次。
    static func reapply() {
        guard let bar = lastBar, bar.window != nil else { return }
        apply(to: bar)
    }

    /// 拿走（关开关 / 页面走了）。**精确还原三件事**：系统栏、内容 alpha、`additionalSafeAreaInsets`。
    static func remove(reason: String, in bar: UIView? = nil) {
        let target = bar ?? lastBar
        if let target {
            if let systemBar = objc_getAssociatedObject(target, &systemBarKey) as? UITabBar {
                systemBar.removeFromSuperview()
                objc_setAssociatedObject(target, &systemBarKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
                writeDebugLog("[\(logTag)] system bar removed (reason=\(reason))")
            }
            restoreRoom(in: target)
        }
        restoreStockContent()
        measuredGlassHeight = 0
        didLogLayout = false
        lastSelectionIndex = -1
    }

    // MARK: - ① 藏 Spotify 自己的内容

    /// 把栈里那几颗按成透明（**不隐藏视图本身**，交互与布局完全不动）。
    private static func hideStockContent(_ items: [UIView]) {
        for item in items where item.alpha != 0 {
            if hiddenContentAlphas[ObjectIdentifier(item)] == nil {
                hiddenContentAlphas[ObjectIdentifier(item)] = item.alpha
                hiddenContent.add(item)
            }
            item.alpha = 0
        }
    }

    /// 还原成**每一颗自己的**原 alpha（没记过的不碰）。
    private static func restoreStockContent() {
        for item in hiddenContent.allObjects {
            if let original = hiddenContentAlphas[ObjectIdentifier(item)] {
                item.alpha = original
            }
        }
        hiddenContent.removeAllObjects()
        hiddenContentAlphas.removeAll()
    }

    // MARK: - ② 系统栏与它的 item

    private static func ensureBar(in bar: UIView) -> UITabBar {
        if let existing = objc_getAssociatedObject(bar, &systemBarKey) as? TabBarSystemGlassBar {
            if existing.superview !== bar { bar.addSubview(existing) }
            if existing.frame != bar.bounds { existing.frame = bar.bounds }
            bar.bringSubviewToFront(existing)
            return existing
        }

        let systemBar = TabBarSystemGlassBar(frame: bar.bounds)
        systemBar.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        // UIKit 按"这条栏继承到的外观"画玻璃，而这条栏在 Spotify 自己的深色导航栈之外
        // ⇒ 浅色模式的手机上会出现"亮玻璃压在纯黑上"。Spotify 永远是深色，这条栏也是。
        systemBar.overrideUserInterfaceStyle = .dark
        systemBar.accessibilityIdentifier = "eevee-tabbar-system-glass"
        // ★ 这一片**不吃触摸**（见文件头）：点下去落到 Spotify 自己那条栏上，点击行为不变。
        systemBar.isUserInteractionEnabled = false
        // 自己的背景不要画：我们要的是系统玻璃本身。
        systemBar.backgroundImage = UIImage()
        systemBar.shadowImage = UIImage()
        systemBar.isTranslucent = true

        bar.addSubview(systemBar)
        bar.bringSubviewToFront(systemBar)
        objc_setAssociatedObject(bar, &systemBarKey, systemBar, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        writeDebugLog(
            "[\(logTag)] system bar added \(frameText(bar.bounds)) on \(NSStringFromClass(type(of: bar)))"
        )
        return systemBar
    }

    /// 从 Spotify 那几颗同步 item（**顺序一致**，索引就是选中态的对齐依据）。
    private static func syncItems(on systemBar: UITabBar, from items: [UIView]) {
        var wanted: [UITabBarItem] = []
        wanted.reserveCapacity(items.count)
        for item in items {
            let title = labelText(of: item)
            let image = glyphImage(of: item)?.withRenderingMode(.alwaysTemplate)
            wanted.append(UITabBarItem(title: title, image: image, tag: wanted.count))
        }

        let current = systemBar.items ?? []
        let sameShape = current.count == wanted.count && zip(current, wanted).allSatisfy { pair in
            pair.0.title == pair.1.title && pair.0.image === pair.1.image
        }
        guard !sameShape else { return }
        systemBar.items = wanted
        lastSelectionIndex = -1
        writeDebugLog(
            "[\(logTag)] items synced — \(wanted.count) item(s), titles \(wanted.map { $0.title ?? "-" })"
        )
    }

    /// ③ 选中态：优先用**无障碍标记**（公共 API），拿不到再退回"谁的文字是白色那档"。
    private static func syncSelection(on systemBar: UITabBar, items: [UIView]) {
        guard let index = selectedIndex(items: items),
              index < (systemBar.items?.count ?? 0) else { return }
        guard index != lastSelectionIndex else { return }
        lastSelectionIndex = index
        systemBar.selectedItem = systemBar.items?[index]
        writeDebugLog("[\(logTag)] selection → #\(index)")
    }

    /// 哪一颗是选中：`accessibilityTraits.contains(.selected)` 是公共 API，先用它；
    /// 真机上要是这个标记不生效，退回**文字亮度**（Spotify 选中那颗画白色、其余 #B3B3B3）。
    private static func selectedIndex(items: [UIView]) -> Int? {
        if let index = items.firstIndex(where: { $0.accessibilityTraits.contains(.selected) }) {
            return index
        }
        if let index = items.firstIndex(where: { isBrightLabel($0) }) { return index }
        return nil
    }

    private static func isBrightLabel(_ node: UIView) -> Bool {
        guard let color = firstLabelColor(node) else { return false }
        var white: CGFloat = 0, alpha: CGFloat = 0
        if color.getWhite(&white, alpha: &alpha) { return white > 0.85 }
        return false
    }

    /// 有界找第一段文字的颜色（深度 ≤ 4，与探针同一套读法）。
    private static func firstLabelColor(_ node: UIView, depth: Int = 0) -> UIColor? {
        guard depth <= 4 else { return nil }
        if let label = node as? UILabel, let text = label.text, !text.isEmpty {
            return label.textColor
        }
        for sub in node.subviews {
            if let found = firstLabelColor(sub, depth: depth + 1) { return found }
        }
        return nil
    }

    /// 那一颗的图标（最近的一个有图的 `UIImageView`；「隐藏标签文字」开着时它是仅存的信息）。
    private static func glyphImage(of node: UIView, depth: Int = 0) -> UIImage? {
        guard depth <= 4 else { return nil }
        if let imageView = node as? UIImageView, let image = imageView.image { return image }
        for sub in node.subviews {
            if let found = glyphImage(of: sub, depth: depth + 1) { return found }
        }
        return nil
    }

    /// 那一颗的文字（我们自己的「隐藏标签文字」把它藏掉时返回 nil ⇒ 系统栏只画图标，与屏幕一致）。
    private static func labelText(of node: UIView, depth: Int = 0) -> String? {
        guard depth <= 4 else { return nil }
        if let label = node as? UILabel, let text = label.text, !text.isEmpty, label.alpha > 0.01 {
            return text
        }
        for sub in node.subviews {
            if let found = labelText(of: sub, depth: depth + 1) { return found }
        }
        return nil
    }

    // MARK: - ④ 让高度

    /// 把系统栏**比 Spotify 那条栏多出来的高度**写成容器的 `additionalSafeAreaInsets.bottom`。
    ///
    /// 为什么是这里（pw 的注释写得很清楚）：Spotify 那条栏的高度由"安全区往上 49pt"决定，
    /// 迷你播放器站在同一条基准上，页面拿 49 + inset ⇒ **只要容器多让出多少，那一整套自己就跟着让**，
    /// 我们不用去动任何人的 frame。`additionalSafeAreaInsets` 是**我们写的**，关开关时能**精确写回**。
    private static func makeRoom(for bar: UIView, systemBar: UITabBar) {
        guard let container = container(of: bar), container.isViewLoaded,
              let view = container.view else {
            noteSkipOnce("no TabBarContainerImpl above the bar - not making room")
            return
        }

        let extra = container.additionalSafeAreaInsets
        let inset = view.safeAreaInsets.bottom - extra.bottom
        let height = glassHeight(systemBar, width: bar.bounds.width)
        // Spotify 的常规宽度栏是固定 76pt、不吃 inset；窄宽度时它的栏就是 49 + inset。
        let compact = container.traitCollection.horizontalSizeClass == .compact
        let room = compact ? max(0, ceil(height - stockRowHeight - inset)) : 0
        guard abs(extra.bottom - room) > 0.5 else { return }

        rememberOriginalRoom(for: container, current: extra.bottom)

        var updated = extra
        updated.bottom = room
        container.additionalSafeAreaInsets = updated
        writeDebugLog(
            "[\(logTag)] made room under Spotify's bar: \(Int(room))pt"
                + " (glass \(Int(height)) - row \(Int(stockRowHeight)) - inset \(Int(inset)))"
        )
    }

    private static func glassHeight(_ systemBar: UITabBar, width: CGFloat) -> CGFloat {
        if measuredGlassHeight > 0 { return measuredGlassHeight }
        measuredGlassHeight = systemBar
            .sizeThatFits(CGSize(width: max(width, 1), height: stockRowHeight))
            .height
        return measuredGlassHeight
    }

    private static func restoreRoom(in bar: UIView) {
        guard let container = container(of: bar) else { return }
        guard let state = objc_getAssociatedObject(container, &roomKey) as? RoomState else { return }
        var insets = container.additionalSafeAreaInsets
        guard abs(insets.bottom - state.written) < 0.5 else { return }
        insets.bottom = state.original
        container.additionalSafeAreaInsets = insets
        objc_setAssociatedObject(container, &roomKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        writeDebugLog("[\(logTag)] room restored to \(Int(state.original))pt")
    }

    private final class RoomState: NSObject {
        let original: CGFloat
        let written: CGFloat
        init(original: CGFloat, written: CGFloat) {
            self.original = original
            self.written = written
        }
    }

    /// 第一次写之前记下**原来那个值**（我们只许改自己改过的那一档；别人写过的值不动）。
    private static func rememberOriginalRoom(for container: UIViewController, current: CGFloat) {
        guard objc_getAssociatedObject(container, &roomKey) == nil else { return }
        objc_setAssociatedObject(
            container,
            &roomKey,
            RoomState(original: current, written: current),
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }

    /// 从栏往上找 `TabBarContainerImpl`（pw 也是这么找的：它是这条栏的容器 VC）。
    private static func container(of bar: UIView) -> UIViewController? {
        guard let containerClass = NSClassFromString(containerClassName) else { return nil }
        var responder: UIResponder? = bar.next
        var hops = 0
        while let current = responder, hops < 30 {
            if let controller = current as? UIViewController, type(of: controller) == containerClass {
                return controller
            }
            responder = current.next
            hops += 1
        }
        return nil
    }

    // MARK: - 日志与小工具

    private static func noteSkipOnce(_ reason: String) {
        guard lastSkipReason != reason else { return }
        lastSkipReason = reason
        writeDebugLog("[\(logTag)] standing by (\(reason))")
    }

    private static func logLayoutOnce(
        bar: UIView,
        stack: UIView,
        systemBar: UITabBar,
        items: [UIView]
    ) {
        guard !didLogLayout else { return }
        didLogLayout = true
        let traits = items.map { $0.accessibilityTraits.contains(.selected) ? "S" : "-" }.joined()
        writeDebugLog(
            "[\(logTag)] installed — \(items.count) item(s) mirrored from the stock row"
                + " \(frameText(stack.frame)); system bar \(frameText(systemBar.frame))"
                + "; selected flags [\(traits)]; class \(NSStringFromClass(type(of: systemBar)))"
                + "; not taking touches in this build (taps fall through to Spotify's own bar)"
        )
    }

    private static func frameText(_ frame: CGRect) -> String {
        "\(Int(frame.origin.x)),\(Int(frame.origin.y)),\(Int(frame.width)),\(Int(frame.height))"
    }
}

/// 系统栏本体。
///
/// 这一片它**只负责长得对**（真玻璃 + 让选中气泡跟着走），**不接管触摸** —— 见文件头的说明。
final class TabBarSystemGlassBar: UITabBar {
}
