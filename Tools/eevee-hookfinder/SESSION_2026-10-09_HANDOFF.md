# SESSION_2026-10-09_HANDOFF — 日志 53 的判读 · 照片 60/61/62 的现场 · 三个问题的修法 · 下一轮验收单

> **新会话先读这一份**（自包含）。上一轮的流水在
> [`SESSION_2026-10-08_HANDOFF.md`](SESSION_2026-10-08_HANDOFF.md)（§1–§8：那批 +645/−35 的改动、
> 我犯的四个错、pw 原文对照、下一步排序）。
>
> 写作时：**起点 = 上一轮那批从未编译过的改动**（10-08 文档 §3 的 5 个文件）。
> 这一轮的输入是**日志 53 + 照片 60/61/62**；输出是**又一批未编译的源码改动**。
>
> 证据：日志 `C:\dsh\ipa\eeveespotify_debug_shared 53.log`、照片 `C:\dsh\else\{58,59,60,61,62}.jpg`、
> 类名 `C:\dsh\ipa\dump-9.1.88.txt`、IPA `C:\dsh\ipa\Spotify-9.1.88.ipa`。

---

## 0. 三十秒现状

| | |
|---|---|
| **这一轮的起点** | 日志 53 = 10-08 那批改动的**第一次**真机 |
| **用户报的三个问题** | ① 单行歌词没被隐藏 + 开关没用；②「歌词 · 分享 · 打开全屏歌词」那一行还在；③ 换歌那一瞬间闪一下（照片 61/62） |
| **三个根因（都已定案）** | ① 机制整条压在"按那颗胶囊"上，而**判据在运行期零命中**；② 那一行**是我们自己画的**（判成 Spotify 的原生入口，藏错了对象）；③ 「按住封面」挂在 **0.3s 轮询**上，而换歌会**新建**一个封面对象 |
| **这一轮改了什么** | 6 个文件 + 1 个新 hook 文件（见 §4）；**全部没有编译、没有装机** |
| **下一个动作** | **CI 编译 → 装机 → 日志 54 + 照片 63+**（§6 那张验收单） |

---

## 1. 日志 53 里那三行判据（逐字，含行号）

```
3309  [Declutter] singalong is on but the show/hide-lyrics pill was not found
                  - leaving it alone (you can still switch it off by hand; …)
3310  [NPVLyrics] hid 1 native lyrics affordance(s) (the card's header row with the share/full-screen buttons)
```

这两行**同时**成立，而用户看到的屏幕是"那一行还在 + 那一行歌词还在滚"。
一行是"我藏了"，一行是"我没找到" —— **两条路都没落到用户抱怨的那两个东西上**。

再看视图树（`[NPVTree]`，听歌页**子树**，`#9`–`#20` 每份 390–556 个节点，
`maxPageNodes = 1200` ⇒ **没有截断**，是完整的一份）：

```
3339  #9 2.CollectionViewCell@20,838,374,0,bg=#2A2A2A
3354  #9 5.CardView@0,0,374,0,alpha=0.00,id=lyrics-card-view
3360  #9 7.CardHeaderView@0,0,342,38
3425  #9 11.EncoreButton@0,0,44,44,id=lyrics-share-button
3426  #9 11.EncoreButton@0,0,44,44,id=lyrics-expand-button
3507  #9 14.LyricsContainerView@0,372,366,120
3541  #9 15.LyricsView@0,0,366,120,id=singalong-lyrics-view
```

* 原生那一行（`lyrics-share-button` / `lyrics-expand-button`）在**列表里那张被折成 0 高的卡**里
  （`CollectionViewCell@20,838,374,0`）⇒ **它根本不在屏上，不需要藏**；
* `LyricsContainerView@0,372,366,120` + `LyricsView …366,120` ⇒ **单行歌词的功能是开着的**
  （对照：日志 51 开着是 120、日志 52 关着是 0）⇒ 用户说"没有被隐藏"是真的；
* `2.CollectionViewCell@20,838,374,0,bg=#2A2A2A` 这张卡正是 `WordByWordHost` 内嵌预览的宿主
  （日志里每两秒一行 `[PreviewShell] card container (card)=Lyrics_CardElementImpl.CardView`）
  —— **我们上一轮把它 `alpha = 0` 掉了**（见 §3.2 ③）。

### 1.1 ★ 定案：那一行「歌词 · 分享 · 全屏」是**我们自己画的**

`AppleMusicLyricsOverlayView.previewHeader`（`Lyrics/AppleMusic/AppleMusicLyricsOverlay.swift`）
= 一个 `Text("lyrics")` + `square.and.arrow.up` + `arrow.up.left.and.arrow.down.right`，
`padding(.horizontal, 14)`，两颗按钮各 `40×32`。而照片 60 那一行的**逐像素量测**：

| 元素 | 我们代码算出来的中心 x | 照片 60 量出来的中心 x |
|---|---|---|
| 分享键 | 20 + 374 − 14 − 40 − 20 = **320pt** | 455px ÷ 1.428 = **319pt** |
| 全屏键 | 20 + 374 − 14 − 20 = **360pt** | 520px ÷ 1.428 = **364pt** |

容器 `20,210,374,378` 在日志 53 里也逐字对得上（`[NPVTree] #11 1.UIView@20,210,374,378,id=eevee-npv-lyrics-container`）。
⇒ **它就是我们自己的 SwiftUI 预览标题栏**，藏原生永远不会有任何变化。

### 1.2 ★ 定案：换歌时 contentlayer 换的是 **cell**（新封面对象）

```
#14 (08:08:29)  10.CoverArtCellImpl@…,id=nowplaying-contentlayer-cell-5000            ← 可见
#15 (08:08:35)  10.CoverArtCellImpl@…,id=nowplaying-contentlayer-cell-5000,hidden     ← 被我们按住了
#15 (08:08:35)  10.CoverArtCellImpl@…,id=nowplaying-contentlayer-cell-5001            ← **新的，露着**
```

而"按住封面"那条路（`NowPlayingLyricsPlate.keepNativeCoverHidden`）挂在
`DeclutterChrome` 的 **0.3s 复查节拍**上 ⇒ 新封面**先露 ≤0.3s**。
照片 61 就是这个空档的定格：原生封面 `24,163,366,366`（当时还是 loading 占位：
黑底 + 灰色图片图标）整张铺在歌词底下，而我们的缩略图与上移后的标题都已经就位。

同一秒还有一条**会永久错下去**的证据：

```
08:08:35  [NPVLyrics] track just changed — not caching the artwork this tick
08:08:36  [NPVLyrics] remembered this track's artwork 366×366 (cache 2/8)   ← 抓到的还是旧那张
```

"下一拍树就换过来了"这个假设**不成立** ⇒ 上一首的图被写进新曲目的缓存
（照片 61 的缩略图 = 上一首那张橙色封面 + 新歌名），而 `ensureCover` **优先吃缓存**。

### 1.3 「单行歌词」那条 flag 的名字，就是用户那句话

```
410  [Flags] lyrics flag — scope=ios-nowplaying-contentlayers-impl name=is_lyrics_cover_art_refactor_enabled bool=true
413  [Flags] lyrics flag — scope=ios-nowplaying-contentlayers-impl name=lyrics_under_cover_art_enabled bool=true
```

`lyrics_under_cover_art_enabled` = **"封面下单行歌词"**（设置页那行开关的原文）。
它同时管三件事：那一行、**"把封面抬起来"的布局后果**、底部那颗「显示/隐藏歌词」胶囊。
⇒ 这才是这个开关该动的东西（见 §4.2 第三层）。

---

## 2. 这一轮我改了哪些判断（与上一轮相反的地方）

| # | 上一轮的判断 | 日志 53 / 照片 60 给的真相 |
|---|---|---|
| 1 | 「歌词 · 分享 · 全屏」是 Spotify 的原生入口（`lyrics-share-button` 那一批） | **是我们自己画的**（§1.1 的几何对照） |
| 2 | 藏原生入口能去掉那一行 | 那三颗按钮所在的卡被「一屏」折成 0 高，**它们本来就不在屏上** |
| 3 | `widestRowAncestor`（≥350pt）挑到的是"那一行的容器" | 挑到的是 **`CardView` 本身**（374 宽）⇒ 我们把**整张歌词卡**、连**我们自己内嵌预览的宿主**一起 `alpha = 0` 了 |
| 4 | 那颗胶囊按类名子串 `ShowLyricsButton` 找得到 | 日志 53 的完整页面树里**零命中** —— 类名来自类名表，**不是从视图树上读来的** |
| 5 | 开关失败时"只打一行日志、什么都不藏"是安全的 | 结果是**屏幕上什么都没发生**（照片 60 = 用户看到的状态） |

---

## 3. 三个问题的根因（一句话版）

### 3.1 ① 单行歌词没被隐藏 + 开关没用

上一轮把机制**整条**压在"替用户按下那颗胶囊"上，并且删掉了"藏那一行"的老机制。
胶囊没找到 ⇒ **不按、不藏、什么都不做**。日志 53 那一行 `singalong is on but … was not found`
就是全部现场。

### 3.2 ② 那一行按钮还在

同 §1.1。我们把**别人的**入口藏了（而且藏错到整张卡），**自己的**那一行一直画着。

### 3.3 ③ 换歌闪一下

同 §1.2：新封面对象 + 0.3s 轮询 ⇒ 空档；外加"上一首的图写进新曲目的缓存"。

---

## 4. 这一轮改了什么（**全部未编译、未装机**）

### 4.1 ② 那一行按钮 —— 改我们自己的画法

| 文件 | 改动 |
|---|---|
| `Lyrics/AppleMusic/AppleMusicLyricsOverlay.swift` | 新增 `var showsPreviewHeader: Bool = true`（插在 `previewHeaderInset` 之后、`onSeek` 之前 —— 逐成员初始化器**位置敏感**）。为 `false` 时 `headerContent: nil`、`headerHeight: 0`；`AppleMusicLyricsPage` 那一档退回 `contentInsets.top`（注意它在 `scrollInsets` 里**被加两次** ⇒ 内容起点从原来的 45pt 变 48pt，**净多出 33pt**，不是 39pt —— 独立复核算的） |
| `Appearance/NowPlayingLyricsPlate.swift` | `mount` 传 `showsPreviewHeader: false`；**整块删掉** `hideNativeLyricsAffordances` / `nativeLyricsAffordanceIDs` / `hiddenNativeAffordances` / `didLogNativeAffordances` / `widestRowAncestor` / `restoreNativeLyricsAffordances` 与三处调用点（§2 的 1–3 条） |

★ 关标题栏会**顺带换掉淡出遮罩那套口径**，这里一并按"保持原样"处理了（两处都很隐蔽，写下来免得下一轮又踩）：

* `headerContent == nil` 会让 `AppleMusicLyricsPage.fadeMaskStops` 那条 `guard` 失败、
  退回 `legacyFadeStops`（**整屏比例**口径）⇒ 原来那套"按壳占位算"的停靠点不再生效。
  所以 `fadeBottomOpaqueRatio` 要传 **1.0**（不是预览档的 0.62）——
  0.62 会给这块**加一条本来没有的底部淡出带**（照片 60 里最下面几行是清楚的）；
* 没有标题栏之后内容直接顶到容器上沿，而 `legacyFadeStops` 的 `fadeTopRatio = 0.08`
  （容器 378pt ⇒ 约 30pt）会把第一行压暗 ⇒ `contentInsets.top` 在"无标题栏"那一档取 **24**
  （`scrollInsets` 里会再加一次同样的值 ⇒ 实际 48pt，与原来"有标题栏时的 45pt"对齐）。

### 4.2 ① 单行歌词 —— 三层，各管一段

| 层 | 在哪 | 做什么 | 生效时机 |
|---|---|---|---|
| ① **内容层** | `Appearance/DeclutterChrome.x.swift` `applySingalongPreference` | 把 `singalong-lyrics-view` 自己 `hidden`（带我们的标记，关开关时写回） | 下一拍（≤0.3s） |
| ② **功能层** | 同上 | 找到那颗胶囊就 `sendActions(for: .touchUpInside)`，然后**把刚按下的那一个** `alpha = 0`；★ **一场只按一次**（见 §4.2.1） | 找到就立刻 |
| ③ **根上** | `Premium/DynamicPremium+ModifyingFunctions.swift` | 内置远端配置替换 `lyrics_under_cover_art_enabled=false`（`scope: ios-nowplaying-contentlayers-impl`，`setBool` 只改服务端已下发的值） | **下次启动**（customize 重发） |

#### 4.2.1 ★ 独立只读复核抓到的两条（**已修**）

| # | 复核说的问题 | 处置 |
|---|---|---|
| R1（blocker） | 判据表里「显示歌词」和「隐藏歌词」**两个标签都在**，而判据不看 `alpha`/`isHidden` ⇒ 按过之后 T+2s / T+4s 那两拍会再找到**同一个控件**再按一次；`sendActions` 是**切换**，按两次 = **又开回来**（封面又被抬起 = 用户报的症状），而日志还会连说两遍"已关掉" | 加门禁 `guard pillWeHid == nil else { return true }`（`pillWeHid` 非空 = 这一场已经按过）＋ 文档写清"要再关一次"只有两条路：开关关掉再打开，或第三层 |
| R2 | `reportPillSearchShapeOnce` / `singalongPillMissing` 在**节流那一拍**（根本没查）就会打出来 ⇒ "三次都空"与"只试了一次"在日志里一样，且那句此后永不重复（假日志） | 查找改成三态枚举 `PillLookup { found / notFound / skipped }`：`skipped` **什么都不许报**；`notFound` 只在**预算真的走完**（`pillSearchAttempts >= 3`）时才打那两行 |
| R3 | 关开关**按不回** Spotify 自己的偏好（`sendActions` 会落盘），而注释写着"一个字节都不留" | 不改行为（再按一次分不清"是我们关的还是用户自己关的"，会违背用户的手动选择），**改注释 + 日志**：写回的是视图，胶囊恢复可见、偏好留给用户自己按一下 |
| R4 | 封面缓存那条"同一个对象就不写"没有期限：同专辑连播时图可能真的是同一个对象 ⇒ 那一首**永远**不进缓存（画面仍然对，因为兜底拿的是同一张真图） | 加 **1.5s 窗口**（`staleArtworkWindow` / `artworkTrackChangedAt`）：只覆盖"树晚一拍到一秒"，之后照常缓存 |
| R5（性能） | 事件 hook 会**对每一个** `CoverArtTiltView` 的布局都做整树走查（50ms 节流 ⇒ 最多 ~20 次/秒） | ① 只认**够大且在窗口里**的 tilt（`bounds.width >= 200` + `window != nil`）；② **换了新 tilt 对象就立刻走一次**（换歌那一下零延迟），同一个对象才受 50ms 节流 |
| R6 | 文档/注释与实际不符三处（"39pt"、`searched 3×`、`fadeBottomOpaqueRatio` 那句"预览走不到"） | 全部按实测改写（本节 + §5 + §6.2）；`SESSION_2026-10-08_HANDOFF.md` §4.1 里那条 `hid 1 native lyrics affordance(s)` 已标注**作废** |

★ 复核同时**确认无问题**的地方（照抄它的结论，别重推）：逐成员初始化器顺序与两个调用点、`Optional<AnyView>.none`、
`guard isEnabled, #available(...)`、`onMainThreadSync` 的隔离、新 hook 满足 Orion 四条纪律且新文件会被 Makefile 的
`find Sources/EeveeSpotify -name '*.swift'` 收进去、九个被删/改名的符号**全仓只剩注释**、
`.setBool` 与跳过门禁的语义、`UserDefaults` 在该文件里不歧义、以及 `swift_string_check.py` 不会误报我们那行嵌套插值。

★ 它**读不到**的：`C:\dsh\...`（日志/照片/dump）在本会话里不可达 ⇒ 它**无法**复核本文件引用的日志行号、
`dump-9.1.88.txt:3570/11933` 与照片 60 的像素量测。那些仍是"作者单方证据"。

* 胶囊判据**放宽成两条**：类名子串 `ShowLyricsButton`（保留，可能某些构建里成立）
  **或** 无障碍标签逐字命中「显示歌词 / 隐藏歌词」/`Show lyrics`/`Hide lyrics`
  （照片 58/59 上写的就是这几个字；仓库里 `WordByWordPlaybackControl` 找原生控件用的也是标签表）。
* 走查预算 2000 → **8000** 节点（胶囊在听歌页的**覆盖层**上，而页面子树本身就有 390–556 个节点）；
  并且**每次间隔 ≥2s、最多 3 次**，找不到就不再空转 —— 只打一行"走查的形状"
  （`searched N× (≤8000 nodes each) — neither a ShowLyricsButton* view nor a control labelled …`）。
* 开关关掉时：那一行写回、胶囊 `alpha` 写回、走查的账清零（下一次开开关重新给三次机会）。
* 第三层也跟着开关走：开关关 ⇒ 整条内置替换**跳过**，日志里那行 `[Flags] replacement … — N match(es) (SKIPPED…)` 会说清。

### 4.3 ③ 换歌闪一下 —— 事件驱动 + 不再毒化缓存

| 文件 | 改动 |
|---|---|
| `Appearance/CoverFlashGuard.x.swift`（**新**） | `CoverArtTiltLayoutHook: ClassHook<UIView>`，`targetName = _TtC35CreativeWorkCommons_CoverArtTiltKit16CoverArtTiltView`（`dump-9.1.88.txt:11933`，真机每份 `[NPVTree]` 里都有 `14.CoverArtTiltView@0,6,366,366`）；`layoutSubviews` 里 `orig.` 之后把 `target` 取成局部量、`onMainThreadSync { NowPlayingLyricsPlate.coverDidLayOut(from: tilt) }` |
| `Appearance/NowPlayingLyricsPlate.swift` | 新增 `coverDidLayOut(from:)`：门禁（开关开 + **我们确实铺着** + 页面在窗口里 + tilt 够大且在窗口里）；**换了新 tilt 对象立刻走一次**，同一个对象才受 50ms 节流（独立复核 R5）⇒ 走既有那条 `keepNativeCoverHidden`。轮询改成"新封面一布局就按" |
| `Appearance/NowPlayingLyricsPlate.swift` | `rememberArtworkIfNeeded`：抓到的图**和上一首缓存里那张是同一个对象** ⇒ 这一拍**不写缓存**（日志一行说清），退回 `firstImage(in: source)`（同一张，画面对齐）；树真换过来之后对象不同 ⇒ 正常缓存 |
| `Tweak.x.swift` | `activateCoverFlashGuard()`（在 `activateNowPlayingControls()` 之后） |

* 目标类缺失时只打一行日志、不留给 Orion 报非致命错误（本仓库既有做法）；
* hook 方法**不写 `@MainActor`**（Orion 的代码生成器按源码文本拼接，会拼出 `@MainActoroverride`）。

### 4.4 顺手拆掉的隐患

`CardView.alpha = 0` 那一条（§2 ③）如果留着，一旦「一屏」没折那张卡、或用户关掉「一屏」，
我们就会把**自己**的内嵌预览歌词一起藏掉。这一轮连着整块删了。

---

## 5. 本机自检（都是绿的）

```
python Tools/eevee-hookfinder/orion_hook_guard.py      # OK 327 文件
python Tools/eevee-hookfinder/swift_brace_check.py     # OK 327 文件
python Tools/eevee-hookfinder/swift_member_check.py    # OK 272 文件
python Tools/eevee-hookfinder/swift_string_check.py    # OK 276 文件 / 46876 行
python Tools/l10n_lint.py --locale en                  # exit 0
python Tools/l10n_lint.py --locale zh-CN               # 424 keys, 0 missing, 0 extra
```

⚠️ **它们不做类型检查**（本机没有 Swift 工具链）—— 逐成员初始化器顺序、`@MainActor` 隔离、
`#available` 在 `guard` 里的写法、`Optional<AnyView>.none` 这几类只能靠人工推演 + CI。

本轮还派了一次**独立只读复核**（一位只读 reviewer，通读工作区 + 未提交的 diff）：
它抓到 **1 条 blocker + 4 条 likely-bug/nit + 3 处文档漂移**，全部处置在 §4.2.1；
它同时**显式确认**了 9 类"没问题"（初始化器顺序、`#available` 写法、隔离、Orion 纪律、无悬挂符号、
`.setBool` 语义、`UserDefaults` 不歧义、自检不误报）。
⚠️ 它**读不到** `C:\dsh\...`（日志/照片/dump 在本会话不可达）⇒ 本文件里那些引用是**作者单方证据**，复核没能独立核对。

**它的 blocker（R1）值得单独记一笔**：判据表把「显示歌词」和「隐藏歌词」两个标签都收了，
而判据不看 `alpha` ⇒ 按过的胶囊 2 秒后会被**再按一次**，切换回 ON。
这正是"修好了又自己坏掉"的典型 —— **切换类动作必须配一个"已经按过了"的账**。

---

## 6. 下一轮：CI 编译 → 装机 → 日志 54 + 照片 63+

### 6.1 操作顺序（每一步都短）

1. 进听歌页 → 停在**未展开**状态 **3 秒**（这一屏要拍一张，看"那一行单行歌词"在不在）；
2. 点歌词键展开 → 拍一张（**对比照片 60**：`歌词 / 分享 / 全屏` 那一行**必须消失**）；
3. **连换三首歌**，每首停 2 秒（★ 主验收点：**不许**再出现照片 61 那种"大封面 + 加载占位"，
   缩略图**不许**显示上一首；照片 62 那种"灰封面"如果只是图还没下载完，可以接受，
   但它**不许**和"上一首的图"混起来）；
4. 进设置页把「隐藏封面下单行歌词」**关掉 → 打开**各一次（看当场有没有反应）；
5. **杀掉 App 重开**，再进听歌页停 3 秒（这一条是看**第三层**：flag 关掉之后，
   那一行 + 那颗胶囊**从根上**就不该再出现）；拍两张（开/关对照）；
6. 回归：三颗传输键都还能按 / 歌词键能开能关 / `bounce=on`。

### 6.2 预期日志（照这三组比）

```
[NPVLyrics] expanded — thumbnail 72pt at …, lyrics area …, title row lifted …     ← 展开要成（与旧版同一句）
[CoverGuard] armed on _TtC35CreativeWorkCommons_CoverArtTiltKit16CoverArtTiltView
[NPVLyrics] the tree still shows the previous cover — not caching it for this track
            (falling back to the live image, will retry next tick)

[Declutter] hid the sing-along line itself (the feature is still Spotify's; see the flag below)
[Declutter] turned Spotify's own singalong line off through its pill …
[Declutter] hid the show/hide-lyrics pill (the singalong is off, …)
   —— 或者（三次走查真的都空手时，**只有这一种情况**才会出现下面两行）：
[Declutter] show/hide-lyrics pill: 3 search(es), ≤8000 nodes each, N control(s) inspected
            — neither a view whose class contains ShowLyricsButton
            nor a control labelled one of 显示歌词 / 隐藏歌词 / Show lyrics / Hide lyrics
[Declutter] singalong is on but no show/hide-lyrics pill was found after 3 search(es)
            - the line stays hidden, and the flag replacement (next launch) takes the feature itself away

   —— 关掉那个开关时（写回视图）：
[Declutter] singalongLine restored
[Declutter] the show/hide-lyrics pill is visible again (Spotify's own preference is whatever
            our single press left it at - press the pill once if you want it back)

[Flags] lyrics flag — scope=ios-nowplaying-contentlayers-impl name=lyrics_under_cover_art_enabled bool=true
[Flags] replacement ios-nowplaying-contentlayers-impl.lyrics_under_cover_art_enabled — 1 match(es)
   —— 重启之后：同一行应该变成  bool=false
```

### 6.3 通过判据

| # | 判据 |
|---|---|
| ① | 展开后**没有**「歌词 · 分享 · 打开全屏歌词」那一行（照片 60 的那一行消失），歌词区**净多出 33pt**（`contentInsets.top` 那一档从 45 变 48） |
| ② | 未展开/展开两种状态下，**封面下面都没有那一行歌词在滚**（`singalong-lyrics-view` 不可见） |
| ③ | 换歌**不再出现照片 61**（大封面 + 加载占位），缩略图**不显示上一首**；`[CoverGuard]` 那一行在 |
| ④ | 日志里出现 `[Flags] replacement ios-nowplaying-contentlayers-impl.lyrics_under_cover_art_enabled — 1 match(es)` |
| ⑤ | 重启后那一行与那颗胶囊**都不在**（= 第三层真的把功能关掉了） |
| ⑥ | 回归：三颗传输键都还能按 / 歌词键能开能关 / `bounce=on` / 迷你条与首页开关没受影响 |

### 6.4 失败时要警惕的

* `[Flags] replacement …lyrics_under_cover_art_enabled — 0 match(es)` ⇒ 服务端这次没下发这条
  （那第三层是空枪，只能靠①②两层）；
* `[CoverGuard] missing …CoverArtTiltView` ⇒ 目标类没了（那照片 61 只会回到 0.3s 的空档）；
* 那一行歌词**还在** + 胶囊**还在** + `singalongPillMissing` ⇒ 三层全落空，
  下一步就得按 §1.3 的 flag 名字去**核对 scope**（或者走"自己接管那一格高度"那条更硬的路）；
* 展开后歌词**被顶到标题栏里** ⇒ `showsPreviewHeader: false` 的 `headerHeight = 0` 那一路没走对
  （对照 `AppleMusicLyricsPage` 里 `headerContent == nil` 那一段）；
* ★ **重启之后连"Spotify 自己的歌词卡"也不见了**（听歌页列表里那张 `lyrics-card-view` 没内容、
  或内嵌预览再也挂不上）⇒ 说明 `lyrics_under_cover_art_enabled` 管得**比我们以为的宽**
  （它顺带关掉了歌词卡而不只是"封面下那一行"）。那时**把第三层撤掉**（留下①②），
  并把这一条实测写进下一份文档 —— 这是这一层唯一没被真机验证过的前提。

---

## 7. 规矩（这一轮新增 / 强化）

1. ★★ **"改别人视图"之前，先证明"用户看到的那一件确实是别人的"。**
   这一轮花了整整一轮才纠正：那一行按钮**是我们自己画的**（几何能算、能对），
   而原生那三颗在**被折成 0 高的卡**里。**先量几何，再决定动谁。**
2. ★★ **判据不许落在"类名表里的字符串"上。** `ShowLyricsButtonElementUI` 是真类名，
   但**运行期的视图不是那个类** —— 日志 53 的完整页面树里零命中。
   类名表只能用来**缩小范围**，最终判据必须是**运行期能看到的东西**（id / 标签 / 几何 / 结构位置）。
3. ★ **"藏一个入口"要连带问一句"它的容器是谁"**：`≥350pt` 这条规则挑到的是 `CardView`（整张卡），
   而那张卡同时是**我们自己**预览层的宿主。**藏之前先把祖先链列出来。**
4. ★ **轮询追不上"新建对象"这类事件**。0.3s 的复查节拍对"Spotify 换了 cell / 换了封面对象"
   永远是"晚一拍" —— 这种地方要挂**事件**（`layoutSubviews`），不是把节拍调快。
5. ★ **"下一拍就对了"这种假设必须写成判据**（这里：抓到的图**和上一首是同一个对象** ⇒ 不写缓存），
   否则它会把一次性的时序问题**变成永久错误**（缓存毒化）。
6. ★★ **切换类动作（`sendActions` 那种）必须配一个"已经按过了"的账。**
   判据不看 `alpha`，而「显示 / 隐藏」两个标签**都在判据表里** ⇒ 每 2 秒会再按一次，
   按两次 = 又开回来。**独立复核抓到的 blocker 就是这一条**（§4.2.1 R1）。
7. ★ **"没查到"和"没去查"必须是两个返回值。** 上一版把"节流没过"与"查了没有"混成一个 `nil`，
   于是日志会在第一次空手时就断言"找不到"，而那句此后永不重复 —— **假日志比没有日志更坏**。
8. ★ **诊断日志要带上"走查的形状"**（找过几次、预算多少、看了多少控件、比对了什么），
   否则"没找到"和"没去找"在日志里长得一样（日志 53 就是只有一句"没找到"）。
9. ★ **"纯视图写回"≠"行为还原"。** 我们按下的是 Spotify **自己的**开关（它会落盘偏好），
   写回 `isHidden`/`alpha` 只还了视图。**注释里别把它写成"一个字节都不留"。**
10. ★ **一次装机只验一轮**：这一轮又攒了 6 个文件 + 1 个新 hook，别再往里加东西。

---

## 8. 还没做的（按优先级，来自 10-08 文档 §4.2，这一轮没动）

| 序 | 做什么 | 前置 |
|---|---|---|
| 1 | 按日志 54 收口 §6 那六条 | 日志 54 |
| 2 | ★ **排版向 kumone 看齐**（标题在顶、封面居中、歌词替代封面区）—— 手法仍是"搬 holder 不搬控件" | 三个 `*ElementsUnit` 类都在 9.1.88（已核） |
| 3 | **「突然无法播放全部歌曲」**：日志证据不支持"premium 伪装漏了"；下一步是补只读的**音频密钥路径探针** | —— |
| 4 | `NowPlayingPageOverlay` 的"没找到就接着试几拍"（九份日志同形 `bottom anchor not found`） | —— |
| 5 | 封面改成"自己持有"（复用 `LyricsArtworkResolver`） | 要先把 `layoutAndMount` 的同步返回改成"异步图到了再铺" |
| 6 | 「一屏」橡皮筋：用户拍 A / B（10-06 文档 §2.5） | 用户决定 |
| 7 | 刷新 customize 种子（9.1.76 → 9.1.88）；`swift_string_check.py` 接进 CI | —— |

---

## 9. 未验证声明（**不要去掉这一段**）

* **本轮 6 个改动文件 + 1 个新文件全部没有编译过、没有装机过。**
  上面所有"已修"都只到"源码层面 + 六条自检 + 人工推演"这一步。
* **最后一版真机数据是日志 53**（≈ 10-08 文档 §3 那批未编译改动的第一次真机）；
  照片 60/61/62 都是那一版。
* 本轮派过一次**独立只读复核**（只读 reviewer + 未提交 diff）：结论与处置在 §4.2.1，
  确认项与"读不到的东西"在 §5 末尾。**它读不到 `C:\dsh\...`** ⇒ 本文件引用的日志行号、
  dump 行号、照片像素量测仍是**作者单方证据**。
* ★ **第三层（flag）从未在真机上验过**：`lyrics_under_cover_art_enabled` 的
  scope/name 来自日志 53 的 `[Flags]` 行（**不是猜的**），但"关掉它是不是就等于照片 59 的样子"
  **只有下一次装机才知道**。
* ★ **"那一行歌词到底在屏幕的哪个位置"没有逐像素定案**：日志只能给出
  `LyricsContainerView@0,372,366,120`（父坐标），照片 60 里它被我们自己的歌词层压着、
  肉眼分不出哪一行是它。所以第①层（藏视图）与第③层（关 flag）是**两条独立的路**，
  谁先成立都算修好，但**判据要看日志与照片一起**（见 §6.3 ②⑤）。
