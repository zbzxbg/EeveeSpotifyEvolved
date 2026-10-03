# SESSION_2026-10-11_SUMMARY — 这一场干了什么 · 现在什么状态 · 下一步做什么 · 规矩

> **新会话先读这一份。** 它是**整场会话**的汇总（照片 60 → 70、日志 53 → 55 这一路），
> 逐轮的流水在下面三份里，需要细节再点进去：
>
> | 想看的 | 去哪 |
> |---|---|
> | 日志 53 / 照片 60–62（自己的标题栏、胶囊、换歌闪封面） | [`SESSION_2026-10-09_HANDOFF.md`](SESSION_2026-10-09_HANDOFF.md) |
> | 日志 54 / 照片 63–64（胶囊的 id、封面的 pw 手法、页面记忆） | [`SESSION_2026-10-10_HANDOFF.md`](SESSION_2026-10-10_HANDOFF.md) |
> | 日志 55 / 照片 65–69（进出转场、几何量测、音量条、元素清单） | [`SESSION_2026-10-11_HANDOFF.md`](SESSION_2026-10-11_HANDOFF.md) |
> | 照片 67/68 逐区块量测 + 与 kumone 的差距 + 元素身份清单 | [`KUMONE_REFERENCE.md`](KUMONE_REFERENCE.md) §6 |
> | 更早的历史（歌词线、pw 移植评估、过时目标审计） | `LYRICS_MODULE_NEXT_STEPS.md` / `SPOTIPW_0211_PORT_ASSESSMENT.md` / `STALE_AUDIT.md` |
>
> 写作时的仓库状态：**HEAD = `5541023`**（`b9e250b` 那批功能 + 一行编译修正 + 新自检规则）。
> 本机**没有 Swift 工具链**，所有"已修"都只到"源码 + 六条自检 + 人工推演 + 一轮独立只读复核"这一步。

---

## 0. 三十秒现状

| | |
|---|---|
| **用户这一场报过的问题** | ①「歌词 / 分享 / 全屏」那一行还在 ②「隐藏歌词」胶囊点不掉 ③ 换歌/进出页面时**原生大封面一闪** ④ 想要**页面记忆** ⑤ 排版还差 kumone 五六十 ⑥ 音量条难看 ⑦ 无时间轴 / 未找到 / 纯音乐时**歌词键点不开** |
| **已经落地的** | 那三行按钮消失（**是我们自己画错了对象**）；两颗胶囊按 **id** 按住；换歌/进出转场的封面闪（事件驱动 + 收尾推迟）；页面记忆；`.player` 排版档；header 上移 + 歌词块锚到进度条；音量条换皮；歌词键**随时能按**并在正中写一句说明 |
| **最有价值的一次纠正** | **判据落在 `accessibilityIdentifier` 上** —— 前两轮按类名子串、按无障碍标签猜那颗胶囊，白绕两轮；它一直有 id：`lyrics-npv-switch-button` |
| **用户最新一次确认（照片 70）** | 页面的**几何与观感是对的**：缩略图 105–175pt（≈导航条下沿 + 8）、歌词块 242→~660、当前行居中 ≈440pt、音量条细轨+两端喇叭、胶囊/标题行/大封面都不在 |
| **🔴 现在唯一已知的"错行为"** | **无时间轴的歌词**：渲染层把它们滤掉 ⇒ 键点开后写的是**「未找到歌词」**（其实找到了，只是没时间轴）。见 §5·S1 |
| **下一个动作** | 先修 S1（一句话的判据拆开），再 CI → 装机 → **日志 56 + 照片** 收口 §4 那张单子 |

---

## 1. 逐轮做了什么（输入 → 判读 → 改动）

| 轮 | 输入 | 判读（证据） | 改了什么 |
|---|---|---|---|
| 1 | 日志 53、照片 60/61/62 | ★ 那一行「歌词 · 分享 · 全屏」**是我们自己画的**（`previewHeader`；几何算出来分享键中心 319 / 全屏 364，照片量到就是 319/364）；而 Spotify 那三颗在**被「一屏」折成 0 高的卡**里。胶囊的类名子串判据在完整页面树里**零命中**。换歌时 contentlayer **换 cell ⇒ 换封面对象**，而"按住封面"挂在 0.3s 轮询上 | `showsPreviewHeader`（歌词层不再画标题栏）+ 删掉整块 `hideNativeLyricsAffordances`；胶囊三层（藏那一行 / 按胶囊 / flag `lyrics_under_cover_art_enabled=false`）；`CoverFlashGuard.x.swift`（`CoverArtTiltView.layoutSubviews` 事件）+ 封面缓存防毒 |
| 2 | 日志 54、照片 63/64 | ★ 胶囊**一直有 id**：`lyrics-npv-switch-button`（104×32）/ `nowplaying-npv-musicvideos-switch`；**flag 生效了**（整份日志里 `LyricsContainerView` 一个都没有）⇒ "替用户按胶囊"整条路可以删 | 按 id `alpha = 0` 按住两颗胶囊（新开关 `hide_npv_pills`，默认开）+ 兜底走查；删掉类名/标签判据与"按胶囊"；封面改用 **pw 的局部手法**（`coverIn(tilt)` + `inCoverCell`） |
| 3 | 用户口头 | 展开状态只活在内存变量里，页面一走就被清 ⇒ 没有记忆 | `nowPlayingLyricsExpanded`（落盘）：只有用户点键才改；重进自动铺回 |
| 4 | 日志 55、照片 65/66 | 记忆生效（那次进出 6 回全对）；**退出闪** = `viewWillDisappear` 当场收尾（页面还在屏幕上就把封面写回）；**进入闪** = 第一拍量不到 ⇒ `isOpen` 回退 ⇒ "按住封面"的门禁那一整段是关的 | `pageWillLeave()` + 收尾推迟到"页面真不在窗口里"；`wantsOpen`（意图比结果宽一档）；胶囊发现改成**从听歌页子树**按 id 找并自报结论 |
| 5 | 照片 67/68 | 逐区块量测：header 低 ≈100pt、歌词块矮 ≈58pt、块距 10 vs kumone 26、音量条是系统原样 | `.player` 排版档 22/17/26/6；`thumb.y` 改成贴**导航条下沿**（id `now-playing-minimize-button`）；歌词块底边锚**进度条单元**（id `Components.UI.ProgressBarUnitNowPlaying`）−19；`lyricsTop` 20→66；音量条走 `MPVolumeView` **公开图片接口** + 两端小喇叭 |
| 6 | 照片 69 + 用户口述 | 用户点名每个元素是什么（**「1」= 歌单名**、**绿色 ✓ = 收藏歌曲**、左下 = 设备联动、右下 = 分享/播放页）⇒ "像 kumone"不必画假图标，**搬真控件**即可 | 只改文档与判断：`KUMONE_REFERENCE.md` §6.4 元素清单；计划改成"搬 ✓ 到 header" |
| 7 | CI 报错 + 用户要求提交 | `error: cannot find 'maxNodes' in scope` —— 我从别的文件抄了名字（那个文件的预算是 `maxScanNodes`） | 一行修正 + `swift_member_check.py` 新增**规则 ③**（跨文件裸引用 private 名字 ⇒ 必然编译错），两向验证过；提交 `b9e250b`（功能）+ `5541023`（修正+自检） |
| 8 | 照片 70 | 几何/观感**确认落地**（见 §0 表）；★ 但发现**无时间轴歌词被误报成"未找到"** | 未改代码（当时只读），记在 §5·S1 |

---

## 2. 现在这一页是什么样（照片 70 的实测，作为"基线"）

| 元素 | 位置/尺寸（414pt 宽换算） | 谁负责 |
|---|---|---|
| 导航条 | `v`(关闭) / **歌单名** / `⋯`(菜单) —— *Spotify 自己的，不动* | —— |
| header | 缩略图 72pt @ y **105–175**，右侧歌名 + 艺人 | `NowPlayingLyricsPlate.measure()`（`thumb.y = navBottom + 8`） |
| 歌词块 | **242 → ~660pt**（≈418pt 高），当前行居中 ≈440pt | 同上（`lyricsTop = 66`、底边锚进度条 −19） |
| 歌词排版 | 22pt / 块距 26（一屏 7 行左右） | `LyricsTypographyScale.player` |
| 进度条 + 三键 + 底部行 | Spotify 原生（5 键：shuffle/prev/play/next/repeat） | 不动（见 §5·S3） |
| 音量条 | 细轨 4pt + 小圆钮 14pt + 两端小喇叭，y≈823pt | `NowPlayingPageOverlay`（`eevee-npv-volume-row`） |
| 绿色 ✓（**收藏歌曲**） | 仍浮在右侧 ≈630pt | ⏳ 计划搬到 header 右侧（kumone 的 ♥ 位，见 §5·S3） |
| 两颗胶囊 | **不在**（`hide_npv_pills` 默认开） | `DeclutterChrome`（按 id `alpha = 0`） |
| 「歌词·分享·全屏」那一行 | **不在** | `showsPreviewHeader: false` |

---

## 3. 用户这一场明确提过的要求（**照这句做，别再自己发挥**）

1. **「歌词 / 分享 / 打开全屏歌词」这三个按钮不该出现** —— 那一行是我们自己画的 ⇒ 关掉我们自己的画法。
2. **「隐藏封面下单行歌词」这个开关要真的有用**（不是只藏文字，要那行**不存在**）。
3. **那颗「显示/隐藏歌词」胶囊不该出现**；旁边那颗「切换至视频」也一起。
4. **换歌 / 进页面 / 出页面时"原本的大封面"不许一闪而过。**
5. **页面记忆**：「我当时正在打开歌词这个页面，退出之后再重进也还是在这个页面，不是那个大封面。」
6. **「只要求像，暂时不做点击功能」** —— 目标是**看上去**和 kumone 一样；**搬运已有的真控件**（不是画假图标）。
7. **歌词键随时能按**；没词时在**歌词正中间**写：
   * 未找到歌词 ⇒ **「未找到歌词」**
   * 纯音乐 ⇒ **「此歌曲为纯音乐」**（现有键 `song_is_instrumental` = 「此歌曲为纯音乐。」）
8. **译文 / 罗马字**：**「之后再说」** ⇒ 不要擅自打开或改动。
9. **音量条**「是有点，只是挺难看的」⇒ 已换皮；位置逻辑（锚在底部堆下面）先别动。
10. **提交信息用英文**（仓库历史也是 `feat(scope): …` / `fix(scope): …`）。

---

## 4. 这一场学到的规矩（**都踩过，别再踩**）

1. ★★ **判据落在 `accessibilityIdentifier` 上**。前两轮按类名子串（`ShowLyricsButton`）与无障碍标签猜那颗胶囊，**两次零命中**；它一直有 id。**要动一个具体控件，先把 `[NPVTree]` 里带 `id=` 的整列打印出来。**
2. ★★ **改别人视图之前，先证明"用户看到的那一件确实是别人的"。** 那一行按钮算了三轮才定案：几何对得上 ⇒ **是我们自己的**。
3. ★ **藏一个入口要连带问"它的容器是谁"**：`≥350pt` 那条规则挑到的是 `CardView`（整张卡），而那张卡同时是**我们自己**预览层的宿主 ⇒ 会把自己藏掉。
4. ★ **轮询追不上"新建对象"**（换 cell / 换封面对象）：这种地方挂**事件**（`layoutSubviews`），不是把节拍调快。
5. ★ **"下一次就对了"必须写成判据**（抓到的图与上一首是同一个对象 ⇒ 不写缓存），否则一次性的时序问题会变成**永久错误**。
6. ★ **收尾时机要跟着转场**：`viewWillDisappear` 时页面**还在屏幕上**，当场把别人的东西写回 = 在转场里当场露出来。pw 把这一步放在 `tearDown`。
7. ★ **门禁要写"意图"（`wantsOpen`）而不只是"结果"（`isOpen`）**，否则"还没成功"的那段窗口（恰好是转场最显眼的时候）整段漏掉。
8. ★ **切换类动作（`sendActions`）能删就删**：按两次回到原状 + 落盘用户偏好。功能本身交给远端 flag 更干净。
9. ★ **别有"哑"控件**：没有内容可画要么别给入口，要么打开之后**说清楚是哪一种没词**（未找到 / 纯音乐 / 正在查找）—— 这是用户这一场亲自提的。
10. ★ **"查无此歌"不许冒充"纯音乐"**：两者数据都是空行，靠 `LyricsDto.isInstrumental`（只认源明确判定）区分。
11. ★ **诊断日志要能读出结论**：一次性日志（启动瞬间只有 6 个节点时打掉）等于没有；要"找到/没找到各一行 + 形状（走了几个节点、比对了什么）"。
12. ★ **别从别的文件抄私有常量名**（`maxNodes` vs `maxScanNodes`）—— 已加进自检规则 ③（§7）。
13. ★ **一次装机只验一轮**：这一场攒了很多轮改动，导致"哪一版出的问题"要靠照片时间戳去对。

---

## 5. 接下来做什么（按优先级，**S1 是唯一已知的错行为**）

### S1（立刻）无时间轴歌词被误报成「未找到歌词」

**事实链**（都有行号）：
* `LyricLinesAdapter.toAppleMusicLyricLines()` 第 21 行 `.filter { $0.offsetMs != nil }`，**一行时间都没有 ⇒ 返回空** ⇒ 我们这层没有行模型；
* 而注入给 Spotify 的那份 payload **是带这些行的**（`offsetMs` 全 0、`timeSynchronized=false`）⇒ **Spotify 自己的歌词卡能列全文**，只有我们这层不能；
* 我这一轮新加的 `NowPlayingLyricsPlate.noticeText()` 第 ③ 条把"有行但画不出来"归成**「未找到歌词」** ⇒ **误报**。

**建议改法**（按最小→最好）：
1. **拆判据 + 加一句话**：`lines` 非空但**没有一行带 `offsetMs`** ⇒ 新 l10n 键
   `lyrics_no_timeline`（en: "These lyrics have no timing" / zh-CN:「这首歌的歌词没有时间轴」），
   与"真没有行"（`lines.isEmpty`）分开；
2. （可选，体验最好）给这一档加**静态渲染**：不走时间轴，只把文本按行列出（不高亮、不滚动）——
   这正是 kumone"没有歌词排版"那一档的样子。

### S2（随下一次装机）验这一场剩下的"未验证"

装机后按 [SESSION_2026-10-11_HANDOFF.md](SESSION_2026-10-11_HANDOFF.md) §4 那张单子，重点：
* **进出转场不再闪**（照片 65/66 的两种情况）；
* 日志里 `[NPVLyrics] expanded — … (anchors: navBottom=…, progressTop=…, bottomStackTop=…)`
  —— **三个锚点必须是数字**，出现 `not found` 就换判据；
* 三种说明文案各来一次（未找到 / 纯音乐 / 正在查找）；
* `[Declutter] hid the Now Playing pill row (…) — hide #N` 有没有、N 涨不涨。

### S3（"像 kumone"剩下的几件，**都要用户拍板**）

| 序 | 做什么 | 依据 | 代价 |
|---|---|---|---|
| a | **把绿色 ✓（收藏）搬到 header 右侧**（kumone 的 ♥ 位）——「搬 holder 不搬控件」，**不写点击逻辑** | `KUMONE_REFERENCE.md` §6.4；`Components.UI.AddToButton`（页里有两份，一份常 hidden） | 动别人的布局，一轮验 |
| b | （可选）把 `⋯`（`Context menu`）也搬进 header | 同上 | 同上 |
| c | （可选）藏中间那行**歌单名**（`now-playing-navigation-unit-title-label`） | kumone 没有这一行 | 用户会失去"在哪个歌单"的提示 |
| d | （可选）藏 shuffle / repeat（kumone 只有三键）；左下设备键已有开关 | `KUMONE_REFERENCE.md` §6.3 表 | 功能取舍 |
| e | 非当前行**太暗**（照片 70 里几乎看不清）——可把非焦点不透明度抬一点 | 照片 70 vs 照片 68 | 一行常量 |

### S4（用户说"之后再说"）逐行译文 / 罗马字

`AppleMusicLyricsOverlay` 的 page 调用**现在没传** `showsTranslation`（恒 false）。等用户开口再做；
注意它会把歌词块占满（每块变两行），**要和 S1/S3 的几何一起算**。

### S5（老账，与本场无关但一直挂着）

1. **「突然无法播放全部歌曲」**：只排除了一个假设；下一步是补只读的**音频密钥路径探针**；
2. `NowPlayingPageOverlay` 的"没找到就接着试几拍"（九份日志同形）；
3. 封面改成"自己持有"（复用 `LyricsArtworkResolver`）；
4. 「一屏」橡皮筋：用户拍 A / B（10-06 文档 §2.5）；
5. 刷新 customize 种子（9.1.76 → 9.1.88）；把自检接进 CI（见 §7）。

---

## 6. 代码地图（这一场动过的地方，下一轮直接跳）

| 想改什么 | 去哪 |
|---|---|
| 歌词层几何（缩略图/标题行/歌词块/两个锚点） | `Appearance/NowPlayingLyricsPlate.swift` → `measure()`、`anchorText`、`navBarBottom`、`progressUnitTop` |
| 没词时的说明文案 | 同上 → `noticeText()` / `canShow()` / `applyNoticeLabel()`（标签 id `eevee-npv-lyrics-notice`） |
| 换歌 / 进出转场的封面 | 同上 → `coverDidLayOut(from:)`、`wantsOpen`、`pageLeaving`、`reconcile()`；`Appearance/CoverFlashGuard.x.swift` |
| 页面记忆 | 同上 → `rememberExpanded` / `reopenIfRemembered`；`UserDefaults.nowPlayingLyricsExpanded` |
| 两颗胶囊 | `Appearance/DeclutterChrome.x.swift` → `nowPlayingPillIdentifiers`、`notePillIfOurs`、`adoptNowPlayingPills`、`NowPlayingPillHideHook`；开关 `hideNowPlayingPills` |
| 音量条 | `Appearance/NowPlayingPageOverlay.swift` → `layoutVolumeRow` / `styleVolumeSlider` / `trackImage` / `thumbImage` |
| 排版档 | `Lyrics/AppleMusic/AppleMusicLyricsTextProfiles.swift` → `.player` |
| 标题栏开关（预览那一行） | `Lyrics/AppleMusic/AppleMusicLyricsOverlay.swift` → `showsPreviewHeader` |
| 取词状态 / 纯音乐标记 | `Lyrics/LyricsWordByWord.x.swift`（`LyricsLookupState`）、`Lyrics/CustomLyrics.x.swift`（三处写入）、`Lyrics/Models/LyricsDto.swift`（`isInstrumental`）、两个仓库（置位） |
| 无时间轴那条链 | `Lyrics/AppleMusic/LyricLinesAdapter.swift`（第 21 行的 filter） |

---

## 7. 自检与验收（本机可跑的部分）

```
python Tools/eevee-hookfinder/orion_hook_guard.py      # OK 327 文件（Orion 四条纪律）
python Tools/eevee-hookfinder/swift_brace_check.py     # OK 327 文件（括号/字符串配对）
python Tools/eevee-hookfinder/swift_member_check.py    # OK 272 文件（含本场新增的规则 ③）
python Tools/eevee-hookfinder/swift_string_check.py    # OK 276 文件（字符串字面量两向）
python Tools/l10n_lint.py --locale en                  # exit 0
python Tools/l10n_lint.py --locale zh-CN               # 426 keys, 0 missing, 0 extra
```

* **规则 ③（本场新增）**：裸引用"在别的文件里只有 `private` / `fileprivate` 声明"的名字 ⇒ 必然编译错。
  两向验证过：干净仓库 0 命中（2 秒）；同形状两文件夹具**报在该行、exit 1**。
  只认**值位置**的用法，声明过/绑定过的文件跳过 —— 宁可漏，不误报（脚本里留着 2026-10-01 那两次误报 246/110 的教训）。
* ⚠️ **它们都不做类型检查**（本机没有 Swift 工具链）：逐成员初始化器顺序、`@MainActor` 隔离、
  `#available` 在 `guard` 里的写法、`Optional<AnyView>.none` 这几类只能靠 CI。
* **建议把上面六条接进 CI**（一条 `run:` 的事），这样"编译错"之前先被自检挡掉。

---

## 8. 未验证声明（**不要去掉这一段**）

* **`b9e250b` / `5541023` 这一版在真机上没验过**：进/出转场那两处修复、三个锚点的实测值、
  三种说明文案、胶囊的 `hide #N` 计数、`.player` 排版与音量条换皮之后的样子 —— 都要看**日志 56 + 照片**。
  照片 70 只证明了"几何 + 音量条 + 胶囊不在"这几项。
* **本场派过两次独立只读复核**：一次抓到 1 条 blocker（胶囊按两次会又开回来）+ 4 条 likely-bug/nit，
  一次抓到 3 条缺口（无兜底发现 / 类名字符串比较 / 新路径零日志）—— **都已修**；
  两次复核**都读不到 `C:\dsh\...`**，所以本文件引用的日志行、照片量测、id 都是**作者单方证据**。
* **§5·S1 那条"无时间轴歌词被误报"是据代码推的**（`LyricLinesAdapter` 的 filter + `noticeText()` 的第 ③ 条），
  **没有专门跑一首无时间轴的歌去验**。
* **S3 那几件（搬 ✓ / 搬 ⋯ / 藏歌单名 / 藏 shuffle·repeat）都还没动** —— 按仓库规矩 7，动别人的布局前先问用户。
