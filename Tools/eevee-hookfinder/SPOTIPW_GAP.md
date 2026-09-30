# spoti.pw ↔ 本仓库：功能缺口清单

> 写于 2026-10-01。用途：**排期用**，不是实现说明。
> 想知道"它还差什么/我们还差什么"看这一份就够，不必再去翻它的仓库。

---

## 0. 红线与清点方法（先看这段）

- 本地 checkout `C:\Users\ngzhwm\Documents\GitHub\spoti.pw` = **v0.22.0**（`version.txt`；
  `README.md` 徽章也是 PolyForm Strict 1.0.0）→ 已过 v0.21.1 那条 GPL 线，
  **禁止修改 / 复用 / 再分发它的代码**。用户定的规矩：**只看思路，代码全部自己写**。
- 本次清点**只读了它的 `.md`**：`README.md`、`AGENTS.md`、`CHANGELOG.md`、`docs/tweaks.md`、
  `harness/*/README.md`（19 个）。`tweak/`、`vendor/`、`extension/`、`scripts/` 一行没看。
  所以下面每一条都能追到文档，没有一条来自它的实现。
- 它的基线与我们不同，比较时要记住：

| | spoti.pw | 本仓库 |
|---|---|---|
| 宿主 | Spotify **9.1.78** | Spotify **9.1.86** |
| 系统 | 重设计要求 **iOS 26+**（Live Activity 17+） | iOS 27 / iPhone 11 |
| 路线 | 无越狱 Theos tweak，**自绘整套界面**（Liquid Glass） | hook 原生视图 + 藏/改/插层；只自绘了全屏歌词 |
| 语言/构建 | Objective-C + Theos；本地 Mac 或 GitHub Actions | Swift + Orion；只能 GitHub Actions（无 Mac） |
| 文档里的许可 | PolyForm Strict 1.0.0（≤v0.21.1 为 GPL-3.0） | 见仓库自身 |

总量：**约 65 条用户可见功能**（第 1–9 节 69 行，含同一功能在两套 look 下的分身，去重后 ~65），
另有 **7 条工程/工具链**项。

---

## 1. 能力块对照（结论层）

| # | spoti.pw 的能力块 | 我们 | 判断 |
|---|---|---|---|
| 1 | Liquid Glass 整体重设计（Home/Search/Library/Playlist/Album/Artist/Player/Queue/TabBar 全部自绘） | ❌ 只有 AMOLED 深色栏 + 标签栏插一层材质 + 藏 chrome×7 | **它的主体，我们等于没做** |
| 2 | 逐页自绘头部（歌单 header 按 Music app 布局、由页面 view model 喂数据；专辑/单曲套同款；艺人页换头去视频与 tab 条） | ❌ | 最大的一块工作量 |
| 3 | morph 转场（播放器从迷你条卡片"长出"、封面"飞出"） | ❌ | 对着它私有的 `SPTBarOverlayPresentationTransition` 做 |
| 4 | Live Activity 三视图（Lyrics/Queue/Control）+ 睡眠定时器 + 锁屏小组件 + 主屏 widget（App Groups） | ❌（顶层没有 `extension/`） | **用户已决定"不做"** |
| 5 | 锁屏动态封面（Canvas / AM 式动画封面）+ 锁屏歌词 | ❌ | **用户已"暂缓"**（两者共用同一个 now-playing 字典，属同一块） |
| 6 | 音频三件套：自研 DSP 效果链 + Speed/Pitch + Music Haptics | ❌ `Sources/` 里 `AVAudioEngine`/`CoreAudio`/`AudioUnit`/`fishhook` **零命中** | **用户已"搁置"** |
| 7 | 歌词：Apple Music TTML(BiniLyrics/Unison) 等多源链、逐音节、同行同唱一起亮、间奏三点动画、发音+翻译、RTL、Genius 逐行释义、给无词曲目伪造歌词 | ✅ 大部分有（Spicy/NetEase/AMLL/Petit/Musixmatch/LRCLIB/Genius、逐词、翻译、中日韩罗马音、删 `♪`、以及同类的"骗服务端"注入：`ScrollsitaLyricsElementInjector` / `CasitaResponseProbe`） | ❌ 缺：**逐行释义**、**RTL**、间奏三点动画、BiniLyrics/Unison 两个源 |
| 8 | 屏蔽艺人：曲目开头跳过 + 名单页 | ❌（只有 `SPTPlayerTrack` 基础设施） | **最小、最独立、不需要新数据** |
| 9 | 触感：控件震动 + **Music Haptics**（渲染线程分析鼓/贝斯，跟随音乐）+ 强度 | ⚠️ 只有控件震动（`UIFeedbackGenerator`），且**从未验证** | 缺 Music Haptics（要 CoreHaptics + 音频 buffer） |
| 10 | Tab 编辑器（拖动排序、点按显隐、Add a tab） | ❌ | 中等；tab 的类名/id 我们已抓全 |
| 11 | Home 渐变（8 色 × 3 强度 × 4 高度） | ❌ | 便宜，纯外观 |
| 12 | 强调色 Accent（两套 look 各自一套色，可切回 Spotify 绿） | ❌ | 便宜；比"正经主题色"现实得多 |
| 13 | Navbar Hide labels（玻璃栏只留图标） | ❌ | 便宜 |
| 14 | All flags 页（每个 flag Auto/Off/On + 数字/文本输入）+ Labs 页（Spotify 未发布功能） | ⚠️ 我们有 Flag 覆盖 + 41 条真机目录，但没有"AUTO"这一档与数字/文本输入 | 原料已有，缺那页 UI |
| 15 | Updates 页（列出比当前新的每个版本的 changelog）+ Licenses 页 + 欢迎 tour + Donate | ⚠️ 有 release 检查（`GitHubHelper.getLatestRelease()`，`EeveeSettingsVersionView.swift:139` 已在用），但 `GitHubRelease` **只解了 `tagName`** | **不到一个文件的量** |
| 16 | Reset all settings → 按前缀删键回原版 / Backup settings | ❌ | 便宜 |
| 17 | 单点：歌单内玻璃搜索栏（下拉出现）、实体页 `?` 菜单、Add to library 变勾、Follow 变勾、下载按钮状态、queue 页重绘、library 排序修复 | ❌ | 多条小项，随重绘一起做才划算 |
| 18 | 遥测拦截（+ 计数页） | ✅ 有（开关级） | 打平 |
| 19 | 诊断：屏幕 dump、**tree server（8085/iproxy）**、**主线程 hang sampler** | ⚠️ 只有日志版 `ViewTreeDumper` | 实时 tree server 很对症我们"抓类名"的痛点 |
| 20 | 工程：分层架构 + `check-layers.sh` 构建把关 + `SGFlagForce.h` flag 注册表 | ⚠️ 我们有 tests.yml + 自检脚本 | 它的架构纪律更强 |

**我们净多出来的**：完整的 **SponsorBlock**（19 个文件：分类 Off/Show/Manual/Auto、投票、提交、
草稿、隐藏段、toast、进度条 overlay、长按标记；它的文档里**完全没有**这一项）、
**Flag 覆盖目录（41 条真机实测值）**、多语言罗马音分语言配置、Premium 修补链路。

---

## 2. 缺口分档（排期用）

### A. 已否决 —— 不要再花时间（3 块，占它"重型功能"的一半以上）
1. **音频三件套**：自研 DSP（rebind `AudioOutputUnitStart` + RemoteIO render notify，
   1024 帧分块、迟一个 block 原地处理；gain/limiter/EQ/convolver/ViPER DDC/Liveprog EEL2/
   reverb/stereo widening/crossfeed/tube/compander）、Speed/Pitch（插 Apple time-pitch unit）、
   Music Haptics（纯 C 鼓/贝斯分析 + Core Haptics 调度）。
   → 我们的前提是"**先抽 IPA 导入符号表 + 自己写 DSP**"，用户已搁置。
2. **Live Activity + 小组件 + 锁屏小组件 + 睡眠定时器**。
3. **锁屏动态封面 + 锁屏歌词**。

### B. 巨型（它的主体，周—月级）
玻璃重设计 + 逐页自绘（Home/Search/Library/Playlist/Album/Artist/Player/Queue/TabBar）+
morph 转场 + 实体页 `?` 菜单 + 歌单内玻璃搜索栏。
→ **先做 1 屏样品给用户看**，再决定要不要铺开（10 个屏各自独立）。

### C. 中等
Tab 编辑器 / 屏蔽艺人 + 名单页 / 诊断 tree server 与 hang sampler / 间奏三点动画 /
All flags（AUTO 档 + 数字文本输入）与 Labs 页 / Apple Music TTML 两个源。

### D. 小而快（一次编译能捎带好几条）
Updates 页（模型加 `body`/`htmlUrl` + 列表接口 + 一页 UI）、Home 渐变、强调色 Accent、
Navbar Hide labels、Licenses 页、Reset-to-stock、`spotify:` 链接派发（已有 `OpenSpotify.x.swift`）。

---

## 3. 建议顺序（结合"无 Mac、只能 CI、一次编译成本高"）

1. **修地基**：15 秒手势 / 清爽"藏了回不来" / SponsorBlock 类名 —— 已写但坏的，见 `SESSION_HANDOFF.md` §8。
2. **捎带 D 档小项**（越小越先）：Updates 页 → Home 渐变 → Accent → Navbar labels。
3. **屏蔽艺人**（C 档最小，复用 `WordByWordPlaybackControl.skipToNext()`，日志 8 已证明可用）。
4. **一屏玻璃样品**（挑"正在播放页"或"歌单页"，这两屏的类名/frame 日记 8 已抓全）→ 给用户看 → 再排期。
5. 继续不碰 A 档三块。

> ⚠️ 2026-10-01 追加：第 4 步之前**先试一条零代码实验** —— 9.1.86 主二进制里有
> `ios-reprise-liquid-glass-override` → `mode`（Spotify 自己的液态玻璃总开关）。
> 若 `force_enabled` 能打开它，第 4 步的形态会完全不同。见
> `Tools/eevee-hookfinder/FLAGS_9186_DESIGN.md`。

---

## 4. 文档级不确定性（别当事实用）

1. `docs/tweaks.md` 的 Redesigned 目录清单里**没有** `Artist/`，但 `harness/artist/README.md`
   与 CHANGELOG 0.19.0 都明确说艺人页被重绘了 → 文档自相矛盾，现状未说明。
2. **Spicy Lyrics** 只在 CHANGELOG 0.20.0 出现，`docs/tweaks.md` 的歌词来源清单里没有。
3. Backup settings 的具体行为、诊断工具细节、部分 flag 名：文档未说明（需读源码 → 按红线，不读）。
4. 文档未见"需要自建服务器"的要求；歌词走公开端点，更新检查走它自己的 GitHub Releases。
