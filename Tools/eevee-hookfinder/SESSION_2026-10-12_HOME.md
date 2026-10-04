# SESSION_2026-10-12_HOME — 页面第二站：**主页头部**（AM 的 Listen Now 那一档）

> 上一份入口是 [`SESSION_2026-10-12_LIBRARY.md`](SESSION_2026-10-12_LIBRARY.md)（音乐库三片 + 真机第二轮的三条纠正）。
> 这一份是用户拍板「做吧。要求：**依旧以网上的 AM 为准**，没搜到就自己做。**还是要求优雅**」之后的第一片：
> **主页（Home / Listen Now）的头部**。
>
> 三页的排序（这一轮定的）：**主页 → 搜索页 → 歌单页**（理由见 §1.2）。

---

## 0. 三十秒现状

| | |
|---|---|
| 提交 | 本片 **1 笔**（见 §5） |
| 要编译的 | `main` 最新提交；`Build IPA — patched`（`ipa_url` 留空，本机没有 `gh`） |
| 自检 | ✅ 六条全绿（orion / brace / member / string / l10n en / l10n zh-CN） |
| 开关 | **设置 → 扩展功能 → 主页 →「Apple Music 式主页」**，**默认开**（与音乐库那颗同一个观感档） |
| 一句话 | 主页头部：**大标题贴左（自己画，文字取标签栏那一颗 ⇒ 跟随语言）+ 头像靠右 + 收掉那排 pills 与顶部灰纱**；**这一版一行都没上过机器**，验收见 §3 |

---

## 1. 用户的要求，与 AM 的事实

### 1.1 原话

> 「做吧。要求：**依旧以网上的 AM 为准**，没搜到就自己做。**还是要求优雅**。」

**查到的 AM「现在就听 / Listen Now」**（[按公开 App + HIG 逐 token 拆的 iOS 规格页](https://code.jiangshu.ai/awesome-design-html/assets/ios/design.apple-music-ios.html)；
另有 [MacStories 关于 Apple Music 网页版改版](https://www.macstories.net/news/apple-music-for-web-debuts-new-beta-version-with-fresh-design-and-listen-now/)）：

| AM 的规矩 | 值 | 我们的落点 |
|---|---|---|
| **大标题** | `--large-title` = **32pt / 800**、紧字距、**贴左沿**（"Listen Now"） | 自己画一颗 `UILabel`：**32pt bold** + `UIFontMetrics(.largeTitle)` 跟随动态字体；文字取**标签栏那一颗**（我们机器上是「主页」）⇒ 跟随语言 |
| 标题行**右端一颗** | 账户头像 | 就是打开侧边栏的头像（`Components.UI.SideDrawerButton`）⇒ **靠右** |
| 顶部**没有压暗层** | —— | 收掉 `LiquidGlass.GradientView` |
| **没有内容筛选胶囊** | AM 是 "Stations for You 横排 → Recently Played 网格 → 推荐卡" | 收掉「全部 / 音乐 / 播客」那排 pills（`home-feed-{default,music,podcasts}-chip`） |
| 分区标题 | 18pt / 800（"Recently Played"） | ⏭ 下一片（`HomeHeadings`/`HomeSections`） |
| 卡片 | 圆角 6/8 连续、间距 8 的倍数 | ⏭ 下一片（`HomeCards`） |

### 1.2 三页的排序（这一轮定的，含成本依据）

| 顺序 | 页面 | pw 的规模 | 为什么 |
|---|---|---|---|
| **① 主页** | `Home.h` 32 / `HomeHeader.x` **148** / `HomeHeadings.x` 138 / `HomeCards.x` 80 / `HomeSections.x` 174 / `HomePerf.x` 175 | **≈747** | 头部是**最小的一份**，而且结构与音乐库**最像**（pw 自己写：音乐库头部就是"按 Home 和 Search 的做法"做的）⇒ 用最小代价把"**头部随滚动动**"这层新机制攻下来；一开 App 就看到 |
| ② 搜索页 | `SearchPage.x` 147 / `SearchCards.x` 205 / `SearchSections.x` 190（+ `Navbar/SearchField.x` 142） | ≈561 + 142 | 复用最多（搜索框/Cancel 胶囊我们做过**同一对 id**），但头部**多一层"滑 56pt + 淡出"**，而且 **Spotify 原生已经最像 AM**（照片 85）⇒ 视觉收益最小 |
| ③ 歌单页 | `PlaylistHeader.x` **556** / `PlaylistMenu.x` 347 / `PlaylistRows.x` 102 / `PlaylistField.x` 99 | ≈1147 + Kit | 唯一的"**新原语工程**"：全出血封面 + **取色场**（`Kit/SGRPalette` 293）+ 玻璃控件行（`Kit/SGActionRow` 430）+ `Kit/SGRFlow` 194。攒出来之后专辑页（818）、艺人页（606）都能复用 ⇒ 单独占一轮 |

**照片 85 的结论（用户问"这玩意什么时候做过"）**：搜索页我们**一行都没改过** —— 全仓库 grep 不到
`BrowsePageImpl` / `SearchToolBar` / `SearchHeaderFind` / `ScannablesButton`（pw 是 hook `Browse_BrowsePageImpl.BrowsePageViewController` 的）。
照片 85 里唯一属于我们的是**底部那条系统玻璃标签栏**。搜索页"看着像做过"是因为 **Spotify 自己在那一页的设计本来就最接近 AM**。

---

## 2. 这一片做了什么（`Appearance/HomeHeaderAppearance.x.swift`）

### 2.1 真机结构（日志 64 的 `[Tree] #1`，**我们自己的机器**，不是 pw 的树）

```
16.GradientView@0,0,414,98,id=LiquidGlass.GradientView          ← 灰纱（收掉）
16.HomeHeaderView@0,0,414,50                                    ← 头部
└ 17.UIStackView@0,8,414,34                                     ← 那一行
  ├ 18.AdaptiveFaceContainer@16,0,32,34
  │ └ 19.EncoreButton@0,0,32,34,id=Components.UI.SideDrawerButton     ← 头像（挪到右沿）
  └ 18.LeadingFadeMaskView@48,1,366,32
    └ 19.PillScrollView@0,0,366,32 → 22.PillView id=home-feed-{default,music,podcasts}-chip
```

### 2.2 四条"照 pw"的纪律（每条都有理由，别再自己发明）

1. **头像靠右 = 把那一行翻成 RTL**（`semanticContentAttribute = .forceRightToLeft`），**不是**自己算 transform：
   RTL 下 stack 会把**第一个 arranged subview 摆到右沿** ⇒ 每拍自动对，"正在收听的朋友"临时插进来改变宽度也不用管。
2. **pills 是 arranged subview ⇒ 只能 `alpha = 0`**，不能 `isHidden`、更不能摘掉
   —— 摘掉会让那个 stack 卡在 `updateConstraints`（pw 的 `SGRRestyle.h` 立的规矩，我们音乐库也吃过）。
3. **标题自己画**（一个不属于任何 stack 的 `UILabel`，`header.addSubview` 直接加），文字从**标签栏那一颗**读
   （`TabBar.Item.Home` 里第一个有字的 `UILabel`）⇒ 跟随 App 语言；**绝不去改 Spotify 自己那个 label**。
4. **所有事情做在页面的 `viewDidLayoutSubviews` 里**：主页的头**随滚动往上滑并淡出** ⇒
   音乐库那套"头部静止 + 0.5s 复查"在这里**不成立**；页面的布局回合在滑动每一步都会来（pw 同款挂点）。

### 2.3 与音乐库**刻意相反**的一处

音乐库的筛选 chips **保留**（那是排序用的，pw 删过又装回来 —— issue #20）；
主页那排 pills 是**内容筛选**、**AM 的 Listen Now 没有** ⇒ **收掉**，位置让给大标题。
要装回来：`HomeHeaderMetrics.vanishPills` 改 `false`（一行）。

### 2.4 还原（关开关 / 离开页面）

标题移除 + RTL 翻回 `.unspecified` + 被收掉的 alpha 各写回**它自己原来的**值（含灰纱）+ 交互与无障碍标志复位。

### 2.5 与「隐藏主页头部」那颗开关的关系

那颗（`DeclutterChrome.hideHomeHeader`）开着时整个 header 被隐掉 ⇒ **我们让位**（标题挂在一个看不见的容器上没意义），
日志里说一次：`[Home] standing down — the hide-home-header switch owns this header …`。

---

## 3. ★ 装机验收（这一片只看三条）

先点一次 `Actions → Build IPA — patched`（`ipa_url` 留空）。**它红了就先修编译，别的都别验。**

| # | 怎么做 | 应该看到 | 日志判据 |
|---|---|---|---|
| ① | 打开 App（主页） | **左上一个大标题「主页」**（32pt bold）；**右上头像**；那一排「全部/音乐/播客」**没了**；顶部灰纱没了 | `[Home] header the way Apple Music has it — title "主页" 32pt at the leading edge, avatar 350,0,32,34 at the trailing edge, pills vanished (alpha only, they stay in the stack), scrim off` |
| ② | **在主页上下滚动** | 标题与头像**跟着那一行一起**上滑/淡出（跟随 Spotify 自己的滚动，不卡住、不重叠） | 同一行不会重复刷（只在第一次报） |
| ③ | 设置 → 扩展功能 → 主页 → **关掉**「Apple Music 式主页」 | 标题消失、pills 回来、头像回左、灰纱回来 | —— |
| ④ | 反向：开着「隐藏主页头部」+ 开着这片 | 头部整体不可见（让位），日志一行 `standing down` | `[Home] standing down …` |

**下一份日志我要的就是这一行**：`[Home] header the way Apple Music has it — …`（若一行都没有，把整段发我）。

---

## 4. 未验证声明（**不要删这一段**）

* **本片 1 个源码文件（+ 开关/l10n）一行都没在真机上跑过。** 本机**没有 Swift 工具链**，
  "能编译"只有 CI / 用户能回答；六条自检**不做类型检查**（这一轮已经栽过三次：抽走的局部量、
  改名后的旧引用、UIKit 协议方法名）。
* **RTL 那一招是 pw 的实证，不是我们的**：他用它把 Home/Search 的头像推到右沿（我们真机结构与他的一致：
  `HomeHeaderView > UIStackView > [AdaptiveFaceContainer, LeadingFadeMaskView]`）。**万一头像没到右边**
  ⇒ 说明这一版的 stack 不是那条（或 RTL 被 Spotify 覆盖）⇒ 日志里 `avatar …` 那一段会给出真实 frame。
* **标题的文字来自标签栏那一颗**：读不到时退回本地化文案（`home_header_title`）。这条路径**没验过**
  （正常情况下标签栏一定在）。
* **"主页的头随滚动动"是 pw 的注释 + 我们的常识判断，没有我们自己的实测**：
  真机日志 64 只有 `#1` 那一份主页树（静止状态）。**若 ② 出现"标题不跟着滑/盖住内容"**，
  说明这一页的头其实不滑（或者滑的是别的层），那就把挂点从页面 VC 换到 header 自己（一行）。
* **pills 收掉之后，Spotify 的"内容筛选"能力就没了**（AM 没有这个能力）。用户若要它回来，
  改 `HomeHeaderMetrics.vanishPills = false`（一行）；**别**改成 `isHidden`/摘掉（见 §2.2 ②）。

---

## 5. 本片的提交

1. `feat(home)`：`Appearance/HomeHeaderAppearance.x.swift`（新 hook + 施加/还原 + 日志）
   + `UserDefaults.homeLargeTitle`（默认开、进 ownedKeys）
   + 设置页「主页」一节（en/zh-CN 各 4 条新文案）
   + `Tweak.x.swift` 里激活

---

## 6. 下一片（按 §1.2 的顺序）

| 顺序 | 内容 | pw 的对照 |
|---|---|---|
| **主页第二片** | **分区标题**（AM：18pt/800）+ **卡片圆角/间距**（AM：6/8 连续、间距 8 的倍数） | `Home/HomeHeadings.x` 138 + `Home/HomeCards.x` 80 + `Home/HomeSections.x` 174（"折起来的分区留下的空档"也在 `HomeSections`） |
| 主页第三片 | 性能与边缘：pw 的 `HomePerf.x` 175（主页卡片多，别让复查变慢）+ `Kit/SGREdgeEffect.x`（顶部"软边缘"替代灰纱） | —— |
| 然后 | **搜索页**（头部滑 56pt + 淡出 + 搜索框胶囊） | `Search/SearchPage.x` 147 |
| 最后 | **歌单页**（取色场 + 玻璃控件行） | `Playlist/PlaylistHeader.x` 556 + Kit |

---

## 8. ★★ CI 契约：**为什么 GitHub 上一串红叉**（2026-10-12 付的学费）

用户问「怎么我这边 GitHub 提交的全是有个红 x 的」。根因：**`Logic tests`（`.github/workflows/tests.yml`，
每次 push 都跑）会把几个源文件<u>单独</u>丢给 `swiftc`**，只加上它自己的测试 main：

```
swiftc Sources/EeveeSpotify/Premium/Helpers/ServerSidedFeaturePolicy.swift  Tests/ServerSidedFeaturePolicy/main.swift
swiftc Sources/EeveeSpotify/Privacy/TelemetryEndpointRules.swift            Tests/TelemetryClassification/main.swift
swiftc Sources/EeveeSpotify/Flags/FlagOverride.swift                        Tests/FlagOverrideStore/main.swift
swiftc Sources/EeveeSpotify/Shared/Models/Extensions/URL+Extension.swift    Tests/URLAdClassification/main.swift
swiftc Sources/EeveeSpotify/Shared/Helpers/DebugLogSanitizer.swift          Tests/DebugLogRedaction/main.swift
swiftc Sources/EeveeSpotify/Premium/Helpers/BrowsitaSectionStripper.swift   Tests/BrowsitaSectionStripper/main.swift
python3 Tests/ResolveConfigurationSnapshot/test.py
```

⇒ **这六个文件只许依赖 Foundation**。我为了 Premium 取证，往 `ServerSidedFeaturePolicy.swift` 里加了一个
`static func reportServerAccountTier(_ attributes: [String: AccountAttribute])` —— 它引用了 `AccountAttribute`
与 `writeDebugLog`，而这两个在独立编译里**都不存在** ⇒ 那一步编不过 ⇒ 从 `7a4fd5a` 起每个 push 都红。

**修法**：把那段取证搬到 `DynamicPremium+ModifyingFunctions.swift`（CI **不**单独编译它，而且它本来就
用着 `writeDebugLog`），`ServerSidedFeaturePolicy.swift` 的**代码**回到原样，并在文件尾留一段
"这是 CI 契约"的注释；那六个文件同上 —— **动它们之前先看 `tests.yml`**。

⚠️ 归类：这和"六条自检不做类型检查"是同一类 —— **本机看不出来的错，只有 CI / 真机能发现**。

---

## 9. 下一轮最容易踩的三件事

1. **先编译**：新加了一个 `ClassHook<UIViewController>` 与一次激活改动 —— 编译错最容易出在这一层。
   另外记住那条踩过三次的纪律：**hook 方法体里不许直接碰 `@MainActor` 的东西**（`viewIfLoaded` 也算！），
   要把引用带进 `onMainThreadSync` 闭包里再读。
2. **别把"音乐库的做法"直接搬过来**：那一页的头**静止**（0.5s 复查够用），主页的头**随滚动动**
   ⇒ 只能在**页面布局回合**里算。两页的挂点不同是**有意的**，不是不一致。
3. **判据只留一份**：头部那行的结构判断（stack / 头像 / pills）只在 `HomeHeaderAppearance` 里；
   几何（大标题字号、左沿、间距）只在 `HomeHeaderMetrics` 里。以后要调数值**只改那一处**。
