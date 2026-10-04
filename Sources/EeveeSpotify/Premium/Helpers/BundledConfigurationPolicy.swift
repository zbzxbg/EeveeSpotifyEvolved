import Foundation

private struct SpotifyVersion: Comparable {
    let major: Int
    let minor: Int
    let patch: Int

    init?(_ version: String) {
        let parts = version.split(separator: ".")
        guard parts.count >= 3,
              let major = Int(parts[0]),
              let minor = Int(parts[1]),
              let patch = Int(parts[2]) else {
            return nil
        }

        self.major = major
        self.minor = minor
        self.patch = patch
    }

    static func < (lhs: SpotifyVersion, rhs: SpotifyVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
}

enum BundledConfigurationPolicy {
    static let legacyResourceName = "resolveconfiguration"
    static let spotify9176ResourceName = "resolveconfiguration_9_1_76"
    static let spotify9188ResourceName = "resolveconfiguration_9_1_88"
    private static let minimumVersionForSpotify9176Configuration = SpotifyVersion("9.1.76")!
    // 2026-10-12：**服务器回 304 时 App 跑的正是这份配置**（真机 68/69：
    // `[HCUS] customize 304 -> replaying the seed`），而 9.1.76 那份快照里**没有** 9.1.88
    // 才引入的开关 —— 真机日志 69 里 4 个 `[Flags] replacement … 0 match(es)` 就是它们
    // （其中 `enable_has_lyrics_check_bypass` 正是免费号最需要的那颗绕过）。
    // 所以 9.1.88 起改用新快照：100278 字节 / 1096 条 assignment（旧的 99439 / 1089）。
    private static let minimumVersionForSpotify9188Configuration = SpotifyVersion("9.1.88")!

    static func resourceName(for spotifyVersion: String) -> String {
        guard let currentVersion = SpotifyVersion(spotifyVersion) else {
            return legacyResourceName
        }

        if currentVersion >= minimumVersionForSpotify9188Configuration {
            return spotify9188ResourceName
        }

        return currentVersion < minimumVersionForSpotify9176Configuration
            ? legacyResourceName
            : spotify9176ResourceName
    }
}
