import AVFoundation
import Foundation

/// 按输出设备记住这套效果设置。
///
/// 开关默认关：打开之后，换到另一类设备（外放 / 耳机 / 蓝牙 / 车机 …）会把那一类最近一次
/// 用的设置接上，并把当前这套存回上一类。关着的时候这里什么都不做，行为和以前一样。
///
/// 只在设备**类别**变了才切（同一类里的两副耳机共用一个桶）：系统只给到这一类信息，
/// 再细就只能按端口名猜，猜错比不猜更烦人。
enum AudioDSPDeviceProfiles {

    /// 设置页据此刷新影子值（`NotificationCenter` 里只带桶名）。
    static let didSwitchNotification = Notification.Name("AudioDSPDeviceProfilesDidSwitch")

    private static var observer: NSObjectProtocol?
    private static var currentBucket: AudioDSPDeviceBucket?

    /// 幂等：`AudioDSP.syncWithSettings()` 每次都会调。
    static func start() {
        guard observer == nil else { return }
        currentBucket = activeBucket()
        if UserDefaults.dspDeviceProfilesEnabled, let bucket = currentBucket {
            // 启动时先把当前这台设备那套装上；没存过就沿用上次的设置。
            restore(bucket: bucket)
        }
        observer = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            handleRouteChange()
        }
    }

    /// 当前活动输出的桶（读不到就用 `other`）。
    static func activeBucket() -> AudioDSPDeviceBucket {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        guard let port = outputs.first else { return .other }
        return AudioDSPDeviceBucket.bucket(forPort: port.portType.rawValue)
    }

    static func currentBucketName() -> String {
        activeBucket().rawValue
    }

    /// 把当前这套设置存进某个桶。
    static func storeCurrent(into bucket: AudioDSPDeviceBucket) {
        var profiles = storedProfiles()
        profiles[bucket.rawValue] = AudioDSPDeviceProfile(
            bandGainsDb: UserDefaults.dspBandGainsDb,
            lowShelfDb: UserDefaults.dspLowShelfDb,
            highShelfDb: UserDefaults.dspHighShelfDb,
            balance: UserDefaults.dspBalance,
            companderAmount: UserDefaults.dspCompanderAmount,
            crossfeedLevel: UserDefaults.dspCrossfeedLevel
        )
        save(profiles)
    }

    /// 把某个桶的设置写回 UserDefaults；没有存过就什么都不动（沿用当前这套）。
    @discardableResult
    static func restore(bucket: AudioDSPDeviceBucket) -> Bool {
        guard let profile = storedProfiles()[bucket.rawValue] else { return false }
        UserDefaults.dspBandGainsDb = profile.bandGainsDb
        UserDefaults.dspLowShelfDb = profile.lowShelfDb
        UserDefaults.dspHighShelfDb = profile.highShelfDb
        UserDefaults.dspBalance = profile.balance
        UserDefaults.dspCompanderAmount = profile.companderAmount
        UserDefaults.dspCrossfeedLevel = profile.crossfeedLevel
        AudioDSP.reloadParameters()
        return true
    }

    // MARK: - 路由变化

    private static func handleRouteChange() {
        let bucket = activeBucket()
        guard bucket != currentBucket else { return }
        let previous = currentBucket
        currentBucket = bucket

        if UserDefaults.dspDeviceProfilesEnabled, let previous {
            // 先存旧的，再装新的：顺序反了会把新设备的值写进旧桶。
            storeCurrent(into: previous)
            restore(bucket: bucket)
        }

        NotificationCenter.default.post(name: didSwitchNotification, object: bucket.rawValue)
    }

    // MARK: - 存储

    private static func storedProfiles() -> [String: AudioDSPDeviceProfile] {
        guard let data = UserDefaults.dspDeviceProfilesJSON?.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: AudioDSPDeviceProfile].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private static func save(_ profiles: [String: AudioDSPDeviceProfile]) {
        guard let data = try? JSONEncoder().encode(profiles),
              let text = String(data: data, encoding: .utf8) else {
            return
        }
        UserDefaults.dspDeviceProfilesJSON = text
    }
}
