# SESSION_2026-10-07_HANDOFF — 日志 50/51 两轮的判决 · 歌词键两次不同的根因 · 暂停键确诊

> 🆕 **2026-10-07 追加 §10–§11**：**日志 51 的判决**（`HEAD = bcadd25`）。**先读那两节**。
> 一句话：日志 50 那个回归（§1.3）**修对了，但不是这一个症状的根因** ——
> 日志 51 用新判据查到**真正的病根是 `visibleCover()` 挑错了封面**
> （挑中「一屏」折掉的那张卡里的 374×374，`lift` 因此变成 +240 而被否），已在 §10.2 修掉；
> **暂停键同时确诊**（投影单次采样抖动），**H1 被证伪**，见 §10.3。
> §11 回答你追问的两件事（premium 伪装 / 点击封面出现的卡片）。

> **新会话先读这一份**（自包含）。上一份入口是
> [`SESSION_2026-10-06_HANDOFF.md`](SESSION_2026-10-06_HANDOFF.md)（那一轮 10 个未装机提交的清单与纪律）。
>
> 写作时：**§0–§9 写于 `f59b1e6`**（日志 50 判读 + 那一轮改动，**未提交、未装机**）；
> **§10–§11 写于 `bcadd25`**（日志 51 判读 + 又一轮改动，**未提交、未装机**）。
> 证据：日志 `C:\dsh\ipa\eeveespotify_debug_shared {49,50,51}.log`、
> 照片 `C:\dsh\else\{49…53}.jpg`、类名 `C:\dsh\ipa\dump-9.1.88.txt`。
> 对照构建：**`f906512`**（= 日志 49 那个 git 提交，在那一批 10 个提交之前）。

---

## 0. 三十秒现状

| 线 | 状态 |
|---|---|
| **日志 50 是什么** | 上一轮 10 个提交的**第一次真机**。所以"日志 50 判读"= 那一批的验收 |
| **歌词键** | 🔴 **本轮新引入的回归**：`toggle()` 第一次量不到就把 `isOpen` 清掉，而 `reconcile()` 只在 `isOpen` 时重试 ⇒ **一次失败 = 这枚键永久死掉**。日志 49（旧代码）明明**展开成功过两次** |
| **暂停键"一卡一卡的"** | 🟡 **日志 50 里一行判据都没有**。本轮补了三条只读判据；三条候选（钉被盖掉 / 硬切 / 位置跳步）**等你打日志 51 分辨** |
| **判据纠错** | ⚠️ 上一份 §3.4 ② 那条「`pinned (time 2)` ⇒ 有东西在重建」**是错的**（两颗跳转键**共用同一个类名**）。计数必须落在 id 上，本轮已把 id 打进日志 |
| **本轮改了什么** | 两个 Swift 文件（`git diff --stat`：169 + 242 行改动）+ 本文件；六条自检全绿；**未编译**。独立只读复核做过，它抓到我这一轮改出的 3 条缺陷，**全部已修**（§5.3） |
| **⚠️ 这一段已被 §10 更新** | 上面"歌词键是回归"**只是日志 50 那一半**；日志 51 查明**真正的病根是 `visibleCover()` 挑错封面**（§10.2）。两处都改了。 |
| **下一个动作** | **构建 + 抓日志 51**（§6 的单子），别再加新功能 |

---

## 1. ★★ 你报的问题②：点歌词键没反应 —— 确诊，**是一次回归**

### 1.1 先纠正我自己的一个错判（记下来，别再犯）

中途我一度得出「`[NPVLyrics] expanded` 在全部 50 份日志里零命中 ⇒ 这个功能从来没成功过」。
**那是错的。** 原因很蠢也很典型：**日志 49 的日志文案还是中文**
（`[NPVLyrics] 展开 — 缩略图 72pt、歌词区 20,204,374,346、封面从 40,104,334,334 缩过来`），
而英文文案是第 10 个提交 `1a626d3` 才上的 ⇒ 拿英文串去 grep 中文日志，当然零命中。

> **写进纪律**：跨构建 grep 日志，**先确认那一版的语言**（本仓库有过一次全量中英切换）。
> 这正是 `SESSION_2026-10-06_HANDOFF.md` §2.1 第 2 条"不要从日志缺项反推"的同一个坑。

**日志 49 的真实记录**（旧代码，`f906512`）：

```
02:58:40  [NPVLyrics] 歌词键已就位 185,790,44,44（看得见的圆键；点它展开/收起；这一首有词）
02:58:44  [NPVLyrics] 展开 — 缩略图 72pt、歌词区 20,204,374,346、封面从 40,104,334,334 缩过来
02:58:46  [NPVLyrics] 收起（reason=tapped）
02:58:47  [NPVLyrics] 展开 — 缩略图 72pt、歌词区 20,204,374,346、封面从 40,104,334,334 缩过来
02:59:05  [NPVLyrics] 收起（reason=page disappeared）
```

⇒ **点得开、收得起、再点还开得起来。** 日志 49 唯一没验成的是"封面有没有真的缩走"（照片 51）。

### 1.2 日志 50 的真实现场

```
04:34:54  [NPVLyrics] lyrics button in place 185,790,44,44 (visible round button; …)
04:34:54  [NPVLyrics] remembered this track's artwork 366×366 (cache 1/8)
04:34:55  [NPVLyrics] not expanding (cannot measure the artwork area / title row (layout not finished yet?))
04:35:07  [NPVLyrics] lyrics button in place 185,790,44,44 …
```

- 那行 `not expanding` **证明点击确实到达了** —— 唯一能在 `isOpen == false` 时调用
  `layoutAndMount` 的路径就是 `toggle()`；
- 而且**不是**"这首歌没有可用的歌词"那条 ⇒ `canShow()` 过了 ⇒ 歌词数据是好的；
- **整份日志里 `expanded` 一次都没有** ⇒ 这一整轮会话里这枚键**再没活过来**；
- 时间差：键在 `04:34:54` 出现，用户在 **`04:34:55`（1 秒后）**就点了。
  日志 49 那次是 `02:58:40` 出现、`02:58:44`（**4 秒后**）才点。

### 1.3 ★★ 根因：`4215e8e` 那个提交少了一半

**取证（可复现）**：`measure()` 在 `f906512` 与 HEAD 上**逐字节相同** ——

```
git diff f906512..HEAD -- Sources/EeveeSpotify/Appearance/NowPlayingLyricsPlate.swift
```

那段 `private static func measure(in page:)` **没有一行改动**。差别在**调用方**：

| | 旧（`f906512`，日志 49） | 新（`4215e8e` 之后，日志 50） |
|---|---|---|
| `toggle()` | `isOpen = true` → `layoutAndMount(...)`，**不看返回值** | `if !layoutAndMount(...) { isOpen = false }` |
| `reconcile()` | `if isOpen { layoutAndMount(...) ; return true }` —— **每拍都重试** | 同上，但失败后 `isOpen` 已经是 `false` ⇒ **再也不进这一支** |
| `apply()` | `guard isOpen else { return }` → `layoutAndMount(...)` | `if isOpen, !layoutAndMount(...) { isOpen = false }` |

⇒ 旧代码的形状是"**这一拍量不到就下一拍再量**"：日志 49 里用户点得晚一点，第一拍就量到了。
新代码的形状是"**第一次量不到就永久认死**"：日志 50 里用户点早了 1 秒，这枚键就再也没回来。

`4215e8e` 的**本意是对的** —— 别留"标题已经上移、歌词已经画出来、封面还整张露着"的半成品
（照片 51 就是那个现场，pw 也这么取舍：*"the cover stays and the lyrics wait"*）。
它**只是少了另一半**：失败之后要接着试。**本轮补的就是这另一半**（`openAndMount` + 2.5s 窗口）。

### 1.4 顺便修掉的两处（不是本次症状的原因，但确实是缺陷）

| # | 缺陷 | 为什么是缺陷 | 现在 |
|---|---|---|---|
| 1 | `measure()` 把**四种不同的失败**压成同一句话 | 日志 50 那唯一一次点击只留下那一行 ⇒ 事后**分不出**是封面没量到 / 标题行没量到 / 歌词区太矮 / 标题行还没落位。仓库规矩「静默分支不许静默」的变体：一个分支不许盖住四种死法 | 拆成 `MeasureOutcome.ok/failed(reason)`，每种带数字 |
| 2 | `guard stage.height > livingHeight/2, lift < 0` 里的 `lift` **会自毁** | 量不到标题行时 `let lift = top - (rowFrame?.minY ?? top)` **恒等于 0** ⇒ `0 < 0` 不成立 ⇒ **永远拒绝**，报的还是更含糊的那句话 | 只有 `rowFrame != nil` 时才拿 `lift` 当判据；量不到标题行 = 没有要上移的东西 ⇒ **照常展开** |

⚠️ **`rowFrame != nil && lift >= 0` 那一条不能放宽**：日志 50 那次失败极可能就是它
（那一拍 `npv.bottomStackView` 已经在树里但还没落位，`rowFrame.minY ≈ 0` 而 `top > 0`
⇒ `lift > 0`）。把一个还没落位的标题行"上移"到错的地方比不展开更糟 ——
要治的是"下一秒再试一次"，那正是重试窗口干的事。

### 1.5 ★ 另一条**被我证伪**的猜想（留档，别再回去）

我一度推：「`npv.bottomStackView` 是列表的**兄弟**，所以 `measure()` 从 `list` 里永远找不到标题行
⇒ 必然失败」。**这是错的**，日志 49 自己就能否掉它：

```
歌词区 20,204,374,346  ⇒  barTop = 346 + 8 + 204 = 558
```

而 `npv.bottomStackView` 的顶边**就是 558**（日志 50 的 `[NPVTree] #7 8.UIStackView@4,558,406,275`）
⇒ 日志 49 那次 `bottomStackTop(in: list)` **是找得到它**的 ⇒ **那一坨就在列表子树里**。

那为什么本轮还是把这两处改成**优先从 `page` 找**？因为 `page` 是**严格超集**，两种版式都覆盖，
成本一样；而且另外两个消费者（`toggleFrame`、底部音量条）本来就是用 `page` 才稳的。
**但这是加固，不是修复** —— 修复是 §1.3 那条。

---

## 2. ★★ 你报的问题①：暂停键"一卡一卡的" —— **还没有判据，本轮补齐**

日志 50 里这条线**一行判据都没有**：字形换符号不报、字形跳位置不报、钉被谁盖掉不报、
`uiButtonTapped` 钩子有没有真的跑过也不报。所以只能列嫌疑，不能下结论。

### 2.1 三条嫌疑

| | 机理 | 依据 |
|---|---|---|
| **H1 钉被盖掉** | `pinInvisible` 原来是**一次性**的（`guard !isPinned` 之后永不复核）。日志 50 证明 Spotify **确实会写这些按钮的 `alpha`**：同一个类 `PlayButtonView` 在迷你条上的模型值是 **`alpha=0.50`**（`[Tree] #2..#5`，04:34:44–04:34:50）。UIKit 写 `alpha` 会加一条隐式 `opacity` 动画，**同 keyPath 谁后加谁说话** ⇒ 我们的钉被压在下面 ⇒ 原生圆盘漏回来一帧 | `[Tree]` 里的 `alpha=0.50` |
| **H2 硬切** | 整颗按钮被钉成不可见 ⇒ Spotify 自己的按下回弹与 crossfade 全没了；我们的字形是 `glyph.image = …` **瞬时硬切**，没有任何过渡 | 代码本身 |
| **H3 位置跳步** | 字形只在节拍上重排（`Timer 0.5s` + `tolerance 0.2` + `0.3s` 节流 + `armRehide` 的 0.05/0.15/0.35/0.6 四连）⇒ 卡片折叠 / 换歌时按钮几何一动，字形是**跳着**追上去的 | `DeclutterChrome.startReconcileTimer` |

### 2.2 已经被**证伪**的一条（省掉下一轮）

~~「位置源是整秒量化的 ⇒ `advanceThreshold = 0.05s` 大部分采样都跨不过去 ⇒ 字形 1Hz 抖动」~~
—— **假**。日志 5/7/8/36 的 `pos sample` 是平滑小数：
`2.7063 → 2.9020 → 2.9149 → 2.9326 → 2.9481`。
（日志 42/43/44/45/48/49/50 里那些**恒定不变**的 `160.476 / 45.758 / 19.755 …` 不是量化，
是那些日志里**播放器真的卡住了**，同页就有 `⚠️ position stalled`。两回事。）

### 2.3 一条对判断有用的现场（日志 50 会话 2）

`04:34:52` 与 `04:35:02` 各有一次 `[PLAYER] track changed — pos=0.0s dur=230.0s`，
中间**没有** `⚠️ position stalled` ⇒ 那 10 秒里位置是**在前进**的（否则 3 秒就会打那一行）
⇒ **用户待在听歌页那段时间，歌是在放的**。所以"因为播不动所以图标乱跳"这条在日志 50 不成立。

---

## 3. ★ 判据纠错：上一份 §3.4 ② 那条是错的

> 上一份原文：「`pinned … (time 1)` ← ★ 期望每颗按钮**只出现一次**（time 1）。
> 出现 time 2 / time 10 ⇒ 还有东西**每按一次被重建**」

日志 50 的实测：

```
[NPVControls] pinned _TtCCE16Encore_ButtonKitO16EncoreFoundation6Encore6Button8Tertiary (time 1)
[NPVControls] pinned _TtCCE16Encore_ButtonKitO16EncoreFoundation6Encore6Button8Tertiary (time 2)
[NPVControls] pinned EncoreConsumerMobile_BaseKit.PlayButtonView (time 1)
```

**`time 1` 与 `time 2` 是两颗不同的按钮**：上一首（`SPTNowPlayingPreviousTrackButton`）
与下一首（`SPTNowPlayingNextTrackButton`）**共用同一个类 `Encore.Button.Tertiary`**
（`[NPVTree] #7 14.Tertiary@0,0,56,56,id=SPTNowPlayingPreviousTrackButton` /
`…id=SPTNowPlayingNextTrackButton`）。

⇒ **机制是对的**（每颗按钮只钉了一次，`newly pinned 3 → 0` 也对），**判据写错了**：
**类名不是身份，`accessibilityIdentifier` 才是。** 本轮已把 id 打进那一行：

```
[NPVControls] pinned <类名> id=<accessibilityIdentifier> (time N)
```

---

## 4. 日志 50 对照 §3.4 六条的完整判决

| §3.4 | 结果 | 证据 |
|---|---|---|
| ① 快连点 10 次不再闪白圆盘 | **❓ 无判据**（且你新报的"一卡一卡"属于同一族） | 全程 `[NPVControls]` 只有 9 行 |
| ② 每颗按钮 `time 1` | **✅ 机制对 / ❌ 判据错** | 见 §3 |
| ③ 点歌词 → 封面缩成 72pt | **❌ 失败（回归）** | 见 §1 |
| ④ 三颗按钮还都能按 | **❓ 无判据**（`notePlayTapped` 原来不打日志） | 本轮补上 |
| ⑤ Reduce Motion | 未测 | —— |
| ⑥ 不回归 | **✅** | `[OneScreen] diag … bounce=on bounces=on panRecs=3 pan=UICollectionView`（5042 行）；`tap hook installed` 也在（475/3177 行，两次启动都有） |

**其它已验成的**（写在 §3.3 的预期里、也都出现了）：

```
[NPVControls] the three transport buttons now use local glyphs - found 3 button(s), newly pinned 3 this pass
[NPVControls] … found 3 button(s), newly pinned 0 this pass          ← 钉是一次性的 ✔
[NPVLyrics] lyrics button in place 185,790,44,44 (visible round button; …)
[NPVLyrics] remembered this track's artwork 366×366 (cache 1/8)
[NPVTree] #7 15.MixedPlayButtonDecorationView@0,0,64,64              ← 钉住后不带 alpha= ✔
[NPVPage] overlay installed …; bottom anchor npv.bottomStackView = not found (falling back to the safe-area bottom)
```

⚠️ **关于最后一行**：日志 40/41/42/43/48/49/50 **七次**都是"没找到"。
日志 50 记下的退回落点 `8,860,398,32` 正好等于
`896 − safeAreaInsets.bottom(0) − 4 − 32` ⇒ **进页面那一刻那一坨确实还不在树里**
（同一秒稍后 `[NPVTree] #7` 里它就在 `4,558,406,275` 了）⇒ 这是**时序**问题，
`SESSION_2026-10-03_NIGHT.md` §12 那次"补列表那一跳"**没有治到病根**（它补错了根）。
⇒ 记成**下一轮的候选**（`NowPlayingPageOverlay` 该像本轮歌词线一样"没找到就接着试几拍"），
**本轮不动**。

---

## 5. 本轮改了什么（两个文件，未提交）

### 5.1 `Sources/EeveeSpotify/Appearance/NowPlayingLyricsPlate.swift`

| # | 改动 | 为什么 |
|---|---|---|
| 1 | 新增 `openAndMount(in:)` + `pendingOpenUntil` / `pendingOpenWindow(2.5s)`；`apply` / `reconcile` / `toggle` 三条路都改走它，**窗口只武装一次、不往后推** | ★ **§1.3 的回归**：失败不再"认死"，从**第一次失败起** 2.5s（≈5 拍）内接着试。**不新开定时器** |
| 2 | `openAndMount` 里加了 `wasLive`（`coverHost != nil \|\| lastContainer != nil`）⇒ **已经铺着的时候量不到，不许把 `isOpen` 改掉** | 独立复核抓到的死角：歌词明明开着而 `isOpen` 已是 `false` ⇒ 用户再点走的是"展开"那一支 |
| 3 | `toggle()` 的**折叠条件**从 `isOpen` 放宽到 `isOpen \|\| coverHost != nil \|\| lastContainer != nil` | 同上：屏幕上有我们的东西时，点一下**必须**是收起（与 `closeEverything` 的守卫同一组判据） |
| 4 | 把 `guard lines/trackId` **提到所有副作用之前** | 旧顺序它在藏封面 / 位移标题**之后** ⇒ 那一步失败会留下半成品；提前判断 ⇒ 失败是**零副作用** |
| 5 | `measure()` 返回 `MeasureOutcome`（`.ok(Geometry)` / `.failed(String)`） | 四种死法各有各的话，带数字 |
| 6 | `lift` 只在 `rowFrame != nil` 时才当判据 | 去掉那条"自己把自己否掉"的判据（§1.4 缺陷 2） |
| 7 | 标题行改成 **`list` 先、`page` 兜底**；`bottomStackTop` **`page` 先、`list` 兜底** | 独立复核：`findByIdentifier` 的 800 预算 + BFS 先宽后深 ⇒ 反过来写**可能因为预算耗尽而比原来更差**。列表那一跳是日志 49 证明走得通的 |
| 8 | `leading` **夹到页面内** | 标题行现在真的量得到了；它是 marquee 时 `transform.tx` 是**模型值**、会跳 ⇒ 缩略图会飞出去，而且 `applyCoverState` 的收敛判据是**精确比较** ⇒ 每 0.5s 重启一次动画 |
| 9 | `closeEverything` 的重试窗口清理**挪到 `guard` 之前** | 关掉 / 离页时要**无条件**清账 |
| 10 | `expanded` 那行补上缩略图矩形与"标题行有没有上移" | 日志 51 一眼看出几何对不对 |

### 5.2 `Sources/EeveeSpotify/Appearance/NowPlayingControlsPlate.swift`

| # | 改动 | 为什么 |
|---|---|---|
| 1 | `pinInvisible(_:force:)`；`pinButton` 在**钉丢了 / 有别人的 `opacity` 动画**时重申 | H1：钉原来是一次性的，被盖掉就**永远不复查**。重申只动呈现层、`fromValue == toValue == 0`，**观感零影响**，依然一个字节都不写 `alpha` |
| 2 | 重申**不是每拍无条件做** | 独立复核：`refreshGlyphs` 也跑在 `PlaybackControlsUnitHook.layoutSubviews` 上 ⇒ 无条件重申就是转场时**每帧 3 个** `CABasicAnimation`，白花 |
| 3 | 新增 `noteForeignOpacity`（**只报观察到的事实**，并带上 `alpha` 与其余 key） | H1 的**提示**。⚠️ 它**不是判决**：真空转的 `opacity` 动画会假阳性，而"动画块外写 `alpha`"根本不加动画 ⇒ 假阴性 |
| 4 | 新增 `noteDiagnostic(_ channel:_:)`：**每路一个预算**（tap 200 / symbol 120 / move 40 / foreign 8）+ 每路用满时留一行墓志铭 | 第一版是**一个共用预算 120 行**，独立复核指出：`move` 是帧级的，翻页动画 1 秒就能烧光，然后 `tap`（§3.4 ④ **唯一**的自动判据）被**静默丢掉** ⇒ 得到一条假绿灯 |
| 5 | 字形**换符号**、**跳位置**两条判据 | H2 / H3 的分辨器，也是"投影抖动"与"点击接管到期回弹"的分辨器 |
| 6 | `notePlayTapped` 加一行日志 | §3.4 ④ 至今无法验收就是因为没有它 |
| 7 | `pinned …` 那行补 `id=` | §3 的判据纠错 |

### 5.3 独立只读复核（仓库纪律 §5.11）—— 本轮抓到 5 条，全已修

| # | 复核抓到什么 | 处置 |
|---|---|---|
| 1 | ★ **重试窗口永不到期**：每次失败都把 deadline 往后推，而 `reconcile` 每 ~0.5s 再进来一次 ⇒ 变成无限轮询 | 已修（§5.1 #1「只武装一次」） |
| 2 | ★ **`isOpen` 与屏幕不一致 ⇒ 关不掉**：某拍量不到就把 `isOpen` 归 false，而屏幕上还挂着我们的封面 ⇒ 再点走"展开"支 | 已修（§5.1 #2/#3） |
| 3 | ★ **判据被静默丢掉**：共用一个预算 ⇒ `move` 刷爆后 `tap` 永远打不出来 | 已修（§5.2 #4 每路单独预算 + 墓志铭） |
| 4 | ★ **从 `page` 找标题行可能比原来更差**（800 预算 + BFS 先宽后深） | 已修（§5.1 #7 `list` 先、`page` 兜底） |
| 5 | `leading` 无夹取 ⇒ 缩略图飞出去 / 动画每拍重启 | 已修（§5.1 #8） |

**复核提出、本轮**没做**的（记进 §8）**：
`hideSpotifyCover` 会把 `visibleCover` 要的那张封面 `alpha` 写成 0 ⇒ 之后某拍可能"挑不到封面"
（自毒）；`lastUnit` 在 `closeEverything` 里没清 ⇒ 可能把 `.identity` 写到 Spotify 换过用途的行上，
而且还原写的是 `.identity` 而不是**存下来的原值**（有损）；
`bottomStackTop` 的列表那一跳是**内容坐标系**（没算 `contentOffset`）；
`noteSkip` 按**完整字符串**去重，而新原因里带数字 ⇒ 同一类失败会打几条。

---

## 6. 下一次装机（**日志 51**）：一次问完

### 6.1 构建 / 设置

* **workflow**：`.github/workflows/build-ipa-with-orion-patched.yml`，`liquid_glass` 保持默认开；
* **调试**：「启用日志记录」+「转储视图树」**都开**（我要 `[NPVTree]`）；
* **扩展功能 → 听歌页，五项全开**：「一屏」/「整页封面取色底」/「底部音量条」/
  **「歌词进播放器」** / **「播放键换成本地字形」**；
* 歌词设置里确认「**更好的逐词歌词**」是**开**。

### 6.2 操作顺序（每一步都短，**这次别抢**）

1. 进听歌页 → **心里数 1、2、3** 再动手（★ 这一条是给日志 50 那个 1 秒钟的提前点击补的）；
2. **先点歌词键**（底部那一排正中间那枚圆键）→ 期望：封面从原位置平滑缩到左上角 72pt、
   标题挪到它右边、歌词在下方淡入、**封面不再整张露着**；
3. **再点一次**收起 → 封面飞回原位、Spotify 那条封面正常显示；**然后再点一次**（连点两次不跳）；
4. **快连点播放/暂停 10 次以上** ← 暂停键那条线的主验收点；
5. **顺手**：上一首 / 下一首各点一次（★ 这三下同时验"钉了整颗按钮之后**还都能按**"）；
   下拉关闭一次；停在听歌页 3 秒。

### 6.3 预期日志行（照着比）

```
[NPVControls] pinned <类名> id=<id> (time N)          ← ★ 每颗按钮**只出现一次**（time 1）。
                                                         出现 time 2 且 id 相同 ⇒ 真的在重建
[NPVControls] the three transport buttons now use local glyphs - found 3 button(s), newly pinned 0 this pass
                                                       ← 连点期间应当一直是 0
[NPVControls] play button tapped — glyph pause.fill -> play.fill (trust 1.2s)
                                                       ← ★ 新：点一次一行（§3.4 ④ 的判据）。**预算 200 行**
[NPVControls] glyph SPTNowPlayingPlayButton symbol pause.fill -> play.fill (via tap-override, …)
                                                       ← ★ 新：字形换符号的每一次（含原因、`isPlaying`、位置、接管剩余秒数）
[NPVControls] glyph SPTNowPlayingPlayButton moved 175,678,64,64 -> …     ← ★ 新：字形跳位置的每一次（预算 40 行）
[NPVControls] <类名> has a foreign 'opacity' animation on its layer (alpha=1.00, other keys: …) - the pin was re-asserted over it
                                                       ← ★ 新：**出现就是 H1 的强提示**（但它是提示、不是判决，见 §5.2 #3）
[NPVControls] 'symbol' diagnostics reached their limit (120 lines) - further lines of this kind are suppressed
                                                       ← ★ 新：某一路判据用满时的墓志铭（**不会**再静默丢掉 tap）
[NPVControls] restored (pins undone, our glyphs taken away; …)
[NPVLyrics] lyrics button in place 185,790,44,44 (visible round button; tap to expand/collapse; this track has lyrics)
[NPVLyrics] expanded — thumbnail 72pt at …, lyrics area …、cover shrunk in from …, title row lifted -Npt / shifted 72pt
                                                       ← ★ 本轮主验收点（**必须出现**）
[NPVLyrics] not expanding (<**具体**原因，带数字>)
                                                       ← 若出现：现在能一眼看出是四种里的哪一种
[NPVPage] overlay installed …; bottom anchor npv.bottomStackView = not found (falling back to the safe-area bottom)
                                                       ← ⚠️ 已知问题（§4），**本轮没治**，别误判成回归
[OneScreen] diag inset.bottom=0 content.h=896 bounds.h=896 adj.top=0 adj.bottom=0 bounce=on bounces=on panRecs=3 pan=<delegate 类名>
```

### 6.4 通过 / 失败判据

| # | 判据 | 类型 |
|---|---|---|
| ① | **点歌词键能展开**，封面真的缩成 72pt、不再整张露着；收起后封面正常显示；连点两次不跳 | ★ 本轮主症状 |
| ② | `pinned …` 每颗按钮**按 id**只报一次 | 机制 |
| ③ | **三颗按钮还都能按**（`play button tapped —` 出现 ≥10 次；上一首/下一首各生效一次） | **回归**（最高风险项） |
| ④ | 暂停键**不再"一卡一卡"**；并且 `glyph … symbol` 那几行**在没碰它的时候不刷** | 本轮第二症状 |
| ⑤ | `… has a foreign 'opacity' animation …` **出现 / 不出现** ⇒ H1 有多强 | 取证 |
| ⑥ | 开「减弱动态效果」→ 封面直接到位、不放动画 | 无障碍 |
| ⑦ | 之前已验的不回归：歌词键点得到 / `bounce=on` | 回归 |

**失败判据（要警惕的）**：点歌词后**只有 `not expanding` 而没有 `expanded`**（回归没修好）；
`glyph … symbol` 在没有用户操作时**成串刷**（投影在抖 ⇒ H2/投影那条线成立）；
`play button tapped —` **一次都不出现**（钉坏了命中判定 ⇒ 立刻回滚本轮第 1 条）。

---

## 7. 未验证声明（**不要去掉这一段**）

* 本轮两个文件的改动**未提交、未编译、未装机**。`f59b1e6` 之前的一切照旧。
* **本机六条自检全绿**（`orion_hook_guard` / `swift_brace_check` / `swift_member_check` /
  `swift_string_check` / `l10n_lint --locale en` / `--locale zh-CN`，全部 `exit 0`）。
  ⚠️ **它们不做类型检查** —— 逐成员初始化器顺序、`@MainActor` 隔离、`frame`/`bounds` 误用
  这几类只能靠 CI 与人工推演（见 `SESSION_2026-10-05.md` §4）。
* **日志 50 的判读结论里，只有 §1.3 那条是"代码可证的"**（`measure()` 逐字节相同 +
  调用方三处 diff），其余（§1.4 的两处缺陷、§2 的三条嫌疑）都标了依据的强弱。
* §2 的三条嫌疑**一条都没证实**，本轮只是把判据补齐 —— **别把"补了判据"当成"修好了"**。
* **独立只读复核做过了**（仓库纪律 §5.11）：两个**独立的只读** reviewer 对着源码推演，
  指出 5 条 —— 其中 3 条是**我自己这一轮改出来的**缺陷（重试窗口永不到期 / `isOpen` 与屏幕
  不一致导致关不掉 / 判据预算共用害 `tap` 被静默丢掉），**全部已修**（§5.3）；
  另外 4 条已记进 §8。
  ⚠️ 两个 reviewer 都**没能跑 `git diff`**（它们的 shell 起不来），是直接读工作区文件推演的
  ⇒ 结论有价值，但**不是编译证据**。

---

## 8. 下一步（排序 + 前置证据）

| 序 | 做什么 | 前置 / 判据 | 风险 |
|---|---|---|---|
| **1** | **构建 + 抓日志 51**，按 §6 那张单子验收 | 无（就现在） | —— |
| **2** | 按日志 51 收口暂停键：`foreign 'opacity'` 出现 ⇒ 治 H1（钉要"持续有效"，不只是"重申"）；`symbol` 成串刷 ⇒ 治 H2/投影 | 日志 51 | 低 |
| **3** | ★ **`hideSpotifyCover` 的自毒**：它把 `visibleCover` 要的那张封面 `alpha` 写成 0 ⇒ 之后某一拍可能"挑不到封面"、`measure()` 失败。修法是让"**被我们藏起来的那张**"也算合格（隐藏名单已经记在关联对象里） | 日志 51 里有没有 `cannot find a visible artwork` | 中 |
| **4** | `lastUnit` 在 `closeEverything` 里没清 ⇒ 可能把 `.identity` 写到 Spotify 换过用途的标题行上；而且还原写的是 `.identity` 而不是**存下来的原值**（有损） | 与 3 一起做 | 低 |
| **5** | 封面改成"自己持有"（复用既有的 `LyricsArtworkResolver`，它已把 `spotify:image:<hex>` 那条链走通） | 要先把 `layoutAndMount` 的**同步返回 Bool** 改成"异步图到了再铺" | 中 |
| **6** | ★ `NowPlayingPageOverlay` 的"没找到就接着试几拍"（与本轮歌词线**同一个形状**；日志 40/41/42/43/48/49/50 **七次**同形） | 日志 51 里那一行仍是"not found" | 低 |
| **7** | 「一屏」橡皮筋：用户拍 A / B（`SESSION_2026-10-06_HANDOFF.md` §2.5） | 用户决定；B 档先看 diag 的 `pan=<delegate 类名>` | A 低 / B 中高 |
| **8** | 头部 / 控件 / footer 排版向 kumone 看齐（**手法是「搬 holder 不搬控件」**，见 `SESSION_2026-10-06_HANDOFF.md` §4 第 5 条） | 三个 `*ElementsUnit` 类都在 9.1.88（已核） | 中 |
| **9** | `bottomStackTop` 的列表那一跳是**内容坐标系**（没算 `contentOffset`）；`noteSkip` 按完整字符串去重、而新原因带数字 ⇒ 同类失败会打几条 | 复核指出，都是小活 | 低 |
| **10** | 刷新 customize 种子（9.1.76 → 9.1.88） | 需要一次**真的拿到 body** 的 customize（常态 304） | 低 |
| **11** | 歌词区 0.96 放大进场 | 先把容器也改成 `transform` + `bounds`/`center` | 低 |
| **12** | `swift_string_check.py` 接进 CI | 改 `.github/workflows/`（目前没进） | 低 |

---

## 9. 规矩（本轮新增 / 强化）

1. ★ **跨构建 grep 日志前，先确认那一版日志的语言** —— 本仓库做过一次全量中英切换
   （`1a626d3`），中文日志里 grep 英文串会得到**假阴性**，而"假阴性"正是上一份 §2.1 第 2 条
   要防的东西。（本轮我自己踩了一次，见 §1.1。）
2. ★ **改"行为开关"的代码要成对看**：`4215e8e` 把"铺不上就不认已展开"加上时，
   忘了同一处还有"下一拍接着试"这半边 ⇒ 一个意图正确的改动造成了**功能全死**。
   **凡是"失败就回退状态"的写法，旁边必须有一句"谁来重试"。**
3. ★ **判据必须落在 `accessibilityIdentifier` 上，不能落在类名上** —— 上一首/下一首
   共用 `Encore.Button.Tertiary`（§3）。
4. ★ **"钉"必须每拍重申**，不许"钉一次就再也不看"：别人的 `alpha` 写回会盖住它（§2.1 H1）。
5. ★ **补判据 ≠ 修好**。日志 51 之前，§2 那三条嫌疑一律按"未证实"对待。
6. ★ **判据的"预算"要按通道分，不许共用** —— 共用必然出现"帧级那一路刷爆、把关键那一路
   **静默丢掉**"，那比没有判据更坏（会得到一条**假绿灯**）。每一路用满时还要留一行墓志铭。
7. ★ **写"失败就回退状态"的代码，必须连问三句**：① **谁来重试**？② 这个重试窗口
   **会不会永远不到期**（每次失败都往后推 = 无限轮询）？③ 回退之后，
   **屏幕上的东西和那个状态还一致吗**（不一致 ⇒ 用户关不掉）？
   本轮第一版三条里中了三条 —— 这不是运气差，是这三条本来就该一起想。
8. 其余照旧：日志文案英文 / 注释中文；字符串里不用 ASCII 双引号做强调；
   **别人的视图只钉 layer 不写 `alpha`**；一律 `bounds` + `center`；不新开定时器；
   静默分支不许静默；一次装机只验一轮；改"动别人视图/布局"的代码要**独立只读复核**。

---

## 10. ★★ 日志 51 的判决（同一天追加；HEAD 已到 `bcadd25`）

### 10.1 三十秒

| 线 | 结果 |
|---|---|
| **上一轮拆的 `measure()` 原因** | ★ **一击命中**：`not expanding (the title row has not settled yet (lift=240pt) - will retry next tick)` —— **`240` 这个数字直接破了案** |
| **歌词还是点不动** | 🔴 根因**换了一个**：不是重试窗口，是 **`visibleCover()` 挑错了封面**（挑中「一屏」折掉的那张卡里的 374×374，而不是主封面的 366×366）。已修 |
| **暂停键"一卡一卡的"** | ✅ **确诊**：投影在**一次采样没前进**时就判暂停。已修（粘滞判决）。**并且 H1 被证伪** |
| **判据本身** | `glyph … symbol` 序列、`pinned … id=`、`measure` 的分因 —— **三条都按设计工作了**；`foreign 'opacity'` **零命中** |
| **本轮又改了什么** | 两个 Swift 文件 +180/−5，六条自检全绿，**未编译、未装机** |

### 10.2 ★★ 歌词：`visibleCover()` 挑中了「一屏」折掉的卡里的封面

**证据链（三份日志闭合）**：

```
日志 51  [NPVTree] #7 2.CollectionViewCell@20,838,374,0,bg=#2A2A2A      ← 「一屏」折掉的卡：高 0
日志 51  [NPVTree] #7 7.ImageView@0,-62,374,374,id=Encore.ImageView     ← **那张卡里的封面**
日志 51  [NPVTree] #7 13.ImageView@0,0,366,366,id=Encore.ImageView      ← 真正的主封面，比它**深**
日志 51  [NPVLyrics] not expanding (the title row has not settled yet (lift=240pt) …)
```

`lift = +240` 只有一个解：`cover.minY` 落在页面**底部**（≈805…827）——
正好就是"那张卡的封面"的位置（`838 − 62 = 776` 起、往下 374）。而主封面在 `y≈104`。

**为什么日志 49 成了、50/51 不成**：那张 `374×374` 是**卡片建好/折掉之后**才出现的。

| 日志 | `374×374` 第一次出现 | 用户点击 | 结果 |
|---|---|---|---|
| 49 | `#10`（02:59:09） | 02:58:44 / 02:58:47（**在它之前**） | ✅ 两次都成 |
| 50 | `#7`（04:34:54）没有，`#8`（04:34:56）有 | 04:34:55 —— **正好在它出现的那一秒** | ❌ 失败 |
| 51 | `#7`（05:27:29）已在 | 05:27:28（在它之后） | ❌ 失败 |

⇒ **旧判据（可见 + 宽 ≥ 200）对"被折成 0 高的卡里的封面"一样成立**，而 BFS 先宽后深
⇒ 它**先撞上**那张 374×374。这就是病根，与重试窗口无关（所以重试修不好它）。

**修法**：`visibleCover()` 两趟 —— 先要"**祖先里没有被折成 0/被 hidden 的**"，找不到才退回旧判据
（宁可回到老行为，也不要一张都挑不出来）。`anyCoverImage()` 同样两趟（否则缩略图会拿卡片的位图）。
外加一行只读判据 `[NPVLyrics] artwork picked <类名> W×H at x,y,w,h (strict=true|false)`，
**挑中的换了就报一行**（上限 12 行）——`strict=false` 就是"退回了老行为"，一眼可见。

### 10.3 ★★ 暂停键：确诊，而且 **H1 被证伪**

日志 51 里抓到的完整现场（三对，**同一秒内翻两次**）：

```
05:27:42  glyph SPTNowPlayingPlayButton symbol pause.fill -> play.fill (via projection, isPlaying=false, pos=28.91s, overrideLeft=0.00s)
05:27:42  glyph SPTNowPlayingPlayButton symbol play.fill -> pause.fill (via projection, isPlaying=true,  pos=29.38s, overrideLeft=0.00s)
05:27:46  glyph … pause.fill -> play.fill (isPlaying=false, pos=32.34s)
05:27:46  glyph … play.fill -> pause.fill (isPlaying=true,  pos=32.68s)
```

* 三对的位置差是 **0.47 / 0.34 / 0.48 秒**，而每一对的**前一半**都是 `isPlaying=false`
  ⇒ **位置提供者在两次采样之间没有前进**；
* 采样来自 `DeclutterChrome` 那条 **≈0.5s** 的节拍，而投影的 `pauseThreshold` 只有 **0.35s**
  ⇒ **采样间隔比阈值还长** ⇒ **一次"没前进"就直接判暂停**，下一次采样又翻回来。
  **这就是"一卡一卡的"。**
* ★ **`has a foreign 'opacity' animation` 一行都没有** ⇒ **H1（钉被 Spotify 的 alpha 写回盖掉）证伪**。
  `pinInvisible` 的"按需重申"保留（它是廉价的保险），但它**不是**这个症状的原因。

**修法**：字形改成**粘滞判决** —— 新状态要**连续 2 次、并且持续 ≥ 1.2s** 才允许换符号；
用户自己点的那一下不受影响（`notePlayTapped` 的接管窗口在它**之前**就 return 了）。
⚠️ **刻意不去改共用的 `AppleMusicLyricsPlaybackProjection`**：全屏歌词页是按帧喂它的，那边 0.35s 是对的。

### 10.4 这一轮的判据，哪些真的起作用了（留档）

| 判据 | 结果 |
|---|---|
| `measure()` 的**分因** | ★★ **一击命中** —— `lift=240pt` 这一个数字就是破案的全部 |
| `glyph … symbol`（换符号序列） | ★★ **一击命中** —— 三对翻转，直接证明是投影抖动而不是钉 |
| `foreign 'opacity'` | **零命中** ⇒ H1 证伪（省掉一整轮猜测） |
| `pinned … id=` | ✅ 生效；仍然是"每颗按钮一次"（`Tertiary (time 1)` = 上一首、`(time 2)` = 下一首） |
| `[NPVPage] … bottom anchor = not found` | ⚠️ 仍然（§4 已知问题，本轮没治） |
| `[PLAYER] ⚠️ position stalled at 11.1s for ~3s` → `position resumed at 11.2s` | 曲中卡住 3 秒只走 0.1 秒（见 §11.1） |

### 10.5 独立只读复核（§5.11）—— 这一轮它又抓到 3 条，全已修

| # | 复核抓到什么 | 处置 |
|---|---|---|
| 1 | ★★ **本轮修法的前置条件没做**：`ensureCover` 展开那一刻就把主封面的 `alpha` 写成 0，而下一拍 `visibleCover` 还要再认出它 ⇒ 不认它的话**展开撑不过半秒**、又退回旧判据去挑卡的封面 | 已修：`isHiddenByUs()` —— **被我们自己藏起来的那张也算合格**（顺带把 §8 第 3 条一起做了） |
| 2 | ★ **粘滞判决可能"冻住"**：日志 51 那种"每隔一次采样恰好等于当前值"的形态下，候选被反复清零 ⇒ 永远不提交 ⇒ 从"闪"变成"错"，更糟 | 已修：加**分歧上限** `disagreeLimit = 2.5s`，分歧超时就无条件采纳最新读数；另加 `candidateSince > 0` 防呆 |
| 3 | 封面判据的日志预算**整个会话共享 12 行** ⇒ 开合三次就看不见了 | 已修：`closeEverything` 里按"一次开合"重置；另外去掉 `rect.map(frameText)` 这种"把 `@MainActor` 静态方法当函数值传"的写法 |
| 4 | ★★ 复核点出的**残留**：`hasCollapsedAncestor` 只挡"**被折成 0**的卡"；一张**没被折掉**的卡里的 374×374 仍然会赢 BFS | 已修（**升级成三趟**）：日志 51 的树里挖到一个**结构性锚点** —— `7.UIView@0,0,414,896,id=SPTNowPlayingView`。播放器的每一件都在**它里面**（`npv.bottomStackView` 8 / 进度条 13 / 三颗按钮 14 / 标题行 15），而**卡片自己的封面 `7.ImageView@0,-62,374,374` 与它平级、在它外面**；这个 id 从 **2026-09-30 起每份日志都有**。⇒ 第一趟改成"**必须是 `SPTNowPlayingView` 的后代**"，第二趟才是"祖先没被折成 0"，第三趟才是旧判据 |

★★ **复核同时确认**：三趟的"严格找不到就退回"**保证了不会比原来更差**
（后一趟的接受集是前一趟的**超集**，BFS 顺序相同 ⇒ 都合格时挑中的还是原来那张，
也就是日志 49 那次成功挑中的那张）。
判据那一行也跟着改成 `artwork picked … (tier=inside SPTNowPlayingView|no collapsed ancestor|legacy predicate)`
——**日志 52 一眼看出走的哪一趟**：`legacy predicate` 就是"又退回老行为"。

### 10.6 ⚠️ §3.4 ④「三颗按钮还都能按」——**日志 51 仍然没验成，而且这次能分辨了**

日志 51 里 **`play button tapped —` 零命中**。但那一条只能证明"门面没收到"，
分不出**"用户没点"**与**"钩子没被调用"** —— 而且从现场看更像是前者
（`[NPVPage] overlay removed (reason=switch off)` 在 05:27:39，用户在设置页翻开关；
而那些 `pause.fill -> play.fill` 的翻转 0.4 秒后又翻回来，**不可能是人点的暂停**）。

⇒ 本轮加了一条**在身份判断之前**的判据：

```
[NPVControls] uiButtonTapped fired on <id> (isOurPlayerButton=true|false)
```

日志 52 里：**有它、没有 `play button tapped` = 钩子在跑、只是没认下这颗按钮**；
**两条都没有 = 钩子根本没被调用**（那就要换落点）。同时把身份判据从"严格同一实例"放宽到
"**互为祖先/后代**"（`isDescendant(of:)` 本身就包含"就是自己"）—— 防的是
"id 挂在子树里、hook 到的是外壳"那种接管窗口永远不生效的情况。

---

## 11. 你问的两件事（2026-10-07 追问）

### 11.1 「为什么会突然无法播放全部歌曲？是不是 premium 伪装漏了？」

**先看日志说了什么**（日志 51）：

```
[INIT] patching: overwriteConfig=OFF (ON = the bundled Premium config snapshot fully replaces the one the server sends)
[REVERT_WATCH][init] type=premium catalogue=premium ads=0 on-demand=1 unrestricted=1 shuffle-eligible=1
                     player-license=premium player-license-v2=premium subscription-enddate=2027-10-03T05:26:45Z
                     financial-product=pr:premium,tc:0
```

* **premium 属性层面没漏**：开场那一行是全 premium；而且 `[REVERT_WATCH]` 这个探针就是专门
  盯"Spotify 把值写回去"的（`EeveePremiumForce.x.swift`），**整场一条 reversion 都没有**。
* **本轮 `overwriteConfig=OFF`** —— 也就是"服务端下发的那份配置照用"。仓库自己的判定表
  （`Tweak.x.swift:527-539`）是：**开着覆盖配置还是放不了 ⇒ 大概率不是产品状态那一层**。
* ★ **日志 51 新给的一条**：这次是**曲中卡住**，不是"从 0 秒就放不了" ——
  `track changed — pos=11.1s dur=162.0s` → **`⚠️ position stalled at 11.1s for ~3s`** →
  `position resumed at 11.2s`（**3 秒只走了 0.1 秒**）。
  账号/授权被判死通常是**在 0 秒就起不来**；"先放 11 秒再卡"更像**流/密钥续期**那一层。

⇒ **结论**：日志不支持"premium 伪装漏了"这个假设；它把矛头指向**音频流/密钥**那一层。
**下一步（低风险实验）**：① 把「覆盖配置」**打开**再复现一次（一次只动这一个变量）；
② 本轮**没有**的东西：一条只读的**音频密钥路径探针**（只看那些请求的 status / 耗时，不看 body、不看 id）
—— 这是下一轮性价比最高的取证，能把"服务端判死"和"网络/CDN"分开。

### 11.2 「为什么点封面会出现一个能稍微转动一下的卡片？」

**那个卡片不是我们的，是 UIKit 自己的**：

```
[Tree] #3 12._UIParallaxTransitionCardView@-124,0,414,896
[Tree] #3 12._UIParallaxTransitionCardView@0,0,414,896
[Tree] #4 12._UIParallaxTransitionCardView@0,0,414,896
[Tree] #4 12._UIParallaxTransitionCardView@414,0,414,896
```

* 它**在 10-01 起的每一份日志里都有**（10/11/17/27/28/29/30/32/35/36/37/40/41/42/45/47/48/49/50/51）
  ⇒ **不是本轮引入的**，也不是我们的视图（我们的都以 `eevee-npv-` 开头）。
* 三个横向偏移（`-124` / `0` / `414`）= 卡片式转场的**出屏 / 居中 / 入屏**三份；
  「稍微转动一下」就是它的**视差（parallax）倾斜**。

**为什么现在特别容易碰到**：**「一屏」把列表里每一张卡都折成了 0 高**
⇒ 封面那块区域底下**只剩播放器自己的卡片手势面**，一点/一带就走到那张转场卡。
**可验证的一步**：临时关掉「一屏」，再点封面 —— 如果那张卡不见了（或变成正常滚动），这条因果就成立。

---

## 12. 文档地图

| 想看什么 | 去哪 |
|---|---|
| **本轮全貌 / 现状 / 下一步 / 规矩** | **本文件** |
| 上一轮（10 个提交的清单、§3.3/§3.4 的验收单、⚠️ §3.4 ② 已作废） | `SESSION_2026-10-06_HANDOFF.md` |
| 更早的详细流水与取证（日志 48/49 逐行、照片 49–53 逐像素、pw 原文引用） | `SESSION_2026-10-05.md` §8–§13 |
| pw 的移植评估（14 个目标类、一屏算法、依赖面） | `SPOTIPW_0211_PORT_ASSESSMENT.md` |
| pw ↔ 我们的功能缺口 + **许可红线** | `SPOTIPW_GAP.md` |
| kumone 的配方、常量、照片 40/41 的逐像素量测 | `KUMONE_REFERENCE.md` §5 |
| 歌词线的历史 | `LYRICS_MODULE_NEXT_STEPS.md` |
| 哪些目标类已过时/已删 | `STALE_AUDIT.md` |
| **六条自检脚本** | `orion_hook_guard.py` / `swift_brace_check.py` / `swift_member_check.py` / `swift_string_check.py` / `Tools/l10n_lint.py` |
