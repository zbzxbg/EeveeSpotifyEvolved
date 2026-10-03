# SESSION_2026-10-08_HANDOFF — 这个会话干了什么 · 现在到哪 · 下一步 · 规矩

> **新会话先读这一份**（自包含）。
> 详细流水在 [`SESSION_2026-10-07_HANDOFF.md`](SESSION_2026-10-07_HANDOFF.md) 的 **§10–§15**
> （日志 50/51/52 的逐行判读、照片 54–59 的逐像素、我犯过的错、pw 原文对照都在那儿）。
>
> 写作时：**HEAD = `d9d6c74`**（= 日志 52 跑的那一版）；
> **工作区里还有 5 个文件、+645 / −35 的改动，从未编译、从未装机。**
> 证据：日志 `C:\dsh\ipa\eeveespotify_debug_shared {49,50,51,52}.log`、
> 照片 `C:\dsh\else\{40,41,49…59}.jpg`、类名 `C:\dsh\ipa\dump-9.1.88.txt`、
> pw 隔离副本 `.spotify-ipa\spotipw-v0.21.1\`（GPL-3.0，≤v0.21.1 可读可复用）。

---

## 0. 三十秒现状

| | |
|---|---|
| **这个会话的起点** | 日志 50 = 上一轮 10 个提交的**第一次**真机 |
| **这个会话的终点** | 一批**从未编译过**的改动（+645/−35），等 CI + 日志 53 |
| **✅ 已经真的修好的** | **歌词进播放器能用了**（日志 52：`expanded` 出现、几何正常，照片 54/55） |
| **✅ 已经真的诊断清的** | 暂停键"一卡一卡" = 投影**单次采样没前进**就判暂停（H1「钉被盖掉」**证伪**） |
| **🟡 改了但没验的** | 换歌照片 57 半成品 / 封面显示上一首 / 暂停键的点击接管 / 两处原生歌词入口 / 逐词性能 / 单行歌词的正确关法 |
| **🔴 一直没解决的** | 「突然无法播放全部歌曲」（**日志证据不支持"premium 伪装漏了"**） |
| **下一个动作** | **CI 编译 → 装机 → 日志 53**（§5 那张单子） |

---

## 1. 这个会话干了什么（按真机轮次）

### 1.1 日志 50 → 定位「`4215e8e` 少了一半」

用户报："暂停键一卡一卡 + 点歌词键无法使用"。

* **歌词**：`measure()` 在 `f906512`（日志 49 的构建）与当时 HEAD 上**逐字节相同**
  ⇒ 差别只在**调用方**：`4215e8e` 让"铺不上"时把 `isOpen` 清掉，而 `reconcile()` 只在
  `isOpen == true` 时重试 ⇒ **一次失败 = 这枚键永久死掉**。
  （旧代码是"这拍量不到就下拍再量"。日志 49 用户点得晚、第一拍就量到了。）
  ⇒ 修法：`openAndMount(in:)` + 2.5s 重试窗口（**只武装一次**，否则永不到期）。
* **暂停键**：日志 50 里**一行判据都没有** ⇒ 那一轮只是**补判据**（换符号 / 跳位置 / 钉被盖掉 / 点击），
  并按仓库纪律派了**独立只读复核**。

### 1.2 日志 51 → 找到真正的病根：`visibleCover()` 挑错了封面

我上一轮修的"重试窗口"是**真回归**，但**不是这个症状的根因** —— 新判据一句话就破了案：

```
[NPVLyrics] not expanding (the title row has not settled yet (lift=240pt) - will retry next tick)
```

`240` 只有一个解：`cover.minY` 落在页面**底部**。树里正好有：

```
2.CollectionViewCell@20,838,374,0        ← 「一屏」折掉的卡：高 0
7.ImageView@0,-62,374,374,id=Encore.ImageView   ← **那张卡里的封面**（BFS 更浅，先被撞上）
13.ImageView@0,0,366,366,id=Encore.ImageView    ← 真正的主封面（更深）
```

**三份日志时间线闭合**：日志 49 点击早于那张 `374×374` 出现 ⇒ 成；
日志 50 点击**正好在它出现那一秒** ⇒ 败；日志 51 它已在 ⇒ 必败。

⇒ 修法：`visibleCover()` 改**三趟** ——
**① 必须是 `SPTNowPlayingView` 的后代**（结构性 id：播放器每一件都在它里面，
而卡片封面与它平级、在外面；这个 id 从 09-30 起每份日志都有）
→ ② 祖先里没有被折成 0 的 → ③ 旧判据（**宁可回到老行为，也不要一张都挑不出来**）。

### 1.3 日志 52 → **歌词键通了**；同时暴露三个新问题

```
[NPVLyrics] artwork picked …ImageView 366×366 at 24,163,366,366 (tier=inside SPTNowPlayingView)
[NPVLyrics] expanded — thumbnail 72pt at 28,171,72,72, lyrics area 20,263,374,325,
             cover shrunk in from 24,163,366,366, title row lifted -421pt / shifted 88pt
```

**这一轮加的判据全部按设计工作了**（`tier=` / `measure` 分因 / `glyph … symbol` 序列 /
`pinned … id=`），而且**证伪了暂停键的头号嫌疑 H1**（`foreign 'opacity'` 零命中）。
用户新报三个：

| 症状 | 根因（都已修，见 §4） |
|---|---|
| 换歌时**照片 57**（大封面回来、我们的层还压着） | ★ **我自己的回归**：上一轮把 `lines/trackId` 门禁提到所有副作用之前，**连"按住原生封面"这个必需的副作用一起拿掉了**。换歌会换成**新的封面对象**，我们藏的是旧对象 |
| **封面显示上一首** | 竞态：`currentTrackId()` **立刻**变，而树里的图**晚一拍**才换 ⇒ **旧图被存进新曲目的缓存**，而且会一直错下去 |
| **暂停键反应比以前更慢** | ① `uiButtonTapped` 钩子**在 9.1.88 上从不触发**（实测零命中，"类里有这个方法"≠"这条路会被走"）；② 我那个 1.2s 粘滞窗口是**无差别**的 |

### 1.4 照片 58/59 → 单行歌词的**真正**机理（我判反两次）

用户："我想**要的高度效果是图片 59 的效果**"；并澄清：
**「隐藏封面下的一行歌词」他从来没关过 —— 他动的是那颗胶囊**；
58 = 胶囊「显示歌词」（**单行功能生效中**，内容被我们藏了）⇒ **封面照样被抬着**；
59 = 按了胶囊（**功能真的关掉**）⇒ **封面回到正常**。

⇒ 真相：**藏视图只去得掉"内容"，去不掉"功能"**；`alpha` 更糟（把那一格留着）。
**唯一对的做法：替用户按下 Spotify 自己那颗开关。**

---

## 2. ★★ 我在这个会话里犯的四个错（留档，别再犯）

| # | 错 | 教训 |
|---|---|---|
| 1 | 拿英文串 `NPVLyrics] expanded` 去 grep **中文日志**，得出"这功能从来没成功过" | **跨构建 grep 前先确认那一版的语言**（本仓库做过一次全量中英切换）。这正是"不要从日志缺项反推" |
| 2 | 推"标题行不在列表里所以 `measure()` 必然失败"，还写进了代码注释 | **被日志 49 一眼否掉**（`stage` 底边 558 = `npv.bottomStackView` 顶边 ⇒ 它就在列表子树里）。**推断过头时先找反例** |
| 3 | 单行歌词的正确做法**判反两次**（先 `hidden`、再 `alpha`、又撤回） | **用户给的"操作 + 现象"是最高证据**；我两次都在"怎么藏零件"上打转，而答案是"去按它自己的开关" |
| 4 | 把门禁提到副作用之前，**连必需的副作用一起挪走**，造成照片 57 | 独立复核的建议要**连同它的前提一起审**："失败零副作用"在这一处**不成立** —— 换歌时必须继续按住新封面 |

---

## 3. 现在的工作区（**+645 / −35，从未编译**）

| 文件 | 改了什么 |
|---|---|
| `Sources/EeveeSpotify/Appearance/NowPlayingLyricsPlate.swift` | ① `keepNativeCoverHidden()`：**每拍**按住当前那张原生封面（照片 57）；② 封面缓存**换歌那一拍不认图**（`lastArtworkTrackId`）；③ `hideNativeLyricsAffordances()`：藏歌词卡顶部「歌词 · 分享 · 全屏」那一行（**一趟 BFS**，用 `alpha`）；④ 逐词歌词改用**每帧时钟**（`usePerFrameClockIfAvailable`） |
| `Sources/EeveeSpotify/Appearance/DeclutterChrome.x.swift` | ★ **`turnOffSpotifySingalong()`**：不藏那一行，改成**替用户按 Spotify 自己那颗胶囊**（判据=那一行的高度 120/0）；**只有真关掉了才把胶囊按住**；关开关时全部写回 |
| `Sources/EeveeSpotify/Appearance/NowPlayingControlsPlate.swift` | ① 给播放键**内部那颗 `UIControl`** 挂公开的 `addTarget(.touchUpInside)`（`uiButtonTapped` 在 9.1.88 上不走）；② 粘滞判决改成**不对称**（「在播」立刻采纳、「暂停」才等窗口）；③ `tap seen on …` 判据 |
| `Sources/EeveeSpotify/Shared/Models/Extensions/UserDefaults+Extension.swift` | `hideSingalongLine` 默认值 **→ 开**（机制换了之后它做的才是对的事） |
| `Tools/eevee-hookfinder/SESSION_2026-10-07_HANDOFF.md` | 日志 50/51/52 + 照片 58/59 的判读（§10–§15） |

**六条本机自检全绿**（`orion_hook_guard` / `swift_brace_check` / `swift_member_check` /
`swift_string_check` / `l10n_lint --locale en|zh-CN`）。
⚠️ **它们不做类型检查** —— 编译只能走 CI。

---

## 4. 下一步（排序）

### 4.1 立刻：CI 编译 + 装机抓日志 53

**操作顺序**（每一步都短）：

1. 进听歌页 → **停 3 秒**（别抢）；
2. 点歌词键展开 → **换一首歌**（★ 主验收点：**不许**出现照片 57 那种"大封面 + 我们的层压在上面"，
   封面也不许显示上一首）→ 再换一首 → 收起；
3. **快连点播放/暂停 10 次以上**（字形要**跟手**，不许再有 1 秒延迟）；
4. 上一首 / 下一首各点一次（回归：三颗按钮都还能按）；
5. 停在听歌页 3 秒。

**预期日志（照这三组比）**：

```
[NPVLyrics] artwork picked <类名> 366×366 at 24,163,366,366 (tier=inside SPTNowPlayingView)
[NPVLyrics] expanded — thumbnail 72pt at …, lyrics area …, title row lifted …     ← 展开要成
[NPVLyrics] track just changed — not caching the artwork this tick (…)            ← 换歌那拍
[NPVLyrics] hid 1 native lyrics affordance(s) (the card's header row with the share/full-screen buttons)
[NPVLyrics] word-by-word lyrics are now driven per frame (shared CADisplayLink)    ← 逐词流畅度

[Declutter] turned Spotify's own singalong line off through its pill (…)
[Declutter] hid the show/hide-lyrics pill (the singalong is off, so it has nothing left to toggle)
[Declutter] singalong is on but the show/hide-lyrics pill was not found - leaving it alone   ← 若出现：没找到，你还能手关

[NPVControls] tap target installed on <id>
[NPVControls] tap seen on <id> (isOurPlayerButton=true)        ← ★ 这两行**终于该出现了**
[NPVControls] play button tapped — glyph pause.fill -> play.fill (trust 1.2s)
[NPVControls] glyph SPTNowPlayingPlayButton symbol pause.fill -> play.fill (via tap-override, …)
```

**通过判据**：

| # | 判据 |
|---|---|
| ① | **封面/歌名的高度 = 照片 59 的样子**（单行歌词功能被真正关掉），而且那块地方**没有歌词在滚** |
| ② | 换歌**不再出现照片 57**，封面**不显示上一首** |
| ③ | 暂停键**跟手**（`via tap-override` 出现，而不是清一色 `via projection`） |
| ④ | 歌词卡顶部「歌词 · 分享 · 全屏」那一行**不见了**，底部那颗胶囊**也不见了** |
| ⑤ | 逐词歌词**不再一格一格跳** |
| ⑥ | 回归：三颗按钮都还能按 / 歌词键能开能关 / `bounce=on` |

**失败判据（要警惕的）**：`singalongPillMissing` 出现（胶囊没找到 ⇒ 高度会停在 58）；
`tier=legacy predicate` 出现（封面判据又退回老行为）；换歌后出现
`not expanding (no lyric lines to draw right now …)` **且**大封面露着。

### 4.2 之后（按优先级）

| 序 | 做什么 | 前置 |
|---|---|---|
| 1 | 按日志 53 收口上面六条 | 日志 53 |
| 2 | ★ **排版向 kumone 看齐**（照片 41 = 未展开 / 40 = 展开：**标题在顶、封面居中、歌词替代封面区**；我们现在是 pw 形状 = 左上 72pt 缩略图 + 标题并排 + 歌词在下）。**手法：「搬 holder 不搬控件」**——用 `transform` 平移"装它的那颗 arranged view"，触摸会自动跟着走，一行转发代码都不用写 | 三个 `*ElementsUnit` 类都在 9.1.88（已核） |
| 3 | **「突然无法播放全部歌曲」**：日志证据**不支持**"premium 伪装漏了"（属性全 premium、`[REVERT_WATCH]` 零 reversion；而且是**曲中卡住**：`11.1s → 11.2s` 走 3 秒）。下一步是补一条**只读的音频密钥路径探针**（只看 status/耗时，不看 body 与 id） | —— |
| 4 | `NowPlayingPageOverlay` 的"没找到就接着试几拍"（日志 40/41/42/43/48/49/50/51 八次同形 "bottom anchor not found"） | —— |
| 5 | 封面改成"自己持有"（复用 `LyricsArtworkResolver`，它已把 `spotify:image:<hex>` 那条链走通） | 要先把 `layoutAndMount` 的**同步返回 Bool** 改成"异步图到了再铺" |
| 6 | 「一屏」橡皮筋：用户拍 A / B（见 10-06 文档 §2.5） | 用户决定 |
| 7 | 刷新 customize 种子（9.1.76 → 9.1.88）；`swift_string_check.py` 接进 CI | —— |

### 4.3 ★ 还没做、但已经很明确的一件事：**真按 pw 抄"封面从哪来"**

读完 pw 原文（`.spotify-ipa\spotipw-v0.21.1\...\PlayerArtwork.x`）之后：

* pw **不搜索视图树**。它 `%hook _TtC35CreativeWorkCommons_CoverArtTiltKit16CoverArtTiltView`
  **注册实例**，再用 `showingTilt()`（"在窗口里 + 祖先没有 hidden"）挑出正在显示的那一个，
  `coverIn(tilt)` = **与 tilt 等大**的那个子视图；
* `SGRPlayerArtworkAreaIn`：从 tilt 往上找**第一个和播放器等宽的祖先** = "封面 band" ——
  **这 5 行我们一直没有**，而它同时决定缩略图位置与歌词区底边；
* **`_TtC35CreativeWorkCommons_CoverArtTiltKit16CoverArtTiltView` 在 9.1.88 上存在**
  （`dump-9.1.88.txt:11933`）⇒ 这条路走得通。
* 取图那条 pw 也不是纯 API：`SGRNowPlayingArtwork()` 是"按 URL 取 + **从迷你条
  `SPTNowPlayingBar` 刮一张**"的缓存（带质量/身份纪律）。

⇒ **建议**：等日志 53 确认三级判据够用就先不动；如果 `tier=legacy predicate` 又出现，
**下一轮直接按 pw 做**（tilt 注册 + artwork band），别再自己发明判据。

---

## 5. 规矩（这个会话新增 / 强化）

1. ★ **跨构建 grep 日志前，先确认那一版的语言**（本仓库做过一次全量中英切换）—— 否则得到假阴性。
2. ★ **"失败就回退状态"的写法必须连问三句**：① 谁来重试？② 重试窗口**会不会永不到期**
   （每次失败都往后推 = 无限轮询）？③ 回退之后**屏幕上的东西和那个状态还一致吗**（不一致 ⇒ 用户关不掉）。
3. ★ **"零副作用"不是普适美德** —— 在"必须持续按住别人的视图"这类地方，
   把门禁提到副作用之前会**把必需的副作用一起拿掉**（照片 57 就是这么来的）。
   **独立复核的建议要连同它的前提一起审。**
4. ★ **判据必须落在 `accessibilityIdentifier` 上，不能落在类名上** ——
   上一首/下一首共用 `Encore.Button.Tertiary`，`time 1/time 2` 是**两颗不同的按钮**。
5. ★ **判据的"预算"按通道分，不许共用** —— 共用必然出现"帧级那一路刷爆、把关键那一路静默丢掉"，
   那比没有判据更坏（**假绿灯**）。
6. ★ **补判据 ≠ 修好**。没有日志/照片证据之前，一律按"未证实"对待。
7. ★ **对"别人的布局"下手前先问用户**：藏视图 / 改 `alpha` / 按它自己的开关，
   三种做法的后果完全不同 —— 这一处我判反两次，代价是两轮。
8. ★ **`frame` 在 transform 非恒等时不可信**；一律 `bounds` + `center`；位置换算用 `convert`。
9. ★ **日志文案英文、注释中文**；字符串里**不用 ASCII 双引号**做强调（第 6 条自检会抓）。
10. ★ **别人的视图：要在意"还能不能按"时，只钉 `layer`、不写 `alpha`**；
    要**故意**让它收不到触摸时，`alpha` 才是对的。
11. **不新开定时器**（蹭既有节拍；要每帧就用仓库既有的 `WordByWordPlaybackClock`）。
12. **一次装机只验一轮**；未装机的提交别堆太多。
13. **改"动别人视图/布局"的代码要独立只读复核**（本会话派过一次，抓到 5 条，其中 3 条是我自己引入的）。

---

## 6. 本机环境（这个会话踩到的）

* ★ **`pwsh` 必须提权**才能跑（否则 `0xC0000142` / `STATUS_DLL_INIT_FAILED`，连 `echo` 都失败）。
  会话里第一次调用要带 `sandbox_permissions: "danger-full-access"`，否则 shell 完全不可用，
  六条自检、`git` 全都跑不了。
* **本机没有 Swift 工具链** ⇒ 编译只能走 CI；六条自检**不做类型检查**
  （逐成员初始化器顺序、`@MainActor` 隔离、`frame`/`bounds` 误用这几类只能靠人工推演 + CI）。
* 六条自检：`Tools/eevee-hookfinder/{orion_hook_guard,swift_brace_check,swift_member_check,swift_string_check}.py`
  + `Tools/l10n_lint.py --locale en|zh-CN`。

---

## 7. 文档地图

| 想看什么 | 去哪 |
|---|---|
| **本会话全貌 / 现状 / 下一步 / 规矩** | **本文件** |
| 日志 50/51/52 + 照片 54–59 的**详细判读**、我犯过的错、pw 原文对照 | `SESSION_2026-10-07_HANDOFF.md` §10–§15 |
| 上一批 10 个提交的清单与原始验收单（⚠️ §3.4 ② 那条判据已作废） | `SESSION_2026-10-06_HANDOFF.md` |
| 更早的流水与取证（日志 48/49 逐行、照片 49–53 逐像素） | `SESSION_2026-10-05.md` §8–§13 |
| pw 的移植评估（14 个目标类、一屏算法、依赖面） | `SPOTIPW_0211_PORT_ASSESSMENT.md` |
| pw ↔ 我们的功能缺口 + **许可红线** | `SPOTIPW_GAP.md` |
| kumone 的配方、常量、照片 40/41 的逐像素量测 | `KUMONE_REFERENCE.md` §5 |
| 歌词线的历史（几十条结论） | `LYRICS_MODULE_NEXT_STEPS.md` |
| 哪些目标类已过时 / 已删 | `STALE_AUDIT.md` |

---

## 8. 未验证声明（**不要去掉这一段**）

* **工作区那 5 个文件（+645/−35）没有编译过、没有装机过。**
  上面所有"已修"都只到"源码层面 + 六条自检 + 人工推演"这一步。
* **最后一版真机数据是日志 52**（≈ `d9d6c74`）；照片 58/59 是用户**在会话中途构建工作区**得到的，
  所以它们对应的源码状态**介于两者之间**（`hideSingalongLine` 默认值当时被我改成了"开"，现已改成
  带着新机制再改回"开"）。
* 本会话派过一次**独立只读复核**（两个只读 reviewer）；它抓到的 5 条已全部修掉（其中 3 条是
  我这一轮自己引入的）。**它们都没能跑 `git diff`**（shell 起不来），是直接读工作区文件推演的。
* ★ **"突然无法播放全部歌曲"这条从头到尾没有进展** —— 只排除了一个假设（premium 伪装漏了），
  真正的取证工具（音频密钥路径探针）**还没写**。
