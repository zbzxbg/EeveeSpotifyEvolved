# 交接：底部两条玻璃胶囊 + 第一批功能补齐（2026-10-02 深夜）

> **新会话先读这一份**。它讲的是"上一份入口文档（`SESSION_2026-10-02_SUMMARY.md`）之后发生的事"：
> 底部两条玻璃胶囊做到 v4.7.1、以及按 `SPOTIPW_GAP.md` 的估算开工的**第一批功能**。
>
> ⚠️ **2026-10-02 又加了一轮（v4.8）**：用户拿日志 28 + 照片 36/37 报了**四个问题**，
> 全部已改。**代码已由用户提交**（`76c687d fix`）并装机 → **日志 29 验收**：
> ①③④ ✅、② ❌ → 当天又写了 **v4.9**（§8，只改②，**未装机**）。
> **新会话先看 §0 的现状表 + §8**（§8.4 是日志 30 的验收清单）。
>
> 细节流水在 `SESSION_2026-10-02_APPEARANCE.md` **§19–§24**（§23 = v4.8、**§24 = v4.9**）；
> 对手清点在 `SPOTIPW_GAP.md` **§5–§8**；flag 那条线在 `FLAGS_9186_DESIGN.md`。

---

## 0. 三十秒现状

| 线 | 状态 |
|---|---|
| **标签栏玻璃胶囊** | **v4.9：360×60 恒定**、四颗收紧、文字已藏、边缘 0.75pt 描边。纵向位移在「隐藏标签文字」时**四颗共用一个数**（中位数）—— 点开「创建」时那一颗的暂时态**再也带不动自己**；文字显示时按"看得见的内容"。另有一层复核（短促重试 + 蹭 0.5s 节拍）兜"菜单关掉后不再布局"（见 §8.2/§8.3） |
| **迷你播放条玻璃** | **v4.8：与标签栏等宽（360）、同高（60）**；内容等比缩到 **0.87**；封面色底有**两个驱动**（50ms 级短促重试 + 蹭 `DeclutterChrome` 的 0.5s 节拍）。**日志 29 已验 ✅**：8 份 `[Tree]` 里 `id=SPTNowPlayingBar` 全都不带 `bg=` |
| **第一批功能**（上一轮） | ① 28 条新 flag；② All flags 补「写入数字」档；③ 备份/导入/重置；④ 更新日志页；⑤ 开源许可页 |
| **更新日志页** | v4.8 修好，**日志 29 已验 ✅**：`[GitHub] GET /repos/zbzxbg/EeveeSpotifyEvolved/releases/latest -> 5863 bytes`（原来是 280 字节的限流体 → "格式不正确"）。**页面本身这次没打开**，下次顺手看一眼能不能列出 `v0.1.0-beta.1` |
| **歌词：「AMLL 优先」** | **2026-10-02 恢复**（2026-09-25 你一句"感觉没什么用"删过一次，提交 `50528cd`）：单源模式下**先向 AMLL 要逐词歌词、只接受逐词**，不合格回退到你自己选的那个源。6 处按原文取回，默认**关**。细节见 `LYRICS_MODULE_NEXT_STEPS.md` **§58**（含"已知代价：AMLL 摸不到时会卡十几秒"） |
| **基线** | ⚠️ **Spotify 换成 9.1.88 了**（`C:\dsh\ipa\dump-9.1.88.txt` + `Spotify-…_9.1.88_decrypted.ipa`）。本改动依赖的类名/id 已核：**一个都没变**（见 APPEARANCE §24.1） |
| **本轮改动状态** | ⏳ **未提交**（工作区里是 v4.9 的源码 + 文档；v4.8 那一批已由用户提交成 `76c687d fix`） |
| **装机验证状态** | v4.6→v4.7.1 已验证；**v4.8 由日志 29 验收：①③④ ✅ / ② ❌**（见 APPEARANCE §24.2）。**现在 HEAD = `fa0bbe7`，里面叠了 4 处未装机改动（v4.9 / AMLL 优先 / RTL 贴边 / 应用图标接线）→ 一次装机的总清单在 §12** |

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

---

## 8. 2026-10-02 第四轮（**v4.9**）：基线换 9.1.88 + 日志 29 判读 + ② 真正修好

> 输入：**日志 29**（`C:\dsh\ipa\eeveespotify_debug_shared 29.log`）、
> **新数据资产** `C:\dsh\ipa\dump-9.1.88.txt` 与 `Spotify-…_9.1.88_decrypted.ipa`。
> 技术细节在 **APPEARANCE §24**。

### 8.1 基线：Spotify **9.1.86 → 9.1.88**（数据资产也换了）

`dump-9.1.86.txt` → **`dump-9.1.88.txt`**（17047 个类），IPA 换成 `…_9.1.88_decrypted.ipa`。
**本轮改动依赖的类名/id 已逐个核对：一个都没变**（`NavigationUI_TabBarImpl.TabBarView` /
`tabs-container-view-identifier` / `SPTEncoreIconView` / `SPTEncoreLabel`，依据是日志 29 的
`[Tree]`，见 APPEARANCE §24.1）。⚠️ `dump-9.1.88.txt` 是**符号表**，查不到运行时视图类名/id
是正常的 —— **判据永远是真机 `[Tree]`**。

### 8.2 日志 29 判读：①③④ ✅ / ② ❌

| # | 证据 | 判定 |
|---|---|---|
| ① | `[TabBarPlate] 胶囊 (27,-3 360x60)` + `[MiniBarGlass] 胶囊 (27,-2 360x60)`（x/宽一致）、迷你条内容缩到 `0.87` | ✅ |
| ③ | 8 份 `[Tree]` 里 `id=SPTNowPlayingBar` **全部不带 `bg=`**；`封面色底写回第 1..4 次 — 已再清掉` | ✅ |
| ④ | `[GitHub] GET /repos/zbzxbg/**EeveeSpotifyEvolved**/releases/latest -> 5863 bytes`（不再是 280 字节限流体） | ✅（页面没打开） |
| ② | `dy=[+10,+10,+10,**+2.5**]` 之后 **7 份 dump 全是 `ElementContentView@279,2`**，16 秒没回 `@279,10` | ❌ |

**②的病根（v4.8 只修了一半）**：v4.8 把基准从"看得见的内容"换成"自己的图标"——算是对的，
但仍然是**一颗一个数**：那个 `+2.5` 写进了创建那一颗的 transform，而
**菜单关掉时这条栏不一定再收到 `layoutSubviews`** → `apply` 再也不跑 → transform 永远停在那儿。
（`ElementContentView` 是 UIStackView 的 arranged subview，四颗 layout y 恒为 0 →
渲染 y=2 就是我们写的 dy=+2.5，不是 Spotify 挪的。）

### 8.3 v4.9 修法（只动标签栏那一支）

1. **主修**：文字藏起来时，纵向位移改成**四颗共用一个数** = 每颗"按自己图标"期望值的**中位数**。
   点开「创建」时四颗期望值是 `[+10,+10,+10,+2.5]` → 中位数还是 **`+10`**
   → 创建那颗**根本不动**，卡死这条路从根上断掉（日志里 `基=图标·整行`）。
2. **安全网**：一旦这一行"明显不齐"就置位 `rowIsTransient`，排一轮短促复核
   （0.2/0.5/1/2/3.5s，**自己直接调 `apply`**，不等布局）+ 蹭 `DeclutterChrome`
   既有的 **0.5s 节拍**（`TabBarGlassPlate.reconcileRowIfTransient()`，§8.5 那种一行调用）。
   行稳着时两处都只是**一次 bool 读**；**不新开定时器**。
3. 教训（写进纪律）：**把"暂时态"写进别人的视图之后，必须自己安排复核 —— "下一次布局回合"
   不是一个可以依赖的时机。**（与迷你条"封面色底写回不伴随布局"是同一族问题。）

### 8.4 ★ 日志 30 的验收清单（"五件事"）

**① workflow / 开关**：`.github/workflows/build-ipa-with-orion-patched.yml`，`liquid_glass` 保持默认开。

**② 设置里**：扩展功能 → 标签栏：「标签栏液态玻璃」+「**隐藏标签文字**」都开；
调试里「日志记录」+「转储视图树」开。

**③ 点哪些地方**（这次很短）：
1. 冷启动 → 等迷你条出现；
2. 首页点一次「创建」→ **等 3 秒** → 再点一次取消 → **再等 3 秒**；
3. 切一次歌；4. 打开「设置 → 扩展功能 → 设置与关于 → **更新日志**」。

**④ 发什么**：`eeveespotify_debug_shared 30.log` + 一张首页底部截图。

**⑤ 我会看哪几行**（预期已经写死，照着比对）：

```
[TabBarPlate] 胶囊 (27,-3 360x60) r=30.0 ← 有文字带 (71,5 272x44) 图标带 (71,5 272x24) dy=[+10.0,+10.0,+10.0,+10.0] 基=图标·整行 …
[TabBarPlate] 这一行暂时不齐（多半是「创建」菜单开着）— 会在 ~0.5s 内自己复核，不需要再有布局回合（v4.9）
[Tree] #N 13.ElementContentView<…TabBarItemElement>@279,10,103,49                    ← ★ 全程必须是 10，不能是 2
[MiniBarGlass] 封面色底写回第 N 次 — 已再清掉
[GitHub] /repos/zbzxbg/EeveeSpotifyEvolved/releases?per_page=30 -> … bytes            ← 更新日志页
```

⚠️ **点开「创建」时不会再出现第二条 `胶囊 …` 行** —— 因为这一版 `dy` 根本没变（四颗都还是 `+10`），
`report` 只在"变了"时报。**"没有那一行"正是修好的样子**（v4.8 那版这里会多一行 `…,+2.5]`）。
判据以 `[Tree]` 为准：那一颗的 `ElementContentView` **全程 `@279,10`**。

**通过判据**：① 上面第三条自报消失、且 `[Tree]` 里那一颗**始终是 `@279,10`**
（也就是四个图标永远齐平）；② 更新日志页能列出 `v0.1.0-beta.1` 那一条；
③ ①③④ 不回归（360 等宽 / 无 `bg=` / 新仓库名）。

### 8.5 本轮改动的文件（v4.9）

```
Sources/EeveeSpotify/Appearance/TabBarGlass.x.swift   （iconPreferredShifts / rowShift(中位数) / hasDeviation
                                                       / armRowRecheck / recheckRow / reconcileRowIfTransient）
Sources/EeveeSpotify/Appearance/DeclutterChrome.x.swift（reconcile 里一行：reconcileRowIfTransient()）
Tools/eevee-hookfinder/SESSION_2026-10-02_APPEARANCE.md（§24）
Tools/eevee-hookfinder/SESSION_2026-10-02_HANDOFF.md   （本节）
```

自检（提交前跑过，全过）：`orion_hook_guard` 315 / `swift_brace_check` 315 /
`swift_member_check` 260 / `l10n_lint` en+zh-CN 无输出。

---

## 9. 2026-10-02 第五轮：**恢复「AMLL 优先」**（用户点名要加回来）

**它是什么**：歌词来源是**单选**的；这个开关在单源那条路上多插一层 —— **先向 AMLL 要逐词歌词**，
而且**只接受"逐词可用"的结果**（判据与渲染层同一个 `hasUsableWordLevelData`；只有行级时间轴、
或干脆没有时间轴的，一律算不合格），不合格就**回退到你自己选的那个源**（连同它的设置与 Genius 兜底）。
依赖逐词歌词；来源是 Genius / 多级回退 / LRCLIB / AMLL 时设置页**不显示**它（那时没有"回退目标"）。
默认**关**。完整说明 + 当年为什么被删见 `LYRICS_MODULE_NEXT_STEPS.md` **§58**。

**恢复方式**：2026-09-25 删除它的是提交 `50528cd`（8 文件）。这次**按那次 diff 逐字取回**，6 处：

| 文件 | 内容 |
|---|---|
| `Lyrics/CustomLyrics.x.swift` | 单源分支里整段 `if amllPreferred { … }` + `allowGeniusFallback` 文档 + `catch` 注释 |
| `Settings/ngzhwm/ngzhwmSettingsViewModel.swift` | `amllPreferredKey`（`"ngzhwm_amllPreferred"`）+ `isAmllPreferred`（默认 false） |
| `.../Lyrics/ViewModels/EeveeLyricsSettingsViewModel.swift` | `@Published amllPreferred` + `animationValues` 里加回 |
| `.../EeveeLyricsSettingsViewModel+setupBindings.swift` | `logBooleanSetting($amllPreferred, "AMLL preferred")` |
| `.../Lyrics/Views/EeveeLyricsSettingsView.swift` | `amllPreferredSection()` + 调用点（四个来源排除条件） |
| `en` / `zh-CN` `Localizable.strings` | 两个键（删前原值；**只在 en/zh-CN**，其它 25 个语言从来没加过，不用补） |

**唯一差异**：`makeLyrics` 调用不再传 `durationMs`（该参数 2026-09-27 已从签名里删掉）。

⚠️ **已知代价**（当年"感觉没什么用"的真正原因之一）：日志 1/2 实测过 **14 秒阻塞**
（`api.amll.dev` 的 TLS 重试吃掉 11 秒）。真机上如果还是慢，便宜的改法是给那个仓库单独加短超时，
**不改回退链**；本次没做，等反馈。

**日志 30 顺手可以验**（前提：来源不是那四个排除项 + 逐词歌词开 + 开关打开）：

```
[Settings] AMLL preferred -> ON
[Lyrics] AMLL preferred — trying AMLL first, fallback target: <你选的源>
[Lyrics] AMLL succeeded — using it (N line(s))          ← 或 "…but not word-by-word…" / "AMLL unavailable…"
```

---

## 10. 2026-10-02 第六轮：**RTL（阿拉伯语）歌词贴左 → 贴右**

**用户原话**：「逐词歌词的时间轴没问题，就是**贴左**不是贴右。」

**病根**：贴哪一边跟的是**系统语言**，不是歌词语言 ——
AM 页 `row(for:)` 恒传 `alignment: .leading`（SwiftUI 的 `.leading` 用**环境 layoutDirection** 解析，
环境方向＝系统语言）；旧 overlay 三处 `textAlignment = .left` 写死。
（词序/连写/扫光方向本来就对：AM 渲染器读 `Text.Layout.Run.layoutDirection`，旧 overlay 按字符串区间上色。）

**改动**（3 个文件）：
| 文件 | 内容 |
|---|---|
| `Shared/Models/Extensions/String+ScriptDirection.swift`（**新**） | `String.prefersRightToLeftLayout`：UAX#9 P2/P3 取第一个强方向字符（跳过数字/标点/emoji，阿拉伯-印度数字显式跳过），RTL 区段返回 true。刻意**不用** `Unicode.Scalar.Properties.bidiClass`（成员名/可用性不稳，我们没 Mac 试错） |
| `Lyrics/AppleMusic/AppleMusicLyricsPage.swift` | `row(for:)` 按 `line.text.prefersRightToLeftLayout` 给整行 `.environment(\.layoutDirection, …)`，放在**链条最外层**（同时盖住行内对齐与 `.scaleEffect(anchor: .leading)`） |
| `Lyrics/LyricsWordByWord.x.swift` | 正文/译文/来源页脚三处 `textAlignment = .left` → **`.natural`**（容器是 `.fill`、`LineLabel` 是裸 UILabel，会生效） |

**边界**：只有**逐词**那条路由我们渲染；只有行级数据 / 无时间轴时整首交还 Spotify 原生（那两条的对齐是 Spotify 自己的事）。

**真机验收**（一首阿拉伯语歌，两张截图）：①「更好的逐词歌词」**开** → 贴右 + 焦点行从**右**侧放大；
② 同一个开关**关** → 旧 overlay 也贴右；③ 顺手放首中文/英文歌确认仍**贴左**（没被带偏）。

细节见 `LYRICS_MODULE_NEXT_STEPS.md` **§59**。

---

## 11. 2026-10-02 第七轮：**应用图标（App icon）接线** —— 「不可更改」的根因补掉

**用户问**：「应用图标不可更改这个补了吗？」→ 之前只把它列进缺口清单（"代码在、接线缺"），**没动手**；这一轮补上。

### 11.1 缺的到底是什么

三块料**早就在**：

* 设置页 `Settings/Sections/AppIcon/Views/EeveeAppIconPickerView.swift`（挂在 `EeveeSettingsView.swift:122`）；
* `Assets/AppIcon/`：**34 套**图标（`sources/*.png` 原始图 + 仓库里已生成好的 `@2x/@3x/~ipad`）；
* 工具 `Tools/alt-icons.sh`：sips 生成尺寸 → PlistBuddy 写键 → 就地改 app 目录。

**唯一缺的**：没有任何构建流程调用那个脚本。而 iOS **只认 app 的 Info.plist 里注册过的图标**
（`CFBundleIcons → CFBundleAlternateIcons → <名字> → CFBundleIconFiles`）——
设置页读的就是这个结构，`setAlternateIconName` 也要求名字与那个 key 一致。
所以装出来的包点开「应用图标」就是**空列表**（观感 = pw 那句 "The icon did not change"）。

### 11.2 改了什么（2 个文件，都在打包前）

两个 IPA workflow 的 `Ensure @executable_path/Frameworks rpath, then add OpeninSafari extension`
步骤里，**在 `zip` 打包之前**加了一段：

```bash
if [ -x /usr/libexec/PlistBuddy ]; then
  echo "== 注册应用图标（CFBundleAlternateIcons）=="
  bash "${{ github.workspace }}/Tools/alt-icons.sh" "$APP" \
    || echo "::warning::应用图标注册失败（不影响安装，只是那页是空的）"
  plutil -p "$APP/Info.plist" | grep -A3 'CFBundleAlternateIcons' | head -12 \
    || echo "(Info.plist 里没有 CFBundleAlternateIcons —— 图标没注册上)"
else
  echo "::warning::没有 PlistBuddy，跳过应用图标注册"
fi
```

* 位置选在打包前、`$APP` 已就绪之后 —— 图标必须进**终包**。
* 用 `${{ github.workspace }}` 的绝对路径：那一步已经 `cd` 到 IPA 所在目录，相对路径找不到脚本。
* **失败不中断构建**（只 `::warning::`）：没有图标的包照常能装能跑，只是那页空 —— 本仓库没有 Mac，
  真要排错只能靠 CI 日志，所以不能让它把构建带崩。
* 两个 workflow 是**公共步骤**（文件头明确要求同步），两边都加了。

### 11.3 本地校验（没有 Mac，能做的都做了）

* `pyyaml` 解析两个 workflow：**都通过**（改坏了 YAML 的话 Actions 会直接不认）。
* 抽出这一步的 shell 文本比对两份：差异只有 ①**本来就存在**的液态玻璃块（patched 版独有，13 行）
  与 ②我写的那行"另一个 workflow 里有同一段"的提示 —— **没有引入新漂移**。
* ⚠️ 本机 `bash` 是 WSL 启动器（没装发行版），所以**没法跑 `bash -n`**：shell 语法靠人眼 + 与
  同一步里既有写法（`|| echo "(没有 LC_RPATH)"`）保持一致。

### 11.4 真机验收 + 已知风险

**验收**：
1. CI 日志里应当有 `== 注册应用图标（CFBundleAlternateIcons）==`、`[alt-icons] applied 34 icon(s) to Spotify.app`、
   以及一段 `CFBundleAlternateIcons` 的 plist 片段；
2. 装机后：设置 → EeveeSpotify → **应用图标** → 列表不再是空的（34 项 + Default）→ 选一个 → 桌面图标变化。

**已知风险（说在前面，免得真机踩了不知所以）**：

* 这是**经典"按文件名"机制**（`CFBundleIconFiles` 指向 bundle 根目录里的 PNG），不是 asset catalog。
  若 iOS 26 已经不认这种形式（只认 Assets.car 里的图标名），日志会显示注册成功但界面仍不生效 ——
  那时的退路是给 `Spotify.app` 单独塞一份只含图标的 `Assets.car`（`actool` 编译，成本高一档）。
* 名字里**带括号/空格**的（`Asta_Liebe(Green)`）在侧载包上 `setAlternateIconName` 可能失败 ——
  设置页会弹错误（`EeveeAppIconPickerView` 的注释里就写着这条）。真机若确认失败，改法是
  在脚本里把注册用的键名 sanitize 成纯 ASCII（**不要**改文件名映射那套）。
* 塞文件 + 改 Info.plist 会让原有签名失效 → **必须重新签名**（侧载流程本来就会做，无额外步骤）。

---

## 12. ★ 下一次构建：**一次验完**（清单起点；**最新一轮的验收在 §14**）

> 你已经把这一轮全部提交：`9be72fb fix` = v4.9（「创建」对齐 + 复核）；`fa0bbe7 new` =
> 恢复「AMLL 优先」+ RTL 贴边 + 应用图标接线。下面是**一次装机要验的全部**，不只是这一轮的：
> 🔴 = 本次新改动；🟡 = **至今一次都没在真机上打开过**的老交付（日志 29 里 `[Settings] 行数 = 0`，
> 说明那次根本没进过任何 EeveeSpotify 子页）。

### 12.1 五件事

**① workflow / 构建开关**：`.github/workflows/build-ipa-with-orion-patched.yml`（Actions 里 patched 那个入口），
`liquid_glass` 保持默认开。

**② 设置里开哪几个**：设置 → EeveeSpotify → **调试** → 「日志记录」+「转储视图树」都开。
其它保持默认（「标签栏液态玻璃」「隐藏标签文字」「迷你播放条用液态玻璃」默认就是开）。

**③ 装完按这个顺序点**（顺序能让日志一次读完）：

1. 冷启动，**别碰屏**，等迷你条自己出现；
2. 放一首歌 → 播 5 秒 → **切下一首**；　　　（1+2 = 🔴③ 封面色底的回归）
3. 停在首页 → 点一次「创建」→ **等 3 秒** → 再点一次取消 → **再等 3 秒**；　（**🔴 v4.9 核心**）
4. 放一首**阿拉伯语歌** → 打开全屏歌词页 → 截图 → 回设置关掉「更好的逐词歌词」→ 再看一次、再截一张；　（🔴 RTL）
   ⚠️ 这首歌**要有逐词数据**（Musixmatch / Spicy 那类源）。若它只有逐行数据，两条路都不走、
   整首交还 Spotify 原生界面 —— 那样截的是 Spotify 的排版，验不到我们的改动。
   （哪一首有逐词，看日志里有没有 `hasUsableWordLevelData` / `[Lyrics] … word` 那类行，或直接看歌词页有没有逐词高亮。）
5. 放一首**中文/英文歌** → 全屏歌词页看一眼（应当**仍然贴左**，确认没被带偏）；
6. 设置 → EeveeSpotify 根页 →「**更新日志**」→ 能不能列出 `v0.1.0-beta.1` → 截图；　（🟡）
7. 设置 → EeveeSpotify → 扩展功能 →「**应用图标**」→ 列表应当是 **34 项 + Default** → 选一个 → 回桌面看图标变化；　（🔴）
8. 同一个「扩展功能」页 →「**备份与重置**」→ **只点导出**（走剪贴板），**先别点重置**；　（🟡）
9. 「扩展功能」→「**开源许可**」→ 能打开、文案在；　（🟡）
10. 「扩展功能」→「**已知 flag**」→ 进「推广与提示」组 → 随便点一条（= 加一条覆盖）→
    回「**Flag 覆盖**」页确认它在列表里；　（🟡：28 条新条目 + 一键 prefill 从没点过）
11. **顺手取证（0 额外成本，省一整轮）**：搜索页停 2 秒 → 歌单页停 2 秒 → 播放页停 2 秒 → 首页停 2 秒
    （转储器一次启动 20 份配额，够抓这四屏）→ 下一批「视图类清理开关」就靠这份日志。

**④ 发什么**：`eeveespotify_debug_shared 30.log` + **三张截图**（阿拉伯语歌词页 ×2：开关开/关；
更新日志页 ×1）。CI 那边顺手把构建日志里那三行 `alt-icons` / `CFBundleAlternateIcons` 也贴一下。

**⑤ 我看哪几行**：见 12.2。

### 12.2 预期日志行（对着比）　★ 判据已按 **v4.10** 更新

```
[TabBarPlate] 胶囊 (27,-3 360x60) … dy=[+10.0,+10.0,+10.0,+10.0] 基=图标 …
[TabBarPlate] 这一行暂时不齐（多半是「创建」菜单开着）— 会在 ~0.5s 内自己复核，不需要再有布局回合（v4.9）
[TabBarPlate] 胶囊 (27,-3 360x60) … dy=[+10.0,+10.0,+10.0,+2.5] 基=图标 …   ← 点开「创建」那一刻（对的）
[TabBarPlate] 胶囊 (27,-3 360x60) … dy=[+10.0,+10.0,+10.0,+10.0] 基=图标 …   ← ★ 取消之后必须回到这一行
[Tree] …ElementContentView<…TabBarItemElement>@279,2 …    ← 菜单开着时（对的，它自己居中）
[Tree] …ElementContentView<…TabBarItemElement>@279,10 …   ← ★ 取消之后必须回到 10，且**不能一直停在 2**
[MiniBarGlass] 封面色底写回第 N 次 — 已再清掉
[GitHub] /repos/zbzxbg/EeveeSpotifyEvolved/releases?per_page=30 -> … bytes
[Settings] AMLL preferred -> ON                                        ← 勾上「AMLL 优先」时
[Lyrics] AMLL preferred — trying AMLL first, fallback target: <你选的源>
[REVERT_WATCH][init] ads=… on-demand=… catalogue=… country=…          ← ★ 新增：每份日志都会有（产品状态）
[INIT] patching: overwriteConfig=ON/OFF（…）                           ← ★ 新增：覆盖配置开关状态
```

CI 日志里（不在手机日志里）：

```
== 注册应用图标（CFBundleAlternateIcons）==
[alt-icons applied 34 icon(s) to Spotify.app]
CFBundleAlternateIcons = { … }
```

### 12.3 「不该出现」清单（出现了就是没修好）

* 点开「创建」时的 `+2.5` **在取消之后没有回到全 `+10`**，或 `[Tree]` 里那一颗**一直停在 `@279,2`** → 复核没生效（v4.8 那个卡死病回来了）；
* 点开「创建」时那颗白圈**明显低于另外三颗**（照片 38 那种）→ v4.10 没生效；
* 任何 `missing ` / `⚠️` 的安装失败行；
* 阿拉伯语歌词仍**贴左** → RTL 没生效（顺手记下当时「更好的逐词歌词」是开还是关）；
* 界面上出现**裸键名**（如 `ngzhwm_amll_preferred`）→ l10n 没进包；
* `[REVERT_WATCH]` **一行都没有** → 新加的 init 日志没生效（那就还是拿不到"整库变黑"的判据）。

### 12.4 两个**老的"待验"项已经不存在**了（别再去找）

旧文档里还挂着两条"⏳ 待验"，实际都已在后续轮次**整块删除**：

* **听歌页 Music 式样品（`MusicStyleNowPlaying`）** —— 源文件已不存在（`SESSION_2026-10-01.md` §2.7 那节的⏳作废）；
* **听歌页自绘壳 / 玻璃顶栏 / 吸顶头让位**（`Appearance/NowPlayingShell.x.swift`，含 `StickyHeaderYieldHook`）
  —— 2026-10-02 **整块删除**，原因写在 `Tweak.x.swift:384-387`（bug 太多：糊底、两颗 ⌄、顶栏与吸顶头打架）。
  现在听歌页那套外观走的是 `AppleMusicLyricsOverlay` + `LyricsShellViews` 这条线。

→ 所以清单里**不需要**给这两条留位置。

### 12.5 这一轮**不建议**再塞新功能（说清理由）

本机没有 Swift 工具链 ⇒ 新代码能不能编译**只能靠 CI 发现**。现在这一版已经叠了 4 处改动
（v4.9 / AMLL 优先 / RTL / 应用图标接线），再加东西就是拿你这一轮编译去赌。
下一批候选（零取证、可合批）留到这一版绿了再上：
**「减少打扰」人话开关页**、**All flags 的 AUTO 档 + 文本输入**、
状态反馈小项（下载三态 / Add-to-library 与 Follow 变勾 / `?` 菜单）——
再往后是需要**四屏取证**的「视图类清理开关」，取证就靠上面第 11 步。

---

## 13. 2026-10-02 第八轮：**日志 30 判读** + v4.10（照片 38 的下偏）+「整库变黑」补判据

### 13.1 日志 30 判读（用户实测 + `eeveespotify_debug_shared 30.log`）

| 项目 | 证据 | 判定 |
|---|---|---|
| **v4.9 的复核真的会跑** | `[TabBarPlate] 这一行暂时不齐（多半是「创建」菜单开着）— 会在 ~0.5s 内自己复核…（v4.9）` | ✅ 机制成立 |
| **「创建」取消后不再上移** | 菜单开着那一刻报的是 `dy=[+10,+10,+10,+10] 基=图标·整行` | ✅ 上移治好（日志 29 的病根解除） |
| **但菜单开着时那一颗往下偏** | **照片 38**：白圈明显低于另外三颗（~7pt） | ❌ → **v4.10 修** |
| **「AMLL 优先」恢复后真的走 AMLL** | `[Lyrics] AMLL preferred — trying AMLL first, fallback target: Musixmatch` + `[AMLL] matched id=5998805469122509 … word-level coverage 64/65 — keeping words` + `mapped 65 line(s), translation=yes` | ✅ |
| **应用图标** | 用户："功能可用"（CI 里 `alt-icons` 那段是对的） | ✅ |
| 备份与重置 / 开源许可 / 已知 flag | 用户："没问题 / 没问题 / 有展示" | ✅ |
| **更新日志** | 接口限流：`[GitHub] ⚠️ … → HTTP 403（280 bytes）{"message":"API rate limit exceeded for 23.132.124.130…"}` | ✅ **功能正常**，只是没额度；顺带把 v4.8 的推断**坐实**了（280 字节 = 限流体） |
| 安装健康度 | 整份日志**没有** `missing` / `⚠️` 的失败行；2 条 `ORION ERROR` 都是 SponsorBlock（`enabled=N`，`addPlayerObserver:` 那个已知装不上） | ✅ |
| RTL 贴右 | 用户这轮没提 | ⏳ 待确认（阿拉伯语歌 ×2 截图） |

### 13.2 v4.10：把「创建」的**下偏**修掉（3 个文件）

**病根**：v4.9 为了根治"取消后上移"，把纵向位移改成"整行共用一个数（中位数）"——
于是菜单开着时那一颗**不再按自己的内容居中**，而它的 33pt 图标 + 40pt 白圆底仍按整行的 `+10` 摆，
圆心就落到胶囊中心**下方 ~7pt**（照片 38）。

**修法**：**回到"一颗一个数"**（v4.8 的 `iconShifts`），**上移那个老毛病交给 v4.9 的复核机制兜**：

| 状态 | 期望 | 由谁保证 |
|---|---|---|
| 菜单**开着** | 那一颗 `dy = +2.5`（白圈正落胶囊中心） | `iconShifts`（一颗一个数） |
| 菜单**关掉** | 回到全 `+10`，**不需要等布局回合** | `rowIsTransient` → 短促重试（0.2/0.5/1/2/3.5s）+ `DeclutterChrome` 的 0.5s 节拍，**自己直接调 `apply`** |

改动：`Appearance/TabBarGlass.x.swift`（`iconShifts` 回归、删掉 v4.9 的 `rowShift(from:)` 与
`iconPreferredShifts`、判据简化为 `hasDeviation(dy)`、文件头加 v4.10 段、`report` 文档同步）。

### 13.3 ★「整库变黑 / 听不了歌」：日志 30 **没有判据** —— 原因是诊断有个缺口，已补

**用户这轮的说法**："开启**覆盖配置**之后也没用"。
⚠️ 先把词对齐（`APPEARANCE` §12.3 已澄清）：这里的「覆盖配置」= **补丁页那个开关**
（`UserDefaults.overwriteConfiguration`，= 用随包的 Premium 配置快照**整体替换**服务端下发的那份），
**不是**「Flag 覆盖」（那两件事完全无关；日志 30 的 `flag overrides=0` 说的是后者，别混）。

**这次为什么判不出来**：`[REVERT_WATCH]` 在日志 30 里**一行都没有** ——
因为那条诊断只挂在 `setOriginalValues:` / `setOverrides:` 上，而**初始的 `initWithValuesDict:` 没打**。
一个"启动之后产品状态没再被改过"的会话，自然就是 0 行 ⇒ 无法区分
**H2（我们的 premium 伪装漏了）** 与 **H1/H3（服务端按会话地区 / 账号风控）**。

**这一轮补的两个口子**（都很小、零风险）：

| 文件 | 补了什么 |
|---|---|
| `EeveePremiumForce.x.swift` | `initWithValuesDict:` 也打 `passiveLogProductState("init", dict)` → **每份日志至少有一行 `[REVERT_WATCH][init] ads=… on-demand=… catalogue=… country=…`** |
| `Tweak.x.swift` | `[INIT]` 段新增 `patching: overwriteConfig=ON/OFF（…）` → **再也不会出现"不知道这个开关开没开"** |

**下次变黑时要你回答/提供**（这次日志里看不出来的）：

1. 那一刻**「覆盖配置」（补丁页）是开还是关**？（新日志会自动打出来）
2. **广告有没有回来 / Premium 徽章还在不在**？—— 这是 H2 与 H1/H3 的分水岭（§12.2 那张表）；
3. Spotify 设置里的**账号国家**与你当时的**网络出口**是否一致（H1）；
4. 重启 App / 重新登录 / 换网络，哪一步能让它恢复？
5. **变黑当场就导出日志**（别等恢复之后）—— 这样 `[REVERT_WATCH][init]` 与那一刻的产品状态才是黑的时候的值。

---

## 14. 2026-10-02 第九轮：**v4.11「预览歌词模块首帧不出现」的定量修复**（分档预算 + 结果备忘）

**根因定量**：用户按四档各测一遍（日志 34，同一首"全网没词"的歌），**耗时与"丢不丢模块"完全对应**：

| 档 | 首轮耗时 | 卡片 |
|---|---|---|
| ① 不回退 | **≤1 秒** | 在 |
| ② ＋Genius 回退 | 4 秒 | 开始丢 |
| ③ ＋AMLL 优先 | 6 秒 | 更差 |
| ④ 多级回退 | **13 秒** | 最差 |

⇒ NPV 的模块列表是**"组件加载完之后"**才建的，而卡片是这次响应喂出来的 → **响应晚于约 1~4 秒就赶不上**。
完整数据、逐档现场与三个新事实写在 `LYRICS_MODULE_NEXT_STEPS.md` **§20**，这里只留结论。

### 14.1 改了什么（3 个文件）

| 文件 | 改动 |
|---|---|
| **新增** `Sources/EeveeSpotify/Lyrics/LyricsResponseCache.swift` | 分档预算（首轮 **1.5s** / 后续 **18s**）+ **单条结果备忘**（曲目 id + 设置签名都对得上才复用）+ 占位不进备忘 + "第几次"按本轮播放计数 |
| `Sources/EeveeSpotify/DataLoaderServiceHooks.x.swift` | 歌词响应那段改成走上面这套：命中备忘 → **0 等待**直接交；否则按分档预算等，超时先交占位把卡片建出来；产出真结果时存备忘。禁用歌词那条路顺手 `reset()` |
| `Tools/eevee-hookfinder/LYRICS_MODULE_NEXT_STEPS.md` | 新增 §20（定量数据 + 验收 + 残留） |

**为什么是"单条备忘"而不是"按曲目缓存"**：① 覆盖真正要救的那条路（同一首的**立刻重请求** —— 日志 34 里 4/4 都会来）；
② **A→B→A 不命中** → 照旧走完整条链，逐词层/`currentLyricsDto` 那套状态都会更新，不会"卡片是新歌、我们的层是旧歌"；
③ 键里有 track id → **绝不串词**。

### 14.2 这一轮的验收（一次装机就能全测）

1. **无词歌 + 多级回退**（montagem）→ 卡片**必须出现**（写"未找到"），**不是**上一首的内容；
2. **有词歌 + 多级回退** → 卡片出现、内容正确、明显短于 13 秒；
3. **同一首来回切 3 次** → 第一次之后**秒开**；
4. **切歌后立刻看日志**：`[Lyrics] Request for /color-lyrics/v2/track/<id>` **有没有第二次**（验证"占位后会立刻重请求"）。

```
[DL] 取词超过 1.5s 预算（首次请求）— 先交占位把卡片建出来
[DL] lyrics from our memo — N bytes, 0 等待          ← 那次立刻重请求应当是这一行
```

### 14.3 本轮**没有**做的（下一批）

| 项 | 说明 |
|---|---|
| **预热**（切歌即取词） | 让首轮直接就是真词。挂点是 `SPTPlayerTrackHook.metadata()`，但它在**热路径**上（一次会话几百行）→ 必须按 track id 去重 + 节流，单独一轮做 |
| **削链**（A+B） | AMLL 那跳去掉 Genius 兜底；同一次请求 Genius 只查一次；多级回退 `for` 串行 → 并发（13s → ~5s） |
| **设置页提示** | "换了歌词来源，**已经听过的歌**要重启 App 才会重取" —— 原因是 Spotify 自己按曲目缓存我们交回去的 payload（服务端 `Cache-Control: public, max-age=3600`，我们没改头）。加文案要动 27 个 locale，单独一轮 |
| **effect 路线**（最高一档） | 若要连"Spotify 不再重请求"也兜住 → 找 `Lyrics_CardElementImpl.40ReloadLyricsWithTranslationEffectHandler` 那族的派发入口，需要**方法级转储**（多一轮取证） |

> ⚠️ 顺带更正第 8 轮（§13）里的一句话：当时说 whoeevee 上游"没有链所以快"只对了一半 ——
> 真正的原因是**那个年代的 Spotify 自己会先把预览歌词框画出来**（响应多慢都不丢模块），
> 所以它连 `semaphore.wait()` 都不带超时也没出事。9.1.88 改成"响应驱动创建"之后，
> 链长才第一次变成问题。
