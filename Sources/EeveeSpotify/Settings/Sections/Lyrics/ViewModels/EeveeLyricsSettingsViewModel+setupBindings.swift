import SwiftUI
import Combine

extension EeveeLyricsSettingsViewModel {
    func setupBindings() {
        $lyricsOptions
            .map(\.musixmatchLanguage)
            .sink { [weak self] language in
                guard let self = self else { return }
                
                let isValidLanguage = language.isEmpty || language ~= "^[\\w\\d]{2}$"
                
                if isValidLanguage {
                    self.showMusixmatchInvalidLanguageWarning = false
                    MusixmatchLyricsRepository.shared.selectedLanguage = language
                    return
                }
                
                self.showMusixmatchInvalidLanguageWarning = true
            }
            .store(in: &cancellables)
        
        $lyricsOptions
            .map(\.lrclibUrl)
            .map { urlString -> AnyPublisher<LrclibURLState, Never> in
                guard let url = URL(string: urlString) else {
                    return Just(.invalidURL).eraseToAnyPublisher()
                }
                
                if url.host == "lrclib.net" {
                    return Just(.originalURL).eraseToAnyPublisher()
                }
                
                return URLSession.shared.dataTaskPublisher(for: url)
                    .map { _ in
                        LrclibLyricsRepository.shared.apiUrl = urlString
                        return LrclibURLState.ok
                    }
                    .catch { _ in Just(LrclibURLState.unreachableURL) }
                    .eraseToAnyPublisher()
            }
            .switchToLatest()
            .receive(on: DispatchQueue.main)
            .assign(to: &$lrclibURLState)
        
        $musixmatchToken
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tokenString in
                guard let self = self else { return }
                
                if let token = self.getMusixmatchTokenFromDebugInfo(tokenString) {
                    self.musixmatchToken = token
                    return
                }
                
                if let token = self.getMusixmatchToken(tokenString) {
                    UserDefaults.musixmatchToken = token
                    writeDebugLog("[Musixmatch] token saved (length \(token.count))")
                } else if !tokenString.isEmpty {
                    // 以前这里是静默失败：输入框显示你粘的内容，UserDefaults 里却仍是旧值（可能是空的），
                    // 于是请求带着空 usertoken 出去，在 Musixmatch 边缘就被拒。
                    writeDebugLog(
                        "[Musixmatch] token rejected - needs 54 lowercase hex characters, got \(tokenString.count)"
                    )
                }
            }
            .store(in: &cancellables)
        
        $lyricsSource
            .dropFirst()
            .sink { [weak self] newSource in
                guard let self = self else { return }
                
                if newSource == .lrclib {
                    self.lyricsOptions.lrclibUrl = LrclibLyricsRepository.originalApiUrl
                }
                
                // 判据是「签名变没变」，不是「sink 来没来」：`@Published` 不判等，
                // 重新选中同一项也会走一趟这里，而那份备忘仍然是可用的
                // （签名里就带来源，见 `LyricsResponseCache.currentSignature`）。
                let previousSignature = LyricsResponseCache.currentSignature

                UserDefaults.lyricsSource = newSource

                // 换来源＝换 payload：把「刚产出过的那份」作废。
                //
                // 签名一变备忘本来也命中不了，这里清掉是为了别让「这一首第几次请求」的
                // 计数把下一次请求算成"后续请求"。顺带留下一条判读用的时间线：下一次
                // `color-lyrics` 请求到达时会多一行日志；没有那一行就说明这一首没有再被
                // 请求过，只有重启才会重取。
                if LyricsResponseCache.currentSignature != previousSignature {
                    LyricsResponseCache.shared.noteSettingsChanged()
                    // 把**当前这一首**的歌词响应从 URL 缓存里删掉：下一次请求就会回源，
                    // 钩子重新取词、交给播放器新来源的词（命中与否都会打一行，见
                    // `LyricsURLCachePurge`）。缓存里没有它也照样清 —— 那一层若在客户端
                    // 自己的模型里，只有重启能换过来。
                    LyricsURLCachePurge.purgeLastRequest(reason: "lyrics source changed")
                }
            }
            .store(in: &cancellables)

        // ── 设置项变更日志
        //
        // ⚠️ 起因：改任何开关过去只有**副作用**日志（比如"hide translation enabled"
        // 会出现在取词流程里），没有"用户在什么时候把哪个开关改成了什么"的时间线。
        // 排查"这个行为差异是不是设置造成的"时，只能靠猜当时是什么配置。
        //
        // 全部走 `.dropFirst`：订阅时会先收到一次当前值，那是页面打开、不是用户改动，
        // 记下来会污染时间线。之后每次真实改动记一行。
        //
        // 写入量：只在用户真的拨开关时触发，不在任何每帧路径上。所以不用节流。
        logSettingChanges()
    }

    /// 订阅一批 `@Published` 设置项，值一变就记一行 `[Settings] 名称 -> ON/OFF`。
    ///
    /// ⚠️ 这里**只能记新值，不能记"原值"**：这些属性是 `didSet` 里写 UserDefaults，
    /// 而 `@Published` 的 `willSet` 就已经把 `self.xxx` 更新了 —— 所以 sink 里
    /// 再读 `self.xxx` 拿到的是**新值**，写"原值"会是假的。宁可不记。
    private func logBooleanSetting(_ publisher: Published<Bool>.Publisher, _ name: String) {
        publisher
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { newValue in
                writeDebugLog("[Settings] \(name) -> \(newValue ? "ON" : "OFF")")
            }
            .store(in: &cancellables)
    }

    /// 见 `logBooleanSetting` 的说明。这里单独铺开每个开关而不是泛型循环，
    /// 是为了让"到底记了哪些开关"在代码里一眼可数 —— 少记一个不容易被发现。
    private func logSettingChanges() {
        logBooleanSetting($wordByWordLyrics, "word-by-word lyrics")
        logBooleanSetting($betterWordByWordLyrics, "better word-by-word lyrics")
        logBooleanSetting($amllPreferred, "AMLL preferred")
        // 「隐藏官方歌词」已写死启用（见 NgzhwmSettingsViewModel），设置页不再有开关，
        // 因此这里也没有可记录的绑定。
        // 已搬走：`$injectLyricsCardElement` / `$lyricsEntryPointFlag`
        // 那两行 `[Settings] … -> ON/OFF`
        // 分组标记跟着绑定一起搬到了 `EeveeDebugSettingsViewModel.setupBindings`，
        // 所以日志格式不变、只是由那个页面负责记录。
        // 已删除：`$syntheticLineTiming`——「补全歌词时间轴」连同它的代码
        // 一起删了（见 `EeveeDebugSettingsViewModel` 顶部说明），不再有任何绑定。
        logBooleanSetting($disableLyricsFeature, "disable lyrics feature")
        // 已删除：`$removeMxmInterludeSymbol` ——「删除间奏符号 ♪」连同它的
        // 键与 UI 行一起摘掉了（间奏行无条件丢弃），没有可记录的绑定。
        logBooleanSetting($neteaseRomajiLocal, "NetEase romaji display mode")
        logBooleanSetting($hideLyricsTranslation, "hide lyrics translation")
        logBooleanSetting($lyricsAutoTranslate, "auto-translate lyrics (system)")
        logBooleanSetting($chineseRomanization, "Chinese romanization")
        logBooleanSetting($japaneseRomanization, "Japanese romanization")
        logBooleanSetting($koreanRomanization, "Korean romanization")

        // 来源选择器：不是 Bool，单独一条。
        // ⚠️ 值用 `UserDefaults.lyricsSource`（持久化的那份），不是 `self.lyricsSource` ——
        // 后者在 sink 里读会踩"闭包捕获可变 self"，而且如上所述已经是新值了。
        $lyricsSource
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { _ in
                writeDebugLog("[Settings] lyrics source -> \(UserDefaults.lyricsSource.description)")
            }
            .store(in: &cancellables)
    }
}
