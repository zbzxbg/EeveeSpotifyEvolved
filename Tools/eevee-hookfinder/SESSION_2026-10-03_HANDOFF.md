# 交接：2026-10-03 会话（歌词线收口 + 减少打扰页 + 听歌页取色底）

> 🆕 **2026-10-05 追加入口**：[`SESSION_2026-10-05.md`](SESSION_2026-10-05.md)
> —— 「禁止回弹」删掉（它弄坏了下拉关闭）、双击手势删掉、转储器定向化、一屏默认开、
> 控制键换本地字形、歌词进播放器（按 pw 形状重做）、NetEase 选歌与 `<Music>` 修复。
> 链条：本文件 → `SESSION_2026-10-03_NIGHT.md` → **`SESSION_2026-10-05.md`（最新）**。
>
> ⛔ **这一份已被取代**：最新入口是 [`SESSION_2026-10-03_NIGHT.md`](SESSION_2026-10-03_NIGHT.md)
> —— AM 页面开工 + 探针包 + spoti.pw 许可边界重画 + 「一屏」被真机打回三次的完整记录 + 新增规矩。
> **新会话先读那一份**；本文件的 §8 / §8.7 仍然有效（那是那一夜**之前**的裁决与流水）。
>
> （以下为写作当时的说明，保持不变。）**新会话先读这一份**，然后按 §4 的"待验收"清单往下做。
> 上一份入口是 [`SESSION_2026-10-02_HANDOFF.md`](SESSION_2026-10-02_HANDOFF.md)（它自己又指向
> `SESSION_2026-10-02_SUMMARY.md` 的 §9）。**本文件不重复它的内容**，只写"那一份之后发生的事"。
>
> 写作时状态：**HEAD = `b14d6b9`**，工作区干净。
> ⚠️ 这一轮的所有改动**都还没在真机上验收过**（日志 37 是旧构建），见 §4。
> ★ **2026-10-03 夜补记：验收日志 38 已经到了，裁决与重做写在 §8 —— 先读 §8 再动手。**

---

## 0. 三十秒现状

| 线 | 状态 |
|---|---|
| **歌词：v4.11 的 1.5s 预算** | ❌ **已撤销**（`19192df`）。日志 36 证明它每次都在 1.6s 交出 62 字节占位、把卡片**锁死**在"未找到歌词"，真词 3 秒后到手也刷不进去 |
| **歌词：两条传输层** | ✅ 分档预算/结果备忘**对齐到 `HttpClientURLSession`**（`4e756f1`，用户提交；`ca3e080` 修了其中的编译错）。此前只有 `SPTDataLoaderService` 那条路有，而真机日志 28→35 **`[DL]` 全零、`[HCUS]` 有值** ⇒ 修的东西从没执行过 |
| **歌词：AMLL 优先的回退链** | ✅ **按用户设置**（`196119f`）：现在是 `AMLL → 用户源 → Genius`。以前是 `AMLL → Genius(自带兜底) → 用户源 → Genius`（用户指出、日志 36 t2 坐实，15s 里白花一跳） |
| **歌词：响应耗时** | ✅ 有判据了：`[HCUS]/[DL] lyrics 交付给 Spotify — N bytes（请求起算 X.Xs）` + `[Lyrics] chain: …` |
| **「减少打扰」页** | ✅ 新页（`0c5e3ff` + `c7db3a5`）：**8 个小开关 + 1 个总开关**，写 flag 覆盖、可撤销、需重启生效 |
| **听歌页取色底（仿 AM）** | 🔁 **日志 38 判决：代码跑到了、但页面零变化**（§8.2）⇒ **本轮 重做**：自己持有整页视图 + 可见性闸门 + 0.3s 自愈（§8.3）。等新构建的**截图** + `[NPVStyle]` 行 |
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

---

## 8. ★ 2026-10-03 夜：验收日志 38 的裁决 + 取色底重做

> 这一节是**上面 §4 的答案**。新会话读完 §0/§4 之后直接跳到这儿。

### 8.0 一句话

日志 38 = **`b14d6b9` 之后的验收日志**（提交 19:16:46，日志 19:52–19:54；`[NPVStyle]` 那两句
与 HEAD 源码**逐字一致**；交接本文件写于 19:19，所以它只提到日志 37）。

* 歌词那两件（回退链、HCUS 交付）**✅ 通过**；
* 「减少打扰」页 **❓ 没验**（那份日志里根本没打开过）；
* 听歌页取色底 **❌ 失败** —— 代码跑到了、自报"接管 1 层"，**但页面零变化**。

### 8.1 日志 38 对 §4.1 四件事的逐条裁决

| 项 | 日志 38 的证据 | 裁决 |
|---|---|---|
| 歌词回退链（`196119f`） | `[Lyrics] chain: AMLL → NetEase → Genius（仅当用户源也失败）` ×3（L544 / L3372 / L4636）；`AMLL failed — Genius fallback suppressed by caller, no retry`（L3807）；**没有**旧的 `falling back to Genius` | ✅ 通过 |
| 歌词交付（`4e756f1`/`ca3e080`） | `[HCUS] lyrics 交付给 Spotify — 2733 / 2571 / 2373 bytes（请求起算 1.9 / 2.8 / 1.0s）`（L999 / L3822 / L4664）—— 是真词，不是 62 字节占位；`[DL]` 仍然零行（这台设备走 HCUS，与 §2.2 一致） | ✅ 通过 |
| 「减少打扰」页 | 日志里没有 `reduce_interventions` / `[Flags] replacement <用户开的那条>` / `user overrides` —— **用户没打开那一页** | ❓ 仍待验 |
| 听歌页取色底 | 见下 §8.2 | ❌ 失败 |

### 8.2 ★ 取色底为什么"接管了却没变化"（日志 38 的铁证链）

```
11:52:59  [NPVStyle] no full-page coloured sibling found under UIView — backdrop skipped   ← viewWillAppear
11:52:59  [NPVStyle] backdrop (414x896) ← 封面取色 e84838，接管 1 层（…）                   ← viewDidAppear，自报成功
11:53:01  [Tree] #7  7.UIView@0,0,414,896,bg=#E84838
11:53:03  [Tree] #8  7.UIView@0,0,414,896,bg=#E84838
11:53:09  [Tree] #9  7.UIView@0,0,414,1682,bg=#584860      ← 还自己换了色、长高了
```

* **`bg=` 的打印条件是 `backgroundColor != nil && != .clear`**（`ViewTreeDumper.swift:159`）
  ⇒ 我们"清空底色"这件事**在树上不可能不留痕迹**。三次 dump 都还在 ⇒ 写操作没生效（或被写回）。
* 数量本来是对的：NPV 子树里"满页 + 有底色"的视图只有那一个（`#121212` 那个在播放列表/首页/
  搜索页同一深度都出现，是全 App 的页面容器，不在 NPV 子树里）⇒ 所以**不是选错层**这一种可能
  —— 但旧代码**没有可见性闸门**，同一页里确实躺着 `15.UIView@0,0,414,896,hidden,alpha=0.00`
  这种满页不可见视图（#7 L4047），所以"垫了个看不见的"也没法排除。
* **真正的病根在机制**：旧做法把渐变 `insertSublayer(at: 0)` + `zPosition = -1` 塞进**别人的
  layer 栈**，又去清别人的 `backgroundColor` —— 前者可能被那层自己的子层压住（这一页本来就有
  `NowPlaying_ScrollImpl.NPVGradientView`，`dump-9.1.88.txt:3127`），后者要与 binder 抢写回
  （`MiniBarGlass.swift:244-285` 为同一个坑写过"清了又写回"）。
* **另一个独立缺陷**：#7→#9 证明**用户一直待在这一页时那层自己会换色/长高**，而这段时间
  **没有第三次 `[NPVStyle]`**（`apply` 只在 `viewWillAppear`/`viewDidAppear` 跑）⇒ 就算垫对了，
  换歌/滚动之后也必然失配。

### 8.3 本轮 改了什么（三条一起）

| # | 改动 | 依据 |
|---|---|---|
| 1 | **不再动 Spotify 的任何属性**：改成"我们自己的一个整页 `UIView`（三层渐变作子层）+ `insertSubview(at: 0)`"。它自己的底色在我们下面、它自己的子视图在我们上面 ⇒ **最坏只是"没效果"，不会盖掉内容**；关开关 = 拿走我们的视图 ⇒ **天然完全还原** | §8.2 第一、三条 |
| 2 | **候选加可见性闸门**：`isHidden` / 祖先链 `alpha` / `window != nil`，被排除的**计数上报** | §8.2 第二条 |
| 3 | **`reconcile()` 自愈**：蹭 `DeclutterChrome` 既有的 0.3s 复查节拍（**不新开定时器**）—— 颜色先读**那一层自己的底色**（Spotify 每首歌写一次，一次属性读），变了才去问 `metadata()["extracted_color"]`；尺寸每拍同步；我们的层不见了就重挂（1s 节流） | §8.2 第四条 |
| 4 | **`[NPVStyle]` 自报身份**：垫上谁（类名 + frame + 它自己的底色 + `subviews`/`layer.sublayers`/手插子层数）、跟到换色、重挂 —— 下次不必再翻 `[Tree]` 的 BFS 层级反推 | 这一轮诊断的主要代价 |

改动文件：`Sources/EeveeSpotify/Appearance/NowPlayingBackdrop.swift`（重写）、
`Sources/EeveeSpotify/Lyrics/CustomLyrics+AllTracksLyrics.x.swift`（`refreshNowPlayingBackdrop`
的"没有 VC"那条支路退到 `refreshLastPage()`）、
`Sources/EeveeSpotify/Appearance/DeclutterChrome.x.swift`（复查节拍里加一行）。

自检：`orion_hook_guard` / `swift_brace_check`（320）、`swift_member_check`（265）、
`l10n_lint --locale en|zh-CN` —— **5 条退出码全 0**。
⚠️ 这 5 条**不做类型检查**，本机也没有 Swift 工具链；改完已逐句读过签名
（本轮自己抓到一处：`layers(of:)` 被调用却没定义 —— 这类错只有 CI 或人眼能抓）。

### 8.4 下一次验收（一次装机就够）

设置：调试 →「启用日志记录」开；「转储视图树」**这次可以不开**（身份现在由 `[NPVStyle]` 自己报）。

> ⚠️ **别靠版本号认构建**：这一轮**没有动发布元数据**，`control` 仍是 `6.6.8`，
> 所以日志第一行还会是 `=== EeveeSpotify 6.6.8 (build 2) starting ===`。
> 认构建看 **`[NPVStyle] backdrop …` 那行里的新字段**：`（那层底色 …，subviews=…，layer.sublayers=…，手插子层=…）`
> —— 旧构建没有这一段（日志 38 那句只有"接管 N 层"）。

1. 放一首**有封面**的歌 → 进**听歌页** → **截图**（应能看到"对角渐变 + 左上白光 + 底部压黑"，
   不再是原来那块**平的**封面色）；
2. **切下一首** → 等 1 秒 → **再截一张**（颜色应在 0.8s 内淡入着换）；
3. **在听歌页里往下滚** → **再截一张**（底色应跟着内容长，不留白/不露原来的平色）；
4. 扩展功能 →「听歌页」→ 关掉「整页封面取色底」→ 回听歌页 → **截一张**（应完全恢复原样）。

**我看哪几行**：

```
[NPVStyle] backdrop 414x896 ← 封面取色 E84838，垫在 UIView 0,0,414,896 之下（那层底色 E84838，subviews=N，layer.sublayers=M，手插子层=M-N）；三层：…
[NPVStyle] ⚠️ 那层自己还挂着 M-N 个手插子层 — 万一截图仍无变化，就是它们压着我们
[NPVStyle] 跟到换色 → 584860（第 2 次；那一层底色 584860）
[NPVStyle] 我们那层不在了 — 重挂（第 1 次）
[NPVStyle] 有 N 个满页着色层是 hidden / 透明 / 不在窗口里 — 已排除
[NPVStyle] backdrop removed（1 层已拿走，reason=switch off）
```

**通过判据（这次以截图为准，日志只用来解释）**：
1. 第 1 张与"没这个功能"时**明显不同**（渐变 + 底部变暗）；
2. 第 2、3 张里颜色/尺寸**跟得上**（日志里有 `跟到换色`）；
3. 第 4 张与"没这个功能"**看不出差别**，日志有 `backdrop removed`；
4. 若仍无变化：看那行 `手插子层=` —— **>0 就说明是它自己的子层压着我们**，
   下一版把 `backdrop` 从"子视图栈最下面"提到最上面（`addSubview`）。

### 8.5 离"和 kumone 听歌页差不多"还差什么

用户 2026-10-03 明确目标：**听歌页最终要对齐 kumone 的听歌页**。取色底只是第 1 项（`KUMONE_REFERENCE.md` §1）：

| # | 还差 | 位置 | 状态 |
|---|---|---|---|
| 1 | 整页取色底 | `NowPlayingBackdrop.swift` | 🔁 本轮重做，**等这次验收** |
| 1b | **一屏**（卡片全折 + 列表钉顶部 —— kumone 那种"一屏一首歌、滚不动"） | `NowPlayingOneScreen.swift` + `NowPlayingOneScreenCards.x.swift`（借 spoti.pw **v0.21.1**，GPL-3.0） | ✅ 已实现，**默认关**（会连**歌词卡**一起折掉，见 `SPOTIPW_0211_PORT_ASSESSMENT.md` §8），等验收 |
| 2 | 歌词列**上下渐隐 + 拖动暂停** | 逐词层外层加 mask；`NowPlayingMetrics.lyricFadeStops` 已经备好（0/0.12/0.85/1） | ⏳ 下一轮（取色底能看见之后再排） |
| 3 | 播放页**头部排版**（歌名加粗放大、`⋯` 靠右） | 要动 Spotify 标签 ⇒ 必须走 `LibraryAppearance` 那套复查节拍 | ⏳ 待定 |
| 4 | 控件行的间距/尺寸对齐 kumone（`NowPlayingView.swift:766`） | `NowPlayingMetrics` 已落表，部分还没被消费 | ⏳ 低优先 |

### 8.6 这一轮新增的纪律

| 坑 | 正确做法 |
|---|---|
| **"自报成功"不是证据** —— `接管 1 层` 这种只报数量的日志，事后要靠翻 `[Tree]` 的 BFS 层级反推 | 自报要带**身份**（类名 + frame + 那层自己的属性）+ **写后读回** |
| **往别人的 layer 栈里插东西 / 抢 `backgroundColor`** | 加**我们自己的视图**；别人的属性一字节不改 ⇒ 还原是天然的 |
| **同一页的 dump 里有满页但 `hidden`/`alpha=0` 的视图**（`15.UIView@…,hidden,alpha=0.00`） | 选目标前先过**可见性闸门**（自己 + 祖先链 + 在窗口里） |
| **`apply` 只在 `viewWillAppear`/`viewDidAppear` 跑** | 换歌/滚动要在**既有复查节拍**上自愈（不新开定时器） |
| **`lastHex == hex` 就早退** | 早退 = 自愈永远来不了；幂等要做成"确保状态"，不是"什么都不做" |
| ★ **Orion hook 方法里写 `self`** | 钩到的对象是 **`self.target`**（`self` 是 hook 类自己）。写成 `self` **只有 CI 才炸**，报成 `has no member 'clipsToBounds'` / `cannot convert value of type 'XHook' to expected argument type 'UICollectionViewCell'`，一路冒泡到 `make` exit 2、**deb 没生成**（2026-10-03 夜真机踩到）。既有 hook 全是 `self.target`，照抄那个写法。**`orion_hook_guard.py` 已加规则 4 拦它**（允许 `self.target` / `self.orig` / 本类自己声明的成员；不算 `[self]` 闭包捕获）—— 两向验证过：322 文件 0 误报、假错恰好抓两条 |

---

## 8.7 ★ 日志 39 + 照片 42–44 的裁决（2026-10-03 深夜，构建 = 带探针包那份）

### A. 探针一次答完的问题

| 问题 | 答案 |
|---|---|
| pw v0.21.1 的 **14 个播放页目标**在 9.1.88 上还在吗 | ✅ **14/14 全在** ⇒ AM 视图（头部 / footer / 控件 / 封面场 / 歌词进播放器）**全部可搬** |
| morph 那个类呢 | ❌ `SPTBarOverlayPresentationTransition` **不存在** ⇒ **正式划掉 morph** |
| pw 注释里"下拉关闭挂在列表 pan 上"的那个类 | ❌ `SPTBarInteractivePresentationController` **不存在** ⇒ 9.1.88 的关闭机制换了（我们是**绕开它**做的，不受影响；但"下拉还能不能关"仍以实测为准） |
| pw 手势层要的播放控制器 | ✅ `SPTNowPlayingPlaybackControllerImplementation` **在** ⇒ 将来想要 pw 那种分区手势是可行的 |
| 双击那条坑在我们这儿活不活 | ✅ **活的**：`[Gestures] diag … singleTapsAbove=2` ⇒ 值得花那一轮修 |

### B. 取色底：✅ **成功**（日志 + 截图双证）

```
[NPVStyle] backdrop 414x896 ← 封面取色 E03038，垫在 UIView 0,0,414,896 之下
           （那层底色 E03038，subviews=2，layer.sublayers=2，手插子层=0）
[NPVStyle] 跟到换色 → C84098（第 2 次）→ E030B8（第 3 次）→ C00000（第 4 次）
```

* **`手插子层=0`** ⇒ 那层自己没有手插 layer ⇒ 我们插在**最下面也不会被压住**（照片 42/43/44 整页的红 / 粉 / 紫就是它）；
* **`跟到换色` ×3** ⇒ 换歌跟着换；
* 顺带证实了旧版为什么失败：`有 1~2 个满页着色层是 hidden / 透明 / 不在窗口里 — 已排除`
  —— **可见性闸门真的挡掉了旧版会误选的那些层**。

### C. 一屏：卡片 ✅、钉住 ❌ → **根因已抓到并修掉**

```
14:30:36 [OneScreen] 列表已钉在顶部 — 折掉 1236pt    ← 按"卡片还在时"的 content.h=2132 算的
14:30:37 [OneScreen] 内容还没到一屏高（want=+0pt）— 不压   ← 卡片折完，内容只剩一屏
```

⇒ 上一版那条 `want >= 0` 分支**只 return、不把 inset 退回去** ⇒ `-1236` 留在列表上 ⇒
**往下能滑 1236pt 空白**（用户原话："往下划也没东西了"）。
修法：那一支改成 `revertInsetIfNeeded(list)` —— 内容缩回一屏内就把 inset 退回原值。

**还剩一件（单独一轮、有风险，先不动）**：`bounce=on`（`panRecs=3`）。钉好之后若还有**一点点**
回弹，那是 `alwaysBounceVertical`；关它才能真正一动不动，而关它**有可能弄坏下拉关闭**
⇒ 必须以"下拉还能关吗"为验收判据。

### D. 「无法播放任何歌曲」：第一个候选现场

```
14:29:31 [PLAYER] track changed — pos=27.4s dur=114.0s
14:29:36 [PLAYER] ⚠️ position stalled at 27.4s for ~3s (dur=114.0s)
（之后直到 14:30:08 换曲，都没有 `position resumed`）
```

⚠️ **探针分不清"暂停"和"卡住"**（没有 paused 源）。而 ProbePack 证明
`SPTNowPlayingPlaybackControllerImplementation` **在 9.1.88 上存在** ⇒ 下一版可以补一个
**只读 `isPaused`**，这条线就能定性了。



