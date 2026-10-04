import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fatalError("FAIL: \(message)")
    }
}

require(
    BundledConfigurationPolicy.resourceName(for: "9.1.75")
        == BundledConfigurationPolicy.legacyResourceName,
    "Spotify 9.1.75 must use the legacy configuration"
)

require(
    BundledConfigurationPolicy.resourceName(for: "9.1.76")
        == BundledConfigurationPolicy.spotify9176ResourceName,
    "Spotify 9.1.76 must use the new configuration"
)

require(
    BundledConfigurationPolicy.resourceName(for: "9.1.80")
        == BundledConfigurationPolicy.spotify9176ResourceName,
    "Spotify 9.1.80 must use the new configuration"
)

// 2026-10-12：9.1.88 起改用**从真机 customize body 转出来的**快照
// （旧的 9.1.76 快照里根本没有 9.1.88 才有的开关，见 `BundledConfigurationPolicy` 里的注释）。
require(
    BundledConfigurationPolicy.resourceName(for: "9.1.87")
        == BundledConfigurationPolicy.spotify9176ResourceName,
    "Spotify 9.1.87 must still use the 9.1.76 configuration"
)

require(
    BundledConfigurationPolicy.resourceName(for: "9.1.88")
        == BundledConfigurationPolicy.spotify9188ResourceName,
    "Spotify 9.1.88 must use the 9.1.88 configuration"
)

require(
    BundledConfigurationPolicy.resourceName(for: "9.2.0")
        == BundledConfigurationPolicy.spotify9188ResourceName,
    "Anything newer than 9.1.88 must keep using the 9.1.88 configuration"
)

print("BundledConfigurationPolicy tests passed")
