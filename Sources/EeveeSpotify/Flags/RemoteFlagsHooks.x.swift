import Foundation
import ObjectiveC.runtime
import Orion

// 远端配置（flag）的**读时拦截**：钩 Spotify 自己的 `RemoteConfigurationSDK`。
//
// 上游原型：`SideloadLabs/EeveeSpotifyReincarnated` → `Flags/RemoteFlagsHooks.x.swift`
// （用他们的之后移植）。引擎与设置页在 `RemoteFlags.swift`。
//
// ── 为什么钩这三个方法就够
//
// Spotify 的远端配置最终都收敛成三种取值（bool / int / enum），客户端拿值的入口就是
// 这三个方法：
// · `boolValueForId:defaultValue:`
// · `intValueForId:lower:upper:defaultValue:`
// · `enumValueForId:values:defaultValue:`
// 覆盖到它们，就等于"不管这条 flag 从哪条链路来、有没有进 customize 响应，
// 只要客户端问，答的都是我们的值"。
//
// ── 两个类，两套装法（别合并）
//
// `_TtC22RemoteConfigurationSDK25ConfigurationProviderImpl` 是 NSObject 派生的 Swift 类
// ⇒ Orion 的 `ClassHook` 直接可用。
// `_TtC22RemoteConfigurationSDK35ObservableConfigurationProviderImpl` 是**纯 Swift 类**
// （没有 NSObject 基类），Orion 的 `ClassHook` 找不到可换的 objc 方法 ⇒ 手动
// swizzle 它的三个 @objc 方法（同上游做法）。
//
// 类名判据：解压产物里逐字有这两个类与这三个 selector
// （见 `RemoteFlags.swift` 文件头）。探测不到就**什么都不装**，只写一行日志 ——
// 这与本仓库对私有类的纪律一致（不猜、不崩）。

struct RemoteFlagsGroup: HookGroup {}

private enum FlagResolve {
    static func bool(_ key: NSString, _ orig: Bool, _ start: UInt64) -> Bool {
        let value = RemoteFlags.shared.resolve(key as String, kind: .bool, orig: orig, since: start)
        return (value as? NSNumber)?.boolValue ?? orig
    }

    static func int(_ key: NSString, _ lower: Int, _ upper: Int, _ orig: Int, _ start: UInt64) -> Int {
        let value = RemoteFlags.shared.resolve(
            key as String, kind: .int, orig: orig, lower: lower, upper: upper, since: start
        )
        guard let number = value as? NSNumber else { return orig }
        return min(max(number.intValue, lower), upper)
    }

    static func choice(_ key: NSString, _ values: NSArray, _ orig: AnyObject, _ start: UInt64) -> AnyObject {
        let value = RemoteFlags.shared.resolve(
            key as String, kind: .choice, orig: orig,
            options: values.compactMap { $0 as? String }, since: start
        )
        // 只认服务端自己给的候选值：写了一个不在 values 里的字符串就当没覆盖
        // （否则 `enumValueForId` 会拿到一个 Spotify 从没听说过的取值）。
        guard let string = value as? NSString, values.contains(string) else { return orig }
        return string
    }
}

class RemoteFlagsConfigurationProviderHook: ClassHook<NSObject> {
    typealias Group = RemoteFlagsGroup
    static let targetName = "_TtC22RemoteConfigurationSDK25ConfigurationProviderImpl"

    func boolValueForId(_ key: NSString, defaultValue: Bool) -> Bool {
        let value = orig.boolValueForId(key, defaultValue: defaultValue)
        return FlagResolve.bool(key, value, mach_absolute_time())
    }

    func intValueForId(_ key: NSString, lower: Int, upper: Int, defaultValue: Int) -> Int {
        let value = orig.intValueForId(key, lower: lower, upper: upper, defaultValue: defaultValue)
        return FlagResolve.int(key, lower, upper, value, mach_absolute_time())
    }

    func enumValueForId(_ key: NSString, values: NSArray, defaultValue: AnyObject) -> AnyObject {
        let value = orig.enumValueForId(key, values: values, defaultValue: defaultValue)
        return FlagResolve.choice(key, values, value, mach_absolute_time())
    }
}

/// 纯 Swift 类的三个 @objc 方法（`ClassHook` 装不上，见文件头）。
private enum ObservableFlagProviderSwizzle {
    static let targetName = "_TtC22RemoteConfigurationSDK35ObservableConfigurationProviderImpl"

    /// - Returns: 装上了几个方法（0 = 这个类不在这一版里）。
    static func install() -> Int {
        guard let cls = NSClassFromString(targetName) else { return 0 }
        var installed = 0

        let boolSelector = NSSelectorFromString("boolValueForId:defaultValue:")
        if let method = class_getInstanceMethod(cls, boolSelector) {
            typealias Signature = @convention(c) (AnyObject, Selector, NSString, Bool) -> Bool
            let original = unsafeBitCast(method_getImplementation(method), to: Signature.self)
            let block: @convention(block) (AnyObject, NSString, Bool) -> Bool = { target, key, fallback in
                FlagResolve.bool(key, original(target, boolSelector, key, fallback), mach_absolute_time())
            }
            method_setImplementation(method, imp_implementationWithBlock(block))
            installed += 1
        }

        let intSelector = NSSelectorFromString("intValueForId:lower:upper:defaultValue:")
        if let method = class_getInstanceMethod(cls, intSelector) {
            typealias Signature = @convention(c) (AnyObject, Selector, NSString, Int, Int, Int) -> Int
            let original = unsafeBitCast(method_getImplementation(method), to: Signature.self)
            let block: @convention(block) (AnyObject, NSString, Int, Int, Int) -> Int = { target, key, lower, upper, fallback in
                FlagResolve.int(
                    key, lower, upper,
                    original(target, intSelector, key, lower, upper, fallback),
                    mach_absolute_time()
                )
            }
            method_setImplementation(method, imp_implementationWithBlock(block))
            installed += 1
        }

        let choiceSelector = NSSelectorFromString("enumValueForId:values:defaultValue:")
        if let method = class_getInstanceMethod(cls, choiceSelector) {
            typealias Signature = @convention(c) (AnyObject, Selector, NSString, NSArray, AnyObject) -> AnyObject
            let original = unsafeBitCast(method_getImplementation(method), to: Signature.self)
            let block: @convention(block) (AnyObject, NSString, NSArray, AnyObject) -> AnyObject = { target, key, values, fallback in
                FlagResolve.choice(
                    key, values,
                    original(target, choiceSelector, key, values, fallback),
                    mach_absolute_time()
                )
            }
            method_setImplementation(method, imp_implementationWithBlock(block))
            installed += 1
        }

        return installed
    }
}

/// 启动时调一次（`Tweak.x.swift` 的 `init` 里，紧跟 customize 种子之后）。
func activateRemoteFlags() {
    // ⚠️ 先摸一下启动快照：`needsRestart` 靠它跟当前值比。晚摸就会把"刚改过"
    // 当成"启动时就是这样"。
    _ = RemoteFlags.launchOverrides

    let flags = RemoteFlags.shared
    guard flags.needsHooks else {
        writeDebugLog("[Flags] off (no overrides, catalog current for \(flags.spotifyVersion))")
        return
    }
    guard NSClassFromString(RemoteFlagsConfigurationProviderHook.targetName) != nil else {
        writeDebugLog("[Flags] skipped: RemoteConfigurationSDK provider classes are missing")
        return
    }

    let start = CFAbsoluteTimeGetCurrent()
    flags.prepare()
    RemoteFlagsGroup().activate()
    let observable = ObservableFlagProviderSwizzle.install()
    let cost = String(format: "%.2f", (CFAbsoluteTimeGetCurrent() - start) * 1000)
    writeDebugLog(
        "[Flags] active: \(RemoteFlags.overrides.count) override(s), \(flags.forced.count) forced,"
            + " observable \(observable)/3, catalog \(flags.catalogIsCurrent ? "current" : "capturing"),"
            + " \(cost) ms"
    )
}
