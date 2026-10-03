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
| **这一轮改了九件事** | ★ **控件条**：[分享 58→**和 shuffle 同线**] [歌词键 215→**和播放键同线**] [绿 ✓ 371（不动）] ★ **关着歌词时标题/歌手贴左上角** ★ **音量条小喇叭抬 5pt** ★ 四处修复（照片 74 + 日志 56）：**收尾顺序**（不再"短暂重合"）、**分享键替身热区**（能点了）、**歌词容器放行触摸**（收藏键能点了）、**标题加动画 + 图标恒定为歌词气泡** ★ 照片 75：**两条竖线对齐** + **没有时间轴时静态列出全文** |
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

## 4.7 ★ 第四批：照片 75（两条竖线 + 静态歌词）

用户原话：

> 两个问题：分享按键并不和下面的选择随机播放按键同一条直线，歌词按键不和下面的暂停键同一条直线。
> 而且，如果选择加载了没有时间轴的歌词，歌词页只会显示「这首歌的歌词没有时间轴」这句话，**歌词呢**

### 4.7.1 两条竖线（照片 75 逐列量）

| 控件条（照片 75，y≈880…915px） | 中心 | 下面那一排（y≈1050…1100px） | 中心 | 差 |
|---|---|---|---|---|
| 分享键 | **57.4pt** | shuffle | **39.9pt** | 17.5 |
| 歌词键 | **214pt** | 播放/暂停 | **208pt** | 6 |
| ＋（收藏） | 371.6pt | repeat | 373.7pt | 2 ✅（用户没提，几乎就是齐的） |

⇒ 改法**不是**把常量改成 40 / 208 就完事，而是**运行时量下面那一颗的 `midX`**：
新增 `transportColumnX(_:in:)`（按 id 找 `Components.UI.ShuffleButton` / `SPTNowPlayingPlayButton`），
分享键和歌词键都用它对齐；量不到（那一颗被藏了 / 页面还没铺完）才退回常量 40 / 208。
—— 这样换机型 / 换版式也不会错位（"和下面那颗对齐"本来就是**相对**判据）。

### 4.7.2 没有时间轴 ⇒ **复用同一个渲染层**（静态档）

> ⚠️ **第一版做错了，已推翻**：我当初为了省事写了一个 `NowPlayingStaticLyricsView`
> （`UIScrollView` + 一个 label，`.center` 居中）。用户在照片 75 之后指出两件事：
> 「**滚动、展示大小什么的不是复用有时间轴的逻辑吗**」（对 —— 时间轴那一档是
> `alignment: .leading` 左对齐、走 `.player` 档字号/行距/内边距），以及
> 「**最下面的歌词还会被自己画的功能挡住**」（对 —— 时间轴那一档的 `contentInsets.bottom = 120`
> 正好让最后一行躲开控件条，我自己那版把 label 贴到容器底边，于是被 604…648 的控件条压住）。
> 那个自绘视图**已整块删掉**。

现在的做法：**同一套渲染层**，只多一个 `isStatic` 开关。

* `AppleMusicLyricsPlate.staticLines(from:)` 把文本包成**合成行**（`time: 0`、无音节、
  `timingKind: .lineSynchronized`）—— 时间只是占位；
* `AppleMusicLyricsOverlayView.isStatic` → `AppleMusicLyricsPage.isStatic`（都带默认值 `false`，
  所以全屏页那一档调用点不用改）；
* `AppleMusicLyricsPage` 里**只改三件事**：
  1. 每一行按"焦点行"画（`focusStrength = 1`）—— 不高亮某一行、也不把别的行压暗/糊掉；
  2. 两个自动跟随入口（`onAppear` / `onChange(of: highlightedLyricID)`）直接 `return`；
  3. **点行不跳转**（合成行时间是 0，点了会把歌拉回开头）；
* 宿主 `NowPlayingLyricsHost` 多带一个 `isStatic`（`mount` / `updateLines` / `isCurrent` 三处），
  换档会重挂；
* 判据同步：`layoutAndMount` 里 `isStatic = timedLines.isEmpty && staticTexts != nil`，
  然后**走原来那条挂载路**（`host.mount(lines:)`）—— 于是字号 / 行距 / 左右内边距 /
  滚动容器 / **底部 120pt 留白**全部自动一致。

日志里那一行会带 `static lyrics N line(s) (this track has no timeline; same renderer, static mode)`。

---

## 4.8 ★ CI 红了一次：`UIView` 上没有 `sendActions`（并加了自检规则 ④）

CI 报（用户转来的原文）：

```
Sources/EeveeSpotify/Appearance/NowPlayingLyricsPlate.swift:2210:
  value of type 'UIView' has no member 'sendActions'
  cannot infer contextual base in reference to member 'touchUpInside'   ← 上一条的连锁
```

**根因**：`bandShareButton` 的声明类型是 `UIView?`（我们本来只当它是"页里那个视图"），
所以 `guard let button = bandShareButton` 拿到的是 **`UIView`** —— 而 `sendActions(for:)` 是
`UIControl` 的方法。

**修法**（`relayShareTap`）：`guard let control = view as? UIControl else { 打一行日志; return }`。
日志留的是 `the share button (<类名>) is not a UIControl — cannot forward the tap` ——
下一轮就能分开"我们的转发发生了、但对方不是 UIControl"和"热区根本没收到触摸"这两种。

★ **顺手加了自检规则 ④**（`Tools/eevee-hookfinder/swift_member_check.py`）：把"声明成 `UIView` 的名字"
顺着 `guard let a = b` 这种**纯标识符赋值**传播两三跳，再看它们头上有没有
`sendActions` / `addTarget` / `removeTarget`。**两向验证过**：

* 干净仓库 0 命中（272 个文件，exit 0）；
* 同形状的假货（`.tmp-rule4/Probe.swift`，就是这次的写法）**报在该行、exit 1**；
* 修好之后的 `as? UIControl` 写法 **不被报**（RHS 不是裸标识符 ⇒ 不进集合）。

⚠️ 顺带把新写的那处 `UIView.animate(... usingSpringWithDamping: …)` 补上 `completion: nil` ——
UIKit 的 Swift 签名虽然给了默认值，但这个仓库的编译器版本只保证"最多一个警告"，不冒这个险。



```
python Tools/eevee-hookfinder/orion_hook_guard.py      # OK 327 文件
python Tools/eevee-hookfinder/swift_brace_check.py     # OK 327 文件
python Tools/eevee-hookfinder/swift_member_check.py    # OK 272 文件（含本场新增的规则 ④）
python Tools/eevee-hookfinder/swift_string_check.py    # OK 276 文件 / 48499 行
python Tools/l10n_lint.py --locale en                  # exit 0
python Tools/l10n_lint.py --locale zh-CN               # 427 keys, 0 missing, 0 extra
```

* **规则 ④（本场新增）**：`UIControl` 专有方法被调在 `UIView` 类型的变量上 ⇒ 必然编译错
  （就是 §4.8 那次 CI 红）。两向验证过；**只认"声明成 `UIView` + 纯标识符赋值传播"**，
  同名遮蔽 / 参数传入的一律跳过 —— 宁可漏，也不误报（与规则 ③ 同一条纪律）。

⚠️ 六条都**不做类型检查**（`CGAffineTransform(a:b:c:d:tx:ty:)` 的逐参数、`@discardableResult` 的调用点、
`flatMap` 那两处 Optional 链、`NSMutableParagraphStyle` 那几行只能靠 CI）。

---

## 4.9 ★ 点行跳转："同一个算法抄了四份"（用户：我选中某一行，定位到上一行去了）

用户原话：**「点击区似乎有些问题。我选中某一行歌词，定位到上一行歌词去了」**。

**这不是点击区的问题，是 seek 落点的问题**，而且仓库里**记过这个坑**：

* 高亮判据是 `time <= playbackTime` ⇒ seek 落在**行边界**上就会被判成**上一行**；
* `line.time` 是 `TimeInterval(offsetMs) / 1000`，双精度存不下 26.622 ⇒ 落在略小的一侧
  （26.621999999999999…）⇒ 直接 `Int()` 截断会**再少 1ms**；
* 全屏页那条路 **2026-09-28** 就踩过并修了 —— 但它是在 `makeRootView` 的**闭包里**就地修的
  （`rounded() + 5ms`），**没有提成公共函数**；
* "歌词进播放器"那一档（`NowPlayingLyricsPlate`）当时**另抄了一份**、只 `rounded()` 没有 `+5`
  ⇒ 用户这次报的正是它；旧 UIKit overlay 的 `handleLineTap` 更是**连 `rounded()` 都没有**
  （直接把 `offsetMs` 丢进去）。

**修法：只留一份** —— `AppleMusicLyricsOverlay.swift` 文件开头新增

```swift
func seekToTappedLyricLine(_ time: TimeInterval) {
    WordByWordSeeker.seek(toMs: Int((time * 1000).rounded()) + 5)
}
```

四个调用点全部改走它（全屏页 / 歌词进播放器 / 旧 overlay 的全屏页 / 旧 overlay 的点行）；
函数上方那段注释把"为什么 `rounded()`、为什么 +5ms、这个 bug 犯过两次"一次写清。
**仍留在外面的只有** `AppleMusicLyricsPlaybackControl` 里那句 `seek(toMs: 0)`
（"上一首 → 重播本曲"，语义不同，不该套这个 +5ms）。

> ★ 教训（和 §4.8 是同一类，值得同时记住）：
> **"就地修好的算法"必须提成一份** —— 修在闭包里、只改一个调用点，
> 等于给下一条路留了同一个坑（这次就是隔了三周又踩一遍）。

---

## 4.10 ★ 歌词提供商写进歌手那一行；`(EeveeSpotify)` 水印去掉

用户原话：

> 我还有个想法：就是在歌手的右边，写上歌词提供商。即 **歌手名字（歌词提供商）** 这种。
> 而这两行是等高的。这个就不需要写 eveespotify 的水印了

**水印是从哪来的**（代码实证）：`CustomLyrics.storeLyricsDto` 写
`providerName = "\(source.description) (EeveeSpotify)"`，同一条字符串也进注入 payload 的
`providedBy` —— 而 **Spotify 原生歌词页 / 卡片底部那一行是直接照 `providedBy` 显示的**
（`CustomLyrics.x.swift` 开头那段注释就记着这事）⇒ 屏幕上就是那个水印；
"所有源都失败"那条占位路更是回落到**裸的 `"EeveeSpotify"`**。

**这一轮的改动**：

| 改哪 | 怎么改 |
|---|---|
| `LyricsDto.toSpotifyLyricsData` 的 `providedBy` | `"\(source) (EeveeSpotify)"` → **`"\(source)"`**（只留源名） |
| `CustomLyrics.storeLyricsDto` 的 `providerName` | 同上（这串是 `currentLyricsProvider` 的来源） |
| 占位路的 `providedBy` | 回落到**裸的 `"EeveeSpotify"`** → 改成"没问过就留空" |
| `NowPlayingLyricsPlate` | ★ 新增 `applyProviderToArtistLine` / `restoreArtistLine` / `artistLabel` / `providerSuffix` / `setLabelText`：把 `歌手（提供商）` 写到 **Spotify 自己的** `now-playing-subtitle-label` 上 |

**写法上的三个要点**（照本仓库既有手法）：

* 这一行是 **Spotify 的标签**，binder 会写回 ⇒ 走**复查节拍**（0.3s 那一拍里比一次、不等才写一次），
  并且"第一次贴上"和"第一次被写回"各留一行日志（同 `LibraryAppearance` 那套；不然就是"改了没生效"）；
* 改文本时**保住它自己的属性字符串**（有 `attributedText` 就在它上面改，否则退回 `text`）——
  直接写 `text` 会把 Spotify 设的字体/颜色整段丢掉；
* **只在展开歌词时贴**；收起 / 离开页面 / 关开关由 `settleAfterClosing` 调 `restoreArtistLine`
  精确摘掉（记住贴上去的那一段，不靠猜括号）。

**"这两行是等高的"怎么落的**：标题与歌手各是 Spotify 自己的字号（真机树 24 / 22pt），
我们**只往歌手那行追加文本**、不换行不改字体 ⇒ 两行高度与原来一致。
（若用户的意思其实是"把两行字号调成一样"，那是另一件事 —— 要在 `label.font` 上做、
照 `LibraryAppearance` 那条路，**先问**。）

---

## 4.11 ★ 译文与罗马字接上（用户：把罗马字和歌词翻译接上去）

用户原话：

> 把罗马字和歌词翻译接上去吧，要求：翻译/罗马化**尊重歌词页面的选择**，
> 翻译在歌词下方，**罗马字在歌词上方**（这字的高度和大小你自己想吧）

**三件事、四份数据源都查过之后的落法**：

| 档 | 数据从哪来 | 开关（"歌词页面的选择"） | 画在哪 |
|---|---|---|---|
| **译文** | `LyricLine.translation` ← `LyricsDto.translation.lines`（适配器早就在映射） | `!NgzhwmSettingsViewModel.isNeteaseHideTranslationEnabled`（默认随设备语言；旧 overlay 同一条判据） | 主歌词**下方**（`SynchronizedLyricText` 里本来就有那一行，只是以前 `showsTranslation=false`） |
| **罗马字** | ★ **复用仓库既有管线** `LyricsDto.romanizedForWordByWordIfEnabled()` —— 整首语言判定 + 三个逐语言开关 + 首字母大写；**只读它的 `content`**，主歌词仍用原文 | `ngzhwm_{japanese,chinese,korean}Romanization`（就是设置页那三个） | 主歌词**上方**（新增 `romanizationText`，放在 `VStack` 最顶） |

**几个关键决定**：

* **罗马字与原文相同就不显示**（`LyricLinesAdapter.romanization(original:romanized:)`）——
  一首日文歌里的英文行罗马化后就是它自己，再显示一遍纯噪声、还白占一行；
* **排版数值**（用户把大小交给我）：字号 = `supplementalFontSize × 0.85`
  （`.player` 档 17pt ⇒ ≈14.5pt，比译文再小一档）；与主歌词的间距用 **Apple Music 自己的
  `transliterationSpacing = 5`**（`AppleMusicLyricsSupplementalTextProfile`，那个常量本来就写着"音译"）；
  颜色/焦点跟随与译文同一条公式、整体再淡一档；
* **开关即时生效**：罗马化那三个开关只写 `UserDefaults`、**不会让 `currentLyricsVersion` 变**
  ⇒ 把开关**指纹**放进 `NowPlayingLyricsHost.isCurrent`，一改下一拍（≤0.3s）就重写行模型，
  不用等换歌；
* ★ **同一个判据只留一份**：指纹函数 `romanizationSwitchesFingerprint()` 定义在
  `LyricLinesAdapter.swift` 开头，播放器那一层直接调它（§4.9 刚因为"抄两份"踩过坑，这里不再犯）；
* **性能**：`toAppleMusicLyricLines()` 在**每 0.3s 那条节拍**上被调（`currentLines()`），
  而罗马化不便宜（日文还要分词）⇒ 新增 `romanizedContentsForDisplay()`，按
  「歌词版本 + 三个开关 + 行数 + 首行内容」缓存；
* **没有时间轴那一档也带上**：`currentUntimedLines()` 改成返回 `(原数组下标, 文本)`，
  译文/罗马字都按同一个下标配对（空行被滤掉之后下标会错位，这正是它不返回 `[String]` 的原因）；
* **日志判据**：`expanded — … translation N/M romanization N/M`（各自命中多少行）——
  下一次不用靠猜"是不是没接上"。

---

## 4.12 ★ 这几句提示在非简体中文设备上是中文还是英文（用户问的）

**机制**（`BundleHelper.localizedString(_:)`，`Premium/Helpers/BundleHelper.swift:52`）：

```
① 设备语言那个 .lproj 里查（用哨兵值 "No translation" 判断"没查到"）
② 查不到 ⇒ **回落 en.lproj**
③ en 也没有 ⇒ 返回**键名本身**
```

所以**永远不会串成中文**（除非那个语言的表里正好写着中文）——
非简体中文设备上看到的是"该语言的翻译"，没有翻译就是**英文**。

**用户问的那两句的实测**（2026-10-11 逐文件查）：

| 键 | zh-CN | 其它 26 个语言 |
|---|---|---|
| `ngzhwm_lyrics_unavailable`（未找到歌词） | 「未找到歌词」 | ★ **全是英文 `"No lyrics found"`** —— 连 **zh-TW 都是英文**（繁体用户看到英文） |
| `song_is_instrumental`（此歌曲为纯音乐。） | 「此歌曲为纯音乐。」 | **多数有真翻译**：ja「この曲は歌詞がありません」/ ko / de / ru / zh-TW「此歌曲為純音樂。」…（缺的那些回落英文） |

**顺带补掉的缺口**（这一轮做的）：

* `lyrics_looking_up`（上一轮加的）与 `lyrics_no_timeline`（本轮加的）**原先只有 en + zh-CN**
  ⇒ 非中文设备一律英文。现在**补进全部 27 个语言**（zh-TW 给了真翻译：
  「正在尋找歌詞…」/「這首歌的歌詞沒有時間軸」，其余语言先放英文 —— 与原来的回落结果一致、
  但文件变完整）；
* **zh-TW 的 `ngzhwm_lyrics_unavailable`** 从英文改成「未找到歌詞」；
* 校验：四个键现在 **27/27**；仓库实际 gate 的两个语言仍 `en exit 0` / `zh-CN 427 keys, 0 missing, 0 extra`。

⚠️ **其余语言本来就不完整**（实测：de / ko / ru… 各 **148 个键缺失**，ja 141 个）——
那是仓库既有状态、不在本轮范围；缺的一律优雅回落英文。
若要做全语言补齐，那是另一件事（要么人工译，要么机器译 + 你过一遍）。

---

## 4.13 ★ 默认值：把用户点名的那些开关改成默认开

用户原话：

> 这样：听歌页的那几个功能全部默认开启，音乐库的那个默认开启，标签栏功能默认开启，
> 迷你播放条选项默认开启，隐藏封面下一行歌词和隐藏胶囊默认开启

**先做了一次全量审计**（`UserDefaults+Extension.swift` + `ngzhwmSettingsViewModel.swift` 里每一个
`static var X: Bool`），再按设置页的分区标题逐条对：

| 用户说的 | 设置分区（中文标题） | 开关（键） | 改之前 | 结果 |
|---|---|---|---|---|
| **听歌页那几个** | 「听歌页」 | 整页封面取色底 `nowPlayingBackdrop` | ON | 本来就是开 |
| | | 一屏 `nowPlayingOneScreen` | ON | 本来就是开 |
| | | **底部音量条** `nowPlayingVolume` | **OFF** | ★ **改成 ON** |
| | | **歌词进播放器** `nowPlayingLyricsInPlayer` | **OFF** | ★ **改成 ON** |
| | | **控制键换成本地字形** `nowPlayingControlGlyphs` | **OFF** | ★ **改成 ON** |
| 音乐库那个 | 「音乐库」 | Apple Music 式头部 `libraryLargeTitle` | ON | 本来就是开 |
| 标签栏 | 「标签栏」 | 标签用液态玻璃 `tabBarGlass` / 隐藏标签文字 `tabBarHideLabels` | ON / ON | 本来就是开 |
| 迷你播放条 | 「迷你播放条」 | 迷你播放条用液态玻璃 `miniBarGlass` | ON | 本来就是开 |
| 隐藏封面下一行歌词 | （隐藏类那一节） | `hideSingalongLine` | ON | 本来就是开 |
| 隐藏胶囊 | 同上 | `hideNowPlayingPills` | ON | 本来就是开 |

⇒ **实际只翻了 3 个**（`nowPlayingVolume` / `nowPlayingLyricsInPlayer` / `nowPlayingControlGlyphs`），
三处的注释都从"为什么当初默认关"改写成"为什么现在默认开"（并把用户原话记进去）✓。

### 4.13.1 两个要留意的点

* **改默认值只影响"还没写过这个键"的用户** —— 已经写过的值照旧。
  用户自己的设备上：日志 56 那行 `installed (miniPlayer=OFF singalongLine=ON npvPills=ON …)`
  说明 **miniPlayer 是已存值**；`nowPlayingVolume` / `nowPlayingLyricsInPlayer` 他已经开过 ⇒
  这一改对**他的设备**几乎没有可见变化（`nowPlayingControlGlyphs` 若从没点过则会生效）。
* ★ **"歌词进播放器"默认开之后，它的前置门禁却是关的**：
  `NowPlayingLyricsPlate.canShow()` 第一道就是
  `NgzhwmSettingsViewModel.isBetterWordByWordLyricsEnabled`（「更好的逐词歌词」），
  而它 `defaultValue: false`（`ngzhwmSettingsViewModel.swift:110`）⇒ **全新安装上
  "歌词进播放器"会是"键看得见、点了没反应"**。
  ⇒ **已按用户回复（「2 也默认打开吧」）改成 `defaultValue: true`**，
  连带 `isLyricsBlurredBackdropEnabled`（模糊封面底）与 `isLyricsBackdropMaterialEnabled`
  （系统材质压色带）两个派生值一起开。注释里记了：想回旧实现的人仍然可以关掉它。

---

## 4.14 ★ 最低 / 推荐 iOS 版本（用户问的，证据在这）

| | 值 | 证据 |
|---|---|---|
| **最低** | **iOS 14.0** | `control`：`Depends: ${ORION}, firmware (>= 14.0)`；`Makefile:1`：`TARGET := iphone:clang:latest:14.0`（deployment target = 14） |
| **推荐** | **iOS 26 或更高**（作者自己的目标机是 **iOS 27**） | `#available(iOS 26.0, *)` 在仓库里 **47 处**；听歌页那一整套（`NowPlayingLyricsPlate` / Apple Music 渲染层 / 玻璃）都挂在这条线上；已有记录里目标机是 iOS 27（`LYRICS_MODULE_FINDINGS.md:3`） |

**推论（装机/答疑时别答错）**：

* **iOS 14~25 能装、能跑**，但**听歌页那一套（音量条 / 一屏 / 歌词进播放器 / 控制键本地字形 /
  Apple Music 渲染层）与液态玻璃都用不了** —— `canShow` / `apply` 那几处 `guard #available(iOS 26.0, *)`
  会直接返回，走的是旧实现那条路；
* 这也是仓库的一条**明文纪律**（`SESSION_2026-10-02_APPEARANCE.md` §6.3）：
  **不要为了玻璃提高最低版本**（提高版本 = 砍掉 iOS 14~25 的全部用户，换不到新能力；
  iOS 26 的玻璃 API 靠**运行期反射**拿）；
* ⚠️ 因为底线是 14，写代码时**不能用 iOS 15+ 的 API**（`UIButton.Configuration`、
  SwiftUI `foregroundStyle` 这类都会编译错 —— 记录在 `SESSION_2026-10-01.md:295`）；
* 另一条轴是 **Spotify 版本**（`EeveeSpotify.hookTarget`，`Tweak.x.swift:296`）：
  `8.9.8 → .lastAvailableiOS14`、`9.0.48 → .lastAvailableiOS15`、`9.1.x → .v91`、其余 `→ .latest`。
  也就是"iOS 14 这条线"实际绑的是**最后一个支持 iOS 14 的 Spotify 版本**。

---

## 4.15 ★ 本地化审计（用户：「我怎么感觉有很多已废弃和重复的本地化文件。你看看」）

### 4.15.1 审计方法（两个坑，下次直接用正确的解析器）

* **没有重复的文件**：全仓库只有 `layout/…/EeveeSpotify.bundle/` 下 **27 个 `.lproj/Localizable.strings`**，
  一个语言一份，没有第二份副本。
* ⚠️ **坑 1：键可以不带引号**。26 个语言用的是老式 plist 写法
  （`patching = "Patching";`，只有 `en` / `zh-CN` / `it` 三种混用带引号的写法）。
  只按 `"key" =` 解析会得到"0 个键"。
* ⚠️ **坑 2：`//` 行注释必须先剥掉**，否则整段注释会被当成键名（第一版审计就这样造出了
  一堆"extra 键"假阳性）。块注释 `/* */` 也要剥。
* **死键判定**要看**代码/配置**文件（`.swift/.plist/.json/...`），**不能**把 `Tools/**/*.md`
  算进来 —— 会话笔记里到处都在引用键名，会把所有死键都判成"仍被引用"。
* ⚠️ **动态拼接的键不是死键**：`reduce_interventions_flag_<shortName>`（`_description` 同）
  与 `reduce_interventions_scope_<末段>`（`_footer` 同）共 **34 个**是
  `EeveeReduceInterventionsView.swift:290/294/331/335` 拼出来的。

### 4.15.2 结论：真正的问题不是"文件"，而是三种**键**的问题

| 问题 | 实测 | 处理 |
|---|---|---|
| ★ **`zh-CN` 你自己的更新被旧条目盖住了** | `flag_catalog_description` 有两条：337 行是你新写的（"…点一行即可填入上面的表单…"），393 行是旧文案（"…把这条钉住…"，说的是**已经删掉的钉住交互**）。`.strings` 里**后写的生效** ⇒ 你的新版**没起作用** | ✅ **删掉 393 那条**（代码里这个键只在 `EeveeFlagCatalogView.swift:20` 用一次） |
| ★ **`it` 的 96 条意译全被英文盖住** | 该文件 = "上游英文表（裸键）+ 一份意译贴在前面（带引号）"，于是这 96 个键**意译在前、英文在后** ⇒ 意大利用户看到的是英文 | ✅ **删掉这 96 条英文重复行**（保留意译） |
| **15 个死键**（全语言共 236 行） | `now_playing_shell*`（7，自绘壳那一整节 2026-10-02 已删）、`music_style*`（3）、`show_instagram_destination*`（2）、`amoled_description`（1）、`Developement` / `Localization`（2，疑似误加的垃圾键）——**代码/配置里 0 处引用** | ✅ 全语言删除 → en 427 → **412** |

**校验**：`l10n_lint` `en exit 0`、`zh-CN 412 keys, 0 missing, 0 extra`（`zh-TW/ja/it` 也 exit 0）；
六条自检全绿；`it` 的 `resetButtonTitle` / `showToast` 已确认只剩意译。

### 4.15.3 顺带查清、**还没动**的两件事

1. ★ **`resetSubtitle` 一个键用在两个地方**（代码级，跨所有语言）：
   * `SponsorBlockAdvancedView.swift:77` —— SponsorBlock「重置」ActionSheet 的 **message**
     （en：`"Each is independent."`，"各项互不影响。" ⇒ 合理）；
   * `EeveeSettingsView.swift:326` —— **完全重置**的确认框 message（同一个键）⇒
     **每种语言的"完全重置"确认框都在说"各项互不影响。"** ✗（zh-TW 恰好写反了：
     它的 `resetSubtitle` 是擦除说明 ⇒ SponsorBlock 那边反而不对）。
   * 建议修法（**待用户拍板**）：确认框改用 `resetFooter`（en 里就是那段擦除说明，
     各语言也都翻了），或另起一个键。**没有擅自改 UI 文案。**
2. **25 个语言的覆盖率**：改完后 en = 412 键，而 22 个语言只有 **275**（= **137 个键缺失**）、
   `ja`/`zh-TW` 277、`it` 278 ⇒ 这些语言里**三分之一的界面是英文**（优雅回落，不是 bug，是没翻）。
   `now_playing_one_screen` / `now_playing_backdrop_section` / `now_playing_control_glyphs`
   这类新键更是只有 **2/27** 个语言有。**要补就是全语言机器翻译 + 人工抽查**，是另一件事。

---

## 5. 本机自检（六条全绿）

```
python Tools/eevee-hookfinder/orion_hook_guard.py      # OK 327 文件
python Tools/eevee-hookfinder/swift_brace_check.py     # OK 327 文件
python Tools/eevee-hookfinder/swift_member_check.py    # OK 272 文件（含本场新增的规则 ④）
python Tools/eevee-hookfinder/swift_string_check.py    # OK 276 文件 / 48824 行
python Tools/l10n_lint.py --locale en                  # exit 0
python Tools/l10n_lint.py --locale zh-CN               # 427 keys, 0 missing, 0 extra
```

* **规则 ④（本场新增，见 §4.8）**：`UIControl` 专有方法被调在 `UIView` 类型的变量上 ⇒ 必然编译错
  （那次 CI 红就是它）。两向验证过；**只认"声明成 `UIView` + 纯标识符赋值传播"**，
  同名遮蔽 / 参数传入的一律跳过 —— 宁可漏，也不误报（与规则 ③ 同一条纪律）。

⚠️ 六条都**不做类型检查**（`CGAffineTransform(a:b:c:d:tx:ty:)` 的逐参数、`@discardableResult` 的调用点、
`flatMap` 那两处 Optional 链、`NSMutableParagraphStyle` 那几行、SwiftUI 的 `some View` 链只能靠 CI）。

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
5. **点一下分享键**（现在在**和 shuffle 同一条竖线**上，≈40pt）：应该弹出 Spotify 的分享面板
   （日志里会出现 `relaying a tap to the share button (…)`）；**再点一下绿 ✓/＋**（371,626）：应该能收藏/取消收藏；
6. **放一首"没有时间轴"的歌**（就是照片 75 那一首《Psycho》）：歌词页应该**列出全文**（会滚），
   而不是只有一句说明；日志里有 `static lyrics N line(s) (this track has no timeline)`；
7. **音量条**：两个小喇叭要和**那条轨（和圆钮）在同一条线**上（照片 71 里它们低了 5pt，见 §4.6）；
8. **展开/收起各看一次**：歌名/歌手是**滑**过去、不是跳过去；那颗键**始终是歌词气泡**（没有向下箭头）；
9. 顺便把上一轮那张单子一起拍了（进出转场不闪、胶囊不在）。

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
| ⑪ | ★ **两条竖线**（照片 75）：分享键与下面那颗 **shuffle** 同一条竖线、歌词键与 **播放/暂停**同一条竖线 |
| ⑫ | ★ **静态歌词（复用渲染层）**：放一首"没有时间轴"的歌 ⇒ 歌词页**列出全文**：
| | · **左对齐**（和时间轴那一档同一套 `LazyVStack(alignment: .leading)`）； |
| | · 字号/行距/左右内边距与有时间轴时**完全一致**（同一页、同一档 `.player`）； |
| | · **能滚**、**不自动跟随**、点行**不跳转**； |
| | · **最下面一行不被控件条挡住**（那一页本来就留了 120pt 底部内边距）； |
| | · 日志里有 `static lyrics N line(s) (this track has no timeline; same renderer, static mode)`。 |
| ⑬ | ★ **点行跳转落在被点的那一行**（不是上一行）—— 见 §4.9 |
| ⑭ | S1：**连文本都提不出来**那一档才写「这首歌的歌词没有时间轴」 |
| ⑭ | ★ **提供商在歌手右边**：展开歌词时那一行读作 `歌手（NetEase）`；收起后**还原**成纯歌手名（见 §4.10） |
| ⑮ | ★ **没有 `(EeveeSpotify)` 字样**了：Spotify 原生歌词卡/全屏页底部那行只写源名（`歌词提供者：NetEase`），不再出现品牌 |
| ⑯ | ★ **罗马字在主歌词上方、译文在下方**（见 §4.11）：放一首日文歌、在设置里开「日语罗马化」⇒ 罗马字**下一拍就出现**（不用换歌）；日志里 `romanization N/M` 的 N ≠ 0 |
| ⑰ | ★ **译文**：中文设备默认就该有（`隐藏译文` 默认关）；日志里 `translation N/M` 的 N ≠ 0 |
| ⑱ | 上一轮那张单子：`(anchors: navBottom=… progressTop=… bottomStackTop=…)` 三个都是数字、进出转场不闪、胶囊 `hide #N` |

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
* ★ **第四批（照片 75：两条竖线 + 静态歌词）同样没编译、没装机**：
  * **两条竖线**：兜底常量 40 / 208 是照片 75 量出来的；真正生效的是 `transportColumnX()` 量的
    `midX`。**"量得到 / 量不到会退回常量"两条路都没在真机上验过** —— 下一份日志里
    `share button moved … to <x>,604,…` 的 x 应该 ≈40（±2），不是 58；`lyrics button in place <x>,604,…` 的 x 应该 ≈208。
  * **静态档（复用渲染层）**：三个开关点（`focusStrength = 1` 全亮 / 不跟随 / 点行不跳）
    都**没有在真机上走过**；尤其"所有行都按焦点行画"会不会连**焦点行的额外效果**
    （`SynchronizedLyricText` 里跟 `isFocused` 走的那部分）一起带上，只能看照片。
    我是把 `isFocused` 传 **false**、只把 `focusStrength` 拉到 1 的 —— 如果照片上行看起来
    "一半亮一半暗"，就是这一处要调。
  * `hasSomethingToShow()` / `hasAnythingToDrawFast()` 两条新门禁也没在真机走过。
* ★ **点行跳转那 5ms**（§4.9）：这是**"全屏页那条路三周前就验过"的值**，但"歌词进播放器"
  这一档第一次带上它 ⇒ **没在真机验过**。若照片上还是"点这一行、跳到上一行"，
  就只改 `seekToTappedLyricLine` 里那一个数（先试 30ms）——
  它就是"往这一行里面多走一点"的安全余量，没有别的副作用。
* ★ **歌手那一行的提供商**（§4.10）**没在真机验过**，而且有两处只能看照片：
  · **binder 会不会每拍都写回** ⇒ 若那一行在"有（NetEase）/ 没有"之间闪，就是它 ——
    对策是改成 hook 它的 layout 事件（像 `CoverFlashGuard` 那样）而不是 0.3s 复查；
  · **贴上去之后会不会触发 marquee 滚动**（行变长了）——若文字开始来回跑，就把提供商改短
    （例如只用源的缩写）或改成不上 marquee 的写法。
  · 另外 `(EeveeSpotify)` 水印是**注入 payload 的 `providedBy`** 去掉的 ⇒ 也要看一眼
    Spotify **原生**那行（歌词卡 / 全屏页底部）现在只有源名。
* ★ **译文 / 罗马字**（§4.11）**没在真机验过**，而且是这一批里"看得见"的成分最多的一档：
  · **排版数值是我定的**（罗马字 = 译文 × 0.85、间距用 Apple Music 的 5、颜色再淡一档）——
    照片上要看的就三件：**罗马字是不是在主歌词上方**、**译文是不是在下方**、
    **一块比原来高多少**（一屏会少半行到一行；若太挤就把罗马字再缩小或把块距从 26 调回 24）；
  · **日文罗马字的质量**：走的是仓库既有那条管线（`toJapaneseRomaji()` + 分词对齐），
    我们没改它的算法 —— 但"整行罗马化"和"逐词罗马化"是同一个函数的两条支路，
    如果一行长得离谱（整句连成一串），下一轮就改用它的 `words` 那条支路；
  · **开关即时生效那条路**（指纹进 `isCurrent`）**没验过**：在设置里开/关「日语罗马化」，
    下一拍应该就变；没变的话，问题在这个判据而不是渲染层。
* ★ **照片 74 是"过渡帧"**（用户明确说过：实际页面不长那样）⇒ 它证明的是**收尾顺序有问题**，
  **不能**当成"关着态的稳态长什么样"来读。
