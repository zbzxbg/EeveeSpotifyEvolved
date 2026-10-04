# SESSION_2026-10-12_NIGHT — 一轮交互/歌词修复 + 两个老 bug 的根因（**apresolve** / 歌词入口 flag），**下一步开始做页面**

> 上一份入口是 [`SESSION_2026-10-12_HANDOFF.md`](SESSION_2026-10-12_HANDOFF.md)（10 个问题 + 2 条建议那一轮）。
> 这一份是**用户装机之后连着报回来的东西**：先复核那 10 条，再修交互（音量条 / 点歌名 / 歌词键）、
> 设置页与文案、罗马字与 mxm，最后是**追了三轮的那条「突然无法播放任何歌曲」——这一轮抓到根因并修掉了**。
>
> 现场材料：照片 **78–81**（`C:\dsh\else\`）、日志 **57–62**（`C:\dsh\ipa\` 与
> `C:\Users\ngzhwm\Downloads\AyuGram Desktop\`）。**这一版一行都没上过机器**，验收见 §2。

---

## 0. 三十秒现状

> ⚠️ **本文档有两轮**：§1–§7 是第一轮（UI/交互/歌词 + apresolve），**§8 起是同一晚的第二轮**
> （装机之后发现的：标签栏系统玻璃、与上游 fork 的对比、以及**两件要用户做的事**）。
> **先看 §0、§11、§12**：下一步不是写代码，是**跑两个不用重装的 A/B**。

| | |
|---|---|
| 提交 | 两轮共 **28 笔**（`531a6ac` → **`01ece12`**），**已全部推到 `origin/main`** |
| 要编译的 | `main` 最新提交 **`01ece12`**；点 `Build IPA — patched` 时 `Use workflow from` 选 `main`，**`ipa_url` 留空** |
| 自检 | ✅ 六条全绿（orion 329 / brace 329 / member 274 / string 278 / l10n en / l10n zh-CN 418 keys） |
| CI | ⏳ **`Build IPA — patched` 要用户手动点**（本机没有 `gh`，我点不了）。**已经红过一次**（`@MainActor` 隔离，见 §8.4）⇒ 推完先看它绿不绿 |
| 装机 | 🟡 **装了两版**：日志 63 / 照片 82 = 带 apresolve 修复 + 标签栏模块的那一版；**§11 那两个 A/B 请在现在这版上直接做** |
| 一句话 | **先跑 §11 的 A/B（不用重装）→ 把结果告我；同时 §12 那支证据（内容请求日志）我下一轮补上** |

---

## 1. 这一轮改了什么

### 1.1 ★★ 头号：追了三轮的「突然无法播放全部歌曲 / 歌单歌曲消失 / 全是灰色」= **`apresolve` 被当成登出端点**

**用户原话**（分三次说全的）：

> 「退出重进 spotify 大概率会突然无法播放任何歌词」→ 澄清「**不是，我的意思是突然无法播放全部歌曲**，图片 79，怎么按都没反应，
> 但是 premium 那边又显示 eevee，不是 free」→「有时候会**歌单内的歌曲全部消失**，退出再重进就**全是灰色歌曲**了。
> 有时候还有**只展示部分歌曲**的时候，不知道剩下的歌去哪了」（照片 80/81，日志 61/62）

**现场（日志 62，第一次抓到 —— 这个 bug 此前 31 份日志零判据）**：

```
  5: [PLAYER] track changed — pos=9.5s dur=238.0s      ← 在放
117: [PLAYER] track changed — pos=0.0s dur=0.0s        ← 曲目没了
214: [PLAYER] track changed — pos=9.5s dur=238.0s      ← 又回来
240: [PLAYER] ⚠️ position stalled at 9.5s for ~3s (dur=238.0s) - the unplayable evidence line
```

曲目在、时长正常、**位置冻住** ⇒ **音频根本没拉下来**。照片 80/81 补上另两面：歌单显示 **`0 分钟`** 且行不全；
同一列表**整片发灰**（可播放性判不出来）。`drm / widevine / unplayable` **零命中**，`[REVERT_WATCH]` 只有启动那一行
⇒ **不是 DRM、不是地区、也不是我们伪造的 premium 被写回**。

**根因（三处，全是"把 `apresolve` 归进登出那一族"）**：

| 位置 | 原来干了什么 |
|---|---|
| `Premium/Helpers/SpotifyResponsePatcher.swift` `shouldBlock()` | 启动 **30 秒后**拦掉 `apresolve` |
| 同文件 `blockedResponseData()` | 给它回一个假的 **`{"status":"OK"}`** —— 那**不是**合法 apresolve 响应（真响应是 `{"accesspoint":[…]}`） |
| `SessionProtection.x.swift:382` | 同样 30 秒后**直接 `task.cancel()`** |

`apresolve.spotify.com` 回答的是「**音频/内容的接入点在哪**」。App 拿不到接入点 ⇒ 三件事同时出现：
**① 音频拉不动**（位置冻住）**② 内容请求打不到**（歌单空/只加载一部分/`0 分钟`）**③ 可播放性判不出来**（整片灰）。
它同时解释了用户的三个观察：**换代理没用**（本地行为）、**退出重进后大概率**（冷启动才重新解析，且 30 秒后才开始拦）、
**点一下灰色歌曲又能放**（那一下触发新的请求，绕开坏状态）。

**来历**：`git log -S "Cancelled apresolve"` → **2026-09-18 的上游导入提交**（`83dada3` "wow"），**没有任何说明**
—— 不是我们写的，这也解释了为什么查了三轮都没往这儿看。

**改法**（`942e81e`）：三处**全部放行**。登出保护**一点没少**（`session/purge` / `token/revoke` / `DeleteToken` /
`signup/public` / `pses/screenconfig` / `v1/customize` 照旧拦）。`TelemetryEndpointRules.corePathTokens` 里
`apresolve` **本来就在放行白名单** ✓。`[NET] Auth request: … apresolve …` 那行日志**保留**（正是它让这事可见）。

### 1.2 歌词入口 flag 的**静默失效**（`a9d05ac`）

`DynamicPremium+ModifyingFunctions.swift` 里「歌词入口」那条内置替换原本是 **`.setBool(true)`**
（注释自己写着"只改已下发的值、**绝不新增**"），而**服务端下发的就是 `false`**（日志 59 第 16 行逐字）。
凡是**不带**这条 flag 的 customize payload（unauth 配置、增量 payload），我们那一枪**落空且完全静默** ⇒ 歌词入口消失。
用户手动加的覆盖"能好一小会"正是因为它走 `.forceBool`/`.forceEnum`（**有追加能力**）—— 两条路能力不对等就是这个 bug。

**改法**：升级成 `.forceBool(true)`（命中就钉住、没下发就补一条）+ 新增
`reportEntryPointFlagPresence()`：**每份 payload** 的"有/没有"**状态翻转时**报一行（现有
`reportLyricsReplacementOutcome` 是"每个 key 只报一次"，恰好把后面那份 payload 挡住了，而问题就出在后面那份）。

### 1.3 交互：三处「看得见、点不动」

| 症状 | 根因（实证） | 改法 |
|---|---|---|
| **音量条是装饰** | 覆盖层 `isUserInteractionEnabled = false`（为"不吃原生手势"）+ 音量那一行也 false ⇒ UIKit 命中测试**在父视图那级就停了**，里面那颗真的 `MPVolumeView` 收不到触摸 | 改 `NowPlayingOverlayView.point(inside:)`：整层开交互、**只放行音量那一行**（与 `NowPlayingLyricsContainerView.passThroughBottom` 同一手法）；行开交互、两个装饰喇叭仍关 |
| **点歌名/歌手不能跳专辑/艺人页** | 那一行被 `transform` 抬到左上角，但**仍在原 cell 里** ⇒ 命中测试只在点落在 **cell frame 内**才往下走 ⇒ 看得见摸不到 | 照 pw `PlayerLyrics.x:100-104` 的做法：加 `NowPlayingTitleRelayView`（铺满页面、`hitTest` 把点**换算**进那一行并返回它命中的子视图），**展开/收起都摆**；前几次转发打日志 |
| **只开「逐词歌词」时歌词键点不动** | 键总开关只判「歌词进播放器」，而 `canShow()` 要求「更好的逐词歌词」⇒ 键照摆、吃触摸、点下去 false | **把门禁放对地方**：`isEnabled` / `canShow` / `hasLyricsAvailable` 里**都不再要求**「更好的」（这一层画的就是那套渲染，没有第二种可选）；那颗开关只决定 **Spotify 原生歌词页**用哪套渲染（`AppleMusicLyricsOverlay` ↔ 旧 `LyricsWordByWord`） |

### 1.4 歌词数据层

| 改动 | 要点 |
|---|---|
| **mxm 不再替换原文**（`d3f95cc`） | 与网易 `romalrc` **同一套机制**：原文不动，罗马字存 `LyricsDto.officialRomanizedLines`。⚠️ 长度**必须** `== lines.count`（没匹配的留空串），否则整套被忽略。`♪` 清洗对那份也做 |
| 适配器判据**语言感知**（同笔） | 原来**写死日语开关** ⇒ 中文/韩文的官方罗马字"读到了、存下了、然后整份忽略"。现在按 `languageCode` 问对应开关，**日语那条既有行为一个字没动** |
| **主歌词首字母大写**（`1c59265`） | 大写约定早有（会跳过 `「 " （ [` 与零宽前缀），但只做在 payload/罗马字上，**我们自己画的主歌词原文没做** ⇒ 英文歌首字母小写。新增 `LyricsDto.capitalizingFirstLettersForDisplay()` 在 `storeLyricsDto` **落一次**（含**逐词 token**的"第一个含字母的词"）；**幂等**（判据是"token 里有没有字母"，不是"这次改没改动"） |
| 官方罗马字首字母（`531a6ac`） | 只动**显示那一份**，主歌词与词级对齐不受影响 |
| 折行行距（同笔） | `SynchronizedLyricText` 原来把 `lineSpacing`（`.player` 档 **26pt**，那是"块间"间距）当成**一行自己折行**的行距 ⇒ 折一次像空一整句。新增 `wrappedLineSpacing`（player 6 / 全屏 5 / 预览 3） |
| 折行诊断（同笔） | 旧判据用 `字数 × 字号 × 0.55`（拉丁文系数）⇒ 日文行估不出来、**日志里一条 `[LyricWrap]` 都没有**。改成真实 `measuredTextWidth` vs `effectiveLayoutWidth` |

### 1.5 设置页与文案

| 改动 | 要点 |
|---|---|
| **全仓库 `.listStyle` 统一成 `InsetGroupedListStyle()`**（`ae84d29`） | pw 的做法就是 `UITableViewStyleInsetGrouped`（11 个文件都是这一句，内容用 `UIListContentConfiguration`）—— **没有自绘**，iOS 26 上系统把它画成"胶囊卡片"。17 个文件从 `GroupedListStyle()` 换过来，另 6 个本来就是 ⇒ 23 处一致；`InsetGroupedListStyle` 是 iOS 14+，**不抬高底线** |
| **新开关「未播放歌词行模糊化」**（`8623813`） | **默认关**（关 = 只变淡不发糊）；并进 `romanizationSwitchesFingerprint()`，否则是"哑开关"（拨了要等换歌） |
| **彩蛋「替换寻找歌词时的占位符」**（`88a6b7c` / `a4b5734`） | 调试页、转储视图树**下面**；开着把「正在查找歌词…」写成「少女祈祷中…」；footer 只写"一个小彩蛋。" ⚠️ **那一行 footer 已于 2026-10-13 按用户要求删除**（`lyrics_search_placeholder_easter_egg_description` 两个语言键一起删，开关保留）。**全仓库只有一处**写那句占位文本（`noticeText()` 的"还在查"分支） |
| 一屏说明补回（`59cfbcc`） | 分区 footer 改成通用说明后，原来那两句（"卡片全折起来/歌词卡也被折掉"）**没地方显示了** ⇒ 挂回那颗开关标签里的第二行小字 |
| flag 说明与行为对齐（`51f2c39`） | 中文那条描述的是**旧交互**（"点一行即可填入上面的表单"），与代码（点一下=加覆盖、再点一下=取消、改取值去上一层、未观察到数值的 int 点不了）不符 ⇒ 中英一起重写；一屏标签英文对齐中文（`Hide Spotify's now-playing modules`） |
| l10n 同步若干轮（`4cf4413` / `a840cdd` / `b6ca6e0` / `a5e2333`） | 用户**自己改中文**、我同步英文。分区键改名 `now_playing_backdrop_{section,description}` → `now_playing_{section,section_description}`（只有 en/zh-CN 有这两条）；删掉 AMLL/逐词介绍里"不展示歌词翻译"那句（已过期）；`补充模块5` 的含义**仓库注释自己对得上**（`EeveeDebugSettingsView.swift:17`：「往元素列表里补 `5`」） |

### 1.6 诊断

- **播放探针补盲区**（`6f50dbc`）：`Diagnostics/PlayerStateProbe.swift` 原来只在 `duration > 0` 时判"卡住"，
  `dur=0` 直接 `return` ⇒ **"什么都没有"这件事一行都没有**（日志 61 就那一条）。现在补两行（各一次）：
  `⚠️ no track loaded for ~Xs (Ys since launch) - nothing can play in this state` 与
  `first track after launch — Xs in`。
- **`ORION ERROR` 两条是良性的**（实证）：`-[NowPlayingPlatformSwiftServiceImplementation provideStatefulPlayer]`
  与 `-[SPTPlayerServiceImplementation addPlayerObserver:]` 每次启动都报，但日志紧接着有
  `[Lyrics] statefulPlayer resolved (feature: …)` ×25 个 feature + `[WordByWord] position source: statefulPlayer.position()`
  ⇒ **多 feature 兜底接上了**，进度也读到了。**别为这两条去改 hook**。
- ⚠️ 但同一处暴露了一个**真缺陷**：`[SB] player observer hook cannot install — SB will not see playback state`
  ⇒ **SponsorBlock 看不到播放状态**，自动跳过实质是哑的（见 §4）。

---

## 2. ★ 装机验收（下一轮照这张单子）

### 2.1 先点一次 CI

`Actions → Build IPA — patched (Orion.framework + zxPluginsInject) → Run workflow`，`ipa_url` **留空**
（`.deb` 那一步无条件跑 = 把全部 Swift 编一遍）。**它红了就先修编译，别的都别验。**

### 2.2 判据（按顺序，一条一张照片）

| # | 怎么做 | 应该看到 | 日志判据 |
|---|---|---|---|
| ① | **退出重进 3–5 次** | 歌单**不再变空/变灰**；歌**不再卡住** | **不该再出现** `[NET] Cancelled apresolve`；`[PLAYER]` 里不该出现 `⚠️ position stalled …` / `⚠️ no track loaded …` |
| ② | 进播放器（**不展开歌词**） | 缩封面 ≈242pt、标题在左上、控件条在、封面下那行居中歌词在 | `[NPVLyrics] … cover shrunk in from …`；`left the layer …`；`the one-line lyric … is up` |
| ③ | **点歌名 / 歌手** | 弹专辑 / 歌手页 | `forwarded a tap into the moved title row — forward #N` |
| ④ | **拖音量条** | 音量真的变 | —— |
| ⑤ | 点歌词键展开 | 歌词进来；「未找到/纯音乐/没有时间轴」各有各的说法 | `our layer is not in play (…)` **不该出现**（除非开关关着） |
| ⑥ | ⏮/⏭ 连点 5 次 | **每次**大封面都在 | 不该有"只有 `not expanding …`、没有 `expanded —`"的成对现场 |
| ⑦ | 日文逐词歌 + 开日语罗马化 | **原文在、罗马字在它上方**；译文在下方 | `official romaji kept for the line above (N line(s))`、`translation N/M romanization M/M`（两个都别是 0） |
| ⑧ | **英文歌** | 每行**首字母大写**（含 `「` 之后那个） | —— |
| ⑨ | 设置 → 扩展功能 | 页面是**胶囊卡片**（inset-grouped） | —— |
| ⑩ | 拨「未播放歌词行模糊化」 | **一秒内**非当前行变糊（默认关着时是"只变淡"） | 指纹变了 ⇒ 宿主重建（不用等换歌） |
| ⑪ | 设置 → 调试 → 最下面 | 多一节**「替换寻找歌词时的占位符」**，footer「一个小彩蛋。」；开着换首歌 ⇒ 那句变成「少女祈祷中…」 | `[Settings] lyrics search placeholder easter egg -> ON` |
| ⑫ | 「一屏」那颗开关下面 | 有第二行小字说明（卡片全折起来 / 歌词卡也被折掉） | —— |
| ⑬ | 已知 flag 页说明 | 与行为一致（点一下=加覆盖、再点一下=取消、改取值去上一层） | —— |
| ⑭ | 只开**逐词歌词**、关掉**更好的逐词歌词** | 播放器**照旧是我们的版式**，歌词键**点得动** | `[Flags] user overrides in effect: N` |
| ⑮ | 那 4 条歌词行/标题行/封面/末行贴底（上一轮的老账） | 见 `SESSION_2026-10-12_HANDOFF.md` §3 | 同上那份 |
| ⑯ | **额外换行**（用户报过、说"之后再说"） | 若复现：看 `[LyricWrap]` 那几行 | 新诊断会写出**哪一行、text 多宽、layout 多宽、断点** |

### 2.3 这一版最该看的两件

1. **`Cancelled apresolve` 必须消失**，且 ① 的症状不再出现 —— 这是本轮的**核心修复**；
2. 如果**还是**卡/空：下一份日志现在会自动带 `⚠️ no track loaded …` / `first track after launch — Xs in`，
   以及 `[NET] Auth request: … apresolve …` ⇒ 能立刻分清"没曲目"还是"有曲目但不走"。

---

## 3. ★★ 下一步：开始做页面（用户点名要的）

### 3.1 结论：**先「音乐库」，再「歌单」**（按"原语复用 + 风险"排序，不是按可见度）

| 顺序 | 页面 | pw 的规模 | 为什么 |
|---|---|---|---|
| **1** | **音乐库 Your Library** | 4 文件 / **418 行**（`LibraryHeader` 259、`LibraryRows` 83、`LibrarySearch` 55） | 最小的一片；**根页面**（其他页都从它进）；我们**已有验证过的钩子**；产出的全是**可复用原语** |
| 2 | **歌单 Playlist / Liked Songs** | 5 文件 / **1166 行**（`PlaylistHeader` **575**、`PlaylistMenu` 347、`PlaylistRows` 102、`PlaylistField` 99） | 最出彩（全出血封面 + 取色场 + 玻璃控件行），但要吃掉上面那些原语；贵在"取色场" |
| 3 | 专辑 / 艺人 | 818 / 606 行 | pw 自己说这两页**是另一套框架**，它没动 |

> ⚠️ 仓库 2026-10-01/02 的旧计划写的是「歌单 → 专辑 → 艺人 → 资料库」。**这一份建议反过来**（理由如上）。
> 用户 2026-10-12 听过这个建议，**尚未拍板**。

### 3.2 音乐库三片（每片一张照片验收）

| 片 | 做什么（pw 的原文意图） | 我们的起点 |
|---|---|---|
| **L1** | 头部：**大标题靠左 + 头像靠右 + 去掉顶部灰纱**；**筛选 chips 保留**（pw 删过又装回来 —— 排序没法用了，issue #20） | `Appearance/LibraryAppearance.x.swift`（277 行）**已经在 hook `YourLibraryView`**，大标题 `24pt → 30pt` **已上机器验证**（2026-10-02 日志 19，且没被 binder 写回），0.5s 复查节拍也在 ⇒ **L1 主要是"头像靠右 + 去灰纱"** |
| **L2** | 行/网格：**连续圆角**（Spotify 自己 4pt 是直角味；艺人头像的半圆**保持圆**）+ 行间**发丝线从文字起始边开始** | 全新 |
| **L3** | 库内搜索框 + Cancel **变胶囊**（pw：Spotify 自己那层玻璃已经有了，**缺的只是形状**） | 全新 |

### 3.3 三条 AM 化硬规矩（都是 pw 文档里的原文依据）

1. **先试 Spotify 自己的 flag**：`enable_full_bleed_header_list_layout`
   （scope `ios-listuxplatformconsumers-fullbleedheaderlayoutplugin-impl`）。
   ⚠️ **我们已经试过了，结论：没用**（见 §3.4）。
2. **只在 Spotify 自己的视图上改样式/加层，绝不重写页面**（pw 的文件头原话：
   *"with its controllers, its list and its rows, decluttered…"*）—— 也是 2026-10-02 那版自绘壳被整块删掉之后立的规矩。
3. **元素行里的字号一律不动**（pw：行高 64pt、标题 18pt，是 element framework **量好的盒子**，放大会被裁）；
   能放大的是**页面大标题**（我们已有 30pt 的先例）。
   两条实现细节直接抄：**发丝线用 layer + `actions` 关掉**（cell 复用极快，加视图会看到线"滑"进来）；
   **取色场垫在最底层且比页面大一圈**（Spotify 的 header 自己会从 y=-134 滚到 -529）。

### 3.4 ★ flag 实验的结论（2026-10-12，**已经试完**）

用户在「Flag 覆盖」页加了 `enable_full_bleed_header_list_layout`（scope
`ios-listuxplatformconsumers-fullbleedheaderlayoutplugin-impl`，**强制开启**）→ 界面**无变化**。日志 59/61/62 逐字：

```
[Flags] override ios-listuxplatformconsumers-fullbleedheaderlayoutplugin-impl.enable_full_bleed_header_list_layout
        — 0 match(es) (server did not send it; we append our own)
[Flags] user overrides in effect: 1
```

⇒ 覆盖**在册**、**追加成功**、并且**重启了两次**（06:50:09 / 06:50:22 两次启动横幅），但界面没变。

**结论：这条 flag 在 9.1.88 上不是歌单头那个开关**（`listuxplatformconsumers` 更像另一套列表框架；
而且 **pw 自己也没用它** —— 它的歌单头是 `PlaylistHeader.x` **575 行**手写的）。
⇒ **歌单头部要自己画**。**不要再花时间试这条 flag**（要试别的，先看 §3.5 的红线）。

### 3.5 红线与风险

- **不动别人的布局**（这条线在 2026-10-01/02 已经划过并吃过教训）：只改样式/加层，写上去的必须能**精确还原**。
- 音乐库那层**已经有"被 binder 写回"的先例**（2026-10-02：`24pt → 30pt` **没**被写回 ✓，
  但滚动边缘效果那条被删了，因为它每 0.5s 清零是在**和别人的滚动动画对着干**）⇒ **每加一处都要问"值会不会被写回"**，
  会写回的就走复查节拍，不改的就别改。
- 做页面前先看 `git diff`：`LibraryAppearance` 里有"原值还原"的写法，**别把还原那一行删掉**。

---

## 4. 仍然挂着的其他事（用户已明确"碰到再说"的排在后面）

| # | 事 | 现状 |
|---|---|---|
| 1 | **SponsorBlock 看不到播放状态** | `[SB] player observer hook cannot install`（`-[SPTPlayerServiceImplementation addPlayerObserver:]` 钩不上）⇒ **自动跳过实质是哑的**。已发现、**未修**（问过用户要不要修） |
| 2 | 短歌（≤5 块歌词）当前行可能不再居中 | 播放器档底边距 240→24 的固有取舍（`SESSION_2026-10-12_HANDOFF.md` §4）。用户说"碰到再说" |
| 3 | 旧 UIKit 逐词层没有罗马字 | 同上一份 §4（它那份是"替换"语义，按用户的选择不该保留） |
| 4 | 罗马化三个键的字面量散在 4 处 | `NgzhwmSettingsViewModel` / `LyricsDto` / `NeteaseLyricsRepository` / `MusixmatchLyricsRepository`（+ `LyricLinesAdapter`）。收敛是单独一次改动 |
| 5 | **额外换行** | 用户报过、说"之后再说"；诊断已改成真实测量，等日志 |
| 6 | **iOS 16.1–18 的覆盖** | Spotify 自己最低 **16.1**（`Spotify-9.1.88.ipa` 的 `Info.plist`：`MinimumOSVersion = 16.1`，`DTPlatformVersion = 26.2`，`UIDesignRequiresCompatibility = true`）② 我们的听歌页层是 **26+**（`NowPlayingLyricsPlate` 的 `apply/reconcile/coverDidLayOut/layoutAndMount/canShow` 各有一道 `#available(iOS 26)）` ⇒ 16.1–18 上**整层不参与**。**可做**：把"版式层"那 4 处门拆开（歌词仍走原生 + 旧 overlay）；**渲染层降到 18** 要换掉 `attributedTextFormattingDefinition`（**唯一**的硬闸，见 `LyricAttributedText.swift:20-26`），是**中等偏大**的活 |
| 7 | 「更好的逐词歌词」在 26 以下应**置灰** | pw 的做法：26 以下那颗开关**是灰的**（不是"看起来能用、点了没反应"）。我们该照做（小活） |
| 8 | 兼容性自检 | 用户问过"pw 那个检查适配的" —— **pw 其实没有**（只有 Mod 页显示版本 + README/bug 模板写死 9.1.78）。真有用的是**哨兵自检**（关键锚点/类在不在本机），不是比版本号。**未做** |
| 9 | `[PLAYER]` 探针的 `isPaused` | 2026-10-03 计划里那条"只读 `isPaused`"（`SPTNowPlayingPlaybackControllerImplementation` 在 9.1.88 上存在，探针实测过）**仍未做** —— 这次不需要它（`apresolve` 是根因），但留着以后用 |
| 10 | 文档债 | 这次 flag 实验的结论**已在本文 §3.4 记录**；`FLAGS_9186_DESIGN.md` 里可以加一句回指 |

---

## 5. 用户的要求与规矩（**照做**）

**硬规矩（用户明确说过/仓库纪律）**

1. **一次只改一处**，改完**六条自检必须全过**才算完：
   `orion_hook_guard.py` / `swift_brace_check.py` / `swift_member_check.py` / `swift_string_check.py` /
   `l10n_lint.py --locale en` / `--locale zh-CN`。
2. **commit message 用英文**（"外国人用的多"）；**代码注释用中文**；**日志字符串用英文**；
   一个日志表达式里**不许嵌双引号字面量**。
3. **作者必须是 `zbzxbg <yuanhainigu@outlook.com>`**（用户纠正过一次；**不许**用 `-c user.name` 临时覆盖）。
4. **证据优先**：改之前先看**照片 / 日志 / `file:行`**；"猜"要写明是猜。**同一个判据只留一份**（抄两份 = 迟早只修一份）。
5. **不动别人的布局**：只改样式 / 加层；写过的值必须**精确还原**（关开关、离开页面都不许留痕）。
   绝不留下"看得见、点不动"或"永久空白"的状态。
6. **l10n**：`en` 是**唯一源**（其它语言回落英文）；**`zh-CN` 同步**。用户会**自己改中文**然后让我同步英文。
   文案要**短、说人话**；已经过期的说明要删（例："开了更好的逐词歌词就不显示翻译"）。
7. **`pwsh` 必须带 `sandbox_permissions: "danger-full-access"`**（否则 `0xC0000142 STATUS_DLL_INIT_FAILED`）。
   另外这台机器上**个别文件会间歇性"找不到/读到旧内容"**（`EeveeExtrasSettingsView.swift` 踩过三次）
   ⇒ 改之前**先校验读到的是最新版本**（比对已知标记 + 长度），改完**重读复核**。
8. **装机验收**：代码改完**必须让用户点 `Build IPA — patched`**（本机没有 `gh`，我点不了）；
   装完**拍照片 + 存日志**（`C:\dsh\else\NN.jpg`、`C:\dsh\ipa\eeveespotify_debug_shared NN.log`）。

**沟通偏好**

9. **中文回答、结论先行**；**不要长时间沉默**（宁可先交一批能装的改动，再继续）。
10. 用户会**边用边报**：报了就按"证据 → 根因 → 改法 → 怎么验"回，**不要**让他重复描述第二遍。
11. 用户说"**碰到再说**"/"**之后再说**"的，别自作主张去做（§4 那张表就是这些）。

---

## 6. 未验证声明（**不要删这一段**）

* **这一轮 12 个源码文件 + 2 个 l10n 文件，一行都没在真机上跑过。** 本机**没有 Swift 工具链**，
  "能编译"只有 CI 能回答；六条自检**不做类型检查**。
* **`apresolve` 那条是"实证 + 推理"**：日志 62 的 `position stalled` 与照片 80/81 是实证，
  三处拦截的代码是实证，**"改完就不卡了"没在机器上验过**（§2.2 ① 就是验它）。
* **两处交互修复**（音量条的点放行、标题行的 `hitTest` 转发）是"照 pw 的做法 + 触摸链推的"，**没验过**。
* **mxm 那条"不再替换"**：机制与网易同一套（那套**也没验过**），而且**长度必须等于行数**这条硬要求
  写错就会"整份被忽略、罗马字一行都不显示"——下一份日志看 `[Musixmatch] romanization kept as the line above the original — N/M`。
* **`hasLyricsAvailable()` 去掉「更好的」判据**之后，**只开逐词歌词**那档的键**不再是灰的**（这是刻意的）——
  如果用户觉得该灰，改回去要连 `canShow` 一起想（别只改一处）。
* **探针新增的两行**能覆盖"没有曲目"，但**覆盖不了**"有曲目、位置在动、但没声音"那种（要 `isPaused`，见 §4.9）。
* **`UIDesignRequiresCompatibility`**：本机那份**解密 IPA**里它是 `true`（Spotify 自己写的）；
  我们打 IPA 时删掉它（CI `liquid_glass` 默认开）—— 用户装的那版**玻璃是生效的**（照片 78 可见），
  所以"flag 没效果"与那条硬闸**无关**。

---

## 7. 下一轮最容易踩的三件事

1. **先跑 §11 的两个 A/B**（不用重装，各 2 分钟）——它们比再猜一轮都值钱；
   跑完再点 CI（`Build IPA — patched`，`ipa_url` 留空）：**已经红过一次**（§8.4 的 `@MainActor`）。
2. **`apresolve` 这条要盯住，但别再当它是根因**：日志 63 证明修复生效（`Cancelled` 零命中）而症状还在
   ⇒ 假设**被证伪**；它现在是"与上游不同的一处"（§9.3），留着 + 盯，**别急着再动它**。
3. **做页面时**：先看 §3.3 那三条 + §3.5 的红线；每片**只拍一个判据**；
   动 `LibraryAppearance` 之前先 `git diff`，**别把"原值还原"删掉**。

---

# 第二轮（同一晚，装机之后）

## 8. 标签栏：换成**系统 `UITabBar`** 的真玻璃（用户点名要的"像 pw 那样"）

### 8.1 起因与结论

用户看出差别：*"我做的标签栏液态玻璃是不是和 pw 的不一样，我的只是看起来是个液态玻璃胶囊，
pw 的是不是可以像果冻一样，并且可滑动的"* —— **对，而且路线完全不同**：

| | pw（`Redesigned/Navbar/TabBar.x`，492 行） | 我们（改前） |
|---|---|---|
| 做法 | Spotify 那条栏**留着但隐形**，上面叠一条**系统 `UITabBar`** | **手拼** `UIGlassEffect` 胶囊贴在图标行下面（994 行，逐像素校准） |
| 玻璃 | **UIKit 画的真玻璃**（选中气泡、折射、明暗自适应）—— 原文：*"with no glass API of ours"* | 我们自己的玻璃层 |
| "会滑" | **系统栏的选中气泡在 item 之间滑动/形变** | 没有：选中态是 Spotify 自己那颗白色标签 |
| "果冻" | 系统玻璃的交互物理 | 只有**按下回弹**（`UIGlassEffect.isInteractive`） |
| 拖动 | **也不能拖**：那个 `UILongPressGestureRecognizer` 是"长按主页图标进设置" | v4.3 拖过、v4.6 按用户要求删了（会被误拖） |

### 8.2 新增模块 `Appearance/TabBarSystemGlass.x.swift`（四步照 pw）

① 藏 Spotify 那几颗的**图标与文字**（不是整颗）；② 叠系统栏、item 从原栏同步；
③ 选中态跟着"白色那颗"走；④ 系统栏更高时把差额写进 `TabBarContainerImpl.additionalSafeAreaInsets.bottom`
（Spotify 自己把栏 / 迷你播放器 / 页面一起让开）。**开关默认关**：设置 → 扩展功能 → 标签栏 →「标签栏改用系统玻璃」；
与旧的自绘胶囊**互斥**（`TabBarGlassPlate.isEnabled` 现在两颗开关都要看）。

### 8.3 第一次真机（日志 63 + 照片 82）→ 三处已修（提交 `d99b5fd`）

| 用户看到 | 根因 | 现在的做法 |
|---|---|---|
| **整条栏点不动**（"划不动"） | **我们的错**：把整颗 item 视图按成 `alpha = 0`，而 UIKit 命中测试**跳过 alpha < 0.01 的视图** ⇒ 点击落不到 Spotify 那几颗上 | 只藏**图标与文字**两个子视图，item 视图 alpha 不动 ⇒ 看不见但照样收触摸 |
| **图标不见了** | 系统栏只拿到标题（`glyphImage` 深度 ≤ 4 找不到），原图标又被藏了 | 图标/文字都找到**深度 6**；**先同步后隐藏**；**拿不到图标的那颗就不藏原图标**（安全网） |
| 「隐藏标签栏文字」**不生效** | 文字由**系统栏**画，而那颗开关归让位的那盘胶囊管 | `tabBarHideLabels` 开着时**不给系统栏标题** |

另外两条**实测**（别再猜）：`accessibilityTraits` 在 9.1.88 上**没有 `.selected`**（四颗 `traits=0x0`）
⇒ 选中态实际靠**文字亮度**（`主页` `#FFFFFF` vs 其余 `#B3B3B3`）；`made room` 那行没出现**是对的**
（`83 − 49 − 34 = 0`，Face ID 机型两条栏本来就对得上）。

### 8.4 CI 红过一次（`@MainActor`，提交 `619c947`）

```
TabBarSystemGlass.x.swift:80: call to main actor-isolated static method 'findTabsStack(in:)'
                              in a synchronous nonisolated context
```
`TabBarGlassPlate.findTabsStack(in:)` 是 `@MainActor`（`:872`）⇒ 新模块**整个 enum 标 `@MainActor`**
（`NowPlayingControlsPlugin` 同款写法）。两条证据：`onMainThreadSync` 的闭包类型本身就是
`@escaping @MainActor () -> Void`（`LyricsChromeVisibility.swift:25`），设置页 `persist` 闭包与既有的
`NowPlayingControlsPlate.reapply()` 同一上下文 ⇒ **两个调用点都不用包东西**。

### 8.5 还没做（第二片）

**"果冻"要系统栏接管触摸**：接管之后必须把点击**转发**给 Spotify 那一颗（pw 用 objc runtime 读手势
识别器的 target/action）。转发入口的优先链应当是：`UIControl.sendActions` → `accessibilityActivate()` →
runtime 读 recognizer；**哪条真能触发只有真机日志能回答**，所以第一片先不吃触摸（点击行为不变，零风险）。

### 8.6 下一版要看的两条（日志）

`[TabBarSystem] items synced — … ; icons [Y,Y,Y,Y]`（出现 `N` 就说明还有图标没找到，把那行发我）
与 `[TabBarSystem] selection signal in use: bright label`。

---

## 9. ★ 与上游 fork 的对比（用户点名："对比一下那几个 eeveespotify 仓库处理 premium、http 有什么不同"）

### 9.1 本地就有三个上游 fork —— 不用上网

`C:\Users\ngzhwm\Documents\GitHub\` 下有 **`EeveeSpotifyReincarnated`**、`EeveeSpotifyReborn`、
`EeveeSpotifyReborn-ng`（+ `kumone`、`MeloX`、`spoti.pw`）。**whoeevee 原仓库已被 GitHub DMCA 封**
（`api.github.com` 返回 **451**）⇒ 只能拿本地这几个比。

**`EeveeSpotifyReincarnated` 是最近的同代 fork**（Reborn 那两代**连这些文件都没有**）：

| 文件 | 我们 | Reincarnated | 说明 |
|---|---|---|---|
| `SessionProtection.x.swift` | 350 | 340 | **逐行一致**（含 `apresolve` 的取消） |
| `Premium/DynamicPremium+ModifyBootstrap.x.swift` | 108 | 108 | 一致 |
| `Premium/Helpers/SpotifyResponsePatcher.swift` | **727** | **165** | 多出的 560 行 = 我们的 **flag 覆盖机制 + 探针** |
| `DataLoaderServiceHooks.x.swift` | 290 | 180 | 多出的是我们的 **`LyricsResponseCache`**（会用缓存顶掉真实响应，只作用于歌词路径） |
| `HttpClientURLSessionHooks.x.swift` | 240 | 153 | 同上 |
| `EeveePremiumForce.x.swift` | 228 | 205 | —— |
| `Premium/Models/EeveePropertyReplacement.swift` | 32 | 18 | 我们多了 `.forceEnum` / `.forceInt`（**追加进配置**的能力 —— 用户那条 full-bleed 覆盖走的就是它） |
| `Privacy/TelemetryBlocker.swift` | 89 | **没有** | 我们自己的上报拦截 |

### 9.2 ★ 找到的那条真差异：`cachedCustomizeData` **我们只有内存**

```
上游（Reincarnated）：
  SpotifyResponsePatcher.swift:26    UserDefaults.cachedCustomizeData = newValue
  DataLoaderServiceHooks.x.swift:61  if url.isCustomize, let cached = SpotifyResponsePatcher.cachedCustomizeData
  DataLoaderServiceHooks.x.swift:62      ?? UserDefaults.cachedCustomizeData {

我们（改前）：只有内存 `_cachedCustomizeData`（+ 启动时用随包 `resolveconfiguration_*.bnk` 喂一份）
```

**机制**（正好落在用户说的"退出重进之后"）：新进程刚起 → 随包快照没拿到（或 Spotify 换了文件名）
→ 服务器对 customize 回 **304**（很常见）→ `cachedCustomizeData == nil` ⇒ **我们交不出 body**
⇒ App 拿到空配置 ⇒ premium / 可播放性降级 ⇒ **歌单发灰、歌曲消失、放不动**（用户报的三个症状）。

**已对齐（提交 `01ece12`）**：setter 同步落盘（沿用上游键名 `eeveeCachedCustomizeData`；
**刻意不进 `ownedKeys`** —— 它是缓存不是设置，不该进备份、不该被"清空设置"连坐），
四处读取都补 `?? UserDefaults.cachedCustomizeData`（两个传输层各两处，304 回放那两条路）。

### 9.3 `apresolve`：**与上游不同的一处**（保留 + 盯）

对比结果：上游/Reincarnated **也**把它当登出端点拦（`shouldBlock` + `blockedResponseData` 回
`{"status":"OK"}` + `SessionProtection` 里 30 秒后 `cancel()`）⇒ **那不是我们引入的**（`git log -S`
追到 2026-09-18 的上游导入提交），而我们的修复（`942e81e`）**逆着上游**。

**证据判它无效**：日志 63（带修复的那版）里 `apresolve` **只被记一次、`Cancelled` 零命中**，
而用户的灰色/空歌单**照旧** ⇒ **假设被证伪**。

**处置**：**保留**（给"接入点解析"回假 `{"status":"OK"}` 本身没道理，且没有任何证据表明它有害），
但**标注成"与上游不同、待观察"**。要完全对齐上游：把那三处改回来即可
（`SpotifyResponsePatcher.shouldBlock` 一条、`blockedResponseData` 一条、`SessionProtection` 里那段
注释换回原来的 `task.cancel()`）。

---

## 10. 还缺的那支证据：**内容请求到底拿到了多少**

"歌单里的歌全部消失 / 只显示一部分"至今**没有直接判据** —— 我们的响应钩子只记**歌词路径**与几个探针，
**播放列表/内容请求一行都不记** ⇒ 分不清"**服务器只给了几行**"还是"**UI 把它们丢了**"。

**下一轮补**（照仓库已有的只读探针写法，如 `probeHasLyricsKey` / `CasitaResponseProbe`）：
在 `DataLoaderServiceHooks` 与 `HttpClientURLSessionHooks` 的 `didReceiveData` 里，
对一小组**内容路径**（`playlist/v2`、`metadata/4`、`context-resolve`、`collection/v2`、`browse/`、`hub/`…）
记 **URL 路径 + HTTP 状态 + 累计字节数**（只在完成时打一行、有上限、**不记内容**）。
判读：字节数为 0 / 明显偏小 ⇒ 服务端就没给；字节正常而界面空 ⇒ 是我们或 App 的渲染层。

---

## 11. ★★ 请用户做的两个 A/B（**不用重装**，各 2 分钟）

现在装的那版就够（两个开关都在设置页里）。**做完把"A 还灰不灰 / B 还灰不灰"告我**。

| # | 做什么 | 若"不灰了"意味着 | 我接下来做什么 |
|---|---|---|---|
| **A** | 设置 → **Flag 覆盖** → **清空全部覆盖** → 完全退出重启 → 用一会儿 | 元凶是**我们往配置里追加 flag** 那套（`.forceEnum`/`.forceInt` 的 append 能力；用户当前有一条 full-bleed 覆盖） | 把 append 收窄：只对**已知安全**的 flag 追加、并校验追加进去的 `AssignedValue` 形状 |
| **B** | 设置 → 补丁 → 打开「**不要补丁 premium**」→ 完全退出重启 → 再看 | 元凶在 **premium 层**（customize / premium 那份配置） | 继续按 §9 往上游对 `SpotifyResponsePatcher` 的 flag 改动，一条条 A/B |

**两个都不灰了** ⇒ 各自按上表处理；**两个都还灰** ⇒ 基本可以排除"我们的配置层"，
转向 §10 那支证据（内容请求字节数）+ 账号/地区那条线（`SESSION_2026-10-03_HANDOFF.md` §2.3 的 H1/H3）。

---

## 12. 第二轮的其它小账

* **探针的"没有曲目"那行太急**：日志 63 里两次都是 `~3s (5–6s since launch)` —— 冷启动 5 秒还没载入曲目
  **是正常的** ⇒ 下一轮把阈值提到 **~10s**（否则每条日志都会带一行噪声，反而看不出真现场）。
* **`selected flags [----]`** 已被 `syncSelection` 的"亮度优先"接住（§8.3），但日志里那一段仍会打 `----`
  （它读的是 traits）—— 别把它当成"选中态失效"。
* **上一轮那 16 条验收**（§2.2）**依然有效**，其中 ①（`Cancelled apresolve` 消失）**已验证 ✓**；
  ⑮（上一轮 10 个问题）见 `SESSION_2026-10-12_HANDOFF.md` §3。

