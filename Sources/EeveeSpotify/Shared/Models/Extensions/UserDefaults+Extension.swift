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
    private static let blockRatingPromptsKey = "blockRatingPrompts"
    private static let hapticsEnabledKey = "hapticsEnabled"
    private static let hapticsStrengthKey = "hapticsStrength"
    private static let hapticsSurfaceKeywordsKey = "hapticsSurfaceKeywords"
    private static let hapticsLogControlsKey = "hapticsLogControls"
    private static let dumpViewTreeKey = "dumpViewTree"
    private static let hideMiniPlayerBarKey = "hideMiniPlayerBar"
    private static let hideSingalongLineKey = "hideSingalongLine"
    private static let hideNowPlayingPillsKey = "hideNowPlayingPills"
    private static let hideHomeHeaderKey = "hideHomeHeader"
    private static let hideConnectButtonKey = "hideConnectButton"
    private static let hideAddToButtonKey = "hideAddToButton"
    private static let blockedArtistsEnabledKey = "blockedArtistsEnabled"
    private static let blockedArtistsKey = "blockedArtists"
    private static let dumpCustomizeBodyKey = "dumpCustomizeBody"
    private static let libraryLargeTitleKey = "libraryLargeTitle"
    private static let homeLargeTitleKey = "homeLargeTitle"
    private static let tabBarSystemGlassKey = "tabBarSystemGlass"
    private static let tabBarHideLabelsKey = "tabBarHideLabels"
    private static let tabBarHideCreateKey = "tabBarHideCreate"
    private static let miniBarGlassKey = "miniBarGlass"
    private static let playlistSingleCoverKey = "playlistSingleCover"
    private static let nowPlayingBackdropKey = "nowPlayingBackdrop"
    private static let nowPlayingOneScreenKey = "nowPlayingOneScreen"
    private static let nowPlayingVolumeKey = "nowPlayingVolume"
    private static let nowPlayingLyricsInPlayerKey = "nowPlayingLyricsInPlayer"
    private static let nowPlayingLyricsExpandedKey = "nowPlayingLyricsExpanded"
    private static let nowPlayingSingleLyricKey = "nowPlayingSingleLyric"
    private static let nowPlayingBlurUnplayedLyricsKey = "nowPlayingBlurUnplayedLyrics"
    private static let lyricsSearchPlaceholderEasterEggKey = "lyricsSearchPlaceholderEasterEgg"
    private static let nowPlayingControlGlyphsKey = "nowPlayingControlGlyphs"
    private static let entityPageFieldKey = "entityPageField"
    private static let entityPageDissolveKey = "entityPageDissolve"
    private static let entityPageHideChromeKey = "entityPageHideChrome"
    private static let amoledThemeKey = "amoledTheme"
    private static let accentColorRGBKey = "accentColorRGB"

    /// **本仓库自己写进 `UserDefaults` 的全部键** —— 只给「备份与重置」用。
    ///
    /// ⚠️ 为什么必须是白名单、而不是"遍历 `dictionaryRepresentation()` 全导/全删"：
    /// 这个进程的 `.standard` **同时就是 Spotify 自己的偏好存储**（tweak 注进 Spotify.app）。
    /// 全删会把 Spotify 的登录态周边、播放设置一起清掉 —— 那是 `FullResetHelper`（"重置
    /// Spotify 状态"，另一个按钮）的语义，不是"重置本仓库的设置"。
    ///
    /// 加新键时**记得往这里也加一行**（否则它不会被导出/导入/重置）。
    static let ownedKeys: [String] = [
        musixmatchTokenKey,
        darkPopUpsKey,
        patchTypeKey,
        trueShuffleEnabledKey,
        overwriteConfigurationKey,
        lyricsColorsKey,
        lyricsOptionsKey,
        hasShownCommonIssuesTipKey,
        hasPatchedBootstrapKey,
        iconNamePrettifyKey,
        cleanShareLinksKey,
        enableLogRecordingKey,
        redactSharedLogKey,
        blockTelemetryKey,
        telemetryObserveOnlyKey,
        telemetryExtraKeywordsKey,
        blockRatingPromptsKey,
        hapticsEnabledKey,
        hapticsStrengthKey,
        hapticsSurfaceKeywordsKey,
        hapticsLogControlsKey,
        dumpViewTreeKey,
        hideMiniPlayerBarKey,
        hideSingalongLineKey,
        hideNowPlayingPillsKey,
        hideHomeHeaderKey,
        hideConnectButtonKey,
        hideAddToButtonKey,
        blockedArtistsEnabledKey,
        blockedArtistsKey,
        dumpCustomizeBodyKey,
        libraryLargeTitleKey,
        homeLargeTitleKey,
        tabBarSystemGlassKey,
        tabBarSystemGlassDefaultMigratedKey,
        tabBarHideLabelsKey,
        tabBarHideCreateKey,
        miniBarGlassKey,
        playlistSingleCoverKey,
        nowPlayingBackdropKey,
        nowPlayingOneScreenKey,
        nowPlayingVolumeKey,
        nowPlayingLyricsInPlayerKey,
        nowPlayingLyricsExpandedKey,
        nowPlayingSingleLyricKey,
        nowPlayingBlurUnplayedLyricsKey,
        lyricsSearchPlaceholderEasterEggKey,
        nowPlayingControlGlyphsKey,
        entityPageFieldKey,
        entityPageDissolveKey,
        entityPageHideChromeKey,
        amoledThemeKey,
        accentColorRGBKey,

        // 不在上面那批常量里、但同样属于我们的：
        // 「Flag 覆盖」表（`FlagOverrideStore` 用 `flagOverrides` 存 JSON Data）。
        "flagOverrides",
    ]
    // 听歌页「卡片」那批（总开关 + 每张卡一个键）：键表由 `PlayerCard` / `PlayerCardsDeclutter`
    // 自己拥有 —— 加一张卡片只改那一处，这里跟着走，不会漏。
    + PlayerCardsDeclutter.allKeys

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

    /// 「阻止评分提示」：拦住 App Store 的系统评分弹窗，**默认关**。
    ///
    /// 拦的是 `SKStoreReviewController` 那两个类方法（系统弹窗，不是 Spotify 自己的
    /// UI），所以与 `UpsellPopupBlocker` 那套弹窗 hook 互不相干 —— 详见
    /// `RatingPromptBlock.x.swift` 顶部的说明。
    ///
    /// ⚠️ **只在启动时读一次**（`RatingPromptBlock.launchEnabled`，hook 组装不装是启动
    /// 时定的）⇒ 改完要重启，设置页那一行下面配了「立即重启」。
    static var blockRatingPrompts: Bool {
        get {
            container.object(forKey: blockRatingPromptsKey) as? Bool ?? false
        }
        set {
            container.set(newValue, forKey: blockRatingPromptsKey)
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

    // MARK: - 外观（Appearance）

    // ⛔「深色栏底色」(amoledEnabled) 已于 2026-10-02 删除：
    // 新设计语言下它每次布局都主动让位，是个纯空操作。
    //
    // ★ 2026-10-13：**另一个** AMOLED 回来了（键名刻意不同，见下）——
    // 它是全局换色而不是给某条栏涂底，机制在 `Sources/EeveeSpotifyC/ColorSwap.m`。

    /// 「AMOLED 纯黑」：把 Spotify 的 #121212 底色换成纯黑（保留 alpha）。默认关。
    ///
    /// ⚠️ 与那个被删的 `amoledEnabled` **不是一回事**：那个只给旧设计语言的导航/标签栏涂底。
    /// 键名换成新的，就是为了避免设备上存量的旧值把纯黑主题悄悄打开。
    ///
    /// ⚠️ **只在启动时读一次**（`Theme.launchAmoled`，C 侧还是 `dispatch_once`）⇒ 改完要重启，
    /// 设置页那颗开关下面配了「立即重启」。
    static var amoledTheme: Bool {
        get {
            container.object(forKey: amoledThemeKey) as? Bool ?? false
        }
        set {
            container.set(newValue, forKey: amoledThemeKey)
        }
    }

    /// 「强调色」（`0xRRGGBB`）：把 Spotify 的品牌绿换成它。`-1` = 不换（保持 Spotify 绿）。
    ///
    /// 与 `amoledTheme` 同样**只在启动时读一次** ⇒ 改完要重启。
    static var accentColorRGB: Int {
        get {
            container.object(forKey: accentColorRGBKey) as? Int ?? -1
        }
        set {
            if newValue < 0 {
                container.removeObject(forKey: accentColorRGBKey)
            } else {
                container.set(newValue, forKey: accentColorRGBKey)
            }
        }
    }

    // MARK: - 清爽（Declutter）

    /// 隐藏标签栏上方的迷你播放条。默认关，实时读。
    static var hideMiniPlayerBar: Bool {
        get {
            container.object(forKey: hideMiniPlayerBarKey) as? Bool ?? false
        }
        set {
            container.set(newValue, forKey: hideMiniPlayerBarKey)
        }
    }

    /// 隐藏封面与歌名之间那行跟唱单行歌词（`id=singalong-lyrics-view`）。
    ///
    /// ★ **2026-10-08：默认值改回「开」，但机制换了**（用户拍板："我想要的高度效果是图片 59 的效果"）。
    ///
    /// **踩过的坑（两次判反）**：这个开关原来是"把那一行的视图 `hidden` 掉"，而用户给的现场是——
    ///
    /// > 图片 58 是胶囊显示「显示歌词」（**此时单行功能生效**）的时候截屏的
    /// > （但是这个功能似乎是**只隐藏歌词内容，不隐藏功能，所以封面被抬上去了**）；
    /// > 图片 59 是胶囊显示「隐藏歌词」的时候截屏的（**此时单行功能关闭，封面还是原来的正常的样子**）。
    ///
    /// ⇒ **藏视图只去得掉内容，Spotify 的"抬高封面"那个功能还在**。用户要的是 **59**
    /// （= 功能真的关掉）。
    ///
    /// ★ 2026-10-10（照片 63 之后定案，现在是**两层 + 一颗开关**）：
    ///   ① `DeclutterChrome.applySingalongLine` 当场把那一行的视图 `hidden`
    ///      （屏幕上立刻没有那一行）；
    ///   ② **`lyrics_under_cover_art_enabled=false`** 的远端配置替换
    ///      （`DynamicPremium+ModifyingFunctions`）—— 连"封面被抬起来"的布局后果一起从根上关掉，
    ///      **下次启动**生效。★ 日志 54 已证第二层真的生效：整份日志里 `LyricsContainerView` /
    ///      `singalong-lyrics-view` **一个都没有**。
    ///   ③ 那两颗胶囊（「切换至视频」/「显示歌词」）**不归这个开关**，归
    ///      `hideNowPlayingPills`（见下）。
    static var hideSingalongLine: Bool {
        get {
            container.object(forKey: hideSingalongLineKey) as? Bool ?? true
        }
        set {
            container.set(newValue, forKey: hideSingalongLineKey)
        }
    }

    /// 隐藏听歌页底部那排**胶囊**：「切换至视频」+「显示/隐藏歌词」。默认**开**。
    ///
    /// ★ 2026-10-10（照片 63）：用户第二次报"这个隐藏歌词的胶囊还在"，并新发现旁边那颗
    /// 「切换至视频」。日志 54 的 `[NPVTree]` 一次把两颗都点名了（**它们都有无障碍 id**，
    /// 之前一直在按类名/标签猜，白绕了一圈）：
    ///
    /// ```
    /// 13.Primary@0,0,26,32,hidden,id=nowplaying-npv-musicvideos-switch    ← 「切换至视频」（无视频时 hidden）
    /// 13.Primary@0,0,104,32,id=lyrics-npv-switch-button                   ← 「显示/隐藏歌词」（104pt = 图标 + 文字）
    /// ```
    ///
    /// 归属：两颗是**同一排**、同一类（`Encore.Button.Primary`），一起给一个开关最省事，
    /// 也符合用户"这两个都不该出现"的说法。关掉开关 ⇒ 写回 `alpha`（**不用 `hidden`**：
    /// pw 的文档明确写过 Encore/OverflowStack 那类栈里写 `hidden` 会崩）。
    static var hideNowPlayingPills: Bool {
        get {
            container.object(forKey: hideNowPlayingPillsKey) as? Bool ?? true
        }
        set {
            container.set(newValue, forKey: hideNowPlayingPillsKey)
        }
    }

    /// 隐藏首页顶部那条（问候语 + 筛选胶囊）。默认关，实时读。
    ///
    /// 证据：真机树里只在**首页**出现（日志 7 的 #1–#7），`HomeHeaderView@0,0,414,50`。
    static var hideHomeHeader: Bool {
        get {
            container.object(forKey: hideHomeHeaderKey) as? Bool ?? false
        }
        set {
            container.set(newValue, forKey: hideHomeHeaderKey)
        }
    }

    /// 隐藏设备 / 输出切换按钮（"连接"）。默认关，实时读。
    ///
    /// ⚠️ 它在迷你播放条和播放器里**共用**（20/20 份转储都有），所以关掉是
    /// "所有传输条上都不显示"，不是只在播放器页。
    static var hideConnectButton: Bool {
        get {
            container.object(forKey: hideConnectButtonKey) as? Bool ?? false
        }
        set {
            container.set(newValue, forKey: hideConnectButtonKey)
        }
    }

    /// 隐藏播放器里的"加号"按钮。默认关，实时读。
    static var hideAddToButton: Bool {
        get {
            container.object(forKey: hideAddToButtonKey) as? Bool ?? false
        }
        set {
            container.set(newValue, forKey: hideAddToButtonKey)
        }
    }

    // MARK: - 播放器双击手势（Gestures）—— ⛔ 2026-10-04 整体删除
    //
    // 删掉的是 `playerGestureNowPlaying` / `playerGestureFullscreenLyrics` /
    // `playerGestureBehavior` 三个键与它们的 getter（含 `ownedKeys` 里的三行）。
    // 为什么删（都不是"坏了"）：① 手势挂在页面根视图上 ⇒ **在播放键上方双击也会跳歌**；
    // ② 最该起作用的全屏歌词那一面默认关、从没验过；③ 最近 8 份日志里它一次都没被用过。
    // 重做时的三条要求见 `Tools/eevee-hookfinder/SESSION_2026-10-03_NIGHT.md` §10。

    // MARK: - 屏蔽的艺人（Blocked artists）

    /// 「屏蔽的艺人」总开关。**默认开** —— 名单空着时什么都不做（`BlockedArtists.match`
    /// 先判名单是否为空），所以开着没有副作用；而名单一旦有内容，用户显然就是要它生效。
    /// 这个开关的用处是"临时全停"，不用去把名单清空。
    static var blockedArtistsEnabled: Bool {
        get {
            container.object(forKey: blockedArtistsEnabledKey) as? Bool ?? true
        }
        set {
            container.set(newValue, forKey: blockedArtistsEnabledKey)
        }
    }

    /// 名单。存用户输入时的原样（只去掉首尾空白），**匹配时才转小写** ——
    /// 这样设置页里显示的是 "MIMI" 而不是 "mimi"。
    static var blockedArtists: [String] {
        get {
            container.stringArray(forKey: blockedArtistsKey) ?? []
        }
        set {
            container.set(newValue, forKey: blockedArtistsKey)
        }
    }

    // ⛔ 听歌页那套外观开关（`musicStyleNowPlaying` / `nowPlayingShellEnabled` /
    // `nowPlayingShellHeader` / `nowPlayingShellGlass` / `nowPlayingShellBackdrop`）
    // 已于 2026-10-02 **全部删除**：那几版 bug 太多，先放一边，
    // 等导航栏这条线收干净再重做（细节见 `Tools/eevee-hookfinder/SESSION_2026-10-02_SUMMARY.md`）。

    // MARK: - 标签栏玻璃

    // ⛔「**标签用液态玻璃**」（`tabBarGlass`，我们自己画的那条胶囊）已于 2026-10-13
    //   按用户要求**连同实现一起删除**（"这个功能可以删掉了"）。现在的标签栏玻璃只有一条路：
    //   `tabBarSystemGlass`（下面那个）—— 叠一条系统 `UITabBar`，玻璃由 iOS 26 自己画
    //   （折射 / 镜片 / 明暗自适应都是 UIKit 的）。旧键留在 `UserDefaults` 里无害，
    //   只是不再被读；「重置本仓库设置」也不再管它（它已经不进 `ownedKeys`）。

    /// 「**标签栏改用系统玻璃**」—— 用户 2026-10-12 提的（他看出 pw 那条栏"像果冻、还能滑"）。
    ///
    /// **默认开** —— 2026-10-13 用户要求："默认启用标签用液态玻璃"（此前默认关，理由只是"我没验过"）。
    /// 做法是**照 pw 的做法**（`Redesigned/Navbar/TabBar.x`）把 Spotify 的栏内容藏掉、
    /// 在上面叠一条**系统 `UITabBar`** ⇒ iOS 26 直接画成真·液态玻璃（选中气泡会滑、折射、明暗自适应）。
    ///
    /// ⚠️ 关掉 = **完全不动**（连一次布局都不碰）：藏起来的内容与让出去的高度都**精确写回**
    /// （见 `TabBarSystemGlass.remove(reason:)`）。
    /// ⚠️ 它现在是**唯一**一条标签栏玻璃的路（自绘那条已于 2026-10-13 按用户要求删除）。
    /// 实现与四步做法写在 `Appearance/TabBarSystemGlass.x.swift` 的文件头。
    ///
    /// ⚠️ **光改默认值不够**：这个键只要被设置页写过一次，盘上就是一个具体的 `false`，
    /// `?? true` 再也追不到它 ⇒ 配套的一次性迁移见下面
    /// `applyTabBarSystemGlassDefaultIfNeeded()`（只做一次，之后尊重用户在设置里的开关）。
    static var tabBarSystemGlass: Bool {
        get {
            container.object(forKey: tabBarSystemGlassKey) as? Bool ?? true
        }
        set {
            container.set(newValue, forKey: tabBarSystemGlassKey)
        }
    }

    /// 迁移标记（只认它一次，之后永远尊重用户在设置里的选择）。
    private static let tabBarSystemGlassDefaultMigratedKey = "tabBarSystemGlassDefaultOn"

    /// **一次性**把盘上的 `tabBarSystemGlass` 打开 —— 为"默认值从关改成开"补一刀。
    ///
    /// 为什么需要它（而不是只改默认值就行）：`UserDefaults.standard` 在这个进程里就是 Spotify 自己的
    /// 偏好存储，而**设置页那颗开关只要被拨过一次**，盘上就已经有了一个具体的 `false`
    /// （旧默认值写进去的），`?? true` 永远追不到它 —— 用户会觉得"你根本没改"。
    ///
    /// 只发生**一次**（标记键），并且照实打一行日志：
    /// 这是"默认值变更"的补偿，不是每次启动都覆盖用户的选择。
    /// 做法与理由与 `LyricsOptions.applyGeniusFallbackDefaultIfNeeded()` 完全一致。
    static func applyTabBarSystemGlassDefaultIfNeeded() {
        guard container.object(forKey: tabBarSystemGlassDefaultMigratedKey) == nil else { return }
        container.set(true, forKey: tabBarSystemGlassDefaultMigratedKey)

        guard container.object(forKey: tabBarSystemGlassKey) as? Bool == false else { return }
        container.set(true, forKey: tabBarSystemGlassKey)
        writeDebugLog(
            "[TabBar] system glass default turned on once (the stored switch said off)"
                + " — from here on the switch in the extras settings decides"
        )
    }

    // MARK: - customize 快照的**落盘**兜底（2026-10-12，对齐上游）

    /// customize 响应体的**落盘缓存**。
    ///
    /// ★★ 为什么加它（用户 2026-10-12 让"对比上游那几个仓库"）：
    ///   `EeveeSpotifyReincarnated`（我们最近的同代 fork）里，`cachedCustomizeData` **每写一次就同步落盘**，
    ///   而且**每处读取都 `?? UserDefaults.cachedCustomizeData`**：
    ///
    /// ```
    /// SpotifyResponsePatcher.swift:26   UserDefaults.cachedCustomizeData = newValue
    /// DataLoaderServiceHooks.x.swift:61 if url.isCustomize, let cached = SpotifyResponsePatcher.cachedCustomizeData
    /// DataLoaderServiceHooks.x.swift:62     ?? UserDefaults.cachedCustomizeData {
    /// ```
    ///
    /// 我们这边**只有内存那一份**（+ 启动时用随包 `.bnk` 喂一份，见 `SpotifyResponsePatcher.seedCustomizeData`）。
    /// 缺它的后果很具体，而且**正好落在用户报的"退出重进之后"**：
    /// 新进程刚起、随包快照没拿到或名字变了、而服务器对 customize 回 **304**（很常见）
    /// ⇒ `cachedCustomizeData == nil` ⇒ 我们**交不出 body** ⇒ App 拿到空配置
    /// ⇒ **premium / 可播放性降级 ⇒ 歌单发灰、歌曲消失、放不动**（用户报的那三个症状）。
    /// 上游靠落盘那一份就永远有 body 可交。
    ///
    /// ⚠️ 它**不进 `ownedKeys`**：这是**缓存**不是设置（不该进备份，也不该被"清空设置"连坐）；
    ///    每次拿到 200 就会被覆盖，所以留着旧的也不会长期错。
    private static let cachedCustomizeDataKey = "eeveeCachedCustomizeData"
    private static let cachedCustomizeVersionKey = "eeveeCachedCustomizeVersion"

    static var cachedCustomizeData: Data? {
        get {
            container.data(forKey: cachedCustomizeDataKey)
        }
        set {
            if let newValue {
                container.set(newValue, forKey: cachedCustomizeDataKey)
            } else {
                container.removeObject(forKey: cachedCustomizeDataKey)
            }
        }
    }

    /// ★★ 2026-10-12 补：那份落盘 body 是**哪个 Spotify 版本**抓到的。
    ///
    /// 为什么必须有它（用户这一轮的三个症状）："退出重进 ⇒ 歌曲全黑 ⇒ 过一会部分能放"。
    /// 新进程刚起、服务器对 customize 回 **304** 时，我们手上其实有两份 body：
    ///   ① 内存里那份**随包种子**（旧版快照，刚才才修成 9.1.88）；
    ///   ② 磁盘上那份**上一场真抓到的 body**（同一版本、而且已经过我们的改写）。
    /// 以前**内存优先** ⇒ 回放的永远是旧快照，磁盘上更好的那一份**从来没被用过**
    /// （真机日志 69：`customize 304 -> replaying the seed, 101415 bytes` —— 101415 正是种子的字节数）。
    /// 现在反过来：**同版本的落盘 body 优先**，种子只在"磁盘上那份是别的版本"或"磁盘上没有"时兜底；
    /// 而**种子本身不再落盘**（否则它会把真正的那份覆盖掉 —— 那就又回到"永远用旧快照"）。
    static var cachedCustomizeVersion: String? {
        get {
            container.string(forKey: cachedCustomizeVersionKey)
        }
        set {
            if let newValue {
                container.set(newValue, forKey: cachedCustomizeVersionKey)
            } else {
                container.removeObject(forKey: cachedCustomizeVersionKey)
            }
        }
    }

    // MARK: - 标签文字（默认藏）

    /// 隐藏四颗标签的**文字**（照片 21/23/25 里那条栏是没有文字的）。**默认开**。
    ///
    /// 这一条同时把"玻璃太扁"顺手解掉：内容带从"图标 + 文字 44pt"变成"只有图标 ~24pt"，
    /// 胶囊自然收到 ~40pt（正好是照片里的比例），图标仍然居中。
    ///
    /// 来自 **spoti.pw** 的「Hide labels」（见它的 `docs/tweaks.md`）——
    /// 来源、许可与改动见「开源许可」页。
    static var tabBarHideLabels: Bool {
        get {
            container.object(forKey: tabBarHideLabelsKey) as? Bool ?? true
        }
        set {
            container.set(newValue, forKey: tabBarHideLabelsKey)
        }
    }

    /// 「**隐藏「创建」标签**」—— 用户 2026-10-13 要的：
    /// 「有个按键在音乐库的右边，叫创建歌单。能不能不要这个功能了。即液态玻璃只显示主页，搜索，音乐库三个按键」。
    ///
    /// **默认开**（就是他要的结果）。做法：**保住它在 `UIStackView` 里的槽位、只把内容藏起来**
    /// （`alpha = 0` + 点不到；真机树里它是 `CreateMenu_TabBarItemImpl.CreateMenuTabBarItemView`，
    /// id `TabBar.Item.创建`）——
    /// ① 因为它**收不到点击**（UIKit 命中测试跳过 alpha < 0.01 的视图），"创建"这个入口真的没了；
    /// ② 而且**槽位还在** ⇒ 我们自己的几何与 UIKit 画的那块玻璃都照旧按四颗算，
    ///    **宽度不随这颗开关变**（用户 2026-10-13 第二条要求："关掉创建之后玻璃宽度不变"；
    ///    早先 `isHidden = true` 的写法会让另外三颗平分整条栏，玻璃从 360 缩到 274）。
    ///
    /// ⚠️ 判据是**类名**而不是文字：文字随语言变（`创建` / `Create`）。
    /// ⚠️ 与 `tabBarHideLabels` 一样是**可撤销**的：关掉开关把它恢复成原来的 `alpha` 与交互开关
    /// （见 `TabBarGlassPlate.applyCreateTabVisibility`）。
    static var tabBarHideCreate: Bool {
        get {
            container.object(forKey: tabBarHideCreateKey) as? Bool ?? true
        }
        set {
            container.set(newValue, forKey: tabBarHideCreateKey)
        }
    }

    // ⛔「**拖动胶囊切换标签**」（`tabBarDragCapsule`）已于 2026-10-13 **当天加、当天删**：
    //   那个交互是**原生 iOS 26 标签栏自带的**（手指贴上玻璃就能横向滑，镜片立刻跟手、
    //   松手选中手指下那一颗 —— 见 `TabBarSystemGlass.x.swift` 第五片的两处外部来源）。
    //   我们自己装 pan 是**重复实现**，而且只会把触摸从系统手里抢走 ⇒ 一行都不该有。
    //   要做的事只有一件：让玻璃接管触摸（`probeForwardRoute`）。

    // MARK: - 迷你播放条玻璃（默认开）
    /// 迷你播放条也铺一层**液态玻璃胶囊**：与标签栏那条**同高、同圆角、同材质**，
    /// 宽度贴它自己的内容（真机 398pt，因为要装封面 + 歌名 + 按钮）。
    /// **默认开** —— 用户 2026-10-02 直接点名要的（照片 33：那条实心红底太扎眼）。
    ///
    /// 关掉即完全还原：玻璃撤掉，被我们清空的封面色底与放开过的裁剪都还回去
    /// （见 `MiniBarGlassPlate.removePlate`）。
    static var miniBarGlass: Bool {
        get {
            container.object(forKey: miniBarGlassKey) as? Bool ?? true
        }
        set {
            container.set(newValue, forKey: miniBarGlassKey)
        }
    }

    // MARK: - 歌单封面：四宫格 → 单张（默认开）
    /// 歌单封面默认是**服务端拼好的四宫格**：地址里就串着歌单前四首歌的专辑封面 id
    /// （`https://mosaic.scdn.co/<size>/<id1><id2><id3><id4>`，每张 40 位十六进制）。
    /// 把这个地址截到**第一个 id**，服务端回的是一张正常的单张封面（本机实测：
    /// 640 与 300 的单 id 地址都是 200 + `image/jpeg`）⇒ 不用换 host、不用自己裁图。
    ///
    /// **默认开** —— 用户第 5 轮直接点名问的就是「能不能只显示一张」。
    /// 机制、证据、以及"为什么不能写 `setURL:`"都在 `Appearance/PlaylistSingleCover.x.swift` 文件头。
    ///
    /// 关掉即完全还原：钩子只在开关开着时改写（关着一行都不改）；已经加载过的那几张
    /// 会留在图片缓存里，重开一次歌单页就是原来的四宫格。
    static var playlistSingleCover: Bool {
        get {
            container.object(forKey: playlistSingleCoverKey) as? Bool ?? true
        }
        set {
            container.set(newValue, forKey: playlistSingleCoverKey)
        }
    }

    // MARK: - 页面取色底（AM 化：专辑页 / 歌单页）

    /// 「**封面取色底**」：专辑页 / 歌单页的最底层铺一层"封面取色 → 向下渐隐成 `#121212`"的竖直渐变。
    ///
    /// **默认开** —— 用户 2026-10-13：「我就一个要求：**看起来像 Apple Music**」。
    /// 机制、证据、以及"**为什么必须先清掉 list / 每个 cell 画的 `#121212` 底色**"（不清就完全看不见）
    /// 都写在 `Appearance/EntityPageAppearance.x.swift` 的文件头 —— 与 pw 的 `AlbumField` 同一条路。
    /// 关掉即**完全还原**：清过的底色逐个写回原色、渐变层撤掉。
    static var entityPageField: Bool {
        get {
            container.object(forKey: entityPageFieldKey) as? Bool ?? true
        }
        set {
            container.set(newValue, forKey: entityPageFieldKey)
        }
    }

    /// 「**Melox 风页面**」：模糊封面底 + 整页取色 + 头部居中（原「封面下缘溶解」，
    /// 名字是历史遗留，行为早已不止"下缘一条"）。
    ///
    /// **默认关** —— 2026-10-13 用户要求：「专辑/歌单页的**两个按钮默认关闭**」。
    /// 只改 fallback、**不动已存的值**：手动开过的设备保持他开的那一档（与 AMLL 那条同一纪律）。
    static var entityPageDissolve: Bool {
        get {
            container.object(forKey: entityPageDissolveKey) as? Bool ?? false
        }
        set {
            container.set(newValue, forKey: entityPageDissolveKey)
        }
    }

    /// 「**藏掉 Spotify 自己的按键**」：每行的「+」「…」、头部的下载 / 加入 / 观看信息。
    ///
    /// **默认关** —— 2026-10-13 用户要求（同上：「两个按钮默认关闭」）。
    /// ⛔ **右上那颗「…」永远不碰**：pw 的整套做法就骑在它上面（把 ⋯ 里没有的 Sort/Mix
    /// 补进它的 sheet）⇒ 把它藏掉等于把要用的面板弄没了 ✗（见 `EntityPageAppearance` 里的名单）。
    /// **play / shuffle 也一律不碰**（那是真功能）。
    static var entityPageHideChrome: Bool {
        get {
            container.object(forKey: entityPageHideChromeKey) as? Bool ?? false
        }
        set {
            container.set(newValue, forKey: entityPageHideChromeKey)
        }
    }

    // MARK: - 听歌页（NPV）：仿 AM 的取色渐变底

    /// 听歌页**整页底色**换成"封面取色"的三层渐变（AM 那种）。**默认开**。
    ///
    /// 取值来源与理由（含"为什么不模糊"）都写在 `NowPlayingBackdrop` 的文件头。
    /// 关掉即完全还原：把我们改过的那些视图的 `backgroundColor` 写回原值、删掉渐变层。
    static var nowPlayingBackdrop: Bool {
        get {
            container.object(forKey: nowPlayingBackdropKey) as? Bool ?? true
        }
        set {
            container.set(newValue, forKey: nowPlayingBackdropKey)
        }
    }

    /// 听歌页「**一屏**」：把播放器下面那些卡片全折起来 + 把列表钉在它的顶部
    /// —— kumone / Music app 那种"一屏一首歌、滚不动"。**默认开**（2026-10-04 改的，见下）。
    ///
    /// ⚠️ **默认值改过一次，两次都有理由**：
    ///   · 原来**默认关**：折掉卡片会连**歌词卡**一起折掉，那会儿还没有替代的歌词入口；
    ///   · 现在**默认开**：① 「歌词进播放器」（`NowPlayingLyricsPlate`）已经补上那个入口；
    ///     ② 更要紧的是**照片 40/41（kumone）的对照** —— 它中间那块（185–644）**没有任何卡片**，
    ///     卡片堆着就永远不像。而我们的 header 与底部已经和它逐条对上了 ⇒
    ///     **卡片堆是"像不像"的唯一分水岭**，所以它必须是默认行为。
    ///
    /// 仍然可以一键关掉（关掉即完全还原：`restore()` 把列表的 bottom inset 写回记下的原值）。
    ///
    /// 思路与算法借自 spoti.pw v0.21.1（GPL-3.0）的 `Redesigned/Player/PlayerCards.x` +
    /// `PlayerScroll.x`；为什么是"钉住"而不是"把滚动关掉"（关掉会让播放器划不掉）
    /// 写在 `NowPlayingOneScreen` 的文件头。
    ///
    /// 关掉即完全还原：`restore()` 把列表的 bottom inset 写回我们记下的原值，
    /// 卡片折叠那一半读的就是这个开关（立刻生效，不必重启）。
    static var nowPlayingOneScreen: Bool {
        get {
            container.object(forKey: nowPlayingOneScreenKey) as? Bool ?? true
        }
        set {
            container.set(newValue, forKey: nowPlayingOneScreenKey)
        }
    }

    /// 听歌页底部那条**音量条**（我们自己的一层覆盖层上的第一件控件）。**默认开**。
    ///
    /// 它是 kumone 播放页下半屏的辨识度元素之一（Apple Music 没有）。落点与纪律写在
    /// `NowPlayingPageOverlay` 的文件头：**透明覆盖层 + 只加我们自己的视图 +
    /// 容器不吃触摸**，关掉 = 把那一层拿掉，天然完全还原。
    ///
    /// ★ 2026-10-11（用户）：从「默认关」改成「**默认开**」——
    /// 原话「听歌页的那几个功能**全部默认开启**」。
    /// （当初默认关的理由是"让用户先看一眼认不认"；用户看过照片 70/71 之后拍板要开。）
    static var nowPlayingVolume: Bool {
        get {
            container.object(forKey: nowPlayingVolumeKey) as? Bool ?? true
        }
        set {
            container.set(newValue, forKey: nowPlayingVolumeKey)
        }
    }

    /// 听歌页「**歌词进播放器**」。**默认开**。
    ///
    /// 把**我们自己的**逐词歌词画进播放器中段（`npv.bottomStackView` 之上那块），
    /// 这样「一屏」把卡片全折掉之后，页面上仍然有歌词可看 —— 它是「一屏」能默认开的**前置**。
    ///
    /// ★ 2026-10-11（用户）：从「默认关」改成「**默认开**」（「听歌页的那几个功能全部默认开启」）。
    /// 当初默认关的两条理由现在的状态：
    ///   1. "它压住的是 Spotify 自己的卡片区，得先让用户看一眼" —— 用户已经用过并拍板（照片 70/71/75）；
    ///   2. "需要**逐词**数据，没有逐词的歌这一层会自己收起来" —— 仍然成立，而且现在
    ///      **没有词就写一句说明 / 没有时间轴就静态列全文**（见 `NowPlayingLyricsPlate.noticeText()`），
    ///      所以"收起来"不再是唯一结局。
    ///
    /// 渲染复用 `AppleMusicLyricsOverlayView`（内嵌那一档，背景透明），宿主是
    /// `NowPlayingLyricsPlate` 自己的一份 —— 不去抢全屏页那个单例宿主。
    static var nowPlayingLyricsInPlayer: Bool {
        get {
            container.object(forKey: nowPlayingLyricsInPlayerKey) as? Bool ?? true
        }
        set {
            container.set(newValue, forKey: nowPlayingLyricsInPlayerKey)
        }
    }

    /// ★ 2026-10-10（用户提的「**页面记忆**」）：听歌页上"歌词是展开着的那一屏"这个状态**记不记**。
    ///
    /// ⚠️ **默认 `false` = "还没有偏好"**，不是"功能关着"：这个键**只由用户点那枚歌词键来写**
    ///    （点开 ⇒ true，点收起 ⇒ false）。默认 false 的结果就是"用户没表过态时，行为与改动前
    ///    完全一样（每次进播放器都是大封面）"；他**第一次点开**之后，记忆才开始生效。
    ///    如果默认给 `true`，那"从没点开过"的用户一进播放器就会被自动展开 —— 那是错的。
    ///
    /// 用户原话：
    /// > 是不是没有那种页面记忆的功能。就是假如说我当时正在打开歌词的这个页面（照片 63），
    /// > 退出之后再重进也还是在这个页面，不是那个大封面
    ///
    /// 现状（改动前的实证）：歌词展不展开只活在 `NowPlayingLyricsPlate.isOpen` 这个内存变量里，
    /// 而 `remove(reason:)`（页面 `viewWillDisappear`）会走 `closeEverything` 把它清成 `false`
    /// ⇒ **没有记忆**，重进必然是大封面。
    ///
    /// 语义（写死在 `NowPlayingLyricsPlate` 里，不另设开关）：
    ///   · **用户点开**歌词键 ⇒ 记 `true`；**用户点收起** ⇒ 记 `false`。只有这两种动作会改它；
    ///   · **离开页面 / 切歌 / 收起动画 / 切开关**都不动它（那正是"记忆"的含义）；
    ///   · 重进页面时若记的是 `true`、且「歌词进播放器」开着、且这一首**有能画的东西**
    ///     ⇒ 自动铺回去；没词就只打一行日志、保持大封面（不空转）；
    ///   · **落盘**（`UserDefaults`）⇒ 杀掉 App 重开也还记得。
    static var nowPlayingLyricsExpanded: Bool {
        get {
            container.object(forKey: nowPlayingLyricsExpandedKey) as? Bool ?? false
        }
        set {
            container.set(newValue, forKey: nowPlayingLyricsExpandedKey)
        }
    }

    /// 听歌页「**封面与歌词键之间那一行居中歌词**」。**默认开**。
    ///
    /// ★ 2026-10-04（用户建议的第二条，原话）：
    /// > 把现在的大封面做小，不需要那么大（图片 41 的大小差不多）。然后，在封面和歌词按钮中间
    /// > 做一行居中的歌词（类似于 Spotify 的单行歌词，但这行歌词现在是我们自己做）
    ///
    /// 它只在**收起歌词那一屏**出现（展开时整页歌词都在，再来一行就是重复），
    /// 摆在封面底边与控件条上沿的**中点**。做法与判据见
    /// `NowPlayingLyricsPlate.applySingleLyric`（行模型 / "唱到哪一行"都用现成的，
    /// 一处判据都不新写）。
    ///
    /// ⚠️ 默认开：用户是**主动点名要**这个功能的，默认开才看得到效果；
    ///    觉得多余就在 设置 → 扩展功能 里关掉（关掉当场拿走那一行，不用重启）。
    static var nowPlayingSingleLyric: Bool {
        get {
            container.object(forKey: nowPlayingSingleLyricKey) as? Bool ?? true
        }
        set {
            container.set(newValue, forKey: nowPlayingSingleLyricKey)
        }
    }

    /// 听歌页「**未播放歌词行模糊化**」—— 非当前播放的歌词行要不要**发糊**。**默认关**。
    ///
    /// ★ 2026-10-12（用户原话）：
    /// > 现在是未播放歌词行是模糊不清的，加个功能叫「未播放歌词行模糊化」。
    /// > 关闭之后，未当前播放歌词行不模糊化，**默认关闭**。
    ///
    /// 关着（默认）：非当前行**只变淡、不发糊**（变淡是"焦点"这件事的表达，两边都有）；
    /// 翻开：回到改动前那条公式 `maximumNonFocusedBlurRadius × (1 − 焦点强度)`
    /// （`AppleMusicLyricsPage.blurRadius`）。
    ///
    /// ⚠️ 拨开关要**当场生效**：它只写 `UserDefaults`、不会让 `currentLyricsVersion` 变，
    ///    所以它进的是 `romanizationSwitchesFingerprint()` 那个"要不要重建渲染层"的指纹
    ///    （与罗马字 / 译文两颗同一个理由；不进去就得等换歌 —— 那正是上一轮修掉的"哑开关"）。
    static var nowPlayingBlurUnplayedLyrics: Bool {
        get {
            container.object(forKey: nowPlayingBlurUnplayedLyricsKey) as? Bool ?? false
        }
        set {
            container.set(newValue, forKey: nowPlayingBlurUnplayedLyricsKey)
        }
    }

    /// 调试页「**替换寻找歌词时的占位符**」—— 用户 2026-10-12 点名要的**彩蛋**。**默认关**。
    ///
    /// 用户原话：
    /// > 在转储视图树的下面，名字：替换寻找歌词时的占位符。它的作用：正常来讲找歌词的时候，
    /// > 页面会显示「正在查找歌词...」，换成「少女祈祷中...」。这东西作为一个彩蛋好了。
    ///
    /// 开 ⇒ 还在取词时那句占位文本换成 `lyrics_looking_up_easter_egg`
    /// （改的只有 `NowPlayingLyricsPlate.noticeText()` 里"还在查"那一档，**一处**）。
    /// 默认关：彩蛋要自己发现，别默认把所有人看到的那句话换掉。
    static var lyricsSearchPlaceholderEasterEgg: Bool {
        get {
            container.object(forKey: lyricsSearchPlaceholderEasterEggKey) as? Bool ?? false
        }
        set {
            container.set(newValue, forKey: lyricsSearchPlaceholderEasterEggKey)
        }
    }

    /// 听歌页「**控制键换成本地字形**」（上一首 / 播放暂停 / 下一首）。**默认开**。
    ///
    /// 这是照 spoti.pw v0.21.1（GPL-3.0）`PlayerControls.x` 的做法：**原生按钮留着**
    /// （动作 / 可用状态 / 无障碍 / 手势区全在），只把按钮里原来那个图标**设成透明**，
    /// 再叠一个我们自己的 SF Symbol 字形（不吃触摸）。播放键底下那层白圆盘一起透明掉 ——
    /// 照片 40/41（kumone）里是**裸字形**，没有圆盘。
    ///
    /// ★ 2026-10-11（用户）：从「默认关」改成「**默认开**」（「听歌页的那几个功能全部默认开启」）。
    /// 当初默认关的理由是"它改的是**别人按钮的内部**（透明度），这类改动本仓库栽过，
    /// 先让用户看一眼" —— 现在用户已经看过照片 70/71（三颗键是本地字形）、并点名要开；
    /// 关掉仍然即把透明度写回并拿走我们的字形（`NowPlayingControlsPlate.restore()`）。
    static var nowPlayingControlGlyphs: Bool {
        get {
            container.object(forKey: nowPlayingControlGlyphsKey) as? Bool ?? true
        }
        set {
            container.set(newValue, forKey: nowPlayingControlGlyphsKey)
        }
    }

    // MARK: - 音乐库（改原生）

    /// 音乐库大标题 + 收掉顶部滚边渐隐。**默认开**。
    ///
    /// 这是"改原生"路线的第一个开关（区别于听歌页那条"加壳"路线）：
    /// 它改的是 Spotify 自己的标题对齐与那层 `LiquidGlass.GradientView` 灰纱，
    /// 关掉即把原值写回。
    static var libraryLargeTitle: Bool {
        get {
            container.object(forKey: libraryLargeTitleKey) as? Bool ?? true
        }
        set {
            container.set(newValue, forKey: libraryLargeTitleKey)
        }
    }

    // MARK: - 主页（改原生，2026-10-12）

    /// 主页头部按 **Apple Music 的 Listen Now** 改：大标题贴左（自己画、文字取标签栏那一颗 ⇒ 跟随语言）、
    /// 头像靠右、收掉「全部/音乐/播客」那排 pills 与顶部灰纱。**默认开**（与音乐库那颗同一个观感档）。
    ///
    /// ⚠️ 它与音乐库那颗**刻意相反**的一点：音乐库的筛选 chips **保留**（排序要用，pw 删过又装回来），
    /// 而主页那排 pills 是**内容筛选**、AM 没有 ⇒ 收掉。理由写在 `HomeHeaderAppearance` 文件头。
    /// 关掉即还原（标题移除、RTL 翻回、pills 与灰纱的原 alpha 写回）。
    static var homeLargeTitle: Bool {
        get {
            container.object(forKey: homeLargeTitleKey) as? Bool ?? true
        }
        set {
            container.set(newValue, forKey: homeLargeTitleKey)
        }
    }

    // MARK: - customize 响应体抓取（排障用）

    /// 「转储 customize 响应体」。**默认关**，只为**替换种子快照**而存在。
    ///
    /// 背景：flag 改写依赖 `customize` 的响应体，而我们只能改写**拿得到的** body。
    /// 现在用的是随包的 `.bnk`（9.1.76 时期转存）当种子，它够了、但不够**精确**——
    /// 那份快照里没有 9.1.86 新下发的条目（新设计那批 flag 就在其中）。
    ///
    /// 所以：打开这个开关 + 打开「覆盖配置」清一次缓存（逼出 200）→ 下一次启动
    /// 就能从调试日志里取到**你自己这版**的真 body（base64），把它转成新的
    /// `.bnk` 换掉旧的即可（见 `SpotifyResponsePatcher.dumpCustomizeBodyIfEnabled`
    /// 的说明，里面有解码命令）。
    static var dumpCustomizeBody: Bool {
        get {
            container.object(forKey: dumpCustomizeBodyKey) as? Bool ?? false
        }
        set {
            container.set(newValue, forKey: dumpCustomizeBodyKey)
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
