# SESSION_2026-10-12_NIGHT — 一轮交互/歌词修复 + 两个老 bug 的根因（**apresolve** / 歌词入口 flag），**下一步开始做页面**

> 上一份入口是 [`SESSION_2026-10-12_HANDOFF.md`](SESSION_2026-10-12_HANDOFF.md)（10 个问题 + 2 条建议那一轮）。
> 这一份是**用户装机之后连着报回来的东西**：先复核那 10 条，再修交互（音量条 / 点歌名 / 歌词键）、
> 设置页与文案、罗马字与 mxm，最后是**追了三轮的那条「突然无法播放任何歌曲」——这一轮抓到根因并修掉了**。
>
> 现场材料：照片 **78–81**（`C:\dsh\else\`）、日志 **57–62**（`C:\dsh\ipa\` 与
> `C:\Users\ngzhwm\Downloads\AyuGram Desktop\`）。**这一版一行都没上过机器**，验收见 §2。

---

## 0. 三十秒现状

| | |
|---|---|
| 提交 | 本会话共 **21 笔**（`531a6ac` → `942e81e`），**已全部推到 `origin/main`** |
| 要编译的 | `main` 最新提交 **`942e81e`**；点 `Build IPA — patched` 时 `Use workflow from` 选 `main`，**`ipa_url` 留空** |
| 自检 | ✅ 六条全绿（orion 328 / brace 328 / member 273 / string 277 / l10n en / l10n zh-CN 416 keys） |
| CI | ⏳ **`Build IPA — patched` 要用户手动点**（本机没有 `gh`，我点不了） |
| 装机 | ❌ **一轮都没上机器**：§2 那 16 条全是"看一眼" |
| 一句话 | **代码改完、自检过、推上去了；接下来是「点一次 Build IPA（`942e81e`）→ 装 → 按 §2 拍照 + 存日志 63」**，然后**开页面**（§3） |

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
| **彩蛋「替换寻找歌词时的占位符」**（`88a6b7c` / `a4b5734`） | 调试页、转储视图树**下面**；开着把「正在查找歌词…」写成「少女祈祷中…」；footer 只写"一个小彩蛋。"。**全仓库只有一处**写那句占位文本（`noticeText()` 的"还在查"分支） |
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

1. **先看 CI 红不红**（`Build IPA — patched`，`ipa_url` 留空）。红了先修编译，别的都别验。
2. **`apresolve` 这条要盯住**：如果新版本**还是**卡/空，先看 `[PLAYER]` 那三行 + `[NET] … apresolve …`，
   再决定是"还有别的接入点拦截"还是"根因不在这"——**别急着回滚那三处放行**。
3. **做页面时**：先看 §3.3 那三条 + §3.5 的红线；每片**只拍一个判据**；
   动 `LibraryAppearance` 之前先 `git diff`，**别把"原值还原"删掉**。
