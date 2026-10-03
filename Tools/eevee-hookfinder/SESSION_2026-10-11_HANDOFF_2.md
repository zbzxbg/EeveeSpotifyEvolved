# SESSION_2026-10-11_HANDOFF_2 — 控件条（照片 71 圈的两处）+ 关歌词时标题去左上角（照片 72/73）+ 无时间轴歌词不再误报

> **读的顺序**：先 [`SESSION_2026-10-11_SUMMARY.md`](SESSION_2026-10-11_SUMMARY.md)（整场汇总：照片 60–70 / 日志 53–55），
> 再看本文件。上一轮的交接在 [`SESSION_2026-10-11_HANDOFF.md`](SESSION_2026-10-11_HANDOFF.md)。
>
> **这一轮的输入**：用户点名的参考件 —— `C:\dsh\ipa` 里的日志（最新仍是 **55**）、`Spotify-9.1.88.ipa`、
> `dump-9.1.88.txt`、`C:\dsh\else\{40,41}.jpg`（kumone）、`70.jpg`（我们）、以及**新给的 71/72/73**。
> **输出**：2 个源码文件 + 2 个 l10n 文件（**未编译、未装机**）。

---

## 0. 三十秒现状

| | |
|---|---|
| **仓库起点** | `c8f766e`，之后这一场有两笔：`f2dc707`（S1 + 当时那版"✓ 搬 header"）、本轮的这一笔 |
| **★ 用户改了方案** | 上一轮点头的「绿 ✓ 搬进 header」**已按第二版方案撤掉**（用户原话：「那个绿色勾就**让它呆在那里**」）⇒ 换成 **控件条**方案（§2） |
| **S1 保留** | 无时间轴歌词不再冒充「未找到歌词」（§3）—— 这一条不受方案变化影响 |
| **❌ 日志仍停在 55** | `C:\dsh\ipa` 里**没有** `b9e250b` 之后的日志 ⇒ 上一轮那张验收单（转场 / 锚点 / 三种文案 / 胶囊计数）**仍然挂着** |
| **这一轮改了七件事** | ★ **控件条**：[分享 58] [歌词键 215] [绿 ✓ 371（不动）] ★ **关着歌词时标题/歌手贴左上角** ★ **音量条小喇叭抬 5pt** ★ 再修四处（照片 74 + 日志 56）：**收尾顺序**（不再"短暂重合"）、**分享键改用替身热区**（能点了）、**歌词容器放行触摸**（收藏键能点了）、**标题加动画 + 图标恒定为歌词气泡** |
| **下一个动作** | CI → 装机 → **日志 56 + 照片 74+**，按 §6 收口 |
| **本机没有 Swift 工具链** | 六条自检全绿（§5），类型检查只能靠 CI |

---

## 1. 照片 71/72/73 的实测（这一轮**重新裁图量过**）

### 1.1 用户的原话（**照这句做**）

> 照片 71 我圈的两个，一放分享按钮，二放歌词开关，然后那个绿色勾就让它呆在那里。
> 其他的按键也不用改了。但是这个方案要解决一个问题（照片 72）：一这个位置会占用
> 不开歌词进入播放器这个功能不开启时，歌手/歌曲名字会挡住。所以（照片 73）：可以和
> kumone 一样，在不开展示歌词的情况下，就把歌曲/歌手放到左上角，在开启展示歌词之后，
> 封面再到左上角，然后歌曲/歌手往右让位。

### 1.2 量出来的数（591×1280px → 414pt 宽，×0.7005）

| 东西 | 照片里的位置 | 换算 |
|---|---|---|
| 圈 ①（放**分享键**） | 中心 ≈(83, 906)px | **(58, 635)pt** |
| 圈 ②（放**歌词键**） | 中心 ≈(317, 892)px | **(222, 625)pt** |
| 绿色 ✓（**不动**） | 中心 ≈(531, 894)px | **(371, 626)pt** |
| 进度条 | y ≈969px | **679pt** |
| 照片 72：原生**歌名** | x 48px、y ≈882px | x **34pt**、y **618pt** |
| 照片 72：原生**歌手** | y ≈914px | **640pt** |
| 照片 72：**原生大封面顶边** | y ≈207px | **145pt** |
| 照片 72：导航条下沿（`v` 那颗 48pt） | 46…94px | **96pt** |
| 照片 73（kumone）：歌名 / 歌手 | 124 / 158px | **87 / 111pt**（x 都是 34） |

⇒ 两条结论：
1. **控件条 = y 626 那一条**（绿色 ✓ 本来就在那儿），三颗按 **58 / 215 / 371** 排（等距 ≈157；
   ② 用户量的是 222，取 215 纯粹为了等距 —— 不满意就改 `toggleCenterX`）；
2. **关着歌词时标题行只有 96…145 这 49pt 可用**（标题 24 + 歌手 22 = 46pt）⇒ 落点取 `navBottom + 2 = 98`。

---

## 2. 这一轮改了什么（**全部未编译、未装机**）

| 文件 | 改动 |
|---|---|
| `Sources/EeveeSpotify/Appearance/NowPlayingLyricsPlate.swift` | ★ **控件条**：新增 `applyControlBand` / `clearControlBand` / `visibleShareButton` / `firstVisibleShareButton` / `isOnScreen` / `bandNote` + 常量 `controlBandMidY=626` / `shareButtonCenterX=58` / `toggleCenterX=215`；`toggleFrame` 改成"**先控件条**，量不出来才退回老的三级判据（`fallbackToggleFrame`）"；★ **关着歌词时标题行去左上角**：`applyClosedTitleTransform` / `clearClosedTitleTransform`（落点 `navBarBottom + 2`）；调用点：`apply` / `reconcile`（每拍）/ `remove`（关开关）；★★ **第三批（照片 74 + 日志 56）**：`settleAfterClosing()`（`closeEverything` 的 `defer` —— 修"短暂重合"）、`ensureShareRelay` / `relayShareTap` / `NowPlayingShareRelayTarget`（**替身热区**）、`NowPlayingLyricsContainerView` + `applyContainerPassThrough`（**容器放行触摸**）、`moveTitleRow`（**动画**）、`applyToggleAppearance` 恒定歌词图标 |
| `Sources/EeveeSpotify/Appearance/NowPlayingPageOverlay.swift` | ★ **音量条两端小喇叭抬 5pt**（新常量 `volumeGlyphLift`）：用户报「那两个扬声器的高度没有和那个调整音量的行一样高」。逐像素量过（见 §4.6），偏差**不在我们这边** —— iOS 26 的 `MPVolumeView` 把轨画在它自己 frame 中线上方 ≈5pt；只补偿我们自己的两个装饰字形，并把实测几何打进安装日志（`volumeRowInternals`） |
| `layout/…/EeveeSpotify.bundle/{en,zh-CN}.lproj/Localizable.strings` | 新键 `lyrics_no_timeline`（en: "These lyrics have no timing" / zh-CN:「这首歌的歌词没有时间轴」）—— **S1，保留** |
| `Tools/eevee-hookfinder/SESSION_2026-10-11_HANDOFF_2.md` | 本文件 |

### 2.1 时序（改完之后）

```
进播放器（功能开着、没展开歌词）
  viewWillAppear → apply → applyControlBand（分享键 → 58,626）
                        → applyClosedTitleTransform（标题行 → 98，x 不变）
  之后每拍：reconcile 先 applyControlBand，再 applyClosedTitleTransform（幂等）

点歌词键展开
  toggle → rememberExpanded(true) → openAndMount → layoutAndMount
        → applyTitleTransform（标题行 → 缩略图右边；**覆盖**刚才那条"去左上角"）
        → 歌词铺上；控件条不动（分享键仍在 58,626）

再点收起
  closeEverything（isEnabled 且页面还在窗口里）
    ├ 封面飞回原位（0.45s）
    └ defer → settleAfterClosing()：控件条就位 + **标题行从缩略图右边滑回左上角**（0.45s，同一个动画）
  页面真的走了（page.window == nil）→ clearControlBand + clearClosedTitleTransform（屏幕外）

点分享键（58,626）
  替身热区（透明 44×44，压在最前面）收到触摸
    → sendActions(for: .touchUpInside) 转给那颗真的 ShareButtonNowPlayingView
    → 日志：[NPVLyrics] relaying a tap to the share button (…)
```

---

## 3. S1 ★ 无时间轴歌词被误报成「未找到歌词」——判据拆开了（**保留**）

事实链（两行代码就能对上）：

| # | 事实 | 出处 |
|---|---|---|
| ① | `LyricLinesAdapter.toAppleMusicLyricLines()` 第一件事就是 `.filter { $0.offsetMs != nil }`；**一行时间都没有 ⇒ 返回空** | `Sources/EeveeSpotify/Lyrics/AppleMusic/LyricLinesAdapter.swift:21` |
| ② | `currentLines()` 把"空"翻成 `nil` ⇒ 我们这层没有行模型可画 | `NowPlayingLyricsPlate.swift`（`currentLines()`） |
| ③ | 注入给 Spotify 的那份 payload **是带这些行的** ⇒ Spotify 自己的歌词卡列得出全文 | 上一轮文档 §5·S1 |
| ④ | 旧 `noticeText()` 第 ③ 条把"有行却画不出来"**一律**写成「未找到歌词」 | 改动前 |

改法：第 ③ 条先问"**有没有一行带 `offsetMs`**"，没有 ⇒ 新键 `lyrics_no_timeline`；有 ⇒ 才按"转换异常/没找到"说。
四档现在各说各的：纯音乐 / **没有时间轴** / 查完了没有 / 还在查。

> 还没做（用户没点）：**静态列出全文**（不高亮不滚动）—— kumone 照片 41「有封面、没有歌词排版」那一档。
> 它要动渲染层（`LyricLine.time` 是必填），属于另一件事。

---

## 4. 控件条与"标题去左上角"的三条设计取舍

| # | 取舍 | 为什么这么定 |
|---|---|---|
| ① | **分享键是"视觉"搬运：搬过去之后点不到** | UIKit 的 hit-test 在祖先那层就问 `point(inside:)`；它被抬到 626 之后已经在 footer 那一行（≈792…836）之外。**用户 2026-10-11 明确选了"只搬，不要点击"**（「像就行」）⇒ 要分享走右上角 `⋯` 菜单里的 Share。`bandNote` 会把"到底被谁挡住"写进日志 |
| ② | **绿 ✓ 一颗都不动** | 它本来就在 626 那一条（371），是控件条的天然参照物；用户原话「让它呆在那里」 |
| ③ | **标题行只在"关着歌词"时才去左上角** | 展开时标题的位置由 `applyTitleTransform` 管（缩略图右边），两者写的是**同一行的 transform**，后者赢；`apply` 里因此先判 `isOpen` |

★ 还有一条**没动**的：`now-playing-toggle-button`（`Tertiary@0,0,48,48`）**至今没定位**（不在照片 70/71/72
的任何可见位上）—— 下一份 `[NPVTree]` 里能看出它在哪儿，**先别动它**。

### 4.5 ★ 第三批：照片 74 + 日志 56 之后的四处修复

日志 56 是这一批的**真机判决**（`b9e250b` 之后的第一次行为面数据），先记它判了什么：

| 项 | 日志 56 逐字 | 判定 |
|---|---|---|
| 三个锚点 | `(anchors: navBottom=96, progressTop=660, bottomStackTop=593)` | ✅ 全是数字 |
| 歌词区 | `lyrics area 20,242,374,399`（242…641） | ✅ 与 kumone 对齐 |
| 缩略图 | `thumbnail 72pt at 28,104,72,72` | ✅ 贴导航条下沿 |
| 音量条 | `glyphLow 0,1,16,16 glyphHigh 350,1,16,16 (glyphs lifted 5pt to meet the track)` | ✅ 5pt 抬升生效 |
| 胶囊 | `[Declutter] hid the Now Playing pill row (…) — hide #1` | ✅ 终于有结论了 |
| 分享键 | `share button moved … to 36,604,44,44 (visual only: _TtGC13Element_UIKit11ElementView… does not contain the landing spot, so taps stay dead)` | ⚠️ 位置对了，但**点不到**（预测命中） |

用户这一批报了四件，逐条：

**① 点歌词键时"歌名/歌手和分享键短暂重合"（照片 74 就是那一帧）**
根因在**我们自己的收尾顺序**：`closeEverything` 里先在函数中段摆了"关着的样子"（标题 → 左上角），
而函数后段那句 `lastUnit?.transform = .identity`（撤销展开时的位移）**当场把它撤销** ⇒
关掉之后的 **0.3s** 里标题回到原生位置（618），正好压在控件条第 ① 处的分享键（58,626）上。
修法：把"关着的样子"挪到 **`defer`** 里（无论从哪条返回都在**最后**跑），见 `settleAfterClosing()`；
并且**故意不先撤**展开时那段位移 —— 让标题直接从"缩略图右边"滑回左上角。

**② 分享键点不动** —— 它被**自己祖先**的边界挡住（日志 56 那条 `…ElementView… does not contain
the landing spot`）。`transform` 改不了父视图的命中范围 ⇒ 加了一颗**透明的替身热区**
（`eevee-npv-share-relay`，44×44 盖在同一格，压在最前面），点它 = `sendActions(for: .touchUpInside)`
转给那颗真按钮。为什么这次可以用 `sendActions`（上一轮刚删过"替用户按"）：那次删的是**切换类**
动作（按两次回到原状 + 落盘偏好）；分享是"打开面板"，幂等无状态。

**③ 收藏键（＋/绿 ✓）点不动** —— ★ 这个是我上一轮**漏掉**的：**我们自己的歌词容器**铺满
242…641（`isUserInteractionEnabled = true` 且在最前面）⇒ 把那一整片触摸全吃了。
修法：容器换成 `NowPlayingLyricsContainerView`，**只在那一条放行**
（`point(inside:)` 里把 `controlBandMidY − 22` 以下让开），歌词正文照旧吃触摸。

**④ 两件视觉**：
* **动画**（用户：「能不能给歌曲/歌手移动到右边的时候，加个动画」）——
  标题行的两段位移统一走 `moveTitleRow()`，**只在目标真的变了**时才动画
  （0.45s + 临界阻尼 + `BeginFromCurrentState`，与封面同一套；"每拍重开动画"是本仓库的老坑）。
  第一程（这一行还在原生位置）**不**动画 —— 那是进页面时从屏幕中间跳到左上角，滑过去更怪。
* **箭头**（用户：「它原本就是歌词图标，就无论怎么点，它看起来都是那个歌词图标」）——
  `applyToggleAppearance` 里展开时**不再**换 `chevron.down`，永远画 `quote.bubble.fill`。



### 4.6 音量条：两个小喇叭为什么低了 5pt（照片 71 逐像素）

用户原话：**「那两个扬声器的高度没有和那个调整音量的行一样高」** —— 对的。

| 东西 | 像素行（照片 71） | 中线 |
|---|---|---|
| 音量**轨**（那 5 行实心像素，宽 201px） | y 1196…1200 | **839.3pt** |
| **圆钮**（白色 19 行，直径 13.3 ≈ 14pt） | y 1189…1207 | **839.2pt** |
| **左**喇叭字形 | y 1196…1214 | **844.1pt** |
| **右**喇叭字形 | y 1200…1211 | **844.4pt** |

⇒ **轨与圆钮同心**，只有两个字形低 ≈4.9pt。而代码里两者都按"行中线"摆
（`slider.y = (28−28)/2 = 0`、`glyphY = (28−16)/2 = 6`）⇒ 偏差**不在我们这边**：
**iOS 26 的 `MPVolumeView` 把轨（和钮）画在它自己 frame 中线上方 ≈5pt**（行内局部：轨 ≈9.2，中线 14）。

处理：新增 `volumeGlyphLift = 5`，只把**我们自己的**两个装饰字形抬上去 —— **不动**系统那条音量条的位置
（它的触控区照旧），也**不去猜**它内部的 `UISlider`（那是私有层级，本文件早就定过这条纪律）。
为什么抬字形而不是把 slider 下移 5pt：slider 下移会把触控区一起推到更靠屏幕底边；
抬字形是零触控影响的等价观感（kumone 照片 40/41 那条也是"三样在一条线上"）。

---

## 5. 本机自检（六条全绿）

```
python Tools/eevee-hookfinder/orion_hook_guard.py      # OK 327 文件
python Tools/eevee-hookfinder/swift_brace_check.py     # OK 327 文件
python Tools/eevee-hookfinder/swift_member_check.py    # OK 272 文件
python Tools/eevee-hookfinder/swift_string_check.py    # OK 276 文件 / 48047 行
python Tools/l10n_lint.py --locale en                  # exit 0
python Tools/l10n_lint.py --locale zh-CN               # 427 keys, 0 missing, 0 extra
```

⚠️ 六条都**不做类型检查**（`CGAffineTransform(a:b:c:d:tx:ty:)` 的逐参数、`@discardableResult` 的调用点、
`flatMap` 那两处 Optional 链只能靠 CI）。

---

## 6. 下一轮：CI → 装机 → **日志 56 + 照片 74+**

### 6.1 操作顺序

1. **不开歌词**进播放器 → 看照片 72 那一版式：
   * 歌名/歌手应在**左上角**（≈y 98，x 不变 ≈34），**不压**大封面（封面顶 145）；
   * **分享键**应在 (58, 626) 那一格；**歌词键**在 (215, 626)；**绿 ✓** 还在 (371, 626)；
   * 底部那两排（shuffle/prev/play/next/repeat、Connect/收起/队列）**一颗都不该变**；
2. **点歌词键**展开 → 缩略图回左上角、歌名/歌手**右移**（现在就是这样）、歌词铺上；
   那一条里三颗**位置不变**；
3. **收起** → 立刻回到第 1 步的样子（标题回左上角，不留残影）；
4. 来回 5 次，并**换一首歌**（标题行/分享键都是新对象，看会不会有半拍错位）；
   ★ 重点：**收起的那一瞬间不许再出现"歌名压住分享键"**（照片 74 那一帧）——动画期间也不许；
5. **点一下分享键**（58,626 那一颗）：应该弹出 Spotify 的分享面板（日志里会出现
   `relaying a tap to the share button (…)`）；**再点一下绿 ✓/＋**（371,626）：应该能收藏/取消收藏；
6. **音量条**：两个小喇叭要和**那条轨（和圆钮）在同一条线**上（照片 71 里它们低了 5pt，见 §4.6）；
7. **展开/收起各看一次**：歌名/歌手是**滑**过去、不是跳过去；那颗键**始终是歌词气泡**（没有向下箭头）；
8. 顺便把上一轮那张单子一起拍了（进出转场不闪、三种说明文案、胶囊不在）。

### 6.2 预期日志（**逐字**）

```
[NPVPage] overlay installed 0,0,414,896; bottom anchor … = …; volume slider 24,830,366,28;
          volume row 24,830,366,28 slider 26,0,314,28 glyphLow 0,1,16,16 glyphHigh 350,1,16,16
          (glyphs lifted 5pt to meet the track)
[NPVLyrics] title row moved to the top left for the closed state — …,612,308,46 to …,98,308,46
[NPVLyrics] share button moved into the control band — 44×44 from …,789,44,44 to 36,604,44,44 (…
            (a transparent relay covers that spot and forwards taps)
[NPVLyrics] relaying a tap to the share button (…)          ← 点分享键时才有
[NPVLyrics] expanded — thumbnail 72pt at …, lyrics area …, cover shrunk in from …, title row lifted … (anchors: …)
[NPVLyrics] collapsed (reason=page disappeared)
```

★ 音量那两行的读法：`volume row 24,830,366,28` 是那一行的 frame，`slider 26,0,314,28` 是系统那条
音量条**在行内**的 frame（28 高、铺满行），`glyphLow 0,1,16,16` 是左喇叭（行内 y=1 ⇒ 中线 9）。
**判据**：喇叭的中线（9）要落在系统那条轨的中线上 —— 那条轨在行内 ≈9.2（§4.6 量的），
所以 `glyphLow` 的 y 应该是 **1**；如果日志里是 6（= 没抬），说明这一版没生效。

（中间那个 `title row moved to the top left … to …,98,…` 是**新增**的一行：关着态摆上了才打，
一次一页一行 —— 上一份日志读不出"关着态到底有没有生效"，就是缺它。）

`bandNote` 三种尾巴，看到哪种就知道是什么情况：

| 尾巴 | 意思是 |
|---|---|
| `(visual only: <类名> does not contain the landing spot, so taps stay dead)` | 正常预期（祖先边界挡住）——**功能上就是"只像"** |
| `(visual only: our own lyrics container is in front of it, so taps stay dead)` | 我们的歌词容器在前面吃掉了触摸（展开态必然如此） |
| `— WARNING: <类名> clips to bounds …` | ★ **会被裁掉** ⇒ 屏幕上可能看不到那颗分享键；把类名抄下来，下一轮只清那一层 |
| `(inside every ancestor — it should still take taps)` | 意外之喜：它其实还点得到 |

另外两条要看的：

* `no visible share button in this page yet — leaving it in the footer row` ⇒ 分享键没找到（走查起点要改）；
* `cannot find the title row — leaving it where Spotify put it` ⇒ 标题行没找到（关着态的左上角不会生效）。

### 6.3 通过判据

| # | 判据 |
|---|---|
| ① | **关着歌词**时：歌名/歌手在左上角（≈98），封面顶(145)没被压 |
| ② | 分享键出现在 (58, 626)，歌词键在 (215, 626)，绿 ✓ 仍在原位 |
| ③ | **展开**时：缩略图 + 歌名/歌手在左上角那一行（现状不变），歌词块起于 242 |
| ④ | 收起/离开后**没有残影**（标题回原位、分享键回 footer） |
| ⑤ | 底部两排**一颗都没变**（这正是这一版的取舍） |
| ⑥ | **音量条**：两个小喇叭与那条轨（和圆钮）**在同一条线**上 —— 照片里对一下 §4.6 那三行数 |
| ⑦ | ★ **点歌词键收起的那一瞬间**：歌名/歌手**不压**分享键（照片 74 那一帧不复现） |
| ⑧ | ★ **分享键点得动**（弹出分享面板；日志有 `relaying a tap to the share button`） |
| ⑨ | ★ **收藏键（＋/绿 ✓，371,626）点得动**（能收藏/取消） |
| ⑩ | ★ **动画**：展开/收起时歌名/歌手是**滑**过去；那颗键**永远是歌词气泡**（没有向下箭头） |
| ⑪ | S1：无时间轴的歌说明文案是**「这首歌的歌词没有时间轴」** |
| ⑫ | 上一轮那张单子：`(anchors: navBottom=… progressTop=… bottomStackTop=…)` 三个都是数字、进出转场不闪、胶囊 `hide #N` |

### 6.4 ⚠️ 已知风险（照片上专门看这几条）

| # | 风险 | 判据 / 对策 |
|---|---|---|
| ① | **关着态标题行 98…144，而封面顶 145** —— 只差 1pt。标题行实际高度若比 46 大（不同字号/多语言），就会**压到封面** | 照片一看就知道；真压了就把 `closedTitleTopInset` 从 2 调到 0（或让行贴 96） |
| ② | **展开态：控件条那三颗落在歌词块的下缘**（歌词块 242…658，三颗在 604…648）⇒ 长歌词的**最后 1–2 行**会被压住 | 现在的歌（照片 71）那一段本来就是空的。真压住了就把歌词块底边抬到 ≈586（`stageBottom` 那条锚点）——**一次只改一片** |
| ③ | **分享键被祖先裁掉**（§6.2 的 WARNING） | 抄类名，下一轮只清那一层；不清的原因写在 `bandNote` 注释里 |
| ④ | **同一行有两个"写 transform"的人**（展开时 `applyTitleTransform`、关着时 `applyClosedTitleTransform`） | 都是**每拍重算 + 覆盖**，且 `untransformed()` 会先减掉 tx/ty ⇒ 不会叠加。若照片上出现"标题在两处之间跳"，就是这一条 |
| ⑤ | 长标题在**展开态**会从绿 ✓ 底下滚过去 | 上一轮就记着：`applyTitleMask` 的坐标口径没算标题自己的 page-x，**不敢贸然接**（下一轮候选） |

---

## 7. 还没做的（按优先级）

| 序 | 做什么 | 前置 / 备注 |
|---|---|---|
| 1 | 按日志 56 收口 §6 那张单子（含上一轮的转场 / 锚点 / 文案 / 胶囊计数） | 日志 56 |
| 2 | **控件条那三颗要不要"真能点"**（分享键现在只是像） | 用户当下选的是"只搬"；要真能点得加转发 |
| 3 | 「歌词块底边让位给控件条」（§6.4 ②） | 只看照片：压住了才改 |
| 4 | 标题与 ✓ 的让位（`applyTitleMask` 坐标口径） | §6.4 ⑤ |
| 5 | 非当前歌词行**太暗**（照片 70 几乎看不清）——抬一点不透明度 | 一个常量 |
| 6 | 可选：`⋯`（`Context menu`）搬进 header；藏歌单名 `1`；藏 shuffle+repeat | 用户没点，先问 |
| 7 | S1 的升级档：无时间轴歌词**静态列出全文** | 要动渲染层 |
| 8 | 译文 / 罗马字 | 用户说「之后再说」 |
| 9 | 老账：音频密钥探针 / `NowPlayingPageOverlay` 重试 / 封面自持 / customize 种子 9.1.76→9.1.88 / 六条自检接进 CI | —— |

---

## 8. 未验证声明（**不要去掉这一段**）

* **本轮 2 个源码文件 + 2 个 l10n 文件全部没有编译过、没有装机过。**
* **最后一版真机数据仍是日志 55 + 照片 70/71/72/73**；`C:\dsh\ipa` 里**没有** `b9e250b` 之后的日志。
* ★ **"分享键搬过去之后点不到"是据 UIKit hit-test 规则 + footer 行的估算高度推的**
  （`UIView@0,231,406,44` 那条老证据 ⇒ ≈792…836），**没有在真机上试过**；
  万一它其实点得到（父视图很大 / 有人重写过 `point(inside:)`），`bandNote` 会写
  `(inside every ancestor — it should still take taps)`。
* ★ **"关着态标题行 98…144 不压封面"用的是照片 72 量出来的封面顶边 145**；行高 46 是从真机树
  （`MarqueeLabel 24` + `22`）推的，**没有在真机上量过"行"的整体高度**（背景透明，树里也没有那个 frame）。
* ★ **音量条那 5pt 是"照片逐像素量出来的偏差"**（§4.6），**不是**"改完之后量过"——
  抬 5pt 之后两者应该在 839 那一条线上；下一张照片请对着 §4.6 那三行数复核
  （日志里 `glyphLow … ,1,16,16` 是"我们摆的"，照片才是"系统画在哪"）。
* ★ **上半场那版"绿 ✓ 搬进 header"（`f2dc707`）已经作废并撤掉**：代码里**没有**留开关或死代码；
  要回那一版就照 §2 里同一套手法（`transform` + 收尾还原）重写一遍即可，那份说明在
  `git show f2dc707` 里。
* 本轮**没有派独立只读复核**（改动集中在两处新增 + 两个常量）；若照片 74 显示位置不对 / 有残影，
  **下一轮第一件事就是派复核**。
* ★ **第三批（照片 74 + 日志 56 之后的四处修复）同样没编译、没装机**，而且其中两处是**新的机制**：
  * **替身热区**（`eevee-npv-share-relay` + `sendActions`）：**"转发能不能真的弹出分享面板"没有验证过** ——
    本仓库上一次对胶囊用过同一招（那次是能按动的），但那是 `Primary` 按钮、这次是 `EncoreButton`。
    日志会先打 `relaying a tap to the share button (…)` ⇒ 至少能分清"我们的转发发生了但对方没响应"
    还是"热区没收到触摸"。
  * **容器放行**（`NowPlayingLyricsContainerView.point(inside:)`）：**"收藏键因此变得能点"没有验证过** ——
    我们只证明了"以前是它吃掉触摸"，没证明"让开之后那颗键自己接得住"（它自己的祖先链也可能挡）。
    若照片显示 ✓ 仍点不动，下一轮就把 `bandNote` 那套判据也套到它身上（先量出是谁挡的）。
  * **动画**：`0.45s + 临界阻尼`、且"只在目标变了时才动"；**没有在真机上量过时长/会不会抖**。
  * **恒定的歌词图标**：`applyToggleAppearance` 里那句 `isOpen ? … : …` 已删，只剩 `quote.bubble.fill`。
* ★ **照片 74 是"过渡帧"**（用户明确说过：实际页面不长那样）⇒ 它证明的是**收尾顺序有问题**，
  **不能**当成"关着态的稳态长什么样"来读。
