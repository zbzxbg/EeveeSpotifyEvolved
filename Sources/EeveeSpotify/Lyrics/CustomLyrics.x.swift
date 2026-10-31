// 自定义歌词：从各仓库取词，转成 Spotify 的 `Lyrics` payload 注入 `color-lyrics/v2` 响应，
// 并同步全局状态供两个自绘 overlay 使用。
//
// 三条关键约定：失败也要交出一份可解析的占位（否则 Spotify 不建歌词卡片，连全屏入口都没有）；
// 署名一律写**实际给词的那个源**（`lastRequestedLyricsSourceDescription`）；
// 时间轴偏移在这里加**一次**，注入 payload 与 overlay 必须读同一份平移过的数据。
import Orion
import SwiftUI

struct BaseLyricsGroup: HookGroup { }
struct LegacyLyricsGroup: HookGroup { }
struct ModernLyricsGroup: HookGroup { }

var lyricsState = LyricsLoadingState()
var hasShownRestrictedPopUp = false
var hasShownUnauthorizedPopUp = false
/// 「SpicyLyrics 的 key 被拒」弹窗只弹一次。见 `handleLyricsErrorPopUp`。
var hasShownSpicyKeyPopUp = false
/// 「Apple Music 官方 TTML 缺令牌 / 令牌失效」弹窗只弹一次。见 `handleLyricsErrorPopUp`。
var hasShownAppleMusicTokenPopUp = false

private let geniusLyricsRepository = GeniusLyricsRepository()
private let petitLyricsRepository = PetitLyricsRepository()
private let amllTtmlLyricsRepository = AmllTtmlLyricsRepository.shared
private let appleMusicTtmlLyricsRepository = AppleMusicOfficialTtmlLyricsRepository.shared

/// 「这一次我们向哪个源要的歌词」——**失败**时占位 payload 的署名要用它。
///
/// 占位 payload（"未找到歌词"）若把 `providedBy` 写死成 `"EeveeSpotify"`，Spotify 原生
/// 歌词页底部那行就成了 `歌词提供者：EeveeSpotify` —— "是哪个源没找到"这条信息丢了。
/// 正常路径（`LyricsDto.toSpotifyLyricsData(source:)`）写的是**源名**，两处都不带
/// `(EeveeSpotify)` 后缀。
///
/// 放在文件作用域而不是 `CustomLyrics` 里：`unavailableLyricsBytes` 是文件作用域函数
/// （URLSession 钩子的兜底路径），它也要读同一个值。
///
/// ⚠️ 只在 `requestSingleSource` 入口写一次 —— 那正是"我们向某个源发出请求"的时刻，
/// 与失败发生在哪个源**必然**同源。写在成功路径会漏掉"源直接抛错"这一路。
private var lastRequestedLyricsSourceDescription: String = ""

// 已移除：`forcedGoodLines` / `forcedGoodDto`（配合 `forcedLyricsPayload` 排障开关）。
//
// 保留结论、不留代码：**卡片（与「关于艺人」并列那块）是被我们注入的 payload 驱动的** ——
// 卡片底部显示的 provider 就是我们自己写死的名字。且 `timeSynchronized = false` 会建卡片，
// `true` 则 Spotify 走单行表现而不建卡片。加入它之后出现稳定复现的启动崩溃，故整体回退；
// 详见 `UserDefaults+Extension.swift` 末尾的说明。

private func lyricsRepository(for source: LyricsSource) -> LyricsRepository {
    switch source {
    case .genius: return geniusLyricsRepository
    case .lrclib: return LrclibLyricsRepository.shared
    case .musixmatch: return MusixmatchLyricsRepository.shared
    case .petit: return petitLyricsRepository
    case .spicy: return SpicyLyricsRepository.shared
    case .netease:
        return NeteaseLyricsRepository.shared
    case .amllTtml:
        return amllTtmlLyricsRepository
    case .bini:
        return BiniLyricsRepository.shared
    case .unison:
        return UnisonLyricsRepository.shared
    case .qqMusic:
        return QQMusicLyricsRepository.shared
    case .kugou:
        return KuGouLyricsRepository.shared
    case .appleMusicOfficialTtml:
        return appleMusicTtmlLyricsRepository
    case .notReplaced, .autoSelect:
        // Never actually reached — callers filter these out beforehand.
        return geniusLyricsRepository
    }
}

// 两种回退模式共用：处理 Musixmatch 相关错误弹窗
//
// ⚠️ 每条分支的**两个方向都要记日志**：因为这两个弹窗各只有一次机会
// （`hasShownXxxPopUp` 一旦置位就再也不会弹）。只记"弹了"区分不出
// "这次被抑制了"和"这次压根没走到这里"。
private func handleLyricsErrorPopUp(_ error: LyricsError?) {
    switch error {
    case .invalidMusixmatchToken:
        if !hasShownUnauthorizedPopUp {
            writeDebugLog("[Lyrics] popup: Musixmatch unauthorized (first time — showing)")
            PopUpHelper.showPopUp(
                delayed: false,
                message: "musixmatch_unauthorized_popup".localized,
                buttonText: "OK".uiKitLocalized
            )
            hasShownUnauthorizedPopUp = true
        } else {
            writeDebugLog("[Lyrics] popup: Musixmatch unauthorized (already shown once — suppressed)")
        }
    case .musixmatchRestricted:
        if !hasShownRestrictedPopUp {
            writeDebugLog("[Lyrics] popup: Musixmatch restricted (first time — showing)")
            PopUpHelper.showPopUp(
                delayed: false,
                message: "musixmatch_restricted_popup".localized,
                buttonText: "OK".uiKitLocalized
            )
            hasShownRestrictedPopUp = true
        } else {
            writeDebugLog("[Lyrics] popup: Musixmatch restricted (already shown once — suppressed)")
        }
    case .invalidSpicyKey:
        // key 被 SL 拒了（401 key_not_found / 403 origin_not_allowed）。这是"配置问题"，
        // 不是"这首歌没词" —— 必须让用户看见一次，否则他只会以为 SL 源没词可用。
        if !hasShownSpicyKeyPopUp {
            writeDebugLog("[Lyrics] popup: SpicyLyrics key rejected (first time — showing)")
            PopUpHelper.showPopUp(
                delayed: false,
                message: "spicylyrics_key_invalid_popup".localized,
                buttonText: "OK".uiKitLocalized
            )
            hasShownSpicyKeyPopUp = true
        } else {
            writeDebugLog("[Lyrics] popup: SpicyLyrics key rejected (already shown once — suppressed)")
        }
    case .missingAppleMusicToken, .invalidAppleMusicToken:
        // 「实验 → 启用Apple Music官方TTML歌词」要靠用户自己粘的 `media-user-token`。
        // 没填 / 过期都属于"配置问题"，与"这首歌没词"完全两回事 ——
        // 只弹一次，否则每切一首歌都弹一遍。
        if !hasShownAppleMusicTokenPopUp {
            writeDebugLog("[Lyrics] popup: Apple Music media-user-token missing/invalid (first time — showing)")
            PopUpHelper.showPopUp(
                delayed: false,
                message: "apple_music_token_popup".localized,
                buttonText: "OK".uiKitLocalized
            )
            hasShownAppleMusicTokenPopUp = true
        } else {
            writeDebugLog("[Lyrics] popup: Apple Music token problem (already shown once — suppressed)")
        }
    default:
        break
    }
}

/// 从曲目元数据里把**全部**艺人名抠出来（`artist_name` / `artist_name:1` / `artist_name:2` …）。
///
/// 为什么走 metadata 而不是新 API：`SPTPlayerTrack` 是我们**手写**的 protocol，
/// 只有 `artistName` / `artistTitle` 两个 getter（`artistTitle` 在 9.1.x 上
/// 并不存在）。metadata 字典是 `SPTPlayerTrackHook` 覆写过的，一定在，
/// 合作艺人会以 `artist_name:1` 这种键出现。
///
/// 只读、失败就返回空数组（选歌那边对空名单会退回"只按时长"的旧行为）。
private func allArtistNames(from track: SPTPlayerTrack) -> [String] {
    guard let metadata = track.metadata() as? [String: Any] else { return [] }

    let keys = metadata.keys
        .filter { $0 == "artist_name" || $0.hasPrefix("artist_name:") }
        .sorted()

    return keys.compactMap { key -> String? in
        guard let value = metadata[key] as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private func loadCustomLyricsForCurrentTrack() throws -> Lyrics {
    guard let track = statefulPlayer?.currentTrack() ?? nowPlayingScrollViewController?.loadedTrack else {
        throw LyricsError.noCurrentTrack
    }

    let metadata = track.metadata()
    let title = track.trackTitle()
    let metadataTitle = metadata["title"]?.trimmingCharacters(in: .whitespacesAndNewlines)
    let metadataAlbum = metadata["album_title"]?.trimmingCharacters(in: .whitespacesAndNewlines)

    // NetEase 的搜索对文字敏感（日文名能搜到，罗马字名常常只搜到翻唱）。
    // Spotify 侧同一首歌可能有多份标题：player track 的 `trackTitle` 与 metadata
    // 里的本地化 `title`。把不一样的都带上，让 NetEase 那边逐个试（见
    // `NeteaseLyricsRepository.getLyrics` 的「标题变体」段）。
    var titleVariants: [String] = []
    if let metadataTitle, !metadataTitle.isEmpty, metadataTitle != title {
        titleVariants.append(metadataTitle)
    }

    let searchQuery = LyricsSearchQuery(
        title: title,
        primaryArtist: EeveeSpotify.hookTarget == .lastAvailableiOS14 ? track.artistTitle() : track.artistName(),
        spotifyTrackId: track.trackIdentifier,
        durationMs: track.trackDurationMilliseconds,
        // 全部艺人（`artist_name` / `artist_name:1` / …）—— 选歌判定要比对歌手，
        // 只靠 `primaryArtist` 会被同曲异名 / 翻唱骗过去。
        artistNames: allArtistNames(from: track),
        titleVariants: titleVariants,
        albumTitle: (metadataAlbum?.isEmpty == false) ? metadataAlbum : nil
    )

    let options = UserDefaults.lyricsOptions
    lyricsState = LyricsLoadingState()
    writeDebugLog("[Lyrics] Track \"\(searchQuery.title)\" - \(searchQuery.primaryArtist) (id \(searchQuery.spotifyTrackId))")
    if let durationMs = searchQuery.durationMs {
        writeDebugLog("[Lyrics] Track duration \(durationMs)ms (from metadata)")
    } else {
        writeDebugLog("[Lyrics] Track duration unavailable — NetEase duration gate skipped")
    }

    // 已移除：`forcedLyricsPayload` 排障短路（连同它用的 `forcedGoodLines`）。
    // 加入之后出现稳定复现的启动崩溃，见 `UserDefaults+Extension.swift` 末尾的说明。
    //
    // lyricsSource == .autoSelect -> 自动优选（按时间轴质量挑，见 `LyricsAutoSelect`）
    // 其它来源 -> 的单一源 + 可选 Genius 回退
    //
    // 署名先清空：否则"上一次问的是谁"会残留到这一次的失败路径上。
    // 两条分支都会在真正发请求之前写回它（单源在 `requestSingleSource` 入口，
    // 自动优选在下面那一行）。
    lastRequestedLyricsSourceDescription = ""

    // 「设置 → 实验 → 启用 Apple Music 官方 TTML 歌词」（默认关）是一个**总覆盖**开关：
    // 打开后这一首**只**问 Apple Music 官方 TTML，歌词来源（`UserDefaults.lyricsSource`）、
    // 「AMLL 优先」、「Genius 回退」、「自动优选」以及各来源自己的配置（Spicy key /
    // Musixmatch 令牌 / LRCLIB 地址 …）**一个都不看**。
    // 失败也**不兜底**：不切到用户选的源、不兜 Genius —— 这正是设置页那句
    // "选项开启后可能会忽略当前所有有关于歌词的设置"的字面语义。
    //
    // ⚠️ 放在 `var source = ...` **之前**：一旦打开，连 `lyricsSource` 都不必读，
    // "禁用歌词替换"（`.notReplaced`）也被覆盖。
    if UserDefaults.experimentsOptions.appleMusicOfficialTtml {
        writeDebugLog(
            "[Lyrics] Experiment ON: Apple Music official TTML —"
                + " every other lyrics setting is ignored for this track"
        )

        let result = try requestSingleSource(
            .appleMusicOfficialTtml,
            searchQuery: searchQuery,
            options: options,
            recordFallbackError: true,
            allowGeniusFallback: false
        )

        return makeLyrics(from: result.dto, source: result.source)
    }

    var source = UserDefaults.lyricsSource

    // **不再内置 Spicy Lyrics 的默认密钥**。用户没填自己的客户端密钥时，这一首改用
    // **Musixmatch** —— 而不是去走 SpicyLyrics 那条内部接口 `POST /query`：那条路的响应
    // 外壳写明只授权官方客户端与其公开 fork，第三方应用用它属于条款 §5 的"绕过 key 体系"，
    // 而且每首歌都要先抓 Spotify 的 access token。
    //
    // 为什么兜底给 Musixmatch：它在自动优选链路里也一直排在前列
    // （`LyricsAutoSelect.chain`），方向与"用户自己选的源失败时"一致。
    //
    // ⚠️ 两个连带后果都必须在代码里处理，否则观感是"设置没生效"：
    // ① 屏幕上显示的提供者会变成 Musixmatch —— 这是**对的**，词确实是它给的；
    // ② Musixmatch 自己也要令牌，它抛的 `invalidMusixmatchToken` **不许**弹
    // "请检查 Musixmatch 令牌"那个窗（用户没选过它），由 `spicyLyricsKeyMissingFallback` 挡。
    spicyLyricsKeyMissingFallback = false
    if source == .spicy, !UserDefaults.hasSpicyLyricsApiKey {
        writeDebugLog(
            "[Lyrics] SpicyLyrics has no client key — using Musixmatch for this track"
                + " (the key field is in Settings > Lyrics)"
        )
        source = .musixmatch
        spicyLyricsKeyMissingFallback = true
    }

    if source == .autoSelect {

        writeDebugLog("[Lyrics] Auto select enabled")

        // ⚠️ 这一段**不经过 `requestSingleSource`**，所以必须自己写这个署名 ——
        // 否则它一直是空串，占位 payload 的 `providedBy` 只会显示成裸的 "EeveeSpotify"，
        // 四源全败时看不出是哪个环节没找到词。
        // 自动优选不是"某一个源"，所以署这条链本身（本地化后 = "自动优选"）。
        lastRequestedLyricsSourceDescription = LyricsSource.autoSelect.description

        let picked = try autoSelectLyrics(searchQuery: searchQuery, options: options)
        return makeLyrics(from: picked.dto, source: picked.source)

    } else {

        writeDebugLog("[Lyrics] Single source: \(source.description)")

        if source == .notReplaced {
            throw LyricsError.invalidSource
        }

        // 「AMLL 优先」：先向 AMLL 要逐词歌词，**只接受逐词歌词**，
        // 拿不到就回退到用户在来源选择器里设置的那个源（连同它的相关设置）。
        //
        // 回退目标刻意不是硬编码的：哪个源适合兜底完全取决于地区与语言 ——
        // 日本用户设 PetitLyrics、大陆用户设网易云、其它地区设 SpicyLyrics，
        // 各自回退到自己最合适的地方，不需要再维护一份地区判断。
        // 该选项依赖逐词歌词，未开启时视为未勾选。
        let amllPreferred = NgzhwmSettingsViewModel.isAmllPreferred
            && NgzhwmSettingsViewModel.isWordByWordLyricsEnabled
            && source != .amllTtml

        if amllPreferred {
            writeDebugLog("[Lyrics] AMLL preferred — trying AMLL first, fallback target: \(source.description)")

            // 把**实际**会走的链写死在一行里（判读用）：Genius 只在"用户源也失败"时才兜一次。
            writeDebugLog(
                "[Lyrics] chain: AMLL → \(source.description)"
                    + (options.geniusFallback && source != .genius ? " -> Genius (only if the user's source fails too)" : " (no Genius fallback)")
            )

            // 走同一套单源错误处理：记录 fallbackError、弹 MxM 相关弹窗。
            //
            // ⚠️ 结果里带的是**实际**给词的那个源：AMLL 请求失败而 Genius 兜底成功时，
            // 拿回来的 dto 是 Genius 的。以前这里只回传 dto、源名沿用调用方传的那个，
            // 于是"来源标签写 AMLL、内容其实是 Genius"。
            //
            // ⚠️ AMLL 这一跳**不自带 Genius 兜底**。用户设置的字面语义是"AMLL 拿不到就用
            // **我选的那个源**"，而 `requestSingleSource` 的 `allowGeniusFallback` 默认是 true
            // ⇒ 否则真实链会变成
            // AMLL → Genius（AMLL 那跳自带的兜底）→ 用户源（多半再自带一次 Genius）
            // 也就是 AM→Gen→NE→Gen，**比用户以为的多一跳、还多花一次 Genius 的时间**。
            // 要的是 **AM → NE → Gen**（Genius 只在"用户源也失败"时兜一次）。
            let amllResult = try? requestSingleSource(
                .amllTtml,
                searchQuery: searchQuery,
                options: options,
                recordFallbackError: true,
                allowGeniusFallback: false
            )

            // ⚠️ 判据是**逐词可用**，不是「有行」。
            //
            // AMLL 的 TTML 里两种数据都可能出现：
            // · 有 `<span>` 逐词时间轴 → 逐词歌词（要的）
            // · 只有 `<p begin=...>` 行级时间轴 → 就是一行一句的普通同步歌词
            // 只判 `!lines.isEmpty` 的话，第二种也会被当成"AMLL 成功"直接采用：用户明明开了
            // 「AMLL 优先」（只想要逐词），结果拿到一份逐行歌词，而且它的排版/来源和用户自己设的
            // 那个源完全不同 —— 看起来就像"设置没生效"。
            //
            // 判定口径与渲染层对齐（同一个 `hasUsableWordLevelData`）：
            // 行级数据在这里就被判为"不合格"，交给下面用户设置的源去处理。
            // 无时间轴的数据同样过不了这一关（`timeSynced == false`），一并回退。
            if let result = amllResult, hasUsableWordLevelData(result.dto) {
                writeDebugLog("[Lyrics] AMLL succeeded — using it (\(result.dto.lines.count) line(s))")
                return makeLyrics(
                    from: result.dto,
                    source: result.source
                )
            }

            if let dto = amllResult?.dto {
                let timeline = dto.timeSynced ? "line-or-word timeline" : "no timeline"
                writeDebugLog(
                    "[Lyrics] AMLL returned \(dto.lines.count) line(s) but not word-by-word"
                        + " (\(timeline)) — falling back to \(source.description)"
                )
            } else {
                writeDebugLog(
                    "[Lyrics] AMLL unavailable — falling back to \(source.description) with its own settings"
                )
            }
            // 设置的就是 Genius 时不必再走下面的 geniusFallback，否则会重复请求一次。
            let result = try requestSingleSource(
                source,
                searchQuery: searchQuery,
                options: options,
                recordFallbackError: false,
                allowGeniusFallback: source != .genius
            )
            return makeLyrics(
                from: result.dto,
                source: result.source
            )
        }

        let result = try requestSingleSource(
            source,
            searchQuery: searchQuery,
            options: options,
            recordFallbackError: true
        )

        return makeLyrics(
            from: result.dto,
            source: result.source
        )
    }
    }

    // MARK: - 自动优选（取代多级回退）
    //
    // 按 `LyricsAutoSelect.chain` 的顺序逐个问，保留**时间轴最细**的那一份。
    //
    // 与"多级回退"的区别只有一条，但就是这一条：**先答出来的不再等于被采用**。
    // 先到的纯文本 / 逐行歌词先留在手里，链路继续往下问 ——
    // 直到拿到逐字歌词，或者为「升级」预留的预算用完（见 `LyricsAutoSelect.shouldStop`）。
    //
    // 为什么不做成并发：这几个仓库各自持有 `URLSession` / `NSCache` / 令牌刷新状态
    // （`AnonymousTokenHelper`），并发拉起来要逐个确认线程安全。串行 + 预算上限
    // 已经能达到「逐字优先」的目的，风险小得多。
    //
    // - Returns: 保留下来的一份（`dto` 还没施加时间轴偏移 —— 那是 `makeLyrics` 的事）。
    // - Throws: 一个源都没答上来时，抛**第一个**错误（保留"为什么没词"的原始原因，
    // 而不是统一成 `unknownError`）。
    private func autoSelectLyrics(
        searchQuery: LyricsSearchQuery,
        options: LyricsOptions
    ) throws -> LyricsAutoSelectPick {
        let startedAt = Date()
        let chain = LyricsAutoSelect.chain()
        var best: LyricsAutoSelectPick?
        var firstError: Error?

        writeDebugLog(
            "[Lyrics] auto select chain: \(chain.map(\.description).joined(separator: " → "))"
                + " (wanted \(LyricsAutoSelect.wantedTier.logName))"
        )

        for (index, source) in chain.enumerated() {
            let remaining = Array(chain.dropFirst(index + 1))
            let elapsed = Date().timeIntervalSince(startedAt)

            if LyricsAutoSelect.shouldStop(best: best, elapsed: elapsed, remaining: remaining) {
                break
            }

            // Spicy Lyrics 没有客户端密钥时那条路是**必然失败**的（仓库自己会抛
            // `missingSpicyKey`）。这里提前跳过，既不产生网络请求，
            // 看起来像"这个源没词"的失败记录。
            if source == .spicy, !UserDefaults.hasSpicyLyricsApiKey {
                writeDebugLog("[Lyrics] auto select: Spicy Lyrics skipped — no client key")
                continue
            }

            // 这一跳最多等多久：单源上限、总预算余额、以及（手里已有逐行时的）升级预算，
            // 三者取最小。少了最后一项，一次慢请求就能把"最多再等 4 秒"变成 9 秒。
            var timeout = min(
                LyricsAutoSelect.timeout(for: source),
                LyricsAutoSelect.totalBudget - elapsed
            )
            if let best, best.tier == .line, LyricsAutoSelect.wantsWordTiming {
                timeout = min(timeout, LyricsAutoSelect.upgradeBudget - elapsed)
            }
            guard timeout > 0 else {
                writeDebugLog("[Lyrics] auto select: budget spent, stopping before \(source.description)")
                break
            }

            writeDebugLog(
                "[Lyrics] auto select \(index + 1)/\(chain.count): \(source.description)"
                    + " (timeout \(String(format: "%.1f", timeout))s)"
            )

            let semaphore = DispatchSemaphore(value: 0)
            var resultDto: LyricsDto?
            var requestError: Error?

            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    resultDto = try lyricsRepository(for: source).getLyrics(searchQuery, options: options)
                } catch {
                    requestError = error
                }
                semaphore.signal()
            }

            if semaphore.wait(timeout: .now() + timeout) == .timedOut {
                writeDebugLog("[Lyrics] auto select: \(source.description) timed out after \(timeout)s")
                if firstError == nil { firstError = LyricsError.unknownError }
                continue
            }

            if let dto = resultDto {
                // 纯音乐是**结论**，不是"没有词" —— 立刻收工，不必再问后面的源：
                // 后面的源就算答上来也不会有词，只会白花一次请求。
                if dto.isInstrumental {
                    writeDebugLog("[Lyrics] auto select: \(source.description) says the track is instrumental")
                    return LyricsAutoSelectPick(
                        dto: dto,
                        source: source,
                        tier: .untimed,
                        elapsed: Date().timeIntervalSince(startedAt)
                    )
                }

                // 空行 = 这个源其实没答上来（"查无此曲"）。旧的多级回退会把这种答案
                // 当成成功、直接终止链路 —— 于是后面明明有词的源一个都没被问到。
                if dto.lines.isEmpty {
                    writeDebugLog(
                        "[Lyrics] auto select: \(source.description) returned 0 line(s) — treated as no answer"
                    )
                } else {
                    let tier = LyricsAutoSelect.tier(of: dto)
                    let pick = LyricsAutoSelectPick(
                        dto: dto,
                        source: source,
                        tier: tier,
                        elapsed: Date().timeIntervalSince(startedAt)
                    )
                    let better = LyricsAutoSelect.isBetter(pick, than: best)
                    writeDebugLog(
                        "[Lyrics] auto select: \(source.description) returned \(dto.lines.count) line(s),"
                            + " \(tier.logName) — \(better ? "kept" : "not better than what we already have")"
                    )
                    if better { best = pick }
                }
            } else if let requestError {
                // 自动优选模式下**不弹**任何源自己的配置弹窗：用户没有"选中"过其中任何一个，
                // 弹一句"请检查 Musixmatch 令牌"只会把他引到一个他没打算用的源上。
                writeDebugLog("[Lyrics] auto select: \(source.description) failed: \(requestError)")
                if firstError == nil { firstError = requestError }
            }
        }

        if let best {
            writeDebugLog(
                "[Lyrics] auto select picked \(best.source.description)"
                    + " (\(best.tier.logName), \(best.dto.lines.count) line(s),"
                    + " \(String(format: "%.2f", best.elapsed))s)"
            )
            return best
        }

        // 一个源都没答上来。`fallbackError` 决定「报告问题」那颗按钮显不显示，
        // 所以只在**全军覆没**时写 —— 有结果时写它会让按钮莫名其妙地出现。
        lyricsState.fallbackError = (firstError as? LyricsError) ?? .unknownError
        if let firstError { throw firstError }
        throw LyricsError.unknownError
    }

    // MARK: - 单源请求
    //
    // 一次单源请求的产物：歌词数据 + **实际**产出它的源。
    //
    // 为什么要显式带着"实际源"：这个方法在失败时会用 Genius 兜底重试，此时
    // 返回的是 Genius 的歌词，而调用方传进来的 `source` 是用户设的那个源。
    // 只回传 dto 的话，来源标签就会写成明明拿的是 Genius 的歌词，
    // 底部却写着 PetitLyrics）。
    private struct SourceLyricsResult {
        let dto: LyricsDto
        let source: LyricsSource
    }

    /// 按用户设置请求单一来源。保持既有行为不变：
    /// - 该源的错误会写入 `lyricsState.fallbackError`（`recordFallbackError`）并弹 MxM 相关弹窗；
    /// - 非 Genius 源失败且 `options.geniusFallback` 开启时，再用 Genius 重试一次
    /// （三道门与每一道门自己的日志见 `catch` 里那一段）。
    ///
    /// - Parameter allowGeniusFallback: 为 false 时跳过 Genius 兜底。两个调用方：
    /// ①「AMLL 优先」的 **AMLL 那一跳**（用户设置的字面语义是"AMLL 拿不到就用我选的
    /// 那个源"，不该先插一跳 Genius，见调用点注释）；
    /// ②「AMLL 优先」的**用户源那一跳**（用户源本身就是 Genius 时传 false，避免重复请求）。
    private func requestSingleSource(
        _ source: LyricsSource,
        searchQuery: LyricsSearchQuery,
        options: LyricsOptions,
        recordFallbackError: Bool,
        allowGeniusFallback: Bool = true
    ) throws -> SourceLyricsResult {
        let repository = source == .genius
            ? geniusLyricsRepository
            : lyricsRepository(for: source)

        // 记下"这一次问的是谁"：失败时占位 payload 的 `providedBy` 要用
        // （见文件作用域那个全局的说明）。
        lastRequestedLyricsSourceDescription = source.description

        do {
            return SourceLyricsResult(
                dto: try repository.getLyrics(searchQuery, options: options),
                source: source
            )
        } catch let error {
            // 错误原文要打全：只写一句「failed — falling back to Genius」的话，
            writeDebugLog("[Lyrics] \(source.description) failed: \(error)")

            if recordFallbackError {
                if let error = error as? LyricsError {
                    lyricsState.fallbackError = error
                    // ⚠️ "没填 SpicyLyrics 密钥 → 自动改用 Musixmatch"那一档**不许**弹
                    // "Musixmatch 令牌无效，请检查你的令牌"：用户根本没选过 Musixmatch，
                    // 弹了只会让他去改一个他没打算用的源。见 `spicyLyricsKeyMissingFallback`。
                    if spicyLyricsKeyMissingFallback, error == .invalidMusixmatchToken {
                        writeDebugLog(
                            "[Lyrics] Musixmatch unauthorized popup suppressed — the source was"
                                + " substituted because no SpicyLyrics key is set"
                        )
                    } else {
                        handleLyricsErrorPopUp(error)
                    }
                } else {
                    lyricsState.fallbackError = .unknownError
                }
            }

            // 注意顺序：Genius 失败不再兜底为空歌词（与既有行为一致）——
            // allowGeniusFallback 在用户设置本身就是 Genius 时为 false。
            //
            // ── Genius 兜底的三道门
            // 每一道没过都**必须留一行日志**：静默 rethrow 会让"开关关着"和"真的没词"
            // 看起来一模一样，事后无法区分。
            //
            // 门 1：来源本来就是 Genius —— 回退到自己没有意义（设置页对 Genius /
            // 自动优选来源也不显示那个开关）。以前这里会真的再打一次 Genius 请求，
            // 就是这么来的。
            if source == .genius {
                writeDebugLog("[Lyrics] Genius failed — source is already Genius, no fallback")
                throw error
            }

            // 门 2：调用方显式要求这条链不做兜底。「AMLL 优先」的 AMLL 那一跳
            // 与"用户源就是 Genius"那一跳都会传 false（见调用点），所以这门是**常走**的。
            if !allowGeniusFallback {
                writeDebugLog(
                    "[Lyrics] \(source.description) failed — Genius fallback suppressed by caller, no retry"
                )
                throw error
            }

            // 门 3：用户开关。默认 false —— 这个值一旦被重置，表现是"整整一场都不回退"，
            // 而不是"偶尔失败"。读日志时先看这里，再看 Genius 那边 0 命中。
            if !options.geniusFallback {
                writeDebugLog(
                    "[Lyrics] \(source.description) failed — Genius fallback is OFF, no retry"
                )
                throw error
            }

            writeDebugLog("[Lyrics] \(source.description) failed — falling back to Genius")

            // 兜底一跑，「这次问的是谁」就变成 Genius 了 —— 必须在这里把那个署名全局改掉。
            //
            // 为什么：它只在 `requestSingleSource` **入口**写过一次（= 用户设的源），成功路径
            // 靠下面 `source: .genius` 纠正署名，**失败路径没人纠正** —— 于是"兜底也失败"时
            // 占位 payload 写回用户设的那个源（网易云没词 → Genius 搜到 1 条但没可用行 →
            // 卡面却写着 `歌词提供者：NetEase`），看起来像"根本没回退"。
            //
            // 口径与成功路径一致：**最后被问的那个源**。
            lastRequestedLyricsSourceDescription = LyricsSource.genius.description

            do {
                // ⚠️ 回传的 `source` 必须是 `.genius`：这份 dto 是 Genius 给的，
                // 来源标签也得写 Genius（写用户设的那个源就是"注解显示 PetitLyrics"）。
                return SourceLyricsResult(
                    dto: try geniusLyricsRepository.getLyrics(searchQuery, options: options),
                    source: .genius
                )
            } catch let geniusError {
                // ⚠️ 兜底失败必须**显式**抛出去并打一行：源内日志只有 `[Genius] No usable
                // lyrics` 这类，`[Lyrics]` 这一级不打的话，读日志时分不清"最后是 Genius
                // 没找到"还是"这次压根没回退"。与第一个源的 `failed: <error>` 对称。
                writeDebugLog("[Lyrics] Genius failed: \(geniusError)")
                throw geniusError
            }
        }
    }

    // MARK: - DTO → Lyrics
    //
    // 自造一套可读的歌词配色（拿不到 Spotify 原始颜色时用）。
    //
    // **两条路径共用**：真实歌词（`makeLyrics` 里那段）与占位 payload
    // （`makeUnavailableLyrics`）。必须共用 —— 占位那一支原本"`originalColors` 为 nil
    // 就什么都不设"，于是 404 曲目（Spotify 自己没词，必然没有 `originalColors`）的
    // 卡片与全屏页在**颜色字段全空**时被渲染成纯黑；而能取到词的曲目走了另一支，已经修好了。
    //
    // 产出**中明度不透明面板 + "未唱黑 / 已唱白"** —— 与 Spotify、以及我们自己的逐词
    // overlay 同一套语义（`lineColor` 管未唱、`activeLineColor` 管已唱/当前行）。
    // ⚠️ 这两个字段不能一起改：都设黑 = 整片全黑，都设白 = 整片全白。
    func synthesizedLyricsColors() -> LyricsColors {
        let settings = UserDefaults.lyricsColors
        let track = statefulPlayer?.currentTrack() ?? nowPlayingScrollViewController?.loadedTrack

        let extractedColor: String? = switch EeveeSpotify.hookTarget {
        case .lastAvailableiOS14:
            track?.extractedColorHex()
        default:
            track?.metadata()["extracted_color"]
        }

        // 这里只算出"这首歌的底色"本身；归一化放到下面**一处**做（不要两处，
        // 否则读的人无法判断最终明度到底由谁决定）。
        var color: Color
        if settings.useStaticColor {
            color = Color(hex: settings.staticColor)
        } else if let extractedColor {
            color = Color(hex: extractedColor)
        } else if let uiColor = backgroundViewModel?.color() {
            color = Color(uiColor)
        } else {
            color = Color.gray
        }

        // 面板：album 主色归一化到中明度，**保持不透明**。
        // 不能像原来那样把 alpha 清掉（那会露出卡片默认黑底）；也不该压得很暗 ——
        // 因为下面的字色是"未唱黑 / 已唱白"，黑字需要中明度以上的底才看得见。
        let panel = color.normalized(settings.normalizationFactor)

        // 字色沿用**最初那套约定**（也就是我们自己 overlay 的约定，见 `LyricsWordByWord`：
        // `index <= activeIndex ? activeLineColor : lineColor`）：
        // · 未唱到的行 = `lineColor` = 黑
        // · 已唱 / 正在唱 = `activeLineColor` = 白
        //
        // ⚠️ 这两个字段一个管"未唱"、一个管"已唱"，**不能一起改** ——
        // 两个都设黑 → 卡片与全屏页整片全黑；两个都设白 → 整片全白
        // （"正常来讲是未唱到的行才黑色，其他的白色"）。
        let palette = LyricsColors.with {
            $0.backgroundColor = panel.uInt32
            $0.lineColor = Color.black.uInt32
            $0.activeLineColor = Color.white.uInt32
        }
        // 两条路径共用这个函数，所以这条日志同时覆盖"真实歌词"与"占位 payload"
        // （后者原本完全没有颜色、也没有日志，占位曲目的黑块就是那么来的）。
        writeDebugLog(
            String(
                format: "[Lyrics] synthesized card colors — panel=%08X line=%08X active=%08X",
                palette.backgroundColor, palette.lineColor, palette.activeLineColor
            )
        )
        return palette
    }

    /// 「取不到我们的歌词」时交给 Spotify 的替身 payload —— 目的是**不让 Spotify 把
    /// 它自己的官方歌词显示出来**。
    ///
    /// 背景：取词失败时钩子原本走 `customLyricsData ?? buffer`，也就是把 Spotify 的原始
    /// 响应原样放行。于是界面（歌词卡片 / 全屏页）显示的是 **Spotify 自己的歌词**：
    /// 日区那一批的来源写着「プチリリ」——Spotify 的日文歌词供应商，**不带 (EeveeSpotify)
    /// 后缀**（这就是"看着像 PetitLyrics 又不是"的原因），而且它是官方歌词，
    /// 不会跟着我们的罗马化设置走。
    ///
    /// 返回 nil 表示**不替换**（继续用 Spotify 自己的歌词）。此时是三种情况之一：
    /// · 禁用歌词替换（`notReplaced`）—— 那就是明确要看官方歌词；
    /// · 「隐藏 Spotify 官方歌词」开关关着；
    /// · 歌词功能整体被禁用。
    private func unavailableLyricsPayload(original: Lyrics?) -> Lyrics? {
        // 「Apple Music 官方 TTML」是**总覆盖**实验 —— 它连"要不要顶掉官方歌词"这两个策略
        // 开关一起忽略（否则隐藏 Spotify 官方歌词时，实验取词失败会掉回
        // Spotify 自己的词，看起来像"实验根本没生效"）。
        let experimentForcesReplacement = UserDefaults.experimentsOptions.appleMusicOfficialTtml

        guard !NgzhwmSettingsViewModel.isLyricsFeatureDisabled,
              experimentForcesReplacement || UserDefaults.lyricsSource != .notReplaced,
              experimentForcesReplacement || NgzhwmSettingsViewModel.isOfficialLyricsHidden else {
            return nil
        }

        return makeUnavailableLyrics(originalColors: original?.colors, note: nil)
    }

    /// 构造「没有歌词」的替身 payload —— 与 `unavailableLyricsPayload` 同一份内容，
    /// 但不带任何用户开关判断：**调用方已经决定"必须给出一个响应"**。
    ///
    /// 抽出来的原因：现在有两个调用方，一个是下面这个"要不要替换官方歌词"的策略判断，
    /// 另一个是 URLSession 侧的"响应兜底"（见 `unavailableLyricsBytes`）。
    /// 两处必须长得一模一样，否则用户会在不同失败路径上看到不同文案。
    ///
    /// - Parameter note: 有值时**追加一行**说明（例如"这首歌正在切换"）。
    /// 传 nil 时只有一行"未找到歌词"（历史上是三行：通知 + 空行 + 提示行）。
    func makeUnavailableLyrics(originalColors: LyricsColors?, note: String?) -> Lyrics {
        // 占位文案要有行级时间轴。
        //
        // 这个版本把"无时间轴"判为不可用，而占位恰恰是"取不到词"那条路上唯一交出去的
        // 东西 —— 没有时间轴就等于连"未找到歌词"都显示不出来，的是
        // **彻底没有歌词模块**。（真实歌词源那条合成已删除，占位这条保留。）
        // ⚠️ 提示行 `ngzhwm_lyrics_unavailable_hint`（"可以在设置里换一个歌词来源…"）
        // 已随中文本地化一起删除 —— 占位现在只有"未找到歌词"一行（`note` 有值时追加一行）。
        // 只删文案、留代码的话，两个 locale 都拿不到这个 key，界面会直接把 key 名当文案显示。
        // 要把提示加回来：恢复下面那行 `LyricsLineDto(content: "…_hint".localized)`，
        // 并在 en / zh-CN 两个 `Localizable.strings` 里补回该 key。
        var placeholderLines = [
            LyricsLineDto(content: "lyrics_unavailable".localized)
        ]
        if let note, !note.isEmpty {
            placeholderLines.append(LyricsLineDto(content: note))
        }

        // ⚠️ 这里**写死**补时间轴，不看任何开关。
        //
        // 它是"未找到歌词"这一行能不能显示出来的前提（这个版本把无时间轴的 payload 判为
        // 不可用，占位恰恰是取不到词那条路上唯一交出去的东西），**不是**"给某个源伪造
        // 时间轴"—— 真实源那条合成已整体删除（见 `LyricsDto.toSpotifyLyricsData` 顶部）。
        // 旧设置键 `ngzhwm_syntheticLineTiming` 连同它的调试页开关一起删了。
        placeholderLines = SyntheticLyricTiming.applying(
            to: placeholderLines,
            durationMs: currentTrackDurationMs
        )

        return Lyrics.with {
            $0.data = LyricsData.with {
                // 合成过时间轴 → 如实声明；否则保持旧的"无时间轴"语义。
                $0.timeSynchronized = placeholderLines.contains { ($0.offsetMs ?? 0) > 0 }
                $0.restriction = .unrestricted
                // 署名：**谁被问了就署谁**（形如 `"NetEase"`），与正常路径
                // `LyricsDto.toSpotifyLyricsData(source:)` 的写法完全一致。
                //
                // ⚠️ 以前这里写死 `"EeveeSpotify"`（还带过 `(EeveeSpotify)` 后缀）。
                // Spotify 原生歌词页/卡片底部那行 provider 是直接照 payload 的 `providedBy`
                // 显示的，于是取不到词时的是 `歌词提供者：EeveeSpotify` ——
                // 看起来像"歌词源设置没生效"。
                //
                // 兜底：还没问过任何源（首次启动、或走 URLSession 兜底那条路）时**留空**。
                $0.providedBy = lastRequestedLyricsSourceDescription
                $0.lines = placeholderLines.map { line in
                    LyricsLine.with {
                        $0.content = line.content
                        $0.offsetMs = Int32(line.offsetMs ?? 0)
                    }
                }
            }
            // 颜色：有 Spotify 原来那份就沿用（背景色 / 歌名配色保持原样，看不出被替换过）；
            // **没有的时候必须自己造一套** —— 404 曲目（Spotify 自己没词）必然没有
            // `originalColors`，而 `colors` 空着会让卡片与全屏页渲染成**纯黑**
            // （取不到词的曲目全都走 `[NetEase] No usable lyrics` → `serving our placeholder`
            // 这条路，而能取到词的曲目已经有 `keeping synthesized background opaque` 生效）。
            $0.colors = originalColors ?? synthesizedLyricsColors()
        }
    }

    // MARK: - 「绝不空手而归」的响应兜底
    //
    // `unavailableLyricsBytes` 是文件作用域函数（见本文件 `getLyricsDataForCurrentTrack` 上方）：
    // 调用方是 URLSession 的两个钩子，属"这次响应交什么字节"的纯数据问题。
    //
    // 把 dto 落到全局状态上（**唯一**写入口），返回**已经加上时间轴偏移**的那一份。
    //
    // 三件事必须一起做，而且是同一个顺序：
    // 1. 提供者写进 dto 本身（`providerName`）并同步 `currentLyricsProvider`；
    // 2. 按「这一首 + 这个源」加时间轴偏移（`LyricsTimingOffset`，Genius 不参与）；
    // 3. `currentLyricsVersion` 自增并通知逐词 overlay 重挂。
    //
    // ⚠️ 为什么返回 dto：注入给 Spotify 的 payload 是由**调用方**用这份 dto 现造的
    // （`makeLyrics` / 自动优选那一段），如果只改 `currentLyricsDto` 而不把平移过的
    // 那一份交回去，原生歌词页与两个自绘 overlay 会差一个偏移量。
    //
    // 提供者与 dto 必须是同一时刻写下的：写晚了，旧 overlay 在 rebuild 时会读到
    // 上一首的提供者，慢一拍是必然会发生的。
    @discardableResult
    private func storeLyricsDto(_ dto: LyricsDto, source: LyricsSource) -> LyricsDto {
        var dto = dto
        // 只留**源名**，不带 `(EeveeSpotify)` 水印。这一串有两个去处：
        // ① 我们自己画的页脚（`逐词歌词提供者：…`）；
        // ② 注入 payload 的 `providedBy`（Spotify 原生那一行照它显示）。
        // 另有一处把它写进**歌手那一行的右边**，见
        // `NowPlayingLyricsPlate.applyProviderToArtistLine`。
        //
        // **仓库自己算好的署名不许被这里盖掉。** SpicyLyrics 会在 dto 上写
        // "Spicy Lyrics · 制作者 X · 上传者 Y"（见 `SpicyLyricsRepository.providerCredit`）——
        // SL 的服务条款 §6 要求 provider + 社区同步的 uploader/maker 全部展示，且
        // "歌词在哪、署名就在哪"。以前这里无条件覆盖成 `source.description`，
        // 那一串永远显示不出来。所以：dto 带了署名就用它的，空的才兜底成源名。
        dto.providerName = dto.providerName.isEmpty ? source.description : dto.providerName

        // 同样**不许盖掉**仓库给的完整署名（Spicy Lyrics 的社区贡献者）。
        // 它只进注入 payload 的 `providedBy`（原生歌词页底部那一行），不贴歌手行。
        if dto.providerCredit.isEmpty {
            dto.providerCredit = dto.providerName
        }

        // 罗马字是**显示层**的事，这里必须存**原样**的 dto。
        //
        // 以前这里存的是 `dto.romanizedForWordByWordIfEnabled` 的副本 —— 那个副本会把
        // `lines[i].content` **和词级 token** 一起改写成罗马字（见 `LyricsDto` 里那段
        // "整行罗马化 + 首字母大写"）。于是后面每一个读 `currentLyricsDto` 的人都以为
        // 自己拿到的是原文，实际上已经是罗马字：
        // · `LyricLinesAdapter.toAppleMusicLyricLines` 的 `romanization(original:romanized:)`
        // 拿罗马字和罗马字比 ⇒ 判定"这行没有罗马字可显示" ⇒ **上方那一行永远不出现**；
        // · 主歌词那一行画的也是罗马字 ⇒ 的就是"原文被替换掉了"。
        //
        // `LyricLinesAdapter.romanizedContentsForDisplay` 自己会从这份原文现算一份罗马字
        // （带缓存、跟 `currentLyricsVersion` + 三个开关走），主歌词仍用 `line.content`
        // ⇒ 原文在、罗马字画在它上方。所以这里必须存**原样**的 dto。
        //
        // ⚠️ 那句"原样"指的是**不许换成罗马字**；大小写不在此列 —— 主歌词也走
        // "每行第一个字母大写"这条显示约定（`LyricsDto.capitalizingFirstLettersForDisplay`
        // 只动大小写，原文一个字不换）。
        // 这份数据**属于哪一首**：切歌不一定伴随歌词请求（客户端命中自己的歌词存储 /
        // 离线歌词时不会有 `color-lyrics` 请求），所以"模型归属"必须显式记下来，
        // 供两层每帧比对。详见 `currentLyricsDtoTrackId` 的说明。
        //
        // 优先用"这次请求问的那首"（`lyricsLayerTrackId` 在请求入口就写好了），
        // 再退回播放器实时读到的曲目。
        let trackId = lyricsLayerTrackId
            ?? statefulPlayer?.currentTrack()?.trackIdentifier
            ?? ""

        // 偏移**所有源共用**，并统一在这里加**一次** —— 注入给 Spotify 的 payload 与
        // 两个自绘 overlay 读的必须是同一份平移过的数据。键是「源 + 曲目」：同一首歌
        // 换一个源就是另一份时间轴（见 `LyricsTimingOffset`）。
        // Genius 由 `LyricsTimingOffset.supportsOffset` 挡掉，恒为 0。
        //
        // ⚠️ 必须在 `currentLyricsDto` 赋值**之前**平移：下面那份是 UI 每帧在读的全局量。
        let offsetMs = LyricsTimingOffset.offsetMs(forTrackId: trackId, source: source)
        if offsetMs != 0 {
            dto = dto.applyingTimingOffset(offsetMs)
            writeDebugLog(
                "[Lyrics] timing offset \(offsetMs)ms applied — source=\(source.description)"
            )
        }

        currentLyricsDto = dto.capitalizingFirstLettersForDisplay()
        // 数据到了（哪怕是纯音乐那种"空行 + isInstrumental"）⇒ 取词这一步 = found。
        currentLyricsLookupState = .found
        currentLyricsDtoTrackId = trackId
        // 这份 dto 是谁给的：运行时调偏移（`reapplyLyricsTimingOffset`）与设置页都要读它。
        currentLyricsSource = source
        // 已经加了多少：运行时只补差值。
        currentLyricsTimingOffsetAppliedMs = offsetMs
        // ⚠️ 提供者要在**版本号自增之前**写好：观察者（两个 overlay 层）都是
        // 盯着版本号决定要不要重建的，版本一变它们就会立刻读 `currentLyricsProvider`。
        currentLyricsProvider = dto.providerName
        // 可点署名用的两样：提供者站点 + 社区贡献者（SL 条款 §6 要链接）。
        currentLyricsProviderURL = dto.providerURL
        currentLyricsContributors = dto.providerContributors
        currentLyricsVersion += 1
        writeDebugLog("[Lyrics] provider: \(dto.providerName)")

        // 源**没给译文**、而开关打开时，在后台用 Apple 的 `Translation` 框架翻一遍；
        // 翻完会自己把 `currentLyricsDto` 补上 `translation` 并**再加一次**版本号
        // （见 `LyricsAutoTranslation`）。
        // ⚠️ 放在版本号自增**之后**：那一拍 overlay 先用原文把版面立起来，
        // 译文到了只是多一行副行，不会出现"空页等翻译"。
        LyricsAutoTranslation.considerAfterLoad()

        // 数据到达即刷新逐词 overlay：9.1.x 上内嵌宿主是 NPV，
        // 它只在进入正在播放页时出现一次，不会因为这首歌词到了再来一次。
        // `WordByWordHost` 是 @MainActor 隔离的，必须经 `onMainThreadSync` 这个
        // 本模块既有的桥进入（ng 的 hook 里也都是这么写的）。
        onMainThreadSync {
            WordByWordHost.shared.refreshForCurrentLyrics()
        }

        // 交回**平移过**的那一份：调用方拿它造注入 payload。
        return dto
    }

    /// 上一次**已经装上/清空**的逐词层对应的曲目 id（切歌信号，见调用点）。
    ///
    /// 用途：把"切歌"这件事从"新歌词到达"里解耦出来。理由与 `AppleMusicLyricsOverlay`
    /// 里 `currentModelTrackId` 的说明相同 —— 那边负责**渲染前**兜底，这边负责**尽早**清掉。
    var lyricsLayerTrackId: String?

    /// 把逐词层的全局状态清空，并把已经挂上的层摘掉。
    ///
    /// 用于"这一首没有我们的歌词"（取词失败 / 用户选了 `notReplaced`）：
    /// 旧层的 `setCurrentTime` 与新层的 `update` 都以"有没有可用数据"为准，
    /// 数据一清：
    /// · 旧层整块透明 + 触摸穿透 → 原生歌词与控件原样可用；
    /// · 新层因为没有行模型而 `detach` → 同上。
    ///
    /// 默认保持历史文案（取词失败那条路）；
    /// 切歌时传 "track changed…"，这样日志一眼能分清是"没词"还是"换歌"。
    private func resetWordByWordLyrics(
        reason: String = "no custom lyrics for this track",
        lookupFailed: Bool = true
    ) {
        writeDebugLog("[Lyrics] \(reason) — clearing word-by-word layer")
        currentLyricsDto = nil
        // 听歌页那层靠这个状态决定"点开之后写哪一句" ——「还在查」与「查完了没有」
        // 必须分开（前者写"正在查找"、后者写"未找到"）。
        // `lookupFailed: false` 的调用点是"切歌 / 功能被关"，那两种情况**不许**写成"未找到"。
        if lookupFailed {
            currentLyricsLookupState = .failed
        }
        // 模型归属也要一起清：留着它会让"这份数据属于哪一首"永远指向上一首。
        currentLyricsDtoTrackId = ""
        currentLyricsProvider = ""
        currentLyricsSource = nil
        currentLyricsTimingOffsetAppliedMs = 0
        // 署名两样也要一起清：留着会让"这首歌没有我们的词"时页面上还挂着上一首的贡献者。
        currentLyricsProviderURL = nil
        currentLyricsContributors = []
        currentLyricsVersion += 1
        onMainThreadSync {
            WordByWordHost.shared.clearForUnavailableLyrics()
        }
    }

    /// 把来源返回的 DTO 转成注入 Spotify 的 `Lyrics`，并同步全局状态
    /// （`currentLyricsDto` / `currentLyricsVersion` / `currentLyricsProvider` / `lyricsState`）。
    ///
    /// - Parameter source: **实际**产出这份 dto 的源（Genius 兜底时是 `.genius`，
    /// 不是用户设的那个）。来源标签与注入给 Spotify 的 `providedBy` 都用它。
    ///
    /// ⚠️ `durationMs` 参数已删 —— 它唯一的用途是给无时间轴的源合成时间轴，
    /// 那条兜底整体删掉了（见 `LyricsDto.toSpotifyLyricsData` 顶部说明）。
    private func makeLyrics(
        from dto: LyricsDto,
        source: LyricsSource
    ) -> Lyrics {
        lyricsState.isEmpty = dto.lines.isEmpty
        lyricsState.wasRomanized = dto.romanization == .romanized
            || dto.romanization == .canBeRomanized
        lyricsState.loadedSuccessfully = true

        // 偏移在这里施加，返回值是**平移过**的那一份 —— 注入 payload
        // 必须用它，否则原生歌词页会比自绘层差一个偏移量。
        let shifted = storeLyricsDto(dto, source: source)

        return Lyrics.with {
            $0.data = shifted.toSpotifyLyricsData(
                // 同上：`providedBy` 优先用 dto 的 `providerCredit`，源名只是兜底。
                source: source.description,
                useInstrumentalPlaceholder: source != .genius
            )
        }
    }

// MARK: - 「绝不空手而归」的响应兜底
//
// URLSession 钩子侧的兜底 payload 计数器。
private var urlSessionFallbackCount = 0

/// 歌词请求的**响应兜底**：只要 URL 是 `color-lyrics/v2`，钩子就必须交给 Spotify
/// 一个可解析的 `Lyrics` —— 这是 910 时代 `InterceptionContext` 那条底线。
///
/// 为什么必须有它：9.1.x 的 NPV 歌词卡片是**等歌词数据到达才创建**的
/// （`CustomLyrics+AllTracksLyrics.x.swift` 里 `NPVScrollViewController.viewWillAppear`
/// 的说明）。如果某个失败路径让这次请求"什么都不返回"（`didCompleteWithError` 只报
/// completion、不投递数据），Spotify 就不会建卡片；而没有卡片，连全屏歌词页的入口
/// 也不存在 —— 的就是"这首歌没有歌词模块"，比"有模块但写着未找到歌词"严重得多。
///
/// 放在文件作用域（而不是 `CustomLyrics` 扩展里）：调用方是 URLSession 那两个钩子，
/// 它们拿到的是"这次响应到底交什么字节"这个纯数据问题，跟歌词仓库的加载逻辑无关。
/// 里面也不读任何隐藏 Spotify 官方歌词只决定**要不要顶掉官方歌词**，
/// 不决定"能不能一个字节都不给"。
///
/// - Parameter original: Spotify 原始响应解析出来的歌词（可能是 200 的官方歌词，
/// 也可能因为 404 而没有）。它只用来**沿用配色**，内容一律用我们自己的占位。
/// - Parameter note: 追加说明行，见 `CustomLyrics.makeUnavailableLyrics`。
/// - Returns: 可直接投给 `didReceiveData` 的字节；只有序列化失败这种理论上不会发生的
/// 情况才返回 nil（那时调用方退回原始响应）。
func unavailableLyricsBytes(original: Lyrics?, note: String? = nil) -> Data? {
    var lyrics = makeUnavailableLyrics(originalColors: original?.colors, note: note)
    // 404 场景下没有原始歌词可继承配色，给一套中性配色，
    // 避免客户端拿到全 0 颜色把整页刷成纯黑。
    if original == nil {
        lyrics.colors = LyricsColors.with {
            $0.backgroundColor = 0xFF12_1212
            $0.lineColor = 0xFF9E_9E9E
            $0.activeLineColor = 0xFFFF_FFFF
        }
    }

    guard let data = try? lyrics.serializedBytes() as Data else {
        writeErrorLog("[Lyrics] fallback payload failed to serialize — lyrics response will be dropped")
        return nil
    }

    urlSessionFallbackCount += 1
    if urlSessionFallbackCount <= 5 || urlSessionFallbackCount % 20 == 0 {
        writeDebugLog("[Lyrics] serving fallback payload for this response (#\(urlSessionFallbackCount))")
    }
    return data
}

func getLyricsDataForCurrentTrack(_ originalPath: String, originalLyrics: Lyrics? = nil) throws -> Data {
    writeDebugLog("[Lyrics] Request for \(originalPath)")

    // 署名先清空：这一次到底问过哪个源，要等 `requestSingleSource` 写回来。
    //
    // 为什么必须在这里清（而不是只靠 `loadCustomLyricsForCurrentTrack` 入口那次清）：
    // `trackMismatch` / `noCurrentTrack` 这两条是**早退**路径 —— 它们发生在进
    // `requestSingleSource` 之前，所以那个全局还留着**上一首**的值，占位就会署上一个
    // 这次根本没被问过的源（换歌瞬间那次占位就是这个）。
    // 清空后占位退回空串 —— 这正是 `makeUnavailableLyrics` 里那条
    // "还没问过任何源"兜底分支存在的意义。
    lastRequestedLyricsSourceDescription = ""

    guard !NgzhwmSettingsViewModel.isLyricsFeatureDisabled else {
        writeDebugLog("[Lyrics] Feature disabled — refusing")
        // 功能被关掉时同样要把逐词层清干净：否则它会继续盖着原生歌词显示旧内容。
        // ⚠️ `lookupFailed: false`：这是"用户把功能关了"，不是"没找到歌词" ——
        // 听歌页那层不该因此写「未找到歌词」。
        resetWordByWordLyrics(lookupFailed: false)
        throw LyricsError.invalidSource
    }

    // 非阻塞状态同步机制：解决启动/切歌时 track 状态尚未更新导致的
    // noCurrentTrack 与 trackMismatch 问题。
    //
    // ⚠️ 等待上限是 **3.0s**：换歌瞬间来的那次 color-lyrics 请求，1 秒内播放器还停在
    // 于是判
    // `trackMismatch`，那次响应被兜底成占位；紧接着客户端的第二次请求也照样失败，
    // 连页面元素清单都还是上一首。的就是"切歌后第一次预览歌词不对、重进才对"。
    //
    // 这里唯一能拿到的"这一首是谁"只有播放器 / 正在播放页（按 URI 反查元数据没有接口），
    // 所以只能多等：3s 覆盖"播放器元数据比歌词请求晚一拍"这个窗口。
    // 代价：这次响应最多被多留 3s（本来也会挂住到取词完成，18s 预算内）。
    var track = statefulPlayer?.currentTrack() ?? nowPlayingScrollViewController?.loadedTrack
    var trackIdentifier = track?.trackIdentifier ?? ""
    let maxWaitTime: TimeInterval = 3.0
    let startTime = Date()

    while Date().timeIntervalSince(startTime) < maxWaitTime {
        let isReady = track != nil &&
            (trackIdentifier.isEmpty || originalPath.contains(trackIdentifier))
        if isReady {
            break
        }

        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        track = statefulPlayer?.currentTrack() ?? nowPlayingScrollViewController?.loadedTrack
        trackIdentifier = track?.trackIdentifier ?? ""
    }

    guard let track = track else {
        throw LyricsError.noCurrentTrack
    }

    // 记下这一首的时长：占位文案的合成时间轴要用（那几步拿不到 track 对象）。
    // 与 `currentLyricsDto` 同一时机写入，语义都是"这一次请求的曲目"。
    currentTrackDurationMs = track.trackDurationMilliseconds

    // ── 切歌信号：**立刻**作废上一首的逐词层，不等新歌词
    //
    // 真机症状（PL / MXM / AMLL 三个源都能复现）：切歌后到新词到达之间，卡片与全屏的壳
    // 已经换成新歌，而我们的层还挂着**上一首的行模型**。根因是 `currentLyricsVersion`
    // 随**歌词数据**自增，"歌换了"在那一层里不可见。
    //
    // 用请求里的曲目 id 当切歌信号最可靠：歌词请求是**每首歌都会来一次**的（客户端
    // 缓存命中时不一定，那条路由 `AppleMusicLyricsOverlayHost` 里的 `hasForeignLineModel`
    // 每帧兜住）。命中即清 —— `resetWordByWordLyrics` 会摘掉新旧两层并把 dto 清空，
    // 于是看门狗的 `hasUsableWordLevelData` 判据也为假，不会拿旧数据把层挂回来。
    let requestedTrackId = track.trackIdentifier ?? ""
    if !requestedTrackId.isEmpty, requestedTrackId != lyricsLayerTrackId {
        let isTrackSwitch = lyricsLayerTrackId != nil
        lyricsLayerTrackId = requestedTrackId
        if isTrackSwitch {
            resetWordByWordLyrics(reason: "track changed (\(requestedTrackId))", lookupFailed: false)
        }
        // 切到新的一首 ⇒ 取词这一步重新开始（听歌页那层会写"正在查找歌词…"）。
        currentLyricsLookupState = .loading
    }

    if !trackIdentifier.isEmpty && !originalPath.contains(trackIdentifier) {
        throw LyricsError.trackMismatch
    }

    var lyrics: Lyrics
    // 真的开始查了（听歌页那层据此写"正在查找歌词…"）。
    currentLyricsLookupState = .loading
    do {
        lyrics = try loadCustomLyricsForCurrentTrack()
    } catch let error {
        // 这一首没能用上我们的歌词 → 决定**这次 HTTP 响应交什么出去**。
        //
        // 两种错误必须原样放行（它们跟"屏幕上这首歌有没有词"无关）：
        // · `.invalidSource` = 禁用歌词替换，要看官方歌词；
        // · `.noSuchSong` 等真·取词失败：交给下面的占位逻辑（「隐藏 Spotify 官方歌词」
        // 开着就顶掉官方歌词，关着就放行官方歌词）。
        //
        // ⚠️ `.trackMismatch` / `.noCurrentTrack` 以前也是"原样放行"，结果是这次请求
        // **一个字节都不投递**：Spotify 侧等不到歌词数据 → 不创建 NPV 歌词卡片 →
        // 连全屏歌词入口都没有（这就是"有些歌完全没有歌词模块"最重的那条路径）。
        // 现在它们也和其它失败一样，一定给出一份可解析的占位，保证卡片建得起来。
        let lyricsError = error as? LyricsError
        let shouldDropResponse = lyricsError == .invalidSource
        // 切歌竞态单独加一句说明："未找到歌词"时能立刻分清这不是词库的问题。
        let placeholderNote: String? = lyricsError == .trackMismatch ? "track_mismatch".localized : nil

        if !shouldDropResponse {
            resetWordByWordLyrics()
            // 别让 Spotify 把它自己的官方歌词顶上来 —— 用我们自己的占位替换掉。
            if let placeholder = unavailableLyricsPayload(original: originalLyrics) {
                writeDebugLog("[Lyrics] official lyrics hidden — serving our placeholder")
                return try placeholder.serializedBytes()
            }
            // 「隐藏官方歌词」关着 → 本来该放行官方歌词。但如果是 trackMismatch /
            // noCurrentTrack，连"官方歌词"都不能确定属于这一首，同样不能空手而归。
            if lyricsError == .trackMismatch || lyricsError == .noCurrentTrack {
                writeDebugLog("[Lyrics] \(lyricsError!) — serving fallback so the card is created")
                if let data = unavailableLyricsBytes(original: originalLyrics, note: placeholderNote) {
                    return data
                }
            }
        }
        throw error
    }

    let lyricsColorsSettings = UserDefaults.lyricsColors

    /// 这次用的是**我们自己算出来的颜色**（拿不到 Spotify 原始颜色：曲目 404、或用户关了
    /// 「显示原始颜色」）。它决定下面"清背景 alpha"那一步要不要跳过 —— 见那段注释。
    var usesSynthesizedColors = false

    if lyricsColorsSettings.displayOriginalColors, let originalLyrics = originalLyrics {
        writeDebugLog("[Lyrics] Using original colors")
        lyrics.colors = originalLyrics.colors
    } else {
        // 与占位 payload 走**同一个** `synthesizedLyricsColors`：这两条路必须给出一致的配色，
        // 否则又会分叉成"取不到词的曲目是黑块、取得到词的不是"（根因是两条路各写了一份、
        // 其中一份什么都不设）。
        lyrics.colors = synthesizedLyricsColors()
        usesSynthesizedColors = true
    }

    // 记录最终生效的歌词背景色（原始色或定制色），供逐字 overlay 复用，保证与原生模块同色。
    //
    // ⚠️ 必须在下面那个"清 alpha"之前读：overlay 要的是**原色**，
    // 拿去当自己的兜底底色 / 判断明暗，不能是透明值。
    currentLyricsBackgroundColorARGB = lyrics.colors.backgroundColor

    // ── 交给 Spotify 的那份背景色改成**全透明**
    //
    // 为什么：Spotify 拿这个值去刷原生歌词界面的背景 —— 包括**卡片面板**自己那层。
    // 而我们的层是"歌词视图的子视图"，**子视图永远盖不住父视图自己的背景**
    // （绘制顺序是"父视图的 backgroundColor 先画、子视图后画"），
    // 所以预览卡片顶部那条 39pt（「歌词」+ 分享/展开按钮那一行）永远是专辑纯色。
    //
    // 往卡片塞背景层 / 清容器底色 / 每帧重清 / 让我们的背景画到 bounds 之外，
    // 四种"盖住它"的办法全都无效 —— 因为问题不在层级，在绘制顺序。
    // 所以改成**让它别画**：把注入值的 alpha 清掉，面板就是透明，
    // 露出来的正好是我们已经铺在歌词区上的模糊封面。
    //
    // 只动 alpha（高 8 位），RGB 原样保留：
    // · 「歌词」标题与分享/展开按钮是**画在面板背景之上**的独立视图，
    // 颜色不受影响，位置和点击也不变；
    // · 我们自己的 overlay 用的是上面那个 `currentLyricsBackgroundColorARGB`（原值）。
    let injected = lyrics.colors.backgroundColor
    let transparentBackground = injected & 0x00FF_FFFF
    // 只在**不是**"自造颜色 + 已开补卡片元素"这个组合时清 alpha。
    let keepsOpaqueBackground = usesSynthesizedColors
        && NgzhwmSettingsViewModel.isLyricsCardElementInjectionEnabled
    if !keepsOpaqueBackground, transparentBackground != injected {
        lyrics.colors.backgroundColor = transparentBackground
        writeDebugLog(
            String(
                format: "[Lyrics] injected background %08X -> %08X (transparent)",
                injected, transparentBackground
            )
        )
    } else if keepsOpaqueBackground {
        // 为什么这里必须留着不透明：清 alpha 的**前提**是"我们的 overlay 会把模糊封面铺在
        // 卡片面板底下"（见上面那段）。
        // `inline host found` 从未出现过，清完 alpha 只会露出卡片自己的默认黑底
        // （卡片整块黑、歌词字看不见）。
        // 自造颜色这一支本来也没有"Spotify 的底"可以露，所以直接给不透明底色。
        writeDebugLog(
            String(
                format: "[Lyrics] keeping synthesized background opaque %08X (no overlay paints this card)",
                injected
            )
        )
    }

    // 歌词提供者**不在这里写**：它已经由 `storeLyricsDto(_:source:)` 与 dto 同时写好了
    // （`currentLyricsProvider`）。在这个函数末尾再写一次的话，写的是 `lyrics.data.providedBy`，
    // 而那份 protobuf 是**先前**构造的 —— 与 dto 分属两个时刻，正是"注解慢一拍"的老毛病。
    // 需要提供者时读 `currentLyricsProvider` / `currentLyricsDto?.providerName`。

    return try lyrics.serializedBytes()
}

/// 改完歌词偏移后，把**当前已经显示**的歌词按差值平移，并通知观察者重挂。
///
/// - 对**当前这份歌词实际来自的那个源**生效（Genius 除外：它压根没有偏移）。
/// - 只改内存里的 `currentLyricsDto`，不重新联网、不动仓库缓存。
/// - 必须在主线程：`currentLyricsDto` / `currentLyricsVersion` 是 UI 侧每拍在读的全局量。
///
/// 判据是"这份 dto 是哪个源给的"（`currentLyricsSource`）—— 用展示名反推是不行的
/// （"Spicy Lyrics" / "Apple Inc." 与 `LyricsSource` 不是一一对应）。
func reapplyLyricsTimingOffset() {
    onMainThreadSync {
        guard let source = currentLyricsSource,
              LyricsTimingOffset.supportsOffset(source: source) else { return }
        guard let dto = currentLyricsDto, !currentLyricsDtoTrackId.isEmpty else { return }

        let desired = LyricsTimingOffset.offsetMs(forTrackId: currentLyricsDtoTrackId, source: source)
        let delta = desired - currentLyricsTimingOffsetAppliedMs
        guard delta != 0 else { return }

        currentLyricsDto = dto.applyingTimingOffset(delta)
        currentLyricsTimingOffsetAppliedMs = desired
        currentLyricsVersion += 1
        WordByWordHost.shared.refreshForCurrentLyrics()
        writeDebugLog(
            "[Lyrics] timing offset re-applied — \(desired)ms"
                + " (delta \(delta)ms, source \(source.description))"
        )
    }
}
