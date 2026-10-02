# SESSION_2026-10-03_NIGHT — 听歌页（AM 化）这一夜：交付 / 证据 / 下一步 / 规矩

> **新会话先读这一份**（自包含）。要更细的流水再往下看 §7 的索引。
>
> 写于这一夜收尾时。**HEAD = `980cbef`**，工作区干净，**10 个提交全部未 push**。
> 提交时间戳是 `2026-10-02 20:10 – 23:05`（文档沿用 `2026-10-03` 这个工作周期命名，与同目录其它
> 文档一致）。
>
> ⚠️ 这一夜的改动**大部分还没在真机上验收**（§4 是验收清单）。验过的只有：**取色底** ✅、
> **一屏的卡片折叠** ✅。
>
> 🆕 **2026-10-04 追加三节（写在同一夜之后，本文件仍是入口）**：
> **§9 = 「禁止回弹」弄坏下拉关闭 → 已删除**（用户报的 bug，日志 41 判决）；
> **§10 = 双击手势整体删除**（用户拍板"先删了，之后再搞"）+ **下一道工序**；
> **§11 = 日志 42/43 判读** —— ★ **下拉关闭已恢复（43 实测）**、定向转储拿到播放器底部真实层级、
> **歌词卡就在播放器里**（下一刀的地基）。
> 代码改动见提交 `49b9565`（修复+删除）与 `f3353af`（pw 对照结论）。

---

## 0. 三十秒现状

| 线 | 状态 |
|---|---|
| **取色底（仿 AM 整页取色）** | ✅ **真机验成**（日志 39 + 照片 42/43/44：整页红/粉/紫跟着换歌走） |
| **「一屏」（卡片全折 + 列表钉顶）** | ✅ **2026-10-04 验收**（日志 43）：钉住 + 折 4 种卡片 + **下拉关闭正常**（`bounce=on` 哨兵成立） |
| **AM 页面（kumone 那种）** | 🟢 **已开工**：覆盖层地基 + 底部音量条（照片 45 可见）；底部四行（标题/进度/控件/footer）的**真实层级已拿到**（§11.3）；**歌词卡本来就在播放器里**（§11.4）⇒ 下一刀是"歌词进播放器" |
| **spoti.pw 许可边界** | ✅ 钉死：**≤v0.21.1 = GPL-3.0 可读可复用**；**≥v0.22.0 = PolyForm，一行都不碰** |
| **它的播放页目标在 9.1.88 上还在吗** | ✅ **14/14 全在**（ProbePack 实测）⇒ AM 页面可照搬其结构 |
| **双击手势** | ⛔ **2026-10-04 整体删除**（用户拍板"先删了，之后再搞"）—— 不是坏了才删：**没人用 + 会误伤播放键**（§10） |
| **「突然无法播放任何歌曲」** | 🟡 首次有现场（日志 39 位置卡住 3s+），但探针**分不清暂停**，待补 `isPaused` |

---

## 1. 这一夜干了什么（10 个提交）

| # | 提交 | 做了什么 | 关键证据/理由 |
|---|---|---|---|
| 1 | `9710ba5` | **取色底重做**：不再清别人底色/往别人 layer 栈插层，改成"我们自己的整页视图 + 可见性闸门 + 0.3s 自愈 + 自报被垫的是谁" | 日志 38：旧版"自报接管成功"但那层**根本没变** |
| 2 | `097ac95` | **「一屏」**：卡片全折 + 列表钉顶（借 spoti.pw v0.21.1 的思路，Swift 重写）；**移植评估文档**；`SPOTIPW_GAP.md` 红线重画 | 评估见 `SPOTIPW_0211_PORT_ASSESSMENT.md` |
| 3 | `159dbc4` | **修 CI 编译错**：hook 方法里 `self` → **`self.target`** | 三处报错、deb 没生成（用户实测） |
| 4 | `016ad84` | 把这条坑写进交接文档 | —— |
| 5 | `2b5aa11` | **卡片折叠那一刻就地重算**（pw：卡片是播放器之后很久才到的）+ 底部锚找不到时退到窗口 | 日志 39：钉住跑在卡片到货**之前** |
| 6 | `fc4b738` | **探针包**：`ProbePack`（pw 目标类存在性，启动一次）+ `PlayerStateProbe`（换曲/卡住，蹭 0.3s 节拍）+ 一屏/手势诊断行 | "只有装一次机才知道的事"一次问完 |
| 7 | `718052a` | 一屏：`want >= 0` 那一支改成**把 inset 退回原值** | 日志 39：-1236 留在列表上 ⇒ 能滑 1236pt 空白 |
| 8 | `3a29505` | **AM 页面地基**：`NowPlayingPageOverlay`（我们自己的透明覆盖层）+ 底部**音量条** | 照片 45：音量条落在 `8,860,398,32`，没压原生控件 |
| 9 | `0b4aac6` | **README 修正**：spoti.pw 那条"没读过源码"已经不成立；补 Interface 功能段；给"全部已验"加 NOTE | 见 §5 |
| 10 | `980cbef` | 一屏：**目标值统一成 `min(want, 0)`**（不是"压/不压"二选一）+ **「禁止回弹」单独开关** | 日志 40：`inset.bottom=34`（Spotify 自带）就是还能滑的距离 |

> 另有 `0a72cb5`（`更新 README.md`）是**用户自己**的提交：把 Development 版本改成 `v1.0.0-beta.72`、
> iOS 改成 `27.0.1`。**README 的版本表是用户维护的，别去"修"成 `control` 里的 6.6.8。**

---

## 2. ★ 证据裁决（这一夜学到的事实，都带证据）

### 2.1 日志 38（构建 `b14d6b9`）——旧取色底为什么"看起来没变"

```
[NPVStyle] backdrop (414x896) ← 封面取色 e84838，接管 1 层      ← 自报成功
[Tree] #7/#8  7.UIView@0,0,414,896,bg=#E84838                  ← 那层还在（`bg=` 只在非 clear 时打）
[Tree] #9     7.UIView@0,0,414,1682,bg=#584860                 ← 还自己换了色、长高了
```
⇒ 三个病根：① 我们的层插在**别人 layer 栈最下面**；② 候选**没有可见性闸门**；③ 抢 `backgroundColor`
且 `lastHex` 相同就早退（自愈永远来不了）。**现在三条都改了。**

### 2.2 日志 39（带探针包的构建）——一次问完的问题

```
[Probe] pw 播放页目标：14 个，在 14 个，缺 0 个 — 全部可搬
[Probe] pw 用到但 dump 里没查到的：3 个，在 1 个，缺 2 个 — SPTBarOverlayPresentationTransition,
        SPTBarInteractivePresentationController
[NPVStyle] backdrop … 垫在 UIView 0,0,414,896 之下（那层底色 E03038，subviews=2，
           layer.sublayers=2，手插子层=0）；三层：…
[NPVStyle] 跟到换色 → C84098（第 2 次）→ E030B8（第 3 次）→ C00000（第 4 次）
[NPVStyle] 有 1~2 个满页着色层是 hidden / 透明 / 不在窗口里 — 已排除
[Gestures] diag surface=now playing page host=UIView singleTapsAbove=2 — ⚠️ 双击的第一下会漏给它们
[OneScreen] collapsed card root Lyrics_CardElementImpl.CardView（第 1 种）… 共 4 种
```
结论：
* **取色底成功** —— `手插子层=0` 说明我们的层不会被压住；跟到换色 ×3；照片 42/43/44 的整页
  红/粉/紫与之对应；**可见性闸门挡掉了 1~2 个不可见满页层**（正是旧版会误选的）。
* **AM 页面解锁**：14/14 目标全在；**morph 与"下拉关闭"那两个类不存在** ⇒ morph 正式划掉，
  下拉关闭的机制在 9.1.88 上**换了**（不能照抄 pw 的结论）。
* **双击那条坑是活的**（`singleTapsAbove=2`）。
* `[PLAYER] ⚠️ position stalled at 27.4s for ~3s` —— "无法播放"第一个候选现场，但探针**分不清暂停**。

### 2.3 日志 40 ——「一屏」还能往下滑的**量化**根因

```
[OneScreen] 内容还没到一屏高（want=+0pt）— 不该压
[OneScreen] diag inset.bottom=34 content.h=896 bounds.h=896 adj.top=0 adj.bottom=34 bounce=on panRecs=3
[OneScreen] 列表已钉在顶部 — 折掉 314pt …   /   折掉 14pt …
[OneScreen] 内容缩回一屏内 ⇒ inset.bottom 由 -14 退回 34
```
⇒ 内容**刚好一屏**，而 **Spotify 自己留了 `contentInset.bottom = 34`** —— **那 34pt 就是还能滑的距离**。
两个前版一错到底两次：先压 `-1236`（留 1236pt 空白），再"`want>=0` 就退回原值"（把 34 留着）。
**目标从来不是"压/不压"，而是"让列表最多只能滚到它自己的顶"** ⇒ `min(want, 0)`。

### 2.4 照片

| 照片 | 证明什么 |
|---|---|
| 42 / 43 / 44 | 取色底跟着封面走（红 / 粉 / 紫）；44 里**卡片全没了**（一屏折叠生效） |
| 45 | 一屏 + **音量条装上了且落点正确**（在那条 Connect/分享/队列 行下面，没压原生控件） |

---

## 3. 代码现状（按功能）

| 功能 | 文件 | 开关 / 默认 | 验证 |
|---|---|---|---|
| 整页封面取色底 | `Appearance/NowPlayingBackdrop.swift` | 扩展功能→听歌页→「整页封面取色底」/ **开** | ✅ 真机 |
| 一屏（折卡片 + 钉顶） | `Appearance/NowPlayingOneScreen.swift` + `NowPlayingOneScreenCards.x.swift` | 「一屏（卡片折起来，不可滚动）」/ **关**（会连歌词卡一起折） | 🟡 折叠 ✅ / 钉住待验 |
| ~~禁止回弹~~ | ~~同上~~ | ⛔ **2026-10-03 已删除** —— 开了它**下拉关闭就坏**（日志 41 判决），见 §9 | ❌ 删掉才是对的 |
| 覆盖层地基 + 底部音量条 | `Appearance/NowPlayingPageOverlay.swift` | 「底部音量条」/ **关** | 🟡 照片 45 可见，未正式验 |
| 探针包 | `Diagnostics/ProbePack.swift` | 跟随「启用日志记录」 | ✅ 日志 39/40 |
| 播放器状态探针 | `Diagnostics/PlayerStateProbe.swift` | 同上 | ✅ 捕获到一个现场 |
| ~~双击手势~~ | ~~`Gestures/PlayerGestures.x.swift`~~ | ⛔ **2026-10-04 整体删除**（用户拍板"先删了，之后再搞"），见 §10 | ❌ 不是坏了才删，是"没人用 + 会误伤播放键" |

---

## 4. ★ 下一步

### 4.1 一次装机就能推进（**先做这个**）

> ⚠️ **本节第 2、3 条已作废**：用户按这一条开了「禁止回弹」，结果是 4 条里唯一真出事的那条
> —— **开了就划不掉播放器**（2026-10-03 日志 41）。开关已删，复盘与机制见 **§9**。

1. 开「一屏」→ **还能不能往下滑？**（那 34pt 现在应该被归零了）
2. ~~若还能拉动但会弹回 ⇒ 打开「禁止回弹」~~ ⛔ **那条路走不通**（会弄坏下拉关闭）；
   剩下的橡皮筋是「一屏」**无法消除**的残留，除非先能自己接管关闭手势。
3. ~~打开「禁止回弹」后务必试下拉关闭~~ → 已删。
4. 顺手：看一眼「底部音量条」的落点对不对（照片 45 里是对的）。

要看的日志行：`[OneScreen] 把列表自带的 inset.bottom=34pt 归零…` /
`[OneScreen] diag … bounce=on`（★ 必须 on） / `[NPVPage] 覆盖层已装 …`。

### 4.2 之后的三刀（借 spoti.pw v0.21.1，答案都写在它代码里）

> ⚠️ **第 1 条（双击手势）已于 2026-10-04 整体删除**（用户拍板"先删了，之后再搞"）——
> 删除清单与"要重做时的三条要求"在 **§10**。下表的顺序因此变成：**歌词 → 封面场 → 头部/控件**。

| # | 做什么 | 轮次 | 为什么排这里 |
|---|---|---|---|
| ~~1~~ | ~~**修双击手势**~~ ⛔ 已删除（§10） | —— | 不是坏了才删：**没人用 + 会误伤播放键** |
| 2 | **歌词搬进播放器**（pw `PlayerLyrics.x`） | 2~3 | 它是"一屏默认开"的前置（现在卡片全折 ⇒ 歌词卡也没了）；也是 kumone 中段的另一半 |
| 3 | **封面场**（pw `PlayerArtwork.x` + `SGRArtworkField`，注意后者定义在**专辑页**里） | 2~3 | kumone 的中段：无词 → 居中大封面 |
| 4 | 头部一行（歌名/艺人/♥/···）+ 控件收三键 + footer 三个字形 | 3~5 | ⚠️ **要新取证**：需要原生标题/艺人/徽章、`PlaybackControlsElementsUnit`、`FooterElementsUnit` 的子视图 |

**取证提示**：用户**不用重新构建**就能给转储 —— 现在装的版本已带「调试 → 转储视图树」；
进听歌页停 3 秒、切歌、退出再进，一次抓够。⛔ **不做**：morph（目标类不存在）。

---

## 5. 许可边界（这一夜最重要的一条流程变化）

| 范围 | 能做 | 不能做 |
|---|---|---|
| **`≤ v0.21.1`（GPL-3.0，与本仓库同许可）** | **读、复用、改**（义务：署名 + 标注改动 + 继续 GPL-3.0） | —— |
| **`≥ v0.22.0`（PolyForm Strict 1.0.0）** | 只读它的 `.md` | **源码一行都不碰** |

* 证据链：`v0.21.1:LICENSE` = GPL v3；换许可的提交 `f44abdf` **只出现在 `v0.22.0` / `v0.23.0-beta`**。
* **隔离副本**：`.spotify-ipa/spotipw-v0.21.1`（`git worktree`，detached `a08b38b`，已被 `.gitignore` 收口）
  ⇒ **物理上避开**工作区那份 v0.22.0。
* **代价**：v0.21.1 之后的修复拿不到。
* 已同步的文档：`SPOTIPW_GAP.md` §0（红线重画）、`README.md`（收尾那条 + Interface 段）、
  源码文件头（`NowPlayingOneScreen*.swift`）。
* ⚠️ **对外说法要对**：README 里"没读过 spoti.pw 源码"那句已经改成按 tag 划的边界。

---

## 6. 这一夜新增/强化的规矩（照做）

1. **五条自检**（改完必跑，全过才算完）：`orion_hook_guard` / `swift_brace_check` / `swift_member_check`
   / `l10n_lint --locale en` / `l10n_lint --locale zh-CN`。⚠️ **它们不做类型检查**。
2. ★ **不要覆盖 git 身份**。本机 `user.name=zbzxbg` / `user.email=…@outlook.com` 本来就是对的；
   这一夜我一度用 `-c user.name=dsh-agent` 提交，事后 amend 成 `9710ba5`。**commit message 用英文**。
3. ★ **Orion hook 里钩到的对象是 `self.target`**，`self` 是 hook 类自己。写成 `self` **只有 CI 才炸**
   （`has no member` / `cannot convert value of type 'XHook'`）。`orion_hook_guard.py` **规则 4** 已拦它
   （两向验证过）。
4. ★ **探针优先**：只有"装一次机才知道"的只读事实，**集中写进探针包**（`ProbePack` 那种），
   一次装机全部拿到；查完整块删。**静默分支不许静默**（`want >= 0` 那条就是教训）。
5. ★ **幂等 ≠ "什么都不做"**。两次栽在同一处：`lastHex` 相同就早退、`want >= 0` 就 return。
   幂等要做成"**确保状态**"。
6. ★ **目标值别做二选一**：不是"压 / 不压"，而是 `min(want, 0)` 这种**统一的目标值** + "与现值差多少才写"。
7. ★ **有风险的那一步单独开关**：「禁止回弹」可能影响下拉关闭 ⇒ 单独一个键，
   坏了只关它，别牵连「一屏」。
   📌 **当天夜里就被证伪了**（§9）：「单独一个开关"只让用户避开坏掉的那一半 —— 而那个开关本身
   就不该存在。**能弄坏别人的手势/交互的"观感调参"，宁可不做**；真要留风险项，也得先有
   真机验收它的手段（这一条是花了用户一次装机 + 一次报 bug 换来的）。
8. ★ **改"跟已有功能共用视图 / 手势 / inset"的东西，必须真机验收** —— 代码能编过、机制来自 pw，
   集成时机照样会错（这一夜三次都是这类）。
9. **`pw` 的结论不能照抄**：它基线 9.1.78、我们 9.1.88。它说"下拉关闭骑在
   `SPTBarInteractivePresentationController` 的 pan 上"，而**那个类在 9.1.88 上不存在**（探针实测）。
10. **不碰 Spotify 属性、只加我们自己的视图**：这一夜所有落地件都守这条（覆盖层 / 取色底 / 一屏的
    子视图），所以"关掉即还原"是天然的。

---

## 7. 相关文档索引

| 文档 | 看它干什么 |
|---|---|
| 本文件 | **这一夜的总结（入口）** |
| [`SESSION_2026-10-03_HANDOFF.md`](SESSION_2026-10-03_HANDOFF.md) | 上一份入口；§8/§8.7 是本夜之前的流水与裁决 |
| [`SPOTIPW_0211_PORT_ASSESSMENT.md`](SPOTIPW_0211_PORT_ASSESSMENT.md) | **移植评估**：pw 播放页 14 个目标、依赖面、一屏算法、验收判据 |
| [`SPOTIPW_GAP.md`](SPOTIPW_GAP.md) | pw ↔ 本仓库的功能缺口清单 + **许可红线（已重画）** |
| [`KUMONE_REFERENCE.md`](KUMONE_REFERENCE.md) | kumone 的三层配方、几何常量、"为什么不模糊" |
| `Tools/l10n_lint.py` / `orion_hook_guard.py` 等 | 五条自检 |

---

## 8. 已知未解 / 别踩

| 项 | 状态 |
|---|---|
| 「无法播放任何歌曲」 | 有一个候选现场（位置卡 3s+ 未恢复），但**探针分不清暂停**。`SPTNowPlayingPlaybackControllerImplementation` **在 9.1.88 上存在**（探针实测）⇒ 下一版可补**只读 `isPaused`** |
| `country=` | **不用补**：`EeveePremiumForce.x.swift` 的白名单里早就有，看不到值是 `DebugLogSanitizer` **故意**替换成 `<redacted>` |
| morph 转场 | ❌ 目标类不存在，**正式划掉** |
| 下拉关闭在 9.1.88 的现实机制 | ⚠️ **已定位到"它经不起什么"**（见 §9）：唯一动 `alwaysBounceVertical` 的那次构建 = 关闭坏掉的那次；那条代码路径**已删**。窗口那一侧怎么写的仍未反汇编验证 |
| `npv.bottomStackView` | 在**页面子树里找不到**（日志 40），已加**窗口兜底**；位置兜底本身没问题 |
| 双击手势 | ⛔ **已整体删除**（2026-10-04，用户拍板）—— 它不是坏了才删：切歌那条路日志 8/17 证明能用；删是因为**没人用 + 会误伤播放键**。清单与重做要求见 §10 |

---

# 9. 2026-10-03 收尾：「禁止回弹」**弄坏了下拉关闭** → 已删除 + 验收清点（日志 41）

> 输入：用户报「**开启静止回弹后，无法下滑关闭听歌页面**」+ **日志 41**
> （`C:\dsh\ipa\eeveespotify_debug_shared 41.log`，2855 行，15:42:36–15:43:10）。
> 判据全部来自日志与源码，**没有反汇编**。

## 9.1 结论（一句话）

**「禁止回弹」把列表的 `alwaysBounceVertical` 关掉，而这一页的下拉关闭是"经过列表那一层"接管的**
⇒ 列表在顶部又不肯再接下拉时，**窗口永远收不到那次拖动** ⇒ 播放器划不掉。
那条代码路径**已整块删除**（开关 / UI 行 / UserDefaults 键 / en+zh-CN 文案 / 写属性的那一行）。

## 9.2 证据链（三步，缺一不可）

**① 日志 41 是唯一的现场**。全量 37 份日志里，这一行**只出现过一次**：

```
[2026-10-02 15:42:54] [OneScreen] 已关掉列表的回弹（alwaysBounceVertical=false） — 若下拉关闭坏了，把这个开关关掉就是
[2026-10-02 15:42:54] [OneScreen] diag inset.bottom=0 content.h=896 bounds.h=896 adj.top=0 adj.bottom=0 bounce=off panRecs=3
```

对照组（同一台机器、同一首歌、同一页）：

| 日志 | `inset.bottom` | `content.h` / `bounds.h` | `bounce` | 唯一差别 |
|---|---|---|---|---|
| 39 | `-1236` | `2132 / 896` | `on` | —— |
| 40（两次进页） | `34` | `896 / 896` | `on` | —— |
| **41** | **`0`** | `896 / 896` | **`off`** | ★ 就是它 |

**② 源码里只有一个地方会写那个属性** —— `NowPlayingOneScreen.applyNoBounceIfWanted()`
（旧第 278–291 行），只作用于那张 NPV 列表（按 `accessibilityIdentifier` 认出来的）。

**③ 机制与 pw v0.21.1 的记载同源**（`PlayerScroll.x` 文件头，GPL-3.0）：
*"下拉关闭骑在列表自己的 pan recogniser 上 …… 把滚动关掉会把那个 recogniser 一起带走 ⇒
播放器再也划不掉"*。我们的"钉住"本来只改 `contentInset.bottom`（范围），所以一直没事；
「禁止回弹」是**那一版唯一越线去碰开关的东西**。

⇒ **在最坏的情况下也只是相关（不是因果）** —— 但它是唯一变量 + 机制讲得通 + 文档当初就把它
标成"唯一风险点"。**能自洽的解释只有这一个。**

## ★ 9.2.1 「pw 那边有这个问题吗？」——**没有，而且是刻意避开的**（2026-10-04 用户问）

因为 `≤ v0.21.1` 是 GPL-3.0（隔离副本 `.spotify-ipa/spotipw-v0.21.1`），这次是**读源码**回答的，
不是猜：在它**整个 `tweak/Sources`** 里搜 `alwaysBounce` / `bounces`，只有 **3 处**，没有一处在播放器列表上：

| 位置 | 用在哪 | 说明了什么 |
|---|---|---|
| `Redesigned/Lyrics/SGRKaraokeView.m:1029` | **它自己的**歌词滚动视图 | 自己造的视图随便设 |
| `App/Onboarding/Tour.m:239` | 它自己的引导页 | 同上 |
| `Redesigned/Player/PlayerScroll.x:38-40` | 播放器：**只改 `contentInset.bottom`**，且 `if (want >= 0 …) return;` | ★ 见下 |

它那句注释（`PlayerScroll.x:6-11`）把"为什么不能关"写得很直白：
*"**The list is not switched off**: the pull that dismisses the player rides on its own pan recogniser…
Turning scrolling off takes that recogniser out with it and the player can no longer be swiped away."*
⇒ 它连"把滚动关掉"都判死，**更没有去碰回弹** —— 因为那同样会动到同一个 pan 链条。

**另一条旁证**（`Redesigned/Player/PlayerField.x:26-28`）：

```objc
// Past the plane's edges: above for the pull that dismisses the player, below for the bounce at the end
// of the cards.
static const UIEdgeInsets kBleed = {200, 0, 600, 0};
```

它给背景场**故意向上多铺 200pt**，理由写的就是"上面是**下拉关闭**那次拖动" ⇒
"顶部下拉 = 关闭"这条机制在 pw 的真机上是**成立的、被依赖的**，不是我们这套基线的错觉。

**所以这是个"我们可以避免、而且它已经避开了"的坑**，不是两个 mod 都有的通病：
> 在这一页上，**别碰 `alwaysBounceVertical`（也别关滚动）**。要"一屏不滚"就只改 `contentInset.bottom`。

## 9.3 改了什么（5 个文件）

| 文件 | 改动 |
|---|---|
| `Sources/EeveeSpotify/Appearance/NowPlayingOneScreen.swift` | 删 `applyNoBounceIfWanted()` / `restoreBounce()` / `originalBounceKey`；`restore()` 只写回 inset；`pin()` 不再调它；**文件头新增 §「曾经的禁止回弹已删除」**（含日志 41 现场与机制）；`diag` 那行的 `bounce=` 从"调参项"变成**只读回归哨兵**（必须一直是 `on`） |
| `Sources/EeveeSpotify/Settings/Sections/Extras/Views/EeveeExtrasSettingsView.swift` | 删 Toggle + `Shadow.nowPlayingNoBounce`；原位留一条⛔注释说明为什么删 |
| `Sources/EeveeSpotify/Shared/Models/Extensions/UserDefaults+Extension.swift` | 删 `nowPlayingNoBounceKey` / `ownedKeys` 那一行 / getter |
| `en.lproj` / `zh-CN.lproj` `Localizable.strings` | 删 `now_playing_no_bounce`（只有这两种语言有它）。**没在 `.strings` 里补注释**：本机没有 Swift 工具链，改 `.strings` 的注释会不会让真机构建出岔子**没法先验** ⇒ 删干净最稳（"为什么删"写在源码文件头与本文件 §9） |

**代价（写清楚，别当成 bug）**：列表拖拽时**仍然有橡皮筋** —— 那是「一屏」目前**无法消除**的残留：
想去掉它就得碰 `alwaysBounceVertical`，一碰关闭手势就坏。要真去掉，得先有"自己接管关闭手势"的办法
（pw 那套 `SPTBar*` 在 9.1.88 上**不存在**，探针实测）。

**自检**：`orion_hook_guard`（325 文件）/ `swift_brace_check`（325）/ `swift_member_check`（270）
/ `l10n_lint --locale en` / `--locale zh-CN` —— **5 条退出码全 0**。
⚠️ 这 5 条**不做类型检查**，本机也没有 Swift 工具链 ⇒ **编译仍只能靠 CI**。

## 9.4 ★ 日志 41 验收清点（用户第二次选择的活儿）

### A. 日志 41 直接判为 ✅ 的（不用再动）

| 项 | 日志 41 的证据 |
|---|---|
| **pw 播放页目标存活** | `[Probe] pw 播放页目标：14 个，在 14 个，缺 0 个 — 全部可搬`；缺失 2 个：`SPTBarOverlayPresentationTransition` / `SPTBarInteractivePresentationController` |
| **取色底** | `[NPVStyle] backdrop 414x896 ← 封面取色 E03038，垫在 UIView 0,0,414,896 之下（那层底色 E03038，subviews=2，layer.sublayers=2，手插子层=0）` + `有 1 个满页着色层是 hidden / 透明 / 不在窗口里 — 已排除`（可见性闸门真的在挡） |
| **迷你条玻璃 v4.7.1** | 7 份 `[Tree]` 里 `id=SPTNowPlayingBar` **全部不带 `bg=`**；`封面色底写回第 1/2 次 — 已再清掉` |
| **标签栏胶囊 v4.10** | `[TabBarPlate] 胶囊 (27,-3 360x60) … dy=[+10.0,+10.0,+10.0,+10.0] 基=图标 [栏 414x83]` |
| **更新日志页 ④** | `[GitHub] /repos/zbzxbg/EeveeSpotifyEvolved/releases/latest -> 5863 bytes`（新仓库名 + 不再是 280 字节限流体） |
| **安装健康度** | 无 `missing ` / `⚠️` 安装失败行；2 条 `ORION ERROR` 都是 SB 那个已知的 `addPlayerObserver:` 装不上 |
| **一屏②（钉住，部分）** | `把列表自带的 inset.bottom=34pt 归零` + `diag … inset.bottom=0 content.h=896 bounds.h=896` + 3 种卡片被折 |

### B. ⏳ 还要人眼/人手的（一次装机 + 一次点按就能清完）

| # | 项 | 判据 | 为什么日志判不了 |
|---|---|---|---|
| 1 | **下拉关闭已经修好** | 装新构建 → 进听歌页 → 下拉 → 播放器关掉 | 这是手势，日志里没有钩子能看见 |
| 2 | **「一屏」文字不再出现** | 设置 → 扩展功能 → 听歌页：只剩「整页封面取色底 / 一屏 / 底部音量条」 | —— |
| 3 | **回弹哨兵** | 新日志里 `[OneScreen] diag … bounce=on` | `off` 回归 = 又有人碰了关闭链条 |
| 4 | **底部音量条落点** | 照片 45 已经对（`8,860,398,32`），正式确认一次 | 照片只能人眼看 |
| 5 | **一屏默认关时的老路径**（顺手） | 关掉「一屏」→ `列表 inset.bottom 已写回原值 …（reason=switch off）` | 日志判得了，但要有人去点 |
| 6 | **切歌后取色底跟到换色** | `[NPVStyle] 跟到换色 → …（第 N 次）` | 日志 41 里**没有**这行（只待了一小会儿、没切歌） |
| 7 | **RTL 贴右** | 一首**有逐词**的阿拉伯语歌 ×2 张截图（「更好的逐词歌词」开/关） | 从未验过 |
| 8 | **双击手势** | 现在页双击左/右 → `[Gestures] double tap left → previous` | 日志 41 里 `[Gestures]` 只有 3 行，**没有一次 double tap** |
| 9 | **「减少打扰」页** | 开一条 → `[Flags] replacement <那条> — N match(es)` | 日志 41 里 `reduce_interventions` **零命中**（那一页没打开过） |
| 10 | 触感 / 上报拦截 / Flag 覆盖 | 各自要**重启**才能装 hook；日志 41 里分别是 `off` / `block=OFF observeOnly=OFF` / `flags=0` | 都没开过 |

### C. 顺手看到的两条（不是这一轮的活，记下来）

* **`[PLAYER] ⚠️ position stalled at 62.4s for ~3s` → 3 秒后 `position resumed`** ——
  "无法播放任何歌曲"那条线的第二个候选现场。探针仍**分不清"暂停"与"卡住"** ⇒ 下一版补**只读 `isPaused`**。
* **歌词这一轮走的是"单源 + 未找到"那条路**：`[Lyrics] Single source: PetitLyrics` →
  `[Petit] PetitLyrics failed: 未找到歌曲` → `[HCUS] lyrics 交付给 Spotify（404 合成 200）— 69 bytes`。
  69 字节是**正常的占位**（这首歌 PetitLyrics 里没有），**不是 v4.11 那个毒丸**（那条已撤销）。
  但 `[Lyrics] chain: …` 这行**没出现** —— 因为 `genius fallback: OFF` 且是单源，本来就不该有。
  想验回退链，得换一个**开着 Genius 回退**的配置再跑。

## 9.5 下一个构建的"五件事"（只验 §9.4-B 那批）

1. **workflow**：`.github/workflows/build-ipa-with-orion-patched.yml`，`liquid_glass` 默认开，其余不动。
2. **设置**：调试 →「启用日志记录」开（「转储视图树」这次不用开）；扩展功能 → 听歌页：
   「整页封面取色底」保持开、「一屏」保持开（**「禁止回弹」这一行已经不存在了**）。
3. **按顺序点**：① 进听歌页 → **下拉关闭**（← ★ 本轮的验收点）；② 再进听歌页 → **切一次歌** →
   等 1 秒（看取色底跟色）；③ 关掉「一屏」→ 再进听歌页（看 inset 写回）；④ 回设置看「扩展功能」
   那一页 —— **「双击手势」整节应当不见了**（§10）；⑤ **调试 →「转储视图树」开着**（§10.4.1 要的
   那份原料），进听歌页**停 3 秒**再走。
4. **发什么**：`eeveespotify_debug_shared 42.log` + 一张设置页（听歌页那一节）截图。
5. **看哪几行**：
   ```
   [OneScreen] diag inset.bottom=0 content.h=896 bounds.h=896 … bounce=on panRecs=3   ← ★ 必须是 on
   [OneScreen] 列表已钉在顶部 — 折掉 …（上拉只回弹；下拉关闭靠列表自己在顶部让位，我们只改范围、不动回弹）
   [NPVStyle] 跟到换色 → …
   [OneScreen] 列表 inset.bottom 已写回原值 …（reason=switch off）
   [NPVTree] #N begin … nodes=…        ← ★ 新：听歌页那一棵的**定向**树（§10.4.1）
   ```
   **不该出现**：`已关掉列表的回弹`（代码已删，出现就说明装的是旧包）、`now_playing_no_bounce` 字面、
   `[Gestures] installed` / `[Gestures] attached` / `[Gestures] diag … singleTapsAbove`（§10 已整体删除）。

---

# 10. 2026-10-04：双击手势**整体删除**（用户拍板）+ 下一道工序

## 10.1 结论

用户问"这双击手势真的有用吗"，查完三件事后拍板：**先删掉，之后再搞**。
**它不是坏了才删** —— 切歌那条路是真的能用（日志 8：`double tap left/right` + 真换曲；日志 17 还有一次）。
删的依据是三条**它自己的**事实：

| # | 事实 | 证据 |
|---|---|---|
| ① | 手势挂在**页面根视图**上 ⇒ **在播放键上方双击也会跳歌**（本该是播放/暂停） | `[Gestures] diag surface=now playing page host=UIView singleTapsAbove=2`（日志 39/40/41；该诊断 39 才加，之前看不见） |
| ② | 它**最该起作用的那一面**（全屏歌词页）默认关，且**从来没验过** —— 30 份日志的 `[Gestures] installed` 里 `fullscreenLyrics=OFF` 出现在除日志 8 之外的全部 | `[Gestures] installed (nowPlaying=ON fullscreenLyrics=OFF behavior=skip)` ×29 |
| ③ | 最近 8 份日志（覆盖一整天）里它**一次都没被用过**（`double tap` 只出现在日志 8/17） | 全量日志扫描 |

## 10.2 删了哪些（5 处，全部删除、不留"按了没反应"的入口）

| 文件 | 删除内容 |
|---|---|
| `Sources/EeveeSpotify/Gestures/PlayerGestures.x.swift` | **整文件删除**（唯一实现；`Gestures/` 目录随之空掉） |
| `Tweak.x.swift` | `activatePlayerGestures()` 调用点 → 换成一条⛔注释（记原因 + 指向本文件 §10） |
| `Settings/Sections/Extras/Views/EeveeExtrasSettingsView.swift` | 「双击手势」整节（Picker + 两个 Toggle）+ `Shadow` 里三个字段 → 换成⛔注释 |
| `Shared/Models/Extensions/UserDefaults+Extension.swift` | 三个键声明 + `ownedKeys` 三行 + 三个 getter |
| `en.lproj` / `zh-CN.lproj` | 7 个文案键（`gesture_section` / `_description` / `_behavior` / `_behavior_skip` / `_behavior_seek` / `_on_now_playing` / `_on_fullscreen_lyrics`）。**这两条历史上只在 en/zh-CN**，其它 25 个语言本来就没有 |

**没动的**：`WordByWordPlaybackControl` / `WordByWordSeeker` / `WordByWordPositionResolver`
—— 它们被歌词层、屏蔽艺人、`PlayerStateProbe` 共用（删的是消费者，不是原语）。
`SponsorBlockHelpView` 里那个 `playerGesturesTitle` 是**另一件事**（SB 的帮助页），别误删。

**自检**：`orion_hook_guard` 324 文件 / `swift_brace_check` 324 / `swift_member_check` 269 /
`l10n_lint` en+zh-CN —— **5 条全 0**（文件数各少 1 = 删掉的那个）。

## 10.3 ★ 要重做时的三条要求（先写下来，免得下次又踩同一个坑）

> 📌 **这三条不是我想出来的** —— 2026-10-04 读了 pw v0.21.1 的 `Shared/Gestures/Gestures.x` +
> `Redesigned/Player/PlayerGestures.x`（GPL-3.0，隔离副本），**它就是这么做的**，而且是照着
> "控制键是兄弟不是子视图"这条真机树结论摆的挂点。照抄思路即可（义务：署名 + 标注改动）。

1. **挂点：`AccessibleCollectionView`（封面/队列那条横向列表）** —— 不是页面根视图。
   它文件头原话：*"the recognizer goes on that and the grid is the screen. Spotify's controls are
   **sibling units rather than children of it**, so a tap on a button never reaches it."*
   ⚠️ 我们真机上的类名是 `_TtC35NowPlaying_ContentLayerPlatformImpl24AccessibleCollectionView`
   （ProbePack 实测在；旧日志 `[Tree]` 也见过它带 `id=nowplaying-contentlayer-collectionview`）。
   顺带一条：它把**单击封面进 3D 倾斜**那个入口也管住了 ——
   pw 是 hook `_TtC35CreativeWorkCommons_CoverArtTiltKit16CoverArtTiltView` 的 `handleTap`，
   开关关着时 `return`（不让倾斜在双击的第一下打开）。我们那 9.1.88 上有没有这个类**要探**。
2. **单击让位 + 按计数重挂** —— pw 的 `yieldSingleTaps(host, tap)`：从 host 往上遍历每一层，
   把**所有 `numberOfTapsRequired == 1` 的 tap** 都 `requireGestureRecognizerToFail:` 我们那个双击；
   并用 `tapsAbove(host)`（host 及以上各层的手势总数）记住"上次看到几个"，
   **变了才重新让位一次**（因为 Spotify 是随控制器加载后加手势的，顺序不受我们控制）。
   —— 这正好解释了我们日志 41 那条 `singleTapsAbove=2`：我们那版**没有任何让位**。
3. **可选（pw 有的额外一件）**：它把双击做成了**分区动作表**（`SGGestureCellAt` + 设置里画的九宫格，
   一格一个动作：上一首/下一首/播放暂停/快进/快退/随机/循环），且动作全部走
   `SPTNowPlayingPlaybackControllerImplementation`（`canSkipNext` / `seekingAllowed` /
   `disallowPausing` 这些**它自己的**能力位）。我们重做时**先只做左/右两区**就够，
   但这解释了为什么它那套比我们那版"能用"得多 —— 它有播放器控制器的能力位可以问。

**必做项排序**：①（挂点）> ②（让位）> ③（分区动作表，可选）。

**★ 三个目标类在 9.1.88 上全都在**（2026-10-04 对 `dump-9.1.88.txt` 核过，逐字同名）：

```
_TtC35CreativeWorkCommons_CoverArtTiltKit16CoverArtTiltView              ← 封面 3D 倾斜的入口（单击）
_TtC35NowPlaying_ContentLayerPlatformImpl24AccessibleCollectionView      ← ★ 手势挂点（封面/队列横向列表）
SPTNowPlayingPlaybackControllerImplementation                            ← 动作要问的能力位
```
（前两个在 dump 里**各只有 1 条**，第三个由 ProbePack 在真机上确认过存在 ——
所以"重做"不是空中楼阁，是把 pw 那套换到我们基线上；`handleTap` 这个**方法名**在 dump 里查不到，
按仓库纪律要在 hook 前用 `responds(to:)` 探测。）

## 10.4 下一道工序（用户说"先下一道工序"）

按**风险从低到高**、且**不再新增未验证的手势/属性写入**排：

| 顺序 | 做什么 | 为什么排这里 | 需要什么 |
|---|---|---|---|
| **1** | **把这一批装机验掉**（§9 的下拉关闭修复 + §10 的删除） | 两处都改了别人的行为面，必须真机裁决 | 一次构建（CI）+ 一次点按 |
| **2** | **歌词搬进播放器**（pw `PlayerLyrics.x` 的思路） | ★ 它是「一屏」能**默认开**的唯一前置（现在折卡片会连歌词卡一起折掉）；也是 kumone 播放页中段那半 | 现有证据够开工；先做"能看见歌词"，渐隐/拖动暂停后置 |
| **3** | **头部 / 控件 / footer** 对齐 kumone | 观感收益大，但**现在没有证据**：pw 说的 `HeaderElementsUnit` / `PlaybackControlsElementsUnit` / `FooterElementsUnit` **全量日志零命中** | **要一次定向取证**：见下 |
| **4** | 封面场（`CoverArtTiltView` / `AccessibleCollectionView` 都在） | 与 3 同族，可以在同一次取证里一起拿 | 同上 |

**为什么 3/4 卡在取证上**：听歌页一棵树约 **800 节点**，而 `ViewTreeDumper` 是**广度优先 + `maxNodes = 400`**
⇒ 底部那坨（头部 / 控件 / footer）**永远被截掉**。日志 40 的 20 份树每份 402 行，正好卡在它自己的上限。
⚠️ 用户**不用重装**就能给这份取证 —— 现在装的那版本来就带「调试 → 转储视图树」。

### ★ 10.4.1 取证缺口**已经补掉**（2026-10-04，同一个构建里）

`ViewTreeDumper` 新增**定向页转储**：

| 改动 | 内容 |
|---|---|
| `ViewTreeDumper.setPage(_:)` | 由**页面自己的 hook** 登记页根（听歌页 = `NPVScrollViewControllerHook` 的 `viewWillAppear` / `viewDidAppear`；`viewWillDisappear` 传 `nil` 撤销）。**只登记一个指针**，不改任何视图、不读任何内容 |
| `dumpOnce()` | 在登记过的页上 ⇒ **只走这一页的子树**、预算 `maxPageNodes = 1200`、tag 用 **`[NPVTree]`**；其它屏照旧 `[Tree]`（整窗 BFS、400 节点） |
| `collect(…, limit:)` | 预算从常量改成参数（整窗 400 / 页面 1200） |

**用法（用户侧，不用改任何设置）**：调试 →「转储视图树」**保持开着** → 进听歌页停 3 秒 →
日志里就会出现 `[NPVTree] #N begin … nodes=…`。那一份里**应当能看到** pw 说的
`HeaderElementsUnit` / `PlaybackControlsElementsUnit` / `FooterElementsUnit`
（或者它们的 9.1.88 真名）—— 这就是"头部排版 / 控件行"那一刀的原料。
⚠️ "结构没变就不重复打"照旧（共用同一个 `lastSkeleton`），所以停着不动只有一份；换歌 / 折卡片会各来一份。

### ★ 10.4.2 老日志在**另一个目录**：`C:\dsh\readlog`（2026-10-04 用户问起"有没有专门测名字的日志"）

**有。** 但它在 `C:\dsh\readlog\eeveespotify_debug {2…19}.log`（**09-26/27** 那批，tweak 还叫
`eeveespotify_debug` 的时期）——**不在** `C:\dsh\ipa\`。

⚠️ **这个坑本仓库已经踩过一次**：`SESSION_2026-10-01.md:39` 原话 ——
*"09-26 之后那批在 `C:\dsh\readlog\`，不在 `C:\dsh\ipa\` —— 只查后者就会得出'从来没有'的错误结论。"*
**今天又踩了一次**（我第一轮找 `[Artwork]` / `[ShellDump]` 时也是只翻了 `ipa`）。⇒ **以后查历史证据，
两个目录一起查。**

**那份日志里现成能用的两样**（都只到 9.1.86 兼容外观，9.1.88 新设计要复核，但**名字**通常照旧）：

| 想要什么 | 在哪份 | 长什么样 |
|---|---|---|
| **播放页控件的名字 + 无障碍标签 + frame** | `readlog 17/18/19.log`（`[ShellDump]`，`dumpControlCandidates` 打的） | `expand _TtCCE16Encore_ButtonKit…6Button8Tertiary label="展开“当前播放”视图" frame=(-36,-195 48x48)` / `share … label="分享歌词" frame=(290,600 44x44)` / `expand _TtC19LegacyUI_ECMCoreKit…12EncoreButton label="将歌词界面扩展至全屏" frame=(334,600 44x44)` |
| **曲目元数据字段全清单**（歌名 / 艺人 / 取色…） | `readlog 2/3/4/8/17/18/19.log`（`[Artwork] metadata keys`） | `["…","album_title","artist_name","artist_name:1","artist_uri","collection.can_add","duration","entity_uri","extracted_color","has_lyrics","image_*_url","title","track_player","view_index"]`（35 个 key，只打 key 不打值） |
| **播放页可见文字**（标题 / 艺人 / 歌词行） | `readlog 11/12/13/14.log`（`[ShellText]`，轮询版） | `[ShellText] [card] SPTEncoreLabel text="…" frame=(267,121 78x18)` |

⇒ 所以"头部 / 控件 / footer"那一刀**不是零原料**：控件名与元数据字段**已有**；
缺的是**新设计（Plastic/Platter）下的层级与 frame** —— 那正是 §10.4.1 那份 `[NPVTree]` 要补的。

---

# 11. ★ 日志 42 / 43 判读（2026-10-04）：**下拉关闭已恢复**、定向树拿到、歌词卡结构确认

> 输入：`C:\dsh\ipa\eeveespotify_debug_shared 42.log`（11654 行，16:30:42–16:31:56）+
> `… 43.log`（**343 行**，16:35:09–16:35:50）。

## 11.1 日志 43 = §9 那次修复的**验收现场** ✅

```
[16:35:11] [Tree] off                                        ← 这次没开转储（故意的，日志才 343 行）
[16:35:11] [INIT] Spotify: 9.1.88 (build 918802209) / iOS 27.0.1
[16:35:18] [NPVPage] 覆盖层已装 0,0,414,896；底部锚 npv.bottomStackView = 没找到（退回安全区底）
[16:35:18] [OneScreen] 把列表自带的 inset.bottom=34pt 归零（内容刚好一屏时，那正是还能往下滑的距离）
[16:35:18] [OneScreen] 列表已钉在顶部 — 折掉 0pt 的卡片范围（上拉只回弹；下拉关闭靠列表自己在顶部让位，我们只改范围、不动回弹）
[16:35:18] [OneScreen] diag inset.bottom=0 content.h=896 bounds.h=896 adj.top=0 adj.bottom=0 bounce=on panRecs=3
[16:35:20] [OneScreen] collapsed card root Lyrics_CardElementImpl.CardView（第 1 种）… UIView … CreatorBiographyCardLayout … InteractableLayoutBackingButton（第 4 种）
```

| 项 | 判定 |
|---|---|
| **★ `bounce=on` + `inset.bottom=0`** | ✅ **回归哨兵成立**：钉住生效、**而我们一个字都没再碰回弹**（对照日志 41 的 `bounce=off`） |
| **一屏：折卡片（4 种）+ 钉顶** | ✅ |
| **`[Gestures]` 0 行 / `已关掉列表的回弹` 0 行** | ✅ 装的是 §10 之后的新包，删除生效 |
| **用户退出听歌页**（16:35:20 折完卡片 → 16:35:35 回来） | ✅ **用户实测"下拉能关掉播放器"** —— 这就是 §9 的修复判据 |
| ⚠️ `npv.bottomStackView = 没找到`（退回安全区底，音量条仍落在 `8,860,398,32`） | 已知问题：与日志 40/41/42 同形。落点没问题，但**锚点该找到才对**（日志 42 的定向树里它明明在 `4,593,406,240`）—— 见 §11.4 待办 ② |

⇒ **§9 收口**。剩下没验的是"关掉「一屏」应当写回 inset"（`restore()`）——不急，随时可测。

## 11.2 日志 42 = **定向转储的第一次收获** ✅

| 项 | 证据 |
|---|---|
| **`[NPVTree]` 真的跑起来了** | **7531 行 / 10 份**，每份 336→**993** 节点（旧转储永远卡在 402） |
| 取色底 + 跟色 | `backdrop … E03038` → `跟到换色 → C84098（第 2 次）` → `A00030（第 3 次）`；可见性闸门挡掉 1~2 个隐形满页层 |
| `[OneScreen]` 0 行 | ⚠️ 那一次「一屏」是**关**的（所以 42 不能当 §9 的验收，43 才是） |
| `[Gestures]` 0 行 | ✅ 删除生效 |

## 11.3 ★ 播放器底部那一坨：新设计下的**真实层级**（`[NPVTree] #20`，993 节点那份）

```
8.UIStackView@4,593,406,240,id=npv.bottomStackView
  9.UIView@0,0,406,67      ← ① 标题行（两个 label：id=title / id=subtitle）
                             + ExplicitIcon / 19andOverIcon（12x12，各带 -internal）
  9.UIView@0,67,406,41     ← ② 进度（外部另有 Components.UI.ProgressBarUnitNowPlaying
                             + SPTNowPlayingSliderV2@-2,10,362,17）
  9.UIView@0,108,406,88    ← ③ 控件行：SPTNowPlayingPlayButton@64x64 / ShuffleButton /
                             Nowplaying-RepeatButton / AddToButton@48x48 / ConnectButtonOutputSwitcher
  9.UIView@0,196,406,44    ← ④ footer
```

★ **pw 说的 `*ElementsUnit` 在 9.1.88 上确实不存在** —— 真身就是上面这四行 **UIView**。
（`Units`/`Unit` 类名在日志 42/43 里**零命中**，可按 id 认：`Components.UI.ProgressBarUnitNowPlaying` 那种。）

**播放页根视图下、与 `npv.bottomStackView` 平级的还有**（同样是第四级）：
`UIStackView@0,48,414,48`（吸顶头，`PassthroughView@0,0,414,896` 是它的兄弟）/
`UIView@0,833,414,62`（底部条）/ `AccessibleCollectionView@0,0,414,896,
id=nowplaying-contentlayer-collectionview`（**pw 挂手势的那条横向封面列表**，里面 `CoverArtCellImpl#5000`
偏移 `@2070000` = 横向队列；全场只有 1 张非 hidden ⇒ 与 pw"一张封面一屏"一致）。

## 11.4 ★ 歌词：**播放器里本来就有歌词卡**（这一刀的地基）

```
9.ContainerRecreateView<LyricsTextState>@0,0,342,256,id=lyrics-card-view
  10.ElementView<LyricsTextElementProps, Any, Any>@0,0,342,256
  11.EncoreButton@0,0,44,44,id=lyrics-expand-button      ← 进全屏歌词
  11.EncoreButton@0,0,44,44,id=lyrics-share-button
  11.EncoreButton@0,0,44,44,id=lyrics-translations-button
```
* 它**随状态换尺寸**：日志 42 的 dump #8/#9/#10 里是 `342x34`（未加载/单行），#13 之后变 `342x256`（歌词到位）；
* 它**就在播放页那条列表里**（`scrolling_npv_collection_view_accessibility_identifier` 的子树），
  所以「一屏」折卡片会把它一起折掉 —— §10 的"默认关"理由**在证据上成立**；
* ⇒ **"歌词搬进播放器"不必从零造**：入口（三个 button 的 id）与容器（`lyrics-card-view`）都在，
  要做的是**在播放器头部/中段给它一块位置**（或接管这块卡的排布），而不是重写渲染。

## 11.5 顺带两条（不是本轮的活）

* `[PLAYER] ⚠️ position stalled at 45.8s for ~3s` → 3 秒后 `resumed`（日志 39/41 之后**第三次**同形现场）
  ⇒ 补一个只读 `isPaused` 的性价比依旧很高。
* 日志 43 里 `npv.bottomStackView` 又是"没找到"：它在**页面子树里**确实不在（日志 42 的定向树里它在
  **列表的子树**里）⇒ `NowPlayingPageOverlay.locateBottomAnchor` 的**窗口兜底**应当找得到，
  但这次**窗口兜底也没找到**（否则不会退回安全区底）。⇒ **待办**：把定向树里那条路径
  （列表 → `npv.bottomStackView`）纳入查找，或把兜底顺序改成"页面 → 列表 → 窗口"。
