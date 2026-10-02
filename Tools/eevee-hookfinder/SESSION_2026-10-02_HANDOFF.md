# 交接：底部两条玻璃胶囊 + 第一批功能补齐（2026-10-02 深夜）

> **新会话先读这一份**。它讲的是"上一份入口文档（`SESSION_2026-10-02_SUMMARY.md`）之后发生的事"：
> 底部两条玻璃胶囊做到 v4.7.1、以及按 `SPOTIPW_GAP.md` 的估算开工的**第一批功能**。
>
> ⚠️ **2026-10-02 又加了一轮（v4.8）**：用户拿日志 28 + 照片 36/37 报了**四个问题**，
> 全部已改，**代码未装机**。先看 **§7**（那一轮改了什么），再看 §0 的现状表。
>
> 细节流水在 `SESSION_2026-10-02_APPEARANCE.md` **§19–§23**（§23 是 v4.8）；
> 对手清点在 `SPOTIPW_GAP.md` **§5–§8**；flag 那条线在 `FLAGS_9186_DESIGN.md`。

---

## 0. 三十秒现状

| 线 | 状态 |
|---|---|
| **标签栏玻璃胶囊** | **v4.8：360×60 恒定**（v4.6.1 的 312 已加宽；用户要求）、四颗收紧、文字已藏、**每颗各自垂直居中**、边缘 0.75pt 描边。纵向基准按「隐藏标签文字」分两支：**藏着按图标**（点「创建」再取消不再被顶到"有文字"的位置）、显示时按"看得见的内容"（见 §7.2） |
| **迷你播放条玻璃** | **v4.8：与标签栏等宽（360）、同高（60）**；内容等比缩到 **~0.86**（原来 0.74）；封面色底有**两个驱动**（50ms 级短促重试 + 蹭 `DeclutterChrome` 的 0.5s 节拍）—— 照片 36 那块蓝 8 秒不退的问题（见 §7.3） |
| **第一批功能**（上一轮） | ① 28 条新 flag；② All flags 补「写入数字」档；③ 备份/导入/重置；④ 更新日志页；⑤ 开源许可页 |
| **更新日志页** | **v4.8 修好**：以前显示"格式不正确"，真因是 GitHub **未登录限流**（日志 28 的 280 字节 403 响应体）被当成数据解；现在状态码先过闸、按真实原因说话、带 ETag/5 分钟缓存，仓库 slug 改用构建期生成的 `EeveeSpotify.repoSlug`（仓库已改名 `EeveeSpotifyEvolved`，见 §7.4） |
| **本轮改动状态** | ⏳ **未提交**（工作区里是 v4.8 的源码 + l10n + 文档） |
| **装机验证状态** | v4.6/v4.7 已验证；v4.6.1 / v4.7.1 由**日志 28 验收**（见 APPEARANCE §23.1）；**v4.8 未装机** → 验收清单在 **§7.5** |

---

## 1. 这一会话干了什么（按轮次）

### v4.6：胶囊高度恒定（照片 29 + 日志 25）
- **病根**：「创建」那颗**被选中时会显示一个 40×40 白色圆底**（`UIView frame=(32,4 40x40) bg=#FFFFFF alpha=0.00`），
  而 v4.5 的胶囊按"**看得见的内容**"并集量尺寸 → 文字藏着时带子 24→40pt → 胶囊 **40→56pt**（照片 29 实测 55pt）。
- **修法**：另起 `contentBands`，**只认图标 / 文字两类节点**（白色圆底那种装饰天然不算内容），
  且**文字藏没藏都算** → 量出来永远是有文字的版式。量算改读**布局几何**（`layer.position` / `bounds`，
  不吃我们自己写进去的 transform）。删掉拖动整套（保留 `UIGlassEffect.isInteractive` 按下回弹）。

### v4.6.1：图标被顶高的真凶（照片 30/31/32 + 日志 26）
- 日志 26 两份自报自己招了：`312x60 / 图标带 272x24 / dy=+10.0` ↔ `317x60 / 图标带 277x36 / dy=+3.8`
  ——「创建」那颗的 `SPTEncoreIconView` 在菜单打开时**会从 24×24 变成 33×33**（`[Tree] #7: IconView@35,7,33,33`），
  把一个**四颗共用**的 `dy` 拽小了 6pt。
- 修法：①尺寸**按中位归一化**（每块矩形用中位宽高重建、保留自己的中心）→ 胶囊恒为 `312x60`；
  ②纵向位移**一颗一个数**（`rowShifts`，基准是每颗**自己看得见的内容**）。

### v4.7 / v4.7.1：迷你播放条也铺一层（照片 33/34/35 + 日志 27）
- 用户要"迷你条也做成液态玻璃，高度/宽度和下面那条一样"→ 逐像素量出：迷你条内容 **398×56**、两条之间 **6.5pt**、标签栏胶囊 312×60。
- v4.7：新增 `GlassCapsule.swift`（**两条共用一个高度 = 60**）+ `MiniBarGlass.swift`；宽度贴内容（398）。
- **v4.7.1 修两个只有真机才看得见的问题**：
  1. **首帧盖不住** = Spotify 在我们清掉封面色之后**又写回来**（日志 27：16:50:19 清 → 16:50:20 树上又是 `bg=#64204C`）
     → "清一次就完事"是错的，改成**每次布局都清 + 写回计数**；
  2. 用户拍板**两条等宽（都 312）** → 内容**等比缩到 0.74**（`transform`，不动 Spotify 布局），
     玻璃**搬到宿主**里（再当内容的子视图就会跟着缩），宽度取自标签栏那条的**比例**（换设备也等宽，且不再随入场动画 414↔398 抽动）。
  3. 进度小条按用户选择**保持原样**（随内容缩到 ~284pt，仍在胶囊里）。

### 第一批功能（用户"行，做吧"）
- **★ 白捡组**：拿到 spoti.pw **v0.23.0-beta 的 deb**，在可见字符串里发现 Spotify 自己的
  **"减少打扰"模块** `ios-messaging-reduceinterventions-impl`（**一条提示一个 flag**），
  逐条在 9.1.86 的 flag 表里核对后，加了 **28 条** flag 到「已知 flag」的两个新分组
  （**推广与提示** / **界面元素与彩蛋**）。**零新 hook、零取证**。
- **All flags 补齐**：新增 `EeveePropertyModification.forceInt(Int32)` + 「写入数字」档（`FlagOverride.Mode.number`）。
- **备份与重置**：`SettingsBackup.swift`（**只碰 `UserDefaults.ownedKeys` 白名单**）+ 一页 UI（导出走剪贴板）。
- **更新日志页**：`GitHubRelease` 补 5 个**可选**字段（不影响版本检查）+ 一页列表。
- **开源许可页**：只写仓库里查得到的事实。

---

## 2. 接下来做什么（按优先级）

1. ⚠️ **本节这一条已被 §7.5 取代**：日志 28 已经把 v4.6.1 / v4.7.1 验掉大半
   （结论见 APPEARANCE §23.1），用户随后报了四个问题、当天就改完（v4.8）。
   **现在要做的是一次装机**，验收清单与预期日志行在 **§7.5**（那里面也带着"五件事"）。
   原计划（留档）：一次装机验三批（v4.6.1 + v4.7.1 + 第一批），
   冷启动先别碰 → 放歌让迷你条出现 → 四屏逛一遍 → 点「创建」→ 关掉 →
   去「扩展功能 → 设置与关于」把三个新页点一遍（备份页**先别点重置**）→ 发日志 + 截图。
   验收行见 `SESSION_2026-10-02_APPEARANCE.md` §20.3 / §22.3。
2. **第二刀：25 条清理开关里剩下的"界面元素"那批**（不是 flag，是视图）。
   **需要一次取证**：用现成「转储视图树」，在**搜索页 / 歌单页 / 播放页 / 首页**各停 2 秒后导出日志
   （转储器一次启动 20 份，够抓这四屏）→ 拿到 id/类名我就能按 `DeclutterChrome` 那套写出来。
3. **变速变调只读探针**：Spotify 自己有 `com.spotify.service.playbackcontrol.playbackspeed`（日志 25 里出现过）——
   先探它能不能借，零风险、成了就是白捡（不用碰音频图）。
4. **诊断 tree server + hang sampler**（对我们"抓类名"的痛点最对症）。
5. 之后：Custom navbar / Tab **显隐**（拖动排序已被建议砍掉，撞"不动布局"红线）。
6. **音频四块（Sing / DSP 十件套 / Music Haptics / 变速）继续搁置**：它们卡在同一个门槛
   （我们没有音频图访问），要吃先得做"抽 IPA 导入符号表 + fishhook 重绑"那个工程。见 `SPOTIPW_GAP.md` §5–§7。

---

## 3. 要求与规矩（照做，别重新踩）

1. **红线**：spoti.pw 是 PolyForm Strict 1.0.0 —— **只看思路，代码全部自己写**。
   这次"看 deb"也守住了：新增的 `Tools/eevee-hookfinder/inspect_tweak_deb.py` **只抽可见字符串/plist，
   不反汇编**；**导出物用完即删、不要提交**（临时目录 `.pw-inspect` 已删）。
2. **一次编译很贵** ⇒ **批量写、一轮验**；能合批的小项一起做（§7 的估算就是按"轮次"算的）。
3. **凡是要用户"编译 / 装机 / 发日志或照片"的，必须一次写清五件事**：
   ① 哪个 workflow、哪些构建开关；② 设置里开哪几个开关（写全路径）；③ 装完点哪些地方；
   ④ 发什么（日志名 + 截哪一屏）；⑤ **我到时候看哪几行日志**（把预期行先写出来）。
4. **写 `.x.swift` 之前/之后各跑一遍本机检查器**：`orion_hook_guard.py` / `swift_brace_check.py` /
   `swift_member_check.py`，外加 `l10n_lint.py --locale en --locale zh-CN`。
   ⚠️ 检查器认不了 `private(set)`（`swift_member_check` 会误报"没这个成员"）→ 用普通 `static var` + 注释说明"只读约定"。
5. **每个 hook 自报日志、开关可撤销、改动幂等**；设置页别臃肿；**不做运行时类枚举**（`objc_getClassList` 崩过两次）。
6. **不动 Spotify 的布局与手势**：要挪就用 `transform`（渲染期位移，不参与布局），
   并且**凡是反过来量位置的地方不能读 `frame`/`center`**（transform 非恒等时它们未定义）。
7. **值和 Spotify 的 binder 抢的时候**：`值没变不写`、`被写回就再写一次` 并**计数**
   （封面色底与标签文字两次都是这个形状）。
8. **本仓库的 UserDefaults 白名单**：`.standard` 里**同时躺着 Spotify 自己的偏好** ——
   "重置/导出"只能碰 `UserDefaults.ownedKeys`；**加新键记得往那个数组里补一行**，否则它不会被备份/重置。
9. **不要为了一个新 API 提高最低版本**：Theos 的 `spm_config` 给最低版本（历史上低到 iOS 14）——
   这一轮我为此把 `.task{}` 换成 `onAppear + Task`、把 `.textSelection` 删了。
10. **文档即交付**：改动落地就写进对应文档（外观 → `SESSION_2026-10-02_APPEARANCE.md`；
    功能缺口 → `SPOTIPW_GAP.md`；入口 → 本文件与 `SESSION_2026-10-02_SUMMARY.md`）。

---

## 4. 这一轮新学到的坑（血泪，别重踩）

| 坑 | 正确做法 |
|---|---|
| **`frame`/`center` 在 transform 非恒等时不可信** | 需要"布局位置"就读 **`layer.position`**（transform 绕 anchorPoint 施加，不动它）+ `bounds` |
| **同一族视图里有一颗会"变性"**（「创建」图标 24↔33） | 量尺寸时**按中位归一化**，别让一颗把整体拽偏；要各自居中的话就**一颗一个数** |
| **Spotify 会把我们清掉的值写回来** | 幂等 + 计数 + 记住"最后一次看见的原值"用于还原 |
| **迷你条内容是真机 398pt，而胶囊要 312** | 唯一不砍内容的办法 = **等比缩内容**（transform）；玻璃必须**搬出**被缩的那棵子树 |
| **首次布局与稳定态尺寸不同**（414→398） | 宽度别贴"会动的那一层"，取**比例**（相对宿主宽）或在宿主层算 |
| **`KnownFlagGroup` 的 `let` 默认值会被成员逐一初始化器排除** | 要"可省略参数"就用 `var footerKey: String? = nil` |
| **`Section(header:footer:)` 传 `Text?` 会撞重载** | 传非可选 `Text(footerKey.map { ... } ?? "")` |
| **本仓库测试是独立编译的**（`swiftc Tests/FlagOverrideStore/main.swift Sources/.../FlagOverride.swift`） | 改那几个被测试引用的文件时，**只加 Foundation 依赖** |

---

## 5. 改动落在哪儿（**已提交**：`eb9c3e7 w`）

```
Sources/EeveeSpotify/Appearance/MiniBarGlass.swift            (v4.7.1 重写)
Sources/EeveeSpotify/Appearance/TabBarGlass.x.swift           (v4.6–v4.6.1 + 曝露胶囊宽度)
Sources/EeveeSpotify/Appearance/GlassCapsule.swift            (新：两条共用的高度/圆角/材质)
Sources/EeveeSpotify/Flags/{FlagOverride,FlagOverride+Replacement,KnownFlagCatalog}.swift
Sources/EeveeSpotify/Premium/Models/EeveePropertyReplacement.swift        (forceInt)
Sources/EeveeSpotify/Premium/DynamicPremium+ModifyingFunctions.swift      (forceInt 两处分支)
Sources/EeveeSpotify/Settings/Models/SettingsBackup.swift                 (新)
Sources/EeveeSpotify/Settings/Sections/{Backup,Updates,Licenses}/...      (新：三页)
Sources/EeveeSpotify/Settings/Sections/{Extras,Flags}/...                 (入口 + 目录页 + 覆盖页)
Sources/EeveeSpotify/Settings/Shared/GitHub/...                           (release 字段 + 列表接口)
Sources/EeveeSpotify/Shared/Models/Extensions/UserDefaults+Extension.swift (ownedKeys 白名单 + miniBarGlass)
layout/.../EeveeSpotify.bundle/*.lproj/Localizable.strings                (27 语言 × 50 键)
Tools/eevee-hookfinder/inspect_tweak_deb.py                               (新工具)
Tools/eevee-hookfinder/{SESSION_2026-10-02_APPEARANCE,SUMMARY,SPOTIPW_GAP}.md
```
自检（提交前跑过，全过）：`orion_hook_guard` 315 文件 / `swift_brace_check` 315 / `swift_member_check` 260 /
`l10n_lint` en+zh-CN 无输出。**未提交的只剩文档**（本文件 + 两份入口指针）
—— 提交它们只需要一次 `git add Tools/eevee-hookfinder && git commit`，不需要重新装机。

---

## 6. 文档地图（哪份看什么）

| 想看什么 | 去哪 |
|---|---|
| **本次会话全貌 / 下一步 / 规矩** | **本文件** |
| 上一阶段的入口（设置页结构、清爽、手势、歌词线） | `SESSION_2026-10-02_SUMMARY.md` |
| 外观线的完整流水（v1→v4.8，含每个 bug 的真机证据） | `SESSION_2026-10-02_APPEARANCE.md` §11–§23（§19–§22 = 上一轮，**§23 = v4.8 这一轮**） |
| spoti.pw 有哪些功能、我们差什么、工程量估算、第一批交付 | `SPOTIPW_GAP.md` §1–§8（§5–§8 是拿到 deb 之后） |
| flag 通道怎么用、9.1.86 的 flag 证据 | `FLAGS_9186_DESIGN.md` |
| 哪些目标类名已经过时/已删 | `STALE_AUDIT.md` |
| 工具：类名抽取 / 视图清单 / 时点核对 / **deb 只读清点** | `Tools/eevee-hookfinder/*.py` |
| 数据资产（类名表、flag 表、逐屏清单） | `.spotify-ipa/`（未跟踪）、`C:\dsh\ipa\dump-9.1.86.txt` |

---

## 7. 2026-10-02 第三轮（**v4.8**）：用户报的四个问题，全部改完，等一次装机

> 输入：**日志 28**（`C:\dsh\ipa\eeveespotify_debug_shared 28.log`）+ **照片 36/37**
> （`C:\dsh\else\36.jpg`、`37.jpg`）+ 用户口述四条。技术细节在 **APPEARANCE §23**。

### 7.1 四条 → 四个改动

| # | 用户原话 | 病根（有证据） | 改动文件 |
|---|---|---|---|
| ① | 「液态玻璃的宽度有点少，给它伸长一点」 | 不是 bug，是 `horizontalPadding = 20`（312pt） | `TabBarGlass.x.swift`（一行常量）+ `MiniBarGlass.fallbackWidthRatio` |
| ② | 「隐藏标题栏文字时，点『创建』再取消，创建按键会变高，变成有文字时的高度」 | `visibleBand` 的兜底把**整颗 item 框（中心 24.5）**当内容 → `dy` 从 `+10` 掉到 `+2.5` 且**取消后回不来**（日志 28 `dy=…,+2.5` + dump #5–#13 一直是 `@279,2`） | `TabBarGlass.x.swift`（`itemIconBands` + `iconShifts` + 分两支的基准 + report 增加 `基=`） |
| ③ | 「首次加载/切歌时液态玻璃里有 Spotify 的颜色（照片 36），点创建或进听歌页再关就没有了」 | 清色只挂在**宿主布局回合**上，而写回**不伴随布局**：日志 28 里 `bg=#10346C` 出现在 00:47:46，我们直到 00:47:54 才清（8 秒） | `MiniBarGlass.swift`（`armColorGuard` 短促重试 + `reconcileCoverColor`）+ `DeclutterChrome.x.swift`（一行，蹭既有 0.5s 节拍） |
| ④ | 「更新日志显示：未能读取该数据，因为它的格式不正确」 | 限流被当成数据解（280 字节 403 响应体）+ 仓库 slug 写的是**改名前**的名字 | `GitHubHelper.swift`（状态码过闸 + 类型化错误 + ETag/缓存 + 用 `EeveeSpotify.repoSlug`）、`EeveeUpdatesSettingsView.swift`（按真实原因说话 + 重试按钮）、l10n |

### 7.2 问题②的一句话版本

隐藏标签文字时，**纵向居中的基准从"这颗粒看得见的内容"改成"这颗粒的图标"**
（`EncoreIconView`）—— 图标是唯一稳定的东西：「创建」那颗的白圆底（40×40、alpha 会停在 1）
与"子树整个不可见时兜底返回的整颗 item 框"都进不来，取消菜单后图标一定回到
`24×24@y=5`，于是 `dy` 回到 `+10`、四颗齐平。**文字显示时仍走老路**（否则文字会被推出胶囊底）。

### 7.3 问题③的一句话版本

清色**两个驱动**：写完一轮 5 次的 50ms 级短促重试（有节流、不叠加、没东西可清就停），
外加蹭 `DeclutterChrome` 既有的 0.5s 复查节拍看一眼。**不新开定时器、不是常驻轮询。**
残留：写回恰好落在两次复查之间时理论上能看到 ≤0.5s 色闪；要再快只能上 KVO/全局 swizzle，
那两样在本仓库属于"没验证过、崩过两次"的招数，**先不做**。

### 7.4 问题④：限流那条（顺手把仓库引用一起改了）

* 真身：`[GitHub] … -> 280 bytes` + `DecodingError.keyNotFound("tagName")`
  —— 280 字节是 GitHub **未登录限流**的 403 响应体（实测 404 的响应体是 130 字节），
  未登录 60 次/小时**按出口 IP** 算（运营商大内网是很多人共用）。
* 现在：`perform` 先看状态码并**把状态码与响应体开头写进日志**（下一份日志一眼定案），
  `GitHubAPIError` 分「限流 / 404 / 其它状态码 / 网络 / 解码」五种，界面按真实原因说话
  （限流还会说"大约 N 分钟后恢复"），并给「重试」按钮；5 分钟缓存 + `If-None-Match`
  条件请求（**304 不计额度**）。
* **仓库 slug 不再写死**：改用构建期生成的 `EeveeSpotify.repoSlug`（git remote 已指向
  `zbzxbg/EeveeSpotifyEvolved`）。同时把其它写死旧名的地方一起改了：
  `Makefile` 的兜底值、设置页右上角那颗「球」、版本页的 releases 链接、
  `common_issues.md` 的两条链接、两处 User-Agent。
  ⚠️ `Tools/eevee-hookfinder/LYRICS_MODULE_NEXT_STEPS.md` 里那几处是**历史流水**，没动。

### 7.5 ★ 下一份日志（日志 29）的验收清单（"五件事"）

**① 哪个 workflow / 构建开关**
`.github/workflows/build-ipa-with-orion-patched.yml`（与上一轮同一个），
构建开关 **`liquid_glass` 保持开**（默认开），其余不用动。

**② 设置里保持哪几个开关**
只需确认这三条是**开**（都是默认）：扩展功能 → 标签栏 →「标签栏液态玻璃」+「隐藏标签文字」；
扩展功能 → 迷你播放条 →「迷你播放条用液态玻璃」。
另外**打开**：设置 → EeveeSpotify → 调试 →「日志记录」+「转储视图树」。

**③ 装完点哪些地方**（顺序照做，这样日志能一次读完）
1. 冷启动，**别碰屏幕**，等迷你条自己出现（这一帧是问题③的现场）；
2. 放一首歌 → 让它播 5 秒 → **切下一首**（第二次触发问题③）；
3. 停在首页，**点一次「创建」→ 再取消**（问题②的现场；`dy` 必须在取消后回到 `+10`）；
4. 看两条胶囊的宽度与位置（问题①，肉眼 + 日志都要）；
5. 打开「扩展功能 → 设置与关于 → **更新日志**」（问题④）：
   - 正常：列出 `v0.1.0-beta.1` 那一条（标题 `v0.1.0`、日期 2026-09-18、正文两段）；
   - 若仍失败：看它显示的是"限流 / 404 / 网络"哪一种 —— **这句话本身就是新证据**。

**④ 发什么**
`C:\dsh\ipa\eeveespotify_debug_shared 29.log`（导出后改名）+ 两张截图
（① 首页底部那条 + 迷你条；② 更新日志页）。

**⑤ 我会看哪几行**（先在下面写好预期，省得来回）：

```
[TabBarPlate] 胶囊 (51,-3 360x60) r=30.0 ← 有文字带 (71,5 272x44) 图标带 (71,5 272x24) dy=[+10.0,+10.0,+10.0,+10.0] 基=图标 [栏 414x83] 插在 …
[MiniBarGlass] 胶囊 (27,… 360x60) r=30.0 ← 迷你条内容 398x56 缩到 0.86（与标签栏**等宽** 360、同高 60；宽度取自 标签栏那条的比例…）
[TabBarPlate] … dy=[+10.0,+10.0,+10.0,+2.5] 基=图标 …      ← 点开「创建」（这一行是"应该有的"）
[TabBarPlate] … dy=[+10.0,+10.0,+10.0,+10.0] 基=图标 …      ← ★ 取消之后必须回到这一行（问题②的判据）
[MiniBarGlass] 封面色底写回第 N 次 — 已再清掉                  ← 问题③：N 应当只在切歌前后 +1~2
[GitHub] /repos/zbzxbg/EeveeSpotifyEvolved/releases?per_page=30 -> … bytes   ← 问题④：名字必须是新名
[GitHub] ⚠️ … → HTTP 403（280 bytes）…                        ← 若还是限流，会明确写出来（不再是"格式不正确"）
```

**通过判据**：① 宽 360、两条等宽；② 取消后 `dy` 四颗全 `+10`（四个图标齐平）；
③ `id=SPTNowPlayingBar` 带 `bg=` 的那一份 dump 与"已再清掉"之间 **≤0.5s**（冷启动/切歌各验一次）；
④ 更新日志列出那一条 release。

### 7.6 本轮自检（提交前跑过，全过）

`orion_hook_guard` 315 文件 / `swift_brace_check` 315 / `swift_member_check` 260 /
`l10n_lint --locale en|zh-CN` 无输出。
l10n：en + zh-CN 手写，其余 **25 个 locale 补齐 7 个新键**（值用英文原文，符合
`Tools/migrate_localizations.py` 里写的既有惯例），并把它们里面残留的旧数字
`312pt / 75%` 机械改成 `360pt / 86%`（zh-TW 另给了繁中译文）。
⚠️ 其它 locale 仍缺 96–103 个**更早**的键（已知漂移，linter 会报，不在 CI 里）。
