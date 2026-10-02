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
| 1 | **整页底 = 取色三层渐变（不是模糊）** | `Sources/Kumone/Features/Player/NowPlayingView.swift:185-202` | `Appearance/NowPlayingBackdrop.swift` —— 接管播放页那层整页封面底色，铺自己的 `CAGradientLayer` | ✅ 已实现（v6.6.x，开关「听歌页 → 整页封面取色底」） |
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

我们（UIKit，一个 `CAGradientLayer` 表达）：

```swift
gradient.startPoint = CGPoint(x: 0, y: 0)      // topLeading
gradient.endPoint   = CGPoint(x: 1, y: 1)      // bottomTrailing
gradient.locations  = [0.0, 0.55, 1.0]
gradient.colors     = [base, base.darkened(by: 0.35), black.withAlphaComponent(0.35)]
UIView.animate(withDuration: 0.8) { /* 换色 = CA 自己插值 */ }
```

**差异（有意）**：kumone 用**两个**主色（它自己从封面算 primary/secondary）；
我们只有一个 `extracted_color`，所以"次色"由主色**降明度 35%** 得到 ——
同一观感方向，且**不额外要数据**。

**为什么必须记这一笔**：本仓库 2026-10-02 的"自绘壳"就是因为**加模糊层盖在内容上**
而糊底被整块删除（见 `Tweak.x.swift:384-387`）。取色渐变是**在底层铺颜色**，
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

⇒ 播放页**本来就有**一层"整页、底色等于封面取色"的视图。我们的做法是**接管它**
（清空底色 + 塞自己的渐变层 + 记下原值以便还原），而不是在最上层再盖一层。

---

## 4. 还没做但已经看好的（下一轮候选）

* 歌词列渐隐 mask（§1#3）；
* 头部排版（§1#4）——需要复查节拍，因为 Encore 的 binder 会把属性写回去；
* 控件行的间距/尺寸对齐 kumone 的几何（`controls` 在 `NowPlayingView.swift:766`）。
