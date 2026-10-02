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
