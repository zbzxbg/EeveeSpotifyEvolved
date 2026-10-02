# spoti.pw v0.21.1 → 本仓库：**听歌页（播放器）移植评估**

> 写于 2026-10-03 夜。用途：**排期 + 定第一刀**，不是实现说明。
>
> **依据来源（只此一处）**：`spoti.pw` 的 **`v0.21.1` tag** —— 该 tag 的 `LICENSE` 是
> **GNU GPL v3**，与本仓库的 GPL-3.0 兼容。隔离副本在
> `.spotify-ipa/spotipw-v0.21.1`（`git worktree`，detached `a08b38b`；该目录在 `.gitignore` 里）。
> **本次没有打开任何 `v0.22.0` 及以后的源码。**

---

## 0. 结论（先说）

| 问题 | 答案 |
|---|---|
| 能不能移植 | **能** —— GPL-3.0 对 GPL-3.0，法律上可复用（带署名 + 标注改动） |
| pw 的 AM 式播放页是"自绘壳"吗 | **不是**。`Player.h` 原话：**"保留 Spotify 自己的全屏播放器"**，只是"**折叠所有卡片 + 播放器不滚动** + 用 Kit 重排" |
| 这条路和本仓库合不合 | **合** —— 它走的是"改原生 + 藏 + 重排"，正是 `DeclutterChrome` / `LibraryAppearance` 那一套，**不是** 2026-10-02 被删的那种自绘壳 |
| hook 目标还在吗 | **14 个里 13 个在 9.1.88 上仍在**；唯一缺席 = morph 用的 `SPTBarOverlayPresentationTransition` |
| 最小子集多大 | **132 行 ObjC / 2 个文件 / 4 个外部 helper** ⇒ 换成 Swift 约 150 行，**1~2 轮** |
| 全量多大 | **9~15 轮**（封面场 + 头部 + 控件 + footer + 歌词进播放器）；morph 划掉 |
| 用户提的"盖一块布" | **不需要了** —— pw 用"折叠 + 钉住"达到"一屏不滚"，不碰触摸、不抢 z-order |

---

## 1. 许可边界（证据链，钉死）

| 证据 | 结果 |
|---|---|
| `git show v0.21.1:LICENSE` | **GNU GPL v3**（README 徽章同为 `License-GPL_v3`） |
| `git log v0.21.1..v0.22.0 -- LICENSE` | 只有一条：`f44abdf` "the mod is source available under the **PolyForm Strict** License 1.0.0" |
| `git tag --contains f44abdf` | **只有 `v0.22.0` / `v0.23.0-beta`** |
| 本仓库 `LICENSE` | GNU GPL v3 |

⇒ **边界干净**：`≤ v0.21.1` = GPL-3.0（可读、可复用）；`≥ v0.22.0` = PolyForm Strict
（明确禁止 *"making changes or new works based on the software"*）⇒ **一行都不碰**。

**复用时的三条义务**（GPL-3.0 §5）：

1. 保留版权与许可声明 → 在「开源许可」页写明 **spoti.pw by Vojtěch Škopek，v0.21.1，GPL-3.0**；
2. **标注"我们改过"与日期**（每个移植过来的文件头写一行来源 + 改动）；
3. 衍生作品继续 GPL-3.0（我们本来就是，无冲突）。

**纪律**：只从 `.spotify-ipa/spotipw-v0.21.1/` 读；**绝不**去翻工作区那份 `v0.22.0`。
`git worktree` 是为了**物理上避开** PolyForm 版文件，不是形式主义。

**代价**：v0.21.1 之后的修复全部拿不到（v0.22/v0.23 的改进都在 PolyForm 期）。

---

## 2. hook 目标对照（v0.21.1 → 9.1.88）

pw 的每个 `.x` 都以 `SGRequireClasses(@[…])` 自报目标，逐条对 `C:\dsh\ipa\dump-9.1.88.txt`：

| 文件 | 目标类 | 9.1.88 |
|---|---|---|
| `PlayerCards.x` | `_TtC12Element_List18CollectionViewCell` | ✅ |
| `PlayerScroll.x` | `_TtC21NowPlaying_ScrollImpl23NPVScrollViewController` | ✅（**我们已经有这个 hook**） |
| `PlayerField.x` | `NPVBackgroundViewController` / `AccessibleCollectionView` | ✅ / ✅ |
| `PlayerArtwork.x` | `CoverArtTiltView` / `LyricsContainerView` | ✅ / ✅ |
| `PlayerHeader.x` | `HeaderElementsUnit` | ✅ |
| `PlayerControls.x` | `PlaybackControlsElementsUnit` / `PlayButtonView` / `DurationElementUnit` | ✅ / ✅ / ✅ |
| `PlayerFooter.x` | `FooterElementsUnit` | ✅ |
| `PlayerLyrics.x` | `NowPlayingViewController` / `InformationElementsUnit` / `DurationElementUnit` / `FloatingElementsUnit` | ✅ / ✅ / ✅ / ✅ |
| `PlayerGestures.x` | `CoverArtTiltView` / `AccessibleCollectionView` | ✅ / ✅ |
| `PlayerMorph.x` | **`SPTBarOverlayPresentationTransition`** | ❌ **dump 里没有** |

⚠️ 两条诚实说明：

* 那份 dump **不是** Swift-only（里面有 **309 个 `SPT*` 裸名**），所以 morph 那个类的缺席**有信息量**，
  但仍不能 100% 排除"改名 / 被合并进别的类" ⇒ **morph 要单独取证，先划掉**。
* `SPTBarInteractivePresentationController`（`PlayerScroll.x` 注释里讲下拉关闭用的那个类）**同样没在 dump 里**。
  ⇒ 那条 dismiss 路径在 9.1.88 上**必须重新确认**（见 §4 第 1 条）。

---

## 3. 依赖面：71 个 SG/SGR 符号，但**分布极不均匀**

`Player` 目录 11 文件 / **1945 行**，一共引用 **71 个** pw 自家符号。按文件拆开看差别巨大：

| 子集 | 引用的外部 helper |
|---|---|
| **`PlayerCards.x` + `PlayerScroll.x`**（"一屏不滚"） | **只有 4 个**：`SGLog`、`SGRedesignedUI`、`SGRequireClasses`、`SGRFindByIdentifier` |
| 其余 9 个文件（封面场 / 头部 / 控件 / footer / 歌词 / morph） | 剩下 67 个：`SGRArtworkField`、`SGRGlyphButton`、`SGRGlyphView`、`SGRGlassInside`、`SGRMotion*`、`SGRShadowPlate`、`SGRSuppress`、`SGRAnimate`、`SGRKaraokeView`… |

其他相关规模（同一 tag）：

| 目录 | 文件 | 行数 |
|---|---|---|
| `Redesigned/Player` | 11 | **1945** |
| `Redesigned/Kit` | 33 | **3896** |
| `Core` | 18 | 653 |
| `Shared` | 80 | 13695 |

★ 顺带查到：**`SGRArtworkField` 不在 `Kit/`，而是定义在 `Redesigned/Album/AlbumField.x`**
（专辑页与播放页共用那块"封面场"）⇒ 要封面场就得连它一起评估，不是搬一个文件的事。

---

## 4. ★ 已经白捡到的两个答案（这两条最值钱）

### 4.1 **不能关滚动** —— 关掉之后播放器就划不掉了

`PlayerScroll.x` 的注释（真机 + 二进制偏移换来的）：

> 下拉关闭是挂在**列表自己的 pan recogniser** 上的：
> `-[SPTBarInteractivePresentationController scrollViewDidAppear:]` 取走列表的
> `panGestureRecognizer`，对它 `addDismissPanWithGestureRecognizer:`，并让自己的 dismiss recogniser
> 等它失败；那个 handler **只在列表处于（或高于）顶部时**才启动关闭
> （Spotify 9.1.78：`0x109814898` / `0x109814400`）。
> **把滚动关掉会把那个 recogniser 一起带走 ⇒ 播放器再也划不掉。**

它的解法（我们可直接照抄思路）：**把范围关掉，而不是把滚动关掉** ——
把 `contentInset.bottom` 设成"让列表最多只能滚到它自己的顶部"：

```objc
CGFloat safeArea = list.adjustedContentInset.bottom - list.contentInset.bottom;
CGFloat over     = list.contentSize.height - list.bounds.size.height;
CGFloat want     = -list.adjustedContentInset.top - over - safeArea;
if (want >= 0 || fabs(want - list.contentInset.bottom) < 0.5) return;
list.contentInset = (…bottom = want…);
```

⇒ 于是：上拉只拉伸回弹、下拉仍能到负偏移、**关闭手势完全不受影响**。
重算时机：**每次 layout + 每次 scroll + `willDisplayCell`**（后者还要补一枪 `dispatch_async`，
因为 cell 的高度是那之后才报的）。

**这一条正好回答了本次讨论里我标为"风险最集中"的触摸归属问题。**

### 4.2 它的 redesign **需要 iOS 26**，我们不需要

`AGENTS.md`：`SGRedesignAvailable()` 把 redesign 门在 iOS 26（Liquid Glass）；低于 26 开关直接变灰。
我们是 iOS 27 ✓ 无所谓 —— 但**我们的功能不该继承这个门槛**（我们只要"折叠 + 钉住"，
那两条跟 iOS 版本无关）。

另有一条它明写的坑，值得记：**给 `OverflowStackView` / Encore 栈里的视图设 `hidden` 会崩，要用 alpha**
（和本仓库"藏错一个 = 整页空白"是同族的教训）。

---

## 5. 建议的第一刀：最小可移植子集（"一屏不滚"）

**目标**：把听歌页变成 kumone 那种"一屏、不滚、底下没有卡片"。

**移植内容**（两个文件、132 行，依赖 4 个 helper）：`PlayerCards.x` + `PlayerScroll.x`。

**落到我们这边**：

* 改 `Sources/EeveeSpotify/Appearance/` 新增一个 `NowPlayingOneScreen.swift`（纯 Swift，不是 `.x.swift`），
  挂在**已经存在**的 `NPVScrollViewControllerHook`（`CustomLyrics+AllTracksLyrics.x.swift:392`）上：
  * 卡片折叠 = 一个 `Element_List.CollectionViewCell` 的 hook
    （`preferredLayoutAttributesFittingAttributes:` 返回 `height = 0`，判据是内容视图类名含 `NowPlaying_ScrollAPI`）；
  * 钉住 = 在 `NPVScrollViewController` 上找 `accessibilityIdentifier ==
    "scrolling_npv_collection_view_accessibility_identifier"` 的 `UIScrollView`，按上面的公式设 `contentInset.bottom`。
  * 那个 id **我们已经在自己日志 38 的树里见过**（`scrolling_npv_collection_view_accessibility_identifier`）⇒ 不用重新取证。
* `SGLog` → 我们的 `writeDebugLog`；`SGRFindByIdentifier` → 我们自己的锚点走查；另外两个不需要。
* 开关沿用「扩展功能 → 听歌页」，默认**关**；关掉 = 不施加任何改动（我们本来就只改返回值和 inset ⇒ 天然可还原）。

**⚠️ 必须先验的一件事**：`viewDidLayoutSubviews` 是**可选方法**，本仓库纪律是"类没覆写就不能挂"。
pw 在 9.1.78 上挂了；**9.1.88 上是否仍被 `NPVScrollViewController` 覆写，要另取证**
（dump 只有类名清单，没有方法表）。兜底方案：只用 `viewWillAppear`/`viewDidAppear` + `scrollViewDidScroll` +
`collectionView:willDisplayCell:` 三个时机（后两个是 delegate 方法，pw 也挂了）。

**验收判据（一次装机）**：

```
[OneScreen] collapsed card root <类名>（第 N 种）
[OneScreen] the list pinned to its top, Npt of cards closed off
[OneScreen] 下拉关闭仍可用（手动划一下）
截图：播放页一屏、下面没有卡片；向下拉仍能关掉播放器
```

---

## 6. 排除 / 暂缓

| 项 | 理由 |
|---|---|
| **morph 转场**（`PlayerMorph.x`） | 唯一目标类 `SPTBarOverlayPresentationTransition` 在 9.1.88 dump 里找不到；且本仓库文档早把 morph 列为"高、建议划掉" |
| **`SPTBarInteractivePresentationController` 那条路径的改写** | 同上，先不动；我们的 contentInset 方案不依赖它 |
| 整块 Kit 移植 | 33 文件 / 3896 行，且与 pw 的 Core/Settings 层交织；只在需要某个具体件时按需取（如封面场） |
| 继承 pw 的 iOS 26 门槛 / Liquid Glass 体系 | 我们的功能不需要 |

---

## 7. 下一步

1. **同步改仓库文档**（红线变了）：
   * 本目录 `SPOTIPW_GAP.md` §0：把"只看思路，代码全部自己写"改成
     **"≤v0.21.1 = GPL-3.0，可读可复用（需署名 + 标注改动）；≥v0.22.0 一行都不碰"**；
   * `README.md` 的「Reverse-engineered data, and takedowns」段 + 「开源许可」页补一条署名。
2. **第一刀**：按 §5 落"一屏不滚"（1~2 轮），**它独立于取色底那条线**，可以并行。
3. 之后按 §3 的依赖面**按需**取下一个件（建议顺序：封面场 → 头部 → 控件/footer → 歌词进播放器）。

---

## 8. ★ 第一刀已落地（2026-10-03 夜）

**交付**（全部是我们自己的 Swift，不是搬来的 ObjC）：

| 文件 | 作用 |
|---|---|
| `Sources/EeveeSpotify/Appearance/NowPlayingOneScreen.swift` | 找列表（按 `accessibilityIdentifier`）+ **钉住**（`contentInset.bottom` 公式）+ 写回 |
| `Sources/EeveeSpotify/Appearance/NowPlayingOneScreenCards.x.swift` | 卡片折叠：`Element_List.CollectionViewCell.preferredLayoutAttributesFittingAttributes:` 高度报 0 |
| `CustomLyrics+AllTracksLyrics.x.swift` | 进页面时 `apply`（蹭既有的 `NPVScrollViewControllerHook` 两个 appear 点） |
| `DeclutterChrome.x.swift` | 重算节拍 `reconcile`（蹭既有 0.3s 复查，不新开定时器） |
| `EeveeExtrasSettingsView.swift` + en/zh-CN 文案 | 开关「一屏（卡片折起来，不可滚动）」 |

**与 pw 的两处刻意不同**：

1. **重算时机**：pw 挂 `viewDidLayoutSubviews` + `willDisplayCell` + `scrollViewDidScroll`；
   我们**不挂可选方法**（本仓库纪律：类没覆写就会 `Failed to hook method`），改蹭既有的 0.3s 节拍
   ⇒ 代价是最坏 0.3s 的窗口里能多滑一点点，下一拍立刻被拉回。
2. **卡片判据加了一条不依赖类名的硬判据**：cell 是否挂在"按 `accessibilityIdentifier` 认出来的
   那张列表"下面。为什么加：9.1.88 上 `NSStringFromClass` 给的是**混淆名**，而我们在真机树里只证到
   **反混淆**形态（`ElementContentView<ItemIdentifier, AnyBaseElement<NowPlayingScrollData, NoData>>`）——
   模块名（pw 靠的 `NowPlaying_ScrollAPI`）会不会漂**没有证据**，所以两个串都认 + 列表归属兜底。

### ★ 产品级后果（写在这里，别当成 bug）

**折掉所有卡片 = 连歌词卡一起折掉**；而一旦钉住，**保留下来的卡片也永远滚不到**
（这正是"一屏"的含义）⇒ "只折一部分"**不是**稳定中间态。

* 所以默认值 = **关**；
* 想改成"默认开"的前置条件 = **先把歌词搬进播放器**（pw 的 `PlayerLyrics.x`，估 3~5 轮）；
* 验收时如果用户想要歌词，而卡片没了 —— 那就是这条，不是坏了。

### 验收（开关：扩展功能 → 听歌页 →「一屏（卡片折起来，不可滚动）」）

```
[OneScreen] collapsed card root <类名>（第 N 种）
[OneScreen] 列表已钉在顶部 — 折掉 Npt 的卡片范围（上拉只回弹，下拉关闭不受影响）
[OneScreen] 列表 inset 已写回原值 — 滚动范围还原（reason=switch off）
```

**通过判据**：

1. 播放页变成**一屏**、下面没有卡片、**滚不动**；
2. ★ **下拉仍然能关掉播放器**（这是这一刀最关键的验收 —— pw 的注释说"关滚动会把 dismiss
   recogniser 一起带走"，我们走的是 contentInset 那条路）；
3. 关掉开关 → 滚动范围**完全还原**。

**若一条 `[OneScreen]` 都没有**：折叠 hook 没被调用（说明那条列表**不走
`preferredLayoutAttributesFittingAttributes`**）⇒ 下一个判据要换成 `willDisplayCell` 那条路。

