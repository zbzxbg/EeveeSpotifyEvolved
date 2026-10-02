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

> ### ★ 2026-10-03 夜：**上面那条红线已经作废，换成按 tag 划的边界**
>
> 用户指出（复核确认）：**本地是完整 git 仓库，tag 从 `v0.18.0` 到 `v0.23.0-beta`**，
> 而换许可发生在 **`v0.21.1` 之后**：
> * `git show v0.21.1:LICENSE` → **GNU GPL v3**；
> * `git log v0.21.1..v0.22.0 -- LICENSE` → 只有一条 `f44abdf`（改为 PolyForm Strict 1.0.0）；
> * `git tag --contains f44abdf` → **只有 `v0.22.0` / `v0.23.0-beta`**。
>
> ⇒ **新规矩（按 tag 划，不按"看不看源码"划）**：
>
> | 范围 | 能做 | 不能做 |
> |---|---|---|
> | **`≤ v0.21.1`（GPL-3.0）** | **读、复用、改** —— 与本仓库 GPL-3.0 兼容 | —— |
> | **`≥ v0.22.0`（PolyForm Strict）** | 只读它的 **`.md`**（`README` / `CHANGELOG` / `docs/` / `AGENTS.md`） | **源码一行都不碰**（该许可明确禁止 *making changes or new works based on the software*） |
>
> **复用的三条义务**（GPL-3.0 §5）：① 保留版权与许可声明（署名写进「开源许可」页）；
> ② **标注"我们改过"与日期**；③ 衍生作品继续 GPL-3.0（我们本来就是）。
>
> **工程卫生**：GPL 那份只在隔离副本里读 ——
> `.spotify-ipa/spotipw-v0.21.1`（`git worktree`，detached `a08b38b`，已被 `.gitignore` 收口），
> **物理上避开工作区那份 v0.22.0**。
>
> **代价**：`v0.21.1` 之后的修复拿不到（v0.22/v0.23 的改进全在 PolyForm 期）。
>
> **第一个产出**：本目录新增 [`SPOTIPW_0211_PORT_ASSESSMENT.md`](SPOTIPW_0211_PORT_ASSESSMENT.md) ——
> 听歌页（播放器）的移植评估：目标类在 9.1.88 上的存活情况、依赖面、"一屏不滚"的最小可移植子集。
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

---

## 5. ★ 2026-10-02 复核：拿到 **v0.23.0-beta 的 deb** 之后（新增/纠正）

用户把 `C:\dsh\else\com.spotipw_0.23.0-beta_iphoneos-arm.deb` 给了我们 —— 比上面那次
（v0.22.0，**只读 `.md`**）新。红线不变：**不读它的源码、不反汇编**。
这次的证据来源只是**它自己的设置页文案**（等于把它的设置页翻了一遍），工具是新写的
`Tools/eevee-hookfinder/inspect_tweak_deb.py`（只抽可见字符串与 plist，**不反汇编**）。

deb 里只有 `spotifyglass.dylib`（2.4MB）+ 过滤器 plist，没有 `.bundle` → 文案都编在二进制里。
抽到 **36546 条**去重字符串（含 3000+ 个 SF Symbol 名，那是它"自定义导航栏图标选择器"的底料）。

### 5.1 这次才看见的**大块新东西**

| # | 新发现 | 说明（来自它的文案） |
|---|---|---|
| 1 | ★ **Sing = 端上 AI 卡拉OK / 人声分离** | Core ML 推理 + **可下载的 voice model**（`huggingface.co/Darkkos/spoti-sing/…`）、"Connect to Wi-Fi to download Sing's voice model."、"Sing stopped so your iPhone can cool down."、"Sing is unavailable over AirPlay."、`Vocal volume` / `Karaoke` / `Vocals`。**上面那份 §1 完全没有这一项** —— 它 0.23 的主体 |
| 2 | **Custom navbar（自选按钮）** | "Custom navbar" / "Choose a Link" / "Choose an Icon" / "Use search to find any SF Symbol" / "Enter a custom link" → 往导航栏塞自己的按钮（任意 SF Symbol + 任意链接） |
| 3 | **App 图标选择器** | "App icon" / "Choose an Icon" / "The icon did not change"（alternate icons，得随包塞图标） |
| 4 | **设置导出 / 导入** | "Export settings" / "Import settings" / "Import and restart" / "Not a settings file" |
| 5 | **诊断三件** | 屏幕 dump、**hang sampler**（`SGHangSamplerStart/Stop`）、**FLEX**（`FLEXManager`）→ 上面 §1 只记到 tree server |

### 5.2 把上面 §1 里"⚠️ 只有一半"的几项说准

- **清理开关不是 7 条，是 25 条**（`Hide …` 前缀，逐条实测）：
  `Hide above the tracks` / `Hide cards below the player` / `Hide in the header` /
  `Hide in the playlist header` / `Hide labels` / `Hide lyrics` / `Hide on Home` / `Hide on the page` /
  `Hide on the player` / `Hide playlist buttons` / `Hide Pronunciation` / `Hide social proof in Search` /
  `Hide Translation` / **`Hide the account switching tip`** / **`Hide the AI playlist creation tip`** /
  **`Hide the concert notifications tip`** / **`Hide the data saver tip`** / `Hide the device button` /
  **`Hide the live event tip`** / **`Hide the live event venue tip`** / **`Hide the Puffin nudge`** /
  **`Hide the smart shuffle helper`** / `Hide the tab bar` / **`Hide the video carousel in Search`** /
  **`Hide the watch feed explorer tip`**。
  → 我们只有 5 条；**加粗的那些是"藏 Spotify 自己的提示/推广/新功能气泡"**，全是同一种做法
  （`DeclutterChrome` 的可撤销隐藏 + 复查），**一次编译能带一大批**、风险最低。
- **Tab 编辑器**：确认含拖动排序、点按显隐、**"Add a Tab"**、图标选择。
- **真·DSP 链有十件套**（不是笼统的"效果链"）：`Graphic EQ`（带编辑器）/ `Equalizer` / `Crossfeed` /
  `Bass boost` / `Convolver` + **脉冲响应文件** / `Multiband compander` / `Stereo widening` /
  `Tube amplifier warmth` / `Limiter`(threshold/release) / `Loudness` / **`AutoEq` + 耳机校正文件
  (DDC)** / **`ViPER DDC`** / **`Liveprog`（EEL2 脚本）** / `Varispeed`。
  它的自报里有 `audio pipeline: mixer import unavailable; output processing only` 与
  `dsp: output gain … limiter …` → 它**确实把音频图接上了**。
- **变速变调**：`Speed and pitch`（含独立面板、`Pitch follows speed`、`Semitones`、`Varispeed`）。
  ⚠️ 这一条**可能不用碰音频图**：我们自己的日志 25 里出现过 Spotify 自己的
  `com.spotify.service.playbackcontrol.playbackspeed` 服务 → **值得先做一次只读探针**看能不能借它。
- **Music Haptics**：确认在（`Vibrations` + "A tap on each kick and snare, and a rumble under the bass"），
  同样要音频 buffer。
- **队列/设备**：`Queue as a bottom sheet` / `Connect as a bottom sheet` / `Queue badge` /
  `Queue flip transition` / `Sheet style player` / `New progress slider` / `Glowing pill` /
  `Bar to cover art animation` / `Video in the mini player`（这些属"行为+外观"之间，单列）。
- **零碎但便宜**：`Text sizes` / `Denser rows` / `Tooltips` / `Pull to refresh` / `Shortcuts grid` /
  `Reduce interventions` / `Sleep timer` / `Like and dislike buttons` / `Follow` 变勾 / `Add to library` 变勾 /
  `Snake on the cover art`（彩蛋）/ `Welcome tour` / `Licenses` / `Updates` / `All releases` / `Donate`。

### 5.3 结论（回答"是不是还有很多没做"）

**是。** 扣掉美化（它那套自绘玻璃界面）之后，还差：

1. **音频三块**（Sing 人声分离 / DSP 十件套 / Music Haptics）—— 都在同一条技术门槛上：
   **我们没有音频图访问**（9.1.86 的 dump 里没有 audio unit / 渲染类；它走的是 hook 音频管线）。
   要吃这块得先"抽 IPA 导入符号表 + fishhook 重绑"，**用户此前已搁置**；Sing 还多一个"模型是它的"。
2. **一批中等功能**：Custom navbar、Tab 编辑器、App 图标选择器、设置导入导出、
   All flags（AUTO 档 + 数字/文本输入）、诊断三件（dump / hang sampler / FLEX / tree server）。
3. **一堆小项**：25 条清理开关（我们 5 条）、Updates/Licenses/tour/Donate、
   Text sizes / Denser rows / Tooltips / Pull to refresh、队列与设备底部卡片、sheet 式播放器、
   新进度滑条、封面→条动画……**大多是"一次编译捎带好几条"的量级**。
4. **我们比它多的**（§1 已记）：SponsorBlock 全套、41 条真机 flag 目录、多语言罗马音分配置、
   Premium 修补链路。

**建议顺序（仍按"无 Mac、一次编译很贵"）**：
① 先把手上这两条线验完（v4.6.1 图标 / v4.7.1 迷你条玻璃）；
② **25 条清理开关**（最便宜、最贴"清爽"这条线，复用 `DeclutterChrome` 的复查框架）；
③ **设置导出/导入 + Updates/Licenses/tour**（离线、零风险、一次编译一条）；
④ **诊断 tree server + hang sampler**（对我们"抓类名"的痛点最对症）；
⑤ **变速变调只读探针**（借 Spotify 自己的 `playbackspeed` 服务，零风险，成了就是白捡）；
⑥ Custom navbar / Tab 编辑器（中等，需先取证导航栏与 tab 的结构）；
⑦ 音频三块继续搁置（除非决定做那个"符号表 + fishhook"的工程）。

---

## 6. 工程量估算（**按"轮次"算，不按行数**）

为什么用"轮次"当单位：没有 Mac ⇒ 每改一次都要 **写码 → 提交 → CI 编译 → 装机 → 抓日志/截图 → 我判读 → 再修**。
一轮的**固定开销**（编译+装机+抓日志≈几十分钟到一小时）跟改动大小基本无关，所以"一次编译带几条"才是省力的关键。

**本仓库自己的标尺**（都是实测）：
- 2026-10-02 这一晚，为了"底部两条玻璃"发了 **4 轮**（v4.6 → v4.6.1 → v4.7 → v4.7.1），
  每轮 1 个文件、100~300 行；**每轮都暴露一个只有真机才能看见的问题**
  （「创建」那颗图标 33×33、Spotify 把封面色写回、宽度跟着入场动画抽动）。
- 屏蔽艺人：4 个文件 + 2 轮（含一轮修崩溃）。
- SponsorBlock：19 个文件、多轮。
→ 经验值：**"一个文件级改动" ≈ 1 轮；"一个新功能" ≈ 1~3 轮**（含取证与修 bug）。

| 块 | 代码量 | 轮次（装机验证） | 前置 / 风险 |
|---|---|---|---|
| 25 条清理开关 | 1~2 文件（框架现成） | **2~4** | 每个目标要**先取证**（类名/id）→ 靠转储器一次抓多屏；低风险 |
| 设置导出/导入 + Updates/Licenses/tour/Donate | 4~6 文件 | **3~5** | 离线、零风险，最稳的一批 |
| All flags（AUTO 档 + 数字/文本输入） | 1~2 文件 | **1~2** | 目录已有 41 条真机值 |
| 诊断：tree server + hang sampler | 2~3 文件 | **2~3** | 要在手机上跑 iproxy/网络，用户侧步骤变多 |
| Custom navbar（SF Symbol + 链接） | 2~3 文件 | **2~4** | 要取证导航栏结构；3000 个 SF Symbol 的选择器是 UI 工作量 |
| Tab 编辑器（排序/显隐/加 tab） | 3~5 文件 | **3~5** | ⚠️ 排序/显隐要动 Spotify 的布局与手势 —— 撞本仓库"不动布局"的红线，风险最高的一档 |
| App 图标选择器 | 2~3 文件 + 构建流程 | **2~3** | 图标得随 IPA 塞进去（改 CI） |
| 变速变调 | 1~2 文件 | **2~4** | 先 1 轮**只读探针**试 Spotify 自己的 `playbackspeed`；命中就便宜，不中就归入音频工程 |
| 歌词零碎（逐行释义 / RTL / 间奏三点 / BiniLyrics+Unison） | 3~6 文件 | **3~5** | 间奏动画要自绘 |
| 小项群（Text sizes / Denser rows / Tooltips / Pull to refresh / 队列与设备底部卡片 / sheet 式播放器 / 新进度滑条 / 封面→条动画 / Sleep timer / 彩蛋） | 每条几十~一两百行 | **每条 1 轮，批量 3~5 条一次 → 共 4~6** | 单条都便宜，**合批**是关键 |
| **音频：Music Haptics** | 中等 | **3~5** | 要音频 buffer ⇒ 先有音频图 |
| **音频：DSP 十件套 + AutoEq/DDC + Liveprog** | 大（自研 DSP 链） | **10~15+** | 需先抽 IPA **导入符号表** + fishhook 重绑；**没有把握** |
| **音频：Sing（AI 人声分离）** | 大 | **5~10+** | 同上，且**模型是它的**（得自己找/训一个） |
| Live Activity / 小组件 / 锁屏 / 动态封面 | 大（要 extension target） | —— | 用户已否决/暂缓 |

**合起来**：
- **扣掉音频三块**：约 **22~35 轮**（其中"小项群"和"清理开关"能靠合批压到更少）。
- **加上音频三块**：约 **40~55 轮**，而且音频那部分**风险不是"慢"而是"可能做不出来"**
  （我们是 Swift/Orion、无 Mac；spoti.pw 是 ObjC/Theos、有 Mac 且在音频管线上工作）。

**结论**：**"全加"不划算**。合理做法是分成三批 —— ①便宜大碗（清理开关 + 设置页那批，6~9 轮就能有"很大变化"）；
②中等（诊断 / 变速探针 / Custom navbar，6~11 轮）；③音频单独当**项目**评估，而不是当"功能"排进批次。

---

## 7. 砍掉 **A 区（音频）** 与 **D 区（封面/锁屏/桌面）** 之后

用户 2026-10-02 问："音频功能 / D 区功能不考虑的情况下，工作量是不是少很多" → **是，而且不止是"少"，
是性质变了**：剩下的几乎全是"UI 层、可撤销、框架现成"的活，**没有"可能做不出来"的块**。

砍掉的是：Sing / DSP 十件套 / Music Haptics / 变速变调（A 区，**20~34 轮**里的大头）
+ Canvas/Fluid artwork/动态封面/锁屏歌词/锁屏小组件/主屏 widget/Live Activity（D 区）。

| 剩下的块 | 轮次 | 风险 |
|---|---|---|
| 25 条清理开关 | 2~4 | 低（框架现成；每个目标要先取证） |
| 设置与工具页（导出导入 / Reset / Updates / Licenses / tour / Donate / 遥测计数 / All flags 补齐 AUTO+输入） | 3~4（**小页面能一次写 3~4 个，一轮装一次**） | 低 |
| 歌词零碎（逐行释义 / RTL / 间奏三点 / BiniLyrics+Unison / 开关组合） | 2~3 | 低（间奏动画要自绘） |
| 播放器/队列行为（sheet 播放器 / 新进度滑条 / 队列与设备底部卡片 / 队列角标 / 控制菜单） | 3~5 | 中（要动 presentation 层） |
| ⚠️ **封面→条 morph 动画**（`Bar to cover art animation`） | 2~3 | **高**：pw 是 hook 私有转场类做的；建议**也划掉** |
| 导航栏/标签栏：Custom navbar + Tab **显隐**/Icons only | 2~4 | 中低 |
| ⚠️ Tab **拖动排序** | 3~5 | **高**：要动 Spotify 布局与手势，撞本仓库红线；建议砍成"只做显隐" |
| App 图标选择器 | 2~3 | 中（要改 CI 把图标塞进 IPA） |
| 诊断：tree server + hang sampler | 2~3 | 中（用户侧要跑 iproxy） |
| 小项群（Text sizes / Denser rows / Tooltips / Pull to refresh / 库排序 / 勾状态反馈 / `?` 菜单 …） | 每条 1 轮，**批量 3~5 条一次 → 共 3~5** | 低 |
| ⭐ 白捡 flag 条目（Snake / 关 Canvas / 各类 tooltip / account switching…） | **0 轮代码 + 1 轮验证**（先加进 Flag 覆盖目录点着试） | 无（但**可能点了没反应**，要一条条验） |
| Sleep timer | 1~2 | 低：Spotify 自己有 `com.spotify.service.sleeptimer`（我们日志里出现过），**很可能能借** |

**合计：约 17~25 轮**（对比"全加"的 40~55 轮，砍掉一半以上）。

**如果只要"高价值子集"**（我建议的最小集）：
25 条清理开关 + 设置导入导出/Updates/Licenses + All flags 补齐 + flag 白捡条目 + 诊断 tree server
= **6~10 轮**，覆盖的是 pw 里**日常最常碰**的那部分。

**要点**：砍掉 A/D 之后，**编译器与真机的固定开销**（每轮几十分钟 + 你装机抓日志的时间）
成了主要成本 ⇒ **合批比挑功能更重要**（一次编译带 3~5 条小项）。

---

## 8. 第一批已开工（2026-10-02 夜，用户"行，做吧"）

按 §7 的"高价值子集"开工，**这一轮的交付**（等一次装机验证）：

| 交付 | 说明 |
|---|---|
| ★ **"白捡组"：28 条 flag 目录** | 在 deb 的可见字符串里发现 Spotify 自己的**"减少打扰"模块** `ios-messaging-reduceinterventions-impl`（一条提示一个 flag），配合 9.1.86 的 flag 表逐条核对（`.spotify-ipa/flag-table.txt`）后，加进「已知 flag」的两个新分组：**推广与提示**（10 条 reduceinterventions + 省流量提示/视频 tooltip/免费档推销/演唱会/社交提示）、**界面元素与彩蛋**（播放条元素 7 条 + Canvas + 封面贪吃蛇 + 多账号 2 条）。**零新 hook、零取证**：点一下写一条覆盖，日志里 `[Flags] override … N match(es)` 就是证据 |
| **All flags 补齐** | `EeveePropertyModification.forceInt(Int32)` + 「写入数字」档（`FlagOverride.Mode.number`）→ 整数 flag（节流秒数 / 次数上限）从"只能看"变成"能改" |
| **备份与重置** | `SettingsBackup.swift`：只碰 `UserDefaults.ownedKeys` 白名单 —— `.standard` 里**同时躺着 Spotify 自己的偏好**，全删是"重置 Spotify 状态"那个按钮的语义。导出成 JSON 走**剪贴板**（Spotify 沙箱不对 Files 开放） |
| **更新日志页** | `GitHubRelease` 补 5 个**可选**字段（不影响版本检查）+ 一页列表（tag/日期/正文/打开） |
| **开源许可页** | 只写仓库里查得到的事实（GPL-3.0 / fork 出处 / 内置第三方**没有**随附许可文件就照实说 / spoti.pw 只借鉴思路） |

**下一步（第二刀）要取证的那批**（§7 表里的"25 条清理开关"剩下的部分）：
它们不是 flag，而是**界面元素**（"藏掉播放页下方那张卡""藏掉歌单头里的按钮""藏掉列表上方那块"），
必须先拿到真机树里的 **id / 类名**。取证方式**不用新写探针**：用现成的「转储视图树」，
在**搜索页 / 歌单页 / 播放页 / 首页**各停 2 秒，导出日志即可（转储器一次启动 20 份，
够抓这四屏）。拿到那几份日志我就能把剩下的开关按 `DeclutterChrome` 那套写出来。

---

## 9. ★ 2026-10-02 第三次复核：**v0.23.0-beta 就是最新**（对完 GitHub releases）+ 5 条纠偏

**基准确认**：`releases.atom` 显示最新 tag = **v0.23.0-beta（2026-09-28）**，正是用户给的那份 deb；
本地 checkout 是 v0.22.0 → **上面 §5–§8 的特征集就是当前最新的**，不需要再补。

### 9.1 清点文档里已经过时/写错的 5 条（**别按旧清单派活**）

| # | 文档原话 | 代码现状（2026-10-02 复核） | 结论 |
|---|---|---|---|
| 1 | §1#12 / §5.1 "App 图标选择器 ❌" | **代码已有**：`Settings/Sections/AppIcon/Views/EeveeAppIconPickerView.swift`（挂在 `EeveeSettingsView.swift:122`）+ `Assets/AppIcon/` **34 套图标** + `Tools/alt-icons.sh` | ✅ **2026-10-02 已补上接线**：两个 IPA workflow 都在打包 zip 前调 `Tools/alt-icons.sh "$APP"`（PlistBuddy 写 `CFBundleIcons → CFBundleAlternateIcons`；失败只告警）。真机验收见 `SESSION_2026-10-02_HANDOFF.md` §11 |
| 2 | §5.1 "诊断三件（dump / hang sampler / **FLEX**）" | `EeveeFlex.x.swift` **已有入口**（探测 `NSClassFromString("FLEXManager")`）；但 `Package.swift` / `modules/` 里**没有 FLEX** → 库没随包，入口是 no-op | 已有 🟡：要补的是 **FLEX 随包**（或直接砍掉，见 §9.3） |
| 3 | §1#7 "缺 RTL / 间奏三点动画" | 歌词模块比文档记的强：`LyricGlowTextRenderer`（**有 `.rightToLeft` 分支**）、`LyricLongToneEmphasis`、`AppleMusicInterludeMotionProfile` + `LyricInterlude`（**Apple Music 的间奏运动曲线已移植**，只是没有接线到渲染） | 从"从零写"降级为"**接线 + 间奏检测**"；真正缺的只有 **Genius 逐行释义** + **BiniLyrics / Unison 两个源** |
| 4 | §5.2 "变速变调可能不用碰音频图" | 我们自己**已经在用 KVC 读** `playbackSpeed`（`SponsorBlockSkipper.swift:170`：`state.value(forKey: "playbackSpeed")`）→ 那个 state 上确实有这个键 | 探针价值**上调**：先试"能不能写"，能写就是 1~2 轮的白捡 |
| 5 | §7 "高价值子集" | 已交付：**28 条 flag / All flags 数字档 / 备份+导入+重置 / 更新日志页 / 开源许可页** | 剩下的只有 **25 条清理开关**、**All flags 的 AUTO 档 + 文本输入**、**诊断 tree server** |

### 9.2 pw v0.23.0-beta 里新出现、上面几节没记的小项（对完 release notes）

* ⭐ **"Spotify 不是本 mod 支持的版本"提示** + "EeveeSpotify 已注入"提示 → **对我们特别值**：
  我们全靠类名 hook，刚经历 9.1.86 → 9.1.88 换基线；"版本不匹配就提示"是**极便宜且高价值**的保险。
* `mini player in the tab bar`（迷你条做进标签栏）—— 我们的两条玻璃胶囊已经在同一块地方，属观感选择，不必追。
* `Pitch follows speed`（变速时音高跟着走）、`Karaoke 行条目`、`redesign 可在 iOS 26 以下开（带警告）`、
  `⋯ 菜单用 Music app 的方式画`、`专辑/歌单页把艺人头像放回名字旁`、`Fluid artwork`（封面模糊流动背景）。

### 9.3 复核后的建议（按"一次编译能带几条"分三批）

| 批 | 内容 | 轮次 | 取证 |
|---|---|---|---|
| **A（推荐先做）** | **「减少打扰」子页**（28 条 flag → 人话开关；原料已有）、遥测计数页、状态反馈小项（下载三态 / 勾状态 / `?` 菜单） | 1~2 | **零取证**（都是离线小页面） |

> ⚠️ **2026-10-02 纠偏**：上面原先还列着「All flags 的 **AUTO 档 + 文本输入**」——
> **其实早就有**：`FlagOverride.Mode` = `on / off / **remove** / **set** / **number**`，
> 其中 `remove`（把这条 flag 整个删掉）就是 pw 的 **Auto**、`set` 配 `TextField` 是**文本**、
> `number` 是**数字**（v4.x 那一轮补的，见 §8）。**不要再排这一项**。
| **B** | **25 条清理开关**（我们只有 5 条）—— 复用 `DeclutterChrome` 的"可撤销隐藏 + 复查"框架 | 2~4 | 要一份**四屏转储日志**（搜索/歌单/播放/首页），**可蹭日志 30 顺手抓** |
| **C（探针）** | Sleep timer（Spotify 自己有 `com.spotify.service.sleeptimer`）、变速变调（先只读、再试写 `playbackSpeed`） | 1~2 | 零取证，成了白捡 |
| **不做** | 拖动排序（撞"不动布局"红线）、morph 转场（hook 私有转场类）、10 屏自绘（先给 1 屏样品）、FLEX 随包（性价比低） | — | — |




