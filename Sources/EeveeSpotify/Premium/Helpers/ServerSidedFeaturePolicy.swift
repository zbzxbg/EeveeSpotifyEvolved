import Foundation

struct ServerSidedFeaturePolicy {
    struct RemoteFlag: Equatable {
        let scope: String
        let name: String
    }

    // These values are real account entitlements. Spoofing them only exposes
    // incomplete UI; Spotify's backend still rejects the operation.
    static let serverAuthoritativeAccountAttributes: Set<String> = [
        "offline",
        "can-use-offline",
        "has-offline-state",
        "max-offline-downloads-per-device",
        "max-offline-tracks",
        "offline-backup",
        "lyrics-offline",
        "very-high-bitrate",
        "audio-quality",
        "social-session",
        "social-session-free-tier",
        "jam-social-session",
    ]

    // Hide only remote/Premium Jam hosting. Spotify's separate in-person join
    // and free-user hosting flag remains controlled by the live configuration.
    static let premiumGatedJamEntryPoint = RemoteFlag(
        scope: "ios-sociallistening-configuration-impl",
        name: "premium_gated_start_jam_buttons_enabled"
    )

    static func shouldOverwriteResolvedConfiguration(requested: Bool) -> Bool {
        requested
    }
}

// ⚠️⚠️ **这个文件是一条 CI 契约**（2026-10-12 为红叉付过学费）：
//
//   `.github/workflows/tests.yml` 里这一步把它**单独**丢给编译器：
//
//       swiftc Sources/EeveeSpotify/Premium/Helpers/ServerSidedFeaturePolicy.swift \
//              Tests/ServerSidedFeaturePolicy/main.swift
//
//   ⇒ 它**只许依赖 Foundation**，不许引用本仓库别的类型或函数（`AccountAttribute`、
//     `writeDebugLog`、`UserDefaults.…` 这些在这里都**不存在**）。
//   2026-10-12 我往里加了一个"账号档位取证"的 static 方法（引用了那两个符号）⇒
//   这一步每次 push 都编不过 ⇒ GitHub 上**一串红叉**。那条取证现在在
//   `DynamicPremium+ModifyingFunctions.swift`（CI 不单独编译它）。
//
//   同一个契约对 tests.yml 里另外五个被单独编译的文件同样成立：
//   `TelemetryEndpointRules.swift`、`FlagOverride.swift`、`URL+Extension.swift`、
//   `DebugLogSanitizer.swift`、`BrowsitaSectionStripper.swift`。**动它们之前先看 tests.yml。**
