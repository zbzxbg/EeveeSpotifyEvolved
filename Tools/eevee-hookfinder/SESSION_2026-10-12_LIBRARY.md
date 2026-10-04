# SESSION_2026-10-12_LIBRARY — 开始做页面：音乐库三片（照 Apple Music 的那一档观感）

> 上一份入口是 [`SESSION_2026-10-12_TABBAR_AB.md`](SESSION_2026-10-12_TABBAR_AB.md)（标签栏第二片 + Premium 那条 A/B 的落点）。
> 这一份是 **§7「仍然挂着」里第 12 条（页面计划）开工的那一轮**：用户拍板「接下来是做页面了，能不能直接做」，
> 并在动工中途补了一句「**去网上搜搜 AM 的音乐库长什么样**（我没 AM），或者自己做，**看着有 AM 的优雅感**」。
>
> 现场材料：`C:\dsh\else\40/41.jpg`（kumone 听歌页，参照）、`C:\dsh\ipa\dump-9.1.88.txt`（类名核对），
> 以及 pw 的三份实现（下面 §2 逐条注明）。

---

## 0. 三十秒现状

| | |
|---|---|
| 提交 | 本轮的 **3 笔代码**（`4e9bce0` 头部 / `dbd56bc` 行与卡片 / `dc16dd4` 库内搜索 + l10n） |
| 要编译的 | `main` 最新提交；`Build IPA — patched`（`ipa_url` 留空）——**上一轮已经证明六条自检抓不到类型错误**（编译器抓回两条），所以这一轮同样请先编译 |
| 自检 | ✅ 六条全绿（orion / brace / member / string / l10n en / l10n zh-CN） |
| 开关 | **一个**：设置 → 扩展功能 → 音乐库那一段（`libraryLargeTitle`，默认开）。**三片共用它**，关掉各自精确还原 |
| 一句话 | 音乐库的**头部 / 行与卡片 / 库内搜索**三片都改完了；**一行都没上过机器**，验收见 §4 |

---

## 1. 用户的要求，与 Apple Music 的事实

用户原话（两句，第二句是中途补的）：

> 「接下来是做页面了。能不能直接做」
> 「你等会。如果可以的话，可以去网上搜搜 **AM 的音乐库长什么样**（因为我没 AM）。或者自己做，**看着有 AM 的优雅感**。」

### 1.1 AM 音乐库的真身（查到的，不是记忆）

来源：[一份按公开 App + HIG 逐 token 拆解的 iOS 设计规格](https://code.jiangshu.ai/awesome-design-html/assets/ios/design.apple-music-ios.html)
（另有 [Pocket-lint 关于 iOS 26.4 专辑/播放列表改版的报道](https://www.pocket-lint.com/apple-music-playlists-and-albums-get-a-redesign-in-ios-26-4-beta/)）。
**下面这些数是"AM 的规矩"，不是我们的取值** —— 我们只在 Spotify 自己的视图上落到等价档：

| AM 的规矩 | AM 的值 | 我们的落点 |
|---|---|---|
| 大标题 | **32pt / 800**、tracking −0.8、**贴左沿** | 标题字号拉到大标题档（沿用 §①已验过的 1.25× 倍率，约 30pt）；**贴左 = L1 ③** |
| 标题行右端一颗 | Edit（iOS 26 是**头像**） | 头像 + search/plus **一起贴右沿打包，头像最右** |
| 筛选 chips | 标题下面**一整行 pill** | Spotify 自己的 chips **原样保留**（它已经画在系统玻璃上） |
| 区块标题 | 18pt / 800 | **本轮没动**（Spotify 的 group label 是 element 量好的盒子，放大会被裁 —— 见 §5） |
| 封面圆角 | 小图 **6pt**、大图 8pt，都是**连续圆角** | 行缩略图 6、网格卡片 8，`cornerCurve = .continuous`；**艺人那张圆图放过** |
| 列表行 | 15pt/400 + 11pt/500 灰元信息 | Spotify 的行本来就是这个层次 ⇒ **不动**（行的字号是量好的盒子） |
| 分隔线 | 系统分隔线，**从文字左沿起** | 发丝线：1/scale 厚、white @ 12%（pw 的 `SGRHairline`）、起点 = 封面右沿 + 12pt |
| 侧边距 | 18pt（pw 用 16） | 跟 pw：**16pt**（`SGRSideMargin`） |

### 1.2 为什么不照 pw 那样"自己画标题"

pw 的 `LibraryHeader.x` 是 **vanish 掉 Spotify 的标题 + 自己画一个 `UILabel`**（因为它要连字号/字重一起自己负责，
还要把文字从原生 label 里读出来以跟随语言）。我们的 §① 已经有一条**真机验过、没被 binder 写回**的
"只改原生 label 字号"的路 ⇒ 这一轮**保留原生 label，只挪位置**（transform），少一份要自己维护的东西。
要哪天发现"改字号"这条路被写回（日志里那条计数就是判据），再走 pw 那条自绘路 —— §①的注释里已经写着这个决策点。

---

## 2. 三片各做了什么（每一条都注明 pw 的对照）

### 2.1 L1 头部（`Appearance/LibraryAppearance.x.swift`，提交 `4e9bce0`）

真机结构（pw 的树 + 我们的 dump 对得上）：

```
YourLibraryHeaderView
├ LiquidGlass.GradientView                        ← 顶部灰纱（④ 收掉）
├ AutoLayoutStackView，48pt 高的一行
│  ├ AdaptiveFaceContainer  id=Components.UI.SideDrawerButton   ← 头像（挪到最右）
│  ├ YourLibraryHeader.title                                    ← 标题（挪到左沿 x=16）
│  ├ (spacer)
│  ├ YourLibraryHeader.recents （这个账号上隐藏）
│  ├ YourLibraryHeader.search
│  └ YourLibraryHeader.plus
└ YourLibraryHeaderContentFiltersView             ← 筛选 chips：**原样保留，一个字不动**
```

| 做什么 | 怎么做 | 为什么这么做 |
|---|---|---|
| 标题贴左、头像/按钮贴右 | **transform 位移**，不碰 frame、不碰约束 | Auto Layout 每拍只写 `center`/`bounds`、**不碰 transform** ⇒ 位移活得过它那一拍（pw 的原话）。位移从 **`center`** 算（不是 `frame` —— transform 一上 frame 就未定义）⇒ **幂等** |
| 右侧打包次序 | `[recents, search, plus] + 头像`，**倒着**从右沿（8pt 内边距）往左摆 ⇒ 头像最右 | 与 pw 的 Home/Library 完全一致 |
| **绝不摘 arranged subview** | 只有位移，没有移除、没有 hidden | pw 的注释：把 Spotify 的 arranged subview 摘掉会让那个 stack **卡在 `updateConstraints` 里** |
| 顶部灰纱 | 收掉 alpha；**只在页面/头部的布局回合写**（`apply`），**不进 0.5s 节拍**，值已是 0 就一个字节不写；原 alpha 记在**那层视图自己身上** | 上一版被删掉的原因就是"每 0.5s 强行归零 = 和滚动动画对着干"（§②的账）。现在与 pw 等价（他也是只在头部那一拍清一次） |
| 复查节拍 | 沿用既有的 0.5s：**字号 + 位移**每拍都核，**灰纱不核** | 位移可能被 stack 自己的回合冲掉（pw 专门 watch 那一行）；灰纱不能高频写 |

### 2.2 L2 行与卡片（`Appearance/LibraryRowsAppearance.x.swift`，提交 `dbd56bc`）

照 pw 的 `LibraryRows.x`，**同一个 hook 目标、同一套 id**（9.1.88 的 IPA 里逐字在）：
`YourLibrary_CommonKit.YourLibrarySwipeableCollectionViewCellContainer`。

| 做什么 | 怎么做 | 为什么 |
|---|---|---|
| 封面连续圆角 | 行缩略图（`Artwork.Row.Library`，64pt）→ **6**；网格卡片（`Components.UI.CardLibrary.Artwork`）→ **8**；`cornerCurve = .continuous` + `masksToBounds` | Spotify 给的是直角味的 4pt；AM 是 6/8 连续圆角 |
| **艺人头像放过** | `cornerRadius >= side/2 − 0.5` 就**一个字节都不改** | pw 的判据：艺人画像是圆的（真机 r=32） |
| 行间发丝线 | **`CALayer`**（不是 view），1/scale 厚、white @ 12%、**从文字左沿**（封面右沿 + 12）到单元右沿；`CATransaction.setDisableActions(true)` | 单元复用极快，加 view 会看到线"滑"进来；卡片不要线（形状判据：宽 > 300 且高 ≤ 120） |
| 复用不串 | 原半径/原圆角曲线记在**封面那张图自己身上**（关联对象），不记在单元上 | 单元会在行 ↔ 卡片之间复用 |
| 还原 | 同一个 hook：开关关掉就逐颗写回 | 仓库纪律 |
| 静默失效防线 | 两个 id 一个都没找到 ⇒ **自报一行**（只报一次） | 否则这一片是"静默不生效"，下一个人还得重猜 |

### 2.3 L3 库内搜索（`Appearance/LibrarySearchAppearance.x.swift`，提交 `dc16dd4`）

照 pw 的 `LibrarySearch.x`。**只改形状，不画玻璃** —— pw 的原文：那两个形状（
`Components.Header.UI.Toolbar.SearchField` 320×32、`Components.Header.UI.Toolbar.ButtonContainer` 58×32）
**自己里面已经画了** `Reprise_LiquidGlassKit` 的搜索栏玻璃，"缺的只是形状" ⇒ 圆角改成**半高（胶囊）+ 连续**。
灰纱走的是**库里头部那一份判据**（`LibraryAppearance.clearTopEdgeScrim`），不写第二份。
头部或形状找不到时同样**自报一行**。

---

## 3. 开关与文案

三片共用**同一个开关**（设置 → 扩展功能 → 音乐库那一段，`libraryLargeTitle`，默认开），
中英文案已改成"三片都说到了"（提交 `dc16dd4`）。⚠️ **中文那句是初稿，用户照例自己改**。

---

## 4. ★ 装机验收（一条一张照片）

先点一次 `Actions → Build IPA — patched`（`ipa_url` 留空）。**它红了就先修编译，别的都别验。**

| # | 怎么做 | 应该看到 | 日志判据 |
|---|---|---|---|
| ① | 打开音乐库 | **标题贴左沿、比原来大**；**右上角是头像**，头像**左边**依次是搜索、加号；筛选 chips 还在原位 | `[Library] header restyled — the title sits at the leading edge, N control(s) packed at the trailing edge (rightmost: AdaptiveFaceContainer)` |
| ② | 同时看列表顶部 | 原来那层**灰纱没了**（列表滚上来的内容不再被它压暗） | `[Library] the top edge scrim is off — …GradientView …` |
| ③ | 看列表里的行 | 封面圆角**比原来柔和**（连续圆角）；**艺人那一行仍是正圆**；行与行之间一条**极细**的线，且**从文字左边起、不顶到左屏沿** | `[Library] rows styled — the first thumbnail is 64pt at r=6.0 (continuous); the hairline starts at the text's leading edge` |
| ④ | 切到**网格**视图（右上那颗切换） | 卡片封面圆角变柔和、**卡片下面没有线** | 同上那一行只报一次；网格不额外报 |
| ⑤ | 点头部那颗放大镜 → 库内搜索页 | **搜索框与 Cancel 都是胶囊**；这一页顶部也没有灰纱 | `[Library] the in-library search field and Cancel are capsules now (2 shape(s); …)` |
| ⑥ | 把这颗开关**关掉** | 标题字号/位置、头像位置、灰纱、封面圆角、搜索框形状**全部还原**（切页再回来也一样） | `[Library] …` 那一批不再出现（下一拍还原） |
| ⑦ | **顺手看反面**（出现就把整行发我） | —— | `⚠️ no row artwork id on a …x… cell` / `⚠️ the in-library search header has neither …` / `⚠️ the in-library search page has no YourLibrarySearchHeaderView` |

**下一份日志我要的就是这几行**（`[Library]` 开头那四条 + 任何 `⚠️`）。

---

## 5. 还没做的（下一片）

| # | 事 | 说明 |
|---|---|---|
| 1 | **区块标题**（AM：18pt/800） | Spotify 的 group label（`YourLibraryGroupLabelParser` 那条线）是 element 量好的盒子，**放大会被裁** ⇒ 要先拿到真机 frame 再决定"加粗不动字号"还是别碰 |
| 2 | **歌单页**（pw 5 文件 1166 行：`PlaylistHeader` 575 / `PlaylistMenu` 347 / `PlaylistRows` 102 / `PlaylistField` 99） | 全出血封面 + 取色场 + 玻璃控件行；**要吃掉上面这些原语**，所以排在音乐库之后（`SESSION_2026-10-12_NIGHT.md` §3.1 的排序仍然有效） |
| 3 | **音乐库的"最近添加/网格"头部**（AM 有 2 列 Recently Added） | Spotify 的网格已经是同一套卡片（L2 覆盖了圆角），要不要再动布局**等 ④ 的照片** |
| 4 | **`libraryLargeTitle` 这个键名/文案** | 现在它管三片，键名还叫 `libraryLargeTitle`（改名要动 UserDefaults 迁移，**不值当**；文案已经改对了） |

---

## 6. 未验证声明（**不要删这一段**）

* **本轮 3 个源码文件 + 2 个 l10n 文件，一行都没在真机上跑过。** 本机**没有 Swift 工具链**，
  "能编译"只有 CI / 用户能回答；六条自检**不做类型检查**（上一轮的两条编译错误就是这么漏过去的）。
* **所有 id / 类名都是 pw 的树 + 9.1.88 的类名 dump 对出来的**，不是我们真机的树：
  `Artwork.Row.Library` / `Components.UI.CardLibrary.Artwork` / `Components.Header.UI.Toolbar.SearchField` /
  `…ButtonContainer` 这几个 id **没有一份我们自己的 dump 作证** ⇒ 所以每一片都写了"找不到就自报一行"，
  §4 ⑦ 就是它们的判据。**若 ①③⑤ 有哪一条没生效，先看那一行 ⚠️。**
* **位移的时机是推的**：pw 专门 watch 了那一行（stack 自己的回合会把控件摆回去），我们只靠 0.5s 节拍兜 ⇒
  可能出现"某一瞬间标题/头像回到原位，0.5s 内被纠回来"。若肉眼能看到跳变，下一版就照 pw 补一个"监听那一行"。
* **灰纱的频率已经钉死**（只在布局回合写），但**"它会不会被 Spotify 在滚动里一直重写"没有实测**：
  若 ② 出现闪烁，就把 §④ 那一段从 `apply` 里摘掉（一行回滚），恢复成"只改字号 + 布局"。
* **艺人头像"放过"的判据**是 `cornerRadius >= side/2 − 0.5`：若某一行是**正方形艺人图**（AM/Spotify 都有这种），
  它会拿到 6pt 而不是圆 —— 这与 pw 的行为一致，**不是 bug**。
* **发丝线的颜色**取 pw 的 `SGRHairline`（white @ 12%）；AM 的浅色下是 `#D1D1D6`。
  Spotify 永远是深色，所以只取了深色那一档；**若觉得太淡/太亮，改 `LibraryRowsMetrics.hairlineAlpha` 一个数**。

---

## 7. 下一轮最容易踩的三件事

1. **先编译再验收**：这一轮又加了两个 `.x.swift` hook（两个新的 `ClassHook`）与一次 group 激活改动，
   编译错在这一层最容易出现（上一轮就是）：**先看 CI 红不红**。
2. **`LibraryAppearance.restore()` 是所有还原的总闸**：新加的两片（行 / 搜索）**各有自己的 restore**，
   分别由各自的 hook 在"开关关掉"那一拍触发；而头部那一片在 `reconcile` 的 `!isEnabled` 分支里。
   **以后再往这一批加东西，先想清楚"关掉时谁来还原我"**。
3. **判据只留一份**：灰纱只有 `LibraryAppearance.clearTopEdgeScrim(in:)` 一份；胶囊几何只有
   `TabBarGlassPlate.capsuleRect` 一份；行的半径/间距只有 `LibraryRowsMetrics` 一份。
   要调数值**只改那一处**。
