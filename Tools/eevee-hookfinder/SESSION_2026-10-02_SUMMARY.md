# 2026-10-02 会话总结（**新入口**）

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
