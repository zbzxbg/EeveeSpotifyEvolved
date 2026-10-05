import SwiftUI
import UIKit

/// 「听歌页」——听歌页（Now Playing）上所有属于**我们自己的**开关。
///
/// ## 为什么单独一页（2026-10-13 用户：「设置页面有点乱了」，拍板方案 B）
///
/// 这些开关原来全塞在「扩展」那一页里（`EeveeExtrasSettingsView`，627 行、24 个开关 +
/// 8 个子页入口），而「扩展」在根页只占一行 ⇒ 想找"听歌页那一屏"要进两层、还要在
/// 一页里滚很久。现在按**页面**拆开：听歌页 / 标签栏与迷你条 / 首页与音乐库 /
/// 歌单与专辑页，四个都在根页上一步可达。
///
/// 本页三节：
///   · `now_playing_section` —— 听歌页自己的九个开关（取色底 / 一屏 / 音量条 /
///     歌词进播放器 / 单行歌词 / 罗马化 / 译文 / 未播放行模糊 / 控制键字形）；
///   · `declutter_description` —— 按类名藏 Spotify 自己的 chrome（迷你条/跟唱行/胶囊）。
///
/// ⚠️ 罗马化与译文那两颗读的是**歌词页那批键**（`NgzhwmSettingsViewModel` 的
/// `anyRomanizationEnabled` / `isNeteaseHideTranslationEnabled`），两面永远同步。
/// 因此它们**不在本页的「重置本页」里** —— 重置本页不该偷偷改掉歌词页的设置。
struct NowPlayingSettingsView: View {

    /// 本页所有开关的**影子值**。为什么需要、怎么用见 `settingsShadowBinding` 的文件头。
    @State private var shadow = Shadow()

    private struct Shadow {
        var nowPlayingBackdrop = UserDefaults.nowPlayingBackdrop
        var nowPlayingOneScreen = UserDefaults.nowPlayingOneScreen
        var nowPlayingVolume = UserDefaults.nowPlayingVolume
        var nowPlayingLyricsInPlayer = UserDefaults.nowPlayingLyricsInPlayer
        var nowPlayingSingleLyric = UserDefaults.nowPlayingSingleLyric
        var nowPlayingBlurUnplayedLyrics = UserDefaults.nowPlayingBlurUnplayedLyrics
        var nowPlayingControlGlyphs = UserDefaults.nowPlayingControlGlyphs
        // 与「设置 → 歌词」那两颗**同一批键**（不是新造的一套）。
        var showRomanizedLyrics = NgzhwmSettingsViewModel.anyRomanizationEnabled
        var showLyricsTranslation = !NgzhwmSettingsViewModel.isNeteaseHideTranslationEnabled
        var hideMiniPlayerBar = UserDefaults.hideMiniPlayerBar
        var hideSingalongLine = UserDefaults.hideSingalongLine
        var hideNowPlayingPills = UserDefaults.hideNowPlayingPills
    }

    var body: some View {
        List {
            // 听歌页：仿 Apple Music 的**整页取色渐变底**。
            // 借鉴来源与"为什么不模糊"写在 `NowPlayingBackdrop` 的文件头。
            Section(
                header: Text("now_playing_section".localized),
                footer: Text("now_playing_section_description".localized)
            ) {
                Toggle(
                    "now_playing_backdrop".localized,
                    isOn: settingsShadowBinding($shadow.nowPlayingBackdrop) { value in
                        UserDefaults.nowPlayingBackdrop = value
                        // 关掉要**当场**还原（不用等下一次进听歌页）；
                        // 打开就顺手刷一次，用户可以在听歌页里立刻看到。
                        if value {
                            refreshNowPlayingBackdrop()
                        } else {
                            NowPlayingBackdrop.remove(reason: "switch off")
                        }
                    }
                )

                // 一屏：把播放器下面那些卡片折起来 + 把列表钉在它的顶部
                // （kumone / Music app 那种"一屏一首歌、滚不动"）。
                // 思路与算法借自 spoti.pw v0.21.1（GPL-3.0），写在 `NowPlayingOneScreen` 文件头。
                // ★ 2026-10-12（用户问「那个一屏的介绍换成什么了来着」）：那段说明原本挂在
                //   分区的 footer 上，分区改成通用说明之后就**没地方显示了** —— 现在挂回
                //   **这一颗开关自己**：写成标签里的第二行小字（同 Section 里还有别的开关，
                //   不能只为它加 Section footer）。
                Toggle(
                    isOn: settingsShadowBinding($shadow.nowPlayingOneScreen) { value in
                        UserDefaults.nowPlayingOneScreen = value
                        // 关掉要**当场**把 inset 写回（不用等下一次进听歌页）；
                        // 打开就顺手落地一次。
                        if value {
                            NowPlayingOneScreen.reapply()
                        } else {
                            NowPlayingOneScreen.restore()
                        }
                    }
                ) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("now_playing_one_screen".localized)
                        Text("now_playing_one_screen_description".localized)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                // 底部音量条：kumone 播放页下半屏的那一条（Apple Music 没有）。
                // 落在**我们自己的透明覆盖层**上（`NowPlayingPageOverlay`），不碰 Spotify 属性。
                Toggle(
                    "now_playing_volume".localized,
                    isOn: settingsShadowBinding($shadow.nowPlayingVolume) { value in
                        UserDefaults.nowPlayingVolume = value
                        // 打开就当场落地（页面还挂着的话），关掉当场把那一层拿走。
                        if value {
                            NowPlayingPageOverlay.reapply()
                        } else {
                            NowPlayingPageOverlay.remove(reason: "switch off")
                        }
                    }
                )

                // 歌词进播放器：把**我们自己的**逐词歌词画进播放器中段
                // （`npv.bottomStackView` 之上那块），这样「一屏」折掉卡片后页面上仍有歌词。
                // 渲染复用内嵌那一档（背景透明），宿主是 `NowPlayingLyricsPlate` 自己的一份。
                Toggle(
                    "now_playing_lyrics_in_player".localized,
                    isOn: settingsShadowBinding($shadow.nowPlayingLyricsInPlayer) { value in
                        UserDefaults.nowPlayingLyricsInPlayer = value
                        // 打开就当场落地（页面还挂着的话），关掉当场把我们的容器拿走。
                        if value {
                            NowPlayingLyricsPlate.reapply()
                        } else {
                            NowPlayingLyricsPlate.remove(reason: "switch off")
                        }
                    }
                )

                // ★ 2026-10-04（用户建议的第二条）：收起歌词那一屏，在**大封面与歌词键之间**
                // 画一行居中的当前歌词（"类似 Spotify 的单行歌词，但这行歌词我们自己画"）。
                // 落点是封面底边与控件条上沿的中点，做法见 `NowPlayingLyricsPlate.applySingleLyric`。
                Toggle(
                    "now_playing_single_lyric".localized,
                    isOn: settingsShadowBinding($shadow.nowPlayingSingleLyric) { value in
                        UserDefaults.nowPlayingSingleLyric = value
                        // 开/关都当场生效（页面还挂着的话）：关掉就是当场把它收起来。
                        NowPlayingLyricsPlate.reapply()
                    }
                )

                // ★ 2026-10-12（用户）：「我觉得有人不会用这个东西，去用正常的去了」——
                // 所以把歌词那两档也在这里给一颗**总开关**，不用先去歌词页翻逐语言那三颗。
                // ⚠️ 与 设置 → 歌词 里那几颗**是同一批键**（不是新造的一套）：两面永远同步。
                //   · 罗马化：日/中/韩三颗里**有一颗开着**就算开；关掉则三颗全关；
                //   · 译文：与歌词页那颗「隐藏译文」互为反相（键只有一个）。
                Toggle(
                    "show_romanized_lyrics".localized,
                    isOn: settingsShadowBinding($shadow.showRomanizedLyrics) { value in
                        NgzhwmSettingsViewModel.setAllRomanization(value)
                        // 这个指纹进过宿主的 `isCurrent` ⇒ 下一拍就重建，不用等换歌。
                        NowPlayingLyricsPlate.reapply()
                    }
                )

                Toggle(
                    "show_lyrics_translation".localized,
                    isOn: settingsShadowBinding($shadow.showLyricsTranslation) { value in
                        NgzhwmSettingsViewModel.setHideTranslation(!value)
                        NowPlayingLyricsPlate.reapply()
                    }
                )

                // ★ 2026-10-12（用户）：「现在是未播放歌词行是模糊不清的，加个功能叫
                // **未播放歌词行模糊化**。关闭之后，未当前播放歌词行不模糊化，**默认关闭**」。
                // 关着 = 非当前行只变淡、不发糊；翻开 = 回到改动前那条公式。
                Toggle(
                    "now_playing_blur_unplayed_lyrics".localized,
                    isOn: settingsShadowBinding($shadow.nowPlayingBlurUnplayedLyrics) { value in
                        UserDefaults.nowPlayingBlurUnplayedLyrics = value
                        // 这个开关进了宿主那条指纹 ⇒ 下一拍就重建，不用等换歌。
                        NowPlayingLyricsPlate.reapply()
                    }
                )

                // 控制键换成本地字形：原生按钮留着（动作/状态/无障碍全在），
                // 只把按钮里的原生图标设成透明、叠一个我们自己的 SF Symbol 字形。
                // 做法照 pw v0.21.1 的 `PlayerControls.x`（GPL-3.0）：见 `NowPlayingControlsPlate` 文件头。
                Toggle(
                    "now_playing_control_glyphs".localized,
                    isOn: settingsShadowBinding($shadow.nowPlayingControlGlyphs) { value in
                        UserDefaults.nowPlayingControlGlyphs = value
                        if value {
                            NowPlayingControlsPlate.reapply()
                        } else {
                            NowPlayingControlsPlate.restore()
                        }
                    }
                )

                // ⛔「禁止回弹」已于 2026-10-03 夜删除（真机日志 41）：
                // 它把列表的 `alwaysBounceVertical` 关掉，用户实测**开了就划不掉播放器**
                // （下拉关闭是经过列表那一层接管的，那个属性是链条的一环）。
                // 列表拖拽时剩下的那点橡皮筋是"一屏"**无法消除**的残留 ——
                // 要碰它就得先有办法自己接管关闭手势。理由写在 `NowPlayingOneScreen` 文件头。
            }

            Section(footer: Text("declutter_description".localized)) {
                Toggle(
                    "hide_mini_player_bar".localized,
                    isOn: settingsShadowBinding($shadow.hideMiniPlayerBar) { value in
                        UserDefaults.hideMiniPlayerBar = value
                        // 藏过的 chrome 不一定再有 layout 回合 ⇒ 当场复查一遍（见 `DeclutterChrome`）。
                        DeclutterChrome.reconcileNow()
                    }
                )

                Toggle(
                    "hide_singalong_line".localized,
                    isOn: settingsShadowBinding($shadow.hideSingalongLine) { value in
                        UserDefaults.hideSingalongLine = value
                        DeclutterChrome.reconcileNow()
                    }
                )

                // ★ 2026-10-10（照片 63）：听歌页那排胶囊（「切换至视频」+「显示 / 隐藏歌词」）。
                //   判据是**无障碍 id**（日志 54 的 `[NPVTree]`）：`lyrics-npv-switch-button` /
                //   `nowplaying-npv-musicvideos-switch`；关掉开关即当场写回 `alpha`。
                Toggle(
                    "hide_npv_pills".localized,
                    isOn: settingsShadowBinding($shadow.hideNowPlayingPills) { value in
                        UserDefaults.hideNowPlayingPills = value
                        DeclutterChrome.reconcileNow()
                    }
                )
            }

            // ⛔「双击手势」整节已于 2026-10-04 删除（用户拍板：先删掉，之后再搞）。
            //   它不是"坏了"才删：切歌那条路日志 8/17 证明能用；删是因为 ——
            //   ① 手势挂在页面根视图上，**在播放键上方双击也会跳歌**（本该是播放/暂停）；
            //   ② 最该起作用的全屏歌词那一面默认关、从没验过；
            //   ③ 最近 8 份日志里它一次都没被用过。
            //   重做时的三条要求（控件上不认 / 单击让位 / 另选挂点）见
            //   `Tools/eevee-hookfinder/SESSION_2026-10-03_NIGHT.md` §10。
            //   ⇒ 上游 `Player/PlayerGestures.x.swift` 正是按这三条重写的，移植计划见
            //     本轮讨论（排在编译通过之后的第一件）。

            SettingsResetSection(
                keys: Self.ownedKeys,
                afterReset: {
                    // 先重同步影子值（否则开关还显示旧状态），再按**重置后**的值落地。
                    shadow = Shadow()

                    if UserDefaults.nowPlayingBackdrop {
                        refreshNowPlayingBackdrop()
                    } else {
                        NowPlayingBackdrop.remove(reason: "reset this page")
                    }
                    if UserDefaults.nowPlayingOneScreen {
                        NowPlayingOneScreen.reapply()
                    } else {
                        NowPlayingOneScreen.restore()
                    }
                    if UserDefaults.nowPlayingVolume {
                        NowPlayingPageOverlay.reapply()
                    } else {
                        NowPlayingPageOverlay.remove(reason: "reset this page")
                    }
                    if UserDefaults.nowPlayingControlGlyphs {
                        NowPlayingControlsPlate.reapply()
                    } else {
                        NowPlayingControlsPlate.restore()
                    }
                    // 歌词那几档：`reapply()` 自己按当前设置重建容器/指纹。
                    NowPlayingLyricsPlate.reapply()
                    DeclutterChrome.reconcileNow()
                }
            )
        }
        .listStyle(InsetGroupedListStyle())
        // 每次进页重新同步一次：别处（Flag 页、重置、上一版遗留的存储）改了 UserDefaults 时
        // 影子值不该停在旧值上。
        .onAppear { shadow = Shadow() }
    }

    /// 本页「重置本页」的作用范围。
    ///
    /// ⚠️ 故意**不含** `showRomanizedLyrics` / `showLyricsTranslation` 背后的那几个歌词页键：
    /// 那两颗开关是"同一批键的另一个入口"，在听歌页重置它们等于偷偷改掉歌词页的设置。
    private static let ownedKeys = [
        "nowPlayingBackdrop",
        "nowPlayingOneScreen",
        "nowPlayingVolume",
        "nowPlayingLyricsInPlayer",
        "nowPlayingSingleLyric",
        "nowPlayingBlurUnplayedLyrics",
        "nowPlayingControlGlyphs",
        "hideMiniPlayerBar",
        "hideSingalongLine",
        "hideNowPlayingPills",
    ]
}
