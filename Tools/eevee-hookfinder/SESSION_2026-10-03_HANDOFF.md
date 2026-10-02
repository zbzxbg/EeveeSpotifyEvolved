# 交接：2026-10-03 会话（歌词线收口 + 减少打扰页 + 听歌页取色底）

> **新会话先读这一份**，然后按 §4 的"待验收"清单往下做。
> 上一份入口是 [`SESSION_2026-10-02_HANDOFF.md`](SESSION_2026-10-02_HANDOFF.md)（它自己又指向
> `SESSION_2026-10-02_SUMMARY.md` 的 §9）。**本文件不重复它的内容**，只写"那一份之后发生的事"。
>
> 写作时状态：**HEAD = `b14d6b9`**，工作区干净。
> ⚠️ 这一轮的所有改动**都还没在真机上验收过**（日志 37 是旧构建），见 §4。

---

## 0. 三十秒现状

| 线 | 状态 |
|---|---|
| **歌词：v4.11 的 1.5s 预算** | ❌ **已撤销**（`19192df`）。日志 36 证明它每次都在 1.6s 交出 62 字节占位、把卡片**锁死**在"未找到歌词"，真词 3 秒后到手也刷不进去 |
| **歌词：两条传输层** | ✅ 分档预算/结果备忘**对齐到 `HttpClientURLSession`**（`4e756f1`，用户提交；`ca3e080` 修了其中的编译错）。此前只有 `SPTDataLoaderService` 那条路有，而真机日志 28→35 **`[DL]` 全零、`[HCUS]` 有值** ⇒ 修的东西从没执行过 |
| **歌词：AMLL 优先的回退链** | ✅ **按用户设置**（`196119f`）：现在是 `AMLL → 用户源 → Genius`。以前是 `AMLL → Genius(自带兜底) → 用户源 → Genius`（用户指出、日志 36 t2 坐实，15s 里白花一跳） |
| **歌词：响应耗时** | ✅ 有判据了：`[HCUS]/[DL] lyrics 交付给 Spotify — N bytes（请求起算 X.Xs）` + `[Lyrics] chain: …` |
| **「减少打扰」页** | ✅ 新页（`0c5e3ff` + `c7db3a5`）：**8 个小开关 + 1 个总开关**，写 flag 覆盖、可撤销、需重启生效 |
| **听歌页取色底（仿 AM）** | ⚠️ 写完但**从未生效过**（`a2360c0` → `b14d6b9` 修了"挂在恒 nil 全局上"）。等下次日志的 `[NPVStyle]` 行 |
| **"突然无法播放任何歌曲"** | ❌ **仍然零判据**。用户澄清"开覆盖配置也不行" ⇒ **旧结论 H2 被排除**（见 §2.3），指向服务端地区/账号（H1/H3） |
| **CI** | ✅ `tests.yml` 补齐到 **8 条**（原先只跑 3 条，其余 5 条只有手动 builddeb 会跑）。已确认全绿 |
| **仓库策略** | ✅ README 新增「Reverse-engineered data, and takedowns」；`.gitignore` 收口 `.spotify-ipa/`（`f36f42c`） |

---

## 1. 这一会话干了什么（按轮次，全部是提交，工作区已清）

| # | 提交 | 做了什么 | 关键证据 |
|---|---|---|---|
| 1 | `19192df` | **撤销 v4.11 的 1.5s 预算**（`firstAttemptBudget` 1.5 → 18），200 分支不再交占位、改为放行 Spotify 原始响应 | 日志 36 铁证链（§2.1） |
| 2 | `196119f` | **AMLL 优先的回退链按设置走**：AMLL 那一跳传 `allowGeniusFallback: false`；新增 `[Lyrics] chain: …` 一行 | 用户指出 + 日志 36 t2 |
| 3 | `e4aad34` | **CI `tests.yml` 补齐 5 条**（DebugLogRedaction / BrowsitaSectionStripper / ServerSidedFeaturePolicy / BundledConfigurationPolicy / Python 快照）；与 builddeb 里逐字一致 | 该 workflow 是**唯一 push 自动跑**的检查 |
| 4 | `311d88f` | 修「减少打扰」页两处**编译错**（`flag.id` 不存在 / 类型检查超时）；**顺手给 `swift_member_check.py` 加"变量.成员"规则** | CI 报错；新规则已两向验证（假错抓得住、真代码 0 误报） |
| 5 | `0c5e3ff` | **新增「减少打扰」页**（总闸 + 7 行），把 `ios-messaging-reduceinterventions-impl` 那批 flag 变成人话开关；新增键名核对工具 | 用户"先做 A" |
| 6 | `c7db3a5` | **第二批 6 行**（Connect / 睡眠定时器 / 设备提示 / 音乐库 ×3）；两处**白名单**防止"目录新增条目自动上屏成裸键名" | 核对脚本先报出会渲染 6 条无文案的 flag |
| 7 | `a2360c0` | **听歌页取色底**（kumone 配方）+ 常量表 `NowPlayingMetrics.swift` + `KUMONE_REFERENCE.md` + 许可页署名 | 见 §3 |
| 8 | `5b78556` | 修编译错（重构漏改的 `toggle` 调用点）+ 真加**径向白光晕** + 放宽"满页着色层"判据 | CI 报错 + 自查 |
| 9 | `f36f42c` | README 增「逆向产物与下架」一节；`.gitignore` 收口 `.spotify-ipa/` | 用户问 DMCA 风险 |
| 10 | `b14d6b9` | 修**取色底从未执行**：不再依赖恒为 nil 的全局，改传 `target`；补 `viewDidAppear` 第二次机会；每处提前返回都带原因日志 | 日志 36/37 里 `[NPVStyle]` **零行** |

---

## 2. 这一会话学到的硬事实（都带证据，别再重推）

### 2.1 ★ 占位 payload 是**毒丸**，不是"卡片保险"（日志 36，曲目 `Starboy`）

```
07:43:27  服务端 200 + 1712B 官方歌词；我们开始取词（AMLL 起跑）
07:43:29  ★ 1.6s 到点 → 交 62 字节占位（"未找到歌词"）
07:43:30  服务端下发**已含歌词卡片元素**（has5=true）   ← 座位是服务端给的，不用我们抢
07:43:31  卡片建出来 → 高 98pt（正常 320pt）
07:43:32  ★ 真词到手（AMLL 65 行 / 逐词 64）→ **卡片里还是那句占位**
之后      该曲**再无任何一次** /color-lyrics 请求（t2 的第二次在 15 秒后）
```
⇒ 教训：**"先交个占位保住卡片"这条路是错的** —— 占位会被按曲目固化，真结果随后到达也刷不进去。
用户原话"第一次不显示、退出重进才行"就是它。

### 2.2 ★ 两条传输层是**分别实现**的，日志前缀决定修哪一条

| 前缀 | 文件 | 真机情况 |
|---|---|---|
| `[DL]` | `DataLoaderServiceHooks.x.swift`（`SPTDataLoaderService`） | 日志 28→35 **零行** |
| `[HCUS]` | `HttpClientURLSessionHooks.x.swift`（`Connectivity_HttpClientKit.HttpClientURLSession`） | **每份日志都有** |

⇒ 这台设备上歌词走 **HCUS**。**改歌词交付逻辑时必须两条路都改**，否则等于没改（v4.11 就是这么白费的）。

### 2.3 ★「突然无法播放任何歌曲」：H2 被排除，且至今零现场

* 用户澄清：**开着「覆盖配置」也不行** ⇒ 旧结论"开覆盖配置就好 ⇒ 我们的配置层（H2）"**作废**；
  剩下 **H1（服务端按会话地区判可播放性）** / **H3（账号风控）**。
* 上游 `common_issues.md:60-68` 早把这句话的症状写成 **Region Issue**，并明确
  **"Do not enable Overwrite Configuration unless you've also tried the region fix."**
* `[REVERT_WATCH][init]` 那行**不能**当 H2 的铁证：`subscription-enddate` 是**我们自己**写的
  `now+1 年`（`EeveePremiumForce.x.swift:45`）；唯一能分的 `country=` 至今**打不出来**。
* **31 份日志里这个症状一次现场都没有**（`drm|widevine|license|unplayable|restricted` 全零命中）。
  ⇒ 下一轮最该补的就是**只读播放器状态探针**（§5 第 2 条）。

### 2.4 ★ 我（上一轮）在同一个 scope 里漏看了 6 条别的 scope 的 flag

`KnownFlagCatalog` 的 `flag_group_interventions` 组里混着 `ios-feature-nowplayingbar.*` /
`ios-datasaver-automatic-impl.messaging_enabled` / `ios-feature-search.concerts_enabled` 等 6 条。
"渲染整组"会把它们自动带上屏并**显示裸键名**。现在两处都是**显式白名单**，
由 `check_reduce_interventions_l10n.py` 兜底（它会列出"这一页会拼出来的每个键"）。

---

## 3. 听歌页取色底（仿 AM）：借鉴来源与"为什么不模糊"

* 配方来自本地 checkout `C:\Users\ngzhwm\Documents\GitHub\kumone`
  （**独立**网易云客户端，`LICENSE` = **LGPL-3.0**、`COPYING` = **GPL-3.0** ⇒ 与本仓库 GPL-3.0 兼容）。
  **完整清单见 [`KUMONE_REFERENCE.md`](KUMONE_REFERENCE.md)**（借了什么/不借什么/常量表/真机树依据）。
* 三层（`NowPlayingView.swift:185-202`）：**取色对角渐变 + 左上 12% 径向白光 + 底部压黑 35%**，
  换歌 `easeInOut(0.8)` 交叉淡入。
* ★ **关键：那不是模糊封面**。本仓库 2026-10-02 的"自绘壳"就是**加模糊盖在内容上**才糊底被删
  （`Tweak.x.swift:384-387`）；取色渐变是**在底层铺颜色**，机理相反。
* 落地方式：真机树里播放页**本来就有**一层"整页、底色 = 封面取色"的视图
  （`7.UIView@0,0,414,896,bg=#E84838` → 换歌变 `#4890E0`/`#302838`）。
  我们**接管它**（记原色 → 清空 → 塞自己的渐变层），关开关写回 ⇒ 可完全还原。
* 开关：**扩展功能 → 听歌页 → 整页封面取色底**（默认开）。日志 tag：`[NPVStyle]`。

---

## 4. ★ 待验收（**一份日志能验完**）

> 目标提交：**`b14d6b9`**（当前 HEAD）。
> 构建：`.github/workflows/build-ipa-with-orion-patched.yml`（`liquid_glass` 默认开）。
> 设置：调试 → 「**启用日志记录**」开；「转储视图树」这次**不用**开（省配额）。

### 4.1 五件事

**① 怎么装**：上面那个 workflow，`liquid_glass` 默认开，其余不动。
**② 设置里开哪几个**：只要「启用日志记录」。歌词设置**保持现状**（当前是 PetitLyrics + Genius 回退关，
`overwriteConfig=OFF`，够了）。
**③ 装完按顺序点**：
1. 放一首**有封面**的歌 → 进**听歌页** → **截图**（看整页底色是否跟着封面变）
2. **切下一首** → **再截一张**（颜色应 0.8s 淡入着换，且前一首的色不该留着）
3. 扩展功能 →「**听歌页**」→ 把「整页封面取色底」**关掉** → 回听歌页 → **截一张**（应完全恢复原样）
4. 扩展功能 →「**减少打扰**」→ **截一张**（应为：1 总开关 + 8 个小开关，**没有裸键名**）
5. 随便开**一条**（别点总闸）→ **重启 Spotify** → 看那处提示是否消失

**④ 发什么**：4 张截图 + `eeveespotify_debug_shared 38.log`（导出后改名）
**⑤ 我看哪几行**：

```
[NPVStyle] backdrop (414x896) ← 封面取色 FFE84838，接管 N 层（…左上 12% 白光…）
[NPVStyle] 拿不到听歌页 VC（全局为空且调用方没传）— 本次不施加
[NPVStyle] 听歌页 view 还没尺寸（…）— 本次不施加
[NPVStyle] 这次没拿到封面取色（track=ok/nil）— 保留 Spotify 原始底
[NPVStyle] no full-page coloured sibling found under … — backdrop skipped
[NPVStyle] backdrop removed (N 层已还原，reason=switch off)
[Lyrics] chain: AMLL → PetitLyrics → Genius（仅当用户源也失败）   ← 这条链本身也要验（196119f）
[HCUS] lyrics 交付给 Spotify — N bytes（请求起算 X.Xs）           ← N 应是几千（真词），不是 62
[Flags] replacement <你开的那条> — N match(es)
[Flags] user overrides in effect: N
```

**通过判据**：
1. `[NPVStyle]` **至少有一行**（上一次零行 = 代码没跑到，见 §1 #10）；若是那行 `backdrop … 接管 N 层`，
   再看截图是否真有底色变化；
2. 关掉开关那张截图与"没这个功能"时**看不出差别**，且日志有 `backdrop removed`；
3. 减少打扰页**没有裸键名**，开的那条在日志里有 `replacement … N match(es)`；
4. 歌词：出现 `chain: AMLL → PetitLyrics → Genius（…）`，且**不再**出现
   `AMLL failed — falling back to Genius`（那是被去掉的多余一跳）。

### 4.2 「不该出现」清单

* `[NPVStyle]` **零行** ⇒ hook 没跑到（去查 `viewWillAppear` 在这页上是否真被调用）；
* 关开关后底色**没还原** ⇒ `remove()` 没跑到（看有没有 `backdrop removed`）；
* 减少打扰页出现**裸键名**（`reduce_interventions_*` 字面） ⇒ 词典漏了键（跑核对脚本）；
* `AMLL failed — falling back to Genius` 又出现 ⇒ 回退链改动没生效；
* 卡片永远停在"未找到歌词" ⇒ 取词链仍然超时，看 `交付给 Spotify` 那行的耗时。

---

## 5. 接下来做什么（按优先级）

| # | 做什么 | 为什么排这个位置 | 量 |
|---|---|---|---|
| **1** | **先把 §4 那一次验收做完** | 三件事（取色底 / 减少打扰 / 回退链）全是"写完了但没验"，验完才知道下一步该修哪个 | 一次装机 |
| **2** | **只读播放器状态探针 + `country=`** | "无法播放任何歌曲"**至今零判据**：加一行 `[PLAYER] state=playing/paused position=/duration=`（只在变化时打），并把 `[REVERT_WATCH]` 补上账号国家 ⇒ 下次现场就能定 H1 还是 H3 | 1 轮 |
| **3** | 歌词列**上下渐隐 + 拖动暂停**（kumone `NowPlayingView.swift:913-923`） | 观感提升明显、风险低（只动我们自己的层） | 1 轮 |
| **4** | 听歌页**头部排版**（歌名加粗放大、`⋯` 靠右） | 要动 Spotify 标签 ⇒ 必须走 `LibraryAppearance` 那套**复查节拍**（binder 会写回），风险中 | 1~2 轮 |
| **5** | 页面级清理开关**第 2 批** | 原料已在 `.spotify-ipa/view-inventory-all.txt`（31 份日志的合并清单）；每加一条先加白名单 + 两个 l10n 键 | 1~2 轮 |
| — | ⛔ 不做：拖动排序（撞"不动别人布局"红线）、morph 转场（私有转场类）、10 屏自绘、FLEX 随包、音频三件套（用户搁置） | | |

---

## 6. 要求与规矩（本会话新增/强化，照做）

1. **commit message 用英文**（用户 2026-10-03 明确要求："外国人用的多"）。历史里有中文的不重写。
2. **改完必跑五条**（全过才算完）：
   ```
   python Tools/eevee-hookfinder/orion_hook_guard.py        # 320 文件
   python Tools/eevee-hookfinder/swift_brace_check.py       # 320
   python Tools/eevee-hookfinder/swift_member_check.py      # 265（含"变量.成员"规则）
   python Tools/l10n_lint.py --locale en --quiet
   python Tools/l10n_lint.py --locale zh-CN --quiet
   # 动过「减少打扰」页或目录时，加跑：
   python Tools/eevee-hookfinder/check_reduce_interventions_l10n.py
   ```
   ⚠️ 这五条**不做类型检查**。本机无 Swift 工具链 ⇒ `flag.id` / 调用点参数不匹配这类错
   **只有 CI 或"变量.成员"规则**能抓。**写完新代码要自己逐句读一遍签名**。
3. **不要挂"可选方法"**：`viewDidLayoutSubviews` / `viewDidAppear` 这类，只有类**真的覆写**了才能 hook。
   已确认可挂：视图控制器的 `viewWillAppear` / `viewDidAppear` / `viewDidLoad`。
   挂 `NPVScrollViewController` 的 `viewWillAppear`/`viewDidAppear` 都在既有 hook 里（不新开 hook）。
4. **不要依赖 9.1.x 上恒为 nil 的全局**：`npvScrollViewController` / `nowPlayingScrollViewController` /
   `scrollDataSource` 都来自被隔离的 `V91UnavailableLyricsGroup`。要用就**传参**进去（§1 #10 的教训）。
5. **"先交占位"这类"看起来保险"的做法要先想副作用**：占位会被对端固化，见 §2.1。
6. **Swift 类型检查器**：一句话里别堆 `&&` 链 + 集合判据 + 三元 + 字符串插值。
   已在 `EeveeReduceInterventionsView` 上踩过 `unable to type-check in reasonable time`。
   **拆成逐句、显式类型**（本会话有两处注释写着这条）。
7. **两处白名单纪律**（页面显式列出要渲染的 flag）**不要改成"渲染整组"**：会带出没文案的条目 ⇒ 裸键名。
8. **逆向产物的边界**：派生标识（类名/flag 名/视图清单）留在仓库；**新 dump 一律进 `.spotify-ipa/`（已 gitignore）**；
   **绝不**放解密 IPA、二进制、音频、歌词文件、凭证。要对齐 README 的「Reverse-engineered data, and takedowns」。
9. **`pwsh` 在本机必须 `sandbox_permissions: "danger-full-access"`**，否则 `0xC0000142`。
   控制台是 GBK：中文输出**落成 UTF-8 文件再用 `read` 读**，别指望 stdout。
10. **文档即交付**：改动落地就写进本目录的 md（外观 → `KUMONE_REFERENCE.md` / 相关 SESSION 文档；
    功能缺口 → `SPOTIPW_GAP.md`；入口 → 本文件）。

---

## 7. 常见坑（这一会话新增）

| 坑 | 正确做法 |
|---|---|
| **`[NPVStyle]` 零行 = 没跑到，不是"没效果"** | 每个提前返回都要打一行说明原因（本会话补上） |
| **改歌词交付只改 `DataLoaderServiceHooks`** | 两条路（`[DL]` / `[HCUS]`）都要改，先看日志里哪个前缀在跑 |
| **`KnownFlag` 没有 `id`** | 覆盖表 id = `scope.isEmpty ? name : "\(scope).\(name)"`（与 `FlagOverride.id` 同构） |
| **目录里加 flag 会自动上屏** | 页面是白名单驱动；加白名单 + 两个 l10n 键，跑核对脚本 |
| **`.strings` 里值内不能用裸 `"`** | 中文引号用「」；`\"` 转义只在历史行里见过 |
| **`row` 重构后漏改调用点** | 同一文件里搜一遍旧签名（本会话的编译错就是这么来的） |
