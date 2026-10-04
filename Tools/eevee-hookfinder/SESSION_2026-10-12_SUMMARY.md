# 2026-10-12 会话总结（音乐库收尾 → 标签栏 → 主页 → Premium → CI）

> 用户原话："现在上下文长了。你写个总结性文档好了。我记得仓库内不是有 eevee-hookfinder 这个文件夹吗，
> 你把你这个会话干了什么，接下来做什么，什么要求写进去。"
>
> 本文就是那一份。**先看 §2（现在到哪了）**，那里是"到底修好没有"的诚实答案；
> 要动手就看 §3（接下来做什么）与 §4（要求与纪律）。

---

## 0. 三十秒现状

| | 结论 |
|---|---|
| **真机证明修好的** | ① 标签栏玻璃尺寸（`360×60`，量一次不漂）；② 点标签气泡**立刻**动（不再等 0.5s 节拍） |
| **改了但没验**（用户测的四份日志都是旧版） | 原图标隐藏、按住划动+学 VC、主页标题双挂点、Premium 新种子/回放优先级/不造键/反登出、CI 红叉 |
| **没修好** | **灰歌**。本质是"服务器按 free 账号发流"，我们只改了客户端认知；本轮只把"过度播种"这个有出处的假设改掉，**未验证** |
| 本会话提交 | `dc16dd4 … 3a188ac`（§7 全列） |

---

## 1. 这一会话干了什么

### 1.1 音乐库（收尾 + 一次"试了又退"）

| 提交 | 做了什么 |
|---|---|
| `dbd56bc`、`dc16dd4`、`6216c96` | 行/卡片改为 Apple 连续圆角 6/8pt + 发丝线；库内搜索框与 Cancel 改胶囊；交接文档 |
| `c724524` | 删掉重构后残留的 `didReportScrim`（编译错） |
| `1ace166` | 搜索胶囊：**"找到了"和"排好版了"分开计数**（旧版在布局前就报 ⚠️ 假警报） |
| `0bf5f12` | 快速滚动条收掉（`QuickScrollView` 从父视图摘掉、记住原位可还原）；封面按 id（`Components.UI.CardLibrary.Artwork`）或几何兜底找；**占位卡不算警告** |
| `e4a7c57` | 文档：日志 64 到底定了什么 |
| `2c27de3` → `1eaa1fd` | **顶部毛玻璃**：先按公开 API（`UIScrollView.topEdgeEffect.isHidden`）关掉并推上去，用户说"算了先回退"⇒ **已回退**。结论留在 `SESSION_2026-10-12_LIBRARY.md` §9：那层是 `BackdropView` + `ScrollEdgeEffectView`，要做就是那两行；**不要**去涂它的 alpha（它随滚动自己淡入淡出，灰纱那笔账） |

### 1.2 标签栏系统玻璃（本会话四轮，全在这一条线上）

| 提交 | 一轮的主题 | 关键判据 |
|---|---|---|
| `a2e5a80` | ① 尺寸按"UIKit 真画出来的玻璃"自校准；② 点击转发（含容器公开 API） | 日志 64：`host 27,-3,360,60` vs `drawn 318×39` |
| `416e60e` | 编译错：`target.height / 2`；`tabBar(_:didSelect:)` 改短名 | —— |
| `f688621` | **"只能动一次 + 没有按键效果"** 与 **"玻璃忽大忽小"**：① 只在"有可预判的转发路"时才接管触摸，失败时**栏与宿主一起关**且**交还过就不再收回**；② 内边距**只认栏自己那块 `UITabBarPlatterView`**（不能按面积挑 —— `_UITabBarItemPlatterView` 是选中气泡，尺寸随选中态变）且**量一次就冻结** | 日志 65/66/67/68：`glass insets measured once — left 21 right 21 top 0 bottom 21`、`host 6,-3,402,81`、`drawn …=27,-3,360,60` |
| `f624350` | 转发失败时**把 pw 那条链逐环打出来**（`_targets` 在不在 / 几对 / 每对 `target:action`）——"照抄 pw 为什么不通"的唯一判据 | —— |
| `c147d8a` | ① **图标**：这一版图标不是 `UIImageView` 而是 `SPTEncoreIconView`（Encore 自己画）⇒ 照 pw 的 `renderLayer` **把它 layer 渲染成图**（按视图缓存、必须在藏原图标之前做）；② **点一下**（不抢触摸的手势）⇒ 气泡立刻动；③ **按住划**：装 pan，划到哪格切哪格 | 日志 66–69：`icon taken from SPTEncoreIconView at 0,0,24,24`、`icons ["Y","Y","Y","Y"]`、**日志 69 已出现** `bubble mirrored straight away — #0 (a tap on Spotify's own bar; no waiting for the 0.5s tick)` |
| `28a1308` | ① **藏原图标**（以前只藏 `UIImageView` ⇒ 一个都没藏住，用户："底部 spotify 自带的那一层按钮还在"）；② **拖动真的能换页**：容器**不是** `UITabBarController`、`children` 只有 1 个，但它**响应 `setSelectedViewController:`** ⇒ 挂钩子**学"第几颗 ↔ 哪个 VC"**（`TabBarContainerSelectionHook`），划动用它提交；学不到就把气泡**拨回真实那一颗**并报一次；③ 主页标题**双挂点** | 日志 67/68/69：`drag stays off — container TabBarContainerImpl, is a UITabBarController: false, children: 1, answers setSelectedViewController: true` |
| `456d57b` | 点标签"没反应"的三种可能分开报：`tap recogniser installed … Waiting for the first tap` / `first tap seen …` / `⚠️ … no tab index could be worked out` | —— |

### 1.3 主页头部（AM「Listen Now」那一套）

| 提交 | 做了什么 |
|---|---|
| `d0d8f22`、`92b7adf` | 自绘 32pt 粗体大标题（贴左）+ RTL 翻转把头像推到右沿 + pills 只 `alpha = 0` 收掉 + 灰纱关掉 + 设置项与 l10n + 交接文档 |
| `d1d3f2b` | 编译错两条：`findView` 返回 `UIView` ⇒ 要 `as? UIStackView`；`userInteractionEnabled` ⇒ `isUserInteractionEnabled` |
| `c147d8a` | 标题**垂直改以头像中线为准**（用户："主页两个字会偏上"）；**并修好那条丢掉的日志行**（旧版嵌了转义双引号 + `header.window != nil` 条件 ⇒ 日志 65 里一条 `[Home] header …` 都没有，而树里 `LeadingFadeMaskView@0,1,…,alpha=0.00` 证明代码其实跑了） |
| `28a1308` | **再挂一个"头部自己的每一拍"**（`HomeHeaderLayoutHook`）—— pw 的教训原话：那一行也要盯着，它自己的每一拍都把控件重新摆一遍。真机日志 67 里我们那一刻是**对齐的**（`title frame 16,6,342,39` ⇒ 中心 25.5；`avatar 366,8,32,34` ⇒ 中心 25）⇒ 错位发生在"只有那一行自己在动"的回合 |

### 1.4 Premium（这一轮的主战场）

| 提交 | 做了什么 | 依据 |
|---|---|---|
| `3657ad8` | 撤掉"服务端说 premium 就不下伪装"的闸门（前提被用户否掉），只留**取证**：`[Premium] the account state on the wire: type=… catalogue=… player-license=…` | 日志 67/68/69 已有该行 |
| `b936fb4` | **9.1.88 新种子**：用户抓的 `[CustomizeBody]`（107272 字节）→ `ResolveConfiguration` **100278 字节 / 1096 条**（旧的 99439/1089）；`BundledConfigurationPolicy` ≥9.1.88 用它；CI 两条契约同步（`Tests/BundledConfigurationPolicy/main.swift` 补 9.1.87/9.1.88/9.2.0；`Tests/ResolveConfigurationSnapshot/test.py` 补 sha256+条数） | 日志 68/69：`seed ready resolveconfiguration_9_1_76.bnk` + 4 个 `[Flags] replacement … 0 match(es)`（含 `enable_has_lyrics_check_bypass`）⇒ **旧快照里根本没有这些开关** |
| `39704c4` | ① **回放优先级**：同版本的**落盘真 body 优先**，种子只兜底；**种子不再落盘**；回放行写明用的是哪一份。② **`the real body arrived — X.Xs after launch`**（黑屏窗口变成可测量的数字）。③ **暂停 ≠ 播不动**：读 `MPNowPlayingInfoCenter` 的 `rate`，`rate=0` 只报一次"这一段是暂停"、不计入"不可播放" | 日志 69：`customize 304 -> replaying the seed, 101415 bytes`（101415 正是种子字节数 ⇒ 磁盘上那份更好的 body **一次都没被用过**）；用户被问"是不是你按的暂停"答"**忘了**" |
| `3eb4f0d` | **停掉"过度播种"** + 抄来**反登出**那一族。对照 `EeveeSpotifyReincarnated/Sources/EeveeSpotify/EeveePremiumForce.x.swift` | 他们原注释逐字：`Over-seeding caused greyed-out tracks (streaming-rules mismatch). Only seed the safe core set; dates and logout keys override-only.` 我们以前**无条件写 ~30 颗**（`loudness-levels`、`mixing-tools=EDIT`、`libspotify`、`mobile`… 服务器没发也造）；**`product` 一颗都不碰**（核心集合内部不一致） |
| `3a188ac` | 编译错：`launchAt` 是 `Date`（非可选）⇒ 不能 `.map { } ?? 0` | —— |

**`3eb4f0d` 的具体语义**（下一份日志按这个读）：

```
[Premium] attributes — core N seeded, M overridden, K left alone
          (the server never sent them; inventing them is what greys tracks out)
          ; streaming-rules blanked: true ; logout keys neutralised: true
          ; left alone: a,b,c…
```
- **核心集合**（无条件写）：`type` `catalogue` `product` `financial-product` `name` `player-license` `player-license-v2` `ads` `on-demand` `unrestricted` `shuffle-eligible`；
- **其余每一颗**：只在**服务端确实下发了**时才覆盖（`streaming-rules` / `previous-streaming-rules` 清空、日期、反登出 `forced_logout` / `force_logout` / `forced_logout_abroad_since` / `logout_required` / `session_invalidated`）。

### 1.5 CI 红叉（`a127421`）

用户问："怎么我这边 GitHub 提交的全是有个红 x 的"。根因是**我**：

`Logic tests`（`.github/workflows/tests.yml`，**每次 push 都跑**）把六个源文件**单独**丢给 `swiftc`。
我为了 Premium 取证往 `ServerSidedFeaturePolicy.swift` 里加了一个引用 `AccountAttribute` / `writeDebugLog` 的
static 方法 ⇒ 独立编译必挂 ⇒ 从 `7a4fd5a` 起每个 push 都红。

修法：取证搬到 `DynamicPremium+ModifyingFunctions.swift`；那个文件的**代码**回原样、文件尾留"**这是 CI 契约**"注释；
`SESSION_2026-10-12_HOME.md` §8 记了完整契约（六个文件 + 对应的 `swiftc` 命令）。

### 1.6 工具修正（`b936fb4` 顺带）

`Tools/eevee-hookfinder/bnk_from_customize_dump.py` 里那条提取命令**跑不通**：日志每行都有时间戳前缀，
而载荷那一行**没有** `[CustomizeBody]` 标签 ⇒ 前缀没被剥掉 ⇒ `base64 解码失败：Only base64 data is allowed`。
现在写进注释的是**真跑通过**的那条 pwsh 一行命令。

---

## 2. 现在到哪了（**这一节是"修好没有"的诚实答案**）

### 2.1 ✅ 真机证明修好的（日志里能指出来）

| # | 事 | 判据（真机日志） |
|---|---|---|
| 1 | 标签栏玻璃**尺寸**（与自绘胶囊对齐、且不漂） | `glass insets measured once — left 21 right 21 top 0 bottom 21` + `host 6,-3,402,81` + `drawn [_UITabBarItemPlatterView=27,-3,360,60 …]`，只出现一次 |
| 2 | 点标签**气泡立刻动** | 日志 69：`bubble mirrored straight away — #0 (a tap on Spotify's own bar; no waiting for the 0.5s tick)` |
| 3 | 主页头部**代码确实在跑** | 树：`18.LeadingFadeMaskView@0,1,366,32,alpha=0.00`（x 从 48 翻成 0 = RTL 生效；alpha 0 = pills 收掉） |
| 4 | 账号取证行能用 | `[Premium] the account state on the wire: type=free catalogue=free player-license=mft` |

### 2.2 🟡 改了、**没验**（用户测的日志 66/67/68/69 全是旧版）

我把最新那份日志（69）逐条对过 —— 我这几笔的判据**一条都没出现过**：
`drag is armed` / `tap recogniser installed` / `first tap seen` / `resolveconfiguration_9_1_88` /
`replaying the last real body` / `the real body arrived` / `[Premium] attributes — core …`。

| # | 事 | 怎么验 |
|---|---|---|
| 5 | **底部自带图标被藏住** | 眼睛：底部只剩我们那条玻璃的图标；日志：`icon taken from SPTEncoreIconView`（藏本身不打日志） |
| 6 | **按住划动能换页** | 先点四颗各一次 ⇒ `learned tab #N → …ViewController`；再划 ⇒ 一路 `bubble mirrored straight away — #N (a finger slid onto it)` |
| 7 | **主页「主页」与头像一条中线**（且滚动时不跑） | `[Home] header restyled — title … frame …; row …; avatar …; header …` 四个 frame 对齐 |
| 8 | **退出重进不再全黑** | `customize 304 -> replaying the last real body from Spotify 9.1.88, … bytes`（**不再是** `the bundled seed`）+ `the real body arrived — X.Xs after launch` |
| 9 | **灰歌变少**（这是假设，不是承诺） | `[Premium] attributes — core … left alone …` + `[PLAYER]` 行 |
| 10 | **新种子生效** | `seed ready resolveconfiguration_9_1_88.bnk — 1096 flags` |
| 11 | **CI 红叉清了** | GitHub 上最新那笔是否绿（`a127421` 之后） |
| 12 | 库里搜索胶囊那条日志（历史遗留） | 日志 64 及其后都没出现 `[Library] library search …`；要么没触发，要么没进日志 |

### 2.3 ❌ 没修好

| # | 事 | 为什么 |
|---|---|---|
| 13 | **灰歌 / 点播被拒** | 服务器对**免费账号**下发 `type=free catalogue=free player-license=mft`；我们只改客户端认知 ⇒ 客户端按会员点播、服务器按免费拒绝。`3eb4f0d` 只把"过度播种"这个**有出处**的嫌疑改掉，**未验证** |
| 14 | 拖动**第一次**（还没学过 VC 时） | 会在学不到时把气泡拨回真实那一颗（诚实优先，不假装） |

---

## 3. 接下来做什么（按优先级）

### P0 —— **先装一次最新的**（后面全依赖它）

拉 `main` 到 `3a188ac`（或更新）→ 编译 → 装 → 按四步走：

1. 启动看 `seed ready resolveconfiguration_9_1_88.bnk — 1096 flags`；
2. **点四颗标签各一次**（学 VC：`learned tab #N → …`）；
3. **按住从「主页」划到「创建」**（`bubble mirrored straight away — #N (a finger slid onto it)`）；
4. 退出 App **再进一次**（这次磁盘上已有真 body ⇒ 看 `replaying the last real body`）。

导日志给我；要的几类行：`drag is armed` / `first tap seen` / `learned tab` / `bubble mirrored` /
`replaying …` / `real body arrived` / `[Premium] attributes — core …` / `[PLAYER]`。

### P1 —— 灰歌的三条路线（**要用户拍板**）

| 路线 | 做法 | 结果 |
|---|---|---|
| **A（现状）** | 保留伪装 | 界面像会员，但点播被服务器拒 ⇒ 灰/播不动 |
| **B** | 关掉 Premium 补丁 | 免费档完整可用性（广告/随机），界面回免费档 |
| **C** | **分项伪装**（`3eb4f0d` 之后更值得试） | 例如保留 `catalogue=premium` 但让 `player-license` 跟随服务端；判读只看 `[Premium] …on the wire` + `[REVERT_WATCH][init] …` + `[PLAYER]` 三行 |

另：**反登出那一族**是否真的压住了"退出重进全黑"，看 §2.2 第 8 项。

### P2 —— 页面（顺序已定：主页 → 搜索 → 歌单）

- 主页：§2.2 第 7 项验完再谈"第二片"（小节标题 18pt/800 + 卡片圆角/间距，参考 pw `HomeHeadings.x` / `HomeCards.x` / `HomeSections.x`）；
- 搜索页：**我们从来没做过**（仓库里没有 `BrowsePageImpl` 引用）；参考 pw `SearchPage.x`（头部上滑 56pt + 淡出）；
- 歌单页：556 行头部 + 颜色场（`SGRPalette` / `SGRActionRow`）；
- 三个页面的头部都会滚动 ⇒ 都要"**每次布局重算**"那一套（主页已给出双挂点范式）。

### P3 —— 尾巴

- 库/主页的收尾验收（§2.2 第 12 项：搜索胶囊那条日志）；
- 快速滚动条、圆角、灰纱这三件在**关掉开关**时是否精确还原；
- 标签栏玻璃"第一片/第二片"是否还有需要统一的判据（`SESSION_2026-10-12_TABBAR_AB.md` §9）。

---

## 4. 要求与纪律（**不要忘**，都是本会话踩出来的）

### 4.1 代码

1. **一次一小片**；每处改动挂一颗开关，**关掉要精确还原**（记住原值再写回，别"清零了事"）；
2. **幂等**：同一个函数被重复调用不许叠加副作用；"同一个判据只留一份"；
3. **hook 方法体里不许直接碰 `@MainActor` 的东西**（`viewIfLoaded` 就是）——只把引用带进 `onMainThreadSync { }`；
4. **日志表达式里不嵌转义双引号**（会整行丢掉：主页那条就是这么丢的）、不写歌名/账号等隐私（探针只记数字与布尔）；
5. **不许删/藏 Spotify stack 的 arranged subviews** —— 只改 `alpha`（摘掉会踩 `updateConstraints`）；
6. UIKit 协议方法要用**现代 Swift 名**（`tabBar(_:didSelect:)`、`isUserInteractionEnabled`、`isHidden`）；
7. **改前 grep 旧名字**；删/改局部或静态变量后，扫一遍还有谁在用；
8. 移除/隐藏任何东西，都要**留一条能还原的路**（原位、原值）；
9. 新加 `ClassHook` 记得 `import Orion`（`orion_hook_guard.py` 会抓）。

### 4.2 提交前必跑（六条自检 + CI 的 python 测试）

```powershell
python Tools\eevee-hookfinder\orion_hook_guard.py
python Tools\eevee-hookfinder\swift_brace_check.py
python Tools\eevee-hookfinder\swift_member_check.py
python Tools\eevee-hookfinder\swift_string_check.py
python Tools\l10n_lint.py --locale en
python Tools\l10n_lint.py --locale zh-CN
python Tests\ResolveConfigurationSnapshot\test.py      # CI 里也会跑的那条
```

⚠️⚠️ **这六条都不做类型检查** —— 本机**没有 Swift 工具链**，所以"类型/改名/契约"这三类错只有
**CI 或用户的编译器**能发现。本会话因此吃了 5 个编译错（§6）。

### 4.3 CI 契约（改那六个文件之前，先读 `tests.yml`）

`.github/workflows/tests.yml` 的 `Logic tests` **每次 push 都跑**，并把这些源文件**单独**丢给 `swiftc`：

```
ServerSidedFeaturePolicy.swift   TelemetryEndpointRules.swift   FlagOverride.swift
URL+Extension.swift              DebugLogSanitizer.swift        BrowsitaSectionStripper.swift
```

⇒ **它们只许依赖 Foundation**（`AccountAttribute`、`writeDebugLog`、`UserDefaults.…` 在那里都不存在）。
细节见 `SESSION_2026-10-12_HOME.md` §8。

### 4.4 环境 / 流程

- **提交作者必须是 `zbzxbg <yuanhainigu@outlook.com>`**（不要用 `-c user.name` 覆盖）；提交信息英文、文档中文；
- 本机 `pwsh` 在受限沙箱里起不来（`0xC0000142`）⇒ 每调要 `sandbox_permissions: danger-full-access`；
- 一次提交只做一件事，**做完即推**（用户从 GitHub 拉下来编译）；
- 用户是**免费账号**、用中文、要"优雅"、以**网上/Apple Music 为准**、**要求诚实报告未验证项**（不许把"改了"说成"修好了"）；
- 页面设计参照：`https://code.jiangshu.ai/awesome-design-html/assets/ios/design.apple-music-ios.html`；
  竞品参照：`spoti.pw`（最接近的同代实现）、`kumone`、`MeloX`、`EeveeSpotifyReincarnated`（同代 fork，Premium 那条线的出处）。

---

## 5. 一页判据速查（症状 → 看哪一行）

| 症状 | 看这一行 | 说明 |
|---|---|---|
| 玻璃尺寸/位置 | `[TabBarSystem] glass geometry — host … ; drawn [_UITabBarItemPlatterView=…]` | 两个矩形应一致（`360×60` 那一档） |
| 玻璃忽大忽小 | `glass insets measured once — …` | 只该在**建栏时**出现一次 |
| 点标签没反应/慢 | `tap recogniser installed … Waiting for the first tap` → `first tap seen …` → `bubble mirrored straight away — #N` | 三行递进；缺哪行就卡在哪一步 |
| 划不动 | `drag is armed …` / `drag stays off — … answers setSelectedViewController: …` | 前者才装了 pan |
| 划了不换页 | `learned tab #N → …` + `⚠️ the drag could not switch the page yet …` | 没学过 VC |
| 底部还有 Spotify 自带按钮 | `icon taken from SPTEncoreIconView …` + `items synced — icons ["Y",…]` | 镜像成功；藏住与否看眼睛 |
| 主页标题偏上 | `[Home] header restyled — title … frame …; row …; avatar …; header …` | 比中心线 |
| 灰歌 / 播不动 | `[PLAYER] ⚠️ position stalled … (dur=…, rate=…)` vs `position held … reports paused (rate=0.00)` | **rate=0 = 暂停，不是灰歌** |
| 账号到底什么档 | `[Premium] the account state on the wire: type=… catalogue=… player-license=…` | 服务器原样 |
| 改写后 App 以为是什么档 | `[REVERT_WATCH][init] type=… on-demand=… player-license=…` | 我们的版本 |
| 有没有凭空造键 | `[Premium] attributes — core N seeded, M overridden, K left alone …` | `left alone` 越长 = 以前造得越多 |
| 启动时配置从哪来 | `[CustomizeSeed] seed ready …` / `customize 304 -> replaying …` | 看是**种子**还是**上一场真 body** |
| 黑屏窗口多长 | `the real body arrived — X.Xs after launch` | 这个数字就是窗口 |

---

## 6. 本会话踩过的坑（同类别再犯）

| # | 坑 | 教训 |
|---|---|---|
| 1 | `findView` 返回 `UIView` ⇒ `arrangedSubviews` 不存在（`d1d3f2b`） | 拿"父类型"接住子类型 API 前先强转 |
| 2 | `userInteractionEnabled` 是 ObjC 名（`d1d3f2b`） | Swift 是 `isUserInteractionEnabled`（**error 不是 warning**） |
| 3 | 新加 `ClassHook` 忘了 `import Orion`（本会话被 `orion_hook_guard.py` 当场抓住） | 自检能抓这一类，所以**每次都要跑** |
| 4 | 往 CI 单独编译的文件里塞了引用仓库符号的代码 ⇒ **一串红叉**（`a127421`） | 改那六个文件前先读 `tests.yml`（§4.3） |
| 5 | `launchAt.map { } ?? 0` 而 `launchAt` 是**非可选** `Date`（`3a188ac`） | 抄代码要连**类型**一起抄；扫全部 `.map`/`??` 的接收者 |
| 6 | 主页那条日志整行没进日志（嵌转义双引号 + 多余条件）⇒ 白猜一轮 | 日志行**越傻越好**：不嵌引号、条件越少越好 |
| 7 | 同一族视图按"面积最大"挑 ⇒ 挑到随状态变的那个（选中气泡）⇒ 尺寸忽大忽小 | 挑参照物要**指名道姓**（类名 + 尺寸门槛） |
| 8 | 把"改了"当"修好了"汇报 | 汇报分三档：**真机验过 / 改了没验 / 没修好** |

---

## 7. 本会话提交清单（`dc16dd4 … 3a188ac`）

```
3a188ac fix(premium): launchAt is a Date, so subtract it instead of mapping it
3eb4f0d feat(premium): stop inventing account keys, and take the sibling fork's logout guards
39704c4 fix(premium): replay last session's real body instead of the seed, and let the log tell a pause from a stall
b936fb4 feat(premium): run on a 9.1.88 configuration snapshot, not the 9.1.76 one
456d57b diag(tabbar): make it visible whether a tap ever reaches us
28a1308 fix(tabbar,home): hide the icon view this build draws, learn the tab controllers, and re-place the title on the row's own passes
a127421 fix(ci): keep the CI-compiled file self-contained, move the premium evidence out
c147d8a feat(tabbar,home): read the icons this build draws, add the slide, and put the home title on the avatar's line
d1d3f2b fix(home): the header stack needs the cast, and the interaction flag its modern name
1eaa1fd revert(library): hold the scroll edge effect change, keep the finding
2c27de3 feat(library): the top edge frosted glass goes through the public API, nothing else moves
f624350 diag(tabbar): print the forwarding chain pw relies on, link by link
f688621 fix(tabbar): only take the touches when a route exists, and measure the glass once
92b7adf docs(handoff): the home page's first slice, and why the pages are ordered home, search, playlist
d0d8f22 feat(home): the header the way Apple Music's Listen Now has it
e4a7c57 docs(handoff): what log 64 settled - the glass insets, the dead forwarding routes, the false alarm and the scrubber
0bf5f12 feat(library): the quick-scroll scrubber goes, and the artwork is found by id or by geometry
a2e5a80 fix(tabbar): size the glass by what UIKit actually draws, and make a tab tap switch tabs
1ace166 fix(library): the search shapes are found separately from being laid out
c724524 fix(library): drop the stale didReportScrim the scrim refactor left behind
dc16dd4 feat(library): the in-library search field and Cancel become capsules
dbd56bc feat(library): rows and cards take Apple's continuous corners and an inset hairline
```

---

## 8. 相关文档（本会话新增/更新）

| 文档 | 内容 |
|---|---|
| `SESSION_2026-10-12_LIBRARY.md` | 音乐库三片 + §8 日志 64 的五条修正 + **§9 毛玻璃（查清、做过、已回退）** |
| `SESSION_2026-10-12_TABBAR_AB.md` | 标签栏系统玻璃四片 + **§9 第四轮（图标/划动/反应/主页标题）** |
| `SESSION_2026-10-12_HOME.md` | 主页头部第一片 + **§8 CI 契约（红叉根因）** |
| `SESSION_2026-10-12_NIGHT.md` | 上一轮的 Premium/配置链（§9.2 那条"304 没有 body ⇒ 交不出配置"） |
| **本文** | 全会话总结：做了什么 / 现在到哪 / 接下来做什么 / 要求与纪律 |
