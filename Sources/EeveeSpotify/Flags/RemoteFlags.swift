import Foundation

// 远端配置（flag）的引擎：在 Spotify 读 flag 的那一刻，把用户覆盖与本仓库的强制值装进去。
//
// 与原有的改响应体那条路并存：`SpotifyResponsePatcher` 拿到 customize 的 `assignedValues`，`DynamicModifyingFunctions.modifyAssignedValues` 按 `FlagOverrideStore.activeReplacements` 逐条改。那一层管"服务端下发时"的改写，这一层管"客户端读取时"：`RemoteConfigurationSDK` 的 `boolValueForId:defaultValue:` / `intValueForId:lower:upper:defaultValue:` / `enumValueForId:values:defaultValue:` 被截住，直接返回覆盖值。两条路读同一张表（`FlagOverrideStore`），值一定一致；差别只在于"没进 customize 响应、但客户端会去读"的那些 flag，只有这一层盖得住。
//
// 钩取值入口的好处是不需要预先知道有哪些 flag：顺手把每条读到的（种类 / 当前值 / 整数上下限 / enum 可选值）记下来，20 秒后落盘成 `flags.json`，设置页因此能列出真实存在的开关，而不是手抄一份名单。
//
// 目标类（`RemoteConfigurationSDK` 桶里两个）：
// · `_TtC22RemoteConfigurationSDK25ConfigurationProviderImpl`
// · `_TtC22RemoteConfigurationSDK35ObservableConfigurationProviderImpl`
//
// 采集时机：`catalogIsCurrent` = 盘上 `flags.json` 的 Spotify 版本号 == 当前版本。不相等（刚升级完）或置了 `eeveeFlagCapture` 时进入采集模式：只记录、照样返回覆盖值，20 秒后写盘并打戳。采集模式本身不影响行为，代价只是那次启动多装一组 hook。
enum FlagKind: String, Codable {
    case bool
    case int
    case choice
}

/// 运行时**扫到**的一条远端配置项。
struct FlagInfo: Codable, Identifiable, Hashable {
    let key: String
    let kind: FlagKind
    let value: String
    var lower: Int?
    var upper: Int?
    var options: [String]?

    var id: String { key }

    /// `ios-feature-yourlibaryx.enable_x` 里 `.` **之前**那段（scope / 组件名）。
    ///
    /// 与 `FlagOverride.id`（`scope.isEmpty ? name : "scope.name"`）同一套拼法，
    /// 所以「浏览器里改一条」与「`FlagOverrideStore` 里存一条」是同一个 id。
    var component: Substring {
        key.firstIndex(of: ".").map { key[..<$0] } ?? ""
    }

    /// `.` **之后**那段（属性名）。
    var property: Substring {
        key.firstIndex(of: ".").map { key[key.index(after: $0)...] } ?? Substring(key)
    }
}

private struct FlagCatalog: Codable {
    let spotifyVersion: String
    let flags: [FlagInfo]
}

/// 读时拦截 + 自动采集。
///
/// ## 唯一真相
///
/// 覆盖值**不另存一份**：`overrides` 是从 `FlagOverrideStore`（本仓库原来那张表，
/// `flagOverrides` 里存 JSON）**派生**出来的，`.on→true / .off→false / .set→字符串 /
/// .number→整数`，`.remove` 没有"值"可读、由改响应体那条路负责。
/// ⇒ 设置页的两种写法（浏览器 / 手写表）与备份、重置、单测全都还是同一处。
///
/// ## 线程
///
/// `resolve` 在 Spotify 的取值热路径上（每条 flag 每一次读都会进来），所以：
/// · `effective` 是**不可变快照**（`prepare` 之后只读，不加锁）；
/// · 计数与采集走 `lock`，且**只做字典写入**，不做 IO；
/// · 落盘在 `utility` 队列上延迟 20 秒做一次（合并直播期间的所有记录）。
final class RemoteFlags {
    static let shared = RemoteFlags()

    private static let catalogVersionKey = "eeveeFlagCatalogVersion"
    private static let captureKey = "eeveeFlagCapture"

    /// 当前 Spotify 版本 —— 采集结果按它打戳（升级后自动重采）。
    let spotifyVersion: String =
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "?"

    /// 本仓库**自己**写死的强制值（不是用户设置）。今天没人调用 `force`，
    /// 留着是因为浏览器要能显示"这条被我们锁死了"，而不是让它看起来可改。
    ///
    /// ⚠️ 写成"私有存储 + 只读计算属性"而不是 `private(set) var`：仓库的
    /// `swift_member_check.py` 会把 `private(set)` 误解析成一个名叫 `set` 的私有成员，
    /// 于是全仓每一处 `.set` 都被判成"跨文件访问私有属性"（实测 17 条假红）。
    var forced: [String: Any] { forcedStorage }
    private var forcedStorage: [String: Any] = [:]

    /// `overrides + forced` 的合并结果（`prepare` 之后只读）。
    private var effective: [String: Any] = [:]

    private let lock = NSLock()
    private var seen: [String: FlagInfo] = [:]
    private var applied = 0
    private var hookTicks: UInt64 = 0
    private var reads = 0
    private var flushScheduled = false
    private var cataloguing = true

    private lazy var catalogURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let dir = base.appendingPathComponent("EeveeSpotify", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("flags.json")
    }()

    // MARK: - 设置页那一侧
    //
    // 当前覆盖表（从 `FlagOverrideStore` 派生；见类型说明）。
    static var overrides: [String: Any] {
        var result: [String: Any] = [:]
        for item in FlagOverrideStore.all where item.isValid {
            switch item.mode {
            case .on:
                result[item.id] = true
            case .off:
                result[item.id] = false
            case .set:
                result[item.id] = item.value
            case .number:
                let trimmed = item.value.trimmingCharacters(in: .whitespacesAndNewlines)
                if let number = Int(trimmed) {
                    result[item.id] = number
                }
            case .remove:
                // 「把这条整个删掉」没有可读的"值" —— 由改响应体那条路负责。
                break
            }
        }
        return result
    }

    /// 启动那一刻的覆盖表快照（`static let` 惰性求值，`activateRemoteFlags` 先摸它一下）。
    static let launchOverrides: [FlagOverride] = FlagOverrideStore.all

    /// 改过就必须重启才生效（远端配置按会话下发一次）。
    static var needsRestart: Bool { FlagOverrideStore.all != launchOverrides }

    /// 下一次启动进入采集模式（设置页「重新扫描」）。
    static func requestCapture() {
        UserDefaults.standard.set(true, forKey: captureKey)
    }

    var catalogIsCurrent: Bool {
        UserDefaults.standard.string(forKey: Self.catalogVersionKey) == spotifyVersion
    }

    func loadCatalog() -> [FlagInfo] {
        guard let data = try? Data(contentsOf: catalogURL),
              let catalog = try? JSONDecoder().decode(FlagCatalog.self, from: data) else { return [] }
        return catalog.flags
    }

    // MARK: - 启动时

    func force(_ flags: [String: Any], by owner: String) {
        forcedStorage.merge(flags) { _, new in new }
        writeDebugLog("[Flags] \(owner) forces \(flags.count) flag(s)")
    }

    var needsHooks: Bool {
        !Self.overrides.isEmpty
            || !forced.isEmpty
            || !catalogIsCurrent
            || UserDefaults.standard.bool(forKey: Self.captureKey)
    }

    /// 装 hook 之前调一次：把快照合并好、把采集模式定下来（并清掉一次性标记）。
    func prepare() {
        effective = Self.overrides.merging(forced) { _, forcedValue in forcedValue }
        cataloguing = !catalogIsCurrent || UserDefaults.standard.bool(forKey: Self.captureKey)
        UserDefaults.standard.removeObject(forKey: Self.captureKey)
    }

    // MARK: - 热路径
    //
    // 每次 Spotify 读一条 flag 都会进来一次。
    //
    // - Returns: 覆盖值；`nil` = 没覆盖，调用方自己用 `orig`。
    func resolve(
        _ key: String,
        kind: FlagKind,
        orig: Any,
        lower: Int? = nil,
        upper: Int? = nil,
        options: @autoclosure () -> [String]? = nil,
        since start: UInt64
    ) -> Any? {
        let value = effective[key]

        lock.lock()
        reads += 1
        if value != nil { applied += 1 }
        if cataloguing, seen[key] == nil {
            seen[key] = FlagInfo(key: key, kind: kind, value: "\(orig)", lower: lower, upper: upper, options: options())
            scheduleFlushLocked()
        } else if !cataloguing, reads == 1 {
            scheduleFlushLocked()
        }
        hookTicks &+= mach_absolute_time() &- start
        lock.unlock()

        return value
    }

    private func scheduleFlushLocked() {
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 20) { [weak self] in
            self?.flush()
        }
    }

    private func flush() {
        lock.lock()
        flushScheduled = false
        let fresh = seen
        let readCount = reads
        let appliedCount = applied
        let ticks = hookTicks
        lock.unlock()

        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let cost = Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000
        let costText = String(format: "%.2f", cost)

        guard cataloguing else {
            writeDebugLog("[Flags] \(readCount) read(s), \(appliedCount) overridden, hook cost \(costText) ms")
            return
        }

        var merged = catalogIsCurrent
            ? Dictionary(loadCatalog().map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
            : [:]
        merged.merge(fresh) { _, new in new }

        let catalog = FlagCatalog(
            spotifyVersion: spotifyVersion,
            flags: merged.values.sorted { $0.key < $1.key }
        )
        do {
            try JSONEncoder().encode(catalog).write(to: catalogURL, options: .atomic)
            UserDefaults.standard.set(spotifyVersion, forKey: Self.catalogVersionKey)
            writeDebugLog(
                "[Flags] catalogued \(catalog.flags.count) flag(s) for Spotify \(spotifyVersion)"
                    + " — \(readCount) read(s), \(appliedCount) overridden, hook cost \(costText) ms"
            )
        } catch {
            writeDebugLog("[Flags] catalog write failed: \(error)")
        }
    }
}
