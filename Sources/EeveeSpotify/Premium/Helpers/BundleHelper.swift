import Foundation
import SwiftUI
import EeveeSpotifyC

class BundleHelper {
    private let bundleName = "EeveeSpotify"
    
    // Make properties optional to prevent init crash
    private var bundle: Bundle?
    private var enBundle: Bundle?
    
    static let shared = BundleHelper()
    
    private init() {
        // Try locating in main bundle first
        if let path = Bundle.main.path(forResource: bundleName, ofType: "bundle"),
           let b = Bundle(path: path) {
            self.bundle = b
            NSLog("[EeveeSpotify] Loaded bundle from main bundle: \(path)")
        } 
        // If not found, try locating in file system (jailbreak path)
        else {
            let jbPath = EeveeJBRootPath("/Library/Application Support/\(bundleName).bundle")
            if let b = Bundle(path: jbPath) {
                self.bundle = b
                NSLog("[EeveeSpotify] Loaded bundle from filesystem: \(jbPath)")
            } else {
                NSLog("[EeveeSpotify] ERROR: Could not find EeveeSpotify.bundle!")
                self.bundle = nil
            }
        }
        
        // Load English localization if available
        if let b = self.bundle, let enPath = b.path(forResource: "en", ofType: "lproj"),
           let enB = Bundle(path: enPath) {
            self.enBundle = enB
        } else {
            NSLog("[EeveeSpotify] WARNING: Could not load en.lproj from bundle")
            self.enBundle = nil
        }
    }
    
    func uiImage(_ name: String) -> UIImage? {
        guard let bundle = self.bundle else { return nil }
        
        if let path = bundle.path(forResource: name, ofType: "png") {
            return UIImage(contentsOfFile: path)
        }
        return nil
    }
    
    func localizedString(_ key: String) -> String {
        guard let bundle = self.bundle else { return key }

        let value = bundle.localizedString(forKey: key, value: "No translation", table: nil)
        
        if value != "No translation" {
            return value
        }
        
        return enBundle?.localizedString(forKey: key, value: nil, table: nil) ?? key
    }
    
    func resolveConfiguration() throws -> ResolveConfiguration {
        let spotifyVersion = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? ""
        let resourceName = BundledConfigurationPolicy.resourceName(for: spotifyVersion)

        guard let bundle = self.bundle,
              let url = bundle.url(forResource: resourceName, withExtension: "bnk") else {
            throw NSError(domain: "EeveeSpotify", code: 404, userInfo: [NSLocalizedDescriptionKey: "Configuration not found"])
        }

        writeDebugLog("[CONFIG] Using \(resourceName).bnk for Spotify \(spotifyVersion)")
        
        return try ResolveConfiguration(
            serializedBytes: try Data(contentsOf: url)
        )
    }

    /// 只把 bundle 交出去，让调用方自己定位资源。
    ///
    /// 为什么需要它：`resolveConfiguration()` 会**顺带打一行 `[CONFIG]` 日志**并假定
    /// 调用者就是要"现在用这份配置"。而种子（`SpotifyResponsePatcher.seedCustomizeDataIfNeeded`）
    /// 只是**读**同一份 `.bnk` 去构造 customize body，既不该冒充"正在用配置"、
    /// 也不该依赖"覆盖配置"开关的状态 —— 所以给它一个只暴露 bundle 的入口。
    var configurationBundle: Bundle? {
        bundle
    }
}
