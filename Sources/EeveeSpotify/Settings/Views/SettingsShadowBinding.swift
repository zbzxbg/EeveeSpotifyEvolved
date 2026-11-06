import SwiftUI

/// 「影子值 + 落盘」的绑定：先改本地 `@State`（让 SwiftUI 失效重绘），再写 `UserDefaults`。
///
/// ## 为什么不能直接绑 UserDefaults
///
/// 直接绑一个读 `UserDefaults` 的临时 `Binding`：
/// `Binding(get: { UserDefaults.xxx }, set: { UserDefaults.xxx = $0 })` 的话，
/// 写 `UserDefaults` **不会**让 SwiftUI 失效重绘 ——
/// · `Toggle` 自己会重绘，所以看不出问题；
/// · 而 `Picker` / 带自绘标签的控件是**父视图求值**出来的，于是选完仍显示旧值，
/// 要等页面被重建（重启 Spotify）才更新。
///
/// 每个设置页因此都持有一份"影子值"（`@State private var shadow = Shadow`），用它来生成
/// 绑定：
///
/// ```swift
/// Toggle("...".localized, isOn: settingsShadowBinding($shadow.miniBarGlass) { value in
///     UserDefaults.miniBarGlass = value
///     MiniBarGlassPlate.reconcileNow()      // ← 需要"当场生效"的副作用写在这里
/// })
/// ```
///
/// ⚠️ 影子值必须在页面出现时重同步（`onAppear { shadow = Shadow }`）：别处（Flag 页 /
/// 重置本页 / 导入备份）改了 `UserDefaults` 时，否则影子值会停在旧值上。
///
/// 这一对函数是**一个**通用版本（不再每个页面各写一份）：
/// 副作用一律由调用方在 `persist` 里写明，不用为每种"要多做一步"的开关再造一个 helper。
func settingsShadowBinding<Value>(
    _ shadow: Binding<Value>,
    persist: @escaping (Value) -> Void
) -> Binding<Value> {
    Binding(
        get: { shadow.wrappedValue },
        set: { value in
            shadow.wrappedValue = value
            persist(value)
        }
    )
}
