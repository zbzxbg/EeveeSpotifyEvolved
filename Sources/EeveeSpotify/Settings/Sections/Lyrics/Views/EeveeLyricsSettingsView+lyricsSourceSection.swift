import SwiftUI

extension EeveeLyricsSettingsView {

    /// 「想用自己的 Spicy Lyrics 密钥」那个入口的地址。
    ///
    /// **我们自己的 app template 过审了**（提交与审核过程见那几轮讨论），
    /// 所以这里指向**目录页**而不是面板的 applications 页。用户要做的事只剩三步：
    /// 1. 打开这个目录页；
    /// 2. 「Sign in or create an account」——页面原话 *"You only need an account;
    /// you do not need to create an application."*（**不用建 application**，
    /// 也不用管 Client access / allowed origin / no-Origin 那些开关，模板里已经定好了）；
    /// 3. 按 Add → 页面给出 **Client key**（"You get: Client key"）→ 粘回本页输入框。
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

    /// 来源选择器的绑定。
    ///
    /// ⛔（填令牌弹窗**已删除**。
    /// 令牌输入框就在这个 Picker 下面（`musixmatchTokenField`），没有令牌时取词路径
    /// 也会自己换一个匿名令牌（`AnonymousTokenHelper`），没必要在选中的那一刻打断用户。
    /// 这里现在只负责把新来源写回 view model。
    ///
    /// 直接读写 `viewModel.lyricsSource`，而不是绑 `UserDefaults.lyricsSource`：
    /// 后者是持久化的那份，`$lyricsSource` 的 `didSet` 才写它，两者在某些时序上会不一致。
    private var lyricsSourceBinding: Binding<LyricsSource> {
        Binding(
            get: { viewModel.lyricsSource },
            set: { viewModel.lyricsSource = $0 }
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

        // Taurus 有、我们原来缺的四个源。顺序与选择器里一致。
        text.append("\n")
        text.append("bini_description".localized)

        text.append("\n")
        text.append("unison_description".localized)

        text.append("\n")
        text.append("qqmusic_description".localized)

        text.append("\n")
        text.append("kugou_description".localized)

        // 「听歌页样式是 spotify 原生时，自动优选不可选择」。
        // 选项本身会被滤掉（见 `lyricsSourceSection`），所以这里也不能再介绍它 ——
        // 换成一句"为什么没有它"，否则用户只会以为功能丢了。
        text.append("\n")
        if LyricsSource.autoSelect.isAvailableInCurrentNowPlayingStyle {
            text.append("lyrics_source_auto_description".localized)
        } else {
            text.append("lyrics_source_auto_unavailable".localized)
        }
        
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
                    // 听歌页样式为「Spotify 原生」时**不提供**「自动优选」
                    // （`isAvailableInCurrentNowPlayingStyle`）。SwiftUI 的 Picker 不能单独
                    // 禁用某一行，所以这里直接把它滤掉，并在 footer 里说明原因。
                    ForEach(
                        LyricsSource.allCases.filter(\.isAvailableInCurrentNowPlayingStyle),
                        id: \.self
                    ) { lyricsSource in
                        Text(lyricsSource.description).tag(lyricsSource)
                    }
                }

                // 「金牛座那边可以自己排序歌词来源」——
                // 顺序只对「自动优选」有意义，所以只在选中它时出现。
                if viewModel.lyricsSource == .autoSelect {
                    NavigationLink(destination: LyricsSourceOrderView()) {
                        HStack {
                            Image(systemName: "arrow.up.arrow.down")
                            Text("lyrics_source_order".localized)
                        }
                    }
                }

                // 自动优选链路包含 Musixmatch / LRCLIB / Spicy Lyrics，
                // 所以这三项的配置都要能在这里改 —— 否则自动优选
                // 就再也改不到 MxM 令牌、LRCLIB 地址与 Spicy 密钥了。
                if viewModel.lyricsSource == .musixmatch || viewModel.lyricsSource == .autoSelect {
                    musixmatchTokenField()
                }
                
                if viewModel.lyricsSource == .lrclib || viewModel.lyricsSource == .autoSelect {
                    lrclibURLField()
                }

                if viewModel.lyricsSource == .spicy || viewModel.lyricsSource == .autoSelect {
                    spicyLyricsKeyField()
                }
            }
        }
    }

    /// SpicyLyrics 官方 API 的客户端密钥输入框。
    ///
    /// **本仓库不内置默认密钥**，这一栏是"用 SpicyLyrics 的前提"。
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
            // 所以这里必须**教用户怎么拿**（上游也是这么做的）—— 那句说明下面那颗 `Link` 就是入口，
            // 见 `spicyKeyHelp`。
            spicyKeyHelp()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 「想用自己的密钥」那段说明 —— 说明是**纯文本**，入口是**单独一行 `Link`**。
    ///
    /// ⇒ 改成**结构上不依赖译文**：说明永远是纯文本、入口是独立一行 `Link`。
    /// （List 里 `Link` 自己吃点击；`Text` 里嵌的 link 在 List 行里本来就常常点不动 ——
    /// 那是旧做法在别的语言里迟早会翻车的另一个原因。）
    ///
    /// ⚠️ 地址现在是**我们自己的 app template 目录页**（`developers.spicylyrics.org/catalog/
    /// eeveespotifyevolved`）：用户只需登录/注册 → 按 Add → 复制它给出的 Client key
    /// （**不用**建 application、也不用管 Client access / Origin 那几项，模板里已经定好）。
    @ViewBuilder private func spicyKeyHelp() -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("spicylyrics_api_key_description".localized)
                .font(.footnote)
                .foregroundColor(.secondary)

            if let url = Self.spicyKeyHelpURL {
                Link(destination: url) {
                    HStack(spacing: 4) {
                        Text("spicylyrics_key_link".localized)
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .font(.footnote)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    
    /// Musixmatch 用户令牌输入框。
    ///
    /// ⚠️ 这里的注释在改过一次：原先写"「请求匿名令牌」按钮已整体移除、
    /// 现在令牌**只能手填**"，但**下面 `:196-212` 又把它接回来了**，
    /// 文档与代码不一致。当前实况是：
    /// · 令牌**可以**手填（这一栏）；
    /// · 没填 / 填得不合法时，多出一颗「请求匿名令牌」按钮（只在
    /// `!viewModel.isMusixmatchTokenValid` 时显示）；
    /// · 请求期间只禁**那颗按钮**（旧版会把整页 `.disabled`）。
    /// 见 `AnonymousTokenHelper` 文件头：没有匿名令牌这条退路，
    /// "没填 SpicyLyrics 密钥 ⇒ 本首改用 Musixmatch"对用户就是一句空话。
    @ViewBuilder private func musixmatchTokenField() -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("musixmatch_user_token".localized)
            
            TextField("user_token_placeholder".localized, text: $viewModel.musixmatchToken)
                .foregroundColor(.gray)

            // 把「请求匿名令牌」接回来（见 `AnonymousTokenHelper` 文件头 ——
            // 没有它，"没填 SpicyLyrics 密钥 → 改用 Musixmatch"这条回退对用户就是空话）。
            // 只在"还没有合法令牌"时显示：已经有令牌的人不需要它。
            // ⚠️ 旧版请求期间会把**整页** `.disabled`；现在只禁这颗按钮。
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
