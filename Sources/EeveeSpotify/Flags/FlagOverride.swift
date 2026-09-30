import Foundation

/// 一条用户自定义的 Spotify 远端配置（flag）覆盖。
///
/// 对应设置页「Flag 覆盖」里的一行。`scope` 留空表示**不限 scope**：
/// 只改服务端已经下发过的同名 flag。`.forceBool` 需要有 scope 才能在"服务端根本
/// 没下发这条"时补一条（见 `FlagOverride+Replacement.swift`），所以空 scope +
/// On/Off 只对已下发的生效，而 `remove` 配空 scope 是有用的写法（跨 scope 全删）。
struct FlagOverride: Codable, Equatable, Identifiable {

    enum Mode: String, Codable, CaseIterable {
        /// 强制为 true（缺失且给了 scope 时补一条）。
        case on
        /// 强制为 false（缺失且给了 scope 时补一条）。
        case off
        /// 把这条 flag 整个删掉。
        case remove
        /// 写入 `value` 里那个 enum 值（例如 `count`）。
        ///
        /// 只改**服务端已下发**的条目 —— `EeveePropertyModification.setEnum` 不会补新条目，
        /// 所以这条模式配不存在的 name/scope 就是空枪（日志里会显示 0 match）。
        case set

        var localizedKey: String {
            switch self {
            case .on: return "flag_override_mode_on"
            case .off: return "flag_override_mode_off"
            case .remove: return "flag_override_mode_remove"
            case .set: return "flag_override_mode_set"
            }
        }
    }

    var name: String
    var scope: String
    var mode: Mode

    /// 只有 `mode == .set` 用：要写入的 enum 值。
    var value: String

    /// 同一 `scope + name` 视为同一条，重复添加是覆盖而不是追加（`value` 不参与身份）。
    var id: String { scope.isEmpty ? name : "\(scope).\(name)" }

    /// `.set` 必须带值，否则写入的是一个空 enum。UI 会禁掉这种输入，
    /// 这里再兜一层：`activeReplacements` 会把不合法的条目滤掉。
    var isValid: Bool {
        mode != .set || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    init(name: String, scope: String = "", mode: Mode, value: String = "") {
        self.name = name
        self.scope = scope
        self.mode = mode
        self.value = value
    }

    /// 手写解码：`value` 是后加的字段，早期数据里没有它。合成解码器遇到缺字段会抛，
    /// 而 `FlagOverrideStore.all` 解失败会**返回空表** —— 那就等于一次升级把用户
    /// 已有的覆盖全清了。用 `decodeIfPresent` 兜住。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        name = try container.decode(String.self, forKey: .name)
        scope = try container.decode(String.self, forKey: .scope)
        mode = try container.decode(Mode.self, forKey: .mode)
        value = try container.decodeIfPresent(String.self, forKey: .value) ?? ""
    }
}

/// 覆盖表的持久化与增删改（**纯 Foundation**，可以被单元测试单独编译）。
///
/// 只做存取，不碰 Spotify 的 protobuf 类型 —— 映射成 `EeveePropertyReplacement`
/// 那一步在 `FlagOverride+Replacement.swift`，于是这张表和它的测试都不依赖
/// Premium 模块，也不需要 Orion。
enum FlagOverrideStore {

    /// 直接落在 `.standard` 上。
    ///
    /// 仓库里的 `UserDefaults.container` 从未被改成别的 suite（全仓只有声明处一处
    /// 赋值），而 `FullResetHelper` 的「重置数据」清的也正是 `.standard` —— 走
    /// `.standard` 才能保证重置能把这张表一起清掉。测试里替换成独立 suite。
    static var container: UserDefaults = .standard

    private static let storageKey = "flagOverrides"
    private static let lock = NSLock()

    static var all: [FlagOverride] {
        get {
            lock.lock(); defer { lock.unlock() }
            return readUnlocked()
        }
        set {
            lock.lock(); defer { lock.unlock() }
            writeUnlocked(newValue)
        }
    }

    static var count: Int { all.count }

    /// 同名同 scope 覆盖旧值，否则追加。返回是否替换了已有条目。
    @discardableResult
    static func upsert(_ override: FlagOverride) -> Bool {
        var replaced = false

        mutate { items in
            if let index = items.firstIndex(where: { $0.id == override.id }) {
                items[index] = override
                replaced = true
            } else {
                items.append(override)
            }
        }

        return replaced
    }

    static func remove(id: String) {
        mutate { items in
            items.removeAll { $0.id == id }
        }
    }

    static func removeAll() {
        mutate { $0 = [] }
    }

    // MARK: - 加锁的读改写

    /// 读-改-写必须在**同一把锁**里完成：`all` 的 getter/setter 各自加锁，
    /// 直接把 `all` 读出来改完再写回去，两个线程同时干就会丢条目。
    /// 今天只有设置页在写，所以这是潜伏问题而不是已发生的问题 —— 一并修掉。
    private static func mutate(_ body: (inout [FlagOverride]) -> Void) {
        lock.lock(); defer { lock.unlock() }

        var items = readUnlocked()
        body(&items)
        writeUnlocked(items)
    }

    private static func readUnlocked() -> [FlagOverride] {
        guard let data = container.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([FlagOverride].self, from: data) else {
            return []
        }
        return decoded
    }

    private static func writeUnlocked(_ items: [FlagOverride]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        container.set(data, forKey: storageKey)
    }
}
