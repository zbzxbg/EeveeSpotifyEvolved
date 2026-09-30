import Foundation

extension UserDefaults {
    static var container: UserDefaults = .standard
    
    private static let musixmatchTokenKey = "musixmatchToken"
    private static let darkPopUpsKey = "darkPopUps"
    private static let patchTypeKey = "patchType"
    private static let trueShuffleEnabledKey = "trueShuffleEnabled"
    private static let overwriteConfigurationKey = "overwriteConfiguration"
    private static let lyricsColorsKey = "lyricsColors"
    private static let lyricsOptionsKey = "lyricsOptions"
    private static let hasShownCommonIssuesTipKey = "hasShownCommonIssuesTip"
    private static let hasPatchedBootstrapKey = "eeveeHasPatchedBootstrap"
    private static let iconNamePrettifyKey = "iconNamePrettify"
    private static let cleanShareLinksKey = "cleanShareLinks"
    private static let enableLogRecordingKey = "enableLogRecording"
    private static let redactSharedLogKey = "redactSharedLog"
    private static let blockTelemetryKey = "blockTelemetry"
    private static let telemetryObserveOnlyKey = "telemetryObserveOnly"
    private static let telemetryExtraKeywordsKey = "telemetryExtraKeywords"
    private static let hapticsEnabledKey = "hapticsEnabled"
    private static let hapticsStrengthKey = "hapticsStrength"
    private static let hapticsSurfaceKeywordsKey = "hapticsSurfaceKeywords"
    private static let hapticsLogControlsKey = "hapticsLogControls"
    private static let dumpViewTreeKey = "dumpViewTree"

    static var musixmatchToken: String {
        get {
            container.string(forKey: musixmatchTokenKey) ?? ""
        }
        set (token) {
            container.set(token, forKey: musixmatchTokenKey)
        }
    }

    static var darkPopUps: Bool {
        get {
            container.object(forKey: darkPopUpsKey) as? Bool ?? true
        }
        set (darkPopUps) {
            container.set(darkPopUps, forKey: darkPopUpsKey)
        }
    }

    static var patchType: EeveePatchType {
        get {
            if let rawValue = container.object(forKey: patchTypeKey) as? Int {
                return EeveePatchType(rawValue: rawValue) ?? .requests
            }

            // If the key is missing (fresh install / "reset data"), default to patching.
            // This avoids users silently falling back to Free tier.
            return .requests
        }
        set (patchType) {
            container.set(patchType.rawValue, forKey: patchTypeKey)
        }
    }

    static var trueShuffleEnabled: Bool {
        get {
            container.object(forKey: trueShuffleEnabledKey) as? Bool ?? false
        }
        set (isEnabled) {
            container.set(isEnabled, forKey: trueShuffleEnabledKey)
        }
    }
    
    static var overwriteConfiguration: Bool {
        get {
            container.bool(forKey: overwriteConfigurationKey)
        }
        set (overwriteConfiguration) {
            container.set(overwriteConfiguration, forKey: overwriteConfigurationKey)
        }
    }
    
    static var hasPatchedBootstrap: Bool {
        get { container.bool(forKey: hasPatchedBootstrapKey) }
        set { container.set(newValue, forKey: hasPatchedBootstrapKey) }
    }

    static var hasShownCommonIssuesTip: Bool {
        get {
            container.bool(forKey: hasShownCommonIssuesTipKey)
        }
        set (hasShownCommonIssuesTip) {
            container.set(hasShownCommonIssuesTip, forKey: hasShownCommonIssuesTipKey)
        }
    }

    /// When true, icon names are prettified: underscores/hyphens become spaces,
    /// camelCase boundaries and numbers get spaces, and parentheses get a leading space.
    static var iconNamePrettify: Bool {
        get {
            container.object(forKey: iconNamePrettifyKey) as? Bool ?? true
        }
        set {
            container.set(newValue, forKey: iconNamePrettifyKey)
        }
    }

    /// When true, the `si` tracking parameter is stripped from shared Spotify links.
    static var cleanShareLinks: Bool {
        get {
            container.object(forKey: cleanShareLinksKey) as? Bool ?? false
        }
        set (cleanShareLinks) {
            container.set(cleanShareLinks, forKey: cleanShareLinksKey)
        }
    }

    /// When true, EeveeSpotify logs content at the debug level and mirrors it into the
    /// exportable eeveespotify_debug.log (ng / Reborn-ng behaviour).
    static var enableLogRecording: Bool {
        get {
            container.bool(forKey: enableLogRecordingKey)
        }
        set {
            container.set(newValue, forKey: enableLogRecordingKey)
        }
    }

    /// 「分享日志前脱敏」——导出时是否把听歌记录假名化（**默认 true**）。
    ///
    /// 默认 true 的理由：导出这个动作 99% 是为了把日志发给别人（issue / 群里），
    /// 而日志主体就是"你听了哪些歌"。要自己留档的人可以关掉，关上之后导出的是
    /// 原始文件（排查时需要真实曲目才好复现）。
    ///
    /// ⚠️ 这条只影响**导出**。凭证/设备标识那一层是 `DebugLogSanitizer.sanitize`，
    /// 在**写入口**就生效、没有开关 —— 那种东西不该有任何"忘了打开脱敏"的机会。
    static var redactSharedLog: Bool {
        get {
            container.object(forKey: redactSharedLogKey) == nil
                ? true
                : container.bool(forKey: redactSharedLogKey)
        }
        set {
            container.set(newValue, forKey: redactSharedLogKey)
        }
    }

    // MARK: - 上报拦截（Privacy）

    /// 「拦截上报」总开关，**默认关**。
    ///
    /// 默认关的理由：它改的是网络行为，而"哪些端点算上报"没法离线证实（见
    /// `TelemetryEndpointRules`）。先让用户自己开，并在设置页给一条
    /// 「只观察不拦截」的路去确认真实端点。
    static var blockTelemetry: Bool {
        get {
            container.object(forKey: blockTelemetryKey) as? Bool ?? false
        }
        set {
            container.set(newValue, forKey: blockTelemetryKey)
        }
    }

    /// 「只观察不拦截」：把请求的 host+path 打进日志，但一条都不拦。默认关。
    ///
    /// 它是把"哪些是真的上报端点"从猜变成实测的唯一手段，本机没有真机流量可看。
    static var telemetryObserveOnly: Bool {
        get {
            container.object(forKey: telemetryObserveOnlyKey) as? Bool ?? false
        }
        set {
            container.set(newValue, forKey: telemetryObserveOnlyKey)
        }
    }

    /// 用户自加的上报主机 / 路径关键词（逗号、分号或空白分隔），默认空。
    static var telemetryExtraKeywords: String {
        get {
            container.string(forKey: telemetryExtraKeywordsKey) ?? ""
        }
        set {
            container.set(newValue, forKey: telemetryExtraKeywordsKey)
        }
    }

    // MARK: - 播放器触感（Haptics）

    /// 播放器控件触感，**默认关**。
    ///
    /// ⚠️ 这个开关在 `EeveeSpotify.init` 里被读一次（决定 hook 装不装），所以
    /// **改动需要重启 Spotify** —— 和 `darkPopUps` 那些一样。强度不受此限制。
    static var hapticsEnabled: Bool {
        get {
            container.object(forKey: hapticsEnabledKey) as? Bool ?? false
        }
        set {
            container.set(newValue, forKey: hapticsEnabledKey)
        }
    }

    /// 触感强度 0.2 – 1.0，默认 0.6。每次触发都重新读，**改动立即生效**。
    static var hapticsStrength: Double {
        get {
            container.object(forKey: hapticsStrengthKey) as? Double ?? 0.6
        }
        set {
            container.set(newValue, forKey: hapticsStrengthKey)
        }
    }

    /// 认为"属于播放器界面"的控件类名关键词，逗号分隔。
    ///
    /// 默认值覆盖 Spotify 命名里最常见的几种写法，但**不保证 9.1.86 上就对**：
    /// 对不上时不会有任何副作用（不震而已），用设置页的「记录被点控件的类名」
    /// 抓真名再加进来。
    static var hapticsSurfaceKeywords: String {
        get {
            container.string(forKey: hapticsSurfaceKeywordsKey)
                ?? "player,nowplaying,now_playing,npv,transport,playback,scrubber,miniplayer"
        }
        set {
            container.set(newValue, forKey: hapticsSurfaceKeywordsKey)
        }
    }

    /// 记录被点控件的类名（用来找上面那串关键词），默认关。
    static var hapticsLogControls: Bool {
        get {
            container.object(forKey: hapticsLogControlsKey) as? Bool ?? false
        }
        set {
            container.set(newValue, forKey: hapticsLogControlsKey)
        }
    }

    // MARK: - 视图树转储（Diagnostics）

    /// 「转储视图树」：把当前屏幕的视图结构每 2s 写一行进调试日志，默认关。
    ///
    /// 用途只有一个：给还没写的界面 hook（AMOLED / 隐藏区块 / 播放器手势）先拿到
    /// 类名与层级。三条纪律见 `ViewTreeDumper` 的说明 —— 只读、有界、不做类枚举。
    static var dumpViewTree: Bool {
        get {
            container.object(forKey: dumpViewTreeKey) as? Bool ?? false
        }
        set {
            container.set(newValue, forKey: dumpViewTreeKey)
        }
    }

}

// 已移除：`forcedLyricsPayload` 排障开关（连同设置界面的 Picker 与
// `CustomLyrics.x.swift` 里那处短路）。
//
// 移除原因：加入之后出现**稳定复现的启动崩溃**（EXC_BREAKPOINT/SIGTRAP，
// `swift_unexpectedError`，崩在全局 userInitiated 队列上的一个 block 里，
// 我们 dylib 有 4 帧未符号化；两份 .ips 的异常码同一地址 `0x19f2f6f54`）。
// 它挡住了后续所有真机测试，所以先回退，事后再逐一排查。
//
// ⚠️ 但它**已经产出了本轮最重要的结论**，回退不要把结论一起丢掉：
//   · 卡片（与「关于艺人」并列那块）上显示的 provider 是 `EeveeForce…`
//     —— 也就是我们自己写死的名字 ⇒ **卡片是被我们注入的 payload 驱动的**。
//     Spotify 侧的"这首歌有没有词"（`has_lyrics` / 服务端判定 / 本地状态）
//     **不是门控**。
//   · `timeSynchronized = false` 的 payload → **建卡片**；
//     `timeSynchronized = true` → Spotify 走"同步歌词"表现（单行）而**不建卡片**。
//     两个面看起来是**互斥**的。
//   · 推论：「合成行级时间轴」默认开启，正是把卡片挤掉的那个东西。
