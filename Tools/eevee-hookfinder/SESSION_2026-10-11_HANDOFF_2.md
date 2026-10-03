# SESSION_2026-10-11_HANDOFF_2 — 收藏键（绿色 ✓）搬进 header + 无时间轴歌词不再误报「未找到」

> **读的顺序**：先 [`SESSION_2026-10-11_SUMMARY.md`](SESSION_2026-10-11_SUMMARY.md)（整场汇总：照片 60–70 / 日志 53–55），
> 再看本文件（它是那之后的一轮）。上一轮的交接在
> [`SESSION_2026-10-11_HANDOFF.md`](SESSION_2026-10-11_HANDOFF.md)（进出转场 / 胶囊 / 几何）。
>
> **这一轮的输入**：用户点名的四类参考件 —— `C:\dsh\ipa` 里的日志、`Spotify-9.1.88.ipa`、
> `dump-9.1.88.txt`、`C:\dsh\else\{40,41}.jpg`（**kumone 听歌页**）与 `70.jpg`（我们）。
> **输出**：2 个源码文件 + 2 个 l10n 文件（**未编译、未装机**）。

---

## 0. 三十秒现状

| | |
|---|---|
| **仓库起点** | `c8f766e`（= 功能批 `b9e250b` + 修正 `5541023` + 汇总文档）；工作区干净 |
| **★ 先纠正一条**：真机上跑的**已经是 `b9e250b`** | 照片 70（20:21）晚于 `b9e250b` 的提交（19:27），而它显示的正是那一批的几何（缩略图贴导航条下沿）+ 新音量条 ⇒ **几何 / 排版 / 音量 / 胶囊这几项已在照片 70 上确认落地** |
| **❌ 但 `C:\dsh\ipa` 里最新日志仍是 55**（18:29，**改前**那一版） | 55 里**没有** `(anchors: …)`、**没有**胶囊的 `hide #N`、**没有**三种说明文案 ⇒ `b9e250b` 的**行为面一份日志都没有**（§6 那张单子还挂着） |
| **这一轮改了两件** | ★ **S1**：无时间轴歌词不再冒充「未找到歌词」（新键 `lyrics_no_timeline`）★ **S3a**：Spotify 自己的**收藏键（绿色 ✓）搬进 header 行的右侧** —— kumone 的 ♥ 位 |
| **下一个动作** | CI → 装机 → **日志 56 + 照片**，按 §6 收口 |
| **本机没有 Swift 工具链** | 六条自检全绿（§5），但类型检查只能靠 CI |

---

## 1. 照片 40 / 41 / 70 的实测（这一轮**重新裁图量过**，不是照抄文档）

### 1.1 kumone（40 = 无歌词、41 = 有封面；都是 591×1280px，按 ×0.7005 换成 414pt 宽）

| 区块 | 实测 |
|---|---|
| header | 缩略图 67–125（40 有、41 没有）；标题粗体 + 艺人；**右侧 ♥ 中心 ≈ (449px→314.5pt, 138px→96.5pt)**、**⋯ 中心 ≈ (509px→356.6pt)** |
| 中间那块 | 40：音符 + 「纯音乐，请欣赏」；41：居中大圆角封面 |
| 进度条 / 三键 / 音量条 / 三圆钮 | 647 / 722 / 783 / 833 |

⇒ **♥ 的中心距页面右边 = 414 − 314.5 ≈ 99.5pt**（本仓库取 **97**，见 §4.1）。

### 1.2 我们（照片 70）

| 区块 | 实测 |
|---|---|
| 导航条 | `v`(≈73pt) / 歌单名 `1` / `⋯`(≈380pt) —— Spotify 自己的，不动 |
| header | 缩略图 **104–175**（= 导航条下沿 + 8）、标题 119 / 艺人 148 |
| 歌词 | 242 → ~660（当前行居中 ≈440） |
| ★ **收藏键（绿色 ✓）** | **中心 ≈ (529.5px→371pt, 894px→626pt)，直径 ≈33pt** —— 浮在歌词区右下、进度条（677）上方 ≈50pt |
| 进度条 / 五键 / 底部四格 / 音量条 | 677 / 752 / 815 / 844 |

⇒ 与 kumone 的差距里，**唯一"能立刻补上、而且用户已经点名"的一项**就是：
**kumone 的 ♥ 在 header 行右侧（97pt 边距、与缩略图同一条中线），我们的 ✓ 浮在歌词区右下**。

---

## 2. 这一轮改了什么（**全部未编译、未装机**）

| 文件 | 改动 |
|---|---|
| `Sources/EeveeSpotify/Lyrics/…`（**未改**，只读证据） | —— |
| `Sources/EeveeSpotify/Appearance/NowPlayingLyricsPlate.swift` | ★ **S1**：`noticeText()` 第 ③ 段拆开（"有行但一行时间都没有" ≠ "没找到"）；★ **S3a**：新增 `applyHeaderActionTransform` / `restoreHeaderActionTransform` / `visibleAddToButton` / `firstVisibleAddToButton` / `clippingNote`，常量 `addToButtonIdentifier` / `headerActionTrailingInset = 97`，状态 `headerAction` / `headerActionOriginalTransform` / 两条日志闸；`layoutAndMount` 里 ②b 调用；`closeEverything` 里**无条件**还原 |
| `layout/…/EeveeSpotify.bundle/{en,zh-CN}.lproj/Localizable.strings` | 新键 `lyrics_no_timeline`（en: "These lyrics have no timing" / zh-CN:「这首歌的歌词没有时间轴」） |
| `Tools/eevee-hookfinder/SESSION_2026-10-11_HANDOFF_2.md` | 本文件 |

---

## 3. S1 ★ 无时间轴歌词被误报成「未找到歌词」——判据拆开了

### 3.1 事实链（**两行代码就能对上**）

| # | 事实 | 出处 |
|---|---|---|
| ① | `LyricLinesAdapter.toAppleMusicLyricLines()` 第一件事就是 `.filter { $0.offsetMs != nil }`；**一行时间都没有 ⇒ 返回空** | `Sources/EeveeSpotify/Lyrics/AppleMusic/LyricLinesAdapter.swift:21` |
| ② | `currentLines()` 把"空"翻成 `nil` ⇒ 我们这层没有行模型可画 | `NowPlayingLyricsPlate.swift`（`currentLines()`） |
| ③ | 而注入给 Spotify 的那份 payload **是带这些行的**（`offsetMs` 全 0 / `timeSynchronized=false`）⇒ **Spotify 自己的歌词卡列得出全文**，只有我们这层列不出 | 上一轮文档 §5·S1 |
| ④ | 旧 `noticeText()` 的第 ③ 条把"有行却画不出来"**一律**写成「未找到歌词」 | 改动前的 `noticeText()` |

⇒ 用户看到的是「**歌词明明有，插件说未找到**」——这是**误报**，不是"没词"。

### 3.2 改法（最小、只动一句话的判据）

```swift
if let dto = currentLyricsDto, !dto.lines.isEmpty {
    // 一行时间都没有 ⇒ 数据在，只是没有时间轴。
    if !dto.lines.contains(where: { $0.offsetMs != nil }) {
        return "lyrics_no_timeline".localized
    }
    // 有行、也有至少一行带时间，却还是画不出来 ⇒ 转换异常，按"没找到"说（别做死键）。
    return "ngzhwm_lyrics_unavailable".localized
}
```

**四档现在各说各的**：纯音乐 / **没有时间轴** / 查完了没有 / 还在查。

> ⚠️ 判据的**为什么**必须留在这条注释里：`currentLines()` 返回 `nil` 有三种原因，而"没有时间轴"
> 与"真的没找到"在 UI 上给用户的承诺完全不同（前者是"你这首歌的数据就这样"，后者是"我没查到"）。

### 3.3 还没做（**用户没点，先别做**）

**静态列出全文**（不走时间轴、不高亮、不滚动）——那正是 kumone 照片 41「有封面、没有歌词排版」那一档的样子。
它比"一句话"体验更好，但要动渲染层（`LyricLine` 目前**必须有 `time`**），属于另一件事。

---

## 4. S3a ★ 收藏键（绿色 ✓）搬进 header 行的右侧

### 4.1 目标坐标是怎么来的（可复核）

* kumone 照片 40/41 的 ♥：中心 ≈ **314.5pt**、与缩略图**同一条中线** ⇒ 我们取
  **中心 x = 页面右沿 − 97pt**（`headerActionTrailingInset`），**y = 缩略图的中线**（`geometry.thumb.midY`，照片 70 上是 ≈140）。
* 为什么不用 kumone 的绝对 y（96.5）：**我们的 header 比它低 37pt** —— 上面那根 96pt 的 Spotify 导航条
  （`v`/`1`/`⋯`）躲不开（§6.3 已定案）。所以"跟着我们自己的 header 中线"才是对的。

### 4.2 ★ 判据必须是"**看得见的那一份**"（页里有**两份**）

日志 54 的 `[NPVTree]` 逐字：

```
13.UIButton@0,0,48,48,hidden,id=Components.UI.AddToButton      ← 隐藏那份，BFS 里排在前面
14.UIButton@0,0,48,48,id=Components.UI.AddToButton             ← 看得见那份
15.StateMicroInteractionView<AddToButtonState>@-4,-4,56,56     ← 它的子视图（绿色圆圈的动画在这里）
```

⇒ **不能用 `findByIdentifier`**（它返回 BFS 第一份 = 那份 `hidden` 的）——那样位移会写在一个看不见的按钮上，
**屏幕零变化，而日志还会说"成了"**（这正是本仓库规矩 1/11 的老坑）。
所以 `firstVisibleAddToButton(in:)` 的判据是 `id + !isHidden + alpha > 0.01 + window != nil + 有尺寸`。

走查起点**从小到大**（同 `progressUnitTop` 的思路，整页 BFS 会被列表的格子吃掉 800 的预算）：
`npv.bottomStackView` → `SPTNowPlayingView` → `page`。

### 4.3 手法：只写 `transform` 的平移分量

* 位置由父视图的 Auto Layout 决定，**改 `frame` 会被下一拍写回**（本仓库老教训）；
* 每拍用 `untransformed(button, in: page)` 拿"去掉我们那段位移"的模型 frame，再算 `dx/dy`
  ⇒ 父视图重排 / 换歌重建都能跟上；
* 只写平移，`a,b,c,d` **原样保留**（不假设它一定是 identity）；
* **接管前先记下它自己的 `transform`**（`headerActionOriginalTransform`），收尾**原样写回**；
* 收尾放在 `closeEverything` 那条 `guard` **之前**（无条件清账）—— 位移写在**别人的控件**上，漏一次它
  就永远留在 header 上了。

### 4.4 ⚠️ 三条**已知限制**（下一份照片要专门看这三条）

| # | 限制 | 为什么会这样 | 现在怎么办 |
|---|---|---|---|
| ① | **只是"视觉"搬运，点不到** | UIKit 的 hit-test 在**祖先**那层就问 `point(inside:)` —— 搬到 header（≈140pt）之后它已经在父视图边界之外（`transform` 只改绘制与坐标换算，不改父视图命中范围） | **符合用户当下的要求**（原话「只要求像，暂时不做点击功能」）。要变成能点得另写转发，而本仓库 2026-10-10 刚把 `sendActions` 那类"替用户按"整块删掉 |
| ② | **长标题会从 ✓ 底下滚过去** | 标题行被我们右移了 88pt（宽 308 ⇒ 116…424），而 ✓ 落在 293…341；kumone 是把标题**截断**在 ♥ 左边 | **不动**：现有的 `applyTitleMask` 有个坐标口径问题（`room = limit − titleGap` 没算标题自己的 page-x），贸然接上去会把标题**淡错位置**。列为下一轮候选（§7） |
| ③ | **祖先若 `clipsToBounds`，✓ 可能被裁掉** | 它要从底部那一排往上搬 ≈486pt | 代码里**不自动清**别人的裁剪（清掉可能把别的被裁内容一起放出来），只**留一行日志**点名是谁：`WARNING: <类名> clips to bounds and does not contain the landing spot`。**反证**：标题行同样搬了 −421pt 而且照片 70 里好好的 ⇒ 大概率不裁 |

---

## 5. 本机自检（六条全绿）

```
python Tools/eevee-hookfinder/orion_hook_guard.py      # OK 327 文件
python Tools/eevee-hookfinder/swift_brace_check.py     # OK 327 文件
python Tools/eevee-hookfinder/swift_member_check.py    # OK 272 文件
python Tools/eevee-hookfinder/swift_string_check.py    # OK 276 文件 / 47884 行
python Tools/l10n_lint.py --locale en                  # exit 0
python Tools/l10n_lint.py --locale zh-CN               # 427 keys, 0 missing, 0 extra
```

⚠️ 六条都**不做类型检查**（`CGAffineTransform(a:b:c:d:tx:ty:)` 的逐参数、`@discardableResult` 的调用点、
`NSStringFromClass(type(of:))` 这类只能靠 CI）。

---

## 6. 下一轮：CI → 装机 → **日志 56 + 照片 71+**

### 6.1 操作顺序

1. 进播放器（记忆里应是"展开"）→ 看 header 右侧：**绿色 ✓ 应该在缩略图右边、和缩略图同一条中线**（≈317, 140）；
2. 底下那一排（进度条上方）**不该**再有那颗 ✓；
3. 反复进出 5 次 → ✓ 每次都跟着回来，**不许**留在 header 上、也不许两颗同时在；
4. **换一首没收藏的歌** → 那一颗应变成"加号"（而不是绿 ✓）—— 位置不变；
5. 收起歌词 → ✓ 必须**回到原位**（进度条上方）；再展开 → 又上去；
6. 顺便把上一轮那张单子一起拍了（进出转场不闪、三种说明文案、胶囊不在）。

### 6.2 预期日志（**逐字**）

```
[NPVLyrics] add-to button moved into the header — 48×48 from …,626,48,48 to 293,116,48,48
            (header row — kumone's heart spot) (visual only: taps still land at the old spot)
```

* 出现 `to 293,116`（≈ 317±24 / 140±24）⇒ **成了**；
* 出现 `WARNING: <类名> clips to bounds …` ⇒ **会被裁掉**（§4.4 ③）—— 把类名抄下来，下一轮只清那一层；
* 出现 `no visible add-to button in this page yet` ⇒ 走查起点没覆盖到它（把新的 `[NPVTree]` 里带
  `id=Components.UI.AddToButton` 的那几行发过来，按**父链**改起点）；
* ★ 顺便确认 `[Declutter] installed (… addToButton=OFF)` —— **关着**才有那颗 ✓ 可搬。

### 6.3 通过判据

| # | 判据 |
|---|---|
| ① | header 右侧出现绿 ✓，位置 ≈ (317, 140)，与缩略图同中线 |
| ② | 进度条上方**没有**第二颗 ✓（不是"多了一颗"） |
| ③ | 收起 / 退出后 ✓ **回到原位**（不留残影） |
| ④ | 日志里那行 `add-to button moved into the header — …` 出现**且没有 WARNING** |
| ⑤ | S1：放一首**没有时间轴**的歌，说明文案是**「这首歌的歌词没有时间轴」**（不再是「未找到歌词」） |
| ⑥ | 上一轮那张单子：`(anchors: navBottom=… progressTop=… bottomStackTop=…)` 三个都是**数字**、进出转场不闪、胶囊 `hide #N` |

---

## 7. 还没做的（按优先级）

| 序 | 做什么 | 前置 / 备注 |
|---|---|---|
| 1 | 按日志 56 收口 §6 那张单子（含上一轮的转场 / 锚点 / 文案 / 胶囊计数） | 日志 56 |
| 2 | **① 让 ✓ 真的能点**（现在只是视觉） | 要一套转发；用户当下说"不做点击" ⇒ **等他开口** |
| 3 | **② 标题与 ✓ 的让位**：把 `applyTitleMask` 的坐标口径修对（`room` 要减掉标题自己的 page-x），再把 ✓ 的左沿当成新的 limit | 一次只改一片、装一次机看一次 |
| 4 | 非当前歌词行**太暗**（照片 70 几乎看不清）——抬一点不透明度 | 一个常量，风险最低 |
| 5 | 可选：`⋯`（`Context menu`）也搬进 header（kumone 在 ≈357pt） | 用户没点，先问 |
| 6 | 可选：藏歌单名 `1` / 藏 shuffle+repeat（kumone 只有三键） | 功能取舍，先问 |
| 7 | **S1 的升级档**：无时间轴歌词**静态列出全文**（kumone 照片 41 那一档） | 要动渲染层（`LyricLine.time` 是必填） |
| 8 | 译文 / 罗马字 | 用户说「之后再说」 |
| 9 | 老账：音频密钥探针 / `NowPlayingPageOverlay` 重试 / 封面自持 / customize 种子 9.1.76→9.1.88 / 六条自检接进 CI | —— |

---

## 8. 未验证声明（**不要去掉这一段**）

* **本轮 2 个源码文件 + 2 个 l10n 文件全部没有编译过、没有装机过。**
* **最后一版真机数据仍是日志 55 + 照片 70**；`C:\dsh\ipa` 里**没有** `b9e250b` 之后的日志。
* ★ **"照片 70 = `b9e250b` 那一版"是据时间戳推的**（照片 20:21 > 提交 19:27，且几何/音量条对得上），
  **没有日志直接证明**（用户那一程的日志没导出）。若它其实是更早的构建，"几何已落地"这条就要重判。
* ★ **"✓ 搬进 header 之后看得见"没有验证过**：③ 的裁剪风险、② 的标题重叠都只能靠照片 71 判。
* ★ **"点击点不到"是据 UIKit hit-test 规则推的**（父视图边界），**没有在真机上试过**；
  万一它其实点得到（父视图很大 / 有人重写过 `point(inside:)`），那更好，但别当成已实现。
* `dump-9.1.88.txt` 是**符号 dump**（`[classes]` 17047 / `[rpc]` 316 / `[flags]` 543 / `[methods]` 1855 /
  `[selectors]` 12376，**没有字符串字面量**）⇒ **accessibility id 在里面查不到**
  （试过：`Components.UI.AddToButton` 0、`now-playing-minimize-button` 0、`Context menu` 0）
  —— id 只能靠真机 `[NPVTree]` 证明，**别指望这份 dump**。
* 本轮**没有派独立只读复核**（改动集中在一处新增 + 一处判据拆分，两个文件）；
  若照片 71 显示 ✓ 不见了 / 位置不对，**下一轮第一件事就是派复核**。
