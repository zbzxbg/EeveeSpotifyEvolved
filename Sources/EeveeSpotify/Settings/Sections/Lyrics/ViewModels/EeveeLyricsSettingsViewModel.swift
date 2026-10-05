import SwiftUI
import Combine

class EeveeLyricsSettingsViewModel: ObservableObject {
    @Published var lyricsSource = UserDefaults.lyricsSource
    
    @Published var lyricsOptions = UserDefaults.lyricsOptions {
        didSet { UserDefaults.lyricsOptions = lyricsOptions }
    }
    
    @Published var chineseRomanization = UserDefaults.standard.bool(forKey: "ngzhwm_chineseRomanization") {
        didSet { UserDefaults.standard.set(chineseRomanization, forKey: "ngzhwm_chineseRomanization") }
    }
    @Published var japaneseRomanization = UserDefaults.standard.bool(forKey: "ngzhwm_japaneseRomanization") {
        didSet { UserDefaults.standard.set(japaneseRomanization, forKey: "ngzhwm_japaneseRomanization") }
    }
    @Published var koreanRomanization = UserDefaults.standard.bool(forKey: "ngzhwm_koreanRomanization") {
        didSet { UserDefaults.standard.set(koreanRomanization, forKey: "ngzhwm_koreanRomanization") }
    }
    
    @Published var wordByWordLyrics = NgzhwmSettingsViewModel.isWordByWordLyricsEnabled {
        didSet {
            UserDefaults.standard.set(
                wordByWordLyrics,
                forKey: NgzhwmSettingsViewModel.wordByWordLyricsKey
            )
        }
    }
    
    @Published var betterWordByWordLyrics = NgzhwmSettingsViewModel.isBetterWordByWordLyricsEnabled {
        didSet {
            UserDefaults.standard.set(
                betterWordByWordLyrics,
                forKey: NgzhwmSettingsViewModel.betterWordByWordLyricsKey
            )
        }
    }
    
    /// 「AMLL 优先」开关。★ 2026-10-02 恢复（2026-09-25 删过一次）。
    @Published var amllPreferred = NgzhwmSettingsViewModel.isAmllPreferred {
        didSet {
            UserDefaults.standard.set(
                amllPreferred,
                forKey: NgzhwmSettingsViewModel.amllPreferredKey
            )
        }
    }

    // 已**搬走**两个开关（2026-09-27）：`injectLyricsCardElement` / `lyricsEntryPointFlag`
    // —— 它们是排查/验证型开关，属性与绑定整体挪到 `EeveeDebugSettingsViewModel`（「调试」页）。
    // UserDefaults key 一字未改，设备上已设的值照旧生效；`[Settings] ... -> ON/OFF`
    // 那两行日志也随绑定一起搬过去了。
    // 同批**删除**（2026-09-27）：`syntheticLineTiming` ——「补全歌词时间轴」验证完毕
    // （关掉后观感差不多或略好，且给纯文本源伪造时间轴不合语义），开关、key、l10n
    // 与那段合成代码一起去掉；只剩占位文案写死补时间轴。

    // 已移除一个开关（2026-09-25）：`hideOfficialLyrics` —— 它对应的行为已经在
    // `NgzhwmSettingsViewModel` 里**写死启用**（见那个 getter 的说明），
    // 设置页不再暴露、也不再写 UserDefaults。
    
    // 注：背景相关（模糊封面 / 系统材质）**没有** Published 属性 ——
    // 它们不是用户可选项，而是跟随「更好的逐词歌词」自动启用。
    // 见 NgzhwmSettingsViewModel.isLyricsBlurredBackdropEnabled。
    
    @Published var disableLyricsFeature = UserDefaults.standard.bool(
        forKey: NgzhwmSettingsViewModel.disableLyricsFeatureKey
    ) {
        didSet {
            UserDefaults.standard.set(
                disableLyricsFeature,
                forKey: NgzhwmSettingsViewModel.disableLyricsFeatureKey
            )
        }
    }
    
    @Published var removeMxmInterludeSymbol = UserDefaults.standard.bool(
        forKey: NgzhwmSettingsViewModel.removeMxmInterludeSymbolKey
    ) {
        didSet {
            UserDefaults.standard.set(
                removeMxmInterludeSymbol,
                forKey: NgzhwmSettingsViewModel.removeMxmInterludeSymbolKey
            )
        }
    }
    
    @Published var neteaseRomajiLocal = UserDefaults.standard.bool(
        forKey: NgzhwmSettingsViewModel.neteaseRomajiLocalKey
    ) {
        didSet {
            UserDefaults.standard.set(
                neteaseRomajiLocal,
                forKey: NgzhwmSettingsViewModel.neteaseRomajiLocalKey
            )
        }
    }
    
    @Published var neteaseHideTranslation = NgzhwmSettingsViewModel.isNeteaseHideTranslationEnabled {
        didSet {
            UserDefaults.standard.set(
                neteaseHideTranslation,
                forKey: NgzhwmSettingsViewModel.neteaseHideTranslationKey
            )
        }
    }
    
    /// Musixmatch 用户令牌（54 位 hex）。
    ///
    /// 两条路：
    ///   · **手填** —— 从 Musixmatch App 的「设置 → 获取帮助 → 复制调试信息」里抠出来；
    ///   · **匿名令牌** —— 设置页那颗按钮（`requestAnonymousMusixmatchToken()`），不授权直接换一个。
    ///
    /// ★ 2026-10-13：匿名那条路**整块接回来了**（提交 `271de5b` 删过它，删的理由见下面那段
    /// 历史注释）。它回来的原因很实在：本仓库不再内置 SpicyLyrics 的默认密钥，没填密钥时
    /// 这一首会自动改用 Musixmatch —— 那条回退要成立，mxm 就必须能自己拿到令牌。
    /// 取词路径里还有一处**自动**换令牌（`MusixmatchLyricsRepository.ensureTokenIfNeeded`），
    /// 用户没来过设置页也能用。
    ///
    /// 与旧版的差别（删掉的东西**没有**全部带回来）：
    ///   · `musixmatchTokenInputAlertPublisher` **不恢复** —— 它全工程没有任何地方 `send` 过
    ///     （`EeveeLyricsSettingsView` 的 `.onReceive` 收不到东西），是死订阅；
    ///   · `isRequestingMusixmatchToken` 恢复，但只用来给那颗按钮画转圈 + 禁用它自己，
    ///     **不再整页 `.disabled`**（旧版会让用户在转圈期间连来源都改不了）。
    @Published var musixmatchToken = UserDefaults.musixmatchToken
    var isMusixmatchTokenValid: Bool { getMusixmatchToken(musixmatchToken) != nil }

    /// 正在向 Musixmatch 换匿名令牌（设置页那颗按钮画转圈、并禁用它自己）。
    ///
    /// ★ 2026-10-13：随 `requestAnonymousMusixmatchToken()` 一起接回来（它当初被删的原因见
    /// `AnonymousTokenHelper` 文件头）。与旧版的差别：**只禁那颗按钮**，不再整页 `.disabled`
    /// —— 转圈期间用户仍然能改来源。
    @Published var isRequestingMusixmatchToken = false

    /// SpicyLyrics 官方 API 的**客户端密钥**（`sl_pk_…`）。
    ///
    /// ★ 2026-10-13（用户拍板）：**本仓库不内置默认密钥**，所以这一栏是"用 SpicyLyrics 的前提"。
    /// **留空时**这一首会自动改用 **Musixmatch**（见 `CustomLyrics.loadCustomLyricsForCurrentTrack`
    /// 里那一段替换）—— 不会去走 SpicyLyrics 那条被条款禁止的内部接口。
    ///
    /// 为什么要留这一栏（而不是像上游那样内置一个公开 key）：SL 条款 §3 明写 *"Do not share a key"*，
    /// 内置在公开仓库/分发的 IPA 里的 key 就是被所有人共用，被吊销时所有装机一起坏。
    @Published var spicyLyricsApiKey = UserDefaults.spicyLyricsApiKey {
        didSet { UserDefaults.spicyLyricsApiKey = spicyLyricsApiKey }
    }
    
    @Published var showMusixmatchInvalidLanguageWarning = false
    @Published var lrclibURLState = LrclibURLState.default
    
    var animationValues: [AnyHashable] {
        [
            lyricsSource,
            lyricsOptions,
            betterWordByWordLyrics,
            wordByWordLyrics,
            amllPreferred,
            // ⚠️ `hideOfficialLyrics`（已写死启用）、`syntheticLineTiming`（2026-09-27 已整体删除），
            // 以及搬去「调试」页的 `injectLyricsCardElement` / `lyricsEntryPointFlag`
            // 都**不能**再列在这里 —— 属性本身没了，列着就是编译错误。
            disableLyricsFeature,
            removeMxmInterludeSymbol,
            neteaseRomajiLocal,
            neteaseHideTranslation,
            isMusixmatchTokenValid,
            isRequestingMusixmatchToken,
            lrclibURLState,
            showMusixmatchInvalidLanguageWarning
        ]
    }
    
    var cancellables = Set<AnyCancellable>()

    init() {
        setupBindings()
    }
    
    /// 向 Musixmatch 换一个**匿名令牌**并填进上面那个输入框（设置页那颗按钮调它）。
    ///
    /// ★ 2026-10-13：与 `AnonymousTokenHelper` 一起接回来。三个要点：
    ///   · 换来的令牌存进**同一个字段**（`UserDefaults.musixmatchToken`），所以输入框会当场显示出来；
    ///   · 同时把 `musixmatchTokenIsAnonymous` 置位 —— 401 时才知道"该丢掉重换"还是
    ///     "该让用户自己去改"（见 `MusixmatchLyricsRepository.getMacroCalls` 的 401 分支）；
    ///   · 失败只弹一次"获取失败"，不改任何状态（用户仍可手填）。
    func requestAnonymousMusixmatchToken() {
        guard !isRequestingMusixmatchToken else { return }
        isRequestingMusixmatchToken = true
        writeDebugLog("[Musixmatch] anonymous token: requested from the settings page")

        AnonymousTokenHelper.requestAnonymousMusixmatchToken()
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { [weak self] completion in
                    self?.isRequestingMusixmatchToken = false
                    if case .failure(let error) = completion {
                        writeErrorLog("[Musixmatch] anonymous token failed from settings: \(error)")
                        PopUpHelper.showPopUp(
                            delayed: false,
                            message: "anonymous_token_request_failed".localized,
                            buttonText: "OK".uiKitLocalized
                        )
                    }
                },
                receiveValue: { [weak self] token in
                    guard let self = self else { return }
                    self.musixmatchToken = token
                    UserDefaults.musixmatchTokenIsAnonymous = true
                    writeDebugLog("[Musixmatch] anonymous token stored from settings (len=\(token.count))")
                }
            )
            .store(in: &cancellables)
    }

    func getMusixmatchTokenFromDebugInfo(_ debugInfo: String) -> String? {
        if let match = debugInfo.firstMatch("\\[UserToken\\]: ([a-f0-9]+)"),
            let tokenRange = Range(match.range(at: 1), in: debugInfo) {
            return String(debugInfo[tokenRange])
        }
        
        return nil
    }
    
    func getMusixmatchToken(_ input: String) -> String? {
        if input ~= "^[a-f0-9]{54}$" {
            return input
        }
        
        return nil
    }
}
