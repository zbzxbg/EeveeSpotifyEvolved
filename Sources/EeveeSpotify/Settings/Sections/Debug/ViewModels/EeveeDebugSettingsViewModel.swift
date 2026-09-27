import SwiftUI
import Combine

/// 「调试」页的 ViewModel。
///
/// ── 这个页面只装什么 ───────────────────────────────────────────────────────
///
/// **排查/验证型开关**，也就是"验证完就该写死或删掉"的那一类。它们过去散在
/// 「歌词」页里，和用户真正的偏好（罗马字、逐词歌词、NetEase 显示方式…）混在一起，
/// 后果是：用户面对一堆"不该动"的东西，而"哪些是待清理的临时件"完全不可见。
///
/// 目前有两个（全部沿用**原 key**，只是换了容器 ⇒ 设备上已设的值不会丢）：
///
///   · 「给没有歌词卡片的歌曲补一张」`ngzhwm_injectLyricsCardElement`
///   · 「强制歌词入口开关」`ngzhwm_lyricsEntryPointFlag`
///
/// 已清理掉一个（2026-09-27）：「补全歌词时间轴」`ngzhwm_syntheticLineTiming` ——
/// 真机 A/B 结论是"关掉之后差不多或略好"，而给纯文本源伪造时间轴本身不合语义，
/// 于是开关、l10n 与那段合成代码一起删了（`LyricsDto.toSpotifyLyricsData`）。
/// 最终理想形态是这一页**空着**。
///
/// 另有一个还没定性的候选：`ngzhwm_disableNpvPrereleaseProvider`（假预热卡的止血开关）
/// —— 它对应的代码这一轮已整体回退，所以**暂时不放进页面**，等重启那条线时再加。
///
/// ── 纪律 ───────────────────────────────────────────────────────────────────
///
/// 这里的开关**要么在验证中、要么已判定该删**。验证完就"写死 + 删 key + 删 l10n"
/// （`hideOfficialLyrics`、`syntheticLineTiming` 都是这么处理的），页面上不该留长期住户。
class EeveeDebugSettingsViewModel: ObservableObject {

    /// 「给没有歌词卡片的曲目补一个卡片元素」。初值必须走 getter（默认开）。
    @Published var injectLyricsCardElement = NgzhwmSettingsViewModel.isLyricsCardElementInjectionEnabled {
        didSet {
            UserDefaults.standard.set(
                injectLyricsCardElement,
                forKey: NgzhwmSettingsViewModel.injectLyricsCardElementKey
            )
        }
    }

    /// 「把服务端那条 `lyrics_entry_point_enabled` 钉成 true」。同上：默认开。
    ///
    /// 这一条**还没有结论**：那次 A/B 是空跑（customize 走 304 无 body，flag 替换
    /// 那段代码整段没执行）。所以它现在是"待验证"，不是"待删除"。
    @Published var lyricsEntryPointFlag = NgzhwmSettingsViewModel.isLyricsEntryPointFlagForced {
        didSet {
            UserDefaults.standard.set(
                lyricsEntryPointFlag,
                forKey: NgzhwmSettingsViewModel.lyricsEntryPointFlagKey
            )
        }
    }

    /// 见 `EeveeLyricsSettingsViewModel.animationValues` 的用法：把开关本身列进去，
    /// 值一变页面就会重绘（少了它会出现"改了开关但界面不刷新"）。
    var animationValues: [AnyHashable] {
        [
            injectLyricsCardElement,
            lyricsEntryPointFlag,
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
