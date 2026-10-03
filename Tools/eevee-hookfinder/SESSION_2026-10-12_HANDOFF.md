# SESSION_2026-10-12_HANDOFF — 用户 10 个问题 + 2 条建议一轮改完（照片 76/77、日志 57）

> 上一份入口是 [`SESSION_2026-10-11_REPORT.md`](SESSION_2026-10-11_REPORT.md)（那一轮**没装机**）。
> 这一轮是**用户装完之后**报回来的 10 个问题 + 2 条版式建议，一次改完，**装机验收看本文**。
> 照片：`C:\dsh\else\76.jpg`（歌词态）`77.jpg`（封面态）= **我们的构建**；
> `40.jpg` `41.jpg` = **kumone**（用户点名的参照）；日志：`C:\dsh\ipa\eeveespotify_debug_shared 57.log`。

---

## 0. 三十秒现状

| | |
|---|---|
| 提交 | `257016e`（歌词数据层）→ `934d7ff`（末行贴底）→ `e9efc63`（听歌页版式六项 + 两条建议）→ `e6b00c4`（两处自查发现的地雷，见 §2.4），**已推到 `origin/main`** |
| **要编译的就是 `main` 的最新提交** | 点 `Build IPA — patched` 时 `Use workflow from` 选 **`main`** 即可（Swift 内容 = `c66d72b`；其后两笔是独立复核抓出来的编译错与三处「页面走了没收尾」的修）。跑完看 `head_sha`：应当是那一次的 HEAD |
| 自检 | ✅ 六条全绿（orion 327 / brace 327 / member 272 / string 276 / l10n en / l10n zh-CN 全 exit 0） |
| CI | ✅ **Logic tests 已自动跑**（push 触发）；⏳ **`Build IPA — patched` 要手动点一次**（本机没有 `gh`，我点不了）—— 它才会把 Swift 编一遍 |
| 装机 | ❌ **一轮都没上过机器**：下面 §3 那 12 条全是"看一眼" |
| 一句话 | **代码改完、自检过、推上去了；接下来是"点一次 Build IPA（`e6b00c4`）→ 装 → 拍照片 + 存日志 58"** |

---

## 1. 用户这一轮的话（原话，照这句验）

**问题**（顺序照用户给的）：

1. 歌曲名字过长时（晃动展示全名我知道），**右侧的晃动区超过屏幕右侧**；
2. **歌词提供商没有在歌手后面展示**；
3. 大封面有时把**歌手名字的下半部分**挡住；
4. 开了日语歌词罗马化后**直接替换原日文**，不是展示在原文上面；
5. 返回逐词歌词时**不展示歌词翻译**；
6. 用按键切换歌曲时会**漏歌曲大封面**；
7. 歌词划到最后一行时**末行不停在底部**、能划到中间；
8. 歌曲封面有时**加载失败**；
9. 歌词视图**往上淡出的部分可以再高点**；
10. （建议）**大封面做小**（照片 41 的大小），并在**封面和歌词按钮中间加一行居中的歌词**（像 Spotify 的单行歌词，但自己做）。

**用户当场拍板的 5 个选择**（我问过，照这个做）：

| 问 | 用户选 |
|---|---|
| 封面做多大 | **242pt 居中、顶边 ≈204（= kumone 原样）** |
| 单行歌词摆哪 | **封面底与控件条顶的正中（≈525）** |
| "淡出再高点"怎么改 | **歌词块整体上移（242 → ≈200），淡出带跟着上移** |
| 提供商何时显示 | **展开和收起都显示** |
| 罗马化作用范围 | **原生歌词页也回到原文，罗马字只由我们这层画** |

---

## 2. 逐条：根因 → 改法（**都有文件:行**）

### 2.1 数据层（提交 `257016e`）

| # | 根因（代码实证） | 改法 |
|---|---|---|
| 5 | `NeteaseLyricsRepository` 里 `yrcText = try fetchYrcRaw(songId:).yrc` —— **只取 `.yrc` 成员，把元组里的 `ytlrc` 当场丢掉**（而它自己的日志 `yrc … chars, ytlrc … chars` 证明一直在下发）；逐字分支只写一句 `word-by-word — skipping translation layer`，**从不给 `translation` 赋值** ⇒ 日志 57 的 `translation 0/29` | 保留元组 → 新增 `buildWordByWordTranslation()`：先按 offset 对齐（与行级 tlyric 同一条管线），**一条都没命中时按行序配对**（对着**最终** `lines` 数组，保证 `translation.lines[i]` 与 `lines[i]` 同行） |
| 4 | `storeLyricsDto` 存的是 `dto.romanizedForWordByWordIfEnabled()` —— 那份副本会把 `lines[i].content`（和词级 token）**改写成罗马字** ⇒ 适配器的"罗马字≠原文才显示"判据拿罗马字比罗马字，永远返回 nil ⇒ 上方那行永远不出现、主歌词却是罗马字；`toSpotifyLyricsData` 另外还给原生 payload 罗马化 | 存**原样 dto**；`toSpotifyLyricsData` 不再改写 content（原生页回原文）；`romanization(original:romanized:)` 改成**忽略大小写**比较（否则"只差首字母大写"的行会多出一行假罗马字） |

### 2.2 末行贴底（提交 `934d7ff`）

| # | 根因 | 改法 |
|---|---|---|
| 7 | `AppleMusicLyricsPage` 在**没有页脚时把 `contentInsets.bottom` 加两次**，而三档共用 120 ⇒ 播放器这一档拿到 **240pt** 空白，而容器只有 ≈400pt ⇒ **比容器中线还多** ⇒ 末行能停在容器 y=159（中线以上） | 底边距**分档**：全屏 46（不动）/ 预览卡 120（**不动**，它靠这个才让 `scrollTo(.center)` 生效）/ 播放器 **24** ⇒ 空白 48pt，末行落在 641−48=**593**，离控件条上沿（604）还有 11pt |

### 2.3 听歌页（提交 `e9efc63`，全在 `NowPlayingLyricsPlate.swift`）

| # | 根因 | 改法 |
|---|---|---|
| 1 | 展开时标题行右移 `thumbSide + thumbGap`，而那一行真机是 **308pt 宽**：`28+72+16+308 = 424 > 414` ⇒ 晃动区有 10pt 出屏；另外 `applyTitleMask` 把**页面坐标**当**元素坐标**用（差整整一个 shift），而且"右边没有兄弟控件"那一支会**把 mask 整个清掉** | 缩略图 72→**64**、间距 16→**12**（`28+64+12+308 = 412` ✓ 全在屏内；kumone 照片 40 的缩略图量出来也是 64pt），再加一道"右边缘不许越过页面右沿 −4pt"的夹子；mask 改成元素局部坐标 + "页面右沿 −8"兜底 |
| 2 | 日志 57 整份里**一次都没有** `lyrics provider written next to the artist`，而 `currentLyricsProvider` 明明是 NetEase ⇒ 卡在 `artistLabel` 的 id 查找（`now-playing-subtitle-label`）上，而且是**静默**返回 | 加**按位置**的兜底（标题那一行里、标题下方、与标题水平重叠的那个 `UILabel`）+ 两条自报日志（找不到 / 用兜底找到，带类名）；提供商改成**展开与收起都贴**（`settleAfterClosing` 只在"页面要走 / 关开关"时摘） |
| 3 | 收起态标题行 `28,98,308,51`（下沿 **149**）vs 封面顶 **146** ⇒ 压 3pt，而第二行就是歌手（注释里假设行高 46，真机是 51） | 封面缩到 242pt 之后自己就落到 ≈208（离 59pt）；另加"行底 ≤ 封面顶 − 6"的兜底夹子 |
| 6 | `openAndMount` 失败**只回退 `isOpen`**，`wantsOpen` 一个字不动 ⇒ `reconcile` 每拍照样 `keepNativeCoverHidden`，而 `coverHost` 是 nil（我们什么都没画）⇒ **换歌时新封面在它自己第一次 layout 就被按成 alpha=0，而且是永久的** | 意图带**寿命**（1s）+ 过期自愈（撤意图 + 把 Spotify 封面写回）；`coverDidLayOut` 与重试那一路都改问 `wantsOpenNow()`；`wantsOpen` 也进"残留清理"判据 |
| 8 | `firstImage` 只认"有没有 image" ⇒ **4×4 占位图被按曲目 id 缓存**（日志 57：`remembered this track's artwork 4×4 (cache 1/8)`），之后每拍都吃缓存 ⇒ 那一首永远是灰方块；另外 `visibleCover` 会挑中**离屏的那一份**（日志：`at -369264,147,366,366`），`alpha=0` 写在它身上、屏幕上那张一点没变 | 图要 **≥128pt** 才要（太小的**跳过继续找**）；缓存里的坏条目**丢掉重认**；`firstVisibleCover` **优先挑落在页面范围内**的那一份（带 80pt 容差，找不到才退回老行为） |
| 9 | 歌词块顶边 242、淡出带只占顶部 8%–12% | `lyricsTop 66 → 24`（缩略图 64 之后 header 下沿 168 ⇒ 块顶 ≈**192**，整块上移 ≈50pt，一屏多 1–2 行），`lyricFadeStops[1] 0.12 → 0.10` 保证第一行仍在淡出带外 |
| 10a | 收起态那张大封面是 **Spotify 自己的**（我们那份只在展开时存在），尺寸完全由它的 frame 决定（366pt @ 24,146） | **只写一个 transform** 把它缩到 **242pt**（`restingCoverSide`）：与它**原有** transform 复合、按对象记住原值、离开页面/关开关**精确还原**（仓库规矩 14）。因为 `measure()` 用的是 `convert`（含 transform），`geometry.cover` 自动变成 242 ⇒ 缩略图比、动画起点全部跟着对；封面顶边同时落到 ≈208（顺手把 #3 也解决了） |
| 10b | 没有现成的单行歌词可复用（Spotify 自己那条 `singalong-lyrics-view` 被我们**关掉了**） | 新增一行居中 `UILabel`（22pt semibold、投影、不吃触摸、id `eevee-npv-single-lyric`），**y = 封面底边与控件条上沿的中点**；判据**一处都不新写**：行模型 `currentLines()`、当前行 `LyricPlaybackTimeline.position()`（本仓库唯一入口）、位置 `WordByWordPositionResolver`、节拍蹭 0.3s（**不抢**共享 CADisplayLink）；新开关 `nowPlayingSingleLyric`（默认开）+ 设置页一行 + en/zh-CN 文案 |

### 2.4 自查发现的两处地雷（提交 `e6b00c4`，**在 e9efc63 之后补的**）

| 地雷 | 为什么危险 | 改法 |
|---|---|---|
| 封面缩放只盯**一个**对象 | 日志 57 证明**同一页会挑出不同的封面候选**（`-369264,147,366,366` 与 `24,147,366,366` 都出现过）。只盯一个的话，"这一拍挑中另一个"会把上一个**还原成 366pt** —— 而屏幕上正显示的很可能就是它 ⇒ 封面在大小之间来回跳 | 改成**记名册**：凡是被缩过的都进 `NSHashTable`（弱引用，仓库里 `DeclutterChrome` / `NowPlayingControlsPlate` 同款），各自记原 transform，还原时逐个写回；出册条目会清掉（`ObjectIdentifier` 是地址、可能被复用） |
| 单行歌词没问"这份行模型是不是这一首的" | 切歌**不一定**伴随歌词请求（客户端缓存命中 / 离线歌词），`currentLyricsDto` 可能还是上一首的 ⇒ 封面下面那行会显示**上一首的歌词** | 用两层早就有的**同一个口径**（`LyricsWordByWordOverlayView.belongsToAnotherTrack` / `WordByWordHost.lineModelIsForeign`：`currentLyricsDtoTrackId` vs 实时 `trackIdentifier`）；不一致就**这一拍不画** |

---

## 3. ★ 装机验收（**下一轮照这张单子**）

### 3.1 先点一次 CI

`Actions → Build IPA — patched (Orion.framework + zxPluginsInject) → Run workflow`，`ipa_url` **留空**
（`.deb` 那一步无条件跑 = 把全部 Swift 编一遍）。**它红了就先修编译，别的都别验。**

### 3.2 装机顺序与判据

| # | 怎么做 | 应该看到 | 日志里的判据 |
|---|---|---|---|
| ① | 开一首**长歌名**（最好英文长句），**不展开歌词**，看标题行 | 歌名在左上 28…336 那一行来回晃，**整条晃动区都在屏内**（右边不越过 414） | —— |
| ② | 点开歌词（展开） | 缩略图 **64pt**、歌名右移后**右边缘仍在屏内**（≤410）；长歌名在右边**渐隐**而不是硬切 | `expanded — thumbnail 64pt at …` + `title row lifted … / shifted …`（shift 应 ≤74） |
| ③ | 看歌手那一行 | 读作 **`花譜, 羽生まゐご（NetEase）`**；**收起歌词之后仍然是它**（不再还原成纯歌手名） | `lyrics provider written next to the artist — "…" + "（NetEase）"`（**每换一首歌允许再报一次**）；找不到时是 `cannot find the artist line …` 或 `the artist line was found by position, not by id — class …` |
| ④ | 看封面 | 大封面**明显变小**（≈242pt、居中、顶边 ≈208），歌手的下半截**不再被压** | `artwork picked …`（挑中的那份不应再是 `at -369264,…` 那种离屏坐标） |
| ⑤ | **用下面那颗 ⏮/⏭ 连续换歌 10 次** | **每一次**大封面都在（不许出现"封面没了"或"空一块"） | 不该再出现"只有 `not expanding …` 而没有 `expanded —`"的成对现场 |
| ⑥ | 放一首**逐词（yrc）日文歌**（就是照片 76 那首 `わたしの線香`），开「日语罗马化」 | 主歌词是**日文原文**，**罗马字在它上方**；不再整行被替换 | `[Netease] word-by-word — translation built from ytlrc (N line(s))`（或 `… paired by line index`）+ `expanded — … translation N/M romanization M/M`，**两个 N/M 都不该是 0** |
| ⑦ | 看译文 | 逐词歌**下方有译文**（以前完全没有） | 同上那行的 `translation N/M` |
| ⑧ | **Spotify 原生歌词页**（全屏歌词 / 卡片底那一行） | 也回**日文原文**（罗马字只由我们这层画）；底部**不再有 `(EeveeSpotify)`** | 视觉确认（payload 内容没有日志） |
| ⑨ | 划到歌词**最后一行**，继续往上划 | 末行**停在歌词视图底部**（贴控件条上方 ~11pt），**划不到中间** | —— |
| ⑩ | 看歌词区顶部 | 歌词从 ≈192 开始（比上一版高 ≈50pt），顶部淡出带**跟着上移**、第一行完整可见 | —— |
| ⑪ | 看大封面与歌词键之间 | 有**一行居中歌词**，随播放换句（交叉淡入 0.18s）；**展开歌词时它消失** | `the one-line lyric between the cover and the lyrics button is up (22pt, centred between …)` |
| ⑫ | 设置 → 扩展功能 | 多了一行「**封面与歌词键之间显示一行歌词**」（默认开）；关掉它 ⇒ 那一行**当场**消失 | —— |

### 3.3 顺带要拍的（上一轮的老账，别忘）

`(anchors: navBottom=… progressTop=… bottomStackTop=…)` 三个都得是数字；进出转场不闪；
胶囊 `[Declutter] hid the Now Playing pill row … — hide #N`；音量条两个小喇叭与轨同线。

---

## 4. 未验证声明（**不要删这一段**）

* **这一轮 10 个源码文件 + 2 个 l10n 文件，一行都没在真机上跑过。** 本机**没有 Swift 工具链**，
  所以"能编译"这件事**只有 CI 能回答**；六条自检**不做类型检查**。
* **照片 40/41 的封面尺寸是我逐像素扫出来的**（不是目测）：kumone 封面 x 122…467px、
  y 291…639px ⇒ ×0.7005 = **242pt 见方、居中、顶边 ≈204pt**；我们那张是 `24,146,366,366`。
  扫法：`GetPixel` 逐行/逐列找暗块边界（`C:\dsh\else\41.jpg`，591×1280）。
* **#6（漏封面）与 #8（取错图）的根因是代码实证**（`wantsOpen` 只有 `closeEverything` 会清；
  `firstImage` 无尺寸判据 + 日志里那条 `4×4`），但**"改成这样就一定不漏"没在机器上验过**。
* **#2（提供商）我判的是"id 查不到"**：证据是"日志 57 里一次都没有那行日志 + provider 确实有值"。
  真机上到底走的是新加的**位置兜底**还是仍然找不到，要看日志里那两条新行（见 ③）。
* **#5（译文）的 offset 对齐是推的**：`buildTranslation` 按 offset 配对，`parseLrc` 早就为 yrc
  行头修过精度（源码注释里有）；**万一 ytlrc 的时间戳和 yrc 不是一套**，会自动走"按行序配对"
  那一支（日志里能看出走的哪一支）—— 但"配对会不会错一行"没有真机数据。
* **#7 的副作用（已知、未验）**：底边距从 240 收到 48 之后，**很短的歌**（约 ≤5 块歌词）
  内容不再比视口高 ⇒ `scrollTo(anchor: .center)` 没有可滚范围，当前行可能不再居中。
  这是"末行贴底"与"短歌居中"的固有取舍；真出了就把底边距改成"至少让内容高于视口"的动态值。
* **#10a 的封面缩放动的是 Spotify 自己的视图**（只写 transform、原值可还原）。
  没验过的两点：① 它上面可能有的**反光/阴影层**是否跟着缩放；② Spotify 自己的布局回合
  会不会把 transform 写回（我们每 0.3s 重算一次，重复写只在"真的不一样"时发生）。
  若照片上出现"封面比周围反光小一圈"或"封面一会大一会小"，把 `restingCoverSide` 改回 366
  就是一行回滚（`restoreCoverScale` 那条路会把它还回去）。
* **旧版遗留**：`romanizeLine` / `romanizedIfEnabled` 现在**零调用点**（保留了函数，没删）；
  旧 UIKit 逐词层（`LyricsWordByWord.x.swift`）因此**不再显示罗马字**（它自己那份是"替换"
  而不是"上方一行"，按用户的选择不该保留替换行为）—— 若用户在那一层还想要罗马字，
  得给那一层单独做"上方一行"。

---

## 5. 下一轮最容易踩的三件事

1. **先看 CI 红不红**：`Build IPA — patched` 手动点一次（`ipa_url` 留空）。红了先修编译。
2. **一次装机只验一轮**：这一轮一次性改了 10 处，**哪一版出的问题要靠照片时间戳去对**——
   所以拍照片时按上面 ①…⑫ 的顺序、每张只拍一个判据。
3. **改别人的视图（封面缩放 / 标题行 / 分享键）之前先看 `git diff`**：这三处都写了"原值还原"，
   新增东西时**别把还原那一行删掉**（关开关 / 离开页面靠它）。
