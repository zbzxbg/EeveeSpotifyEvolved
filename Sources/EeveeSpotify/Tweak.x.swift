import Orion
import EeveeSpotifyC
import UIKit
import Foundation
import ObjectiveC.runtime
import os

/// Debug 级统一日志（ng / Reborn-ng 实现）。
/// 受设置里的「启用日志记录」开关控制：关闭时既不写统一日志，也不写导出文件。
private let eeveeLogger = Logger(
    subsystem: "com.eeveespotify",
    category: "debug"
)

/// 日志文件的**串行写队列**。
///
/// 为什么必须有：`appendLogFile` 是"open → seekToEndOfFile → write → close"，本身不是原子操作，
/// 而歌词响应是**并发**处理的（同一首歌的两个 color-lyrics 响应各跑在一个后台队列上，
/// 见 `HttpClientURLSessionHooks`）。两个线程同时 seek 到同一个末尾再各自写 → 有一行被覆盖。
///
/// 真机证据（2026-09-27 日志 16，`Corner Store`）：第一次响应的
/// `synthetic line timing applied` **整行消失**，而它的孪生响应（1 秒后）和其余每一首都在，
/// 且上下文行完整 —— 就是这种丢行。丢行会让"某行不在 = 代码没跑"这类推断直接失效。
///
/// 用 `sync` 而不是 `async`：崩溃取证时最后几行必须已经落盘（异步会把它们留在队列里）。
private let logWriteQueue = DispatchQueue(label: "com.eeveespotify.debuglog.write")

private func appendLogFile(_ message: String) {
    let timestamp = Date().description
    let logMessage = "[\(timestamp)] \(message)\n"

    logWriteQueue.sync {
        let logPath = NSTemporaryDirectory() + "eeveespotify_debug.log"

        if FileManager.default.fileExists(atPath: logPath) {
            if let fileHandle = FileHandle(forWritingAtPath: logPath) {
                fileHandle.seekToEndOfFile()
                if let data = logMessage.data(using: .utf8) {
                    fileHandle.write(data)
                }
                fileHandle.closeFile()
            }
        } else {
            try? logMessage.write(toFile: logPath, atomically: true, encoding: .utf8)
        }
    }
}

/// ⚠️ 2026-09-30：这里**必须**过 `DebugLogSanitizer.sanitize`。
///
/// 理由：这一行同时写文件**和** `os_log(privacy: .public)`，而系统统一日志是清不掉的
/// （设置里的「清除调试日志」只清 App 容器里那份）。只在导出时脱敏的话，
/// 系统日志里那份仍然是明文 —— 所以脱敏放在写入口，而不是导出按钮里。
func writeDebugLog(_ message: String) {
    guard UserDefaults.enableLogRecording else { return }

    let safe = DebugLogSanitizer.sanitize(message)
    eeveeLogger.debug("\(safe, privacy: .public)")
    appendLogFile(safe)
}

/// 错误级日志：统一日志走 .error 级（Console 可按 error 过滤），导出文件加 [ERROR] 前缀。
func writeErrorLog(_ message: String) {
    guard UserDefaults.enableLogRecording else { return }

    let safe = DebugLogSanitizer.sanitize(message)
    eeveeLogger.error("\(safe, privacy: .public)")
    appendLogFile("[ERROR] \(safe)")
}

/// `NSLog` 版日志：同样过一遍脱敏。
///
/// 为什么单独给一个函数：这批调用点**不受**「启用日志记录」开关控制（NSLog 直接进
/// 系统统一日志），也**不进**导出文件。既然开关管不到它们，脱敏就更不能漏 ——
/// 否则用户在设置里关掉日志记录、把文件删干净，系统日志里那份明文照样在。
func eeveeSanitizedNSLog(_ message: String) {
    NSLog("%@", DebugLogSanitizer.sanitize(message))
}
// Timestamp of tweak initialization — persists across Orion reinits within the same process
// using an environment variable. This prevents the 30s auth window from resetting
// when the C++ timer triggers a session reinit cycle.
let tweakInitTime: Date = {
    if let existing = getenv("EEVEE_BOOT_TIME"),
       let interval = Double(String(cString: existing)) {
        return Date(timeIntervalSince1970: interval)
    }
    let now = Date()
    setenv("EEVEE_BOOT_TIME", "\(now.timeIntervalSince1970)", 1)
    return now
}()

func exitApplication() {
    UIControl().sendAction(#selector(URLSessionTask.suspend), to: UIApplication.shared, for: nil)
    Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { _ in
        exit(EXIT_SUCCESS)
    }
}

// Premium hooks are split so core network/bootstrap patching can stay enabled
// even if certain UI hooks break on a specific Spotify build.
struct PremiumBootstrapGroup: HookGroup { }      // Intercept bootstrap + mutate UCS
struct PremiumUIHooksGroup: HookGroup { }       // UI JSON injections, Siri tweaks, etc.

struct BasePremiumPatchingGroup: HookGroup { }

struct IOS14PremiumPatchingGroup: HookGroup { }
struct NonIOS14PremiumPatchingGroup: HookGroup { }
struct IOS14And15PremiumPatchingGroup: HookGroup { }
struct V91PremiumPatchingGroup: HookGroup { } // For Spotify 9.1.x versions
struct LatestPremiumPatchingGroup: HookGroup { }

// Spotify 9.1.x originally removed the offline helper, so this version family
// skipped the reminder hook entirely. Newer 9.1 builds expose the modern helper
// again. Activate only that hook when its exact Objective-C entry point exists.
func activateV91ServerSidedReminderIfAvailable() {
    let className = ContentOffliningUIHelperImplementationModernHook.targetName
    let selector = Selector((
        "downloadToggledWithCurrentAvailability:addAction:removeAction:pageIdentifier:pageURI:interactionID:"
    ))

    guard let cls = NSClassFromString(className),
          class_getInstanceMethod(cls, selector) != nil else {
        writeDebugLog("[INIT] Server-sided download reminder unavailable on this 9.1.x build")
        return
    }

    LatestPremiumPatchingGroup().activate()
    writeDebugLog("[INIT] Activated server-sided download reminder for 9.1.x")
}

func activatePremiumPatchingGroup() {
    BasePremiumPatchingGroup().activate()
    
    if EeveeSpotify.hookTarget == .lastAvailableiOS14 {
        IOS14PremiumPatchingGroup().activate()
    }
    else if EeveeSpotify.hookTarget == .v91 {
        // 9.1.x versions: Use NonIOS14 hooks but skip offline content hooks
        NonIOS14PremiumPatchingGroup().activate()
        // Only activate if Spotify's UIView category method exists in this build —
        // the method was removed/renamed in 9.1.28 and hooking a missing method is a fatal crash.
        let trackRowsSel = Selector(("initWithViewURI:onDemandSet:onDemandTrialService:trackRowsEnabled:productState:"))
        if UIView.instancesRespond(to: trackRowsSel) {
            V91PremiumPatchingGroup().activate()
        }
    }
    else {
        NonIOS14PremiumPatchingGroup().activate()
        
        if EeveeSpotify.hookTarget == .lastAvailableiOS15 {
            IOS14And15PremiumPatchingGroup().activate()
        }
        else {
            LatestPremiumPatchingGroup().activate()
        }
    }
}

// MARK: - Session protection activation
// Guard each hook group behind runtime checks so minor Spotify updates
// (e.g., 9.1.34 -> 9.1.36) don't crash the app at launch due to
// missing private selectors.
func activateSessionLogoutProtection(minimal: Bool) {
    func log(_ msg: String) {
        NSLog("[EeveeSpotify][SessionProtect] %@", msg)
    }

    @inline(__always)
    func classHasInstanceMethod(_ cls: AnyClass, _ sel: Selector) -> Bool {
        return class_getInstanceMethod(cls, sel) != nil
    }

    if minimal {
        // Only the URLSessionTask hook (used for diagnostics + cancelling revoke endpoints)
        // tends to be stable across minor versions.
        if let cls = NSClassFromString("NSURLSessionTask"), classHasInstanceMethod(cls, #selector(URLSessionTask.resume)) {
            SessionLogoutNetworkHookGroup().activate()
            log("Activated URLSessionTask hooks (minimal)")
        } else {
            log("Skipped URLSessionTask hooks (missing selector)")
        }
        return
    }

    // Auth hooks
    if let cls = NSClassFromString("SPTAuthSessionImplementation") {
        let required: [Selector] = [
            Selector(("logout")),
            Selector(("logoutWithReason:")),
            Selector(("callSessionDidLogoutOnDelegateWithReason:")),
            Selector(("logWillLogoutEventWithLogoutReason:")),
            Selector(("destroy")),
        ]
        let ok = required.allSatisfy { classHasInstanceMethod(cls, $0) }
        if ok {
            SessionLogoutAuthHookGroup().activate()
            log("Activated auth hooks")
        } else {
            log("Skipped auth hooks (missing selector)")
        }
    } else {
        log("Skipped auth hooks (missing class SPTAuthSessionImplementation)")
    }

    // Connectivity hooks
    if let cls = NSClassFromString("_TtC24Connectivity_SessionImpl18SessionServiceImpl") {
        let required: [Selector] = [
            Selector(("automatedLogoutThenLogin")),
            Selector(("userInitiatedLogout")),
            Selector(("sessionDidLogout:withReason:")),
        ]
        let ok = required.allSatisfy { classHasInstanceMethod(cls, $0) }
        if ok {
            SessionLogoutConnectivityHookGroup().activate()
            log("Activated connectivity hooks")
        } else {
            log("Skipped connectivity hooks (missing selector)")
        }
    } else {
        log("Skipped connectivity hooks (missing class SessionServiceImpl)")
    }

    // Ably hooks
    if let cls = NSClassFromString("ARTWebSocketTransport") {
        let required: [Selector] = [
            Selector(("webSocket:didReceiveMessage:")),
            Selector(("webSocket:didFailWithError:")),
        ]
        let ok = required.allSatisfy { classHasInstanceMethod(cls, $0) }
        if ok {
            SessionLogoutAblyHookGroup().activate()
            log("Activated Ably hooks")
        } else {
            log("Skipped Ably hooks (missing selector)")
        }
    } else {
        log("Skipped Ably hooks (missing class ARTWebSocketTransport)")
    }

    // Network hooks
    if let cls = NSClassFromString("NSURLSessionTask"), classHasInstanceMethod(cls, #selector(URLSessionTask.resume)) {
        SessionLogoutNetworkHookGroup().activate()
        log("Activated URLSessionTask hooks")
    } else {
        log("Skipped URLSessionTask hooks (missing selector)")
    }
}

// MARK: - Bootstrap breadcrumbs
@inline(__always)
func eeveeBreadcrumb(_ label: String) {
    let path = NSTemporaryDirectory() + "eeveespotify_boot.txt"
    let ts = Date().description
    let line = "[\(ts)] \(label)\n"
    if let data = line.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: path), let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}

@inline(__always)
func eeveeEnvFlag(_ name: String) -> Bool {
    guard let v = getenv(name) else { return false }
    let s = String(cString: v).lowercased()
    return s == "1" || s == "true" || s == "yes" || s == "y"
}

// ── 这里曾经有一个"运行时类名探针"（`logPlayerTrackCandidates`）───────────────
//
// 它的目的：离线找出 9.1.x 上到底是哪个类提供 `metadata()`（`has_lyrics` 就在那个
// 字典里），好把 `SPTPlayerTrackHook.targetName` 改成真名。
//
// **已经删掉了**，原因是它连续两次造成启动崩溃，而且一次都没能给出可用结果：
//   · 第一次：挂在「启用日志记录」下面 → 开日志 + 杀后台 + 重开 = 启动后约 291ms
//     崩（EXC_BREAKPOINT/SIGTRAP，栈在 `_CF_forwarding_prep_0` → `swift_getObjectType`，
//     寄存器 `__NSGenericDeallocHandler` = 给已释放对象发消息）；
//   · 第二次：改成独立开关 + 启动后 3 秒 + 只扫白名单前缀，仍然崩（同一崩溃地址
//     0x19dbe54b4、同一份指令流），而且**崩溃时日志文件里什么都没有** ——
//     说明崩在写日志之前，或者日志所在的 tmp 目录随重装被清掉了。
// 结论：在这台设备上"运行时诊断"这条路不可观测也不可控，不值得再试第三次。
//
// 真正需要"哪个类持有 has_lyrics"这个答案时，走离线路线：
//   Tools/eevee-hookfinder/extract_player_track_class.py
// 它直接读解密 IPA 的 `__objc_classname` / `__objc_methname`，不碰运行时，
// 已经据此确认 9.1.86 里 `SPTPlayerTrack` 是存在的（当初 dump-unknown.txt
// 只抓 `_TtC` 开头的 Swift 名，才误判成"不存在"）。

struct EeveeSpotify: Tweak {
    static let version = "6.6.8"
    static let buildNumber = "2"
    static let repoSlug = GeneratedConfig.repoSlug
    
    static var hookTarget: VersionHookTarget {
        let version = Bundle.main.infoDictionary!["CFBundleShortVersionString"] as! String
        
        NSLog("[EeveeSpotify] Detected Spotify version: \(version)")
        
        switch version {
        case "9.0.48":
            return .lastAvailableiOS15
        case "8.9.8":
            return .lastAvailableiOS14
        case _ where version.contains("9.1"):
            // 9.1.x versions don't have offline content helper classes
            return .v91
        default:
            return .latest
        }
    }
    
    // MARK: - Non-fatal hook error handling
    //
    // Orion's default `handleError(_:)` forwards to `handleErrorDefault(_:)`, which logs
    // and then calls `fatalError`, instantly killing the app. This fires for ANY hook that
    // fails to activate - a missing target class, a renamed/removed selector, a method-add
    // conflict, etc. Critically, this can happen for hooks in `DefaultGroup`
    // (e.g. UIOpenURLContextHook, UIApplicationLiveContainerSharingHook), which Orion
    // activates automatically during its init sequence, BEFORE `EeveeSpotify.init()` runs -
    // so none of the NSClassFromString/selector guards below can protect against it.
    //
    // Since this codebase already treats individual hook groups as independently optional
    // (kill switches, per-group existence checks, "minimal" fallbacks for 9.1.x), a single
    // hook failing to bind on an unexpected Spotify/iOS build should degrade gracefully
    // instead of taking down the whole app. Log it and move on.
    static func handleError(_ error: OrionHookError) {
        let description = error.description
        NSLog("[EeveeSpotify][OrionError] Hook activation failed (non-fatal): %@", description)
        writeDebugLog("[ORION ERROR] \(description)")
        eeveeBreadcrumb("Orion hook activation failed (continuing): \(description)")
        // Deliberately NOT calling handleErrorDefault(error) here - that is what fatalErrors.
    }

    init() {
        eeveeBreadcrumb("Tweak init() entered")
        // Reset per-launch bootstrap state; this MUST NOT persist across restarts.
        // Otherwise Spotify can get stuck on splash because bootstrap is cancelled.
        UserDefaults.hasPatchedBootstrap = false

        // Recovery path for private-class changes: this must run before every
        // manual hook activation, including ad and Premium banner blockers.
        if eeveeEnvFlag("EEVEE_DISABLE_ALL") {
            eeveeBreadcrumb("EEVEE_DISABLE_ALL=1 -> returning without hooks")
            return
        }

        // Local-only premium force. Activated first after the recovery kill-switch,
        // before version gating. Independent of patchType / bootstrap
        // patching / network interception. Keeps premium UI/state even if every
        // other Eevee path is disabled.
        activateEeveePremiumForce()

        activateEeveeCrossfadeForce()

        // customize 种子（2026-10-01）：必须在任何网络改写之前跑。
        //
        // 冷启动第一个 customize 常是 304、没有 body，那条路径下
        // `cachedCustomizeData` 会永远填不满（唯一写入点在 `patch()` 里，而它只有拿到
        // body 才会被调用）→ `modifyRemoteConfiguration()` 一次都不跑 → `[Flags]` 全灭、
        // flag 替换（含「Flag 覆盖」）静默失效。这里用随包的 `.bnk` 先喂一份，
        // 304 兜底就有东西可回放；真 body 一到即被替换。详见
        // `SpotifyResponsePatcher.seedCustomizeDataIfNeeded`。
        SpotifyResponsePatcher.seedCustomizeDataIfNeeded()

        // 播放器控件触感：开关关着时连 hook 都不装（见 PlayerHaptics.x.swift），
        // 所以不开触感的用户是零开销。开关在设置页读一次，改动需重启。
        activatePlayerHaptics()

        // 上报拦截的**请求侧** hook（响应侧那半在 `SpotifyResponsePatcher.shouldBlock`
        // 里，只是兜底）。这条**总是装**，开关在运行期读 —— 打开就生效，不必重启。
        activateTelemetryRequestBlock()

        // ⛔ AMOLED（深色栏底色）已于 2026-10-02 删除。
        // 理由：新设计语言下它每次布局都主动让位（`if NewDesignLanguage.isActive { 记一行; return }`），
        // 是个纯空操作 + 21KB 死代码；只有兼容模式的构建（`liquid_glass=false`）里才活，
        // 而本仓库只服务新设计基线。它原来承担的那个"运行期观察新设计"的兜底信号
        // 已搬到 `NewDesignYield.observeNewDesignMarkersIfNeeded`。

        // 新设计语言下让我们自己给旧设计打的补丁让位（目前是标签栏那层渐隐遮罩）。
        activateNewDesignYield()

        // ⛔ 听歌页那套外观代码（自绘壳 / 玻璃顶栏 / 吸顶头让位 / 顶部大标题 / 满屏取色背景）
        // 已于 2026-10-02 **整块删除** —— bug 太多（照片 19/20 的糊底、两颗 ⌄、顶栏与吸顶头
        // 互相打架……），先放一边，等导航栏这条线收干净再重做。
        // 删掉的是整个文件 `Appearance/NowPlayingShell.x.swift`（含 `StickyHeaderYieldHook`）。

        // 底部标签栏（主页/搜索/音乐库/创建）的真液态玻璃。
        // 真类名从解密 IPA 核出：`NavigationUI_TabBarImpl.TabBarItemElementView`
        // 与 `CreateMenu_TabBarItemImpl.CreateMenuTabBarItemView`。
        activateTabBarGlass()

        // 标签栏内部结构探针：**只读、只打一次日志**，用来量出那条栏的真实层级
        // （谁是底、谁是选中滑块、图标在哪、安全区多少）。
        // 第一版玻璃我是按"每颗 103×49"猜的，结果又难看又挡了选中胶囊 —— 不再猜。
        activateTabBarGlassProbe()

        // 音乐库：改**原生**视图的第一批（大标题左对齐 + 收掉顶部滚边渐隐）。
        // 与听歌页那条"加壳"路线不同 —— 它改的是 Spotify 自己的视图，关掉即还原。
        activateLibraryAppearance()

        // ★ 2026-10-12：主页头部 —— 与音乐库同一套"AM 化"（大标题贴左 + 头像靠右 + 收 pills/灰纱），
        //   但**挂点不同**：主页的头随滚动动，所以挂在页面的 `viewDidLayoutSubviews` 上（见那个文件头）。
        activateHomeHeaderAppearance()

        // 清爽开关（迷你播放条 / 标签栏渐隐 / free-tier 提示条）。同上：总是装、实时读。
        activateDeclutterChrome()

        // 播放器控制键的字形替换（藏原生图标 + 叠自己的字形，原生按钮留着）。
        // 做法照 spoti.pw v0.21.1 的 `PlayerControls.x`（GPL-3.0），见 `NowPlayingControlsPlate` 文件头。
        activateNowPlayingControls()

        // ★ 2026-10-09：换歌那一瞬间的"大封面闪一下"（照片 61）—— **事件驱动**地按住封面。
        //   那条每 0.3s 的复查节拍永远追不上"新封面刚建好"的那一帧（见 `CoverFlashGuard.x.swift`）。
        activateCoverFlashGuard()

        // ★ 2026-10-13（用户第 5 轮问的）：「歌单封面是歌单里前四首歌的专辑封面拼成的一张，
        //   有没有办法让它变成一张？」—— 能，而且不用动视图层：
        //   那个四宫格**不是视图拼的**，地址里就串着四张图的 id
        //   （`https://mosaic.scdn.co/<size>/<id1><id2><id3><id4>`，IPA 的 `__cstring` 里逐字有
        //   模板串 `https://mosaic.scdn.co/%lu/%@`）；把路径截到**第一个 40 位 id**，
        //   服务端回的是一张正常的单张封面（本机实测 640/300 都是 200 + image/jpeg）。
        //   钩子挂在 `SPTMosaicImageLoaderRequest` 拆路径之前（`load` / `loadMosaic` / `URL`），
        //   而**不是**去藏/替换视图 —— 视图那边拿到的本来就是一张成品图。
        //   证据、为什么不能写 `setURL:`、以及关掉开关的效果都在
        //   `Appearance/PlaylistSingleCover.x.swift` 文件头。**默认开**（就是他要的结果）。
        activatePlaylistSingleCover()

        // ⛔「播放器双击手势」已于 2026-10-04 删除（用户拍板：先删掉，之后再搞）。
        //   原因（都在日志里）：① 手势挂在**页面根视图**上 ⇒ 在播放键上方双击也会跳歌
        //   （`[Gestures] diag … singleTapsAbove=2`，日志 39/40/41）；② 它最该起作用的那一面
        //   （全屏歌词）默认关，30 份日志里一次都没验过；③ 最近 8 份日志里它**一次都没被用过**。
        //   原来的实现、设置行、UserDefaults 键与 7 条文案**全部删除**，不留"按了会误伤"的入口。
        //   要重做时的三条要求写在 `NowPlayingBackdrop` 同级的文档里 —— 见
        //   `Tools/eevee-hookfinder/SESSION_2026-10-03_NIGHT.md` §10（含修法：控件上不认 + 单击让位）。

        // 调试用视图树转储：默认关，开关在「调试」页且打开即生效（那边会直接调
        // `applyEnabledState()`）；这里只是让重启后能自动续上。
        ViewTreeDumper.applyEnabledState()

        // ★ 2026-10-03 夜：一次性「**探针包**」（`ProbePack`）—— 把"只有装一次机才知道"的
        //   只读事实一次问完（pw v0.21.1 那些目标类在 9.1.88 上还在不在…）。
        //   **只读、只打日志**，查完整块删。它走 `writeDebugLog` ⇒「启用日志记录」关着时零动作。
        ProbePack.runOnce()

        // 屏蔽艺人：1 秒一次的只读轮询，发现换歌就判一次（名单空着时它什么都不做）。
        // 不用新增 hook 的原因写在 `BlockedArtistSkip` 顶部。
        BlockedArtistSkip.start()

        // TESTING: extended ad blocker (NPV/lyrics ad, home brand-ads, in-stream).
        activateEeveeAdBlockerExtended()

        // Block premium upsell / "Like listening without limits?" popups.
        activateUpsellPopupBlocker()

        // Block the newer Swift service-backed Premium sheets/cards used by
        // Spotify 9.1.x. Each target is runtime-gated for minor-version safety.
        activateUpsellServiceBlocker()

        // Block upsell components injected into Hub/home JSON (e.g. upgrade banners).
        if NSClassFromString("HUBViewModelBuilderImplementation") != nil {
            AdBlockerGroup().activate()
            NSLog("[EeveeSpotify] AdBlockerGroup activated")
        }

        // activateEeveeFlexGesture()

        // Clean Share Links: swizzle the concrete class of UIPasteboard.general in
        // addition to the ClassHook<UIPasteboard> hooks — the general pasteboard is a
        // private subclass whose overridden setters would otherwise bypass base-class
        // swizzles. Installed unconditionally; cleaning is gated per-call by the toggle.
        PasteboardConcreteSwizzler.install()

        // Activate session logout protection first.
        // NOTE: On some Spotify 9.1.x builds, Orion can still crash even if a selector exists
        // (e.g., method type encoding changes). Be conservative for 9.1.x.
        if EeveeSpotify.hookTarget == .v91 {
            // Minimal protection only (safest hook)
            activateSessionLogoutProtection(minimal: true)
        } else {
            activateSessionLogoutProtection(minimal: false)
        }

        let spotifyVersion = Bundle.main.infoDictionary!["CFBundleShortVersionString"] as! String
        let spotifyBuild = Bundle.main.infoDictionary!["CFBundleVersion"] as? String ?? "?"
        let iosVersion = UIDevice.current.systemVersion
        let deviceModel = UIDevice.current.model

        writeDebugLog("=== EeveeSpotify \(EeveeSpotify.version) (build \(EeveeSpotify.buildNumber)) starting ===")
        // ★ 2026-10-13：**默认值变更的补偿**（用户要求"Genius 功能默认改成开启"）。
        //   `lyricsOptions` 是**整块 JSON** 落盘的 ⇒ 只改 `defaultValue` 追不到已经写过的那份，
        //   所以这里一次性把盘上那份也打开（只做一次，之后尊重用户在设置里的开关）。
        LyricsOptions.applyGeniusFallbackDefaultIfNeeded()
        // ★ 2026-10-13（用户要求"**默认启用标签用液态玻璃**"）：同上，把
        //   `tabBarSystemGlass` 的默认值由关改成**开**；这个键只要被设置页拨过一次，
        //   盘上就是一个具体的 `false` ⇒ 也要补一刀（只做一次，之后尊重用户在设置里的开关）。
        //   ⚠️ 关掉它仍然是"完全不动"（内容与高度精确写回），见
        //   `UserDefaults.applyTabBarSystemGlassDefaultIfNeeded()` 的注释。
        UserDefaults.applyTabBarSystemGlassDefaultIfNeeded()
        // 这一行是"那一轮跑的是哪一档"的标记：玻璃没出现时，先看它是 ON 还是 OFF。
        writeDebugLog("[INIT] tab bar glass: \(UserDefaults.tabBarSystemGlass ? "ON" : "OFF")")
        writeDebugLog("[INIT] Spotify: \(spotifyVersion) (build \(spotifyBuild))")
        writeDebugLog("[INIT] iOS: \(iosVersion), Device: \(deviceModel)")
        writeDebugLog("[INIT] Hook target: \(EeveeSpotify.hookTarget)")
        writeDebugLog("[INIT] Patch type: \(UserDefaults.patchType)")
        writeDebugLog("[INIT] Lyrics source: \(UserDefaults.lyricsSource)")
        // 一个真开关（补卡片元素）+ 一个写死启用的修复（隐藏官方歌词）
        // + 禁用歌词功能 + Genius 回退开关，一次打出来：
        //   · 补卡片元素 —— 2026-09-26 起是读 UserDefaults 的真开关（默认 ON），
        //     这里记的是**实际生效值**；
        //   · 隐藏官方歌词 —— 2026-09-25 起写死在 `NgzhwmSettingsViewModel` 里；
        //   · 禁用歌词功能 —— 仍然是用户开关，值是它自己。
        //
        // ⚠️ 2026-09-27：`synthetic line timing` 一栏已删 —— 「补全歌词时间轴」那个开关
        // 连同它给真实歌词源合成时间轴的代码一起删了（只剩占位文案写死补，见
        // `makeUnavailableLyrics`）。所以这一栏不再有"两档"，A/B 分组看的是别的字段。
        //
        // 这行同时是排障时的"这一轮跑的是哪一档"标记（A/B 就靠它分组）。
        //
        // ⚠️ 「补卡片元素」必须打出来：排查"预热卡时有时无"时，日志里其余线索全是
        // 间接的（没注入 ≠ 开关关着 —— 也可能是服务端本来就带那个元素，或客户端走了
        // 缓存、我们连响应都没看到）。没有这一行，状态只能靠猜。
        //
        // ⚠️ 「Genius 回退」同样必须打出来 —— 它是**跨场次在变**的那个状态：
        // 2026-09-26 日志 4（10:47）开着，日志 5–14（12:15–23:35，含日志 11）整批关着，
        // 次日日志 15（09:51）又开着。日志 11 里 170 次请求、124 次网易云失败，一次
        // Genius 回退都没有 —— 当时只能靠"有没有 `falling back to Genius` 这一行"反推，
        // 没法区分"开关关着"和"回退跑了但 0 命中"。补上这一行之后每份日志自证状态。
        //
        // ⚠️ 打的是**用户设置里的原值**（不是"本次是否真的会回退"）：来源选 Genius 或
        // 多级回退时那个开关在设置页不显示、也不参与决策，这里照打原值，读日志时
        // 与同一行的 `Lyrics source:` 合起来看。
        writeDebugLog(
            "[INIT] card element inject: "
                + "\(NgzhwmSettingsViewModel.isLyricsCardElementInjectionEnabled ? "ON" : "OFF")"
                + " | official lyrics hidden: "
                + "\(NgzhwmSettingsViewModel.isOfficialLyricsHidden ? "ON" : "OFF")"
                + " | lyrics feature disabled: "
                + "\(NgzhwmSettingsViewModel.isLyricsFeatureDisabled ? "ON" : "OFF")"
                + " | genius fallback: "
                + "\(UserDefaults.lyricsOptions.geniusFallback ? "ON" : "OFF")"
                + " | AMLL preferred: "
                + "\(NgzhwmSettingsViewModel.isAmllPreferred ? "ON" : "OFF")"
        )
        writeDebugLog("[INIT] tweakInitTime: \(tweakInitTime)")

        // ★ 2026-10-13：**只读**探针 —— 封面图到底由哪个类/哪个选择器加载。
        //   用户问"歌单封面能不能只显示第一首的专辑封面"，而 `dump-9.1.88.txt` 的
        //   `[selectors]` 桶只给选择器名、不给所属类 ⇒ 只能上设备问一次（不 hook、不调用）。
        ImagePipelineProbe.probeOnce()

        // ★ 2026-10-13 夜：**只读**探针 —— 专辑页 / 歌单页**头部封面到底是哪一个视图**。
        //   日志 77 把两页的骨架摸清了（专辑页是 `CreativeWorkPlatform` 那一族，且它的 Header
        //   **跟着滚动淡入淡出**；歌单页是 `Components.Header.UI.ArtworkImage`），
        //   但**封面那一格没有 id、`ViewTreeDumper` 又在深度 24 截断** ⇒ 树里看不到它。
        //   这个探针只在两个头部里往下走走、把"像封面的"打出来（不 hook、不改任何东西，
        //   每种头部最多 3 次就自己停）。拿到那一行才做 hero，不猜。
        HeaderArtworkProbe.start()

        // ★ 2026-10-13（用户：「我就一个要求：看起来像 Apple Music」）：
        //   专辑页 / 歌单页的 **AM 化** —— ① 封面取色底（最底层渐变）② 封面下缘溶解。
        //   做法照 pw 的 `AlbumField`：铺在页面最底层，而且**必须先清掉 list / 每个 cell 画的
        //   `#121212` 底色**（不清就完全看不见那层 —— 那条坑的近亲是"整页变黑"）。
        //   两颗开关各自独立、默认都开；关掉即完全还原。机制与证据见
        //   `Appearance/EntityPageAppearance.x.swift` 文件头。日志 tag：`[PageField]`。
        EntityPageAppearance.start()

        // 隐私 / 触感 / Flag 覆盖都是"默认关、用户自己开"的，所以启动时把**实际生效值**
        // 打出来：排查时"没生效"和"没开"是两件完全不同的事，没有这一行只能靠猜。
        writeDebugLog(
            "[INIT] privacy: blockTelemetry="
                + "\(UserDefaults.blockTelemetry ? "ON" : "OFF")"
                + " observeOnly=\(UserDefaults.telemetryObserveOnly ? "ON" : "OFF")"
                + " extraKeywords="
                + "\(UserDefaults.telemetryExtraKeywords.isEmpty ? "(none)" : UserDefaults.telemetryExtraKeywords)"
                + " | haptics=\(UserDefaults.hapticsEnabled ? "ON" : "OFF")"
                + " strength=\(UserDefaults.hapticsStrength)"
                + " | flag overrides=\(FlagOverrideStore.count)"
        )

        // ★ 2026-10-02：把「覆盖配置」（补丁页那个开关）的状态也打出来。
        //
        // 排查"整库变黑 / 听不了歌"时，**H2（我们的 premium 伪装漏了一次）与
        // H1/H3（服务端按会话地区 / 账号风控）的区分全看它开没开**（见
        // `SESSION_2026-10-02_APPEARANCE.md` §12.2–12.3）：
        //   · 开着还是黑 → 大概率不是产品状态那一层（H1/H3）；
        //   · 关着 → 先怀疑 H2，把开关打开再试。
        // 日志 30 里一个字都没有，于是"开了覆盖配置也没用"这句话没法验证。
        writeDebugLog(
            "[INIT] patching: overwriteConfig="
                + "\(UserDefaults.overwriteConfiguration ? "ON" : "OFF")"
                + " (ON = the bundled Premium config snapshot fully replaces the one the server sends)"
        )

        // ★ 2026-10-12：**「不启用 Premium 补丁」那一档以前一行都没有** —— 于是用户那轮
        // A/B（"和不启用 Premium 补丁有关"）在日志里**无法复核**：翻遍 30 多份日志也查不到
        // 症状出现时 patchType 在哪一档。判读：
        //   · `requests` = 我们在改写账号态与 flag（**用户是免费号，这一档才是"能放"的那一档**）；
        //   · `disabled` = 服务端说什么就是什么 ⇒ 免费号在这一档**本来就该灰、该放不动**；
        //   · `notSet`   = 还没定过档（首次启动、或"清空设置"之后）。
        // `hasPatchedBootstrap` = 这次启动 bootstrap 那条路有没有真的改写成功。
        writeDebugLog(
            "[INIT] patching: patchType=\(UserDefaults.patchType)"
                + " (requests = we rewrite the account state and the flags | disabled = we leave it alone,"
                + " which for a free account means grey lists by design)"
                + " | hasPatchedBootstrap=\(UserDefaults.hasPatchedBootstrap ? "ON" : "OFF")"
        )

        // CarPlay crash fix (Issue #16) — safe-gated
        activateCarPlayCrashFix()

        // （已移除：Reincarnated 自带的开屏捐赠彩蛋 Donation.activate()
        //   —— "Hysan's Elsa Recovery Fund"，第 5/10 次启动弹 toast）

        // Verify critical hook targets exist
        let hookTargets: [(String, String)] = [
            ("SPTAuthSessionImplementation", "SPTAuthSession"),
            ("_TtC24Connectivity_SessionImpl18SessionServiceImpl", "SessionServiceImpl"),
            ("SPTAuthLegacyLoginControllerImplementation", "LegacyLoginController"),
            ("_TtC24Connectivity_SessionImplP33_831B98CC28223E431E21CD27ADD20AF222OauthAccessTokenBridge", "OauthAccessTokenBridge"),
            ("ARTWebSocketTransport", "AblyWebSocket"),
            ("ARTSRWebSocket", "AblySRWebSocket"),
        ]
        var allFound = true
        for (className, label) in hookTargets {
            if NSClassFromString(className) != nil {
                writeDebugLog("[INIT] \(label) class found")
            } else {
                writeDebugLog("[INIT] MISSING class for \(label): \(className)")
                allFound = false
            }
        }
        if allFound {
            writeDebugLog("[INIT] All \(hookTargets.count) hook targets verified")
        }

        // `SPTPlayerTrackHook`（见 `CustomLyrics+AllTracksLyrics.x.swift`）在 9.1.x 上挂的是
        // `SPTPlayerTrack`，并在它的 `metadata()` 里写 `has_lyrics = "true"`。
        //
        // 这条覆写若没绑上，客户端就只能听 Spotify 服务端的判定 —— 结果是"Spotify 没词的歌"
        // 连**面 B**（与「关于艺人」并列的「歌词」预览卡片）都不建，而**面 A**（封面与歌名
        // 之间的单行歌词）却能正常显示我们注入的歌词（实测：纯音乐 / 未找到歌词都会出现）。
        //
        // 上面那个 6 项的 hookTargets 列表里没有它，所以它历史上从未被验证过。这里补一条，
        // **纯日志、不改行为**：metadata=false 就说明覆写必然无效，不用再去猜。
        if let trackCls = NSClassFromString("SPTPlayerTrack") {
            let hasMetadata = class_getInstanceMethod(trackCls, Selector(("metadata"))) != nil
            let hasURI = class_getInstanceMethod(trackCls, Selector(("URI"))) != nil
            writeDebugLog("[INIT] SPTPlayerTrack: metadata=\(hasMetadata) URI=\(hasURI)")
        } else {
            writeDebugLog("[INIT] MISSING SPTPlayerTrack — the has_lyrics override cannot possibly work")
        }

        // For 9.1.x, activate premium patching and lyrics
        if EeveeSpotify.hookTarget == .v91 {

            // Premium patching (9.1.x)
            // Always activate the *bootstrap interceptor*; it is required for premium patching.
            if UserDefaults.patchType.isPatching {
                PremiumBootstrapGroup().activate()
                writeDebugLog("[INIT] Activated PremiumBootstrapGroup")

                // Optional UI hooks (safe-gated)
                if let hub = NSClassFromString("HUBViewModelBuilderImplementation"),
                   class_getInstanceMethod(hub, Selector(("addJSONDictionary:"))) != nil {
                    PremiumUIHooksGroup().activate()
                } else {
                    writeDebugLog("[INIT] Skipped PremiumUIHooksGroup (missing HUBViewModelBuilderImplementation/addJSONDictionary:)")
                }

                activateV91ServerSidedReminderIfAvailable()
            }

            let lyricsEnabled = UserDefaults.lyricsSource.isReplacingLyrics

            // Lyrics hooks (guarded)
            if lyricsEnabled {
                let fullscreenOK: Bool = {
                    // For 9.1.x, targetName resolves to Lyrics_FullscreenElementPageImpl.FullscreenElementViewController
                    if let cls = NSClassFromString("Lyrics_FullscreenElementPageImpl.FullscreenElementViewController") {
                        return class_getInstanceMethod(cls, #selector(UIViewController.viewDidLoad)) != nil
                    }
                    return false
                }()

                let npvOK: Bool = {
                    if let cls = NSClassFromString("NowPlaying_ScrollImpl.NPVScrollViewController") {
                        return class_getInstanceMethod(cls, #selector(UIViewController.viewWillAppear(_:))) != nil
                            && class_getInstanceMethod(cls, #selector(UIViewController.viewWillDisappear(_:))) != nil
                    }
                    return false
                }()

                // ng 的歌词分组：Base（全屏宿主 / 表格修复）+ Modern（NPV 宿主 + 全屏逐词）。
                // 指向 9.1.74 已消失类的 hook 由 handleError 非致命跳过。
                if fullscreenOK || npvOK {
                    BaseLyricsGroup().activate()
                    ModernLyricsGroup().activate()
                    writeDebugLog("[INIT] Activated ng lyrics groups (Base+Modern)")
                } else {
                    writeDebugLog("[INIT] Skipped ng lyrics groups (no lyrics host on this build)")
                }
            }

            // Settings 入口：9.1.44+ 唯一那条路（见下面）。
            // ⚠️ 2026-10-02：原来这里还有一段"老设置页"（`ProfileSettingsSection` +
            // `SettingsViewController` + `RootSettingsViewController` + 按标题猜设置的兜底）
            // —— 入口类只在 Spotify 9.1.0 上存在（扫过 9.1.0/9.1.74/9.1.76/9.1.86 四个包），
            // 在本仓库唯一的目标版本 9.1.86 上永远走 `else` 打一行 Skipped。**已按死代码删除。**

            // 9.1.44 path — ProfileSettingsSection gone, new SettingsListViewController owns Settings root.
            if NSClassFromString("_TtC21Settings_PlatformImpl26SettingsListViewController") != nil {
                UniversalSettingsIntegrationListVCGroup().activate()
                writeDebugLog("[INIT] Activated SettingsListViewController hook (9.1.44 path)")
            } else {
                writeDebugLog("[INIT] Settings_PlatformImpl.SettingsListViewController missing")
            }
            NSLog("[EeveeSpotify] Initialization complete for 9.1.x")
            TrueShuffleHook.install()
            activateSponsorBlock()
            return
        }

        // For other versions, activate all features normally
        // （Instagram 分享位那个实验已于 2026-10-02 删除：目标类 `SPTSharingSDK` /
        //   `SPTShare_FoundationImplProperties` 只在 Spotify 9.1.0 上存在。）
        
        if UserDefaults.darkPopUps {
            DarkPopUps().activate()
        }
        
        if UserDefaults.patchType.isPatching {
            activatePremiumPatchingGroup()
        }
        
        if UserDefaults.lyricsSource.isReplacingLyrics {
            BaseLyricsGroup().activate()
            
            if EeveeSpotify.hookTarget == .latest {
                ModernLyricsGroup().activate()
            }
            else {
                LegacyLyricsGroup().activate()
            }
        }
        
        // Settings 入口：只留 9.1.44+ 那条（`SettingsListViewController`）。
        // 老的 ProfileSettingsSection / SettingsViewController / RootSettingsViewController /
        // "按标题猜设置"的那条兜底 hook 已于 2026-10-02 删除（只服务 9.1.86 之前的版本）。
        if NSClassFromString("_TtC21Settings_PlatformImpl26SettingsListViewController") != nil {
            UniversalSettingsIntegrationListVCGroup().activate()
        }

        // These were previously only activated in the 9.1.x branch above
        // (before its early `return`) — meaning karaoke, SponsorBlock, and
        // the debug probes never ran at all on the current/latest Spotify
        // version, only on 9.1.x installs. Each of these functions already
        // self-guards internally on its own enabled/feature flags (see
        // activateSponsorBlock's `opts.enabled` check, for example), so
        // it's safe to call them unconditionally here too.
        activateSponsorBlock()
    }
}
