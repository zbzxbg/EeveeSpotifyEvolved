// ⛔ 本文件曾是「扩展功能」页（627 行，24 个开关 + 8 个子页入口）—— **已按方案 B 拆开**。
//
// 为什么必须拆：这一页在根页只占一行，里面却塞着 24 个开关 + 8 个子页入口 —— 想找"备份 / 许可 / 更新"要进两层，而"听歌页""标签栏"这种天天用的开关要滚到第 4、5 节。
//
// 原来这里的东西现在在哪（一行都没丢）：
// · 听歌页 12 颗（`now_playing_section` 9 + 藏 chrome 3）→ `Settings/Sections/NowPlaying/Views/NowPlayingSettingsView.swift`
// · 标签栏 + 迷你条 4 颗 → `Settings/Sections/TabBar/Views/TabBarAndMiniBarSettingsView.swift`
// · 首页 / 音乐库 / 专辑页 / 歌单封面 8 颗 → `Settings/Sections/Pages/Views/PagesAppearanceSettingsView.swift`
// · 8 个子页入口全部提到根页、按语义归组（进阶 / 维护），一步可达
//
// 共用件（别在四个新页里各抄一份）：影子值绑定 → `Settings/Views/SettingsShadowBinding.swift`；重置本页 → `Settings/Views/SettingsResetSection.swift`。
//
// l10n 的 `extras_title` / `extras_description` 两条已删 —— 审计确认零读者（全仓只有 .strings 自己命中），且只存在于 en + zh-CN。将来若真要再做一个"杂物袋"页，把这两条加回 en.lproj + zh-CN.lproj 即可（其余 25 个 locale 从来没翻过它们）。
