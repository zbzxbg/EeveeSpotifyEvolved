# SESSION_2026-10-06_HANDOFF — 听歌页这一轮（日志 48 / 49 之后）：现状 · 干了什么 · 下一步 · 规矩

> 🆕 **2026-10-07：这一批已经真机跑过了（日志 50）。判决、根因与收口见
> [`SESSION_2026-10-07_HANDOFF.md`](SESSION_2026-10-07_HANDOFF.md)（最新入口，自包含）。**
> 本文件只当**那一批的历史清单**读，下面这三处**已被证伪 / 已作废**：
>
> * ⚠️ **§3.4 ② 作废**：`pinned … (time 2)` **不是**"有东西在每按一次被重建" ——
>   上一首与下一首**共用同一个类** `_TtCCE16Encore_ButtonKitO16EncoreFoundation6Encore6Button8Tertiary`，
>   所以 `time 1` / `time 2` 是**两颗不同的按钮**。**判据必须落在 `accessibilityIdentifier` 上，
>   不能落在类名上**（日志 51 起那一行会带 `id=`）。
> * ⚠️ **§3.3 里"`[NPVTree] … MixedPlayButtonDecorationView` 不带 `alpha=` ⇒ 钉生效"不成立**：
>   转储器读的是**模型值**（`ViewTreeDumper.swift` 打的是 `view.frame` / `view.alpha`），
>   而钉只动**呈现层** ⇒ 那一行**证明不了**钉生效。
> * ⚠️ **§3.3 最后那条 `[NPVPage] … bottom anchor npv.bottomStackView = not found` 是已知问题**，
>   不是本轮回归：日志 40/41/42/43/48/49/50 **七次同形**，是"进页面那一刻那一坨还没建出来"的时序问题
>   （日志 50 里同一秒稍后的 `[NPVTree] #7` 它就在 `4,558,406,275`）。
>
> ---

> **历史入口**（那一轮的现状与流水）。
> 上一份入口是 [`SESSION_2026-10-05.md`](SESSION_2026-10-05.md) —— 它的 **§8–§13 是本轮的详细流水与取证**
> （逐条日志行、照片逐像素、pw 原文引用都在那儿）；**本文件是它的摘要 + 现状 + 下一步**。
>
> 写作时：**HEAD = `1a626d3`**，工作区干净。
> ⚠️ ★ **这 10 个提交全部「未装机验收过」** —— 最后一次真机是 **日志 49**，对应构建 **`f906512`**。
> 也就是说：**下面 §3 那张单子里的东西，一行都还没在真机上跑过。**
>
> 证据目录：日志 `C:\dsh\ipa\eeveespotify_debug_shared {48,49}.log`；
> 照片 `C:\dsh\else\{49,50,51,52,53}.jpg`；符号表 `C:\dsh\ipa\dump-9.1.88.txt`。
> 文档日期沿用「工作周期」命名（与同目录其它文档一致，不是机器时钟）。

---

## 0. 三十秒现状

| 线 | 状态 |
|---|---|
| **上一版（日志 49）验成了什么** | ✅ 安装健康；✅ pw 的 `uiButtonTapped` **在 9.1.88 上确实存在**，点击钩子装上了；✅ 歌词键**真的点得到**了（`展开`/`收起` 都出现）；✅ `bounce=on` 回归哨兵成立 |
| **上一版没验成的** | ❌ 「点暂停键闪烁」**还在**；❌ 点歌词之后**封面没缩也没藏**，歌词画在整张封面图上（照片 51） |
| **本轮的修法（10 个提交）** | ① 播放键改成**钉整颗按钮**（不再逐层去追）；② 封面动画按 pw 重写成 **transform**；③ 封面图改成**页面开着时就缓存**；④ 歌词键做成**看得见的 44pt 圆键**；⑤ 「一屏」的诊断行补两格只读取证；⑥ 日志**全部英文** + 新增第 6 条自检 |
| **风险最高的一处** | **钉 layer 不写 alpha** 换来了"看不见但碰得到" —— 装机时必须确认**三颗按钮还都能按**（§3.4 ④） |
| **下一个动作** | **构建 + 抓日志 50**（§3 的单子一次问完），别再加新功能 |
| **等用户拍板的一件事** | 「一屏」开着仍能下拉橡皮筋 —— 接受 / 还是自己接管关闭手势（§2.5、§4） |

---

## 1. 这一轮干了什么（10 个提交，按时间倒序）

| # | 提交 | 做了什么 | 依据 |
|---|---|---|---|
| 10 | `1a626d3` | ★ **CI 红了一次**：`noteSkip("…与"藏起原生封面"都做不了…")` 里混进 **ASCII 双引号** ⇒ 字面量被截断。修掉 + **全仓扫同一类错（唯一实例就是它）** + 新增第 6 条自检 `swift_string_check.py` + **日志文案全部英文**（60 条 / 20 个文件） | CI 报错；自检脚本先拿那一行验过 |
| 9 | `3d82e1d` | 封面图**页面开着时就按曲目 id 缓存**（0.3s 复查节拍顺手认），点的时候先用缓存 | 真机树里那张图可能是 `UIImageView(alpha=0.00)` |
| 8 | `bceac59` | ★ 封面动画**按 pw 重写**：容器永远按"Spotify 封面那个大小与位置"布局（`bounds`+`center`），位移**只写 `transform`**；圆角**除以 scale**；阴影挂容器；0.45s 弹簧（阻尼 1）+ `BeginFromCurrentState`；Reduce Motion 不做动画 | pw `PlayerLyrics.x` + `SGRTokens.m` 原文 |
| 7 | `2095aab` | 「一屏」橡皮筋的判读：**pw 刻意保留**；diag 补 `bounces=` / `pan=<delegate 类名>` 两格只读取证 | pw `PlayerScroll.x` 原文 + 日志 49 |
| 6 | `98bad49` | ★ **结构性简化**：把三颗按钮**整层钉住**，字形搬到**按钮的兄弟层**；**删掉**整套逐叶子机制（`hideNativeContent`/`HiddenView`/`alphaKey`/圆盘类名片段/尺寸闸） | 用户澄清：日志 49 的 `1/0/1/0` 是**连点**造成的 |
| 5 | `4215e8e` | 钉 **只动 layer、不写 `alpha`**（渲染看呈现层 ⇒ 看不见；命中看模型值 ⇒ 碰得到）；封面判据**统一到 `visibleCover`**；`layoutAndMount` 返回 Bool（铺不上就不认"已展开"） | 照片 51；独立复核 |
| 4 | `766a160` | 主因改写：闪的是 **crossfade 快照**；播放键那一支取消尺寸闸 + 连 alpha 0 的图形叶子也按住；字形加 `layer.zPosition` | 照片 49 的"残缺横条 + 小点" |
| 3 | `bf02427` | 抄 pw 三处：**点击那一刻就翻字形**（`uiButtonTapped`，**探测再挂**）、**crossfade 快照**处理、**缓冲 spinner 立着时藏字形** | pw `PlayerControls.x` 原文 |
| 2 | `eaf8330` | 文档：日志 48 + 照片 49/50 判读；独立只读复核抓到的 4 条已修 | 日志 48 |
| 1 | `4242c70` | 播放键"换脸"（白圆盘那支**被整棵跳过**）+ 歌词键从**隐形热区**改成**看得见的 44pt 圆键** | 日志 48 + 照片 49/50 |

---

## 2. ★ 硬事实（都带证据，别再重推）

### 2.1 ★★ 三条「我读错了、被用户纠正」—— 这是本轮最大的方法论教训

| 我以为 | 真相 | 为什么会错 |
|---|---|---|
| 照片 49 那颗"白圆盘 + 深色横条"= **原生播放态** | 用户：**那是"快速连点暂停键时截到的"过渡帧** | 我把**过渡帧当成了稳态** |
| 于是推出：**原生稳态是裸字形**，白圆盘只是快照 | 照片 52/53（用户给的"Spotify 自己的暂停键"）：**原生稳态一直是"白圆盘 + 深色字形"，播放/暂停两个状态都是** | 我又**从一个过渡帧反推稳态**，方向反了 |
| 日志 49 的 `本拍把 1 处 / 0 处` 交替 7 秒 = **稳态拉锯**（Spotify 每 0.25s 写回一次） | 用户：**那 7 秒他一直在按暂停键** ⇒ 那是**每按一次多出一层**，不是拉锯 | 我把"没有别的日志"当成了"用户没操作" |

⇒ **写进纪律**：
1. **过渡帧不能当稳态证据。** 截图必须**至少两张同状态的对照**，且附上"当时在做什么"；
2. 拿不到"用户当时在做什么"时，**先问**，不要从日志缺项反推；
3. 一次判读错了之后，**下一条结论要先证伪上一版**，别顺着同一个方向再推一层。

### 2.2 ★★ 「点暂停键闪烁」的真实机理与最终修法

**机理**（日志 49 + 用户澄清）：Spotify 每换一次播放状态，就往播放键里**合成/新建一层新图形**
（pw 原话：*"The holder Spotify crossfades a snapshot of the disc in when play turns to pause."*）。
我们**逐叶子、逐圆盘地去"按回去"，永远慢一拍** —— 新图形不是同一批实例。

**最终修法**（`NowPlayingControlsPlate`）：

| 步骤 | 做法 | 为什么 |
|---|---|---|
| ① | 把 `SPTNowPlayingPlayButton` / `Previous` / `Next` **三颗按钮整个 layer 钉住** | 之后塞多少新图形都**出生即不可见**，那一帧的窗口从根上没有了 |
| ② | 钉**只动 layer、不写 `alpha`** | 渲染看**呈现层**（钉在 0 ⇒ 看不见）；命中判定看**模型值**（没动 ⇒ **按钮照样能按**）。这是播放/暂停还活着的前提 |
| ③ | 我们的字形挂到**按钮的兄弟层**（`button.superview`），每拍按按钮的框重算 | 字形若是按钮的子视图会**跟着被钉没** |
| ④ | 字形加 `layer.zPosition = 1000` | 新层是**后插**的，`bringSubviewToFront` 只在我们跑到的那一拍生效 |
| ⑤ | 新钉住一颗按钮时补一串**位置复核**（0.05/0.15/0.35/0.6s） | 只是让字形跟上按钮前几拍还没稳定的坐标 |

**钉的实现**：`pinInvisible` = 在该视图 layer 上加一条 duration 极长、`isRemovedOnCompletion = false`
的 `opacity` 动画，把**呈现层**钉在 0。**还原 = `removeAnimation(forKey:)`，原生一个字节都没改过。**

> **为什么不用 pw 那套**（`SGRSuppress`：把实例换成运行时子类、覆写 `setAlpha:`）：
> ① 纯公开 API，本机没有编译器，能少一处类型陷阱就少一处；
> ② ★ pw 的 `subclassable()` 是 `strncmp(name,"_Tt",3) != 0 && !strchr(name,'.')`，而我们的
> `MixedPlayButtonDecorationView` 真名是 `_TtC28EncoreConsumerMobile_BaseKit29…`（**`_Tt` 开头**）
> ⇒ 照抄只会得到它自己那句 `cannot keep being suppressed, set once per call`；
> ③ 覆写 `setAlpha:` 会**连带改掉命中判定**（我们最不想要的副作用）。

### 2.3 pw（spoti.pw v0.21.1，GPL-3.0 隔离副本）对照：抄了什么、什么**不能**抄

**抄了**（都写在提交里）：
* **点击那一刻就翻字形** —— `%hook PlayButtonView -uiButtonTapped` + `kTapTrust = 1.2s`。
  理由（pw 原话）：播放器状态比点击**晚一拍**，*"read as a slow button"*。
  我们这边量得到：投影的 `pauseThreshold = 0.35s` **加**一个节拍 ⇒ 最坏 **~0.85s**。
  ★ **`uiButtonTapped` 在 9.1.88 上确认存在**（日志 49 的 `点击钩子已装`），但**仍走"探测再挂"**：
  我们的 `dump-9.1.88.txt` 的 `[selectors]` 桶**连 `layoutSubviews` 都没有**，那份清单证明不了方法在不在。
* **封面动画的形状**（见 §2.4）。
* **缓冲 spinner 立着时把我们的字形藏起来**（否则"缓冲中"会显示一个假字形）。

**不能抄**：
* **它的"认圆盘"判据**：pw 按**几何**认（"按钮里那颗与按钮等大的 `UIImageView`"），因为它的树（9.1.78）是
  `PlayButtonView > CondensedButton(UIButton) > UIImageView 64x64`；而我们 9.1.88 的 `[NPVTree]` 里圆盘是
  **`MixedPlayButtonDecorationView`，与 `CondensedButton` 是兄弟** ⇒ 照抄过去就是它自己那句
  `logMissing(@"the play button's disc")`。**判据永远以我们自己的真机树为准。**
* **它的挂点**：`SPTBarInteractivePresentationController` / `SPTBarOverlayPresentationTransition`
  在 **9.1.88 上不存在**（探针实测缺这 2 个）。
* **它也没解决「一屏」的橡皮筋**（见 §2.5）。

### 2.4 「点歌词，封面往左上变小跑」：动画的形状

**上一版错在动 `frame`** —— 而 `layoutAndMount` **每 0.3s 会重跑一次**（`DeclutterChrome` 的复查节拍），
每一拍都重写封面布局 ⇒ 动画被打断/拽回；而且 `frame` 在 transform 非恒等时**不可信**。

**pw 的形状**（`place()` / `thumbTransform()` / `thumbRadius()` / `SGRTokens.m`）：

| 环节 | 做法 |
|---|---|
| 布局 | 容器**永远**按"Spotify 封面那个大小与位置"布局，用 **`bounds` + `center`**（不是 `frame`） |
| 位移 | **只写 `transform`**：`CGAffineTransformConcat(Scale, Move)` = **先缩放、后平移**（关于自己的中心） |
| 圆角 | ★ **缩放会把圆角一起缩放** ⇒ 缩略图想要"看起来 8pt"，模型值写 **8 / scale** |
| 阴影 | 挂**容器**上（容器不裁剪）⇒ 跟着 transform 走，不用每帧重画 |
| 动画 | pw 的 `SGRMotionLayout`：**0.45s + `usingSpringWithDamping 1`（临界阻尼、不回弹）+ velocity 0**，options = `AllowUserInteraction \| **BeginFromCurrentState**`（后者是**连点两次不跳**的关键） |
| 无障碍 | **Reduce Motion 打开时整段不做动画** |
| 换图那一刻 | *"Spotify's cover goes **the moment** the redesign's own takes its place"* |
| 拿不到图 | *"**the cover stays and the lyrics wait**"* ⇒ **不展开**（与"静默分支不许静默"同源） |

**收起的收尾**（撤我们那张 + 把 Spotify 那条写回）**必须挂在动画 completion 上**，且带令牌
`coverGeneration`：动画没走完又被点开时这次收尾作废。
⚠️ `completion` 在"已经在对的位置"和"Reduce Motion"两条路上**也必须被调用**，否则封面永远撤不掉。
⚠️ **切开关 / 页面消失 = 不动画**（拖着 0.45s 写回，会在转场里露一个"没有封面"的帧）。

### 2.5 ★ 「一屏开着还能像橡皮筋一样往下滑」—— **pw 没解决，是刻意保留的**

pw `PlayerScroll.x` 原文：

> *"the range is closed instead … **A drag upward then only stretches and springs back**, a drag downward
> still carries the offset below zero, and the dismissal is untouched."*

⇒ **那个负的 `contentOffset` 就是下拉关闭的输入。** 去掉回弹 = 去掉负偏移 = **关闭手势没有输入**。
我们真机**已经判死过一次**：日志 41（37 份里唯一的 `bounce=off`）那次就是关掉它去追这最后一点橡皮筋，
结果**播放器再也划不掉**，开关当天删除。
**日志 49 证明"范围"那一半是对的**：`content.h == bounds.h`（896 == 896）⇒ 一点可滚范围都不剩，
用户感到的**纯粹是回弹**。

**三档选择（等用户拍板，别擅自做）**：
* **A. 接受它**（pw 同款，成本 0）—— 只在设置页文案里说清"下拉那一下就是关闭手势本身"；
* **B. 自己接管关闭手势**（独立一轮，风险中高）—— 成了才能把 `bounces` 关掉；
* **C. 只关一端** —— ❌ **不存在**：`UIScrollView` 没有"只关顶部回弹"的公开开关。
（diag 里新加的 `pan=<delegate 类名>` 就是给 B 档铺的只读取证。）

### 2.6 ★ 「转储 customize 响应体」**有用，而且是唯一手段**

链路：开关 → `dumpCustomizeBodyIfEnabled`（在 `patch()` 的 customize 分支里、**任何改写之前**抓，
是**服务端原样那份**；每次启动只抓一次）→ 日志 `[CustomizeBody] base64-begin/end`
→ `bnk_from_customize_dump.py` 剥出 `ResolveConfiguration` 字节 = `.bnk` 种子
→ **`seedCustomizeDataIfNeeded`**（启动时）喂成 `cachedCustomizeData`，专治"冷启动 customize 是 304
没 body ⇒ flag 通道整段不执行"。

**★ 实测：种子是活的，而且现在跑的就是它**（日志 48/49 每次启动）：
`[CustomizeSeed] seed ready resolveconfiguration_9_1_76.bnk — 1089 flags`。
⇒ **§10.9 的"Flag 覆盖是空转的"那条旧结论已经过时**（那是**加种子之前**的）。
★ **但随包那份种子是 9.1.76 时代的**：`BundledConfigurationPolicy` 对 **≥9.1.76 一律**返回
`resolveconfiguration_9_1_76.bnk`，而当前基线是 **9.1.88** ⇒ **该用它刷一次种子了**。

### 2.7 ★ 日志文案**一律英文**（用户 2026-10-05 定的规矩）+ 第 6 条自检

**事故**：`noteSkip("…与"藏起原生封面"都做不了…")` —— 用 ASCII 双引号做强调，第一个引号就把字面量关掉了，
CI 报 `expected ',' separator` / `cannot find … in scope` / `extra argument in call`。
**为什么老自检抓不到**：`swift_brace_check` 只数引号**配平**，那一行 4 个引号（偶数）⇒ 放行。

**三条处理**：
1. 全仓扫了同一类错（判据：**闭合引号后面跟了不能跟的字符**），**唯一的实例就是它**（275 文件 / 45585 行）；
2. 新增 **`Tools/eevee-hookfinder/swift_string_check.py`**（两向验证过：干净仓库 exit 0；那次事故的行 +
   第二种坏形状各抓到 1 处；插值/原始字符串/多行字符串都不误报）⇒ **五条自检变六条**；
3. 日志文案**全部英文**（60 条 / 20 个文件）。**注释保持中文**；`[Tag]`、`\(…)` 插值、`reason=` 这类键、
   数字单位、`accessibilityLabel`、本地化文案**不动**。

⚠️ 后遗症：`SESSION_2026-10-05.md` §8.6/§9.6/§11.5 里那些「预期日志行」是**当时的中文原文**；
**验收以本文件 §3.3 为准**（已换成英文）。

---

## 3. ★ 下一次装机（日志 50）：一次问完

### 3.1 构建 / 设置

* **workflow**：`.github/workflows/build-ipa-with-orion-patched.yml`，`liquid_glass` 保持默认开；
* **调试**：「启用日志记录」+「转储视图树」**都开**（我要 `[NPVTree]`）；
* **扩展功能 → 听歌页，五项全开**：「一屏」/「整页封面取色底」/「底部音量条」/
  **「歌词进播放器」** / **「播放键换成本地字形」**；
* 歌词设置里确认「**更好的逐词歌词**」是**开**（歌词层与那枚键的可用性判据都靠它）。

### 3.2 操作顺序（每步都短）

1. 进听歌页 → **停 5 秒别碰**（先确认它是稳的）；
2. **快连点播放/暂停 10 次以上** ← ★ 本轮主验收点（以前每按一次闪一下）；
3. **点那枚歌词键**（底部那一排**正中间**、Connect 与分享之间的圆键）→ 期望：封面**从原位置平滑缩到
   左上角 72pt**、标题挪到它右边、歌词在下方淡入，**且封面不再整张露着**；
4. **再点一次**收起 → 封面应当**飞回原位**，之后 Spotify 那条封面**正常显示**；
5. **顺手**：上一首/下一首各点一次（回归）；下拉关闭一次（回归）；停在听歌页 3 秒。

### 3.3 预期日志行（**英文**，照着比）

```
[NPVControls] pinned <类名> (time N)              ← ★ 期望每颗按钮**只出现一次**（time 1）。
                                                   出现 time 2 / time 10 ⇒ 还有东西每按一次被重建
[NPVControls] the three transport buttons now use local glyphs - found 3 button(s), newly pinned 3 this pass
[NPVControls] … found 3 button(s), newly pinned 0 this pass
                                                   ← ★ 连点 10 次期间**应当一直是 0**（钉是一次性的）
[NPVControls] tap hook installed (_TtC28EncoreConsumerMobile_BaseKit14PlayButtonView.uiButtonTapped) - the glyph flips right at the tap, without waiting for player state
[NPVLyrics] lyrics button in place 185,790,44,44 (visible round button; tap to expand/collapse; this track has lyrics)
[NPVLyrics] remembered this track's artwork 366×366 (cache 1/8)
[NPVLyrics] expanded — thumbnail 72pt, lyrics area 20,204,374,346, cover shrunk in from 40,104,334,334
[NPVLyrics] not expanding (no artwork for this track …)      ← 若出现：是**有解释的失败**（封面图还没到）
[NPVTree] #N …MixedPlayButtonDecorationView@0,0,64,64          ← 钉住后它**不带 alpha=** 了（我们改的是呈现层）
[OneScreen] diag inset.bottom=0 content.h=896 bounds.h=896 adj.top=0 adj.bottom=0 bounce=on bounces=on panRecs=3 pan=<delegate 类名>
```

### 3.4 通过 / 失败判据

| # | 判据 | 类型 |
|---|---|---|
| ① | **快连点 10 次不再闪白圆盘** | ★ 本轮主症状 |
| ② | `pinned … (time 1)` 每颗按钮**只报一次**（出现 time 2 ⇒ 还有东西每按一次重建，下一个修法照它开） | 机制 |
| ③ | 点歌词后封面**真的缩成 72pt 且不再整张露着**；收起后**封面正常显示**、**连点两次不跳** | 功能 |
| ④ | ★ **三颗按钮还都能按**（播放/暂停、上一首、下一首）—— 这是「钉 layer 不写 alpha」的关键回归项 | **回归** |
| ⑤ | 开「减弱动态效果」→ 封面**直接到位、不放动画** | 无障碍 |
| ⑥ | 之前已验的不回归：歌词键点得到 / `bounce=on`（`bounce=off` 再出现就说明有人又碰了关闭链条） | 回归 |

**失败判据（要警惕的）**：`pinned … (time 2)` 出现；`newly pinned 1` 在**没换页**的情况下反复出现；
`本拍…`-类日志重新开始抖动；点歌词后**只有 `not expanding` 而没有 `expanded`**（封面图一直取不到）。

### 3.5 这一版**没有**改的东西（别误判成 bug）

* 「一屏」的**橡皮筋还在**（§2.5，是刻意的，pw 同款）；
* **头部/控件/footer 的排版还没动**（还是 Spotify 原来的落点）——「向 kumone 看齐」的排版是**下一轮**；
* 歌词区**没有**从 0.96 放大进场（那个要把容器也改成 transform + `bounds`/`center`）；
* 封面图仍然**从 Spotify 的视图树里抓**（只是提前抓 + 缓存），**不是** pw 那种"自己持有"；
* 随包的 customize 种子**还是 9.1.76 那份**。

---

## 4. 下一步（排序 + 每条的前置证据）

| 序 | 做什么 | 前置 / 判据 | 风险 |
|---|---|---|---|
| **1** | **构建 + 抓日志 50**，按 §3 那张单子验收 | 无（就现在） | —— |
| **2** | 按日志 50 的结果收口：闪烁若仍在 ⇒ 照 `pinned (time 2)` 出现的那**个类名**开刀 | 日志 50 | 低 |
| **3** | **封面改成"自己持有"**：复用仓库既有的 `LyricsArtworkResolver`（它已把 `spotify:image:<hex>` → `https://i.scdn.co/image/<hex>` 走通） | 需要先把 `layoutAndMount` 的**同步返回 Bool** 改成"异步图到了再铺" | 中 |
| **4** | **「一屏」橡皮筋**：用户拍 A / B（§2.5） | 用户决定；B 档先看 diag 的 `pan=<delegate 类名>` | A 低 / B 中高 |
| **5** | ★ **头部 / 控件 / footer 排版向 kumone 看齐** | 三个 `*ElementsUnit` **类都在 9.1.88**（已核）；**手法是「搬 holder 不搬控件」：用 `transform` 平移"装它的那颗 arranged view"** —— 触摸会自动跟着 transform 走，**一行转发代码都不用写** | 中 |
| **6** | **刷新 customize 种子**（9.1.76 → 9.1.88） | 需要一次**真的拿到 body** 的 customize（常态 304）；用本地日志，别用脱敏分享版 | 低 |
| **7** | 歌词区 0.96 放大进场 | 先把容器改成 transform + `bounds`/`center` | 低 |
| **8** | `swift_string_check.py` **接进 CI** | 改 `.github/workflows/`（目前没进） | 低 |

**第 5 条的手法备忘（重要，别再重新推）**：
pw `PlayerFooter.x` 原话 —— *"Connect and the queue **stay Spotify's controls** … and are **only moved, by a
translation of the arranged view that holds each**: a transform survives the stack view laying them out
again, and **moving the holder keeps its touches inside its own bounds**."*
三条必须一起做：① **装配层也吃触摸**（内容 + `arrangedAround(内容)` 一起处理）；
② **移出父 bounds 后 UIKit 不会往里找**（只有跨边界时才需要接回层）；
③ **反向量位置不能读被平移后的 `frame`**（用 `center` + `bounds`）。
④ 补一条 pw 没提的：`transform` **不改 subview 顺序** ⇒ 需要时用 `layer.zPosition`。

---

## 5. 规矩（本轮新增 / 强化，写代码前先过一遍）

1. ★ **日志文案一律英文**；**注释保持中文**。
2. ★ **字符串里绝不用 ASCII 双引号**做强调 —— 中文强调用「」或单引号。**第 6 条自检会抓**。
3. ★ **别人的视图：只钉 `layer`、不写 `alpha`** —— 写了 `alpha` 就**丢掉命中判定**
   （`hitTest` 跳过 `alpha < 0.01` 的视图）。要"看不见但碰得到"就只剩这一条路。
4. ★ **钉"整颗按钮/整个容器"，不要追子层** —— 对方每换一次状态就新建一层，逐层追**永远慢一拍**。
5. ★ **一律 `bounds` + `center`，不用 `frame`**（transform 非恒等时 `frame` 不可信）；
   位置换算用 `convert(_:to:)`。
6. ★ **过渡帧不能当稳态证据**；截图至少两张同状态对照 + 说明"当时在做什么"。
7. **引用外部源码必须写清许可与出处**（pw ≤ v0.21.1 = GPL-3.0 可读可复用；**≥ v0.22.0 = PolyForm，一行不碰**）。
8. **本机自检先跑（现在六条）**：`orion_hook_guard` / `swift_brace_check` / `swift_member_check` /
   **`swift_string_check`** / `l10n_lint --locale en|zh-CN`。
   **新写的检查器必须两向验证**（干净通过 + 已知坏例报错），否则等于一条假绿灯。
9. **静默分支不许静默**：铺不上、量不到、取不到图 —— 都要**打一行原因**并**不留半成品**。
10. **一次装机只验一轮**；未装机的提交别堆太多（本轮已经堆了 10 个，这是上限了）。
11. **独立只读复核**：本机没有编译器，改"动别人视图/布局"的代码时，另派一个只读复核者对着源码推演
    （本轮它抓到 4 条，全已修）。

---

## 6. 文档地图

| 想看什么 | 去哪 |
|---|---|
| **本轮全貌 / 现状 / 下一步 / 规矩** | **本文件** |
| 本轮**详细流水与取证**（日志 48/49 逐行、照片 49–53 逐像素、pw 原文引用） | `SESSION_2026-10-05.md` **§8–§13** |
| 上一轮入口（删「禁止回弹」与双击、转储器定向化、一屏默认开、歌词进播放器） | `SESSION_2026-10-05.md` §0–§7 |
| pw 的移植评估（14 个目标类、一屏算法、依赖面） | `SPOTIPW_0211_PORT_ASSESSMENT.md` |
| pw ↔ 我们的功能缺口 + **许可红线** | `SPOTIPW_GAP.md` |
| kumone 的配方、常量、**照片 40/41 的逐像素量测** | `KUMONE_REFERENCE.md` §5 |
| 歌词线的历史（几十条结论） | `LYRICS_MODULE_NEXT_STEPS.md` |
| 哪些目标类已过时/已删 | `STALE_AUDIT.md` |
| **六条自检脚本** | `orion_hook_guard.py` / `swift_brace_check.py` / `swift_member_check.py` / **`swift_string_check.py`** / `Tools/l10n_lint.py` |

---

## 7. 未验证声明（不要去掉这一段）

* 本轮 **10 个提交全部未装机**。最后一次真机数据是**日志 49**（构建 `f906512`）。
* **本机没有 Swift 工具链，编译只能走 CI。** 上面所有"修好了"都只到"源码层面 + 六条自检 + 骨架比对"
  这一步 —— **没装机之前不算验收**。
* 骨架比对的结论（本轮做过一次）：subagent 翻译的 150 行改动**全部只落在字符串内容上**
  （抹掉字符串后代码骨架逐字相同），改动里唯一的 3 处骨架差异来自我自己的编辑。
