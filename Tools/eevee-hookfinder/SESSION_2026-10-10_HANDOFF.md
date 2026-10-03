# SESSION_2026-10-10_HANDOFF — 日志 54 的判读 · 照片 63/64 · 那两颗胶囊的真身份 · 封面的 pw 手法

> **新会话先读这一份**（自包含）。上一轮在
> [`SESSION_2026-10-09_HANDOFF.md`](SESSION_2026-10-09_HANDOFF.md)（照片 60/61/62、三层方案、
> 独立只读复核的 6 条发现）。
>
> 写作时：**起点 = 10-09 那批改动**（用户已编译装机 → **日志 54**）。
> 这一轮的输入是**日志 54 + 照片 63/64**；输出是**又一批未编译的源码改动**。
>
> 证据：`C:\dsh\ipa\eeveespotify_debug_shared 54.log`、照片 `C:\dsh\else\{63,64}.jpg`、
> 类名 `C:\dsh\ipa\dump-9.1.88.txt`、pw 隔离副本
> `.spotify-ipa\spotipw-v0.21.1\tweak\Sources\Redesigned\Player\PlayerArtwork.x`
> 与 `...\Native\Player\PlayerDeclutter.x`（GPL-3.0，只读思路）。

---

## 0. 三十秒现状

| | |
|---|---|
| **这一轮的起点** | 日志 54 = 10-09 那批改动的第一次真机 |
| **✅ 真的成了** | 「歌词 · 分享 · 全屏」那一行**没了**（照片 63 对比照片 60）；**单行歌词也没了** —— 日志 54 整份里 `LyricsContainerView` / `singalong-lyrics-view` **一个都没有**，说明第三层 flag `lyrics_under_cover_art_enabled=false` 从根上关掉了那个功能 |
| **❌ 还没成（这一轮修）** | ①「显示 / 隐藏歌词」那颗**胶囊**还在（照片 63），旁边还有一颗「切换至视频」；②换歌时**大封面仍然闪一下**（照片 64） |
| **两个根因（都已定案）** | ① 那颗胶囊**一直带着无障碍 id**（`lyrics-npv-switch-button`）——前两轮按类名子串/标签猜，白绕了两轮；②「按住封面」上一版仍然是**整树找一遍**（`visibleCover`），换歌那一瞬间**必然挑中旧那张** |
| **这一轮改了什么** | 6 个文件 + 1 个新开关 + 2 条 l10n；**全部未编译、未装机** |
| **下一个动作** | CI → 装机 → **日志 55 + 照片 65+**（§6 验收单） |

---

## 1. 日志 54 判读（这一轮的两条硬证据）

### 1.1 ★ 那两颗胶囊**一直有 id**（前两轮白绕的原因）

```
13.Primary@0,0,26,32,hidden,id=nowplaying-npv-musicvideos-switch    ← 「切换至视频」（无 MV 时 hidden）
13.Primary@0,0,104,32,id=lyrics-npv-switch-button                   ← 「显示 / 隐藏歌词」（104pt = 图标+文字）
```

（`[NPVTree] #6`–`#20` 每一份都在；`#6` 那次是 `52,32,hidden` —— 它在"图标态"与"图标+文字态"之间重排。）

上一轮那套判据全落空，原因一目了然：

| 用过的判据 | 结果 |
|---|---|
| 类名子串 `ShowLyricsButton` | 日志 53/54 的听歌页完整子树里**零命中** |
| 无障碍**标签**「显示歌词 / 隐藏歌词」× 整窗 8000 节点 | 照片 63 证明**仍然没命中**（标签大概不在我们猜的那几个字符串上） |
| **无障碍 id** | ★ 一直就在那里：`lyrics-npv-switch-button` |

⇒ 这一轮直接按 id 按住（`alpha = 0`）。**判据落在 id 上，省两轮**——这是本轮最贵的一课。

### 1.2 ★ 第三层（flag）**真的生效了**

整份日志 54 里，`LyricsContainerView` 与 `singalong-lyrics-view` **一次都没出现**
（日志 51 是 `366,120`、日志 53 也是 `366,120`）。而同一份日志里：

```
[Flags] replacement ios-nowplaying-contentlayers-impl.lyrics_under_cover_art_enabled — 1 match(es)
```

⇒ `lyrics_under_cover_art_enabled=false` 把"封面下单行歌词"整个元素拿掉了。
**所以"替用户按那颗胶囊"这一条路已经不需要**（而且它有害：切换类动作按两次 = 又开回来，
10-09 的独立复核抓过这条 blocker）——这一轮把整块删掉。

### 1.3 照片 64：封面闪一下的现场

照片 64（0:00，刚换歌）里同时看得见两件事：

* 原生**大封面** = **新歌**的图（ただ君に晴れ / 眼睛）；
* 我们的**缩略图** = **上一首**的图（蓝天樱花）。

⇒ 上一版的 `coverDidLayOut` 虽然挂上了事件（`[CoverGuard] armed on …` 在日志 54 里），
但动作仍是 `keepNativeCoverHidden` = **在整棵树里再找一遍**哪张是当前封面
（`visibleCover` 的三趟判据）。换歌那一瞬间新封面可能还在淡入（`alpha == 0`）、或被 tier 判据排除
⇒ 挑中的是**旧那张（已经 alpha=0）** ⇒ `alpha = 0` 写在旧对象上，**新封面整张露着**。

---

## 2. **pw 怎么解这两件事**（这一轮照抄的两处）

> 来源：`.spotify-ipa\spotipw-v0.21.1\tweak\Sources\`（v0.21.1 = GPL-3.0，与本仓库同许可；
> **只读思路、代码自己写**。v0.22.0+ 是 PolyForm，绝不碰。）

### 2.1 封面：**不搜索，问 tilt 自己**（`Redesigned/Player/PlayerArtwork.x`）

```objc
// The child of the tilt view the size of the cover.
static UIView *coverIn(UIView *tilt) {
    for (UIView *sub in tilt.subviews)
        if (CGSizeEqualToSize(sub.bounds.size, tilt.bounds.size)) return sub;
}
static BOOL inCoverCell(UIView *tilt) {   // 祖先里有 CoverArtCellImpl
    for (UIView *v = tilt.superview; v; v = v.superview)
        if ([v isKindOfClass:NSClassFromString(@"_TtC28NowPlaying_ContentLayersImpl16CoverArtCellImpl")]) return YES;
}
%hook CoverArtTiltView
- (void)layoutSubviews { %orig;
    if (tilt.bounds.size.width < 200 || !inCoverCell(tilt)) return;
    UIView *cover = coverIn(tilt);  // ← 就地拿到那一张，不做全树搜索
    ...
}
```

**要点**：① 门禁 `bounds.width ≥ 200` + **祖先里有 `CoverArtCellImpl`**（一条判据同时回答
"是哪张"与"要不要管"——迷你条/卡片里那些 tilt 一次滤掉）；② 封面 = **和 tilt 等大的直接子视图**；
③ 用 `bounds` 比大小（tilt 被 inspect 手势转过时 `frame` 会变）；④ 隐藏用 `alpha = 0`。

### 2.2 胶囊/别人的 chrome：**`alpha`，不是 `hidden`**

pw 的 `AGENTS.md` 写得最直白：*"Setting `hidden` on views inside Spotify's `OverflowStackView`
or its Encore stacks crashes, so use alpha."* —— 这两颗胶囊正是 `Encore.Button.Primary`。

（另外 pw 对我们这个"单行歌词"用的是 `%hook Lyrics_NPVContainerKit.LyricsContainerView` 的
`setHidden:` 覆写 + `didMoveToWindow`；**我们已经不需要**它了：那条路是"藏视图"，
而第三层的 flag 直接把元素从树里拿掉，见 §1.2。）

---

## 3. 这一轮改了什么（**全部未编译、未装机**）

| 文件 | 改动 |
|---|---|
| `Shared/Models/Extensions/UserDefaults+Extension.swift` | 新增 `hideNowPlayingPills`（**默认开**）+ key 白名单 + `hideSingalongLine` 的注释按现状重写（两层） |
| `Appearance/DeclutterChrome.x.swift` | ★ **新增那两颗胶囊的按住逻辑**：`nowPlayingPillIdentifiers = [lyrics-npv-switch-button, nowplaying-npv-musicvideos-switch]`；`notePillIfOurs`（事件 hook 调用，出现即 `alpha = 0`）+ `reconcileNowPlayingPills`（把 Spotify 写回来的 `alpha` 再按住）；`apply(wantVanished:to:)` 用 `vanishedPills`（弱表）记账、关开关即写回。**删掉**：`applySingalongPreference`、类名子串判据、标签表、8000 节点走查、2s 节流/3 次上限、`PillLookup`、`firstControl`、`pillWeHid`、"替用户按胶囊"整条路 |
| `Appearance/DeclutterChrome.x.swift`（hook 区） | 新增 `HideNowPlayingPillsGroup` + `NowPlayingPillHideHook`（目标类 `_TtCCE16Encore_ButtonKitO16EncoreFoundation6Encore6Button7Primary`，`dump-9.1.88.txt:16168`），在 `activateDeclutterChrome()` 里按"类在不在"装；`[Declutter] installed (…)` 那行加上 `npvPills=` |
| `Appearance/NowPlayingLyricsPlate.swift` | `coverDidLayOut(from tilt:)` 改成 **pw 的局部手法**：门禁（开关 + 我们铺着 + tilt 在窗口里且 ≥200pt + 祖先里有 `CoverArtCellImpl`）⇒ `sameSizeChild(of: tilt)` ⇒ 对**那一个**写 `alpha = 0`（走同一个还原表）。**删掉** 50ms 节流与 `lastGuardedTilt`（局部动作不需要节流，节流正是"闪一下"的来源）。祖先判据用 **`isKind(of:)`**（= pw 的 `isKindOfClass:`，连子类一起认），不是比类名 |

### 3.1 ★ 独立只读复核（本轮）抓到的三条缺口 —— 已补

| # | 复核说的问题 | 处置 |
|---|---|---|
| R1 | **没有兜底发现**：万一事件 hook 没跑到（类改名 / Orion 拒装 / id 是布局之后才写上去的），`reconcileNowPlayingPills` 只认"已记住的引用"，屏幕上就永远没人管那颗胶囊 —— 而且**没有任何日志** | 新增 `resolvePillsIfNeeded(in:)`：开关开着 + 有槽位空着 + **1s 节流**时按 id 走查一遍（预算**自己一份**，不跟 `resolveIDTargets` 共用 —— 仓库规矩：预算按通道分）；找不到时打一行带节点数的日志 |
| R2 | 祖先判据用**类名字符串相等**，Spotify 一派生子类就**静默失效**（pw 用的是 `isKindOfClass:`） | 改成 `NSClassFromString` 拿类对象 + `isKind(of:)`（只查一个类，不是运行时类枚举） |
| R3 | 新的封面局部路径**一行日志都没有**：日志里只有"装没装"，分不清"tilt 从没布局"与"门禁一直不过"；另外胶囊那条 `reportOnce` 一辈子只打一行，看不出"每拍都在重新藏" | 封面：成功时"第一次 + 每 20 次"打一行（带门禁拒绝计数），**门禁连续拒绝 60 次**也打一行总结；胶囊：同样改成"第一次 + 每 20 次" |

复核同时**显式确认**了：重载 `apply(wantHidden:…)` / `apply(wantVanished:…)` 不歧义、`NSHashTable` 用法与仓库既有两处一致、
`[lyricsPill, videoPill].compactMap` 类型正确、`CGSizeEqualToSize` 可用、新 hook 满足 `orion_hook_guard.py` 全部规则且**被装上了**
（`activateDeclutterChrome` → `Tweak.x.swift:404`）、九个被删符号**全仓只剩注释**、
`hideNowPlayingPillsKey` 在 `ownedKeys` 里、pw 的 `alpha`-vs-`hidden` 原话在副本里逐字可查。
| `Settings/Sections/Extras/Views/EeveeExtrasSettingsView.swift` | 「清爽」那一节新增一行开关（`hide_npv_pills`）+ `Shadow` 加一个字段 |
| `layout/…/en.lproj` + `zh-CN.lproj/Localizable.strings` | `hide_npv_pills`（英文 / 中文各一条） |
| `Appearance/CoverFlashGuard.x.swift` | 文件头注释按新手法重写（照片 61 → 64 的两代现场 + pw 的 `coverIn`/`inCoverCell` 出处） |

---

## 4. 本机自检（全绿）

```
python Tools/eevee-hookfinder/orion_hook_guard.py      # OK 327 文件
python Tools/eevee-hookfinder/swift_brace_check.py     # OK 327 文件
python Tools/eevee-hookfinder/swift_member_check.py    # OK 272 文件
python Tools/eevee-hookfinder/swift_string_check.py    # OK 276 文件 / 46949 行
python Tools/l10n_lint.py --locale en                  # exit 0
python Tools/l10n_lint.py --locale zh-CN               # 425 keys, 0 missing, 0 extra
```

⚠️ **不做类型检查**（本机没有 Swift 工具链）。新开关只加在 `en` + `zh-CN` 两份 ——
这是仓库既有做法（`hide_singalong_line` 当初也只加了这两份；`l10n_lint` 全量跑本来就会为
另外 25 个 locale 报 missing，见 10-09 文档）。

---

## 5. 下一轮：CI → 装机 → 日志 55 + 照片 65+

### 5.1 操作顺序

1. 进听歌页（**有 MV 的那首**，比如照片 63/64 的 ただ君に晴れ）停 3 秒 → 拍一张：
   **两颗胶囊都不该在**（对比照片 63）；
2. 换一首**没有 MV** 的 → 拍一张（那颗「切换至视频」本来就不出现，但「显示歌词」也不该在）；
3. **连换三首**，每首停 2 秒 → 拍三张（★ 主验收点：**不许**再出现照片 64 那种"大封面 + 上一首的缩略图"）；
4. 进设置页把「隐藏播放器里的胶囊」**关掉** → 回听歌页（胶囊该回来）→ 再**打开**（该再消失）；
5. 回归：三颗传输键 / 歌词键能开能关 / `bounce=on` / 迷你条与首页开关没受影响。

### 5.2 预期日志

```
[Declutter] installed (miniPlayer=… singalongLine=ON npvPills=ON homeHeader=… connectButton=… addToButton=…)
[Declutter] hid the Now Playing pill row (lyrics-npv-switch-button / nowplaying-npv-musicvideos-switch) — hide #1
[CoverGuard] armed on _TtC35CreativeWorkCommons_CoverArtTiltKit16CoverArtTiltView
[NPVLyrics] hid the native cover from its own tilt (local path) — hide #1, 3 gate rejection(s) so far
   —— 关掉那个开关时：
[Declutter] the Now Playing pills are visible again
   —— 两条新加的"失败可见"日志（只在出问题时才出现）：
[Declutter] no Now Playing pill found by id in the window (…) — visited N node(s)
[NPVLyrics] the cover-tilt guard rejected 60 layout(s) and never hid anything — check the gates (…)
```

**读数**：`hide #N` 的 N 一直在涨 ⇒ Spotify 每换一次内容都会把 `alpha` 写回来（说明这条"重新按住"的
节拍是必需的，不是白写的）；N 停在 1 ⇒ 一次就够。两条失败日志出现 ⇒ 走 §5.4 的对策。

### 5.3 通过判据

| # | 判据 |
|---|---|
| ① | 有 MV 的歌：**两颗胶囊都不在**（照片 63 那两颗消失） |
| ② | 无 MV 的歌：那颗「显示歌词」也不在 |
| ③ | **换歌不再出现照片 64**（原生大封面 + 上一首的缩略图同屏）；缩略图不显示上一首 |
| ④ | 设置页那颗开关**当场**生效（关→回来、开→消失），不需要重启 |
| ⑤ | 回归：传输键 / 歌词键 / `bounce=on` / 迷你条与首页开关不受影响 |

### 5.4 失败时要警惕的

* 日志里**没有** `[Declutter] hid the Now Playing pill row` ⇒ hook 没装上或被 Orion 拒了
  （看有没有 `[Declutter] missing _TtCCE16Encore…7Primary`）；
* 胶囊在但日志说藏了 ⇒ Spotify 每一拍都把 `alpha` 写回来（看 `hide #N` 涨到多少；那就把
  `reconcileNowPlayingPills` 升成"按 id 重找一遍"，而不是只信引用表）；
* 出现 `no Now Playing pill found by id in the window (…)` ⇒ 那颗胶囊**不在我们走查的那棵树里**
  （或者在别的窗口）——那就把 `resolvePillsIfNeeded` 的起点从 key window 换成"听歌页那一层"再试；
* 出现 `the cover-tilt guard rejected N layout(s)` ⇒ **门禁哪一条不过**要一条条排：
  `window` / `width >= 200` / 祖先里有没有 `CoverArtCellImpl` / 有没有"和 tilt 等大的直接子视图"。
  最后一条最可疑（Spotify 换了层级）——那时改成"取 tilt 里最大的那个子视图"并记下它的类名与 bounds；
* **换歌还是有照片 64** 但两条日志都正常 ⇒ 说明那一下 `CoverArtTiltView` **没走 `layoutSubviews`**
  （事件没来）⇒ 退路是补一条轻量节拍（复用既有 0.3s，不加新定时器）；
* 胶囊**回来了但按钮不能点** ⇒ 我们写错了对象（把 `alpha` 写在栈上而不是按钮上）；
  判据是日志里那颗的 id。

---

## 6. 规矩（这一轮）

1. ★★ **"找不到"往往只是"没看 id"。** 这一轮最贵的一课：两颗胶囊一直有
   `accessibilityIdentifier`，我们却按类名子串、按无障碍标签猜了两轮。
   **下次要动一个具体控件，第一件事是把 `[NPVTree]` 里带 `id=` 的行整列出来。**
2. ★ **判据要落在"局部可判定"的东西上，而不是"全局重算"。** pw 的 `coverIn(tilt)`
   之所以不出错，是因为它**不问"哪张封面现在可见"**，只问"这个 tilt 自己的那张在哪"。
   我们上一版每次都在整树里重挑，于是换歌那一瞬间必然挑错。
3. ★ **切换类动作（`sendActions`）能删就删。** 第三层 flag 已经解决了"功能还在"的问题，
   那"按一下"就只剩坏处：按两次回到原状（10-09 复核抓到的 blocker）+ 落盘用户偏好。
4. ★ **别人的 Encore 栈里只用 `alpha`，不用 `hidden`**（pw 明确写过会崩）——
   这一条写进代码注释里了，别再试。
5. ★ **诊断日志要带 id 与原因**（`hid the Now Playing pill row (id / id)`）：
   下一次日志才能一眼看出"按住的是哪一颗"。

---

## 7. 还没做的（与上一轮相同，按优先级）

| 序 | 做什么 | 前置 |
|---|---|---|
| 1 | 按日志 55 收口 §5 那五条 | 日志 55 |
| 2 | ★ **排版向 kumone 看齐**（标题在顶、封面居中、歌词替代封面区）——「搬 holder 不搬控件」 | 三个 `*ElementsUnit` 类都在 9.1.88（已核） |
| 3 | **「突然无法播放全部歌曲」**：下一步是补只读的**音频密钥路径探针** | —— |
| 4 | `NowPlayingPageOverlay` 的"没找到就接着试几拍" | —— |
| 5 | 封面改成"自己持有"（复用 `LyricsArtworkResolver`） | 要先把 `layoutAndMount` 的同步返回改成"异步图到了再铺" |
| 6 | 「一屏」橡皮筋：用户拍 A / B（10-06 文档 §2.5） | 用户决定 |
| 7 | 刷新 customize 种子（9.1.76 → 9.1.88）；`swift_string_check.py` 接进 CI | —— |

---

## 8. 未验证声明（**不要去掉这一段**）

* **本轮 6 个文件 + 2 条 l10n 全部没有编译过、没有装机过。** 所有"已修"只到
  "源码层面 + 六条自检 + 人工推演 + pw 原文对照 + 一轮独立只读复核"这一步。
* **最后一版真机数据是日志 54**（= 10-09 那批改动）；照片 63/64 都是那一版。
* 本轮派过一次**独立只读复核**（只读 reviewer）：抓到 3 条缺口（无兜底发现 / 类名字符串比较 /
  新路径零日志），**已全部补上**（§3.1）。它同时**读不到** `C:\dsh\...`
  ⇒ 本文件引用的日志行、两个胶囊 id、照片量测**都是作者单方证据**，复核没能独立核对。
* ★ **照片 63 里那颗「显示歌词」胶囊的 id 归属，是从"同一排、同一类、宽度 104 与照片量到的
  ~98pt 吻合"推定的** —— 日志 54 里它**没有** `accessibilityIdentifier` 之外的身份证据
  （比如没有文字）。下一份日志里 `hid the Now Playing pill row` 一出现，
  就能用照片复核"消失的是不是那两颗"。
* ★ **`nowplaying-npv-musicvideos-switch` 在日志 54 里一直是 `hidden`**（那几首没有 MV）——
  所以"它可见时长什么样"只有照片 63/64 这一手；按住它的效果要下一条判据（§5.3 ①）才成立。
* ★ **"闪一下"是否真的没了，只有真机能证**：这条链上任何一环（tilt 没布局 / 子视图不等大 /
  Spotify 把 alpha 写回）都会让照片 64 重现 —— 失败判据与对策都写在 §5.4。
