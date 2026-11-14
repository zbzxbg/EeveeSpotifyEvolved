import Foundation
import SwiftUI

struct EeveeLyricsSettingsView: View {
    @StateObject var viewModel = EeveeLyricsSettingsViewModel()

    var body: some View {
        List {
            wordByWordLyricsSection()

            // 「更好的逐词歌词」是「开启逐词歌词」的子项：**必须紧跟主开关**，
            // 中间不插别的 section。主开关没开时整项不展示
            // （与下面 NetEase 那几项同一套写法）。
            if viewModel.wordByWordLyrics {
                betterWordByWordLyricsSection()
            }

            lyricsSourceSection()
            
            // 「禁用歌词功能」作为「禁用歌词替换功能」的二级菜单：
            // 仅当「禁用歌词替换功能」开启（lyricsSource == .notReplaced）时显示，
            // 写法与文件里其它条件项一致（见 `betterWordByWordLyricsSection` 的入口）。
            if viewModel.lyricsSource == .notReplaced {
                disableLyricsSection()
            }
            
            // （设置页里面放个可点击进去的页面吧）：歌词偏移
            // 从本页拆出去成了独立页（`EeveeLyricsOffsetSettingsView`，起
            // 对所有源生效），入口在根设置页「播放与歌词」组里，与「歌词 / 听歌页 /
            // 补丁」那些并排。
            //
            // 这里原来还有一个「修改 NetEase 日语罗马字展示方式」的开关
            // （`neteaseRomajiLocalSection`），只对 NetEase / 自动优选显示。
            // 2026-11-08 整体删除：默认值本来就是"用官方 romalrc"，开关只会把
            // 更好的官方罗马字换成更差的本地转换 ⇒ 空壳。键与 l10n 一并摘掉。
            
            if viewModel.lyricsSource != .notReplaced {
                // 译文行的开关放在通用区最前面：它对**所有源**生效
                // （`showsTranslationNow` 不看 source），不是网易云专属。
                lyricsHideTranslationSection()

                // 「AMLL 优先」需要有一个「用户自己选的源」作为回退目标，
                // 所以来源为 Genius / 自动优选 / LRCLIB / AMLL 时不展示。
                // （曾整段删除，已恢复）。
                if viewModel.lyricsSource != .genius
                    && viewModel.lyricsSource != .autoSelect
                    && viewModel.lyricsSource != .lrclib
                    && viewModel.lyricsSource != .amllTtml {
                    amllPreferredSection()
                }
                
                // Genius 回退保持原有条件：自动优选链路本身以 Genius 收尾，
                // 不再重复提供该开关；来源为 Genius 时自己回退给自己没有意义。
                if viewModel.lyricsSource != .genius && viewModel.lyricsSource != .autoSelect {
                    geniusFallbackSection()
                }
                
                hideOnErrorSection()
                // 「补时间轴」/「补卡片元素」/「强制歌词入口」三个**排查型**开关
                // 已挪到「调试」页（见 `EeveeDebugSettingsViewModel`）：
                // 它们验证完就该写死或删掉，放在用户偏好旁边只会让人面对一堆不该动的东西。
                // ⚠️ 它们的 UserDefaults key 没有变，设备上已设的值原样保留。
                // 「隐藏官方歌词」已写死启用（见 `NgzhwmSettingsViewModel` 里那个
                // getter），不再有开关。
                romanizationSection()

                // 源没给译文时，用 Apple 的翻译框架
                // 在手机上翻一遍（纯本地）。只处理"每行都有时间轴"的歌词。
                lyricsAutoTranslateSection()
                
                // 自动优选链路包含 Musixmatch，其语言项同样可配置。
                if viewModel.lyricsSource == .musixmatch || viewModel.lyricsSource == .autoSelect {
                    musixmatchLanguageSection()
                }

            }
            
            // 已移除一节：「删除间奏符号 ♪」那颗 Toggle。
            // 它的行为已经无条件生效（间奏行整行丢弃），开关留着只是个空壳 ——
            // 键、属性、绑定日志与 l10n 一起摘掉，理由见 `NgzhwmSettingsViewModel` 顶部。
            
            NonIPadSpacerView()
        }
        // ⚠️ 不要加 `.onReceive(viewModel.musixmatchTokenInputAlertPublisher)`，
        // 用 `showAnonymousTokenOption` 决定弹窗里要不要显示「请求匿名令牌」。
        // 那个 publisher 全工程没有任何一处 `send`（死订阅），而匿名令牌选项本身
        // 也已整体移除 —— 两个一起去掉。
        // 手动填令牌的弹窗保留，改由下面这个绑定在"选中 Musixmatch 那一刻"调用。
        // inset-grouped（胶囊卡片）—— 为什么、怎么做的见 `EeveeSettingsView` 顶部那段
        .listStyle(InsetGroupedListStyle())
        .animation(.default, value: viewModel.animationValues)
    }
    
    @ViewBuilder private func wordByWordLyricsSection() -> some View {
        Section(
            footer: Text("word_by_word_lyrics_description".localized)
        ) {
            Toggle(
                "word_by_word_lyrics".localized,
                isOn: $viewModel.wordByWordLyrics
            )
        }
    }

    /// iOS 26 起才有 `AppleMusicLyricsOverlay`
    /// （`AppleMusicLyricsOverlay.isAvailable` 里那道 `#available` 是同一判据）。
    private static var supportsBetterWordByWordLyrics: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }

    /// 「更好的逐词歌词」：**跟着主开关显示/隐藏的子项**，不单独占一个平级位置。
    ///
    /// 与文件里其它条件项同一套写法（例如
    /// `if viewModel.lyricsSource == .notReplaced { disableLyricsSection() }`）：
    /// 逐词歌词没开时它没有任何意义，所以整项不展示，而不是置灰。
    ///
    /// 页脚里把"开启后自动带上什么"说清楚，免得用户去找已经不存在的
    /// 模糊封面 / 系统材质开关（那两个已改为跟随本项自动启用）。
    ///
    /// ⚠️ 文案 key 是 `_description` 而不是 `_footer`：本文件里所有页脚都用
    /// `<开关名>_description`（逐词歌词、更好的逐词歌词、禁用歌词、多级回退……一致）。
    /// 不要再加 `ngzhwm_better_word_by_word_lyrics_footer`：那是**同一个开关
    /// 两份文案** —— 改文案时只改一处、另一处悄悄过期，正是那种"看起来改过了、
    /// 界面上还是旧话"的坑。现在合并成一条。
    @ViewBuilder private func betterWordByWordLyricsSection() -> some View {
        Section(
            footer: betterWordByWordLyricsFooter()
        ) {
            Toggle(
                "better_word_by_word_lyrics".localized,
                isOn: $viewModel.betterWordByWordLyrics
            )
            // 低版本上这一项**不生效**（渲染层直接 `#available` 返回 false）。
            // 置灰而不是隐藏：开关的状态仍然要看得见，否则用户会以为"我明明开过"。
            .disabled(!Self.supportsBetterWordByWordLyrics)
        }
    }

    private func betterWordByWordLyricsFooter() -> Text {
        var text = "better_word_by_word_lyrics_description".localized
        if !Self.supportsBetterWordByWordLyrics {
            text += "\n\n" + "better_word_by_word_lyrics_needs_ios26".localized
        }
        text += "\n\n" + "lyrics_appearance_hint".localized
        return Text(text)
    }

    @ViewBuilder private func disableLyricsSection() -> some View {
        Section(
            footer: Text("disable_lyrics_feature_description".localized)
        ) {
            Toggle(
                "disable_lyrics_feature".localized,
                isOn: $viewModel.disableLyricsFeature
            )
        }
    }
    
    @ViewBuilder private func geniusFallbackSection() -> some View {
        Section {
            Toggle(
                "genius_fallback".localized,
                isOn: $viewModel.lyricsOptions.geniusFallback
            )
            
        } footer: {
            Text("genius_fallback_description"
                .localizeWithFormat(viewModel.lyricsSource.description))
        }
    }
    
    /// 「AMLL 优先」：勾选后先向 AMLL 要逐词歌词，没正常返回再回退到
    /// 在来源选择器里设置的那个源。选项依赖逐词歌词，未开启时整体禁用。
    ///
    /// （曾整段删除、连带两个 l10n 键，已恢复）。
    @ViewBuilder private func amllPreferredSection() -> some View {
        Section {
            Toggle(
                "amll_preferred".localized,
                isOn: $viewModel.amllPreferred
            )
            .disabled(!viewModel.wordByWordLyrics)
        } footer: {
            Text("amll_preferred_description".localized)
        }
    }
    
    @ViewBuilder private func romanizationSection() -> some View {
        Section(
            footer: Text("romanization_description".localized)
        ) {
            Toggle("chinese_romanization".localized, isOn: $viewModel.chineseRomanization)
            Toggle("japanese_romanization".localized, isOn: $viewModel.japaneseRomanization)
            Toggle("korean_romanization".localized, isOn: $viewModel.koreanRomanization)
        }
    }

    /// **歌词系统翻译**（Apple `Translation` 框架，纯本地）。
    ///
    /// 只对"源自己没给译文"的歌词生效，翻完在每行原文下面多一行译文。
    /// 要求：**iOS 26+**（`TranslationSession` 的公开初始化器从 26.0 才有，不是 18），
    /// 且设置 → App → 翻译 → 语言里下好两种语言。
    @ViewBuilder private func lyricsAutoTranslateSection() -> some View {
        Section {
            Toggle(
                "lyrics_auto_translate".localized,
                isOn: $viewModel.lyricsAutoTranslate
            )
            // ⚠️ iOS 26 以下这颗开关**什么都不做**（`TranslationSession` 没有公开构造入口）。
            // 置灰而不是藏起来：footer 已经写明版本要求，藏起来只会让人以为功能被删了。
            .disabled(!OnDeviceLyricsTranslation.isAvailable)
        } footer: {
            Text("lyrics_auto_translate_description".localized)
        }
    }

    @ViewBuilder private func hideOnErrorSection() -> some View {
        Section {
            Toggle(
                "hide_lyrics_on_error".localized,
                isOn: $viewModel.lyricsOptions.hideOnError
            )
        } footer: {
            Text("hide_lyrics_on_error_description".localized)
        }
    }

    // 已移除两个 Section：`injectLyricsCardElementSection` /
    // `lyricsEntryPointFlagSection` —— 它们是**排查/验证型**开关，已整体挪到
    // 「调试」页（`EeveeDebugSettingsView`）。key 与 l10n 都没变，用户已设的值照旧生效。
    // 同批**删除**的 `syntheticLineTimingSection`（「补全歌词时间轴」）是另一回事：
    // 验证完毕、功能整体删掉，key 与 l10n 也一起删了，不再有任何入口。
    //
    // 已移除一个 Section：`hideOfficialLyricsSection` ——
    // 它的开关价值只在"验证修复有没有用"那一步，验证完就写死启用了。
    // 那个 l10n 键也一并删除（见 en/zh-CN 的 Localizable.strings）。

    // 已删除一个 Section：`neteaseRomajiLocalSection`（「修改 NetEase 日语罗马字的展示方式」）。
    // 删它的理由与「补全歌词时间轴」那批不同：那个是"验证完就写死"，
    // 这个是**它的默认值本来就是对的** —— 官方 `romalrc` 是人工整理的行级罗马字，
    // 比本地 CFS 管线准；开关唯一的作用是把好的换成差的。键与 l10n 一起摘掉。

    /// 「隐藏歌词译文」——**对所有源生效**，不是网易云专属。
    ///
    /// 判据落在两个自绘层里（`AppleMusicLyricsOverlayView.showsTranslationNow` /
    /// `LyricsWordByWordOverlayView`），它们都不看来源。
    /// 交给 Spotify 原生页的那一份不受影响：只有逐行歌词才会把译文递出去，
    /// 那边由它自己的翻译按钮管。
    @ViewBuilder private func lyricsHideTranslationSection() -> some View {
        Section(
            footer: Text("lyrics_hide_translation_description".localized)
        ) {
            Toggle(
                "lyrics_hide_translation".localized,
                isOn: $viewModel.hideLyricsTranslation
            )
        }
    }

    @ViewBuilder private func musixmatchLanguageSection() -> some View {
        Section {
            HStack {
                Text("musixmatch_language".localized)
                
                Spacer()
                
                TextField("en", text: $viewModel.lyricsOptions.musixmatchLanguage)
                    .frame(maxWidth: 20)
                    .foregroundColor(.gray)
            }
            .icon(
                "exclamationmark.triangle.fill",
                color: .yellow,
                when: $viewModel.showMusixmatchInvalidLanguageWarning
            )
        } footer: {
            Text("musixmatch_language_description".localized)
        }
    }

}
