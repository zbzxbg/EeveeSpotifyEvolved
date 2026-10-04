# SESSION_2026-10-12_TABBAR_AB — 标签栏系统玻璃"第二片"（尺寸对齐 + 接管触摸）+ Premium 那条 A/B 的落点

> 上一份入口是 [`SESSION_2026-10-12_NIGHT.md`](SESSION_2026-10-12_NIGHT.md)（§8 标签栏第一片、§9 与上游对比、§11 两个 A/B）。
> 这一份是**用户做完 A/B 之后**的两条反馈：
>   ① 标签栏：「这个系统的液态玻璃和原本自己做的尺寸不一样……**你和自绘的对齐就行**」+
>      「液态玻璃不是胶囊套胶囊吗，**里面那个胶囊不可用手划动**」；
>   ② Premium：「**和 A 应该没关系，和 B 有关系**」→ 追问后确认：
>      **「不启用 Premium 补丁时正常，打了补丁才灰」**。
>
> 现场材料沿用 `C:\dsh\else\40.jpg` `41.jpg`（kumone 的听歌页，用户点名）、`82.jpg`（系统玻璃第一条真机照）、
> 日志 `C:\dsh\ipa\eeveespotify_debug_shared 63`（= 第一片那一版）、`C:\dsh\ipa\dump-9.1.88.txt`。

---

## 0. 三十秒现状

| | |
|---|---|
| 提交 | 本轮 **3 笔**（见 §5），都在 `main` |
| 要编译的 | `main` 最新提交；点 `Build IPA — patched` 时 `Use workflow from` 选 `main`、**`ipa_url` 留空**（本机没有 `gh`，得你点） |
| 自检 | ✅ 六条全绿（orion / brace / member / string / l10n en / l10n zh-CN，全 exit 0） |
| 一句话 | **两条都有动作**：标签栏把系统玻璃摆成"自绘胶囊那一块"并**把触摸交给系统栏 + 转发点击**；Premium 那条**只加了取证日志**（`patchType` + 账号档位）—— 中途那版"服务端说 premium 就不下伪装"的闸门**已撤**（前提被用户否掉，见 §1.2）。**这一版一行都没上过机器**，验收见 §4 |

---

## 1. 用户这两句话，我是怎么判读的

### 1.1 标签栏（第一条）

原话拆成三条要求：

| 用户说 | 判读 | 落地 |
|---|---|---|
| 「系统的液态玻璃和**原本自己做的尺寸不一样**」 | 系统那条浮岛玻璃（≈62pt、比我们的低 6pt）与**我们自绘的胶囊**（360×60、贴图标行）不是同一个框 —— 而迷你播放条那条胶囊是照自绘那份几何做的（用户 2026-10-02 拍板"两条等高"），所以眼睛一看就不齐 | 给系统栏加**宿主**，把宿主摆成 `TabBarGlassPlate.targetCapsuleRect(in:)` 算出来的那一块（**几何判据只有那一份**） |
| 「**你和自绘的对齐就行**」（我问过之后他的答案） | 明确：**以自绘那份为准**，不是反过来 | 同上；系统玻璃的真实 frame 每拍打进日志，偏差用实测数字收敛 |
| 「液态玻璃不是**胶囊套胶囊**吗，**里面那个胶囊不可用手划动**」 | 用户看到的就是 dump 里的真实结构（`_UITabBarPlatterView` + `_UILiquidLensView` + `_UITabSelectionView`）；"划不动"的根因是**第一片故意不吃触摸**（`isUserInteractionEnabled = false`）—— §8.5 明写那是第二片 | 系统栏**接管触摸** + 选中的那颗**转发**成对 Spotify 那一颗的点击（照 pw 的做法，三条退路） |

### 1.2 Premium 那条（第二条）——**第一版读错了，已纠正**

**用户 2026-10-12 的追问：「但是我没真会员啊」** ⇒ 我第一版的推理（"他可能是真订阅账号，
被我们的伪装盖坏了"）**前提不成立，已撤**（见 §3）。

在**免费号**这个前提下，那句 A/B 只有一种读法：

> **灰 / 放不动 = 「不启用 Premium 补丁」（= 不打补丁）那一档** —— 而**免费号本来就是这样**：
> 不打补丁 = 原样免费档 = 歌单发灰、不能点播。
> 用户原话「把不启用 Premium 补丁**关掉**之后，就没这个问题了」正是这个意思：
> **关掉那颗开关 = 恢复打补丁 = 又能放了**。
>
> ⚠️ 我第二轮问的那两个选项，他选的是"反过来"（不打补丁正常、打补丁才灰）—— 与上面**互相矛盾**。
> 以"我没有真会员"为准：免费号不存在"不打补丁还正常"的世界，所以取上面这一种读法。
> （这也解释了为什么他第一句和选项会对不上：那两个选项是我写拧了。）

**⇒ 这一条不构成"我们改账号态的 bug"**：它只是那颗开关的正常语义（关掉伪装，免费号当然就灰）。
而它真正有价值的地方在于：**库里那些"突然发灰 / 歌曲消失 / 只显示一部分"的现场，
都属于"伪装没生效"的那一档**。所以要查的不是"伪装做了什么"，而是 ——
**为什么有时候伪装没生效**。仓库在这条线上已经备好两支：

| 支 | 状态 |
|---|---|
| `SESSION_2026-10-12_NIGHT.md` §9.2：冷启动第一个 customize 常回 **304 且没有 body** ⇒ 交不出配置 ⇒ App 拿到空配置 ⇒ premium/可播放性降级（正是那三个症状）。修法 = customize 快照落盘 + 四处读取补 `?? UserDefaults.cachedCustomizeData`（`01ece12`） | **已经在 `main` 上，但用户装的那一版（日志 63 / 照片 82）没有它** ⇒ **这一版装上就是直接验证** |
| §10：内容请求到底拿到了多少（`playlist/v2` / `metadata/4` / `context-resolve`… 的 URL + 状态 + 字节数） | **还没做**（本轮也没做，先让 §9.2 那一版上机说话） |

**留下的只有取证**（零行为改变）：

| 现在会打的日志 | 判读 |
|---|---|
| `[INIT] patching: patchType=… \| hasPatchedBootstrap=…` | 这次启动在哪一档。`disabled` = 免费号本来就该灰（那颗开关的正常语义）；`requests` = 我们在伪装 |
| `[Premium] the account state on the wire: type=… catalogue=… player-license=…` | **这一行一次都不出现** ⇒ 这次启动**根本没拿到 customize 响应体**（§9.2 的现场，配合 `[DL] customize 304 -> replaying the seed` 一起看）；`type=free` 且后面有 `[Flags] …` ⇒ 伪装链路是通的，症状往 §10 查 |
| `[REVERT_WATCH][init] … subscription-enddate=…` | 仍等于"那次启动 + 1 年" ⇒ 伪装落地了（免费号在 `requests` 档下就该是这个值） |

---

## 2. 这一轮改了什么（标签栏）

### 2.1 几何：**判据只留一份**（`TabBarGlass.x.swift`）

- 把原来写在 `apply` 里的"宽 / 高 / 位置"整块抽成 **`TabBarGlassPlate.capsuleRect(in:band:)`**
  （真机值：宽 `min(栏宽−16, 带子宽+44×2)` = **360**、高 `GlassCapsule.height` = **60**、以 `band.midY` 为心）。
- 新增 **`TabBarGlassPlate.targetCapsuleRect(in:)`**：给系统玻璃那条路用 ——
  同一套 `measure` / `tightenOffsets` / `isUsable`，**不画任何东西**；几何不可信时返回 `nil`（那一次按兜底摆，下一拍再来）。

### 2.2 系统栏（`TabBarSystemGlass.x.swift`）

| 改什么 | 怎么做 | 为什么 |
|---|---|---|
| **宿主视图** `TabBarSystemGlassHost` | 系统栏住进宿主；宿主 `safeAreaInsets.bottom/top` **报 0** | UIKit 的浮岛玻璃**按所在视图的安全区**量高度（Face ID `max(83, 49+inset)`）⇒ 不这么做，它会留 34pt 给 Home Indicator，内容区只剩 26pt。pw 的 `SGRTabBarHost` 同款 |
| **摆位** `place(_:in:)` | 宿主 frame = `targetCapsuleRect`（拿不到就退回整条栏，**绝不藏起来**） | 用户要求"和自绘对齐" |
| **接管触摸** | `isUserInteractionEnabled = true` + `delegate = TabBarSystemGlassRelay` | "果冻 / 可划动"的前提（第一片不吃触摸） |
| **转发点击** | `didSelectItem` → `forwardSelection`：① 读那颗 item 子树里 **tap 识别器自己的 target/action** 并触发（`_targets`/`_target`/`_action` 私有 ivar —— **pw 就是这么干的**）→ ② `accessibilityActivate()` → ③ `UIControl.sendActions` | 系统栏在上层且吃触摸 ⇒ 不转发就是"看得见、点不动"那条红线 |
| **收尾** | 转发后 **0.25s** 再 `reapply()` | Spotify 晚一点才重画标签颜色（我们唯一的选中态信号），那一刻气泡要跟着走（pw 同款） |
| **日志** | ① `tap on #N forwarded … route …`（前 3 次）② 三条路都不通时把子树里的识别器 / UIControl **全列出来** ③ `glass geometry — host … ; system bar … ; drawn [ … ]` | ①/② 让"转发到底通没通"下一份日志直接有答案；③ 因为**我们给的框 ≠ UIKit 画出来的框**，只有实测能收敛 |

⚠️ 宿主只有那一块（≈360×60）⇒ **玻璃以外的区域照旧落到 Spotify 的栏上**，那里行为一个字没变。

---

## 3. 这一轮改了什么（Premium 那条）

| 位置 | 改动 |
|---|---|
| `Premium/Helpers/ServerSidedFeaturePolicy.swift` | 新增 **`shouldSpoofPremium(_:)`**（**判据只此一处**）：`type == premium` **且**（`catalogue` 或 `player-license` == premium）⇒ **不下伪装**；空 attributes（随包快照那一次）用**上次记住的**结论。附 `reportPremiumDecision`：结论**只在翻转时报一行** |
| `Shared/.../UserDefaults+Extension.swift` | 新增 `serverSaidPremium`（键 `eeveeServerSaidPremium`，**刻意不进 `ownedKeys`** —— 它是缓存不是设置，与 `cachedCustomizeData` 同一条纪律） |
| `Premium/DynamicPremium+ModifyingFunctions.swift` | `modifyRemoteConfiguration` 里那个 `modifyAttributes(&configuration.attributes.accountAttributes)` **加了闸门**（读的是**改写之前**的 attributes）；**flag 替换照旧跑**（歌词入口、广告 flag、up-sell 卡片……那是用户要的功能，与档位无关） |
| `Tweak.x.swift` | 新增一行启动日志（**以前完全没有**）：`[INIT] patching: patchType=… \| hasPatchedBootstrap=… \| the server last said premium=…` |

**为什么连"随包快照"那一次也要管**：`SpotifyResponsePatcher.seedCustomizeDataIfNeeded()` 是在**网络之前**
组装种子的，那一次还没见过账号态 —— 不记住上一次的结论，冷启动第一个 customize 回 304 时
交出去的种子又是"伪装过的"，真订阅账号在那一段里照样是坏的（用户报的"**退出重进之后**发灰"正是这一档）。

---

## 4. ★ 装机验收（下一轮照这张单子，一条一张照片）

先点一次 `Actions → Build IPA — patched`（`ipa_url` 留空）；**它红了就先修编译，别的都别验**。

| # | 怎么做 | 应该看到 | 日志判据 |
|---|---|---|---|
| ① | 看标签栏那条玻璃 | 与**迷你播放条那条胶囊**左右边、高度**对齐**（不再一高一低） | `[TabBarSystem] glass geometry — host …,0,361,60 ; system bar … ; drawn [ … ]` ← **把这一行发我** |
| ② | 手指按住某颗图标、左右划 | 有"按下回弹/果冻"；划过的过程里气泡跟着动 | —— |
| ③ | **四颗挨个点一遍** | **每一颗都能切页**（这是"接管触摸"的代价，必须验） | `[TabBarSystem] tap on #N forwarded to Spotify — route … (forward #N)`；**出现 `⚠️ … found nothing to forward to` 就把那一行发我**（里面列了子树里的识别器） |
| ④ | 点**当前已经选中的那一颗**（例如已经在主页再点主页） | 还是能"回到顶部/重选"（`didSelectItem` 对已选中项也会来） | 同上 |
| ⑤ | 关掉「标签栏改用系统玻璃」 | 回到自绘胶囊，且**尺寸与迷你条依旧对齐** | `[TabBarSystem] system bar removed (reason=switch off)` |
| ⑥ | Premium：**保持"不启用 Premium 补丁"关着**（= 打补丁那一档，也是出厂默认）用一会儿 | 歌能放、歌单不发灰 | `[INIT] patching: patchType=requests …` |
| ⑦ | **同一次日志里**找取证行 | 有 `[Premium] the account state on the wire: …` | `type=free` ⇒ 正常（免费号）；**这一行整份日志里一次都没有** ⇒ 这次启动根本没拿到 customize 响应体 ⇒ 把整段日志发我（§9.2 那条线） |
| ⑧ | 把「不启用 Premium 补丁」**打开**再重启一次（可选，只为复核那颗开关的语义） | 免费号在这一档**本来就该灰、该放不动** | `patchType=disabled` —— 这一档的灰**不是 bug**，别当症状报 |

**下一份日志我要的就是这两行**（其余照旧）：
`[TabBarSystem] glass geometry — …` 与 `[INIT] patching: patchType=… | hasPatchedBootstrap=…`。

---

## 5. 本轮的提交（都在 `main`）

1. `feat(tabbar)`（`331affb`）：胶囊几何抽成唯一一份（`TabBarGlassPlate.capsuleRect` / `targetCapsuleRect`）
   + 系统玻璃按它摆位（宿主 + 安全区归零）+ `glass geometry` 日志
   + 系统栏**接管触摸**并把选中的那一颗转发成对 Spotify 那一颗的点击（三条退路 + 前 3 次报路由）
   —— 两件事同属"第二片"，落在同一批文件里（`TabBarGlass.x.swift` + `TabBarSystemGlass.x.swift`），所以合成一笔
2. `fix(premium)`（`7a4fd5a`）：~~账号本来就是真 Premium 时不下伪装~~ + `patchType` 启动日志
   —— **闸门前提被用户否掉（他没真会员），已由第 4 笔撤掉**；留档是为了"别再走这条推理"
3. `docs(handoff)`（`26efe02`）：本文（初版）
4. `fix(premium)`（本笔）：**撤掉那道闸门**（`shouldSpoofPremium` / `UserDefaults.serverSaidPremium` 全删，
   `modifyAttributes` 恢复无条件执行）+ 换成**只记不改**的取证行
   `[Premium] the account state on the wire: type=… catalogue=… player-license=…` + 更正本文
5. `fix(tabbar)`（编译修复，用户报回）：`TabBarGlass.x.swift` 里 `let radius = height / 2`
   还在用**已经被抽进 `capsuleRect` 的局部 `height`** ⇒ 改 `target.height / 2`；
   `TabBarSystemGlassRelay` 的 delegate 方法名写成 `tabBar(_:didSelectItem:)`（旧签名，Swift 3 起改名）
   ⇒ `tabBar(_:didSelect:)`

---

## 6. 未验证声明（**不要删这一段**）

* **本轮的源码改动，一行都没在真机上跑过。** 本机**没有 Swift 工具链**，"能编译"只有 CI 能回答；
  六条自检**不做类型检查**（它们只查 hook 目标名、括号、成员、字符串与 l10n）。
* **本机没有 Swift 工具链 ⇒ 六条自检抓不到类型错误，这一轮的两条就是编译器抓回来的**
  （用户 2026-10-12 报回，见 §5 第 5 笔）。以后抽函数/改签名之后，**必须**至少核一遍
  "被抽走的局部量还有没有别处引用"（`grep` 一下旧名字）与"UIKit 协议方法在 Swift 里的**现代**名字"
  （旧签名会被直接当 error 拦：`tabBar(_:didSelectItem:)` → `tabBar(_:didSelect:)`）。
* **系统玻璃的实际尺寸还是推的**：`_UITabBarItemPlatterView` / `_UILiquidLensView` 在 dump 里是
  `54x0`（那一刻还没排完），pw 的注释说"玻璃条要 83、platter 占它顶上 62" ⇒ 我按"宿主给它 360×60"
  摆，**UIKit 会不会照这个框画、还是按自己的内边距画**只有真机知道。
  所以 ①的日志里我把**宿主框 / 系统栏框 / 玻璃自己那几块**放在同一行 —— 有偏差就是一次减法的事。
* **`_targets` / `_target` / `_action` 是私有 ivar**（照 pw 的 `TabBar.x:139-158`）。
  Spotify 换实现就会失效 —— 失效时**日志里会有一行把子树里的识别器全列出来**，不是静默死掉。
* **转发这条路"点得动"只在 pw 上被验证过**；我们的三条退路哪条会先命中**没验过**。
  万一 ③ 出问题：**先把「标签栏改用系统玻璃」关掉**就回到第一片的行为（那一版点击是落回 Spotify 栏上的）。
* **Premium 那条现在只剩取证，没有任何行为改变**（第 4 笔）。第一版那道闸门之所以撤，
  是因为它的前提（"用户可能是真订阅"）被用户直接否掉 —— 记在这里当作一条教训：
  **同一个信号（`type`）在两个前提下的结论完全相反，别拿"可能性"当判据去改行为**。
* **本轮没有动"伪装怎么改"的任何一行**（`modifyAttributes` 一个字没改）：
  §9.2 那条（304 无 body ⇒ 交不出配置）**已经修在 `main` 上、而用户装的版本没有它** ——
  这才是"为什么有时候伪装没生效"的第一顺位嫌疑，装上即验。
* **`[Premium] the account state on the wire` 这一行会不会出现，取决于 customize 到底有没有 body**
  —— 它本身就是 §9.2 的判据之一；如果整份日志里一次都没有，那就是现场。

---

## 7. 仍然挂着的（用户已说"碰到再说"的排在后面）

§4 那张表与 [`SESSION_2026-10-12_NIGHT.md`](SESSION_2026-10-12_NIGHT.md) §4 完全一致，仍然是这十件：
SponsorBlock 看不到播放状态 / 短歌当前行居中 / 旧 UIKit 逐词层没有罗马字 / 罗马化三个键的字面量散在 4 处 /
额外换行 / iOS 16.1–18 的覆盖 / 「更好的逐词歌词」在 26 以下该置灰 / 兼容性自检 / `[PLAYER]` 探针的 `isPaused` / 文档债。

**外加本轮新增两条**：

| # | 事 | 现状 |
|---|---|---|
| 11 | **系统玻璃的"可划动"到底做到哪一步** | 本轮只做到"接管触摸 + 转发点击"。UIKit 自己会不会在**按住拖动**时让 platter 跟手，只有真机能回答（②那条）。要"像果冻一样能拖"，可能还得照 pw 那样自己读手势 —— **先看 ② 的结果再决定** |
| 12 | **页面计划**（先音乐库、再歌单，`SESSION_2026-10-12_NIGHT.md` §3.1） | 用户**仍未拍板**。这两条标签栏/Premium 完事之后就该问一次 |

---

## 9. ★★ 第四轮（照片 86/87 + 日志 65）：图标、划动、反应、主页标题

用户原话：「液态玻璃**不可以用手划动**，并且**反应时间有点慢**。而且**图标偏移位置，图标几乎看不见**。
主页上的 **主页两个字会偏上**」。

### 9.1 日志 65 一句话就把标签栏的处境说清了

```
[TabBarSystem] system bar added … — in a host that reports no bottom safe area;
                leaving the touches to Spotify's own bar (no forwarding route found, so tapping behaves exactly as before)
[TabBarSystem] items synced — 4 item(s); icons ["N", "N", "N", "N"]
[TabBarSystem] glass insets measured once — left 21 right 21 top 0 bottom 21
[TabBarSystem] glass geometry — host 6,-3,402,81 … drawn [_UITabBarItemPlatterView=27,-3,360,60 …]   ← 尺寸修好了 ✓
```
⇒ 尺寸那一半**已经对了**（玻璃 = 360×60，与自绘胶囊对齐）；剩下三件事：
**没接管触摸**（`canForwardTaps` 判 false）⇒ 只能靠 0.5s 节拍追选中态（"慢"）、手势压根没到我们手里（"划不动"）；
**图标一个都没拿到**（`icons ["N",…]`）⇒ 原图标留在玻璃底下（暗）+ 我们那几颗只剩文字（"偏"）。

### 9.2 图标：这一版的图标**不是 `UIImageView`**

真机树：`16.OBJC_ONLY_IconView@40,5,24,24,id=Encore.IconView`（Encore 自己画的）。
只找 `UIImageView.image` **永远拿不到**（前两版都栽在这）。
照 pw（`TabBar.x:76-133` 的 `renderLayer`）补一条：**找类名含 `IconView` 的那颗视图，把它的 layer 渲染成
UIImage**（按视图缓存；必须在"藏原图标"之前做）⇒ 交回 UIKit 当模板图用（`.alwaysTemplate` 自己上色）。

### 9.3 划动 + 反应：把两只**不抢触摸**的手势装到 Spotify 那条栏上

- `UITapGestureRecognizer`（`cancelsTouchesInView = false`）：点击照旧由 Spotify 完成（**唯一被真机证明能换页的路**），
  我们**同时**知道点了哪一颗 ⇒ **气泡立刻对过去**（不再等 0.5s 节拍）＝ 修"反应慢"。
- `UIPanGestureRecognizer`（`cancelsTouchesInView = true`）：**滑过哪一格就切到哪一格**，气泡实时跟手 ＝ 修"划不动"。
  `true` 是故意的：pan 只在真拖动时 recognize（点一下不 recognize）⇒ 不影响点击，却能**取消**那次触摸，
  免得松手时又触发"按下时那一颗"的点击、把划动结果顶回去。
- 划动要**真的换页**得有提交路（`commitSelection`）：① `UITabBarController.selectedIndex`（公开）；
  ② 容器自己的 `setSelectedViewController:` —— **不是猜签名**，pw 在 `TabBar.x:466-474` hook 的就是它，
  参数是一个 `UIViewController`，传 `children[index]`。没有提交路就**不装 pan**（只动气泡不换页 = 骗人）。

### 9.4 为什么"没有转发路"这句话上一版说不清（已修）

`canForwardTaps` 只有一句 `no forwarding route found`，而它背后有三个完全不同的原因。
现在 `refreshCommitRoute` 会分开报：**没有容器** / **容器不是 UITabBarController**（连带 children 数量、
是否响应 `setSelectedViewController:`）/ **就是它**。下一份日志能直接定位。

### 9.5 主页那两个字偏上：**改成都跟头像一条中线**，并把日志补回来

- 日志 65 里**一条 `[Home] header …` 都没有** —— 而树里 `18.LeadingFadeMaskView@0,1,366,32,alpha=0.00`
  （x 从 48 被翻成 0 = RTL 生效、alpha 0 = pills 收掉）说明**代码其实跑了**。
  原因：那一行里嵌了**转义双引号**、还带 `header.window != nil` 这个条件 —— 两个都不留（见代码注释）。
- 位置：标题的**垂直中线改成对齐头像那一颗**（`face.midY`；拿不到头像才退回那一行），
  这是"看得见的那一行"的判据。日志里现在会打出 **title / row / avatar / header 四个 frame**，
  下一份日志直接能看出还差多少。

### 9.6 这一轮的验收

| # | 应该看到 | 日志判据 |
|---|---|---|
| A | 四颗图标**正常显示、不再偏、不再暗** | `[TabBarSystem] icon taken from … at 24,24 — read as a snapshot of its layer, because this build draws icons itself` |
| B | 点一下标签：**气泡立刻动**（不再半秒后） | `bubble mirrored straight away — #N (a tap on Spotify's own bar; no waiting for the 0.5s tick)` |
| C | **按住划**：滑过哪一格就切哪一格、气泡跟手 | `drag installed on Spotify's own bar …` + `drag is possible — …`；划动时每次 `bubble mirrored …` |
| D | 若划不动：日志会**直接说为什么** | `drag stays off — no TabBarContainerImpl …` 或 `… container X, is a UITabBarController: …, children: …, answers setSelectedViewController: …` |
| E | 主页「主页」与右上头像**一条中线** | `[Home] header restyled — title 主页 at 32pt, frame …; row …; avatar …; header …` |

---

## 8. 下一轮最容易踩的三件事

1. **系统栏现在吃触摸了** ⇒ ③ 那条（四颗挨个点）**必须先验**：转发要是哪一颗不通，那一颗就是"看得见、点不动"。
   真出问题**先关开关**（回到第一片行为），把日志里 `⚠️ … found nothing to forward to` 那一行发我。
2. **Premium 那条的结论已经改了两次，别再凭"可能性"改行为**：第一版那道闸门就是教训
   （同一个 `type` 信号，在"真订阅"与"免费号"两个前提下的结论完全相反）。现在的立场是：
   **不动 `modifyAttributes` 一个字**，先让 §9.2 那支（`01ece12`，用户装的版本还没有）上机说话；
   下一份日志里 `[Premium] the account state on the wire` **有没有出现**就是第一判据。
3. **「不启用 Premium 补丁」那一档的灰不是 bug**（免费号的正常语义）。用户下次报"灰"时，
   先问/先看 `patchType` 在哪一档，别又把那颗开关的正常行为当成症状去修。
4. **几何判据只有一份**（`TabBarGlassPlate.capsuleRect`）：以后要调胶囊尺寸（宽/高/位置），
   **只改那一处** —— 迷你播放条与系统玻璃两条都会跟着走（这正是用户 2026-10-02 定下的规矩）。
