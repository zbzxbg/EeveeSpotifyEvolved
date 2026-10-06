import Foundation
import ObjectiveC.runtime

/// 暴力查类：先 `NSClassFromString`，查不到就**全类枚举一次**并缓存。
///
/// ## 为什么需要它
///
/// 上游在 tester log 里实测过一个坑：**tweak 初始化那一刻查类会漏**。
/// `NSClassFromString` 走的是"已注册类"这张表，而有些类要等它所属的模块晚一步注册 ——
/// 那一刻查不到，表现是每个 hook 都报 `unavailable`（跳过），**而广告/推销卡片照样渲染**，
/// 于是日志看起来"一切正常"。
///
/// 所以这里给一条兜底：`NSClassFromString` 失败时把全类列表扫一遍（只扫一次，之后走缓存）。
///
/// ## ⚠️ 为什么用 `objc_getClassList` + 裸缓冲区，而不是 `objc_copyClassList`
///
/// `objc_copyClassList` 返回的是 `AutoreleasingUnsafeMutablePointer`，**对它做下标**会触发
/// retain / autorelease 的 msgSend，在 iOS 26+ 上会**直接 abort**。
/// 裸缓冲区（`UnsafeMutablePointer` + `load(fromByteOffset:)`）没有这个问题 ——
/// 这与 `EeveeProbes` 踩的是同一个坑，别再换回去。
private var tweakClassCache: [String: AnyClass] = [:]
private var tweakClassCacheBuilt = false

func findTweakClass(_ name: String) -> AnyClass? {
    if let cls = NSClassFromString(name) { return cls }
    if tweakClassCacheBuilt { return tweakClassCache[name] }

    let total = objc_getClassList(nil, 0)
    guard total > 0 else { return nil }

    let buffer = UnsafeMutablePointer<AnyClass>.allocate(capacity: Int(total))
    defer { buffer.deallocate() }

    let count = objc_getClassList(AutoreleasingUnsafeMutablePointer<AnyClass>(buffer), total)
    for index in 0..<Int(count) {
        let raw = UnsafeRawPointer(buffer).load(
            fromByteOffset: index * MemoryLayout<UnsafeRawPointer>.size,
            as: UnsafeRawPointer.self
        )
        let cls = unsafeBitCast(raw, to: AnyClass.self)
        tweakClassCache[String(cString: class_getName(cls))] = cls
    }

    tweakClassCacheBuilt = true
    return tweakClassCache[name]
}
