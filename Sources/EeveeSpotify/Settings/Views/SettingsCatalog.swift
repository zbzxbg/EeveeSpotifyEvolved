import SwiftUI
import UIKit

/// 设置根页的数据源：一行一个入口，按**对象**分组。
///
/// 为什么是表而不是继续手写 `settingsRow(...)`：
/// · 根页要加搜索，搜索得先有一份能遍历的清单；
/// · 有些行要带状态（补丁已启用 / 未启用），状态是渲染时现读 `UserDefaults` 的；
/// · 分组顺序、标题、副标题集中在一处，调整分组时不必在 `body` 里搬代码。
///
/// 这张表只管**入口**，不放开关。开关都在各自的页里（一页一件事）。
enum SettingsGroup: String, CaseIterable, Identifiable {
    case playback
    case lyrics
    case interface
    case audio
    case advanced
    case about

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .playback: return "settings_group_features"
        case .lyrics: return "settings_group_lyrics"
        case .interface: return "settings_group_interface"
        case .audio: return "settings_group_audio"
        case .advanced: return "settings_group_advanced"
        case .about: return "settings_group_about"
        }
    }
}

struct SettingsEntry: Identifiable {
    let id: String
    let group: SettingsGroup
    let titleKey: String
    let subtitleKey: String
    let iconName: String
    let color: Color

    /// 搜索别名：俗称、英文原词、缩写。标题与副标题本身也会参与匹配。
    var aliases: [String] = []

    /// 行尾状态文字；`nil` = 不显示。每次渲染求值，所以读得到刚被改过的键。
    var status: (() -> String?)? = nil

    /// 点开这一行推入的页面。需要导航栈的页面（Flag 覆盖）拿到的就是这个栈。
    let destination: (UINavigationController) -> AnyView

    /// 大小写不敏感的包含匹配；别名与本地化后的标题、副标题一起参与。
    func matches(_ query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }

        let needle = trimmed.lowercased()
        return ([titleKey.localized, subtitleKey.localized] + aliases).contains {
            $0.lowercased().contains(needle)
        }
    }
}

enum SettingsCatalog {

    static let entries: [SettingsEntry] = [
        // ── 播放与 Premium
        SettingsEntry(
            id: "patching",
            group: .playback,
            titleKey: "patching",
            subtitleKey: "settings_sub_patching",
            iconName: "hammer.fill",
            color: .orange,
            aliases: ["premium", "patch", "会员", "广告", "补丁"],
            status: { SettingsCatalog.patchStatus() },
            destination: { _ in AnyView(EeveePatchingSettingsView()) }
        ),
        SettingsEntry(
            id: "sponsorblock",
            group: .playback,
            titleKey: "sponsorblock",
            subtitleKey: "settings_sub_sponsorblock",
            iconName: "forward.end.fill",
            color: .red,
            aliases: ["sponsor", "skip", "跳过", "广告段"],
            destination: { _ in AnyView(SponsorBlockSettingsView()) }
        ),
        SettingsEntry(
            id: "blocked_artists",
            group: .playback,
            titleKey: "blocked_artists_title",
            subtitleKey: "settings_sub_blocked_artists",
            iconName: "person.slash.fill",
            color: Color(hex: "#FF9F0A"),
            aliases: ["block", "屏蔽", "拉黑", "艺人"],
            destination: { _ in AnyView(EeveeBlockedArtistsSettingsView()) }
        ),
        SettingsEntry(
            id: "sleep_timer",
            group: .playback,
            titleKey: "sleep_timer_title",
            subtitleKey: "settings_sub_sleep_timer",
            iconName: "moon.zzz.fill",
            color: .indigo,
            aliases: ["sleep", "timer", "定时", "睡眠"],
            destination: { _ in AnyView(EeveeSleepTimerSettingsView()) }
        ),
        SettingsEntry(
            id: "listening_stats",
            group: .playback,
            titleKey: "listening_stats_title",
            subtitleKey: "settings_sub_listening_stats",
            iconName: "chart.bar.fill",
            color: .teal,
            aliases: ["stats", "统计", "播放次数", "时长"],
            destination: { _ in AnyView(EeveeListeningStatsSettingsView()) }
        ),

        // ── 歌词
        SettingsEntry(
            id: "lyrics",
            group: .lyrics,
            titleKey: "lyrics_sources_title",
            subtitleKey: "settings_sub_lyrics",
            iconName: "quote.bubble.fill",
            color: .blue,
            aliases: ["lyrics", "歌词", "源", "source"],
            destination: { _ in AnyView(EeveeLyricsSettingsView()) }
        ),
        SettingsEntry(
            id: "lyrics_appearance",
            group: .lyrics,
            titleKey: "lyrics_appearance_title",
            subtitleKey: "settings_sub_lyrics_appearance",
            iconName: "textformat.size",
            color: .blue,
            aliases: ["歌词外观", "字号", "行距", "font"],
            destination: { _ in AnyView(EeveeLyricsAppearanceSettingsView()) }
        ),
        SettingsEntry(
            id: "imported_lyrics",
            group: .lyrics,
            titleKey: "imported_lyrics_title",
            subtitleKey: "settings_sub_imported_lyrics",
            iconName: "doc.text",
            color: .blue,
            aliases: ["import", "导入", "lrc", "ttml", "spl"],
            destination: { _ in AnyView(EeveeImportedLyricsSettingsView()) }
        ),
        SettingsEntry(
            id: "lyrics_offset",
            group: .lyrics,
            titleKey: "lyrics_offset_title",
            subtitleKey: "settings_sub_lyrics_offset",
            iconName: "timer",
            color: Color(hex: "#30B0C7"),
            aliases: ["offset", "偏移", "延迟", "微调"],
            destination: { _ in AnyView(EeveeLyricsOffsetSettingsView()) }
        ),

        // ── 界面
        SettingsEntry(
            id: "now_playing",
            group: .interface,
            titleKey: "now_playing_section",
            subtitleKey: "settings_sub_now_playing",
            iconName: "music.note.list",
            color: Color(hex: "#0A84FF"),
            aliases: ["player", "听歌页", "播放页", "now playing"],
            destination: { _ in AnyView(NowPlayingSettingsView()) }
        ),
        SettingsEntry(
            id: "tabs_and_mini_bar",
            group: .interface,
            titleKey: "tabs_and_mini_bar_title",
            subtitleKey: "settings_sub_tabs",
            iconName: "rectangle.on.rectangle",
            color: Color(hex: "#5E5CE6"),
            aliases: ["tab", "标签栏", "迷你条", "mini"],
            destination: { _ in AnyView(TabBarAndMiniBarSettingsView()) }
        ),
        SettingsEntry(
            id: "home_and_library",
            group: .interface,
            titleKey: "home_and_library_title",
            subtitleKey: "settings_sub_home_library",
            iconName: "rectangle.stack.fill",
            color: Color(hex: "#64D2FF"),
            aliases: ["home", "library", "首页", "音乐库", "专辑页", "歌单页"],
            destination: { _ in AnyView(PagesAppearanceSettingsView()) }
        ),
        SettingsEntry(
            id: "lock_screen_artwork",
            group: .interface,
            titleKey: "lock_screen_artwork_title",
            subtitleKey: "settings_sub_lock_screen_artwork",
            iconName: "rectangle.on.rectangle.angled",
            color: Color(hex: "#1ED760"),
            aliases: ["lock", "锁屏", "封面", "canvas", "artwork"],
            destination: { _ in AnyView(EeveeLockScreenArtworkSettingsView()) }
        ),
        SettingsEntry(
            id: "lock_screen_lyrics",
            group: .interface,
            titleKey: "lock_screen_lyrics_title",
            subtitleKey: "settings_sub_lock_screen_lyrics",
            iconName: "text.quote",
            color: Color(hex: "#1ED760"),
            aliases: ["lock", "锁屏", "歌词", "lock lyrics"],
            destination: { _ in AnyView(EeveeLockScreenLyricsSettingsView()) }
        ),
        SettingsEntry(
            id: "app_icon",
            group: .interface,
            titleKey: "appIcon",
            subtitleKey: "settings_sub_app_icon",
            iconName: "app.badge.fill",
            color: .pink,
            aliases: ["icon", "图标", "桌面"],
            destination: { _ in AnyView(EeveeAppIconPickerView()) }
        ),
        SettingsEntry(
            id: "haptics",
            group: .interface,
            titleKey: "haptics_title",
            subtitleKey: "settings_sub_haptics",
            iconName: "waveform",
            color: Color(hex: "#FF375F"),
            aliases: ["haptic", "触感", "震动"],
            destination: { _ in AnyView(EeveeHapticsSettingsView()) }
        ),

        // ── 音频与手势
        SettingsEntry(
            id: "audio_effects",
            group: .audio,
            titleKey: "audio_effects_title",
            subtitleKey: "settings_sub_audio_effects",
            iconName: "slider.horizontal.3",
            color: Color(hex: "#FF2D55"),
            aliases: ["eq", "dsp", "音效", "均衡", "压缩", "crossfeed"],
            destination: { _ in AnyView(EeveeAudioEffectsSettingsView()) }
        ),
        SettingsEntry(
            id: "audio_reactive",
            group: .audio,
            titleKey: "audio_reactive_title",
            subtitleKey: "settings_sub_audio_reactive",
            iconName: "waveform.path.ecg",
            color: Color(hex: "#FF9F0A"),
            aliases: ["rhythm", "beat", "律动", "节拍", "触感", "鼓点"],
            destination: { _ in AnyView(EeveeAudioReactiveSettingsView()) }
        ),
        SettingsEntry(
            id: "head_gestures",
            group: .audio,
            titleKey: "head_gestures_title",
            subtitleKey: "settings_sub_head_gestures",
            iconName: "airpodspro",
            color: Color(hex: "#0A84FF"),
            aliases: ["airpods", "gesture", "头部", "点头", "摇头"],
            destination: { _ in AnyView(EeveeHeadGestureSettingsView()) }
        ),

        // ── 高级
        SettingsEntry(
            id: "experiments",
            group: .advanced,
            titleKey: "experiments",
            subtitleKey: "settings_sub_experiments",
            iconName: "sparkle",
            color: .purple,
            aliases: ["experiment", "实验", "ttml", "spicy"],
            destination: { _ in AnyView(EeveeExperimentsSettingsView()) }
        ),
        SettingsEntry(
            id: "flag_overrides",
            group: .advanced,
            titleKey: "flag_override_title",
            subtitleKey: "settings_sub_flags",
            iconName: "slider.horizontal.3",
            color: Color(hex: "#5E5CE6"),
            aliases: ["flag", "开关", "远程", "覆盖"],
            destination: { navigationController in
                AnyView(EeveeFlagBrowserView(navigationController: navigationController))
            }
        ),
        SettingsEntry(
            id: "reduce_interventions",
            group: .advanced,
            titleKey: "reduce_interventions_title",
            subtitleKey: "settings_sub_reduce",
            iconName: "bell.slash.fill",
            color: Color(hex: "#FF6482"),
            aliases: ["reduce", "打扰", "推荐", "弹窗"],
            destination: { navigationController in
                AnyView(EeveeReduceInterventionsView(navigationController: navigationController))
            }
        ),
        SettingsEntry(
            id: "privacy",
            group: .advanced,
            titleKey: "privacy_title",
            subtitleKey: "settings_sub_privacy",
            iconName: "hand.raised.fill",
            color: Color(hex: "#30B0C7"),
            aliases: ["privacy", "隐私", "上报"],
            destination: { _ in AnyView(EeveePrivacySettingsView()) }
        ),
        SettingsEntry(
            id: "miscellaneous",
            group: .advanced,
            titleKey: "miscellaneous",
            subtitleKey: "settings_sub_misc",
            iconName: "ellipsis.circle.fill",
            color: .gray,
            aliases: ["misc", "杂项", "其他", "分享链接"],
            destination: { _ in AnyView(EeveeMiscellaneousSettingsView()) }
        ),

        // ── 关于与维护
        SettingsEntry(
            id: "updates",
            group: .about,
            titleKey: "updates_title",
            subtitleKey: "settings_sub_updates",
            iconName: "clock.arrow.circlepath",
            color: Color(hex: "#32ADE6"),
            aliases: ["update", "更新", "版本"],
            destination: { _ in AnyView(EeveeUpdatesSettingsView()) }
        ),
        SettingsEntry(
            id: "backup",
            group: .about,
            titleKey: "backup_title",
            subtitleKey: "settings_sub_backup",
            iconName: "externaldrive.badge.timemachine",
            color: Color(hex: "#64D2FF"),
            aliases: ["backup", "备份", "恢复", "export", "导出"],
            destination: { _ in AnyView(EeveeBackupSettingsView()) }
        ),
        SettingsEntry(
            id: "licenses",
            group: .about,
            titleKey: "licenses_title",
            subtitleKey: "settings_sub_licenses",
            iconName: "doc.badge.ellipsis",
            color: Color(hex: "#8E8E93"),
            aliases: ["license", "许可", "开源", "credits"],
            destination: { _ in AnyView(EeveeLicensesSettingsView()) }
        ),
        SettingsEntry(
            id: "debug",
            group: .about,
            titleKey: "debug_title",
            subtitleKey: "settings_sub_debug",
            iconName: "wrench.and.screwdriver.fill",
            color: Color(hex: "#8E8E93"),
            aliases: ["debug", "调试", "日志", "log"],
            destination: { _ in AnyView(EeveeDebugSettingsView()) }
        ),
    ]

    static func entries(in group: SettingsGroup) -> [SettingsEntry] {
        entries.filter { $0.group == group }
    }

    static func search(_ query: String) -> [SettingsEntry] {
        entries.filter { $0.matches(query) }
    }

    /// 补丁行的状态：`.notSet` 是启动前的过渡态，既不算开也不算关，宁可不显示。
    private static func patchStatus() -> String? {
        switch UserDefaults.patchType {
        case .requests: return "settings_status_on".localized
        case .disabled: return "settings_status_off".localized
        case .notSet: return nil
        }
    }
}

/// 推入一个自建设置页。根页与搜索页共用，保证两边的导航行为一致（含宿主 frame）。
enum SettingsPagePresenter {
    static func push(
        _ destination: AnyView,
        title: String,
        from navigationController: UINavigationController
    ) {
        let controller = EeveeSettingsViewController(
            navigationController.view.frame,
            settingsView: destination,
            navigationTitle: title
        )
        navigationController.pushViewController(controller, animated: true)
    }
}
