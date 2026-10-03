# kumone 参考清单（听歌页仿 Apple Music）

> 写于 2026-10-03。对象：本地 checkout `C:\Users\ngzhwm\Documents\GitHub\kumone`
> （**独立**网易云客户端，macOS + iOS，SwiftUI）。它**不是** Spotify 补丁 ——
> 所以"借鉴"只能是**手法、几何、曲线、常量**，不是整段视图代码。

---

## 0. 许可（先看这条，决定能借多少）

| 文件 | 内容 | 与我们（GPL-3.0）的关系 |
|---|---|---|
| `LICENSE` | **LGPL-3.0**（库部分） | ✅ 兼容 |
| `COPYING` | **GPL-3.0**（应用部分） | ✅ 同许可，兼容 |
| `README.md` 徽章 | `LGPL-3.0-only` | —— |

⇒ 与本仓库的 `spoti.pw`（PolyForm Strict，"**只借思路、绝不看源码**"）**完全不同**：
kumone 的许可是 copyleft 兼容的，**代码都能用**。

**纪律（照旧执行）**：
1. 借用**必须署名** —— 「开源许可」页（`Sources/EeveeSpotify/Settings/Sections/Licenses/`）
   要加一行 kumone / LGPL-3.0+GPL-3.0，并把借了什么写清楚；
2. **数值与曲线可以直接抄**（那些是"手感"，不是可版权表达）；
3. **整段视图代码不搬**：它是 SwiftUI + 自己的数据模型，我们是 UIKit + Spotify 的视图树，
   搬过去等于重写一遍，还多一层许可义务。**要搬就搬原子件**（下面 §1 那张表）。

---

## 1. 可借清单（按"能不能落到我们代码里"排序）

| # | 借什么 | 它的位置 | 我们这边怎么落 | 状态 |
|---|---|---|---|---|
| 1 | **整页底 = 取色三层渐变（不是模糊）** | `Sources/Kumone/Features/Player/NowPlayingView.swift:185-202` | `Appearance/NowPlayingBackdrop.swift` —— 在那层整页封面底色**之上垫一个我们自己的整页视图**（三层 `CAGradientLayer`），原来那层一字节都不改 | ✅ 本轮 重做（见 §2.1；开关「听歌页 → 整页封面取色底」） |
| 2 | **几何/曲线常量表** | `Features/Player/NowPlayingPresentation.swift:7-91`（`NowPlayingPresentationMetrics`） | `Appearance/NowPlayingMetrics.swift` | ✅ 已落表（部分还没被消费） |
| 3 | **歌词列上下渐隐 + 拖动暂停** | `NowPlayingView.swift:899-931`（`lyricsColumn`：`LazyVStack(spacing: 26)` + `LinearGradient` mask 停点 0/0.12/0.85/1 + `spring(0.8, 0.85)` 跟随，用户一拖就停） | 逐词层外层加 mask；`inline host found` 那条路径 | ⏳ 下一轮 |
| 4 | 播放页头部排版（歌名加粗放大、`⋯` 靠右） | `NowPlayingView.swift` 的 `CompactTrackHeader` / `trackMetaView` | 靠 `LibraryAppearance` 那套**复查节拍**改 Spotify 标签（binder 会写回） | ⏳ 待定 |
| 5 | 下拉关闭 / 迷你条上推展开的阈值与曲线 | `NowPlayingPresentation.swift:49-80` | 手势线（我们已有双击手势；下拉关闭得先确认 Spotify 自己的手势会不会打架） | ⏳ 暂不做 |
| 6 | 取色器 `ArtworkPalette`（从封面图算出 primary/secondary） | `DesignSystem/ArtworkPalette.swift` | 我们**不需要**：Spotify 已经给了 `metadata()["extracted_color"]` | ❌ 不借（重复造轮子） |
| 7 | 黑胶/唱片机视图、AutoMix、CarPlay、StemKit | `Features/Player/Vinyl/*`、`Core/Player/*`、`StemKit/*` | 与"仿 AM"无关，且体量巨大 | ❌ 不借 |

---

## 2. 我们照抄的那三层（逐字对照）

kumone（SwiftUI）：

```swift
ZStack {
    LinearGradient(colors: [colors.primary, colors.secondary],
                   startPoint: .topLeading, endPoint: .bottomTrailing)
    RadialGradient(colors: [.white.opacity(0.12), .clear],
                   center: .topLeading, startRadius: 0, endRadius: 700)
    LinearGradient(colors: [.clear, .black.opacity(0.35)],
                   startPoint: .top, endPoint: .bottom)
}
.animation(.easeInOut(duration: 0.8), value: colors)
```

我们（UIKit，**三个** `CAGradientLayer`，与上面对齐）：

```swift
// ① 取色对角渐变（不透明 —— 它才是"把底色换掉"的那一层）
base.startPoint = .init(x: 0, y: 0)      // topLeading
base.endPoint   = .init(x: 1, y: 1)      // bottomTrailing
base.colors     = [primary, primary.darkened(by: 0.35)]
// ② 左上白光晕（kumone 的 700pt 半径 → 单位坐标要按尺寸换算）
halo.type = .radial; halo.startPoint = .init(x: 0, y: 0)
halo.endPoint = .init(x: 700 / w, y: 700 / h)
halo.colors = [white 12%, clear]
// ③ 底部压黑 35%
scrim.startPoint = .init(x: 0.5, y: 0); scrim.endPoint = .init(x: 0.5, y: 1)
scrim.colors = [clear, black 35%]
// 换歌：CATransaction + easeInEaseOut + 0.8s（= kumone 的 .animation(.easeInOut(0.8))）
```

**差异（有意）**：kumone 用**两个**主色（它自己从封面算 primary/secondary）；
我们只有一个 `extracted_color`，所以"次色"由主色**降明度 35%** 得到 ——
同一观感方向，且**不额外要数据**。

### 2.1 ★ 本轮 为什么不再"清空人家的底色"（2026-10-03 夜，日志 38 换来的）

旧做法是**清空那一层的 `backgroundColor` + 往它的 layer 栈里 `insertSublayer(at: 0)`**。
日志 38（构建 `b14d6b9`）给了判决：

```
11:52:59  [NPVStyle] backdrop (414x896) ← 封面取色 e84838，接管 1 层   ← 自报成功
11:53:01  [Tree] #7 7.UIView@0,0,414,896,bg=#E84838                  ← 那层还在（没被清掉）
11:53:09  [Tree] #9 7.UIView@0,0,414,1682,bg=#584860                 ← 还自己换了色、长高了
```

`ViewTreeDumper.swift:159` 只在 `backgroundColor != nil && != .clear` 时才打 `bg=` ⇒
"清空"这件事在树上**没有留下痕迹**，页面上零变化。⇒ 结论：**不要往别人的 layer 栈里塞东西、
也不要跟它的 binder 抢 `backgroundColor`**（`MiniBarGlass.swift:244-285` 已经为同一个坑写过
"清了又写回"）。

新做法：**我们自己的一个整页 `UIView`（三层渐变作子层），`insertSubview(at: 0)`**：
* 那层自己的底色在我们下面（我们铺的是不透明底）⇒ 观感上就是"换掉了底色"；
* 那层自己的**子视图**（真有内容的话）仍然在我们上面 ⇒ **最坏只是"没效果"，不会盖掉内容**；
* **零破坏性写入** ⇒ 关开关就是把我们的视图拿走，天然完全还原。

**为什么旧的"模糊自绘壳"不一样**（`Tweak.x.swift:384-387`）：那次是**加模糊盖在内容上**
（2026-10-02 的"自绘壳"就是这么糊底被整块删掉的）；这次是**只替掉背景那一层的颜色**，
机理相反 —— 这条区别别忘。

---

## 3. 我们落到 Spotify 视图树上的依据（真机 `[Tree]`）

```
9.NPVGradientView@0,0,414,896                      ← 整页，Spotify 自己的渐变类
7.UIView@0,0,414,896,bg=#E84838                    ← ★ 整页，底色 = 封面取色（换歌会变）
7.UIView@0,0,414,896,bg=#4890E0                    ← 同一层的下一首
7.UIView@0,0,414,896,bg=#302838                    ← 再下一首
8.UIView@0,0,414,48,bg=#121212                     ← 压在上面的 48pt 导航条
```

⇒ 播放页**本来就有**一层"整页、底色等于封面取色"的视图。我们的做法是**在它之上垫一个
我们自己的整页视图**（`insertSubview(at: 0)`，三层渐变），**它自己的底色/子视图一字节都不改**。
为什么不是"清空它的底色 + 往它的 layer 栈里塞层"：见 §2.1（日志 38 的判决）。

★ **这也让"哪一层"变成可核对的事**：`[NPVStyle] backdrop …` 那行现在会带上被垫那层的
类名、frame、它自己的底色、`subviews` / `layer.sublayers` / **手插子层**数 ——
下次不用再翻 `[Tree]` 的 BFS 层级反推（日志 38 就是这么反推出来的，代价很大）。

---

## 4. 还没做但已经看好的（下一轮候选）

* 歌词列渐隐 mask（§1#3）—— ✅ 2026-10-04 已在 `NowPlayingLyricsPlate` 里用上（`lyricFadeStops`）；
* 头部排版（§1#4）——需要复查节拍，因为 Encore 的 binder 会把属性写回去；
* 控件行的间距/尺寸对齐 kumone 的几何（`controls` 在 `NowPlayingView.swift:766`）。

---

## 5. ★ 照片 40 / 41 的逐像素量测（2026-10-04）：**"看齐"的具体目标**

用户点名：**以 `C:\dsh\else\40.jpg` / `41.jpg` 为准**（kumone 播放页，10-02 21:12 拍的）。
两张是**同一页面**的两种状态：

| 照片 | 状态 | 中间那块 |
|---|---|---|
| **40** | 这首歌**没有歌词** | 一个小音符图标 + 「纯音乐，请欣赏」 |
| **41** | 有封面、无歌词排版 | **居中大圆角封面** |

591×1280px 的照片按 414pt 屏宽换算（×0.7005），量出来的**纵向分区**：

| 区块 | 照片里（pt） |
|---|---|
| 下拉小横条 | ≈ 81–84（44×5 胶囊） |
| **header**：缩略图 + 歌名（粗体）+ 艺人 + ♥ + ⋯ | **95–185** |
| **中间那块** | **185 → 644**（≈ 459pt） |
| 进度条 + 时间 | 644 / 680–708 |
| 三键（◀ ▶▶ ▶▶） | 712–740 |
| 音量条（含两端喇叭图标） | 776–784 |
| 三个圆钮（评论 / 音频路由 / 播放队列） | 800–845 |

### 5.1 与我们这一页（日志 42 的真机树）逐条对照

| 区块 | kumone | 我们（9.1.88） | 判定 |
|---|---|---|---|
| header | 95–185 | `UIStackView@0,48,414,48`（缩略图+歌名+艺人+分享/菜单） | ⚠️ 位置略高，**结构一致** |
| 中间那块 | **185–644** | 封面 `374×374 @≈115–489`，**下面是卡片堆** | ❌ **唯一的分水岭** |
| 三键 | 712–740 | `npv.bottomStackView` 内第 3 行 `UIView@0,108,406,88` ≈ 701–789 | ✅ |
| 音量条 | 776–784 | 我们的音量条 `8,860,398,32` | ✅ |
| 三个圆钮 | 800–845 | `UIView@0,833,414,62` | ✅ |

⇒ **一句话**：**header 与底部已经对上了；"像不像"只取决于中间那块有没有卡片堆。**
这就是 2026-10-04 把「**一屏**」默认值改成**开**的理由（`UserDefaults.nowPlayingOneScreen` 的注释里也写了）。

### 5.2 歌词块该放哪（由此定下来）

`NowPlayingLyricsPlate` 的落点 = **底部那一坨正上方、与它同高**：
`y = 593 − 8 − 240 = 345`，`h = 240`（即 **345–585**）——
正好落在 kumone"中间那块"（185–644）的下半截 + 封面(115–489)的下沿。
⚠️ **绝不能摆到页面顶部**（96 那种）：那会盖住 header。第一版就是这么写的，对着照片才发现。

---

## 6. ★ 2026-10-11：照片 67（我们）vs 照片 68（kumone 现在这一版）—— 差距逐项量出来

> 两张都是 591×1280px，按 414pt 屏宽换算（×0.7005）。用户的话：**「是不是还差个百分之五六十左右」**。

| 纵向区块 | kumone（照片 68） | 我们（照片 67 / 日志 55） | 差 |
|---|---|---|---|
| 顶部（拖拽横条 / Spotify 自己的导航条） | 横条 ≈52 | 导航条 **0–96**（`v` + `1` + `⋯`，躲不开） | —— |
| **header**（缩略图 + 歌名 + 艺人） | **67–133**（缩略图 72pt，歌名**粗体一行**截断；右侧还有 ♥ + ⋯） | **169–241**（缩略图 72pt @ `28,169`；歌名 + 艺人；右侧没有 ♥/⋯） | **我们低了 ≈100pt** |
| header → 歌词的留白 | ≈109pt（歌名下方一大片空） | ≈20pt（`lyricsTop`） | 我们**少** ≈90pt 呼吸 |
| **歌词块** | **242–623（≈381pt）** | **261–584（323pt，日志 55：`20,261,374,323`）** | 我们**矮** ≈58pt |
| 歌词块 → 进度条 | ≈19pt | ≈100pt（容器下沿 584 → 进度条 ≈693） | 我们**多** ≈80pt 空 |
| 进度条 + 时间 | 642 | ≈693 | —— |
| 三键 | 721（**只有 ◀ / ▶ / ▶▶**） | 774（有 **shuffle + repeat**，共 5 颗） | 我们多两颗 |
| 音量条 | 803（两端喇叭） | 没有（`nowPlayingVolume` 开关默认关） | 我们缺一条 |
| 底部圆钮 | 855（3 颗） | 813（4 格） | —— |

### 6.1 观感差距里**占比最大的三项**（不是"再调调间距"能补的）

1. ★★ **歌词排版太挤**（最像/最不像的分水岭）。照片 68 一屏 **4 块**（每块 = 主歌词 1–2 行 + 译文），
   照片 67 一屏塞 **7–8 行**且**没有译文**。量的结果：kumone 主歌词 ≈**22pt**、译文 ≈**17pt**、
   块间距 **26pt**（它源码 `LazyVStack(spacing: 26)`）；我们用的是 `.preview` = 20 / 14 / **10**。
   ⇒ **已落代码**（本轮）：新增 `.player` 档（22 / 17 / **26** / 6），
   `AppleMusicLyricsTextProfiles.swift` + `AppleMusicLyricsOverlay` 里按 `showsPreviewHeader == false` 选它。
2. ★★ **header 比 kumone 低 ≈100pt**。根因在几何：缩略图的 y 是**跟着原生封面走的**
   （`NowPlayingLyricsPlate.measure()`：`thumb.y = cover.minY + thumbTop(8)`，日志 55 的
   `cover.minY = 161` ⇒ 169）。而 kumone 的 header 贴在自己那根横条下面（67）。
   我们上面有 Spotify 的 96pt 导航条躲不开 ⇒ 目标应改成 **导航条下沿 + 8 ≈ 104**
   （那 65pt 空档：96–161 现在是白扔的）。
3. ★ **歌词块向下差 ≈80–100pt**。`measure()` 把下边界锚在 `bottomStackTop`（≈593）上，
   而进度条其实更靠下（≈693）⇒ 中段有 ≈100pt 空着。

### 6.2 建议的改法（按"性价比 ÷ 风险"排序，一轮一片）

| 片 | 做什么 | 落在哪 | 风险 |
|---|---|---|---|
| ① | **歌词排版换 `.player` 档**（22/17/26/6） | ✅ **本轮已改**（两个文件） | 低（只动我们自己的档位） |
| ② | **header 上移到导航条下沿**：`thumb.y` 不再跟 `cover.minY`，改成 `navBarBottom + 8`；导航条下沿用 **id** 量（`now-playing-minimize-button`） | `NowPlayingLyricsPlate.measure()` 一处 | ✅ **2026-10-11 已做**（169 → ≈104） |
| ③ | **歌词块下边界改锚到进度条**：用 `Components.UI.ProgressBarUnitNowPlaying`（id）的顶边 − 19 | 同上，一处 | ✅ **2026-10-11 已做** |
| ③b | **header 与歌词之间那段空气**：`lyricsTop` 20 → **66**，让歌词正好从 **242** 开始（= kumone） | 同上（一个常量） | ✅ **2026-10-11 已做** |
| ④ | **藏 shuffle / repeat**（kumone 只有三键） | 已有 declutter 开关 | 低（用户偏好） |
| ④b | ~~音量条~~ ✅ **2026-10-11 已做**：音量条本来就有（`nowPlayingVolume`），但那是**系统原样的 `MPVolumeView`**（照片 69：iOS 26 的玻璃胶囊轨 + 大钮、铺满整宽），kumone（照片 68）是**细轨 + 小圆钮 + 两端小喇叭**。改法：`MPVolumeView` 的**公开图片接口**（`setMinimum/MaximumVolumeSliderImage(_:for:)` / `setVolumeThumbImage(_:for:)`）喂进可拉伸的 4pt 胶囊轨与 14pt 白圆钮，行左右内缩 24pt，两端加 `speaker.fill` / `speaker.wave.3.fill` 两个装饰图标 —— 落在 `NowPlayingPageOverlay` | 同上 | 低（只动我们自己的覆盖层，公开接口） |
| ⑤ | **逐行译文 / 罗马字**：kumone 每块下面都有译文，我们 overlay 现在**没传** `showsTranslation`（恒 false） | `AppleMusicLyricsOverlay` 的 page 调用 | ★ **用户 2026-10-11 明确说"之后再说"** ⇒ 本轮不动，也不写进近期计划 |

★ 纪律提醒：②③ 动的都是**别人的布局**（Spotify 的标题行与底部堆），**一次只改一片、装一次机看一次**；
日志里要能读出"算出来的 y 是多少、量到的是什么"，否则下一轮又是靠猜。

### 6.3 ★ 2026-10-11：「不做点击、只要像」——能到多少？

用户问：**「如果在暂时不做点击功能，只要求像/一样的情况下，我们现在能和 kumone 一样吗」**。

**答案：纵向分区基本能逐条对上（≈85–90%），但有三处结构性差别，其中一处是用户主动推迟的：**

| # | 差别 | 能不能靠"不做点击"补上 |
|---|---|---|
| 1 | **顶部**：Spotify 的导航行（`v` / `1` / `⋯`）vs kumone 的 44×5 拖拽横条 | ❌ **不该补**：那三个是关掉播放器的唯一入口。后果 = 整个 header 带比 kumone 低 ≈37pt（我们最多提到导航条下沿 104） |
| 2 | **歌词列**：kumone 每块 = 原文 + 译文；我们只有原文 | ⏳ 字号/行距/块距已经对上（`.player` 22/17/26/6），但"块"的形态不同 —— **用户 2026-10-11 明确说"之后再说"** |
| 3 | **header 右侧**：kumone 有 ♥ + ⋯ | ✅ 能：画两个装饰图标即可（纯视觉、不接动作）；也可以做一个真点赞（那是点击功能，本轮不做） |
| 4 | （次要）transport 5 键 vs kumone 3 键；底部 4 格 vs 3 圆钮 | ✅ 能，但要**藏掉 shuffle / repeat / 分享** —— 那是功能取舍，得用户点头 |
| 5 | （次要）音量条 | ✅ 已换皮（§6.2 ④b） |

⇒ 也就是说：**"像"这件事的剩余部分，一多半不在几何，而在"要不要藏掉 Spotify 的功能入口"与"歌词要不要带译文"。**

### 6.4 ★★ 2026-10-11 用户亲手点名：这一页每个元素是什么（**以此为准，之前我认错两个**）

用户原话：

> 我的那一堆 spotify 是这样的：左上角那个是**关闭页面**，**1 是我的歌单名字**，右上角那个是 spotify 的
> 其中一个**功能菜单**，那个**绿色的勾是收藏歌曲**的（也是一个 spotify 菜单），左下角那个有电脑的是
> spotify 的**设备联动**功能（菜单），右下角那两个是**分享歌曲**（功能）和**播放页**（功能）。

| 位置 | 是什么 | 真机树里的身份（日志 54，**id 都是现成的**） | kumone 那边的对应物 |
|---|---|---|---|
| 左上 `v` | **关闭播放器** | `Tertiary@0,0,48,48,id=now-playing-minimize-button` | 44×5 拖拽横条 —— **不该动**（唯一出口） |
| 中间 `1` | ★ **歌单名**（不是队列序号！） | `AutoLayoutStackView@0,0,30,48,id=now-playing-navigation-unit-title-label` | kumone 没有这一行 ⇒ 想更像可以藏它 |
| 右上 `⋯` | 功能菜单 | 导航条那一行里的 `Tertiary@0,0,48,48,id=Context menu` | **header 右侧的 `⋯`** —— 可以搬进 header 行 |
| ★ 绿色 ✓ | ★★ **收藏歌曲**（= 我先前误认成"奇怪的浮层"的那个） | `UIButton@0,0,48,48,id=Components.UI.AddToButton`（页里有**两份**，其中一份常 `hidden`）+ `StateMicroInteractionView<AddToButtonState>` | ★ **header 右侧的 `♥`** —— **搬进 header 行**最像 |
| 左下（电脑） | 设备联动（Spotify Connect） | `ConnectButtonOutputSwitcherViewHolder`/`EncoreButton …id=Components.ConnectButtonOutputSwitcher` | kumone 底部有"音频路由"圆钮 ⇒ 二选一 |
| 右下（分享） | 分享歌曲 | `EncoreButton@0,0,44,44,id=ShareButtonNowPlayingView` | 底部圆钮之一 |
| 右下（列表） | 播放页（队列） | `Control@0,0,47,32,id=QueueButtonNowPlaying` | 底部圆钮之一 |

**这条纠正把结论改好了**：上一节 §6.3 说"♥/⋯ 只能画装饰图标"——**错**。
绿色 ✓ 与 `⋯` **本来就是 Spotify 的功能控件**（收藏 / 菜单），所以"像 kumone"的正解是
**把它们搬到 kumone 的位置**（header 行的右侧），而不是画两个假图标：
* **不需要写任何点击逻辑**（控件本身就能用）；
* 顺手解决一个观感问题：那颗绿色 ✓ 现在**浮在歌词区中间偏右**（照片 60/63/67/69 都能看到），
  搬上去之后歌词列不再被压。

手法照旧是**「搬 holder 不搬控件」**（wrapper 上做 `transform`，触摸跟着走）——
但**属于"动别人的布局"，按仓库规矩 7 要先问用户**（藏 / 改 alpha / 改位置三种后果不同）。

### 6.5 ⚠️ 2026-10-11 两轮：绿 ✓ 先搬进 header、**又按用户的第二版方案撤掉了**

第一轮（`f2dc707`）：把绿色 ✓ 按 kumone 的 ♥ 位搬进 header（中心 = 页面右沿 − 97pt、缩略图中线）。
**第二轮用户改主意了**（照片 71 的原话：「那个绿色勾就**让它呆在那里**」）⇒ 那一版**已撤**，
换成用户自己画的方案 —— 详见 [`SESSION_2026-10-11_HANDOFF_2.md`](SESSION_2026-10-11_HANDOFF_2.md) §1/§2：

* **控件条** = 进度条上方那一条空带（绿 ✓ 本来就在 626 那一条）：**[分享 58] [我们的歌词键 215] [绿 ✓ 371（不动）]**；
* **关着歌词时**：歌名/歌手贴左上角（照片 73 的 kumone 位，`navBottom + 2`），把这一条让出来；
* **展开歌词时**：封面(缩略图)占左上角、歌名/歌手右移 —— 这是原来就有的行为，不变；
* 底部那两排（Connect/收起/分享/队列、shuffle/prev/play/next/repeat）**一颗都不动**。

★ 教训（写进 §4 的规矩里）：**"搬别人的控件"这件事，方案可能被用户一句话推翻** ——
所以两次都做成"一个函数 + 一处调用 + 收尾能无条件还原"，撤的时候只删那一段，不留死代码与开关。





