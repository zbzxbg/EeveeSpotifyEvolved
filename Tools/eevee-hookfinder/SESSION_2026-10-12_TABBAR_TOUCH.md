# SESSION_2026-10-12_TABBAR_TOUCH — 「玻璃不跟手 / 胶囊回弹 / 替用户按按键」：日志 70 的判读 + 照 pw 改法

> 上一份入口是 [`SESSION_2026-10-12_SUMMARY.md`](SESSION_2026-10-12_SUMMARY.md)（全会话总结：做了什么 / 现在到哪 / 接下来做什么）。
> 本文是**它后面那一轮**：用户装完最新构建、报回底部玻璃栏的三个症状，参考材料是
> **日志 70**（`C:\dsh\ipa\eeveespotify_debug_shared 70.log`，2026-10-04 14:55–14:56，`[CustomizeSeed] resolveconfiguration_9_1_88` ⇒ 装的是最新那版）
> 与照片 82–87（`C:\dsh\else\`，其中 86 是那条栏的放大裁切）。
> 代码改动落在 **`Sources/EeveeSpotify/Appearance/TabBarSystemGlass.x.swift` 一个文件**（本机没有 Swift 工具链，**一行都没在真机上跑过**）。

---

## 0. 三十秒现状

| | |
|---|---|
| 用户这一轮的话 | 「**标题栏液态玻璃不跟手**，在划动过程中，**可能有胶囊回弹 / 替用户按按键**的情况，而且**胶囊也没有反射**。你可以去看一下 spoti.pw 看一下他们的标题栏液态玻璃是怎么做的」 |
| 判读 | 说的就是**底部那条玻璃栏**（Spotify 四颗：主页 / 搜索 / 音乐库 / 创建）。pw 那边整块功能就叫 **`Navbar`**（`Redesigned/Navbar/TabBar.x`），是它唯一的玻璃栏；我们这条是照它做的 |
| 根因（**日志 70 第一行 + 代码实证**） | 我们的"要不要接管触摸"判据只认第 ① 条公开路（容器是 `UITabBarController`），真机上容器**不是** ⇒ 判定永远 false ⇒ **系统栏一次都没接过触摸**：玻璃只是一张画（不跟手、不折射），而手指全落在 Spotify 那条栏上，由我们第三片装的 **pan 手势**代劳 ⇒ 划一下就**替用户换页**，提交不了还把气泡**拨回原位** |
| 改了什么 | ① `probeForwardRoute`：转发路**读得出来**才让系统栏接管触摸（pw 那条路本来就能在点之前读出来）；② **删掉那只 pan** 及整套机械（`dragCrossed` / `commitSelection` / `refreshCommitRoute` / `learnSelection` / `TabBarContainerSelectionHook`）；③ 修掉一行**自相矛盾**的日志（`installed — … taking touches`）；④ **第二轮**：去掉第 4 颗「创建」（见 §8） |
| 自检 | ✅ 七条全绿（orion 332 / brace 332 / member 277 / string 281 / l10n en / l10n zh-CN / `Tests\ResolveConfigurationSnapshot\test.py`） |
| 装机 | ❌ **这一版一行都没上过机器**。要验的就是 §5 那三行日志（`forward route probe: …` / `a forward route showed up — …` / 不再有 `drag installed …`） |

---

## 1. 用户这一轮的话，逐句对着看

| 用户说 | 在我们的代码里对应什么 |
|---|---|
| **不跟手** | `ensureBar` 里 `takesTouches = canForwardTaps(in:)` = **false** ⇒ `systemBar.isUserInteractionEnabled = false` + 宿主同样 false。手指落不到系统栏上 ⇒ UIKit 的玻璃收不到 `touchesBegan`：**没有按下回弹、没有镜片跟手** |
| **胶囊也没有反射** | 同一件事。`_UILiquidLensView` / `ClearGlassView` / `SDFView` 都在树上（日志 70 的 `drawn […]` 逐个列着）、但它们是**静态**的：折射只在"玻璃接住手指"之后才是活的 |
| **在划动过程中，可能有胶囊回弹** | 第三片那只 `UIPanGestureRecognizer`（`cancelsTouchesInView = true`）。每次 `.changed` 都 `mirrorSelection` = 写 `systemBar.selectedItem`（UIKit 会给它做动画）⇒ 气泡跟着手指一格一格**跳**；提交不成功时 `dragCrossed` 再把气泡**拨回真实那一颗**（`reason: "snapping back — the commit route is not learned yet"`） |
| **替用户按按键** | 同一只 pan 的 `commitSelection`：用户只是在栏上滑了一下，**页面被我们换掉了**（日志 70：`bubble mirrored straight away — #1 (a finger slid onto it…)` + `⚠️ the drag could not switch the page yet`） |

**"标题栏"这个词的判读**：本合同没有别的玻璃胶囊——`Appearance/` 下只有两条路（`TabBarGlass.x.swift` 自绘胶囊、`TabBarSystemGlass.x.swift` 系统栏），都是**底部标签栏**；
顶部那行（主页 / 搜索 / 音乐库 的大标题）是 Spotify 自己的 label + 我们改字号（`HomeAppearance` / `LibraryAppearance`），**没有玻璃**。
加上症状（划动 / 回弹 / 按键）全落在"按住划"，**按底部标签栏处理**。若用户其实是别的控件，下一轮先问清再动手。

---

## 2. 证据（都可以在盘上复核）

### 2.1 日志 70：第一行就是全部答案

```
[TabBarSystem] system bar added 0,0,414,83 on NavigationUI_TabBarImpl.TabBarView — in a host that reports
   no bottom safe area; leaving the touches to Spotify's own bar (no forwarding route found, so tapping
   behaves exactly as before)
```

而**同一秒后面**又有一行：

```
[TabBarSystem] installed — 4 item(s); … ; class EeveeSpotify.TabBarSystemGlassBar;
   taking touches, taps forwarded to Spotify's own items
```

这两行**自相矛盾**（第四片才发现）：后者是 `logLayoutOnce` 里**写死**的字符串，不看实际状态。
⇒ 判读规矩：**只信 `system bar added …` 那一行**。它说的是"这一版没接管触摸"。

同一份日志里还有：

* `drag installed on Spotify's own bar — sliding across the tabs switches them …` ⇒ pan 装上了（`commitRouteAvailable = true`，因为容器响应 `setSelectedViewController:`）；
* `bubble mirrored straight away — #0 / #0 / #1 (a finger slid onto it…)` ⇒ 用户**确实在划**；
* `⚠️ the drag could not switch the page yet …` ⇒ 划动**没换成页**，气泡被拨回去（= 用户说的"胶囊回弹"）；
* 随后三次 `learned tab #N → SPNavigationController` ⇒ 用户改成"一颗一颗点"，我们才学到 VC。

### 2.2 代码（改前的位置）

| 位置 | 干了什么 |
|---|---|
| `TabBarSystemGlass.x.swift` `ensureBar` 里 `let takesTouches = canForwardTaps(in: bar)` | `canForwardTaps` **只认**"容器是 `UITabBarController` 且有 ≥2 个 VC" ⇒ 真机上是 `TabBarContainerImpl`、`children: 1`（日志 67 逐字）⇒ **永远 false** |
| 同文件 `apply` 里 `if !handedBackTouches, !systemBar.isUserInteractionEnabled, canForwardTaps(in: bar)` | 每拍再问一次，问的还是同一条路 ⇒ 也不会变 true |
| 同文件 `installStockGestures` | 装了 **tap**（`cancelsTouchesInView = false`，只为"气泡立刻动"）+ **pan**（`cancelsTouchesInView = true`，"滑过哪格切哪格"） |
| 同文件 `dragCrossed` / `commitSelection` / `refreshCommitRoute` / `learnSelection` / `TabBarContainerSelectionHook` | pan 那一套：镜像 + 提交 + 学 VC + 失败拨回 |
| 同文件 `logLayoutOnce` | 写死 `taking touches, taps forwarded to Spotify's own items`（与第一行矛盾） |

---

## 3. spoti.pw 是怎么做的（`Redesigned/Navbar/TabBar.x`，492 行；**只读机制、代码自己写**）

| 机制 | pw 的做法 |
|---|---|
| **谁吃触摸** | **系统栏全吃**。Spotify 那条栏留着 frame，但它的子视图 `alpha = 0` **并且 `userInteractionEnabled = NO`**（`TabBar.x:360-364`）⇒ 没有任何东西和系统栏抢 |
| **玻璃** | 它自己**一行玻璃 API 都不用**：`UIDesignRequiresCompatibility` 关掉之后，UIKit 把系统 `UITabBar` 画成真液态玻璃（选中气泡、镜片、明暗自适应）。`overrideUserInterfaceStyle = .dark` 只为了让浅色模式下别画成亮玻璃 |
| **点击怎么落到 Spotify 上** | `UITabBarDelegate` 的 `didSelectItem` → `forwardTap(source)` → **读那颗 item 子树里 tap 识别器的 `_targets`**，把 target/action 逐对触发（`TabBar.x:139-158`），退路是 `UIControl.sendActions`；都没有就把子树里的识别器全打进日志（`tab bar: nothing to tap in …`） |
| **选中态** | 读 Spotify 自己那颗**白字**（`isActive`：`#FFFFFF` vs `#B3B3B3`）→ `bar.selectedItem`；`didSelectItem` 之后再 0.25s `syncBar` 一次 |
| **手势** | **一只手势都没有**，只有一颗 `UILongPressGestureRecognizer`，而且 `gestureRecognizerShouldBegin` 限定**只在"主页"那颗上**有效（长按进 Mod Settings，`TabBar.x:218-239`）。"果冻 / 跟手"是**系统玻璃自己的**交互 |
| **高度** | `SGRTabBarHost` 把底部安全区**减掉自己让出去的那部分**（UIKit 按"所在视图的安全区"量玻璃高度），差额写进 `TabBarContainerImpl.additionalSafeAreaInsets.bottom` |

⇒ 结论：**"跟手 / 有反射"不是写出来的，是"把触摸交给系统栏"换来的**；"不替用户换页"则是因为**没有那只 pan**。

---

## 4. 这一轮改了什么（一个文件）

### 4.1 转发路"读得出来"才接管触摸

新增 `probeForwardRoute(in:)`（顺序与 `forwardTap` 一致，从最公开到最私有）：

| 路 | 判据（**点之前**就能读出来） |
|---|---|
| ① | 容器是 `UITabBarController` 且 `viewControllers.count >= 2` |
| ② | item 子树里那颗启用的 `UITapGestureRecognizer` 的 `_targets` 里，**至少有一对** target/action 能解出来、且 target `responds(to:)` —— 这正是 pw 依赖的那一环（`TabBarItemElementUI` 的 `-handleTap`） |
| ③ | 子树里（响应链或 ivar 上）有对象响应 `-handleTap` |
| ⑤ | 子树里有 `UIControl` |

* **读到了** ⇒ `host.isUserInteractionEnabled = true` + `systemBar.isUserInteractionEnabled = true`
  ⇒ 玻璃接得住手指（"跟手"与折射回来了），点击由 `didSelectItem` → `forwardSelection` 转发；
  日志：`forward route probe: route ② (pw's) the tap recogniser on #0 fires …:handleTap`。
* **一条都没读到** ⇒ 照旧让触摸穿透（点得动第一），并把那条链**逐环**写出来：
  `… — chain: #0 TabBarItemElementView[UITapGestureRecognizer[_targets ivar is gone in this build] on …]`
  —— 下一次它读不出来时，**这条日志就是答案**（`_targets` 改名 / nil / 不是可走的数组 / 一对都没有 / target 不响应）。
* 每拍重试带**节流**（`probeForwardRouteThrottled`：最多 1s 一次，第一次立刻探），
  因为 `apply` 每次布局 + 每 0.5s 复查都会进来；一旦接管就不再探。
* **不采用**"先接管、失败再还回去"：那会白丢第一下（第三片的教训）。仍然保留
  `handTouchesBack` 作为**运行时**兜底（真点空了就把触摸还给 Spotify，且交还过就不再收回）。
* `accessibilityActivate()`（第 ④ 条）**探不出来**（要真调一次才知道）⇒ 只留在 `forwardTap` 的兜底里。

### 4.2 删掉那只 pan

连同它的整套机械：`stockPanKey` / `TabBarSystemGlassGestureRelay.stockDragged` / `dragCrossed` /
`commitSelection` / `refreshCommitRoute` / `commitRouteChecked` / `commitRouteAvailable` /
`knownControllers` / `learnSelection` / `TabBarContainerSelectionHook`（一个 Orion hook 也一并去掉）。
留下的只有 tap（`cancelsTouchesInView = false`，只为"气泡立刻动"），它在"触摸已交给系统栏"那一档里根本收不到触摸，
只在"把触摸交还 Spotify"那一档里起作用。

### 4.3 顺手：一行撒谎的日志

`logLayoutOnce` 的 `installed — …` 改成**照实报** `systemBar.isUserInteractionEnabled`。
（日志 70 里那两行矛盾就是这么来的。）

---

## 5. ★ 装机验收（下一份日志照这个读）

先点 CI：`Actions → Build IPA — patched … → Run workflow`（`ipa_url` 留空）。**红了先修编译，别的都别验。**

| # | 怎么做 | 应该看到 | 日志判据 |
|---|---|---|---|
| ① | 进 App，看标签栏 | 玻璃还是那条（尺寸/位置不该变） | `[TabBarSystem] system bar added …; forward route probe: **route ②** …`（这一步决定后面全部） |
| ② | 若 ① 是 `route ②` ⇒ **点四颗各一次** | 每次都能换页（**这是红线**：点不动就说明转发落空） | `tap on #N forwarded to Spotify — route …` + `[TabBarSystem] selection → #N`；**不该**出现 `⚠️ tap on #N found nothing to forward to` |
| ③ | 手指**划过**那条玻璃（不抬手） | **页面不该被换掉**（这是本轮的主诉求）；玻璃本身有按下/跟手的反应 | **不该**再有 `drag installed on Spotify's own bar …`（出现 = 装的是旧包）；不该再有 `bubble mirrored straight away — #N (a finger slid onto it …)` |
| ④ | 看玻璃的观感 | 手指按住时有系统自己的反应；玻璃有折射/高光 | 视觉确认（日志没有"折射"这一行） |
| ⑤ | 万一 ① 是 `none — no route can be read before a tap` | 行为与旧版一致（点得动、玻璃是画） | 把 `forward route probe: none … — chain: …` **整行**发我：`_targets` 到底哪一环断了，就靠它 |

**出现下面任一条就说明装的是旧包**：`drag installed on Spotify's own bar`、`drag is armed`、`drag stays off`、`learned tab #N → `。

---

## 6. 未验证声明（**不要删这一段**）

* **这一版一行都没在真机上跑过。** 本机没有 Swift 工具链，"能编译"只有 CI 能回答；七条自检**不做类型检查**。
* **`route ②` 在 9.1.88 / iOS 27 上到底读不读得出来，是这一轮唯一的关键未知数。**
  依据是"pw 在 9.1.78 上就是这么转发点击的"＋我们自己的 `describe()` 会把每一环写出来；
  **没有**我们这台机器上的真机数据（日志 64 那次只留下 `found nothing to forward to` 一句，链没打出来）。
  读得出来 ⇒ 玻璃活了；读不出来 ⇒ 行为回退到"点得动、玻璃是画"，但日志会给出确切的断点。
* **"删掉 pan 之后划动会怎样"有两种可能**，都还没见过：(a) UIKit 自己的标签栏接住手指（"跟手/果冻"就来自它）；
  (b) 什么都不发生（划一下没有任何反应）。**两种都比"替用户换页"好**，但 (a) 才是用户想要的 —— ③ 那条验收就是看它。
* **"胶囊没有反射"** 我判的是"玻璃没接到触摸 ⇒ 折射是静态的"。若 ②③ 都过了而观感仍然不对，
  下一个嫌疑是 `systemBar.backgroundImage = UIImage()` / `shadowImage = UIImage()` 这两行
  （pw 没设；改前就有，照片 83 里玻璃是活的，所以先不动它们）。
* 关开关的还原路径**没动**：`remove()` 仍然摘手势、摘栏与宿主、恢复每个视图的**原** alpha、把
  `additionalSafeAreaInsets` 写回原值（只写了 `lastProbeAt = 0` 这一条新状态）。
* **许可**：pw HEAD 是 PolyForm Strict 1.0.0（禁止复用代码）。本文与代码**只读它的机制**（文件头逐条注明出处），
  实现全部自己写；没有拷贝它的任何一行。

---

## 7. 下一步（按优先级）

1. **编译 + 装机 + 一份日志**（§5 的五行判据）。这一轮的结论**只**依赖 `forward route probe:` 那一行。
2. 若 ① 读到 `route ②` 而 ② 里点不动：把 `⚠️ tap on #N found nothing to forward to …` 那一行发我
   （它现在会把链逐环写出来），下一轮照它换转发路，不要再猜。
3. 若 ① 读到 `none`：同样靠那行 `chain: …` 定位（三种可能：`_targets` 改名 / nil / target 不响应）。
4. **仍然挂着的旧账**（用户"碰到再说"的）：灰歌三条路线（`SESSION_2026-10-12_SUMMARY.md` §3 P1）、
   主页第二片 / 搜索页 / 歌单页（§3 P2）、SponsorBlock 观察者、短歌当前行居中、iOS 16.1–18 覆盖。

---

# 8. 第二轮（同一天，用户紧接着提的）：**去掉第 4 颗「创建」**

## 8.1 用户原话与判读

> 「有个按键在音乐库的右边，**叫创建歌单**。能不能**不要这个功能了**。即液态玻璃**只显示主页，搜索，音乐库三个按键**」

= 标签栏第 4 颗 `TabBar.Item.创建`（点开是"创建歌单/播放列表"的菜单）。
真机树逐字（**日志 70 的 `[TabBarDump]`**，这就是判据，不用猜）：

```
#5  ElementContentView<TabBarItemElement> frame=(0,0 104x49)     → #7  TabBarItemElementView              id=TabBar.Item.主页
#12 ElementContentView<TabBarItemElement> frame=(104,0 104x49)   → #14 TabBarItemElementView              id=TabBar.Item.搜索
#19 ElementContentView<TabBarItemElement> frame=(207,0 104x49)   → #21 TabBarItemElementView              id=TabBar.Item.音乐库
#26 ElementContentView<TabBarItemElement> frame=(310,0 104x49)   → #28 CreateMenu_TabBarItemImpl.CreateMenuTabBarItemView id=TabBar.Item.创建
```

⇒ **第 4 颗是另一个类**（`CreateMenu_TabBarItemImpl.CreateMenuTabBarItemView`，pw 也 hook 这个类名）。
判据用**类名**，不用文字 —— 文字随语言变（`创建` / `Create`）。

## 8.2 做法：藏**整颗 arranged subview**，不是只藏图标与文字

| | |
|---|---|
| **只藏内容**（像我们藏图标/文字那样） | 那个位置仍然占着宽度、**而且仍然点得动**（点下去照样弹创建菜单）⇒ "不要这个功能了"没做到 |
| **藏整颗 `isHidden = true`**（采用的） | `UIStackView` 把它的位置让给另外三颗 ⇒ **三颗平分整条栏**；隐藏视图**不参与命中测试** ⇒ 那个入口真的没了；可精确还原（记了它自己的原 `isHidden`） |

**一处判据**：新增 `TabBarGlassPlate.visibleItems(in:)`（`subviews.filter { !$0.isHidden }`），
所有"按颗数"的地方都走它 —— 自绘胶囊的 `tightenOffsets` / `measure` / `tightenRow`，
系统玻璃的镜像列表、`itemIndex(at:)`（手指在哪一格）、`forwardSelection`（`item.tag` → 转发给哪一颗）。
⚠️ 这一步非做不可：隐藏的 arranged subview **仍在 `stack.subviews` 里**，不筛的话三颗会按四颗算
（胶囊偏/宽、点第 3 颗转发到第 4 颗上）。

**开关**：设置 → 扩展功能 → 标签栏 →「**隐藏「创建」标签**」，**默认开**（= 用户要的结果），
关掉把原 `isHidden` 写回；与别处一样是可以撤销的。
驱动：栏自己的布局回合（`TabBarPlateHook.layoutSubviews` 里**先于**两条玻璃路跑）+ 0.5s 复查节拍再压一次
（幂等；Spotify 若把它显示回来，我们会**再藏一次**并报一行 `shown again N time(s)`）。

## 8.3 这一轮改的文件

`Sources/EeveeSpotify/Appearance/TabBarGlass.x.swift`（藏那一颗 + `visibleItems` + 钩子）、
`…/TabBarSystemGlass.x.swift`（三处取列表都走 `visibleItems`）、
`…/Settings/Sections/Extras/Views/EeveeExtrasSettingsView.swift`（一行开关）、
`…/Shared/Models/Extensions/UserDefaults+Extension.swift`（键 `tabBarHideCreate`，默认 **true**）、
`en` / `zh-CN` 两条文案（并顺手改掉 `tab_bar_*_description` 里"四颗/含创建"的过期说法）。

## 8.4 验收（与 §5 那五行一起看）

| # | 怎么做 | 应该看到 | 日志判据 |
|---|---|---|---|
| ⑥ | 进 App 看底部那盘玻璃 | **只有三颗**：主页 / 搜索 / 音乐库（平分整条栏、居中） | `[TabBarPlate] hid the Create tab (…CreateMenuTabBarItemView) — the bar keeps three items: Home, Search, Your Library` |
| ⑦ | 原来第 4 颗的位置点一下 | **什么都不发生**（创建菜单不弹） | —— |
| ⑧ | 点那三颗 | 都还能换页（红线） | `[TabBarSystem] items synced — 3 item(s)` 与 `installed — 3 item(s)`；`tap on #N forwarded …` |
| ⑨ | 设置里关掉「隐藏「创建」标签」 | 「创建」**当场**回来；再打开又没 | `[TabBarPlate] the Create tab is back (…)` |
| ⑩ | 玻璃胶囊的宽度 | 比四颗时**略窄**且**仍然居中**（它按"看得见的图标那一带"算，三颗自然窄一点） | `[TabBarSystem] glass geometry — … drawn […360×60…]` 那行的数字会变小 |

**未验证声明（追加）**：藏 arranged subview 之后 Spotify 会不会在它自己的回合里把 `isHidden` 写回、
三颗的图标间距/胶囊宽度最终长什么样，**都没有真机数据**（本机没有编译器）。
若 ⑥ 之后又冒出第 4 颗，日志里那行 `shown again N time(s)` 就是现场。

---

# 9. 第三轮（同日）：**「标签用液态玻璃」整条删除**

> 用户原话：「**标签用液态玻璃这个功能可以删掉了**」—— 指设置页那颗 `tabBarGlass`
> （我们**自绘**的那盘胶囊），它已经被「标签栏改用系统玻璃」整盘取代。

## 9.1 删了什么、留了什么（一条线画在"画"与"判据"之间）

| | |
|---|---|
| **删（"画"的那一半）** | `TabBarGlassPlate.apply` / `removePlate` / `layering` / `makeGlassView` / `plateKey` / `interactiveOn` / `hasGoodFrame` / `retryCount` / `scheduleRetry` / `report` / `lastReported*` / `reportLimit`，以及只为它服务的**纵向位移**（`rowShifts` / `iconShifts` / `hasDeviation` / `rowIsTransient` / `armRowRecheck` / `recheckRow` / `reconcileRowIfTransient` / `rowShiftLimit`）和 `tightenRow`（**真的去收四颗**那一步） |
| **删（功能面）** | 设置页那一行 `tab_bar_glass`、`UserDefaults.tabBarGlass` 键与访问器、`ownedKeys` 里那一项、en/zh-CN 的 `tab_bar_glass` 文案；那节 footer 改写（它原来整段在讲自绘那盘玻璃） |
| **删（连带）** | `DeclutterChrome` 里那行 `reconcileRowIfTransient()`（它正是"复核自绘胶囊那一行"用的）；`NewDesignYield.x.swift` 里"标签栏玻璃得我们自己做"那句过期结论 |
| **留（**共用判据**）** | `findTabsStack` / `targetCapsuleRect`（`measure` + `tightenOffsets` + `capsuleRect` + `contentBand` + `isUsable`）/ `capsuleWidth` + `capsuleWidthRatio`（迷你播放条按它等宽）/ `visibleItems` / `applyCreateTabVisibility` / `applyLabelVisibility` / 钩子 |
| **改动最大的一个决定** | `tightenFactor = 0.20` **保留**，但它现在的语义变了：**真的去收四颗的代码删了**，这个数只参与 `measure` ⇒ "胶囊按收紧后的版式算多宽"。四颗时 272 + 88 = **360**（就是现在屏幕上那条）。删了它，胶囊会变成贴边的 ≈398 |

**钩子现在只剩三步**（顺序要紧，`TabBarPlateHook.layoutSubviews`）：
① `applyCreateTabVisibility`（藏「创建」）→ ② `applyLabelVisibility`（藏文字，**与玻璃无关，两种开关状态下都要生效**）→ ③ `TabBarSystemGlass.apply`。
⚠️ ②原来挂在自绘胶囊的 `apply` 里 —— 直接删那条 `apply` 会让「隐藏标签文字」**失效**，所以它被搬到了钩子里。

## 9.2 验收

| # | 怎么做 | 应该看到 | 日志判据 |
|---|---|---|---|
| ⑪ | 设置 → 扩展功能 → 标签栏 | **没有**「标签用液态玻璃」那一行；剩下「隐藏标签文字」「隐藏「创建」标签」「标签栏改用系统玻璃」 | —— |
| ⑫ | 关掉「标签栏改用系统玻璃」 | 标签栏回**Spotify 原生**那条（**没有**我们画的胶囊），文字仍按开关藏、创建仍按开关藏 | 不该再出现 `[TabBarPlate] glass capsule laid on …` / `capsule (…) ← with-text band …` |
| ⑬ | 开回来 | 与第 8 节验收一致（系统玻璃 + 三颗 + 点得动） | `[TabBarSystem] system bar added …` |
| ⑭ | 启动日志 | 一行新的安装说明 | `[TabBarPlate] installed — tab row policy (hide labels / hide Create) over NavigationUI_TabBarImpl.TabBarView; the glass itself comes from TabBarSystemGlass (the self-drawn capsule was removed on 2026-10-13)` |

**未验证声明（追加）**：这一轮**删了 589 行**（`TabBarGlass.x.swift` 从 1258 → 778 行），
本机**没有编译器**；七条自检都不做类型检查 ⇒ "能编译"只有 CI 能回答。
系统玻璃那条路的几何判据**一个字没改**（`targetCapsuleRect` 的输入输出与删除前逐行一致），
所以"胶囊还是 360×60"这件事在代码上是**同一份计算**，但没有真机复核。

---

# 10. 第四轮（同日）：两个默认值 + 歌单封面「四宫格」的侦察

## 10.1 两个默认值（用户 2026-10-13 要求）

| 事 | 改法 | 注意 |
|---|---|---|
| **AMLL 优先 → 默认开** | `Settings/ngzhwm/ngzhwmSettingsViewModel.swift`：`bool(forKey: amllPreferredKey, defaultValue: true)` | 只对**从没写过这个键**的设备生效；手动关过的保持关（不覆盖用户的选择） |
| **Genius 功能 → 默认开** | `Lyrics/Models/Settings/LyricsOptions+UserDefaults.swift`：`defaultValue` 里 `geniusFallback: true` | ⚠️ **光改默认值不够**：`lyricsOptions` 是**整块 JSON 落盘**的（`@UserDefault` 包装器），用户只要动过其中任一项，盘上那份里 `geniusFallback` 已是具体的 `false` ⇒ 配套**一次性迁移** `LyricsOptions.applyGeniusFallbackDefaultIfNeeded()`（启动时跑，标记键 `lyricsOptionsGeniusDefaultOn`，只做一次并打一行日志） |

启动横幅那行同步加了 `AMLL preferred: ON/OFF` —— 两个开关的**实际生效值**一眼可见（用户的三份日志里 `genius fallback: OFF` 就是这么读出来的）。

## 10.2 ★ 歌单封面那个「四宫格」：**是服务端拼好的一张图**（实证）

**不是客户端拼的** —— 真实 API 数据（公开仓库里缓存的 Spotify 响应）逐字如此：

```
"images":[{"height":640,"url":"https://mosaic.scdn.co/640/ab67616d0000b27307a7a809c3f77c61fe31e05f
                                                   ab67616d0000b2730a719f2817838a22e6a7e8c9
                                                   ab67616d0000b273587227ac29ff1f83ccbd1623
                                                   ab67616d0000b27362a13d5041f79075d4e317f0","width":640}, …]
```

四个 **40 个 hex** 的图 id 串在同一个 URL 里（`640/300/60` 三档，id 串完全一样）。
单张封面的地址是大家熟知的形式：`https://i.scdn.co/image/<那 40 个 hex>`
（本仓库 `LyricsBackdropArtworkView` 拼的就是它）。

⇒ **要让封面只显示其中一张，最干净的改法是在"URL 进图片加载器"那一刻改写它**：
`mosaic.scdn.co/<size>/<id1><id2><id3><id4>` → `i.scdn.co/image/<id1>`。
视图层拿到的已经是一张成品图，改视图（裁切/藏三格）既更脆也更费。

**还差两件事才能落地：**

1. **第一个 id 是不是"第一首歌"的封面** —— 语义上应当是（2×2 的拼接顺序），
   但要拿一个你认得的歌单在真机上核对一次；
2. **URL 进的是哪个类 / 哪个方法** —— `dump-9.1.88.txt` 的 `[selectors]` 桶**只给选择器名、
   不给所属类**（`[methods]` 桶里其实是类型名，不是"类 → 方法"）
   ⇒ 新增**只读**探针 `Sources/EeveeSpotify/Diagnostics/ImagePipelineProbe.swift`：
   启动时对 9 个候选类（`ImageLoader_ImageLoaderKit.SPTImageLoaderImpl` /
   `ImageLoadingServiceImpl.*` / `ECMImageLoader.*` …）× 8 个候选选择器
   （`loadImageForURL:sourceIdentifier:size:scale:allowUpscaling:context:callback:persistenceKey:` …）
   逐个问"在不在、认不认"，打 `[ImageProbe] …`。**不 hook、不调用、不改任何东西**。

## 10.3 这一轮的验收行

| 看什么 | 应该出现 |
|---|---|
| 两个开关的实际值 | `[INIT] card element inject: … \| genius fallback: **ON** \| AMLL preferred: **ON**` |
| 迁移（只出现一次） | `[Lyrics] genius fallback default turned on once (the stored options said off) — from here on the switch in the lyrics settings decides` |
| 图片管线的答案 | `[ImageProbe] SPTImageLoaderImpl is here — answers: …`（哪一行有 `loadImageForURL:…` ⇒ 下一轮就 hook 那一个） |
