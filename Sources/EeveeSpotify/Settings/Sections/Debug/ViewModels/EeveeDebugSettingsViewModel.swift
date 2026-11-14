import SwiftUI
import Combine

/// 「调试」页的 ViewModel。
///
/// ── 这个页面只装什么
///
/// **排查/验证型开关**，也就是"验证完就该写死或删掉"的那一类。它们过去散在「歌词」页里，
/// 和用户真正的偏好（罗马字、逐词歌词、NetEase 显示方式…）混在一起，后果是：用户面对一堆
/// "不该动"的东西，而"哪些是待清理的临时件"完全不可见。
///
/// 目前有两颗 A/B 开关（全部沿用**原 key**，只是换了容器 ⇒ 设备上已设的值不会丢）：
///
/// · 「给没有歌词卡片的歌曲补一张」`ngzhwm_injectLyricsCardElement`
/// · 「歌词入口开关」`ngzhwm_lyricsEntryPointFlag`
///
/// 外加一颗「更详细的日志记录」（视图树 + customize 响应体合并）和一颗「音频输出探针」
/// （只读诊断：RemoteIO 的格式与 RMS，见 `AudioTapProbe`）。
///
/// 另有一个还没定性的候选：`ngzhwm_disableNpvPrereleaseProvider`（假预热卡的止血开关）——
/// 它对应的代码这一轮已整体回退，所以**暂时不放进页面**，等重启那条线时再加。
///
/// ── 纪律
///
/// 这里的开关**要么在验证中、要么已判定该删**。验证完就"写死 + 删 key + 删 l10n"
/// （`hideOfficialLyrics`、`syntheticLineTiming` 都是这么处理的），页面上不该留长期住户。
/// 最终理想形态是这一页**空着**。
class EeveeDebugSettingsViewModel: ObservableObject {

    /// 「补充模块5」（往元素列表里补 `5` = 保留官方布局时那个歌词预览模块）。初值必须走 getter（默认开）。
    @Published var injectLyricsCardElement = NgzhwmSettingsViewModel.isLyricsCardElementInjectionEnabled {
        didSet {
            UserDefaults.standard.set(
                injectLyricsCardElement,
                forKey: NgzhwmSettingsViewModel.injectLyricsCardElementKey
            )
        }
    }

    /// 「把服务端那条 `lyrics_entry_point_enabled` 钉成 true」。默认开。
    ///
    /// **它不是"待验证的 A/B 开关"，而是"没歌词"事故的保险丝。**
    ///
    /// 症状：退出重进 Spotify 后大概率突然无法播放任何歌词，开覆盖配置也只能好一小会。
    /// 根因是这条替换用的是 `.setBool`（**只钉已下发的值、绝不新增**）—— 只要某一份
    /// customize payload 没带这条 flag，这一枪就**静默**落空，而服务端那份的取值是 false
    /// ⇒ 歌词入口整个消失。升级成 `.forceBool(true)`（命中就钉住、没下发就**补一条**）之后
    /// 问题消失。
    ///
    /// 所以**关掉这颗开关 = 回退到那次"没歌词"的形状**：
    /// · 门禁在 `DynamicPremium+ModifyingFunctions.swift:746-751`（整条跳过）；
    /// · 日志会打 `[Flags] lyrics_entry_point_enabled — SKIPPED (switch off, A/B)`
    ///   —— 那句里的 `A/B` 是历史措辞，现在读作"你主动关掉了保险丝"。
    ///
    /// ⇒ 结论：**留着**，别把它当"实验"关掉；真要让它回到"实验"语义，得先确认服务端
    /// 现在每份 payload 都带这条 flag。
    @Published var lyricsEntryPointFlag = NgzhwmSettingsViewModel.isLyricsEntryPointFlagForced {
        didSet {
            UserDefaults.standard.set(
                lyricsEntryPointFlag,
                forKey: NgzhwmSettingsViewModel.lyricsEntryPointFlagKey
            )
        }
    }

    /// 「更详细的日志记录」：把**视图树**与**customize 响应体**两条转储合到一颗开关。
    ///
    /// 「转储视图树，转储响应体两个融合，换成 更详细的日志记录」。
    /// 底下仍写回原来的 `dumpViewTree` / `dumpCustomizeBody` 两个键
    /// （`ViewTreeDumper` / `SpotifyResponsePatcher` 读的还是它们，备份与已设值不受影响），
    /// 新键 `detailedLogging` 只负责这颗总开关的状态与迁移。
    ///
    /// 与其它开关不同，这个**打开即生效**：`didSet` 直接调 `ViewTreeDumper.applyEnabledState`，
    /// 不必重启 Spotify（定时器是运行期起的，不是启动期装的 hook）。
    @Published var detailedLogging = UserDefaults.detailedLogging {
        didSet {
            UserDefaults.detailedLogging = detailedLogging
            ViewTreeDumper.applyEnabledState()
        }
    }

    /// 「音频输出探针」：只读诊断，确认能不能从 RemoteIO 的 PostRender 拿到 PCM。
    /// 默认关；打开即装 hook（装的动作在 `AudioTapProbe.installQueue` 上跑，不会卡界面）。
    @Published var audioTapProbe = AudioTapProbe.isEnabled {
        didSet { AudioTapProbe.setEnabled(audioTapProbe) }
    }

    /// 见 `EeveeLyricsSettingsViewModel.animationValues` 的用法：把开关本身列进去，
    /// 值一变页面就会重绘（少了它会出现"改了开关但界面不刷新"）。
    var animationValues: [AnyHashable] {
        [
            injectLyricsCardElement,
            lyricsEntryPointFlag,
            detailedLogging,
            audioTapProbe,
        ]
    }

    var cancellables = Set<AnyCancellable>()

    init() {
        setupBindings()
    }

    /// 见 `logBooleanSetting` 的说明。两个开关单独铺开写（而不是泛型循环），
    /// 让"到底记了哪些"在代码里一眼可数。
    private func setupBindings() {
        logBooleanSetting($injectLyricsCardElement, "inject lyrics card element")
        logBooleanSetting($lyricsEntryPointFlag, "lyrics entry point flag")
        logBooleanSetting($detailedLogging, "detailed logging")
        logBooleanSetting($audioTapProbe, "audio output probe")
    }

    /// 照抄 `EeveeLyricsSettingsViewModel+setupBindings` 的实现与理由：
    /// `@Published` 的 `willSet` 已经更新了 `self.xxx`，sink 里只能记新值，不能记"原值"。
    private func logBooleanSetting(_ publisher: Published<Bool>.Publisher, _ name: String) {
        publisher
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { newValue in
                writeDebugLog("[Settings] \(name) -> \(newValue ? "ON" : "OFF")")
            }
            .store(in: &cancellables)
    }
}
