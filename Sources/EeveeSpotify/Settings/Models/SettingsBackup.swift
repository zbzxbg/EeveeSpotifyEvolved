import Foundation

/// 「扩展功能 → 备份与重置」的后端：把**本仓库自己写的** UserDefaults 键导出成一段 JSON，
/// 再导入回来；以及"只重置我们的设置"。
///
/// ── 三条铁律（都写在代码里，别改）────────────────────────────────────────────
///   1. **只碰白名单**（`UserDefaults.ownedKeys`）：这个进程的 `.standard` 里同时躺着
///      **Spotify 自己的偏好**，全导/全删会把它一起带出去或一起清掉。
///      （`FullResetHelper` 那个"核弹"是另一个按钮的语义：重置 Spotify 状态，不是重置我们。）
///   2. **导入只认白名单里的键**：一份手改过的文件不该能把任意键写进进程；
///      未知键一律忽略并计数，导入完给用户一个诚实的数字。
///   3. **Data 键单独处理**：仓库里唯一的 Data 键是 `flagOverrides`（JSON 文本），
///      导出成**字符串**（好看、可手改），导入时再还原成 Data。其余值就是 plist 基础类型。
///
/// 纯 Foundation：不 import UIKit/Orion，可以被单测单独编译（与 `FlagOverrideStore` 同一纪律）。
enum SettingsBackup {

    /// 导出格式的版本号：将来结构变了，导入端能认出"这是老文件"。
    static let formatVersion = 1

    /// 那些"值是 Data、但内容是 JSON 文本"的键：导出成字符串、导入时还原。
    private static let dataKeysAsText: Set<String> = ["flagOverrides"]

    struct Result: Equatable {
        var applied: Int
        var skipped: Int
        var message: String
    }

    // MARK: - 导出

    /// 把白名单里的键收集成 `[String: Any]`（plist 可序列化的值）。
    static func snapshot(in defaults: UserDefaults = UserDefaults.container) -> [String: Any] {
        var values: [String: Any] = [:]

        for key in UserDefaults.ownedKeys {
            guard let value = defaults.object(forKey: key) else { continue }

            if dataKeysAsText.contains(key), let data = value as? Data {
                // 内容是 JSON 文本就存文本；实在不是就当 Base64 兜底（不丢数据）。
                values[key] = String(data: data, encoding: .utf8)
                    ?? data.base64EncodedString()
            } else if JSONSerialization.isValidJSONObject([key: value]) {
                values[key] = value
            } else {
                // plist 里合法、JSON 里不合法的类型（Data / Date / 嵌套的怪东西）：
                // 转成字符串保住内容，标上类型前缀，导入时认得出来。
                values[key] = "plist:\(String(describing: value))"
            }
        }

        return values
    }

    /// 导出成给用户看/复制的 JSON 文本（键排序，稳定可 diff）。
    static func exportText(in defaults: UserDefaults = UserDefaults.container) -> String {
        let payload: [String: Any] = [
            "version": formatVersion,
            "exportedAt": ISO8601DateFormatter().string(from: Date()),
            "values": snapshot(in: defaults),
        ]

        guard let data = try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]
        ), let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    // MARK: - 导入

    /// 从 JSON 文本导入。只写白名单里的键，未知键忽略并计数。
    @discardableResult
    static func importText(
        _ text: String,
        into defaults: UserDefaults = UserDefaults.container
    ) -> Result {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return Result(applied: 0, skipped: 0, message: "empty")
        }
        guard let data = trimmed.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return Result(applied: 0, skipped: 0, message: "unreadable")
        }
        guard let values = root["values"] as? [String: Any] else {
            return Result(applied: 0, skipped: 0, message: "no_values")
        }

        let known = Set(UserDefaults.ownedKeys)
        var applied = 0
        var skipped = 0

        for (key, value) in values {
            guard known.contains(key) else {
                skipped += 1
                continue
            }

            if dataKeysAsText.contains(key), let text = value as? String {
                defaults.set(Data(text.utf8), forKey: key)
                applied += 1
                continue
            }

            if let text = value as? String, text.hasPrefix("plist:") {
                // 导出时被降级成字符串的那种：内容没法安全还原，宁可跳过也不写坏。
                skipped += 1
                continue
            }

            defaults.set(value, forKey: key)
            applied += 1
        }

        return Result(applied: applied, skipped: skipped, message: "ok")
    }

    // MARK: - 重置

    /// 只删**我们自己的**键，返回删掉的条数。Spotify 自己的偏好一个都不碰。
    @discardableResult
    static func resetToStock(in defaults: UserDefaults = UserDefaults.container) -> Int {
        var removed = 0

        for key in UserDefaults.ownedKeys where defaults.object(forKey: key) != nil {
            defaults.removeObject(forKey: key)
            removed += 1
        }

        return removed
    }
}
