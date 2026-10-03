# SESSION_2026-10-11_HANDOFF — 日志 55 · 照片 65/66 · 进/出播放器那一闪（收尾时机 + 意图门禁）

> **新会话先读这一份**（自包含）。上一轮在
> [`SESSION_2026-10-10_HANDOFF.md`](SESSION_2026-10-10_HANDOFF.md)（胶囊按 id 按住、
> 封面改成 pw 的局部手法、页面记忆）。
>
> 写作时：**起点 = 10-10 那批 + 页面记忆**（用户已编译装机 → **日志 55**）。
> 这一轮的输入是**日志 55 + 照片 65/66**；输出是**又一批未编译的源码改动**。
>
> 证据：`C:\dsh\ipa\eeveespotify_debug_shared 55.log`、照片 `C:\dsh\else\{65,66}.jpg`、
> 代码（`CustomLyrics+AllTracksLyrics.x.swift` 的三个 hook 点）、pw 隔离副本
> `.spotify-ipa\spotipw-v0.21.1\tweak\Sources\Redesigned\Player\PlayerMorph.x`（GPL-3.0，只读思路）。

---

## 0. 三十秒现状

| | |
|---|---|
| **这一轮的起点** | 日志 55 = 10-10 那批 + 页面记忆的第一次真机 |
| **✅ 真的成了** | ★ **页面记忆生效**（日志 55 逐字：`re-entering the player expanded (remembered choice)` → 同一秒 `expanded — thumbnail 72pt …`，而且**每一次**进出都对）；照片 63 那两颗胶囊在照片 65/66 里**都不在** |
| **❌ 用户新报** | **进 / 出播放器时，"原本的大封面"闪一下**（照片 66 = 进入时、照片 65 = 退出时） |
| **两个根因（都在我们自己的代码里，日志 55 的时序 + hook 位置可直接对上）** | ① **退出**：`viewWillDisappear` 当场 `remove(...)` ⇒ 封面立刻写回 `alpha = 1`、我们的层当场摘掉，而**退出转场里页面还在屏幕上**（照片 65）② **进入**：`isOpen` 只有"铺成功"才为真，而进页面第一拍**量不到封面**（日志 55：`not expanding (cannot find a visible artwork wide enough (>=200pt)…)`）⇒ "按住原生封面"那条门禁**那一整段窗口是关着的** ⇒ 转场里是原生大封面在动（照片 66） |
| **这一轮改了什么** | 4 个文件（收尾时机推迟 + `wantsOpen` 意图门禁 + 残留清理 + 胶囊发现改成"从听歌页子树找"）；**全部未编译、未装机** |
| **下一个动作** | CI → 装机 → **日志 56 + 照片 67+**（§5 验收单） |

---

## 1. 日志 55 判读

### 1.1 ★ 页面记忆：成了

```
10:29:07  [NPVLyrics] re-entering the player expanded (remembered choice)
10:29:07  [NPVLyrics] expanded — thumbnail 72pt at 28,169,72,72, lyrics area 20,261,374,323,
                      cover shrunk in from -241752,161,366,366, title row lifted -421pt / shifted 88pt
10:29:15  [NPVLyrics] collapsed (reason=page disappeared)
10:29:16  [NPVLyrics] re-entering the player expanded (remembered choice)
10:29:16  [NPVLyrics] expanded — …
```

用户那一分钟里进出了 **6 次**，每一次都是"记得要展开 → 铺上"（10:29:07 / :16 / :18 / :19 / :21 / :22）。
⇒ 记忆这条线**不需要再改**。

### 1.2 胶囊：日志 55 里**没有**"按住"那一行 —— 但也不能据此说它坏了

```
10:28:59  [Declutter] no Now Playing pill found by id in the window
                      (lyrics-npv-switch-button / nowplaying-npv-musicvideos-switch) — visited 6 node(s)
```

* 这一行是**启动瞬间**打的（窗口里只有 6 个节点，App 还没铺 UI）⇒ 它证明不了"胶囊不在"；
* 而它**只报一次**（一次性开关），之后整份日志**再没有一行**说它到底找没找到 ⇒ 读不出结论；
* 照片 65/66 里那颗位置（封面下方、进度条上方）**是空的** ⇒ 那两帧上**没有胶囊**。

⇒ 这一轮把发现改成**从听歌页自己的子树**里找（那棵树只有几百个节点，且调用点在"我们正在这一页上"
的时刻），并且**找到/没找到都会各留一行**。这样日志 56 一定能读出结论（§5.2）。

### 1.3 照片 65/66：进 / 出各闪一次，原因不同

| 照片 | 时刻 | 画面 | 直接对上的代码 |
|---|---|---|---|
| **66** | **进入**（转场中） | 播放器页正在上滑，里面是 **Spotify 自己的版式**：大封面 + 曲名 + 进度条 | `viewWillAppear` → `apply` → `reopenIfRemembered` → `openAndMount` **第一拍失败**（日志 55 的 `cannot find a visible artwork wide enough`）⇒ `isOpen` 回退成 false ⇒ `coverDidLayOut` / `reconcile` 的门禁（`isOpen \|\| coverHost != nil \|\| lastContainer != nil`）**全是 false** ⇒ 那一整段窗口里**没人按封面** |
| **65** | **退出**（转场中） | 页面还在屏幕上，但已经是 **原生大封面**，我们的歌词只剩淡淡的字 | `viewWillDisappear` → `remove(reason: "page disappeared")` → `closeEverything(animated: false)` ⇒ `restoreSpotifyCover()` 当场 `alpha = 1` + 我们的容器/缩略图当场摘掉 |

★ **pw 的做法**（`.spotify-ipa/spotipw-v0.21.1/.../PlayerMorph.x`）：它自己驱动 morph，
`SGRPlayerSetCoverHidden(YES)` 在"播放器的封面布局到位那一刻"按住真封面，
而**写回**放在 `- (void)tearDown`（转场结束）里：`if (_coverHidden) SGRPlayerSetCoverHidden(NO);`
⇒ **收尾时机跟着转场走**，不在 `viewWillDisappear` 当场收。这一轮就是照这条改的。

---

## 2. 这一轮改了什么（**全部未编译、未装机**）

| 文件 | 改动 |
|---|---|
| `Lyrics/CustomLyrics+AllTracksLyrics.x.swift` | `viewWillDisappear` 里**不再** `remove(...)`，改成 `NowPlayingLyricsPlate.pageWillLeave()`（**只记一笔**）。注释写清为什么（照片 65 + pw 的 `tearDown` 出处） |
| `Appearance/NowPlayingLyricsPlate.swift` | ★ 新增 `pageLeaving`（页面要走了，但**什么都不收**）；★ 新增 `wantsOpen`（**"打算铺着"比 `isOpen` 宽一档**，进页面第一拍就把它立起来）；`closeEverything` 清这两个；`reconcile` 里把收尾放在"**页面真的不在窗口里**"那一刻（并且放在 `page.window != nil` 那道 guard **之前** —— 否则页面一走那条 guard 直接 return，永远等不到收尾）；"打算铺但还没铺上"的那段窗口**每拍也按住封面**；`coverDidLayOut` 的门禁加 `wantsOpen`、并且 `pageLeaving` 时不动；`apply` 进页面先清**上一程的残留**（否则"上次展开"的层会留在这一次没要求展开的页面上）；顺手调 `DeclutterChrome.adoptNowPlayingPills(from: page)` |
| `Appearance/DeclutterChrome.x.swift` | ★ 新增 `adoptNowPlayingPills(from:)`：**从听歌页子树**按 id 认那两颗胶囊（1s 节流、只在有槽位空着时走查），**找到/没找到都留一行日志**（修 §1.2 那个"读不出结论"） |
| `Tools/eevee-hookfinder/SESSION_2026-10-11_HANDOFF.md` | 本文件 |

### 2.1 时序（改完之后的"进入/退出"应该是这样）

```
进入：viewWillAppear → apply → reopenIfRemembered
        → wantsOpen = true            ← 门禁当场打开
        → openAndMount（可能这一拍量不到 ⇒ isOpen 回退，但 wantsOpen 还在）
        → 之后每一拍：keepNativeCoverHidden + coverDidLayOut（事件）都按得住原生封面
        → 量到 ⇒ 铺上（thumbnail / 歌词区 / 标题上移）

退出：viewWillDisappear → pageWillLeave（只记一笔，页面保持我们的样子）
        → 转场期间：reconcile 走 `if pageLeaving { ensureToggleZone; return }`，**不写回封面、不撤几何**
        → 页面真的不在窗口里（page.window == nil）⇒ closeEverything + removeToggle（屏幕外，看不见）
```

---

## 3. 本机自检（全绿）

```
python Tools/eevee-hookfinder/orion_hook_guard.py      # OK 327 文件
python Tools/eevee-hookfinder/swift_brace_check.py     # OK 327 文件
python Tools/eevee-hookfinder/swift_member_check.py    # OK 272 文件
python Tools/eevee-hookfinder/swift_string_check.py    # OK 276 文件 / 47278 行
python Tools/l10n_lint.py --locale en                  # exit 0
python Tools/l10n_lint.py --locale zh-CN               # 425 keys, 0 missing, 0 extra
```

⚠️ **不做类型检查**（本机没有 Swift 工具链）；新代码里几处"时序"只能靠真机验（§5）。

---

## 4. 下一轮：CI → 装机 → 日志 56 + 照片 67+

### 4.1 操作顺序

1. 进播放器（此时记忆应是"展开"）→ **录屏/连拍前 1 秒**：**不许**出现"大封面 + 原生版式"的画面；
2. 按左上角 `v` **退出播放器** → 再连拍：退出动画里页面**必须一直是我们的样子**（缩略图 + 歌词），
   **不许**闪出原生大封面；
3. 反复进出 **5 次**（每次停 1 秒）；
4. 点**收起**歌词 → 退出 → 重进 ⇒ 大封面（这是"收起"的记忆，正常）；
5. 换一首**有 MV** 的（胶囊会出现的那种）→ 拍一张：那两颗胶囊不该在；
6. 回归：三颗传输键 / 歌词键能开能关 / `bounce=on` / 迷你条与首页开关。

### 4.2 预期日志

```
[NPVLyrics] re-entering the player expanded (remembered choice)
[NPVLyrics] expanded — thumbnail 72pt at …, lyrics area …, title row lifted …
   —— 退出时（转场里**没有** collapsed 那一行，它要等到页面真的不在窗口里）：
[NPVLyrics] collapsed (reason=page disappeared)          ← 这一行现在出现在 page.window == nil 之后
   —— 胶囊（新增的两条"有结论"的日志，二选一）：
[Declutter] hid the Now Playing pill row (lyrics-npv-switch-button / nowplaying-npv-musicvideos-switch) — hide #1
[Declutter] the player page has no pill with id lyrics-npv-switch-button / nowplaying-npv-musicvideos-switch
            (visited N node(s) of that page)
```

### 4.3 通过判据

| # | 判据 |
|---|---|
| ① | **进入**播放器的转场里**没有**"原生大封面 + 原生版式"那一帧（对比照片 66） |
| ② | **退出**播放器的转场里页面**一直是我们的样子**，没有原生大封面（对比照片 65） |
| ③ | 退出后页面真的收干净了：**再进**的时候不会出现"缩略图在、歌词不在"的半成品（看日志里 `collapsed (reason=page disappeared)` 有没有出现） |
| ④ | 胶囊：日志里出现上面两条之一 ⇒ 下一次判读有结论（照片里也不该看到它们） |
| ⑤ | 回归：传输键 / 歌词键 / `bounce=on` / 迷你条与首页开关不受影响 |

### 4.4 失败时要警惕的

* 进入**还闪** ⇒ 看有没有 `cover-tilt guard rejected N layout(s)`：门禁某一环不过
  （`window` / `width >= 200` / 祖先 `CoverArtCellImpl` / "和 tilt 等大的直接子视图"）；
* 退出**还闪** ⇒ 说明收尾仍然发生在转场里 —— 检查 `page.window` 在转场期间是不是**非 nil**
  （若 Spotify 把这一页从窗口里摘走了，那"推迟到 window == nil"就会**提前**触发 ⇒
  改成"等一次 `didBecomeActive`/下一个 runloop 再收"或按转场时长推迟 ~0.4s）；
* 退出后**残留**（再进时是半成品）⇒ 看 `left over from the previous visit` 那一行有没有出现
  （出现了说明上一程没收干净，但至少被清掉了）；
* 胶囊那行**一直说没找到**，而照片里也没看到 ⇒ 可能这两颗只在特定内容下出现（有 MV / 有 canvas 的歌），
  下一次让用户专门放一首有 MV 的歌再抓。

---

## 5. 规矩（这一轮）

1. ★★ **"收尾时机"要和"转场时机"对齐**：`viewWillDisappear` 时页面**还在屏幕上**，
   当场把别人的东西写回去 = 在转场里当场露出来。**收尾要等页面真的不在窗口里**
   （pw 把这一步放在 `tearDown`）。这一条同时解释了两代闪（57/61/64 是"进入之后"，65 是"退出之中"）。
2. ★★ **门禁里写"结果"（`isOpen`）而不是"意图"（`wantsOpen`）**，会把"还没成功"的那段窗口
   整段漏掉 —— 而那段窗口正好是转场最显眼的时候（照片 66）。
3. ★ **一次性日志（"只报一次"）不是诊断**：它在**错误的时刻**（启动瞬间、窗口只有 6 个节点）
   就把唯一那次机会用掉，之后就再也读不出结论。**改成"每次有结论就报"**（找到/没找到各一行）。
4. ★ **走查的起点要选对**：整窗 3000 节点会被首页那棵大树吃掉预算；**听歌页自己那棵树只有几百个节点**，
   而且调用点就在"我们确实在这一页上"的时候。
5. ★ **进页面先清上一程的残留**：把收尾推迟之后，"残留"从罕见变成常态 —— 必须有人兜底。

---

## 6. 还没做的（与上一轮相同，按优先级）

| 序 | 做什么 | 前置 |
|---|---|---|
| 1 | 按日志 56 收口 §4 那五条 | 日志 56 |
| 2 | ★ **排版向 kumone 看齐**（标题在顶、封面居中、歌词替代封面区）——「搬 holder 不搬控件」 | 三个 `*ElementsUnit` 类都在 9.1.88（已核） |
| 3 | **「突然无法播放全部歌曲」**：下一步是补只读的**音频密钥路径探针** | —— |
| 4 | `NowPlayingPageOverlay` 的"没找到就接着试几拍" | —— |
| 5 | 封面改成"自己持有"（复用 `LyricsArtworkResolver`） | 要先把 `layoutAndMount` 的同步返回改成"异步图到了再铺" |
| 6 | 「一屏」橡皮筋：用户拍 A / B（10-06 文档 §2.5） | 用户决定 |
| 7 | 刷新 customize 种子（9.1.76 → 9.1.88）；`swift_string_check.py` 接进 CI | —— |

---

## 6.5 ★ 同一天追加：照片 67（我们）vs 照片 68（kumone）—— "还差 50~60%" 量出来了

用户原话：**「图片 67 是现在的样子，68 是 kumone 的页面，是不是还差个百分之五六十左右，怎么搞比较好」**。

**逐区块量测表 + 五片改法（含风险与落点）写在
[`KUMONE_REFERENCE.md`](KUMONE_REFERENCE.md) §6**。三句话版：

1. **最大的一项已经改了**（本轮）：歌词排版换 `.player` 档 —— `.preview` 的块间距只有 **10pt**，
   一屏塞 7–8 行；kumone 是 **26pt**、一屏 4 块（照片 68 量的：主歌词 22pt / 译文 17pt / 块距 26）。
   ⇒ `AppleMusicLyricsTextProfiles.swift` 新增 `.player`，`AppleMusicLyricsOverlay` 按
   `showsPreviewHeader == false` 选它。
2. **header 比 kumone 低 ≈100pt**（我们 169–241 / kumone 67–133）：根因是缩略图 y 跟着**原生封面**
   （`thumb.y = cover.minY + 8`，日志 55 的 `cover.minY = 161`）；kumone 贴着自己那根横条。
   目标应是"**导航条下沿 + 8 ≈ 104**"，那 65pt（96–161）现在是白扔的。
3. **歌词块下边界比 kumone 高 ≈80–100pt**：`measure()` 锚在 `bottomStackTop`（≈593），
   而进度条在 ≈693 ⇒ 先用量 id 的进度单元顶边试，**日志里把两个数都打出来**再定。

②③ 都要动别人的布局（Spotify 的标题行 / 底部堆）⇒ **一轮一片、装一次机看一次**。

### 6.6 同一天第二次追加：音量条（照片 69）

用户：**「音量条是有点，只是挺难看的」** + **「至于歌词再展示翻译和罗马字之后再说」**。

* **音量条本来就有**（`nowPlayingVolume`，实现在 `Appearance/NowPlayingPageOverlay.swift`），
  难看的原因是**它就是系统原样的 `MPVolumeView`**：iOS 26 上那是"玻璃胶囊轨 + 大钮、铺满整宽"
  （照片 69 里横在页面最底、白钮贴左边缘的那条）。
* kumone（照片 68）是：**≈4pt 细轨 + ≈14pt 小圆钮 + 两端小喇叭**，整行左右内缩 ≈42pt。
* ⇒ 本轮改（**只走公开接口**，不改它的内部层级）：
  `setMinimumVolumeSliderImage` / `setMaximumVolumeSliderImage` / `setVolumeThumbImage`
  喂进自绘的**可拉伸胶囊轨**（已播放 92% 白 / 未播放 22% 白）与**带投影的白圆钮**；
  外面套我们自己的 `eevee-npv-volume-row` 容器，两端各放一个装饰图标
  （`speaker.fill` / `speaker.wave.3.fill`，白 55%），行左右内缩 24pt。
* **歌词的译文 / 罗马字按用户的意思"之后再说"** ⇒ 本轮不动，计划里降级为"等用户开口"。

### 6.7 同一天第三次追加：**"不做点击、只要像"** —— 几何那两片已经做完

用户问：**「如果在暂时不做点击功能，只要求像/一样的情况下，我们现在能和 kumone 一样吗」**。

**答复与逐条对照写在 [`KUMONE_REFERENCE.md`](KUMONE_REFERENCE.md) §6.3**。落在代码里的三处：

| 片 | 改动 | 文件 |
|---|---|---|
| ② | 缩略图**不再跟原生封面**：`thumb.y = navBarBottom + 8`（导航条用 id `now-playing-minimize-button` 量）⇒ 169 → ≈104 | `NowPlayingLyricsPlate.measure()` |
| ③b | `lyricsTop` 20 → **66** ⇒ 歌词从 **242** 开始（= kumone 照片 68 的实测值） | 同上 |
| ③ | 歌词块底边**锚到进度条单元**（id `Components.UI.ProgressBarUnitNowPlaying`）− 19 ⇒ 块高 323 → ≈400（kumone 381） | 同上 |

★ 顺带把**三个锚点的实测值**打进 `[NPVLyrics] expanded — … (anchors: navBottom=…, progressTop=…, bottomStackTop=…)`：
这两片几何的唯一验证手段就是那一行（量不到会打 `not found`，**不编造**）。

**剩余的三处结构性差别**（§6.3 表）：
① 顶部是 Spotify 的 `v`/`1`/`⋯`，不是 kumone 的拖拽横条 —— **不该动**（那是关播放器的唯一入口）；
② 歌词不带译文（用户说之后再说）；
③ header 右侧没有 ♥ / ⋯（纯装饰可补，但不接动作）。
另有两处**功能取舍**（藏 shuffle/repeat、藏分享）要看用户点不点头。

---

## 7. 未验证声明（**不要去掉这一段**）

* **本轮 3 个源码文件 + 1 份文档全部没有编译过、没有装机过。**
* **最后一版真机数据是日志 55**（= 10-10 那批 + 页面记忆）；照片 65/66 都是那一版。
* ★ **"退出转场期间 `page.window` 仍非 nil"是本轮改动的前提**，它来自"页面还在动画里往下滑"
  这个观察（照片 65 就是那一帧），**没有日志直接证明**。若它其实是 nil，收尾就会在转场里提前发生，
  照片 65 的闪会原样回来 —— 失败判据与对策写在 §4.4 第二条。
* ★ **胶囊那两条日志是"为了下一轮能读出结论"才加的**：日志 55 里既没有"按住"也没有"没找到"
  （只有启动瞬间那次 6 节点的空走查），所以"照片 65/66 里没有胶囊"到底是**我们藏住了**
  还是**这两颗本就不出现**，现在**分不出来**。
* ★ 本轮**没有**再派独立只读复核：改动集中在"时序 + 门禁"两处，且每一处都在注释里写明了
  证据与反例；若下一份日志显示还有闪，**下一轮第一件事就是派复核**。
