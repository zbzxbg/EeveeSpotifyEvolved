import SwiftUI

extension EeveeLyricsSettingsView {

    /// 「想用自己的 Spicy Lyrics 密钥」那个入口的地址。
    ///
    /// ★ 2026-10-13：**我们自己的 app template 过审了**（提交与审核过程见那几轮讨论），
    /// 所以这里指向**目录页**而不是面板的 applications 页。用户要做的事只剩三步：
    ///   1. 打开这个目录页；
    ///   2. 「Sign in or create an account」——页面原话 *"You only need an account;
    ///      you do not need to create an application."*（**不用建 application**，
    ///      也不用管 Client access / allowed origin / no-Origin 那些开关，模板里已经定好了）；
    ///   3. 按 Add → 页面给出 **Client key**（"You get: Client key"）→ 粘回本页输入框。
    ///
    /// 为什么这样最合规：条款 §12 对"要分发到别人设备上的应用"推荐的就是这条，§3 也不许共用
    /// 密钥 —— 模板让**每个人拿到自己的一份**，且每人各自有速率上限（不会挤在同一个 key 上）。
    ///
    /// 上游的对照：他们指向自己的模板
    /// `https://developers.spicylyrics.org/catalog/eeveespotifyreincarnated`，做法相同。
    ///
    /// ⚠️ 仍然保留"自己建 application"这条后路（面板 → applications，开 Client access +
    /// 允许无 Origin 头）—— 想用自己额度、或目录页临时不可用时，用户仍然能拿到 `sl_pk_`；
    /// 文案里没有提它，是因为三步那条路对绝大多数人更短。
    private static let spicyKeyHelpURL = URL(string: "https://developers.spicylyrics.org/catalog/eeveespotifyevolved")

    /// 来源选择器的绑定：额外负责"选中 Musixmatch 但还没有令牌"时的手动填写提示。
    ///
    /// 为什么要有它：以前这个提示挂在一个**从来没被 `send` 过**的
    /// `musixmatchTokenInputAlertPublisher` 上（见 `showMusixmatchTokenAlert` 的说明），
    /// 于是选了 Musixmatch 只会看到来源页一个红色感叹号，弹窗永远不出现。
    /// 现在把提示放在"用户真的选中那一刻"。
    ///
    /// ★ 2026-10-13：**弹窗不再"不填就回退选择"** —— 匿名令牌那条路已经接回来了
    /// （`AnonymousTokenHelper`：取词时自动换一个，见 `MusixmatchLyricsRepository.ensureTokenIfNeeded`），
    /// 填自己的令牌只是"想用自己的额度"。所以取消/填错都**保留** Musixmatch 这个选择。
    ///
    /// 用 `viewModel.lyricsSource` 作为"旧值"而不是 `UserDefaults.lyricsSource`：
    /// 后者是持久化的那份，`$lyricsSource` 的 `didSet` 才写它，两者在某些时序上会不一致。
    private var lyricsSourceBinding: Binding<LyricsSource> {
        Binding(
            get: { viewModel.lyricsSource },
            set: { newSource in
                viewModel.lyricsSource = newSource

                if newSource == .musixmatch, !viewModel.isMusixmatchTokenValid {
                    showMusixmatchTokenAlert()
                }
            }
        )
    }

    private func lyricsSourceFooter() -> some View {
        var text = "lyrics_source_description".localized

        text.append("\n")
        text.append("petitlyrics_description".localized)

        text.append("\n")
        text.append("spicylyrics_description".localized)

        text.append("\n")
        text.append("netease_description".localized)

        text.append("\n")
        text.append("amll_description".localized)

        text.append("\n")
        text.append("ngzhwm_multi_level_fallback_description".localized)
        
        text.append("\n\n")
        text.append("lyrics_additional_info".localized)
        
        return Text(text)
    }
    
    @ViewBuilder func lyricsSourceSection() -> some View {
        Section {
            Toggle(
                "do_not_replace_lyrics".localized,
                isOn: Binding<Bool>(
                    get: { viewModel.lyricsSource == .notReplaced },
                    set: {
                        viewModel.lyricsSource = $0
                            ? .notReplaced
                            : LyricsSource.defaultSource
                    }
                )
            )
        } footer: {
            Text("do_not_replace_lyrics_description".localized)
        }
        
        if viewModel.lyricsSource.isReplacingLyrics {
            Section(footer: lyricsSourceFooter()) {
                Picker(
                    "lyrics_source".localized,
                    selection: lyricsSourceBinding
                ) {
                    ForEach(LyricsSource.allCases, id: \.self) { lyricsSource in
                        Text(lyricsSource.description).tag(lyricsSource)
                    }
                }

                // 多级回退链路包含 Musixmatch / LRCLIB，所以这两项也要能配置。
                if viewModel.lyricsSource == .musixmatch || viewModel.lyricsSource == .multiLevel {
                    musixmatchTokenField()
                }
                
                if viewModel.lyricsSource == .lrclib || viewModel.lyricsSource == .multiLevel {
                    lrclibURLField()
                }

                // 只在真的会用到 SpicyLyrics 时给密钥栏（多级回退链路里没有它）。
                if viewModel.lyricsSource == .spicy {
                    spicyLyricsKeyField()
                }
            }
        }
    }

    /// SpicyLyrics 官方 API 的客户端密钥输入框。
    ///
    /// ★ 2026-10-13（用户拍板）：**本仓库不内置默认密钥**，这一栏是"用 SpicyLyrics 的前提"。
    /// **留空**时这个源会被跳过、这一首改用 **Musixmatch**（见
    /// `CustomLyrics.loadCustomLyricsForCurrentTrack` 里那一段替换）—— 不会去走 SpicyLyrics
    /// 那条被条款禁止的内部接口。见 `UserDefaults.spicyLyricsApiKey` 与
    /// `SpicyLyricsRepository` 的文件头。
    @ViewBuilder private func spicyLyricsKeyField() -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("spicylyrics_api_key".localized)

            TextField(
                "spicylyrics_api_key_placeholder".localized,
                text: $viewModel.spicyLyricsApiKey
            )
            .foregroundColor(.gray)
            .autocapitalization(.none)
            .disableAutocorrection(true)

            // SL 的条款（§3/§12）：key 不许共用；要分发到别人设备上，正解是让每个人**各自**
            // 拿一份 key（提交 app template），而不是把你的 key 打包发出去。
            // 所以这里必须**教用户怎么拿**（上游也是这么做的）—— 那句说明里的
            // 「开发者面板」是可点的，见 `spicyKeyHelpText()`。
            spicyKeyHelpText()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 「想用自己的密钥」那段说明 —— 把里面那句**开发者面板**做成可点链接。
    ///
    /// 做法照上游：文案与链接文本**一起本地化**，再按链接文本自己的 key 在字符串里找那一段
    /// 贴上 `link`。好处是译文可以自由调整语序，不必维护 `%@` 的位置。
    ///
    /// ⚠️ 现在指向的是**面板的 applications 页**：任何账号都能在那里建 application、
    /// 开 Client access、打开 "Allow requests with no Origin header"，拿到自己的 `sl_pk_`。
    /// 等我们自己的 **app template** 过审之后，把 `spicyKeyHelpURL` 换成
    /// `https://developers.spicylyrics.org/catalog/<slug>`、并同步改文案即可 ——
    /// 那时用户只需点一下 Add（条款 §12 对"要分发的应用"推荐的正是这条）。
    private func spicyKeyHelpText() -> Text {
        let raw = "spicylyrics_api_key_description".localized
        let linkText = "spicylyrics_key_link".localized
        var attributed = AttributedString(raw)

        if let url = Self.spicyKeyHelpURL, let range = attributed.range(of: linkText) {
            // 只贴 `link`：SwiftUI 会照 app 的 tint 把这一段画成可点链接，不额外设下划线
            // （`underlineStyle` 在两个 attribute scope 里类型不同，能不碰就不碰）。
            attributed[range].link = url
        } else {
            // 找不到那一段（比如译文只翻了说明、没照抄那句链接文本）⇒ 退化成纯文本，
            // **不静默丢掉整句说明**，并把地址原样附在末尾（至少用户能看见/复制）。
            writeDebugLog("[Settings] spicy key help link text missing in this locale — showing the raw URL")
            if let url = Self.spicyKeyHelpURL {
                attributed.append(AttributedString("\n" + url.absoluteString))
            }
        }

        return Text(attributed).font(.footnote).foregroundColor(.secondary)
    }
    
    /// Musixmatch 用户令牌输入框。
    ///
    /// ⚠️ 这里原来还有一个「请求匿名令牌」按钮（`requestAnonymousMusixmatchToken()`，
    /// 带转圈状态与整页 `.disabled`）—— 已整体移除。现在令牌**只能手填**，
    /// 所以那一行红色感叹号的意义更直接了：没填或填错，Musixmatch 就用不了。
    @ViewBuilder private func musixmatchTokenField() -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("musixmatch_user_token".localized)
            
            TextField("user_token_placeholder".localized, text: $viewModel.musixmatchToken)
                .foregroundColor(.gray)

            // ★ 2026-10-13：把「请求匿名令牌」接回来（见 `AnonymousTokenHelper` 文件头 ——
            //   没有它，"没填 SpicyLyrics 密钥 → 改用 Musixmatch"这条回退对用户就是空话）。
            //   只在"还没有合法令牌"时显示：已经有令牌的人不需要它。
            //   ⚠️ 旧版请求期间会把**整页** `.disabled`；现在只禁这颗按钮。
            if !viewModel.isMusixmatchTokenValid {
                Button {
                    viewModel.requestAnonymousMusixmatchToken()
                } label: {
                    HStack(spacing: 8) {
                        if viewModel.isRequestingMusixmatchToken {
                            ProgressView().controlSize(.small)
                        }
                        Text("request_anonymous_token".localized)
                    }
                }
                .disabled(viewModel.isRequestingMusixmatchToken)

                Text("request_anonymous_token_description".localized)
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
        .icon(
            "exclamationmark.circle",
            color: .red,
            when: Binding<Bool>(
                get: { !viewModel.isMusixmatchTokenValid },
                set: { _ in }
            )
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    
    @ViewBuilder private func lrclibURLField() -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("lrclib_api".localized)
            
            TextField(LrclibLyricsRepository.originalApiUrl, text: $viewModel.lyricsOptions.lrclibUrl)
                .foregroundColor(.gray)
        }
        .icon(
            "exclamationmark.circle",
            color: .red,
            when: Binding<Bool>(
                get: {
                    viewModel.lrclibURLState == .invalidURL
                    || viewModel.lrclibURLState == .unreachableURL
                },
                set: { _ in }
            )
        )
        .icon(
            "checkmark.seal",
            color: .green,
            when: Binding<Bool>(
                get: { viewModel.lrclibURLState == .originalURL },
                set: { _ in }
            )
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
