# SESSION HANDOFF — 外观 / 清爽 / 手势 / 隐私 / 工具链

> 写于 2026-09-30。给**下一个会话**（人或 agent）的交接。
> 读这份就够开始干活了，不用复述背景；所有数据文件都在盘上（见 §2）。
>
> ⚠️ **2026-10-01 更新**：日志 8 已到位，§1 的验证状态与 §5 的待办**已被 §8 取代**。
> 先读 §8 再看别的；§8 里有本轮改了什么、剩下的差什么、下一份日志要抓哪几步。

---

## 0. 一句话概括

本会话把 spoti.pw 的**思路**（外观、清爽、手势、隐私、flag 覆盖、触感）在这个仓库里
**从零实现**了一遍，并为此补了工具链：ObjC 类名抽取、逐屏视图清单、以及一个改成广度优先的
真机视图树转储器。**没有复用 spoti.pw 的任何一行代码**（许可原因，见 §6）。

---

## 1. 本会话交付了什么（含验证状态）

| 功能 | 实现文件 | 验证状态 |
|---|---|---|
| **深色栏（仿 AM）**：藏掉灰 scrim、把模糊换成深色材质 | `Sources/EeveeSpotify/Appearance/AmoledTheme.x.swift` | ✅ **真机验证**：用户确认顶部变透明；日志 `[AMOLED] SPNavigationBar … scrim=2 blur=2` |
| **标签栏 AM 材质**：自己插一层 `.systemThinMaterialDark` | 同上（`ensureTabBarMaterial`） | ✅ **真机验证**：用户确认毛玻璃生效；日志 `[AMOLED] tab bar material inserted` |
| **清爽开关 ×7**（迷你播放条 / 标签栏渐隐 / free-tier 条 / 封面下单行歌词 / 首页顶部条 / 设备按钮 / 加号按钮） | `Sources/EeveeSpotify/Appearance/DeclutterChrome.x.swift` | 前 4 个：日志证明隐藏动作都跑了（`[Declutter] … hidden`）；后 3 个 **待验** |
| **歌词宿主修复**：不再把"封面下那行跟唱"当宿主 | `Sources/EeveeSpotify/Lyrics/CustomLyrics+AllTracksLyrics.x.swift`（`isSingalongLineHost`） | ✅ 日志 7 证明：`inline host found: Lyrics_TextElementImpl.LyricsTextView` + `legacy overlay attached — host=… 342x256`（旧路径！） |
| **播放器双击手势**（3 个面开关 + 动作选择） | `Sources/EeveeSpotify/Gestures/PlayerGestures.x.swift` | ⏳ **待验** |
| **上报拦截**（请求侧取消 + 观察模式 + 关键词） | `Sources/EeveeSpotify/Privacy/Telemetry*.swift` | 部分：日志 `[Telemetry] request-side hook installed`；**实际拦截未验**（开关当时是关的） |
| **Flag 覆盖 + 41 条目录** | `Sources/EeveeSpotify/Flags/*` | 部分：装上且目录可用；**从未设置过一条覆盖**，`activeReplacements` 那条路未验 |
| **触感反馈** | `Sources/EeveeSpotify/Haptics/*` | ❌ **从未验过**：开关一直是关的，而它是启动时装 hook |
| **视图树转储器**（`bg=` / `id=` / 广度优先） | `Sources/EeveeSpotify/Diagnostics/ViewTreeDumper.swift` | ✅ 日志 6（DFS，250 节点）→ 日志 7（BFS，263–400 节点，**播放器控件终于可见**） |
| **逻辑测试进 CI** | `.github/workflows/tests.yml` + `Tests/{TelemetryClassification,FlagOverrideStore,URLAdClassification}` | ✅ workflow 通过（用 `macos-latest`） |
| **工具：ObjC 类名抽取** | `Tools/eevee-hookfinder/extract_objc_classnames.py` | ✅ 5837 个类名 |
| **工具：逐屏视图清单** | `Tools/eevee-hookfinder/summarize_view_trees.py` | ✅ 39 份转储 → 1750 行 |

设置入口：**设置 → EeveeSpotify → 扩展功能**（深色栏 / 清爽 / 首页与播放器 / 双击手势
四节 + 隐私·触感·Flag 覆盖三行入口）。

---

## 2. 数据资产（盘上在哪、怎么重新生成）

| 资产 | 位置 | 生成方式 |
|---|---|---|
| **Swift 类名 16930** + rpc/flags/methods/selectors | `C:\dsh\ipa\dump-9.1.86.txt` | 早先会话跑 `Tools/eevee-hookfinder/find_player_track_class.py` 之类（脚本都在同一目录） |
| **ObjC 类名 5837** | `.spotify-ipa/objc-classnames.txt` | `python Tools/eevee-hookfinder/extract_objc_classnames.py "C:\dsh\ipa\Spotify- Music and Podcasts_9.1.86_decrypted.ipa" -o .spotify-ipa` |
| **逐屏视图清单** | `.spotify-ipa/view-inventory.txt`（日志 3+5+6）、`.spotify-ipa/view-inventory-7.txt`（日志 7） | `python Tools/eevee-hookfinder/summarize_view_trees.py <日志…> -o <输出>` |
| **设备日志**（转储、hook 日志、歌词判定） | `C:\dsh\ipa\eeveespotify_debug_shared {1..7}.log` | 用户真机 + 设置里的「日志记录」 |
| **截图** | `C:\dsh\else\*.jpg` | 用户（照片 15 = 迷你播放条；照片 16 = 正在播放页） |
| `.spotify-ipa/` | 工作区，**未跟踪** | 是否加进 `.gitignore` 由用户决定 |

⚠️ `dump-9.1.86.txt` **只有 Swift 类**；`SPNavigationBar`、`SPTNowPlayingBar` 这类 ObjC 名字
必须去 `objc-classnames.txt` 找（本会话才发现并补上）。

---

## 3. 真机树的关键事实（9.1.86 / iPhone 11 / iOS 27）

**外壳与栏**
- `SPNavigationBar@0,48,414,44`；灰 scrim 是 `_UIBarBackground` 里的 `UIImageView`（alpha=0），
  同级另有 `UIVisualEffectView`。
- **标签栏那一支没有任何底色或材质**：`TabBarContainer.overlayView` / `StackView` / `TabBarView` /
  `TabBarCompactView` 的 `backgroundColor` 全空，子树里也没有 `_UIBarBackground` / `UIVisualEffectView`。
  观感来自 `TabBarGradientView`（已被清爽开关藏）。→ **想改标签栏底色只能自己插视图。**
- 迷你条：host `TouchPassthroughView@0,749,414,64`，内含 `id=SPTNowPlayingBar`（`bg=#2C2430`，封面取色）。
- free-tier 条 `LimitedExperienceIndicatorBar`（`bg=#121212`）在该账号上是 0 高度。

**正在播放页（NPV）**
- 跟唱单行歌词：`LyricsContainerView@0,335,366,120 > LyricsView id=singalong-lyrics-view`（封面正下方）。
- 歌词卡：`CardView id=lyrics-card-view`（374×320）；正确宿主 `Lyrics_TextElementImpl.LyricsTextView`（342×256）。
- 播放器控件 id：`SPTNowPlayingSliderV2`（386×2，拖动时 370×17）、`SPTNowPlayingPlayButton`（48/64pt）、
  `Components.ConnectButtonOutputSwitcher`、`Components.UI.AddToButton`。

**首页**
- `HomeHeaderView@0,0,414,50`（问候语 + 筛选胶囊），**只在首页**出现（日志 7 的 #1–#7）。

**转储里"没有"的东西（重要）**
- 没有 audio unit / 音频渲染 / 引擎类 → **变速变调与 DSP 走不了类名 hook**（spoti.pw 是重绑
  CoreAudio 的 C 函数导入；本仓库有 `modules/fishhook` 可用，但要先抽**导入符号表**）。
- 没有任何 theme / palette / color provider / accent 类 → **"主题色"做不了正经版**。

**还没抓过的屏**：歌单 / 专辑 / 艺人 / 资料库 / 搜索（vc 链里只出现过首页与正在播放页）。

---

## 4. 踩过的坑（别重犯）

1. **转储器原是深度优先 + 250 节点** → 配额被外壳吃光，**屏幕下半部分永远看不到**（播放器控件全缺）。
   已改 **广度优先 + 400 节点**（`ViewTreeDumper.collect`）。
2. `UIBlurEffect` **没有** `style` 属性（"读回比较"会编译失败）→ 用关联对象打标记。
3. `UserDefaults` 里常量漏声明（如 `dumpViewTreeKey`）会编译失败 → 写完用 grep 核对"键 ↔ 属性"配对。
4. `#available(iOS 26.0, *)` 里用到的 API 必须包在判断内；用 `objc_getAssociatedObject` 要 `import ObjectiveC.runtime`。
5. **"只藏不显"会被当成 bug**（用户原话："关掉开关它也不回来"）→ 现在用关联对象记住
   "这一层是我藏的"，关开关即恢复（`DeclutterChrome.apply`）。
6. `isOfficialLyricsHidden` 是**数据层**开关（取不到词时用占位 payload 顶掉官方歌词），
   **它不隐藏任何视图**；反过来，我们供给的歌词会被 Spotify **自己的**视图渲染。
7. **歌词挂错地方的病根**（用户配置：逐词歌词开、更好的逐词歌词关）：`InlineLyricsHostLocator.findHost`
   的兜底会拿 `Lyrics_TextComponentImpl.LyricsViewControllerImplementation` 的 root view 当宿主，
   而它在 9.1.86 上**就是**封面下那行跟唱。AM 开时有 `preview host rejected` 闸门挡住，旧 overlay 路径没有。
   → 已在**宿主查找源头**排除该 id/类（`isSingalongLineHost`）。
8. 本会话 `pwsh` **必须** `sandbox_permissions: "danger-full-access"` 才能创建进程，
   否则一律 `[exit code: 3221225794]`（0xC0000142）。**这是提权点，不是命令错**。
9. 本地编译不可能（无 Mac）→ 只能 CI。`.github/workflows/tests.yml` 用 `macos-latest`
   （ubuntu + `swift-actions/setup-swift@v2` 会 404）。
10. l10n 只维护 **en / zh-CN**；其余 25 个 locale 会报 MISSING（已知漂移，`Tools/l10n_lint.py` 不在 CI）。
    `flag_override_mode_*` 等键经变量拼接，linter 会误报 UNUSED（正常）。
11. 写完功能要**自己先跑**：`python Tools/l10n_lint.py --locale en --quiet` / `--locale zh-CN`、
   grep 符号配对、`git status --short`。本会话靠这个挡掉了 3 个 push 级缺陷。

---

## 5. 下一步待办（按优先级 + 前提）

| # | 待办 | 前提 | 备注 |
|---|---|---|---|
| 1 | **验本批**：手势 + 首页/播放器清爽 | 一次编译 + 一份日志 | 见 §7 |
| 2 | **每屏清爽 + 页面背景统一**（歌单/专辑/艺人/资料库/搜索） | **一次抓取**（那五屏从没抓过） | "更好看"里第二大的块 |
| 3 | **屏蔽艺人跳过** | 不需要新数据 | 用现成 `SPTPlayerTrackHook` + `WordByWordPlaybackControl.skipToNext()` |
| 4 | **玻璃重设计** | 先做 **1 屏样品**给用户看 | 周级工程；10 个屏各自独立 |
| 5 | 主题色 | —— | 只能糙版（全局 `tintColor`）；正经版做不了 |
| 6 | 验 **Flag 覆盖**实际生效 | 设一条覆盖 + 一份日志 | 目录里 41 条都是真机实测值 |
| 7 | 验 **触感** | 打开开关 + **重启 Spotify**（启动时装 hook） | 从未验过 |
| 8 | 音频（变速/DSP） | 抽 IPA **导入符号表** + 自己写 DSP | 用户已决定**搁置** |
| — | Live Activity | —— | 用户已决定**不做** |
| — | 锁屏歌词 / 动态封面 | —— | 用户已决定**暂缓** |

---

## 6. 需求与约束（用户的硬要求 + 环境）

- **许可红线**：spoti.pw HEAD = PolyForm Strict 1.0.0（**禁止复用代码**）；≤ v0.21.1 = GPL-3.0。
  用户要求：**只借鉴思路，代码全部自己写**。看它的 `README.md` / `AGENTS.md` / `docs/tweaks.md` 可以，
  **不要看/抄它的源码实现**。
- **目标设备**：iPhone 11（**LCD**）→ "纯黑省电/更黑"的论证不成立；验证靠**日志自报**，不靠肉眼比黑度。
- **目标版本**：Spotify 9.1.86 / iOS 27。
- **无 Mac**：本地编译不可能 → 编译只走 GitHub Actions
  （用户选的工作流：`.github/workflows/build-ipa-with-orion-patched.yml`）。
- **页面别臃肿**：根设置页曾是 18 行，已收敛为「扩展功能」hub + 子页（隐私 / 触感 / Flag 目录）。
  再加开关时优先考虑拆子页。
- **开关要能撤销、默认值要有理由**（每个默认值在代码注释里写明为什么）。
- **语言**：只维护 en / zh-CN。

---

## 7. 工作方式约定（继续照这个做）

1. **证据驱动**：类名 / id / frame **必须**来自 `dump-9.1.86.txt`、`.spotify-ipa/*.txt` 或真机转储。
   不猜类名——猜错的表现是"写了等于没写"或崩溃（历史上有过 EXC_BREAKPOINT 的教训）。
2. **每个 hook 都要自报**：装不上打 `missing <类名>`；每个开关被触发时打一行（一次）。
   验收靠日志，不靠眼睛。
3. **写完自己先跑**（§4.11）。
4. **批量写、一轮验**：用户每次"编译 + 抓日志"成本高，一次多写几项。
5. **前端/外观类改动**优先复用 `DeclutterChrome.apply` 的"可撤销隐藏"模式；
   新增 `.x.swift`（Orion hook）时 `typealias Group` + `HookGroup` + `activateXxx()` 且
   **先判 `NSClassFromString` 再激活**。

### 新会话第一步

1. 读本文件 + `Tools/eevee-hookfinder/LYRICS_MODULE_FINDINGS.md`（歌词那块的历史结论）。
2. `git -c safe.directory='*' log --oneline -8`：本会话的改动**已经提交**过（2026-09-30 当天
   连续几条），工作区通常只有本文件是新的。想知道某功能落在哪个文件，直接看 §1 那张表和
   `Sources/EeveeSpotify/{Appearance,Gestures,Diagnostics,Privacy,Flags,Haptics}/`。
3. 要写新 hook → 先在 `.spotify-ipa/` 里搜类名/id。
4. 跑脚本 → `pwsh` 记得带 `sandbox_permissions: "danger-full-access"`。

---

# 8. 2026-10-01 会话：日志 8 判读 + 地基修复

## 8.1 日志 8 是什么、判成什么

`C:\dsh\ipa\eeveespotify_debug_shared 8.log`（7757 行 / 644 KB / 16:47:31–16:49:33，
`build 2` / Spotify 9.1.86 / iOS 27）就是 §5 待办 #1 要的那份验收日志。

| 项目 | 日志 8 证据 | 判定 |
|---|---|---|
| AMOLED 深色栏 + 标签栏材质 | `scrim=2 blur=2`；`tab bar material inserted` | ✅ |
| 手势三面装上 | `attached on …` ×3，全程 0 条 `missing` | ✅ |
| 手势「切歌」 | `double tap left/right` + `[Shell] skipToNext/skipToPrevious` + 真换曲 | ✅ |
| 手势「前后跳 15 秒」 | 没测，且**必然失效**（见 8.2 C） | ❌ |
| 清爽：homeHeader / connect / freeTier / tabBarFade | 4 条 `[Declutter] … hidden` + 树上 `hidden` | ✅ |
| 清爽：**迷你播放条** | **无**上报行；树 #19/#20 里 `TouchPassthroughView` 可见、`SPTNowPlayingBar bg=#5C7074` | ❌ **没生效** |
| 清爽：**加号按钮** | **无**上报行；树 #4–#20 里 `id=Components.UI.AddToButton` 全部可见 | ❌ **没生效** |
| 清爽：跟唱单行歌词 | 开关 OFF | ⏳ |
| 歌词宿主修复 | `inline host found: Lyrics_TextElementImpl.LyricsTextView` + `legacy overlay attached … 342x256 level=word` | ✅ |
| 触感 / 上报拦截 / Flag 覆盖 | 分别 `off` / `block=OFF observeOnly=OFF` / `0 条` | ⏳ 三项都没开过 |
| 视图树转储器 | 20 份全 400 节点，`cap reached (20)` | ✅ 但配额用尽 |
| SponsorBlock | `[SB] activate: … class=<missing>` | ❌ 见 8.2 C |

**日志 8 白捡的新数据**（§3 的"还没抓过的屏"要改）：**资料库 #3**（`YourLibraryContent.collectionView`、
`YourLibraryHeader.*`、`Playlist.Row.Library`、`Artist.Row.Library`）、**歌单 #4/#19**
（`SPTFreeTierPlaylistTableView`、`Playlist.ItemCell`、`PlaylistCuration.Row.CurationActionsToolbar`）、
**艺人页 #20**（`Components.UI.ArtistHeadline`）、**全屏歌词 #15/#16**（`Components.UI.LyricsFullscreen`、
`lyrics-table-view`、`Components.UI.LyricsControlsView.*`）。
还差：**专辑 / 搜索 / 个人资料 / 设置页**。
→ 用 `summarize_view_trees.py` 把日志 8 过一遍可生成 `.spotify-ipa/view-inventory-8.txt`（尚未生成）。

## 8.2 日志 8 暴露的三个真问题（本节修复）

**A. 迷你播放条"藏了回不来"**
`DeclutterChrome.apply` 的 `guard !view.isHidden`（原 113 行）在"启动时没在播放"的情况下直接返回：
不标记、不上报；之后 Spotify 把它显示回来时**不一定再有 layout 回合**，于是隐藏/撤销两条路都断了。
日志 5 有 `mini player bar hidden`，**日志 6/7/8 一行都没有**；用户侧表现 = "迷你条消失且无法恢复"。

**B. 加号按钮从没生效**
它只能从 `ConnectButtonView` 的兄弟里扫（原 246–257 行），而那颗按钮**已被我们藏掉** →
被藏的视图不再收 layout 回合 → 扫描实际只跑过启动那一次。

**C. SponsorBlock 观察者类名不存在，并连累手势的 seek 模式**
日志 8：`class=<missing>`。核对：`SPTPlayerServiceImplementation` 在 `.spotify-ipa/objc-classnames.txt`
里**没有**；真名是 `_TtC17Player_CommonImpl30SPTPlayerServiceImplementation`（`dump-9.1.86.txt`）。
后果：`SponsorBlockSkipper.lastPlayer` 永远 nil → `seekTo` 静默返回（外加 `options.enabled` 那道门），
而手势的 seek 分支正是用它取/落位置 → 用户报的"十五秒手势不生效"。
**反证就在同一份日志里**：`[WordByWord] position source: statefulPlayer.position() -> Double` 与
`[WordByWord] seek to 0ms` 都真的跑通了。

**D. 「扩展功能」页：手势动作选择器选完不刷新（2026-10-01 用户报）**
现象：改「双击手势 → 动作」（切歌 / 前后跳 15 秒）后页面显示不变，**重启**才更新；
对照「Flag 覆盖」页的取值控件一切正常。
根因：这一页每个控件绑的是**读 UserDefaults 的临时 Binding**
（`Binding(get: { UserDefaults.x }, set: { UserDefaults.x = $0 })`）——写 `UserDefaults`
**不会**让 SwiftUI 失效重绘。`Toggle` 自己会重绘所以看不出来；`Picker` 的标签要靠**父视图**
重新求值，于是停在旧值。
对照证据：`SponsorBlockSettingsView` 用 `@State options`、Flag 覆盖页用 `@State newMode` + `@State overrides`
（`modeBinding` 的 setter 还会 `overrides = FlagOverrideStore.all`）→ 触发重绘 → 所以那两页没这个毛病。
另注：**行为本身一直是即时生效的**（`PlayerGestures.behavior` 每次点击现读 UserDefaults），
坏的只是**显示**。

## 8.3 本轮改了什么（4 个文件，均已过自检）

| 文件 | 改动 |
|---|---|
| `Sources/EeveeSpotify/Appearance/DeclutterChrome.x.swift` | 新增**复查（reconcile）**：5 个 hook 顺手 `note()` 登记自己，加号/设备按钮由复查按无障碍 id 在窗口里找（另 1s 节流，且两个开关都关着时零扫描）；三个驱动 = **0.5s 定时器**（主节拍，`.common` 模式，带**熄屏 guard**：`applicationState != .active` 时不空转，同 `ViewTreeDumper` 的纪律）+ **`MainWindow` 的 `layoutSubviews`** + **`didBecomeActive`**；`reconcileNow()` 供开关切换时当场落地 |
| `Sources/EeveeSpotify/Settings/Sections/Extras/Views/EeveeExtrasSettingsView.swift` | ①清爽那 7 个开关改用 `declutterBinding`：改完值立刻 `reconcileNow()`，**关掉开关的瞬间就还原**；②整页改用 `@State shadow` 影子值（`set` 先改影子值再落盘）修掉 8.2 D 的"选完不刷新"，并加 `.onAppear { shadow = Shadow() }` 与别处同步 |
| `Sources/EeveeSpotify/Gestures/PlayerGestures.x.swift` | seek 分支改走 `WordByWordPositionResolver.currentPositionSeconds()` + `WordByWordSeeker.seek(toMs:)`；位置读不到就打一行说明，不再"看起来在跳" |
| `Sources/EeveeSpotify/SponsorBlock/SponsorBlockHooks.x.swift` | `targetName` 换成 Swift 混淆名；激活时用 `class_getInstanceMethod` 探测 `addPlayerObserver:` 并写进日志（`class=<found> addPlayerObserver=Y/N`） |

关于迷你条开关的默认值：**已经是"默认展示"**（`UserDefaults.hideMiniPlayerBar` 是 `?? false`）。
日志 8 里 `miniPlayer=ON` 是手动开过的；用户要的是"保留开关 + 默认展示"，所以代码没动这一处。

**自检**：`git status` 只有这 4 个文件 + 本文件（未跟踪）；
四个文件括号/圆括号平衡；`python Tools/l10n_lint.py --locale en|zh-CN --quiet` 均无输出（干净）。
本地编译仍然不可能（无 Mac），必须走 GitHub Actions。

## 8.4 下一份日志（日志 9）要覆盖的清单

1. 手势行为切到**「前后跳 15 秒」**：期望**选择器当场就显示新值**（8.2 D 的验收点，不用重启），
   然后左右各双击一次 → 期望 `[Gestures] double tap left → seek …` + `[WordByWord] seek to Nms`。
2. 迷你条：播放中 → **划出 Spotify 再回来**（期望 `[Declutter] reconcile (app became active)`）→
   在设置里**关掉**开关（期望 `[Declutter] miniPlayer restored`，且条当场回来）。
3. 加号按钮：播放页里确认 `id=Components.UI.AddToButton` 不再可见，并出现
   `[Declutter] add-to button hidden (Components.UI.AddToButton)`。
4. 四个从没开过的开关：触感（**要重启**）、上报拦截、Flag 覆盖（**要重启**）、封面下单行歌词。
5. **抓日志前先重启 Spotify**：转储器一次启动只有 20 份，且**关开开关不会重置计数器**
   （`dumpsTaken` 只在进程启动时归零）→ 这次去**专辑 / 搜索 / 个人资料**三屏。
6. SponsorBlock：确认新日志里 `class=<found> addPlayerObserver=?`，再决定要不要开 SB 开关。

## 8.5 排期：还差什么

见 `Tools/eevee-hookfinder/SPOTIPW_GAP.md`（同一目录）。结论：spoti.pw 约 65 条用户可见功能，
缺的是 3 大块（玻璃重绘 / 音频三件套 / Live Activity+锁屏，后两者用户已否决）+ 一批小项；
顺序建议：**地基 → D 档小项（Updates 页 / Home 渐变 / Accent / Navbar labels）→ 屏蔽艺人 →
一屏玻璃样品**。用户 2026-10-01 决定 **D 档那四条等"液态玻璃"做完再说**。

## 8.6 ★ 路线情报：Spotify 自己有液态玻璃总开关

用新工具 `Tools/eevee-hookfinder/extract_flags.py`（自己写的，只读解密 IPA）从 **9.1.86 主二进制**
抽出了 **2485 条 `scope.name`** 的字面量 flag 表（落盘在 `.spotify-ipa/flag-table.txt` 等）。

关键发现：**`ios-reprise-liquid-glass-override` → `mode`**（推断取值
`default` / `force_enabled` / `force_disabled`）。"Reprise" 是 Spotify 内部对这套新设计的代号，
它旁边就是 `_TtC31Reprise_LiquidGlassOverrideImpl25LiquidGlassOverrideDaemon`。
spoti.pw 文档里说它"强制的那批 flag"（玻璃导航栏 / 新播放器滑块 / sheet 播放器 / 重设计播放器头 /
睡眠定时器选项 sheet / 全出血 header / mixing transition）在 9.1.86 上**逐个都能对上**。

→ 完整短名单、对照表与试法见 **`Tools/eevee-hookfinder/FLAGS_9186_DESIGN.md`**。
→ 这条**插在"一屏玻璃样品"之前**：如果 `force_enabled` 真能把 Spotify 自己的玻璃打开，
"重绘 10 个页面"就可能变成"在 Spotify 自己的新外观上做减法"。

---

# 9. 2026-10-01 第二批：验收通过的收尾 + 清理 + 打通 flag 通道

## 9.1 一次性验收结果（用户实测，§8 那一批全部落地）

| 项目 | 结果 |
|---|---|
| 隐藏加号按钮 / 迷你播放条 / 封面下一行歌词 / 设备按钮 | ✅ |
| 双击手势（正在播放页 / 全屏歌词页）、15 秒手势 | ✅ |
| **关掉开关当场恢复** | ✅ —— §8.3 那次修的核心 |
| 触感 / Flag 覆盖 / 上报拦截 | ✅ |
| 隐藏标签栏渐隐 | ⚠️ 生效（日志里有上报）但肉眼不可见 → **已删** |
| 隐藏 free-tier 条 | ⚠️ 该账号上高度为 0，无法观察（**保留**） |

→ `build 2` 的四个坏点（迷你条 / 加号 / 15 秒 / 选择器不刷新）全部修好并验证。

## 9.2 删掉的两个开关（让"扩展功能"变短）

- **迷你播放条的手势面**：`MiniBarGestureHook` / `GestureMiniBarGroup` / 设置行 /
  `playerGestureMiniBar` 键 / en+zh-CN 文案，全删。现在「双击手势」只剩两项。
- **隐藏标签栏渐隐**：`TabBarFadeHideHook` / `HideTabBarFadeGroup` / 复查里的 `tabBarFade` /
  设置行 / `hideTabBarFade` 键 / 文案，全删。它藏的是 `TabBarGradientView`（黑→透明渐变），
  深色主题上本来就看不出来 —— 不值得占一行。

## 9.3 打通 flag 通道（为"液态玻璃"铺路）

见 `FLAGS_9186_DESIGN.md` 末节。三处改动：

1. `EeveePropertyModification.forceEnum`（新增）+ `FlagOverride` 的「写入指定值」改用它
   → 服务端**没下发**的 flag 也能被覆盖（原来的 `.setEnum` 是空枪）。
2. `[Flags] override <scope>.<name> — N match(es)` 一行（在改写**之前**数命中），
   **所有**用户覆盖都打 → 从日志就能分清"没生效"和"生效了但界面没变"。
3. **构建开关（默认关）**：CI 工作流新增 `liquid_glass` 布尔输入；本地脚本认
   `ALLOW_LIQUID_GLASS=1` → 删掉 Spotify 自己写的 `UIDesignRequiresCompatibility=true`
   （读 IPA 得到的事实：那是玻璃的**硬闸**）。

## 9.4 下一批待办（按优先级）

1. **玻璃基线实验**：跑一次**带** `liquid_glass` 的构建，**先不加任何 flag**，看基线
   （变玻璃了？错位了？崩了？）。不崩再叠 `mode=force_enabled`。
2. **屏蔽艺人**（C 档唯一的真功能）：复用 `SPTPlayerTrackHook` +
   `WordByWordPlaybackControl.skipToNext()`（日志 8 已证明可用）。**待定**：名单怎么加
   （建议：艺人页/正在播放页一键加入 + 设置页手动增删）。
3. D 档小项（Updates 页 / Home 渐变 / Accent / Navbar labels）—— 用户已明确**等玻璃做完再说**。
4. 若第 1 步确认 9.1.86 没带那套玻璃 → 回到"**一屏玻璃样品**"（挑正在播放页或歌单页，
   日志 8 已把这两屏的类名/frame 抓全）。
