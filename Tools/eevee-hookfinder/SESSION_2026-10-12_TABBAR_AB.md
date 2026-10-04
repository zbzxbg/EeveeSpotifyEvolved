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
| 一句话 | **两条都改了**：标签栏把系统玻璃摆成"自绘胶囊那一块"并**把触摸交给系统栏 + 转发点击**；Premium 那条加了**"账号本来就是真 Premium 就不下伪装"**的闸门 + 三行判据日志。**这一版一行都没上过机器**，验收见 §4 |

---

## 1. 用户这两句话，我是怎么判读的

### 1.1 标签栏（第一条）

原话拆成三条要求：

| 用户说 | 判读 | 落地 |
|---|---|---|
| 「系统的液态玻璃和**原本自己做的尺寸不一样**」 | 系统那条浮岛玻璃（≈62pt、比我们的低 6pt）与**我们自绘的胶囊**（360×60、贴图标行）不是同一个框 —— 而迷你播放条那条胶囊是照自绘那份几何做的（用户 2026-10-02 拍板"两条等高"），所以眼睛一看就不齐 | 给系统栏加**宿主**，把宿主摆成 `TabBarGlassPlate.targetCapsuleRect(in:)` 算出来的那一块（**几何判据只有那一份**） |
| 「**你和自绘的对齐就行**」（我问过之后他的答案） | 明确：**以自绘那份为准**，不是反过来 | 同上；系统玻璃的真实 frame 每拍打进日志，偏差用实测数字收敛 |
| 「液态玻璃不是**胶囊套胶囊**吗，**里面那个胶囊不可用手划动**」 | 用户看到的就是 dump 里的真实结构（`_UITabBarPlatterView` + `_UILiquidLensView` + `_UITabSelectionView`）；"划不动"的根因是**第一片故意不吃触摸**（`isUserInteractionEnabled = false`）—— §8.5 明写那是第二片 | 系统栏**接管触摸** + 选中的那颗**转发**成对 Spotify 那一颗的点击（照 pw 的做法，三条退路） |

### 1.2 Premium 那条（第二条）——**A/B 的方向**

- A（清空全部 flag 覆盖）：**无关** ✓（用户原话）。
- B：用户选的是「**反过来：不启用 Premium 补丁时正常，打了补丁才灰**」
  ⇒ 症状落在 **`patchType == .requests`（我们改写账号态）**这一层，不是 flag 覆盖那一层。

**三条佐证（都在仓库/日志里，不是猜的）**：

1. `EeveePremiumForce.x.swift:88` 早就写过同一个现象：
   *"Over-seeding caused greyed-out tracks (streaming-rules mismatch)"* ——
   而 `modifyAttributes` 现在**仍然**把 `streaming-rules` 清成空串、
   把 `subscription-enddate` / `product-expiry` 改成"一年后"（见 `DynamicPremium+ModifyingFunctions.swift:857-875`）。
2. 全部 30 多份日志里每条 `[REVERT_WATCH][init]` 的 `subscription-enddate` **都等于"那次启动 + 1 年"**
   （例：日志 62 07:16:50 → `2027-10-04T07:16:39Z`；日志 63 08:26:17 → `2027-10-04T08:25:41Z`）
   ⇒ 服务端不可能每次会话都改订阅到期日 ⇒ **那份 product state 里已经有我们的伪装**
   ⇒ 这些会话里 `patchType` 一直是 `.requests`（而"灰"就发生在这一档里）。
3. 上游那条 `have_premium_popup`（"你本来就是真 Premium，那就不打补丁"）用的**就是**这个信号
   （`DynamicPremium+ModifyBootstrap.x.swift:71-84` 读 bootstrap 的 `attributes["type"]`），
   但它**只在 `patchType == .notSet` 的那一瞬间**看一眼 —— 而那条路在本机**从未触发**
   （全部日志里 `[BOOTSTRAP]` **零命中**）⇒ 真订阅账号每次都被照盖不误。

⚠️ **这一条是"实证 + 推理"，不是定论**：我手上**没有**"账号到底是真 Premium 还是免费档"
的直接判据（所有日志里的那些 premium 字段都可能是我们自己写的）。所以本轮**不下结论、先把判据补上**，
而且闸门做成"**两种世界都安全**"：
→ 服务端说 premium 就一个字段都不改（真订阅得救）；服务端说 free 就照旧伪装（免费档行为一个字没变）。

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
| ⑥ | Premium：**保持"不启用 Premium 补丁"关着**（= 打补丁那一档）用一会儿 | 歌单**不再发灰**、歌能放 | `[INIT] patching: patchType=requests …`、`[Premium] no spoof — the account is already premium …` |
| ⑦ | 同一次日志里看 `[REVERT_WATCH][init]` | `subscription-enddate` **不再等于"一年后"**（真值两次启动不会变） | 这一条是**用户账号到底是不是真订阅**的判据 |
| ⑧ | 只想复核免费档那条老路没坏 | 如果你是免费档：伪装照旧 | `[Premium] spoofing the account attributes … (from the live payload (type=free …))` |

**下一份日志我要的就是这两行**（其余照旧）：
`[TabBarSystem] glass geometry — …` 与 `[INIT] patching: patchType=… | … | the server last said premium=…`。

---

## 5. 本轮的三笔提交（都在 `main`）

1. `feat(tabbar)`：胶囊几何抽成唯一一份（`TabBarGlassPlate.capsuleRect` / `targetCapsuleRect`）
   + 系统玻璃按它摆位（宿主 + 安全区归零）+ `glass geometry` 日志
   + 系统栏**接管触摸**并把选中的那一颗转发成对 Spotify 那一颗的点击（三条退路 + 前 3 次报路由）
   —— 两件事同属"第二片"，落在同一批文件里（`TabBarGlass.x.swift` + `TabBarSystemGlass.x.swift`），所以合成一笔
2. `fix(premium)`：账号本来就是真 Premium 时**不下伪装**（判据 `shouldSpoofPremium`，跨启动记住）
   + `patchType` 启动日志（`ServerSidedFeaturePolicy` / `UserDefaults+Extension` / `+ModifyingFunctions` / `Tweak.x`）
3. `docs(handoff)`：本文

---

## 6. 未验证声明（**不要删这一段**）

* **本轮 6 个源码文件，一行都没在真机上跑过。** 本机**没有 Swift 工具链**，"能编译"只有 CI 能回答；
  六条自检**不做类型检查**（它们只查 hook 目标名、括号、成员、字符串与 l10n）。
* **系统玻璃的实际尺寸还是推的**：`_UITabBarItemPlatterView` / `_UILiquidLensView` 在 dump 里是
  `54x0`（那一刻还没排完），pw 的注释说"玻璃条要 83、platter 占它顶上 62" ⇒ 我按"宿主给它 360×60"
  摆，**UIKit 会不会照这个框画、还是按自己的内边距画**只有真机知道。
  所以 ①的日志里我把**宿主框 / 系统栏框 / 玻璃自己那几块**放在同一行 —— 有偏差就是一次减法的事。
* **`_targets` / `_target` / `_action` 是私有 ivar**（照 pw 的 `TabBar.x:139-158`）。
  Spotify 换实现就会失效 —— 失效时**日志里会有一行把子树里的识别器全列出来**，不是静默死掉。
* **转发这条路"点得动"只在 pw 上被验证过**；我们的三条退路哪条会先命中**没验过**。
  万一 ③ 出问题：**先把「标签栏改用系统玻璃」关掉**就回到第一片的行为（那一版点击是落回 Spotify 栏上的）。
* **Premium 那条是"实证 + 推理"**：`[REVERT_WATCH]` 的日期每次都变（实证）、
  `EeveePremiumForce:88` 的老账（实证）、上游同一个信号（实证）；
  但**"账号是不是真 Premium"没有直接判据** ⇒ 闸门写成两边都安全，并靠 §4 ⑦ 那一行定案。
* **闸门只跳"账号态伪装"这一块**：`enable-crossfade-product-state` / `mixing-tools` /
  `your-library-tags` / `libspotify` / `loudness-levels` 这些**也在 `modifyAttributes` 里**
  ⇒ 真订阅账号这一版会**少收到**它们（服务端本来大概率就给了，但没验过）。
  若出现"某个 premium 功能不见了"，把 `shouldSpoofPremium` 的用法从"整块跳过"改成"只跳过 tier 那几个键"即可（一处、可回滚）。

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

## 8. 下一轮最容易踩的三件事

1. **系统栏现在吃触摸了** ⇒ ③ 那条（四颗挨个点）**必须先验**：转发要是哪一颗不通，那一颗就是"看得见、点不动"。
   真出问题**先关开关**（回到第一片行为），把日志里 `⚠️ … found nothing to forward to` 那一行发我。
2. **Premium 那条别当定论**：这一版只是"服务端说 premium 就不动它"。日志里那两行（§4 ⑦）到了再决定
   要不要把闸门收窄成"只跳过 tier 那几个键"。**别在同一轮里再动 `modifyAttributes` 别的部分**。
3. **几何判据只有一份**（`TabBarGlassPlate.capsuleRect`）：以后要调胶囊尺寸（宽/高/位置），
   **只改那一处** —— 迷你播放条与系统玻璃两条都会跟着走（这正是用户 2026-10-02 定下的规矩）。
