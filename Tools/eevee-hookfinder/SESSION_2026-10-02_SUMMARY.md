# 2026-10-02 会话总结（**新入口**）

> 🆕 **2026-10-02 下半场（10:16→14:20，日志 29→34）已续写在 §9** ——
> v4.9 / v4.10 / v4.11、恢复「AMLL 优先」、RTL 贴右、应用图标接线、两条诊断日志，
> 以及**当前权威的"状态 / 下一步 / 规矩"**都在那一章。看现状请直接跳 §9。

> ⚠️ **2026-10-02 深夜又推进了一轮**：底部两条玻璃胶囊做到 v4.7.1（等宽、同高、修掉首帧盖不住）
> 并做完了第一批功能补齐（28 条 flag + 备份/重置 + 更新日志 + 许可）。
> **新会话请先读 [`SESSION_2026-10-02_HANDOFF.md`](SESSION_2026-10-02_HANDOFF.md)**，
> 本文件继续当"上一阶段的入口与设置页结构参考"。

> 这一份是**下一个会话先读的东西**。
> 细节流水在 [`SESSION_2026-10-02_APPEARANCE.md`](SESSION_2026-10-02_APPEARANCE.md)（§11–§19），
> flag 那条线在 [`FLAGS_9186_DESIGN.md`](FLAGS_9186_DESIGN.md)，
> "哪些功能已经过时/已删"在 [`STALE_AUDIT.md`](STALE_AUDIT.md)。

---

## 0. 三分钟现状

| 线 | 状态 |
|---|---|
| **底部标签栏玻璃** | ✅ **真机成立**（v4.6.1）：一条胶囊（312×**60**）、四颗收紧、**文字已藏**、**高度恒定**（点不点「创建」都是 60）、**每颗各自垂直居中**（正常三颗 `dy=+9.5`，开菜单时「创建」那颗 `dy=+2.5`）、边缘 0.75pt 描边高光。⚠️ **拖动已删**（用户报"不该滑动的栏在创建页里能被拖着走"）；按下回弹保留 |
| **迷你播放条玻璃**（v4.7.1） | 与标签栏那条**等宽（312）、同高（60）、同圆角、同材质**：迷你条自己的内容（398×56）**等比缩到 0.74** 塞进胶囊 ✓；清掉原封面色底（**Spotify 会写回 → 每次布局都再清**）、放开裁剪、**不吃点击**；两条之间留 **~4.5pt 间隙**（原来 6.5pt）。开关：扩展功能 → 迷你播放条（默认开） |
| **"更像系统"那条路** | ⏸ **用户明确要求先放一边**。三条路已探明（见 §4），其中"放真 UIKit 玻璃 bar"是唯一没试过的实验 |
| **听歌页那套外观** | ⛔ **2026-10-02 整块删除**（bug 太多：糊底、两颗 ⌄、与原生吸顶头打架）。之后重做 |
| **"整库变黑 / 听不了歌"** | 🔍 已定位到**配置/产品状态**层（开「覆盖配置」就好）。已把 `[REVERT_WATCH]` 写进导出日志，**等一次复现取证** |
| **「节省流量模式」自己打开** | ✅ 结论：**Spotify 自己的**（`ios-datasaver-automatic-impl`），我们没碰过；零代码关法已给（§5） |
| **过时功能清理** | ✅ 已删一大批（§1 第 8、9 条） |
| **flag 通道** | ✅ 已修并验证（日志 20 / 23 各 100+ 条 `[Flags]`） |
| **设置页** | 已瘦身：听歌页整节删除、外观开关只剩「标签栏」「音乐库」两节 |

---

## 1. 本会话干了什么（按时间顺序）

1. **读入口**：`eevee-hookfinder` 全部会话文档 + 日志 20 + `dump-9.1.86.txt` + 照片 21/22/23
   → 定位标签栏 v3 的两处错：**锚点差了 15pt**、**玻璃被 `TabBarCompactView` 压在下面**
2. **v4**：胶囊改锚"图标内容带"（不再按整条 83pt 栏）、插到图标 stack 之下 → 日志 23 验收 ✅
3. **v4.1**：修"首次进入那条 16pt 小棍"——`isUsable` 四道护栏（有窗口/非 null/非 inf/高≥20）+ 12×0.1s 有界重试
4. **v4.2**：四颗**收紧 20%**（用 transform，不碰布局）+ 玻璃改成"贴着图标那一行"（398×71 → ~320×60）
5. **v4.3**：**可拖动 + 弹簧弹回**（`UIPanGestureRecognizer`，不吃点击）+ `UIGlassEffect.isInteractive` 按下回弹
6. **v4.4**：修「创建 偏了」——改成**等分布局推算**（`stack.bounds.width × (i+0.5)/4`）+ 宽度闸，
   因为 `frame` 在 transform 非恒等时是**未定义**的（我上一版误以为它不受影响）
7. **v4.5**：**隐藏标签文字**（默认开，27 语言文案已补）+ 胶囊加 **0.75pt 白描边高光**（借 MeloX 旧系统兜底那一手）
8. **删功能**：AMOLED 深色栏底色 / 满屏取色背景 / 旧"样品"大标题 / Instagram 实验 / 老设置入口（9.1.0 专用）/
   `classes_910.txt`（0 字节）/ `class_comparison.md`（9.1.0 vs 9.1.6 时代）
9. **删功能（这一步）**：**听歌页整块外观代码** —— `Appearance/NowPlayingShell.x.swift` 整文件
   （自绘壳 / 玻璃顶栏 / 吸顶头让位 / 三处设置开关 / 三个 UserDefaults 键）
10. **诊断三件事**：变黑（配置层）、节省流量（Spotify 自带）、**选中判据**（`UILabel.textColor`：白=选中、灰=未选中）
11. **看别人的实现**：MeloX（= 系统 SwiftUI `TabView` 白送）、spoti.pw（只读 `.md`：系统玻璃 + 自己拼 + **Hide labels** + accent/repaint）、
    `TWIGalaxy.dylib`（**没有任何折射实现**，只是三个开关让 X 自己的玻璃生效）
12. **v4.6（用户报两条，当天就修）**：①「点『创建』玻璃被拉高」= 「创建」那颗选中时显示的
    40×40 白色圆底被 `contentBand` 当成内容 → 带子 24→40pt → 胶囊 **40→56pt**（日志 25 的
    `[Tree]` 从 `312,40` 变成 `320,56`；照片 29 逐像素量到 55pt、图标中心偏上 8pt）。
    ②「本该不可滑动的栏在创建页里能被拖着走」= v4.3 那套拖动（日志 25 里被拖到 y=-27）。
    修法见 [`SESSION_2026-10-02_APPEARANCE.md`](SESSION_2026-10-02_APPEARANCE.md) **§19**：
    量算只认图标/文字两类别（装饰天然不算）、**永远按"有文字"版式**、改读 `layer.position`/`bounds`、
    图标 `dy=+10.5` 垂直居中、**拖动整套删除**（`isInteractive` 按下回弹保留）。
13. **v4.6.1（用户装机后的照片 30/31/32 + 日志 26，当天修）**：v4.6 之后"点开『创建』，
    另外三颗图标被顶高 6pt"。真凶在日志 26 一份日志的两条自报里：
    `312x60 / 图标带 272x24 / dy=+10.0` ↔ `317x60 / 图标带 277x36 / dy=+3.8` ——
    「创建」那颗的 `SPTEncoreIconView` 在菜单打开时**会从 24×24 变成 33×33**
    （`[Tree] #7: IconView@35,7,33,33`），把一个共用的 `dy` 拽小了 6pt。
    修法见 **§20**：①尺寸**按中位归一化**（胶囊恒 312x60）；②纵向位移**一颗一个数**
    （每颗按自己"看得见的内容"对中心）。
14. **v4.7 迷你播放条玻璃（照片 33，当天做）**：用户要"迷你条也做成液态玻璃，高度、宽度
    和下面那条一样"。逐像素量出来：迷你条内容 **398×56**（左右各留 8）、两条之间 **6.5pt** 间隙、
    标签栏胶囊 312×60。**新增 `GlassCapsule.swift`（两条共用一个高度 = 60）+ `MiniBarGlass.swift`**；
    高度从此由共用常量给，两条不可能再漂。见 **§21**。
15. **v4.7.1（照片 34/35 + 日志 27，当天修）**：① **首帧盖不住** = Spotify 在我们清完之后
    **又把封面色写回来**（日志 27：16:50:19 清掉 → 16:50:20 树上又是 `bg=#64204C`）——
    v4.7 的"清一次就完事"是错的，现在**每次布局都清 + 写回计数**；
    ② 用户拍板**两条等宽（都 312）** → 迷你条内容**等比缩到 0.74**（transform，不动布局），
    玻璃搬到**宿主**里（不能再当内容的子视图，否则跟着缩），宽度取自标签栏那条的比例（换设备也等宽）；
    ③ 进度小条按用户选择**保持原样**（随内容一起缩到 ~284pt，仍在胶囊里）。见 **§22**。
16. **第一批"补功能"（2026-10-02，按 `SPOTIPW_GAP.md` §7 的估算开工）**：
    - **白捡组（本次的大头）**：拿到 spoti.pw **v0.23.0-beta 的 deb** 之后，在 9.1.86 的
      flag 表（`.spotify-ipa/flag-table.txt`，2485 条）里找到了 Spotify 自己的**"减少打扰"**
      模块 `ios-messaging-reduceinterventions-impl` —— **一条提示一个 flag**（账号切换 / AI 歌单 /
      演唱会通知 / 现场活动×2 / Puffin / 智能随机 / 探索提示 / 免费档 NPV 推销 / 整数档），
      加上 `ios-feature-nowplayingbar`（省流量提示、视频 tooltip、加号、设备键促销文案、
      队列角标、两行信息、播客跳过键……）、`ios-feature-canvas`、`ios-feature-cover-art-snake`
      等，**共 28 条**加进「已知 flag」目录的新分组（**推广与提示** / **界面元素与彩蛋**）——
      用户点一下就能关/开，**零新 hook、零取证**。
    - **All flags 补齐**：新增 `EeveePropertyModification.forceInt` + 「写入数字」档
      （`FlagOverride.Mode.number`）→ 整数 flag 从"只能看"变成"能改"（命中就覆盖、没有就追加）。
    - **备份与重置**（`SettingsBackup.swift` + 一页 UI）：只碰 `UserDefaults.ownedKeys`
      白名单（`.standard` 里同时躺着 **Spotify 自己的偏好**，全删是另一个按钮的语义）；
      导出成 JSON 文本走剪贴板（Spotify 沙箱不对 Files 开放，存文件用户拿不出来）。
    - **更新日志页**（`GitHubRelease` 补 `name`/`body`/`htmlUrl`/`publishedAt`/`prerelease`，
      **全部可选**，不影响版本检查）+ **开源许可页**（只写仓库里查得到的事实）。
    - 设置入口：扩展功能 → **设置与关于**（三行）。50 个新文案键 × 27 语言。

---

## 2. 接下来做什么（按优先级）

1. **一次装机验三批（v4.6.1 + v4.7.1 + 第一批功能）**，五件事流程在
   [`SESSION_2026-10-02_APPEARANCE.md`](SESSION_2026-10-02_APPEARANCE.md) **§19.5**，
   玻璃那两条的预期行在 **§20.3 / §22.3**，这一批新功能看下面：
   - workflow：`build-ipa-with-orion-patched.yml`，**`liquid_glass` 默认 true**，不要动 Flag 覆盖；
   - 设置：调试页开**日志记录 + 转储视图树**；扩展功能 → 标签栏两个开关都开、
     迷你播放条那个也开（都是默认值）；
   - 动作：**冷启动先别碰** → 放一首歌让迷你条出现 → 主页/搜索/音乐库 → 点「创建」→ 关掉 →
     回主页 → 最后去 **扩展功能** 里把三个新页面各点一遍（备份页点「复制到剪贴板」与「重新生成」即可，
     **先别点重置**）；
   - 发：`eeveespotify_debug_shared 28.log` + 四张截图（首帧的迷你条 / 两条同框 /
     点开创建时的底栏 / **已知 flag 的两个新分组**）；
   - 验收行：
     ```
     [MiniBarGlass] 胶囊 (51,-2 312x60) r=30.0 ← 迷你条内容 398x56 缩到 0.74（与标签栏**等宽** 312、同高 60…）
     [MiniBarGlass] 封面色底写回第 1 次 — 已再清掉（首帧盖不住就是这个原因）
     [TabBarPlate]  胶囊 (51,-3 312x60) … dy=[+9.5,+9.5,+9.5,+9.5] …
     [TabBarPlate]  胶囊 (51,-3 312x60) … dy=[+9.5,+9.5,+9.5,+2.5] …
     ```
     新功能的自检（点「已知 flag」里任一条 → 回日志看这一行）：
     ```
     [Flags] override ios-messaging-reduceinterventions-impl.enable_message_... — 0 match(es) (server did not send it; we append our own)
     ```
     —— **有这一行就说明通道是通的**（0 命中是预期的：这些 flag 服务端本来就不下发，
     我们会自己追加一条；真生效与否看界面上那条提示是否消失）。
2. **变黑取证**：复现时**别重启**，直接导出日志 → 看 `[REVERT_WATCH]` 里 `type/product/on-demand/streaming-rules` 有没有掉回免费档。
3. **（可选）选中胶囊**：判据已有，样式待用户定（推荐照片 25 那种"比胶囊亮一点的小圆底"）。
4. **（放一边）标签栏"更像系统"**：见 §4 三条路 + 一个实验。
5. **音乐库列表行**（圆角/发丝线）→ 再逐屏铺。

---

## 3. 要求与规矩（照做）

1. **spoti.pw 只看 `.md`**（`tweak/Sources/**`、`vendor/**` 一行不看），**思路可借鉴、代码自己写**（PolyForm Strict）；
2. **一次编译很贵** → 批量写、一轮验；
3. 每个 hook **自报日志**、开关**可撤销**、改动**幂等**、设置页**别臃肿**、**不做运行时类枚举**（`objc_getClassList` 崩过两次）；
4. 观感改造**只做"看着像"**，不追像素级；**别为了一个新 API 提高最低版本**；
5. 碰到"动别人视图"的诱惑时先问：**收益是什么？能不能只读判断 + 改一次？**
6. ★ **凡是要用户"编译 / 装机 / 发日志或照片"的，必须一次写清五件事**：
   ① 哪个 workflow、哪些构建开关；② 设置里开哪几个开关（写全路径）；③ 装完点哪些地方；
   ④ 发什么（日志名 + 截哪一屏）；⑤ **我到时候看哪几行日志**（把预期行先写出来）。
7. 改完 `.x.swift` **先跑本机三个检查器再推 CI**：
   `orion_hook_guard.py` / `swift_brace_check.py` / `swift_member_check.py`。

---

## 4. 「标签栏要更像照片 21/23/25」：三条路 + 一个实验（**本轮暂停**）

| 路 | 内容 | 判据 |
|---|---|---|
| ① **让 Spotify 自己展示** | ⛔ **已判死**：9.1.86 里 Reprise 相关 flag **只有两条**（`ios-reprise-liquid-glass-override.mode`、`…properties.context_menu_in_navigation_bar_enabled`），总开关**实测无效**；标签栏的底是 `TabBarCompactView` + 渐变，本来就没材质 | `FLAGS_9186_DESIGN.md` |
| ② **让系统替它展示**（= pw 的路） | 在 Spotify 那排标签后面放**一条真正的系统栏**（`UITabBar` / SwiftUI `TabView` 的 bar）→ 系统按"系统栏待遇"渲染（边缘折射/色散、选中胶囊、交互）。pw 的 `.md` 原话：**"UIKit's glass bar is 83 pt"** | 未试 |
| ③ **让标签栏进系统的"浮起栏"容器** | Spotify 的**首页顶栏**已经在里面（`_UIFloatingBarContainerView` → `FloatingBarHostingView<FloatingBarContainer>` → `HomeHeaderView`）—— 说明"系统给它画玻璃"在 Spotify 里**已经发生**，只是没给标签栏；但**没有这样的旗子**，自己挪进私有容器 = 红线 → **不做** | 记录思路 |
| ④ 顺手可做的**只读探针** | 挂 `TabBarRegularView`（IPA 里有、我们永远见不到的那个类），看它在什么条件下被实例化 —— 万一"另一种标签栏"自带玻璃，那是零风险的一手 | 未做 |

**另外两个已知事实**（省得再查）：
- **照片 23 那圈彩虹，很可能是"拍屏幕"的相机色散**；系统玻璃只在"高对比内容压在边缘"时泛一点点彩边。
- `UIGlassEffect` 对外只有 `style` / `isInteractive` / tint / 容器，**没有任何"折射强度/色散"参数**。

---

## 5. 「整库变黑」与「节省流量」（都不是标签栏那条线，但记在这）

**整库变黑 / 听不了歌**
- 用户观察：**开「覆盖配置」就好**、换代理也能好一时。补丁页那个开关做的是**用随包的 Premium 配置快照整体替换服务端下发的配置**
  （`DynamicPremium+ModifyingFunctions.swift:12-28`）⇒ **问题在"配置/产品状态"层**。
- 旁证：同文件第 787 行原话 `// audio-quality left unforced: Very High fails to stream on a free entitlement.`
- **取证口已加**：`[REVERT_WATCH]` 那一行现在同时进导出文件（原来只走 `NSLog`，导不出来）。
- 拿到日志后要判：`type/product/on-demand/unrestricted/player-license` 有没有掉回免费档；**广告有没有回来**。

**「节省流量模式」自己开启**
- 结论：**Spotify 自己的**功能（`ios-datasaver-automatic-impl` → `enabled`；全仓库 grep `datasaver` 一处都没有）。
- 它按网络状况（服务端 customize 体里有 `core-bitrate` / `net_fortune_*`）自行开启，走代理时容易被判定该省流。
- **零代码关法**：Flag 覆盖 → `enabled` @ `ios-datasaver-automatic-impl` = `false`（可选再写 `ios-feature-datasaver.enable_local_override` = true）。
- **要永久关**：在 `propertyReplacements` 加一行 `.forceBool(false)`（还没做，等用户点头）。

---

## 6. 已知坑（血泪，照抄别再踩）

| 坑 | 正确做法 |
|---|---|
| **`UIView.frame` 在 transform 非恒等时是"未定义"** | 实测会把我们写进去的位移算进去 → 算位置用**布局推算**（`stack.bounds.width × (i+0.5)/n`）或 `convert(_:to:)`；**v4.6 起量"内容带"一律改读 `layer.position` / `bounds`**（`position` 是布局位置，transform 绕 anchorPoint 施加、不动它）—— 见 `TabBarGlass.x.swift` 的 `contentBands` |
| **`UIView.animate` 的 `animations:` 是 escaping 闭包**，不继承 actor 隔离 | 里面调 `@MainActor` 函数要套 `onMainThreadSync`（否则编译错） |
| **KVC 碰未知 key 会抛异常（崩）** | 先 `responds(to:)` 探 getter + setter 再 `setValue(_:forKey:)` |
| **首次布局 `stack.bounds.width == 0`、`convert` 返回 `CGRectNull`** | 一切几何"**不可信就不画**" + 有界重试（`isUsable` / `scheduleRetry`） |
| **玻璃不能叠玻璃**（Apple 硬规矩） | 我们的玻璃要么独占那块区域，要么别做 |
| 系统玻璃的"全套待遇"只给**系统自己的栏** | 手搓 `UIVisualEffectView` 只有材质，没有系统栏那层 |
| **hook 方法上不写 `@MainActor`** | 方法体里用 `onMainThreadSync`（`LyricsChromeVisibility.swift:3-17` 有成文说明） |
| **沙箱内 pwsh 起不来（`0xC0000142`）** | 每条命令都要带 `sandbox_permissions: danger-full-access` 才跑得动（环境问题，不是命令错） |

---

## 7. 现在设置页长什么样（删完之后）

- **扩展功能**
  - 清爽：隐藏迷你播放条 / 隐藏逐字歌词行；首页与播放器：隐藏首页头部 / Connect 按钮 / AddTo 按钮
  - 双击手势：行为（跳歌/快进）、听歌页生效、全屏歌词生效
  - **标签栏**：「标签用液态玻璃」「隐藏标签文字」（都在这里，**默认都开**）
  - **音乐库**：「Apple Music 式头部」
  - 入口：隐私与上报 / 触感 / Flag 覆盖 / 屏蔽艺人 …
  - ⛔ 已删：深色栏底色、听歌页整节（自绘壳 / 自绘顶栏 / 顶栏玻璃 / 满屏取色背景 / 旧大标题）
- **补丁页**：不修补 Premium / **覆盖配置** / 真随机播放
- **调试页**：开启日志记录 / 转储视图树 / 转储 customize 响应体 …

---

## 8. 只在本会话出现过的工具/资产

| 资产 | 用途 |
|---|---|
| `Tools/eevee-hookfinder/audit_stale_targets.py` | **时点核对**：把仓库里所有 `targetName` / `NSClassFromString` 字面量拿到某个 IPA 里核对（`--ipa` 走字节级），Objective-C 目标也能查 |
| `Tools/eevee-hookfinder/inspect_tweak_deb.py` | **只读摊开一个 Theos tweak 的 `.deb`**（自己解析 ar 归档）：抽 `control`、plist、随包文档，以及**可见字符串**（`--strings`）——用来清点"对手有哪些功能"。**刻意不反汇编**（红线：只看思路、代码自己写），导出物用完即删、别提交 |
| `Tools/eevee-hookfinder/SPOTIPW_GAP.md` §5 | 拿到 **v0.23.0-beta 的 deb** 之后复核的缺口（新增：**Sing = 端上 AI 卡拉OK**、Custom navbar、App 图标选择器、设置导入导出、诊断三件；并把清理开关从 7 条纠正为 **25 条**） |
| `Tools/eevee-hookfinder/STALE_AUDIT.md` | 上面这份审计的结论 + 已删清单 |
| `[TabBarDump]` / `[TabBarSel]` | 一次性只读探针：标签栏结构 + "哪一颗被选中"的信号（**日志关着时连树都不走**） |
| `[TabBarPlate] …` | 玻璃胶囊自报：插在哪、摆在哪、**有文字带 / 图标带 / dy**、文字藏了几个（v4.6 起的行格式见 §19.2） |
| 照片逐像素量尺寸（PIL） | 没有 Mac、也拿不到真机读数时，**用 `PIL` 扫一列像素**就能把"胶囊多高、图标偏上几 pt"量出来（照片 29 就是这么定位的：白色描边 = 胶囊上下边，2px = 1pt） |

---

# 9. 下半场（10:16 → 14:20，日志 29 → 34）：外观收尾 + 歌词模块线

> ⚠️ **本章是当前权威入口**：状态、下一步、规矩以这里为准；§0–§8 是上半场（08:51 之前）。
> 细节流水：外观 → [`SESSION_2026-10-02_APPEARANCE.md`](SESSION_2026-10-02_APPEARANCE.md)（§23–§25）；
> 歌词 → [`LYRICS_MODULE_NEXT_STEPS.md`](LYRICS_MODULE_NEXT_STEPS.md)（§20）；
> 交接 → [`SESSION_2026-10-02_HANDOFF.md`](SESSION_2026-10-02_HANDOFF.md)（§12–§14）。

## 9.1 干了什么（按轮次，7 项）

| 轮 | 交付 | 文件 | 状态 |
|---|---|---|---|
| **v4.9** | 「创建」取消后**上移 8pt**（日志 29 的真机病：那一颗 `ElementContentView@279,2` 卡了 16 秒）→ 改成"整行共用一个位移"+ **复核机制**（短促重试 0.2/0.5/1/2/3.5s + `DeclutterChrome` 的 0.5s 节拍，**不等布局回合**） | `Appearance/TabBarGlass.x.swift`、`Appearance/DeclutterChrome.x.swift` | 日志 30 验收：**上移好了**（`[Tree]` 不再卡 2）；代价 = 菜单开着时那颗**往下偏 ~7pt**（照片 38）→ 见 v4.10 |
| **v4.10** | 照片 38 的**下偏**：回到"一颗一个数"（v4.8 的 `iconShifts`）+ 保留 v4.9 复核；删掉 v4.9 的 `rowShift(from:)` / `iconPreferredShifts` | `Appearance/TabBarGlass.x.swift` | ⏳ **未验**（要再点一次「创建」：开着时 `dy=+2.5` 是对的，**取消后必须回到全 `+10`**） |
| **恢复「AMLL 优先」** | 把历史里那整块 `if amllPreferred {}` 搬回（原 `durationMs` 参数已删 → 按 `makeLyrics(from:source:)` 改写）+ 设置页开关 + 2 条 l10n（**只加在 en / zh-CN**，因为这两条历史上只存在这两处） | `Lyrics/CustomLyrics.x.swift`、`Settings/ngzhwm/ngzhwmSettingsViewModel.swift`、`Settings/Sections/Lyrics/**`（3 个）、en/zh-CN `Localizable.strings` | ✅ 日志 30/31 验收：`AMLL preferred — trying AMLL first` → `AMLL succeeded (65 line(s))` |
| **RTL 贴右** | 新增 `String.prefersRightToLeftLayout`（UAX#9 P2/P3 首强字符；故意跳过数字/标点/emoji，并排除阿拉伯数字）；AM 页按**每行内容**给 `\.layoutDirection`；逐词层 3 处 `textAlignment = .left` → `.natural` | `Shared/Models/Extensions/String+ScriptDirection.swift`（**新增**）、`Lyrics/AppleMusic/AppleMusicLyricsPage.swift`、`Lyrics/LyricsWordByWord.x.swift` | ⏳ **未验**（要一首**有逐词数据**的阿拉伯语歌 + 两张截图：开关开/关） |
| **应用图标接线** | 两个 IPA workflow 在**打包前**调 `Tools/alt-icons.sh`，并打印 `CFBundleAlternateIcons`（失败只 `::warning::` 不中断） | `.github/workflows/build-ipa-with-orion.yml`、`...-patched.yml` | ✅ 用户实测「**功能可用**」 |
| **诊断补口** | `[REVERT_WATCH][init] …`（初始字典也打 —— 原先只挂在 setOriginal/setOverrides 上，导致"整库变黑"的会话 0 行、判不出来）+ `[INIT] patching: overwriteConfig=ON/OFF` | `EeveePremiumForce.x.swift`、`Tweak.x.swift` | ✅ 日志 31 验收：两行都出来了（当时 `overwriteConfig=ON`、产品状态**满档 premium**、`subscription-enddate=2027-10-02`） |
| **v4.11** | 歌词模块**首帧丢失**：**分档预算**（首轮 **1.5s** / 后续 **18s**）+ **单条结果备忘**（曲目 id + 设置签名都对得上才复用）+"第几次"按**本轮播放**计数 + 占位不进备忘 | `Lyrics/LyricsResponseCache.swift`（**新增**）、`DataLoaderServiceHooks.x.swift` | ⏳ **未验**（本轮改动，验收见 §9.3-2） |

## 9.2 这一场"原来如此"（三个硬事实，都由真机日志钉死）

1. **窗口只有 1~4 秒**：NPV 的模块列表是**"组件加载完之后"**才建的
   （`…nowPlayingScrollViewModelWithDidLoadComponentsFor…`），而那张预览歌词卡片就是**这次响应**喂出来的。
   日志 34 四档实测（同一首"全网没词"的歌）：不回退 **≤1s → 卡片在**；＋Genius 回退 4s → 开始丢；
   ＋AMLL 优先 6s → 更差；多级回退（4 源串行）**13s → 最差**。⇒ "退出重进就好" = 让列表重建一次。
2. **Spotify 自己按曲目缓存我们交回去的 payload**（服务端响应头 `Cache-Control: public, max-age=3600`，
   而我们是**伪装成那次响应**交回去的、**没改任何缓存头**）⇒ 用户实测"**改了来源，回到听过的歌还是旧来源、
   而且秒加载**"——**这不是 bug，是它的缓存**，我们清不掉，只能重启 App（**该写进设置页提示**）。
   反证：日志 34 那首没词的歌，**四次重启每次都把整条链重跑一遍**（空 payload 不会被留下）。
3. **"座位"是我们自己注入的**：四档里每次都出现
   `[Scrollsita] … body=368B has5=false` → `injected lyrics-card element — 368B -> 453B`
   ⇒ 服务端**没给**这首歌放卡片元素（它知道没词），是我们补的。**丢的不是座位，是"人没赶上"。**
   另外两条只有读代码才知道的：`getLyricsDataForCurrentTrack` 开头有**最多 3 秒**"等播放器元数据跟上"的循环；
   而**超出预算交占位 ≠ 丢词** —— 后台那条链会继续跑完并把 dto 写进 `currentLyricsDto`（逐词层/自绘页照常可用）。

> ⚠️ **顺带更正上一轮的判断**：whoeevee 上游"没有链所以快"**只对了一半** —— 真正原因是
> **那个年代的 Spotify 自己会先把预览歌词框画出来**（响应多慢都不丢模块），所以它连
> `semaphore.wait()` 不带超时都没出事。9.1.88 改成"响应驱动创建"之后，**链长才第一次变成问题**。
> （上游仓库已在本地：`C:\Users\ngzhwm\Documents\GitHub\EeveeSpotifyReborn`，v6.2.2，最后一条提交是
> `discontinuation notice` —— 已停更，**只借它的"快"，别退回它的架构**。）

## 9.3 接下来做什么（按优先级）

**① 用户侧补验（不用重新编译，欠着的）**
| 项 | 怎么做 |
|---|---|
| v4.10 的「创建」 | 点开「创建」→ 等 2 秒 → 取消 → 再等 2 秒。判据：开着时 `dy=[+10,+10,+10,+2.5] 基=图标`、`[Tree]` 那颗 `@279,2` **都是对的**；**取消后必须回到全 `+10` 与 `@279,10`** |
| **四屏取证** | 调试里打开「**转储视图树**」（日志 31 里它是 `[Tree] off`），再去 搜索 / 歌单 / 播放 / 首页 各停 2 秒 → 下一批"页面级清理开关"靠它 |
| RTL | 一首**有逐词**的阿拉伯语歌，全屏歌词页两张截图（「更好的逐词歌词」开/关） |

**② v4.11 的四条实验（本轮改动的验收）**
1. 无词歌 + 多级回退（montagem）→ 卡片**必须出现**（写"未找到"），**不是**上一首的内容；
2. 有词歌 + 多级回退 → 卡片出现、内容对、明显短于 13 秒；
3. 同一首来回切 3 次 → 第一次之后**秒开**；
4. 切歌后立刻看日志里 `[Lyrics] Request for /color-lyrics/v2/track/<id>` **有没有第二次**。
   该看到的新行：`[DL] 取词超过 1.5s 预算（首次请求）— 先交占位把卡片建出来` /
   `[DL] lyrics from our memo — N bytes, 0 等待`。

**③ 代码线（都零取证或已取证）**
| 优先 | 项 | 说明 |
|---|---|---|
| ★ | **预热** | 切歌即取词 → 首轮直接给真词（正反馈：成功一次就进 Spotify 那份缓存，之后永远秒开）。挂点 `SPTPlayerTrackHook.metadata()`，但它在**热路径**上 → 必须按 track id 去重 + 节流，**单独一轮** |
| ★ | **削链 A+B** | AMLL 那跳去掉 Genius 兜底（省 ~3s）；同一次请求 Genius **只查一次**；多级回退的 `for` 串行 → **真并发**（13s → ~5s） |
| | **设置页提示** | "换了歌词来源，**已听过的歌**要重启 App 才会重取" → 要动 **27 个 locale**，单独一轮 |
| | **effect 路线**（最高一档） | 要连"Spotify 不再重请求"也兜住 → 找 `Lyrics_CardElementImpl.40ReloadLyricsWithTranslationEffectHandler` 那族的派发入口，需要**方法级转储**（多一轮取证；现有 `dump-9.1.88.txt` 是**纯类名**，0 条方法） |
| | **页面级清理 8~10 条** | 复用 `DeclutterChrome` 的可撤销隐藏 + 复查；**等四屏 dump** |
| | 状态反馈小项 / 两个探针 | 下载三态 / Add-to-library 与 Follow 变勾 / `?` 菜单 / 队列角标；Sleep timer、变速（`playbackSpeed` 已能读） |
| | 顺手三个小缺陷 | ① LRCLIB 84 字节响应触发 `DecodingError: keyNotFound 'instrumental'` → 该按"未找到"处理；② Musixmatch 首轮打满 5s 超时（它 7 秒后才回，第二轮 1s 就有）；③ Genius 在"AMLL 优先"下被查两次 |

**④ 明确不做**：整套 10 屏自绘（我们已经在 Spotify 自己的新设计语言上，收益被稀释、成本 15~30 轮；要做只做**1 屏样品**）；
morph 转场（要 hook 私有转场类）；Tab 拖动排序（撞"不动别人布局"红线）；手动重建 Spotify 的私有模块列表。

## 9.4 要求与规矩（本会话新增 / 强化）

**工程纪律**
* **编译只能走 CI**（本机**没有 Swift 工具链**）⇒ 一轮编译很贵：**批量写、一次验**；新代码的编译风险只能靠 CI 兜。
* 改完**必跑四条自检**（全过才算完）：
  ```
  python Tools/eevee-hookfinder/orion_hook_guard.py      # 317 文件
  python Tools/eevee-hookfinder/swift_brace_check.py     # 317
  python Tools/eevee-hookfinder/swift_member_check.py    # 262
  python Tools/l10n_lint.py --locale en  --quiet
  python Tools/l10n_lint.py --locale zh-CN --quiet
  ```
  新增 `.swift` 会被编译（`Makefile`：`find Sources/EeveeSpotify -name '*.swift'`，`.x.swift` 只是命名惯例）。
* **文档即交付**：每轮都要把「结论 + 证据 + 判据」写进 `Tools/eevee-hookfinder/**`，否则下个会话只能重推。
* **验收清单用"五件事"格式**：① workflow/开关 ② 设置里开哪几个 ③ 按顺序点哪些（含"等几秒"）
  ④ 发什么（日志 + 截图）⑤ 我看哪几行（预期行 + **"不该出现"清单**）。
* **证据驱动**：真机 `[Tree]`/日志是唯一仲裁者；自己的推测要标明"推断"，别写成结论（本会话就靠这条纠正过两次判断）。
* **红线**：不动别人的布局（只做 transform/dy 之类的写入）；不新增没证据的 hook（Orion 注册期解析不到会 **SIGTRAP** 崩注入工具）；
  不碰 Spotify 私有转场/私有列表重建；`spoti.pw` 是 PolyForm **只读它的 .md**，**绝不读它的代码**。

**本机操作要点（容易踩，照抄）**
* `pwsh` 工具**必须**带 `sandbox_permissions: "danger-full-access"`，否则 exit `3221225794`（STATUS_DLL_INIT_FAILED）。
* 只读文件策略下 `write`/`edit` 会被拒 → **用同一个操作**重试并带 `sandbox_permissions: "workspace-write"` + 中文理由。
* 控制台是 **GBK**：中文报告**写进 UTF-8 文件再用 read 读**，别指望 stdout；`Python` 可用，**没有 `bash`**（`bash -n` 不可用，WSL 没装发行版）。
* 只读分析脚本用完**即删**（`%TEMP%`），别提交。
* 素材路径：日志 `C:\dsh\ipa\eeveespotify_debug_shared <N>.log`；照片 `C:\dsh\else\<N>.jpg`；
  类名转储 `C:\dsh\ipa\dump-9.1.88.txt`（**只有类名**，17047 条）。日志时间戳是**秒级**（算耗时只能到秒）。

## 9.5 本会话新增的资产

| 资产 | 用途 |
|---|---|
| `Sources/EeveeSpotify/Lyrics/LyricsResponseCache.swift` | 歌词响应**分档预算 + 单条结果备忘**（v4.11）；注释里写着四档实测数据与"为什么不做按曲目缓存" |
| `Sources/EeveeSpotify/Shared/Models/Extensions/String+ScriptDirection.swift` | `String.prefersRightToLeftLayout`（UAX#9 P2/P3 首强字符）——RTL 贴边用 |
| `[DL] lyrics from our memo — N bytes, 0 等待` / `[DL] 取词超过 …s 预算（首次/后续请求）` | v4.11 的两条新日志：一眼看出"这次是缓存命中还是占位" |
| `[REVERT_WATCH][init] …` / `[INIT] patching: overwriteConfig=…` | "整库变黑"的判据（H2 vs H1/H3）+ 覆盖配置开关状态 |
| `Tools/alt-icons.sh`（已有）+ 两个 workflow 的调用 | 应用图标注册（`CFBundleAlternateIcons`），打包前跑、失败只告警 |

## 9.6 工作区状态（写完本章时）

未提交：`DataLoaderServiceHooks.x.swift`（v4.11）、**新增** `Lyrics/LyricsResponseCache.swift`、
`LYRICS_MODULE_NEXT_STEPS.md`（§20）、`SESSION_2026-10-02_HANDOFF.md`（§13/§14）、`SPOTIPW_GAP.md`（纠偏一条）、
`SESSION_2026-10-02_SUMMARY.md`（本章）。已提交并编译过的：`9be72fb`(v4.9) / `464f031` / `fa0bbe7`(AMLL+RTL+图标) / `704f92c`(v4.10+诊断)。
**提交后走同一个 workflow 编译**，然后按 §9.3-① ② 验。

---

## 9.7 2026-10-03 追加：**v4.11 没生效的真实原因** + 「无法播放」结论 + 视图树交付

> 完整版在 [`SESSION_2026-10-02_HANDOFF.md`](SESSION_2026-10-02_HANDOFF.md) **§15**（先读那一节）。三句话：

1. **v4.11 只写在 `SPTDataLoaderService` 那条路上**，而真机日志 28→35 **每一份都是 `[DL]` 0 行**（走的是 `HttpClientURLSession`）⇒
   分档预算/结果备忘**一次都没执行**；且用户测的构建（`704f92c`，12:13）**早于** v4.11 的提交（14:19）。
   → 本轮 **v4.11.1**：两条路共用 `LyricsResponseCache`（新增 `BudgetPlan` / `Outcome` 与统一结果行）。
2. **「突然无法播放任何歌曲」在 31 份日志里零证据**；而且此前"开覆盖配置就好 ⇒ H2"的结论**站不住** ——
   `[REVERT_WATCH][init]` 的 `subscription-enddate` 是**我们自己**写的 `now+1年`，那行分不开 H2 与 H1/H3。
   上游 `common_issues.md:60-68` 把**地区**列为第一顺位，并明确"别先开覆盖配置"（它现在**是开着的**）。
3. **视图树在日志 35 里**（36 份：首页 18 + 播放页 13 + 各 1~2），已清点成
   `.spotify-ipa/view-inventory-35.txt`；**还缺搜索/歌单两屏**（转储器配额被前两屏吃掉），下一份日志顺手抓。

