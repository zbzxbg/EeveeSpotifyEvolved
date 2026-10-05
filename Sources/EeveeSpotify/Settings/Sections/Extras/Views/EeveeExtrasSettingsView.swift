// ⛔ 本文件曾是「扩展功能」页（`EeveeExtrasSettingsView`，627 行）—— 2026-10-13 **按用户要求拆掉**。
//
// 用户原话：「我觉得我们现在的设置页面有点乱了，要不学习一下上游的排版，或者你自己排」，
// 随后拍板方案 B：**把这一页拆开**，而不是只把根页排好看一点。
//
// 为什么必须拆：这一页在根页只占**一行**，里面却塞着 24 个开关 + 8 个子页入口：
// 想找"备份 / 许可 / 更新"要进两层，而"听歌页""标签栏"这种天天用的开关要滚到第 4、5 节。
// （2026-10-13 独立审计逐个点过：HEAD 版正好 24 个 `Toggle(`，拆完仍是 24 个，一个不多一个不少。）
//
// ── 原来这里的东西现在在哪（一行都不许丢）────────────────────────────────────
//
//   开关（按**页面**重分，四页各自带一颗「重置本页」）：
//     · `now_playing_section` 那 9 颗 + 藏 chrome 那 3 颗（迷你条 / 跟唱行 / 胶囊）
//         → `Settings/Sections/NowPlaying/Views/NowPlayingSettingsView.swift`
//     · `tab_bar_glass_section` 3 颗 + `mini_bar_glass_section` 1 颗
//         → `Settings/Sections/TabBar/Views/TabBarAndMiniBarSettingsView.swift`
//     · `declutter_home_player_section` 3 颗 + `library_section` + `home_section`
//         → `Settings/Sections/HomeLibrary/Views/HomeAndLibrarySettingsView.swift`
//     · `playlist_cover_section` 1 颗 + `entity_page_section` 2 颗
//         → `Settings/Sections/EntityPage/Views/EntityPageSettingsView.swift`
//
//   子页入口（8 个，全部提到**根页**按语义归组，一步可达）：
//     · 隐私与上报 / 触感 / Flag 覆盖 / 屏蔽艺人 / 减少打扰 → 根页「进阶」组
//     · 备份与重置 / 更新日志 / 许可 → 根页「维护」组
//
//   共用件（抽成独立文件，别在四个新页里各抄一份）：
//     · 影子值绑定 → `Settings/Views/SettingsShadowBinding.swift`
//     · 重置本页   → `Settings/Views/SettingsResetSection.swift`
//
// l10n 里 `extras_title` / `extras_description` 两条**暂时闲置**（页面没了，键先留着：
// 各语言都已翻译，删键要同时改所有 locale，将来若再需要"杂物袋"可以直接复用）。
