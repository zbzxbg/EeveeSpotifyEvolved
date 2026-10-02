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
    private static let hideMiniPlayerBarKey = "hideMiniPlayerBar"
    private static let hideSingalongLineKey = "hideSingalongLine"
    private static let hideHomeHeaderKey = "hideHomeHeader"
    private static let hideConnectButtonKey = "hideConnectButton"
    private static let hideAddToButtonKey = "hideAddToButton"
    private static let blockedArtistsEnabledKey = "blockedArtistsEnabled"
    private static let blockedArtistsKey = "blockedArtists"
    private static let dumpCustomizeBodyKey = "dumpCustomizeBody"
    private static let libraryLargeTitleKey = "libraryLargeTitle"
    private static let tabBarGlassKey = "tabBarGlass"
    private static let tabBarHideLabelsKey = "tabBarHideLabels"
    private static let miniBarGlassKey = "miniBarGlass"
    private static let nowPlayingBackdropKey = "nowPlayingBackdrop"
    private static let nowPlayingOneScreenKey = "nowPlayingOneScreen"
    private static let nowPlayingVolumeKey = "nowPlayingVolume"
    private static let nowPlayingLyricsInPlayerKey = "nowPlayingLyricsInPlayer"
    private static let nowPlayingControlGlyphsKey = "nowPlayingControlGlyphs"

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
        hapticsEnabledKey,
        hapticsStrengthKey,
        hapticsSurfaceKeywordsKey,
        hapticsLogControlsKey,
        dumpViewTreeKey,
        hideMiniPlayerBarKey,
        hideSingalongLineKey,
        hideHomeHeaderKey,
        hideConnectButtonKey,
        hideAddToButtonKey,
        blockedArtistsEnabledKey,
        blockedArtistsKey,
        dumpCustomizeBodyKey,
        libraryLargeTitleKey,
        tabBarGlassKey,
        tabBarHideLabelsKey,
        miniBarGlassKey,
        nowPlayingBackdropKey,
        nowPlayingOneScreenKey,
        nowPlayingVolumeKey,
        nowPlayingLyricsInPlayerKey,
        nowPlayingControlGlyphsKey,

        // 不在上面那批常量里、但同样属于我们的：
        // 「Flag 覆盖」表（`FlagOverrideStore` 用 `flagOverrides` 存 JSON Data）。
        "flagOverrides",
    ]

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

    // MARK: - 外观（Appearance）

    // ⛔「深色栏底色」(amoledEnabled) 已于 2026-10-02 删除：
    // 新设计语言下它每次布局都主动让位，是个纯空操作。

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
    /// **默认关**：用户明确说过那一行本身**不是**问题 —— 他反馈的是"逐词歌词开、更好的
    /// 逐词歌词关"时逐行歌词挂错地方，那个已经修在 `InlineLyricsHostLocator` 里。
    /// 这个开关只是留个选择，想要更干净的封面再打开。
    static var hideSingalongLine: Bool {
        get {
            container.object(forKey: hideSingalongLineKey) as? Bool ?? false
        }
        set {
            container.set(newValue, forKey: hideSingalongLineKey)
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

    /// 底部标签栏铺**一条玻璃胶囊**（主页 / 搜索 / 音乐库 / 创建 浮在它上面）。**默认开**。
    ///
    /// ── 三版演进（都记下来，别再退回第一版）──────────────────────────────────
    ///   1. 第一版：每颗标签各一块 `103×49` 玻璃 → 不融合、盖住选中滑块，"更难看"；
    ///   2. 第二版：同样每颗一块、只内缩 10pt → 还是四块，方向没变；
    ///   3. **这一版**：整条栏**一条**胶囊（左右留 8、上下留 6、半径=半高）——
    ///      这才是照片里那个形状；四颗标签与 Spotify 的选中滑块全部浮在上面。
    ///
    /// "靠近就融合"那种 morph 需要把 Spotify 的四颗视图搬进同一个玻璃容器，
    /// 会打断它们的布局与手势 —— 不做（见 `TabBarGlass.x.swift` 开头的说明）。
    static var tabBarGlass: Bool {
        get {
            container.object(forKey: tabBarGlassKey) as? Bool ?? true
        }
        set {
            container.set(newValue, forKey: tabBarGlassKey)
        }
    }

    // MARK: - 标签文字（默认藏）

    /// 隐藏四颗标签的**文字**（照片 21/23/25 里那条栏是没有文字的）。**默认开**。
    ///
    /// 这一条同时把"玻璃太扁"顺手解掉：内容带从"图标 + 文字 44pt"变成"只有图标 ~24pt"，
    /// 胶囊自然收到 ~40pt（正好是照片里的比例），图标仍然居中。
    ///
    /// 思路借自 **spoti.pw** 的「Hide labels」（见它的 `docs/tweaks.md`）——
    /// **只借思路，代码自己写**（红线见会话文档 §10）。
    static var tabBarHideLabels: Bool {
        get {
            container.object(forKey: tabBarHideLabelsKey) as? Bool ?? true
        }
        set {
            container.set(newValue, forKey: tabBarHideLabelsKey)
        }
    }

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

    /// 听歌页底部那条**音量条**（我们自己的一层覆盖层上的第一件控件）。**默认关**。
    ///
    /// 它是 kumone 播放页下半屏的辨识度元素之一（Apple Music 没有）。落点与纪律写在
    /// `NowPlayingPageOverlay` 的文件头：**透明覆盖层 + 只加我们自己的视图 +
    /// 容器不吃触摸**，关掉 = 把那一层拿掉，天然完全还原。
    static var nowPlayingVolume: Bool {
        get {
            container.object(forKey: nowPlayingVolumeKey) as? Bool ?? false
        }
        set {
            container.set(newValue, forKey: nowPlayingVolumeKey)
        }
    }

    /// 听歌页「**歌词进播放器**」。**默认关**。
    ///
    /// 把**我们自己的**逐词歌词画进播放器中段（`npv.bottomStackView` 之上那块），
    /// 这样「一屏」把卡片全折掉之后，页面上仍然有歌词可看 —— 它是「一屏」能默认开的**前置**。
    ///
    /// ⚠️ 默认关的两个理由：
    ///   1. 它压住的是 Spotify 自己的卡片区（视觉上"遮了一块"），得先让用户看一眼认不认；
    ///   2. 需要**逐词**数据（`hasUsableWordLevelData`），没有逐词的歌这一层会自己收起来。
    /// 渲染复用 `AppleMusicLyricsOverlayView`（内嵌那一档，背景透明），宿主是
    /// `NowPlayingLyricsPlate` 自己的一份 —— 不去抢全屏页那个单例宿主。
    static var nowPlayingLyricsInPlayer: Bool {
        get {
            container.object(forKey: nowPlayingLyricsInPlayerKey) as? Bool ?? false
        }
        set {
            container.set(newValue, forKey: nowPlayingLyricsInPlayerKey)
        }
    }

    /// 听歌页「**控制键换成本地字形**」（上一首 / 播放暂停 / 下一首）。**默认关**。
    ///
    /// 这是照 spoti.pw v0.21.1（GPL-3.0）`PlayerControls.x` 的做法：**原生按钮留着**
    /// （动作 / 可用状态 / 无障碍 / 手势区全在），只把按钮里原来那个图标**设成透明**，
    /// 再叠一个我们自己的 SF Symbol 字形（不吃触摸）。播放键底下那层白圆盘一起透明掉 ——
    /// 照片 40/41（kumone）里是**裸字形**，没有圆盘。
    ///
    /// ⚠️ 默认关的理由：它改的是**别人按钮的内部**（透明度），这类改动本仓库栽过
    /// （藏错一个视图 = 整页空白），所以先让用户看一眼；关掉即把透明度写回并拿走我们的字形。
    static var nowPlayingControlGlyphs: Bool {
        get {
            container.object(forKey: nowPlayingControlGlyphsKey) as? Bool ?? false
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
