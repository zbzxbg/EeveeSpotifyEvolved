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
/// 现在只有两颗：一颗「更详细的日志记录」（视图树 + customize 响应体合并）与一颗
/// 「音频输出探针」（只读诊断：RemoteIO 的格式与 RMS，见 `AudioTapProbe`）。
///
/// ── 纪律
///
/// 这里的开关**要么在验证中、要么已判定该删**。验证完就"写死 + 删 key + 删 l10n"
/// （`hideOfficialLyrics`、`syntheticLineTiming` 都是这么处理的），页面上不该留长期住户。
/// 最终理想形态是这一页**空着**。
class EeveeDebugSettingsViewModel: ObservableObject {

    /// 「更详细的日志记录」：把**视图树**与**customize 响应体**两条转储合到一颗开关。
    ///
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
    /// 默认关；打开即装 hook（装的动作在 `AudioTapService` 的安装队列上跑，不会卡界面）。
    @Published var audioTapProbe = AudioTapProbe.isEnabled {
        didSet { AudioTapProbe.setEnabled(audioTapProbe) }
    }

    /// 见 `EeveeLyricsSettingsViewModel.animationValues` 的用法：把开关本身列进去，
    /// 值一变页面就会重绘（少了它会出现"改了开关但界面不刷新"）。
    var animationValues: [AnyHashable] {
        [
            detailedLogging,
            audioTapProbe,
        ]
    }

    var cancellables = Set<AnyCancellable>()

    init() {
        setupBindings()
    }

    /// 见 `logBooleanSetting` 的说明。两颗开关单独铺开写（而不是泛型循环），
    /// 让"到底记了哪些"在代码里一眼可数。
    private func setupBindings() {
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
