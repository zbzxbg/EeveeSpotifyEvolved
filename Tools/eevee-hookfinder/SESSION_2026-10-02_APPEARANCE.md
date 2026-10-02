# 听歌页 / 标签栏「观感改造」总结（2026-10-01 深夜 → 10-02）

> **这一份是入口**。上一个会话的结论在 `SESSION_2026-10-01.md`（flag 通道、音乐库、样品 v1）；
> 本文只写**观感改造这条线**：做了什么、错在哪、下一步做什么、什么要求。
> 判据一律来自**真机日志 + 解密 IPA**，不猜。
>
> ⚠️ **2026-10-02 之后请先读 [`SESSION_2026-10-02_SUMMARY.md`](SESSION_2026-10-02_SUMMARY.md)**
> —— 那是新入口（现状 / 待办 / 规矩 / 已知坑一页看完），本文降级为**细节流水**（§11–§19）。

---

## 0. 三分钟看懂现状

| 目标 | 状态 |
|---|---|
| **底部标签栏「一条玻璃胶囊」**（照片 21 那种形状） | ⏳ v3 形状对了但**位置错了 15pt**（日志 20 坐实）→ **v4 已写，等一次 CI**（见 §11） |
| 听歌页「背景跟封面取色」 | ❌ **还没成** —— 现在是"透明档"，等于没做（详见 §2.3） |
| 听歌页「自绘顶栏（⌄ + 歌名 + 艺人）」 | ✅ 成立（照片 19/20 可见） |
| 听歌页「吸顶头让位」（滚动时不被原生底色盖住） | ⏳ hook 已装真类名，**效果未验收** |
| 听歌页「滚动卡死」 | ✅ 病根已拆（原因是我自己写的每帧清别人底色，见 §4.1） |
| 音乐库「大标题放大」 | ✅ 已验证（日志 19：`24pt → 30pt`，且未被 binder 写回） |
| 音乐库「收掉顶部灰纱」 | ❌ 已删除（肉眼看不出 + 属于"动别人视图"，见 §5.2） |
| flag 通道（`[Flags]`） | ✅ 已修并验证（见 `SESSION_2026-10-01.md` §0.5） |
| 音频三件套 / Live Activity / 锁屏封面 | ⛔ 用户已否决，别再提 |

---

## 1. 硬约束（这几条都是这轮踩出来的，动手前必读）

1. **deployment target = iOS 14**（`Makefile:1`），CI 用 Xcode 26.1.1。
   所以：**能用 iOS 26 的 API，但要靠"运行期反射 + 兜底"**，写成
   `NSClassFromString("UIGlassEffect")` → 拿到就用、拿不到退材质。
   ⚠️ **不要为了玻璃提高最低版本**：反射已经能拿到 `UIGlassEffect` / `UIGlassContainerEffect`，
   提高版本只是砍掉 iOS 14~25 的用户，换不到新能力（详见 §6.3）。
2. **不要动别人的视图。** 这条吃了两次亏：
   - 听歌页：在**壳的每帧布局**里遍历整窗、清 Spotify 视图的 `backgroundColor` → **页面划不动**（§4.1）；
   - 音乐库：每 0.5s 把别人的滚动边缘效果 alpha 归零 → 与它的滚动动画对着干（§5.2）。
   规矩：**只 hook 目标自己**、**只做只读判断 + 一次改动**、**绝不在布局回调里反复写**。
3. **改 Encore 的 element 界面不能"改一次就好"**：Spotify 的界面是
   `ElementView` + binder 数据驱动，binder 会把属性写回去。
   仓库里早有解法：`DeclutterChrome` 那套**常驻节拍复查**（定时器 + 前台 + 布局里顺手叫一次）。
   音乐库那边已经照做；**后面每一屏都要照做**。
4. **玻璃不能采样玻璃**（苹果的硬规矩）：系统已经有玻璃的地方再叠一层 → 发浑、边缘脏、掉帧。
   所以"我们的玻璃"要么**独占**那块区域，要么**别做**。
5. **hook 方法上不写 `@MainActor`**，方法体里用仓库现成的 `onMainThreadSync`
   （`LyricsChromeVisibility.swift:3-17` 有成文说明）。
6. **`.x.swift` 必须 `import Orion`**，`typealias Group` 指向的 HookGroup **必须真的定义**
   （漏了会炸出 `HookGroup`/`_Glue`/`orig`/`target` 一大串看起来无关的错）。
7. **改完先跑本机三个检查器再推 CI**（§7），每次编译都很贵。

---

## 2. 听歌页（NowPlaying）

### 2.1 三个版本的演进

| 版本 | 做法 | 结果 |
|---|---|---|
| v1（`MusicStyleNowPlaying` 的 `ensureBackdrop`） | 渐变 `insertSublayer(at:0)` + `addSubview` 标题 | ❌ 背景被 Spotify 自己两个整屏不透明层盖住 = 白画；标题会被吸顶头盖住 |
| v2（`NowPlayingShell`） | 整页自绘壳：`LyricsBackdropView(style:.stage)` 铺满 + 自绘顶栏 + 让原生吸顶头让位 | ⚠️ 顶栏成了；背景铺得**不透明**，把封面/进度/三键全盖住（照片 19）→ 改成透明档后**等于没做** |
| 现在 | 透明档 + 顶栏 + 吸顶头让位（只 hook 它自己） | ⏳ 顶栏在，底色没了，吸顶头待验收 |

### 2.2 照片 19 / 20 的两次教训（都写进代码注释了）

- **照片 19**：`isBackdropOpaque = true` 是**全屏歌词页**那一档（那页我们整页替换）。
  听歌页的原生内容**正是要显示的东西**，一铺实心就全盖住。
- **照片 20**：`UIGlassEffect` 铺在 **121pt 高的顶栏**上 → 把下面整片内容糊成残影
  （用户原话："像糊了一层液态玻璃"）。所以**顶栏玻璃默认关**，只在设置里给开关。

### 2.3 ⚠️ 还没解决的核心问题：「背景跟封面取色」

现状 = **透明档**：不盖内容，但**我们自己什么都没画**。
- 试过的两条路都不行：
  - `insertSublayer(at:0)` → 被盖（v1）；
  - 铺满 + 实心 → 盖住内容（v2）；
- **下一步该试的**：**半透明**（alpha ≈ 0.3~0.4）铺满 + **让原生那道滚边渐隐让位**。
  半透明既能看到取色、又不至于压死内容 —— 这是唯一还没试过的那一档。

### 2.4 吸顶头让位（真类名已拿到）

- 真类名：**`NowPlaying_ViewImpl.StickyHeaderViewControllerImpl`**
  （IPA `dump-9.1.86.txt:2034`）。
  ⚠️ 之前用的 `ScrollStickyHeader` **在 9.1.86 上根本不存在**（那是 element 的标识符，不是类名），
  所以那一版一直在空转。
- 做法（`StickyHeaderYieldHook`）：
  - 只 hook**它自己**的 `viewDidLayoutSubviews`；
  - 目标**不用类名**：从路径里的**歌曲标题 label** 往上找**第一个不透明的祖先**（`firstTintedAncestor`）；
  - **只清一次**（值没变不动）；**保险丝**：被写回超过 5 次就放弃并打日志
    （宁可保持原生，也绝不和它抢 —— 那正是滚动卡死的成因）。

---

## 3. 底部标签栏玻璃（三版都在这一节，别再退回前两版）

### 3.1 真机结构（日志 19 的 `[TabBarDump]`，尺寸那轮是 0x0，见 §3.4）

```
TabBarView(414x83, id=elements-tabs-view-identifier)          ← hook 挂这里
└ TabBarCompactView(414x83) ★有渐变层                          ← 这条栏的"底"
  └ UIStackView(id=tabs-container-view-identifier)             ← 四颗是这条 stack 里的**兄弟**
    ├ ElementView → TabBarItemElementView(id=TabBar.Item.主页|搜索|音乐库)
    │     ├ SPTEncoreIconView(id=Encore.IconView)
    │     ├ SPTEncoreLabel(id=Encore.Label) → UILabel
    │     └ UIView(bg=#1278F2, corner=3, hidden)               ← 疑似选中/通知标记
    └ ElementView → CreateMenuTabBarItemView(id=TabBar.Item.创建)
          └ UIView(bg=#FFFFFF, corner=20.0, alpha=0.00)         ← 它自带的圆底（Spotify 用的半径=20）
```

**关键结论**：四颗是 **stack 里的兄弟** → "每颗一块玻璃"永远**不会融合**。
想要 MeloX 那种"靠近就融合"，必须把四颗放进**同一个玻璃容器**
（UIKit `UIGlassContainerEffect` / SwiftUI `GlassEffectContainer`）——
那要把 **Spotify 的四颗视图搬进我们的容器**，会打断它们的布局与手势 → **不做**。

### 3.2 三次尝试

| 版本 | 做法 | 结果 |
|---|---|---|
| v1 | 每颗标签各一块 `103×49` 玻璃（铺满） | ❌ 四块方玻璃、盖住选中滑块 → 用户："更难看了" |
| v2 | 同 v1 但每边内缩 10pt | ❌ 还是四块，方向没变 |
| **v3（当前）** | **整条栏一条胶囊**：`TabBarView` 索引 0 插一层玻璃，左右留 8、上下留 6、半径=半高（398×71） | ⏳ 等验收 |

v3 的依据全部来自 dump：栏 `414×83`、四颗各 `103×49`（早期树 dump）、Spotify 自己的圆角 `20`。

### 3.3 用户目标（照片 21）

一条**通栏胶囊玻璃筋** + 图标浮在上面 + 选中态有 Spotify 自己的滑动胶囊。
- 用户实测：**关掉我们的开关，底栏是透明的 → 系统没给这条玻璃**，所以"得我们做"；
- 也**不能**做成四块（那是 v1/v2 的错）。

### 3.4 还没拿到的数据（下一步）

日志 19 那轮探针**挂在栏的第一次 `layoutSubviews`** 上 → 所有 frame 都是 `0x0`（内容还没排）。
已改：探针挂到**每一颗标签自己**的布局上，**等它真的有尺寸（>1pt）再 dump**，
并额外打印**栏在窗口里的绝对位置**。

**下次日志要看的**：
```
[TabBarDump] bar 在窗口里的位置 = (…,… 414x83)  [窗口 414x896]
[TabBarDump] #7  TabBarItemElementView frame=(…,… …x…)      ← 真实尺寸
[TabBarDump] #9    SPTEncoreLabel frame=(…,… …x…)
```

### 3.5 如果 v3 还不对（预置判断，别现猜）

| 现象 | 结论 → 动作 |
|---|---|
| 形状对了但"廉价" | 那是 `UIGlassEffect` 在暗底上的本色 → **加淡描边高光**，不改结构 |
| 还是四块 / 没有 | `insertSubview(at:0)` 被 `TabBarCompactView`（带渐变层那个）盖住 → 改成**插在 CompactView 之上、图标 stack 之下** |
| 玻璃把图标糊了 | 说明插错层 → 必须保证图标在玻璃**之上**（`index 0` 的意义就在这里） |

---

## 4. 听歌页那两个"我造成的"故障（已修，记下来别再犯）

### 4.1 页面划不动

- **原因**：`NowPlayingShellView.layoutSubviews` 里跑 `nativeTintYield()` ——
  **每帧遍历整窗 + 清 Spotify 视图的 `backgroundColor`**。
- **修法**：整段删除。让位改成"只 hook 吸顶头自己 + 一次性"（§2.4）。
- **教训**：`DeclutterChrome` 当年就是**同一个坑**（渲染回合不可靠 + 动别人的视图）。

### 4.2 玻璃把内容糊成残影（照片 20）

- **原因**：`UIGlassEffect` 铺在 121pt 高的顶栏上。
- **修法**：顶栏玻璃**默认关**（设置里给开关）；玻璃只用在**小块浮起控件**上。

---

## 5. 音乐库（第一屏"改原生"）

### 5.1 成了的

- **大标题放大**：`YourLibraryHeader.title` 的 font 在原生字号上 ×1.25 + 加重。
  日志 19：`[Library] 大标题已换成 AM 档：24pt → 30pt`，**且没有"被写回"告警**
  （说明 binder 这次没覆盖它）。
- 复查节拍（`LibraryAppearance.reconcile`，0.5s）已按 `DeclutterChrome` 那套装上。

### 5.2 删掉的

- **收掉顶部灰纱**（`Reprise_LiquidGlassKit.LiquidGlass.GradientView` 的 alpha）：两条理由 ——
  ① 肉眼看不出来（用户反馈"没任何改动"）；② 它**每 0.5s 把别人的滚动边缘效果归零** =
  和它的滚动动画对着干（与 §4.1 同源）。**要收它，前提是确认它不会随滚动被写回。**

### 5.3 还没做（同一套流程往下铺）

- 列表行：封面圆角统一、发丝分隔线 —— 那些是 **element 自己画的**，
  不是 `UIImageView.layer.cornerRadius` 那种改法，得单独摸一轮。

---

## 6. 这一轮学到的"界面能力"（可以直接复用）

### 6.1 Spotify 的界面不是普通 UIKit

- 是 **Encore 的 element 系统**：`ElementView<Props, State, Event>`、`LazyElementView`、
  `ElementContentView`，由 **binder** 从数据模型驱动。
- 含义：
  - ✅ 能改：`alpha` / `backgroundColor` / `textAlignment` / **约束常数** / `UILabel` 的 font 与颜色
  - ⚠️ 会被 binder 写回：字号、字重、文本 → **必须复查 + 计数**（"被写回 N 次"是我们判断
    "这条路走不走得通"的判据）
  - ❌ 改不了的：cell 里 element 自己画的圆角/分隔线

### 6.2 液态玻璃的正确用法（来自 MeloX 的源码）

MeloX（从零写的 SwiftUI）用的是系统的**两个 API 配对**：

```swift
GlassEffectContainer(spacing: 10) {      // 容器：决定"多近开始融合"
    transportButtons(…)                  // 里面的每个 .glassEffect 共享采样区
}

.glassEffect(.regular.interactive(), in: .capsule)   // 单元素 + 交互
.buttonStyle(.glass)                                 // 玻璃按钮
```

| SwiftUI（MeloX） | UIKit（我们能用的） |
|---|---|
| `GlassEffectContainer(spacing:)` | **`UIGlassContainerEffect`**（`spacing`） |
| 元素 `.glassEffect` | **`UIGlassEffect`**（`UIVisualEffectView`） |
| `.interactive()`（按下回弹/触摸点亮） | **没有直接对应** —— 要自己写，或先不做 |

**我们缺的从来不是"渲染"，是"容器"**；而容器要求元素是我们自己的视图（§3.1）。

### 6.3 为什么**不要**为了玻璃提高最低版本

| 提高部署目标能解锁 | 实际 |
|---|---|
| `UIGlassEffect`（渲染） | 已经在用（运行期反射） |
| `UIGlassContainerEffect`（融合） | 运行期反射就能拿，**与部署目标无关** |
| SwiftUI `.glassEffect()` | 能编译（CI 是 Xcode 26），但那只对**我们自己拥有的视图**有意义 |
| 代价 | **iOS 14~25 的用户全部装不上** |

---

## 7. 本机三个检查器（改完先跑，再推 CI）

| 脚本 | 挡什么 | 当前 |
|---|---|---|
| `Tools/eevee-hookfinder/orion_hook_guard.py` | ①缺 `import Orion`；②`typealias Group` 指向的 HookGroup 不存在；③`orig.*` 转发缺失 | OK 315 文件 |
| `Tools/eevee-hookfinder/swift_brace_check.py` | 括号/字符串配对（认 raw string `#"…"#`） | OK 315 文件 |
| `Tools/eevee-hookfinder/swift_member_check.py` | ①`类型.成员` 引用是否存在（挡"成员插错作用域"）；②`guard let` 绑了非 Optional | OK 260 文件 |

⚠️ **检查器覆盖不到的**（只能靠人守）：搬代码时新位置引用的 `static` 名字**要补全类型前缀**
（这条我试过自动查，两版都误报 100+ 条，已放弃并在脚本里写明）。

**这一轮 CI 的三次失败，全是这三条能查/守的东西**：
`import Orion` 漏了 → 成员插错作用域 → 删代码没删引用 + `guard let` 绑非 Optional。

---

## 8. 下一步（按优先级）

### A. 立刻（等一次真机日志）
1. **标签栏 v3 验收**：一条胶囊的形状对不对（§3.5 有预置判断）。
2. **吸顶头让位验收**：滚到听歌页最下面，看顶部那道原生底色还在不在
   （日志找 `[Shell] 吸顶头底色已收掉`）。

### B. 听歌页收尾（不再来回改，一次做完）
3. 「背景跟封面取色」改成**半透明档**（§2.3 里唯一没试过的一档）+ 记原值可还原。

### C. 音乐库（"改原生"这套流程的第二个例子）
4. 用**这次修好的探针**拿到真实 frame → 做列表行的圆角/发丝线（§5.3）。

### D. 逐屏铺（每屏 1~2 次编译，做完一屏停一屏）
5. 歌单 → 专辑 → 资料库（其余）→ 首页/搜索。**顺序与手法照 Apple 的设计规则收拾 Spotify**，
   不是逐像素复刻 AM（pw 也是这么干的）。

### ⛔ 明确不做
- morph 转场（播放器"长出"、封面"飞出"）；
- 把 Spotify 的四颗标签视图搬进玻璃容器（会打断布局与手势）；
- 像素级复刻；音频三件套；Live Activity / 锁屏。

---

## 9. 数据资产（这轮新增）

| 资产 | 用途 |
|---|---|
| 真类名（IPA `dump-9.1.86.txt` ↔ 真机 dump 双向核对） | `NowPlaying_ViewImpl.StickyHeaderViewControllerImpl`、`NavigationUI_TabBarImpl.TabBarView` / `.TabBarItemElementView`、`CreateMenu_TabBarItemImpl.CreateMenuTabBarItemView`、`YourLibrary_YourLibraryXImpl.YourLibraryView`、`Reprise_LiquidGlassKit.LiquidGlass.GradientView` |
| `[TabBarDump]` 探针（`TabBarGlassProbe.x.swift`） | 一次性摊开标签栏内部结构（只读、只打一次） |
| `[Shell]` / `[Library]` / `[TabBarPlate]` 日志 | 每个钩子自报"装上了/做了什么/还原了" |
| `bnk_from_customize_dump.py` | customize body → `.bnk` 种子（flag 那条线用） |

---

## 10. 用户定的规矩（照做）

1. **pw 的代码只看 `.md`**（`tweak/Sources/**`、`vendor/**` 一行不看），**思路可借鉴、代码自己写**；
2. **一次编译很贵** → 批量写、一轮验；
3. 每个 hook **自报日志**、开关**可撤销**、改动**幂等**、设置页**别臃肿**、
   **不做运行时类枚举**（`objc_getClassList` 崩过两次）；
4. 观感改造**只做"看着像"**，不追像素级；**别为了一个新 API 提高最低版本**；
5. 碰到"动别人视图"的诱惑时，先问：**收益是什么？能不能只读判断 + 改一次？**
6. **凡是要用户"编译 / 装机 / 发日志或照片"的，必须一次说清五件事**（用户 2026-10-02 明确要求）：
   ① **构建怎么出**：哪个 workflow、哪些构建开关（例如 `liquid_glass` 勾不勾）；
   ② **设置页开哪几个开关**：写全路径 + 默认值，**不许只说"打开相关开关"**；
   ③ **装完点哪些地方**（最小动作集，要保证那行日志真的会被打出来）；
   ④ **发什么**：日志文件名 + 要截的图（截哪一屏、竖横屏、要不要含上下文）；
   ⑤ **我到时候看哪几行日志**——把**预期会出现的行先写出来**，对不上就知道是哪一步没跑。
   反面教材：§8 A2「吸顶头让位验收」只写了"滚到最下面看日志"，没写"得先开「自绘顶栏」"——
   而日志 20 里 `header=OFF`，用户照着做根本触发不了。

---

## 11. 续（2026-10-02 白天）：日志 20 到手 → v3 判死、v4 已写

**入口仍是本文**。这一节只写：日志 20 证明了什么、代码改成了什么、下次看什么。
（顺带：`STALE_AUDIT.md` 是"哪些功能已经过时"的清单 + 一个可复跑的审计工具。）

### 11.1 日志 20 是真探针的第一份：v3 的**位置**错了 15pt

`[TabBarDump]`（探针修好后第一次拿到真 frame）↔ 同一份日志的 `[Tree]`，两条来源逐字对上：

| 项 | 真机数值 |
|---|---|
| 栏 `TabBarView` | 414×83 @ 窗口 (0,813)；窗口 414×896（底部安全区 34） |
| 图标行 `UIStackView#tabs-container-view-identifier` | **414×49 @ 栏内 (0,0)** |
| 每颗的内容（`Encore.IconView` / `Encore.Label`） | 图标 `(40,5 24x24)`、文字 `(41,33 22x15)` → **内容带 y=5..48** |
| v3 铺的玻璃 | `UIVisualEffectView(8,6 398x71)` r=35.5 → **6..77，中心 41.5** |

⇒ **胶囊中心比图标内容低 15pt**。照片 22 上就是三个现象：图标顶(5) 比胶囊顶(6) 还高 1pt、
文字底(48) 以下挂着 **29pt 空玻璃**、胶囊底(77) 离屏幕底只剩 6pt —— 整条"沉"在下面，浮不起来。

（照片 22 按 2.0px/pt 独立复测过：栏顶边 y=15、胶囊 27..169、图标 25..73、文字 83..115 —— 与 dump 完全一致，
所以这不是推测。）

### 11.2 层序也错了：§3.5 的预判命中

v3 插在 `TabBarView.subviews[0]` → 正好在 `TabBarCompactView` **之下**；
而 CompactView **自带一层 `CAGradientLayer`**，是画在我们玻璃**之上**的。

### 11.3 v4 已写进 `Sources/EeveeSpotify/Appearance/TabBarGlass.x.swift`

| 项 | v4 做法 |
|---|---|
| 锚点 | 找 id `tabs-container-view-identifier` 那条 stack，取里面**可见内容**的并集（跳过 hidden / alpha≈0 / 0×0；`Encore.Label` 底下那个 0×0 的 `UILabel` 不算，否则它 `22x15` 的框会被孩子吃掉）→ 真机是 `5..48` |
| 摆位 | 以内容带为心、上下各留 `verticalPadding`（=5）→ **`(8,0 398×53)` r=26.5**：上留 5、下留 5、底边离屏幕 30pt，且**不越出栏** |
| 层序 | `host.insertSubview(plate, belowSubview: stack)` → 原生渐变在玻璃下面、图标在玻璃上面 |
| 日志 | frame 变化时打（最多 6 条）：`[TabBarPlate] 胶囊 (8,0 398x53) r=26.5 ← 图标内容带 (0,5 414x43) [栏 414x83] 插在 TabBarCompactView 里` |
| 旋钮 | `verticalPadding`：5 = 贴合的 53pt；8 = 59pt、顶部压出栏外 3pt（更像照片里那种"厚胶囊"） |
| 兜底 | 找不到 stack → 图标带 = 栏高 − 底部安全区；四颗都没排 → stack 框内缩 4pt |

本机三个检查器已过：`orion_hook_guard 315` / `swift_brace_check 315` / `swift_member_check 260`。

### 11.4 两条要更正的旧说法

1. **"标签栏自带 `UIVisualEffectView`"是错的**（`NewDesignYield.x.swift` 开头那句，来自日志 9）。
   日志 20 全树 dump 里 `UIVisualEffectView` **只有我们那一块** → 标签栏**没有**系统玻璃。
   系统给的是**上面**那条：`NavigationBarPlatterContainer_v2` / `PlatterContainerHostingView` /
   `ScrollEdgeEffectView`。**别去"让位"给一个不存在的玻璃。**
2. **"吸顶头让位没验收"不是 bug**：`StickyHeaderYieldHook.viewDidLayoutSubviews` 第一行就是
   `guard UserDefaults.nowPlayingShellHeader else { return }`，而日志 20 自报 `header=OFF`
   → 整段没跑。要验收**先开「自绘顶栏」**（或把让位从那个开关里解耦）。

### 11.5 下次日志 / 照片要看什么

1. `[TabBarPlate] 胶囊 (8,0 398x53) … 插在 TabBarCompactView 里` —— 数字对不对、插对层没有；
2. 照片：图标上下各留 5pt、胶囊底离屏幕 30pt（不再"沉"在下面）；
   嫌**太细** → `verticalPadding` 5→8，一行改；
3. 形状若"廉价" → 按 §3.5 的老判断：加淡描边高光，**不改结构**。

---

## 12. 续（2026-10-02 下午）：v4.1 自愈 + "整库变黑"的诊断口

### 12.1 照片 24 / 日志 21：首次进入那条 16pt "小棍"（**已修**，v4.1）

真机那一行：

```
[TabBarPlate] 胶囊 (8,67 398x16) r=8.0 ← 图标内容带 (inf,inf 0x0) [栏 414x83]
```

- **根因**：第一次布局时这条栏**还没进窗口** → 所有 `convert(_:to:)` 返回 `CGRectNull`
  → 内容带 `(inf,inf 0x0)` → `height = max(16, 0 + 10) = 16`、`midY = inf` 被夹到底边
  → `(8,67 398x16)`：一条贴在栏底的小棍。
- 自愈只能等**下一次布局**：日志 21 里那一次隔了 **22 秒**（用户点了一下别的标签）。
  正常后是 `(8,0 398x54) r=27.2 ← 图标内容带 (40,4 342x44)`。
- **v4.1**：`isUsable()` 四条护栏（有窗口 / 非 null / 非 inf / 高 ≥ 20）→ **不可信就先不画**；
  外加 12×0.1s 的**有界**重试（到点打一行日志收手，**不做常驻轮询**）。

### 12.2 "忽然整库变黑、听不了歌"：先分清是服务端还是我们

| 候选 | 机制 | 变黑时同时能看到什么 |
|---|---|---|
| **H1 地区/IP 与账号国家不一致** | 可播放性是**服务端**按会话地区算的 | 界面仍是高级档、**没有广告**、歌全灰；换代理/换配置就好 ← 与用户描述最吻合 |
| **H2 我们的 premium 伪装漏了一次** | 应用退回免费档 → 全库不可点播 | **广告回来了**、Premium 徽章没了 |
| **H3 账号被风控** | 官方客户端也会发生的现象（Reddit 那批） | 同 H1 |

**已加的口子**：`passiveLogProductState`（`[REVERT_WATCH][setOriginal] ads=… on-demand=… country=…`）
原先**只走 `NSLog`**，导出的 `eeveespotify_debug_shared*.log` 里根本看不到；
现在**同一行也进导出文件**（`writeDebugLog`，脱敏照过一遍）。
变黑那一刻只看 `ads=` / `on-demand=` / `unrestricted=` / `player-license=` / `catalogue=`
有没有被改回去，就能把 **H2** 与 **H1/H3** 分开。

### 12.3 ★「覆盖配置」= 整体替换成随包 Premium 快照（用户澄清，2026-10-02）

用户说的"覆盖配置"是**补丁页**那个开关（`UserDefaults.overwriteConfiguration`，
见 `EeveePatchingSettingsView.swift`）。它在 `DynamicPremium+ModifyingFunctions.swift:12-28` 里做的是：

```swift
if ServerSidedFeaturePolicy.shouldOverwriteResolvedConfiguration(requested: overwriteRequested) {
    configuration.resolve.configuration = try! BundleHelper.shared.resolveConfiguration()
}
```

⇒ **开它 = 用随包的 Premium 配置快照整体替换服务端下发的配置**（关着时只做定点改写）。

**这条把"整库变黑"的归因基本定了**：用户"开覆盖配置就正常"
⇒ 问题在**配置/产品状态**这一层（H2），不是网络出口地区（H1/H3 降权）。
旁证：同文件第 787 行原话 —— `// audio-quality left unforced: Very High fails to stream
on a free entitlement.` —— "免费账号请求了它给不了的音质 → 放不出来"是**已知**失败类型。

下一步要做的（不是让用户手动开开关）：
1. `[REVERT_WATCH]` 进导出日志（**已做**，§12.2）→ 先拿到"变黑那一刻是不是掉回免费档"的铁证；
2. 再决定是"关键项永远强制"、"加一个 watchdog：掉回免费档就重打一遍"，
   还是"默认打开覆盖配置"。

### 12.4 用户已选定：照片 23 的效果 = **可拖的玻璃「透镜」（A 版）**，下一轮做

用户要的是照片 23 那种"**可以拖动 + 真实物理反射**"。可行性核对（API 依据）：

| 要素 | 系统能力 | 结论 |
|---|---|---|
| 真实折射/彩虹边 | `UIGlassEffect` 的**本体行为**（我们那条胶囊已经在用） | ✅ 强弱取决于背后内容对比度与**形状的厚圆程度**（大而扁的胶囊折射弱、小而圆的强） |
| 可拖动 | 自己的视图 + `UIPanGestureRecognizer` | ✅ 只能拖**我们自己的玻璃** |
| 按下回弹/"物理感" | `UIGlassEffect.isInteractive`（iOS 26+，运行时反射） | ✅ |
| 拖动时形变/融合 | SwiftUI `GlassEffectContainer` + `glassEffectID`；UIKit 侧 `UIGlassContainerEffect` | ⚠️ 能做，但要么 SwiftUI 承载、要么自己写形变 |

**三条硬限制（写死在这里，动手前必读）**：
1. **可拖的不能是 Spotify 的标签栏本体** —— 那是"动别人的视图"，会打断布局与手势；
2. 拖到图标上方会**吃掉点击** → 必须"松手弹回 / 拖动时触摸穿透 / 只在实验区里拖"三选一；
3. **玻璃不能叠玻璃**（Apple 硬规矩）→ 可拖玻璃与标签栏那条胶囊**不能重叠**，重叠时让一条让位。

A 版定义：一颗 ~96×96 的圆角玻璃块，拖到哪折射到哪、松手弹回，设置页里一个**默认关**的开关。
B（胶囊跟手）/ C（拖动切换标签）**本轮不做**，C 因为要驱动 Spotify 私有选中态、风险最高。
**本轮编译不带它** —— 先验 v4.1 与 `[REVERT_WATCH]`，变量最少。

---

## 13. v4.2：收紧四颗 + 玻璃改"贴着那一行"（2026-10-02，用户反馈）

用户看完照片 25（浅色参考图：玻璃轨道 + **房子是实心黑、另外三个描边白**）提了三件事：

| 用户说的 | 处置 |
|---|---|
| **"四个图标之间距离太大，想收紧"** | `tightenRow`：`tightenFactor = 0.20`，用 **`transform`** 把四颗往中心收（外两颗各 ~31pt，间距 103.5 → **82.7pt**） |
| **"液态玻璃的展示高度（长方形的高度）有点低"** | 胶囊改成**贴着图标那一行**：宽 = 内容带宽 + 左右各 20（上限"栏宽−16"），高 = 内容带高 + 上下各 **8** → 推算 **`(51,-4 311x60)` r=30**（原来 398×71，5.6:1 → 5.2:1），底边离屏幕 29pt |
| **"房子那一栏图标和别的不一样，要不要也加上"** | ⏳ **先取证**：`TabBarGlassProbe` 新增只读探针 `[TabBarSel]`（每次启动一行/颗：`accessibilityTraits`（含 `selected` 位）、item/图标/文字的 `tintColor`、图标 `renderingMode`）。拿到"哪一颗被选中"的可靠信号后，再决定要不要画**我们自己的选中胶囊**（深/浅随主题），跟着选中项滑 |

### 13.1 ⚠️ "收紧"为什么用 transform（这条要守住）

- transform 是**渲染期位移、不参与布局** → Spotify 的布局回合不会把它算掉，不需要每帧重写
  （那正是文档里禁止的事），也不会像"挪别人的视图"那样打断布局与手势；
- 代价：这些视图的"视觉位置"与"布局位置"分开了 ⇒ **凡是反过来量它们位置的地方一律用
  `convert(_:to:)`**（会算上 transform）；
- **算"往中心收多少"必须用 `item.frame.midX`**（布局位置，不受 transform 影响）——
  用 `convert(item.center)` 会把自己上一轮收进去的量再算一遍，越收越拢（写成死循环式的收敛偏移）；
- 幂等 + 可撤销：值没变不写，`tightenFactor = 0` 即恢复 `.identity`；
- **只在 `stack.subviews.count == 4` 这个已知形状上生效**（形状一变就不动）。

### 13.2 逃生门

"收紧"没有单独开关，**跟着「标签栏玻璃」那个开关走**（关掉玻璃 = 四颗恢复原位）。
理由：收紧本来就是为这条玻璃服务的，多一个开关只会让设置页更臃肿。
本地化文案（`tab_bar_glass_description`）已同步改 zh-CN / en；其余 25 种语言还是旧文案
（说的是"位置不变"），要跟进得另开一轮批量翻译。

### 13.3 下次日志要看的

```
[TabBarPlate] 胶囊 (51,-4 311x60) r=30.0 ← 图标内容带 (71,4 271x44) [栏 414x83] 插在 TabBarCompactView 里
[TabBarDump]  ---- 标签栏内部结构 begin（bar 414x83）----      ← 结构没变
[TabBarSel]   ---- 选中信号 begin（4 颗对比着看）----          ← 哪一颗被选中的判据
```

---

## 14. v4.2 真机验收（日志 23 + 照片 26/27）+ 两个新结论

### 14.1 v4.2 生效 ✅

```
[TabBarPlate] 胶囊 (43,-3 312x60) r=30.0 ← 图标内容带 (63,5 272x44) [栏 414x83]   ← 首次
[TabBarPlate] 胶囊 (46,-3 323x60) r=30.0 ← 图标内容带 (66,5 283x44) [栏 414x83]   ← 稳定后
```

- 胶囊从 **398×71（5.6:1）→ 约 320×60（5.3:1）**：更短、更厚 ✓（照片 26/27 与日志一致）；
- 内容带从 **342 宽 → 272~293 宽** ⇒ `tightenRow` 的 transform 真的生效，而且**是在量之前跑的** ✓；
- v4.1 的护栏也验证了：结构 dump 那一刻 `#4 UIVisualEffectView frame=(0,0 0x0) hidden`
  —— **几何没准备好时它就是不画**，再也没有那条 16pt 小棍 ✓。
- 顺带看到一次 `[栏 414x49]`（没有底部安全区的那一帧，估计是转场），胶囊跟着变 322×57 ✓ 没出错。

### 14.2 ★「哪一颗被选中」的判据（`[TabBarSel]` 第一次真机数据）

```
[TabBarSel] item=? traits=0x0 itemTint=#0091FF/1.00 label(UILabel)text=#FFFFFF/1.00   ← 选中（主页）
[TabBarSel] item=? traits=0x0 itemTint=#0091FF/1.00 label(UILabel)text=#B3B3B3/1.00   ← 未选中 ×3
```

- `accessibilityTraits` 四颗全是 `0x0` → **没有 `selected` 位，这条路不通**；
- `itemTint` 四颗都是 #0091FF → **不通**；
- **`UILabel.textColor`：选中 = `#FFFFFF`，未选中 = `#B3B3B3`** → ✅ **这就是判据**。
- 另：`item=?` 是因为 id 挂在**更里面那层** `TabBarItemElementView` 上，stack 的直接子视图是
  `ElementContentView`（没 id）——下次要拿 id 得往里走一层。

⇒ 想画"选中胶囊"（照片 21 的深色药丸 / 25 里房子背后那块亮底）**现在有可靠信号了**：
按 item 找它的 `UILabel.textColor`，接近白的那一颗就是选中项；用 0.5s 复查 + 变了才写那套节拍
去挪我们自己的胶囊即可。

### 14.3 「节省流量模式」突然自动开启：谁开的

**结论：是 Spotify 自己的功能，不是插件"打开"的**（但有一条间接关联，见下）。

- 9.1.86 里确实有这套东西（IPA 字面量表）：
  `ios-datasaver-automatic-impl` → `enabled` / `event_logging_enabled` / `messaging_enabled`，
  以及 `ios-feature-datasaver` → `dynamic_data_saver_stream_quality` / `enable_local_override`、
  `ios-feature-nowplayingbar` → `data_saver_tooltip`、`ios-settings-connectivitypageplugin-impl`
  → `show_data_saver_multiple_choice_item`。
  ⇒ **"自动数据节省"是 Spotify 的服务端实验**，由它按网络状况/分组自行开启。
- 全仓库 grep：`datasaver|data_saver` **一处都没有** ⇒ 我们的代码没有碰过它。
- 但服务端 customize 体里就有网络相关字段（日志 23 第 188 行那条 `[PreRelease] HIT` 上下文里
  能看到 `core-bitrate` 与 `net_fortune_*`）⇒ Spotify 是**按"网络运气"测量**决定要不要省流的，
  走代理/VPN 时测量结果差，很容易被它判定该省流。
- **唯一可疑的间接关联**：我们改写了产品状态字典里的 `streaming-rules`（置空）与 `high-bitrate=1`
  （`EeveePremiumForce.x.swift:38-40`、`DynamicPremium+ModifyingFunctions.swift:766`），
  而作者自己留过一行注释：**"Over-seeding caused greyed-out tracks (streaming-rules mismatch)"**
  —— 这块动过就会出灰歌。数据节省和它是同一个"音质/带宽"家族，所以**不能 100% 排除我们这边**。

**怎么定性（现场）**：它自动开启的那一刻导出日志，看两处 ——
1. 有没有 `[Flags] replacement …datasaver…`（**没有这行 = 不是我们改的**）；
2. `[REVERT_WATCH][setOriginal] …` 里 `type/product/on-demand/streaming-rules` 有没有变。

**怎么关掉（零代码）**：设置 → 扩展功能 → Flag 覆盖 → 添加
`name = enabled`、`scope = ios-datasaver-automatic-impl`、写入指定值 → `false` → 重启 Spotify。
（想连本地覆盖一起放开：再写 `ios-feature-datasaver.enable_local_override = true`。）
**要"永久关"**：在 `propertyReplacements` 加一行 `.forceBool(false)`（服务端没下发也会追加）。

---

## 15. v4.3：胶囊 + 四颗可以拖着走，松手弹回（2026-10-02，用户要求）

用户要的是"**胶囊和选项可以拖动 + 照片 23 那种真实物理反射**"。已实现：

| 部分 | 做法 |
|---|---|
| 拖动 | `UIPanGestureRecognizer` 装在**栏**上；拖动时**玻璃 + 四颗一起走**（图标继续走 `transform`，玻璃走我们自己的 frame） |
| 不吃点击 | `cancelsTouchesInView = false`、`delaysTouchesBegan = false`、与别的识别器**并行**（`shouldRecognizeSimultaneouslyWith → true`） |
| 什么时候认 | `gestureRecognizerShouldBegin`：**明显横向**（`|vx| > 1.5|vy|` 且 `|vx| > 80`）才开始 —— 竖滑列表/点击标签都不受影响 |
| 范围 | `dragLimit = ±70 / ±24`（**故意小**：这是"推一下看它折"，不是"把栏搬走"—— 搬走会撞安全区、迷你条、系统手势） |
| 松手 | 0.5s 弹簧（damping 0.72）弹回原位；**回弹过程里折射一直在动**，"液体"手感就来自这里 |
| 真实折射 | 本来就是系统 `UIGlassEffect`（动起来才看得出来）；另**探测式**打开 `UIGlassEffect.isInteractive`（按下弹性反馈） |

### 15.1 三条实现纪律（都写进代码注释了）

1. **量内容带时必须 `includeDrag: false`** —— 否则拖动量会被量进内容带、之后再加一次（算两次）；
2. `isInteractive` 只在这两个 selector **都在**（`isInteractive` + `setInteractive:`）时才走 KVC ——
   KVC 碰未知 key 会抛异常（崩），所以必须先探；
3. ⚠️ **`UIView.animate` 的 `animations:` 是 escaping 闭包、不继承 actor 隔离** ——
   里面直接调 `@MainActor` 的 `apply` 是编译错，必须套仓库既有的 `onMainThreadSync`
   （这次编译前自查抓到的，见 `endDrag`）。

### 15.2 逃生门与旋钮

- 逃生门：拖动**跟着「标签栏玻璃」那个开关**走 —— 关掉玻璃 = 拖动/收紧/胶囊一起停（不留尾巴）；
- 旋钮（一行）：`dragLimit`（范围）、`endDrag` 的时长/阻尼（手感）、`tightenFactor`（收紧程度）。

### 15.3 下次日志要看的

```
[TabBarPlate] 拖动已装（±70/±24pt，松手弹回）
[TabBarPlate] UIGlassEffect.isInteractive = true（按下会回弹）
[TabBarPlate] 胶囊 (…,-3 3xx x60) …        ← 拖动过程中这行会随位移变化
[TabBarSel]   item=TabBar.Item.主页 …       ← 这次 id 应该不再是 "?" 了
```

**没做的**：把整条栏拖到屏幕别处（会撞安全区/迷你条/系统手势，故意不做）；
"选中胶囊"还等用户定样式（判据已拿到：`UILabel.textColor` 白=选中 / 灰=未选中）。

---

## 16. 三个"已经没用"的功能就地删除（2026-10-02，用户确认）

判据来自**日志 23 的真实行为**（不是猜的）：

| 功能 | 日志 23 证据 | 结论 | 处置 |
|---|---|---|---|
| **深色栏底色**（AMOLED） | `[AMOLED] installed (enabled=OFF)` + `[NewDesign] … active=yes` | 新设计下 `strip()` 第一件事就是让位 → **纯空操作** | ✅ 删文件（420 行）+ 设置开关 + `amoledEnabled` + Tweak 激活 |
| **背景跟封面取色** | `backdrop=ON`，但 `isBackdropOpaque = false` 在 `LyricsBackdropArtworkView` 里 = **整块透明** | **视觉上等于没做**（假开关） | ✅ 删设置开关 + `nowPlayingShellBackdrop` + 壳里那一层（视图/约束/刷新/两处日志） |
| **顶部大标题**（旧"样品"） | 日志 23 无 `[MusicStyle]` 行（用户关着）；代码上它是**另一套**标题，与壳的顶栏标题重复 | **重复**（两个都开就画两遍） | ✅ 删文件（135 行）+ 设置开关 + `musicStyleNowPlaying` + `applyNowPlayingAppearance` 里那次调用 |
| **AM 式头部**（音乐库大标题） | `[Library] 大标题已换成 AM 档：24pt → 30pt` ✅ | **有效** | 保留 |

**净效果**：11 个文件、**−336 行**；三个检查器 310/310/255 全过；
`LyricsBackdropView` 仍被歌词页用着（不是孤儿类）。

### 16.1 ⚠️ 删 AMOLED 时**必须**一起搬走的东西

AMOLED 的导航栏遍历是**运行期"新设计"兜底信号**的唯一观察者
（`NewDesignLanguage.noteObservedNewDesign()`）。删掉它 = 以后 iOS 若忽略
`UIDesignRequiresCompatibility`，我们会判错、把旧设计补丁重新叠到玻璃上。
→ 已搬到 `NewDesignYield.observeNewDesignMarkersIfNeeded`：
只在"构建意图说兼容"时扫一次，在**已经在走的子树**里认 `Platter` / `ScrollEdgeEffect`
（不做运行时类枚举 —— 本仓库为 `objc_getClassList` 崩过两次）。

### 16.2 ⚠️ 下次装机要顺眼看一眼的副作用

壳的**顶栏**还在（用户开着 `header=ON`）。背景那层删掉之后，
**原生那颗 ⌄ 理论上又能看见/能点了** —— 而我们还自绘了一颗 ⌄。
装上后看一眼顶栏是不是**两颗 ⌄ 叠着**；是的话我下一轮把自绘那颗去掉（或改成只在原生不可见时才画）。

---

## 17. v4.4：修「创建 偏了」+ 借 MeloX 的描边高光（2026-10-02）

### 17.1 真凶：两个坑叠出来的 +41（照片 28 / 日志 24）

日志 24 的 `[TabBarDump]` 里四颗的 frame 是 **41 / 145 / 248 / 352** —— 整齐地 +41。
对照日志 21（v3，没有收紧）是 0 / 104 / 207 / 310 ⇒ **四颗被一视同仁地推了 +41**，
而收紧本该是"两端各向内 31、中间各 10"。第 4 颗「创建」本该 −31 却拿到 +41，
**差 72pt** —— 这就是照片 28 里那颗明显偏右的原因。

两个坑：

1. **首次布局时 `stack.bounds.width == 0`**（内容还没排）。v4.2/v4.3 是用
   `item.frame.midX` 算"离中心多远"的，那时四颗全是 0 → `(207 − 0) × 0.2 = +41.4`
   → 四颗全被推到 +41 ✓ 与 dump 完全吻合。
2. **`frame` 在 transform 非恒等时的语义是"未定义"**（Apple 明文）。实测它会**带上我们
   上一轮写进去的位移** → 下一轮又按"已经被挪过的位置"再收一次 → 收敛点整体偏移，
   而且**两端最明显**。v4.2 的注释里我写的是"frame 不受 transform 影响" —— **那句是错的**，
   已在代码里改正。

**v4.4 的修法**：

- 中心改成**等分布局推算**：`stack.bounds.width × (i + 0.5) / 4`，再经 `stack.convert` 到栏坐标系
  —— **完全不读任何可能被 transform 影响过的值**；
- 加一道闸：`stack.bounds.width > 100` 才算，否则这一轮什么都不做
  （`apply` 那边的有界重试会把我们叫回来）；
- 效果：四颗的位置**必然对称**，冷启动第一帧就对，不再需要"划掉再进"来纠正。

### 17.2 借 MeloX 的一手：边缘描边高光

看 `C:\Users\ngzhwm\Documents\GitHub\MeloX` 的结论：

| MeloX 的做法 | 我们能借吗 |
|---|---|
| `TabView { Tab(…) }` + iOS 26 → **整条玻璃胶囊、选中态、`.tabBarMinimizeBehavior(.onScrollDown)` 收起、`.tabViewBottomAccessory`** 全是**系统的** | ❌ 借不了：Spotify 的标签栏不是系统 TabView，只能自己拼 |
| `.glassEffect(.regular.interactive(), in: .capsule)` / `.clear.interactive()` | ✅ 已借（`UIGlassEffect` + `isInteractive`） |
| `GlassEffectContainer(spacing: 10/14)` 让多个玻璃元素融合 | ❌ 借不了（四颗是 Spotify 的视图） |
| 旧系统兜底：`Capsule().stroke(.white.opacity(0.32), lineWidth: 0.75)` | ✅ **已借**：胶囊加了一圈 **0.75pt / 白 22%** 的描边高光（`UIGlassEffect` 自带边缘高光，深色内容上不够） |

⚠️ 记住这个前提：**照片 21/23/25 那种"整条玻璃 + 选中胶囊"是系统 TabView 画的**，
我们是在别人的标签栏上"拼"出来的 —— 所以永远会比系统版多做工、少几分自然。

---

## 18. 看 spoti.pw 的 `.md`（红线内）+ v4.5「隐藏标签文字」（2026-10-02）

### 18.1 pw 是怎么做的（**只读 `.md`**，出处都列了）

| pw 的做法 | 出处 | 我们 |
|---|---|---|
| 新设计限 iOS 26+，**用系统的 `UIGlassEffect`**，旧系统退 blur | `docs/tweaks.md:48-49` | ✅ 一样 |
| **真玻璃放在 Spotify 自己渲染的视图后面**（`live glass behind Spotify's rendered stand-ins`） | `CHANGELOG.md:115` | ✅ 一样 |
| `Redesigned/Navbar/TabBar.x` 自己组标签栏，**让 Spotify 给玻璃 bar 留出高度** | `docs/tweaks.md:166-169` | ⚠️ 我们相反：把胶囊塞进 83pt |
| **强制 Spotify 自己那套玻璃设计的 flag**（`SGRGlassDesign.x`） | `docs/tweaks.md:163-164, 289-292` | ⚠️ `mode` 实测无效（已记录） |
| **accent / repaint 钩子**统治配色（选中态靠它） | `harness/tabbar/README.md`、`docs/tweaks.md:164` | ❌ 未做（选中判据已拿到） |
| **「Hide labels」** | `docs/tweaks.md:300` | ✅ **v4.5 借来**（见下） |
| 布局常数：**49pt 行 / 83pt 玻璃 bar / platter 比 mini 条低 8pt** | `harness/tabbar/README.md:20-43` | ✅ 与我们实测完全一致 |
| AMOLED 黑**总是开着** | `docs/tweaks.md:164` | — 我们刚删（新设计下空操作） |

**结论**：pw 也不是"系统白送"，而是"系统玻璃 + 自己在后面拼" —— 和我们是同一条路，
只是他们多做三件：**隐藏标签文字**、**让 Spotify 给玻璃留高度**、**accent/repaint 钩子**。

### 18.2 v4.5：隐藏标签文字（默认开）

- **开关**：扩展功能 → 标签栏 →「隐藏标签文字」，默认 **开**；
- **顺带的收益**：内容带从"图标 + 文字 44pt"变成"只有图标 ~24pt" ⇒
  胶囊自动收到 **~40pt**（照片里的比例），图标仍然居中 —— "玻璃太扁"这条顺手解决；
- **实现**（`TabBarGlass.x.swift`）：
  - 在**量内容带之前**处理（`collectContent` 会自然跳过被隐藏的视图）；
  - 只认类名 `SPTEncoreLabel`（**不做运行时类枚举** —— 崩过两次）；
  - **只还原我们自己藏过的**（关联对象打标），不去猜 Spotify 为什么藏；
  - **写回计数 + 12 次上限的保险丝**：真被 binder 反复写回就停手并打日志（宁可保持原生）；
- **本地化**：`tab_bar_hide_labels` 已批量补进 **27 个语言**（zh-CN/zh-TW 中文，其余英文待翻）；
  bundle 由 CI 从 deb 里抽出来塞进 IPA（`build-ipa-with-orion*.yml`）✓。

### 18.3 下次日志要看的

```
[TabBarPlate] 标签文字已隐藏（4 个）              ← 生效
[TabBarPlate] ⚠️ 标签文字被反复写回 N 次 …        ← 如果出现，说明 binder 在跟我们抢（那就保持原生）
[TabBarPlate] 胶囊 (…,-3 32x x40) …              ← 高度应该从 60 掉到 ~40
```

---

## 19. v4.6：胶囊高度恒定 + 图标垂直居中 + 删掉拖动（2026-10-02，用户反馈两条）

用户原话（照片 29 = 现场；日志 25 = 那一轮的日志）：

> 1. 在点击「创建」功能并且开启「隐藏标签文字」后，液态玻璃会被拉高（我觉得无论此开关开启或关闭，
>    液态玻璃的高度都是在有文字时候的高度比较好）。
> 2. 另外，原本应该是不可滑动的导航栏（就是上面在说的那个）会在某个页面里允许滚动。

用户的处置选择（本次会话问过，用户拍板）：
**问题一 = 固定成"有文字时"的高度（≈60pt）+ 四个图标在这一行里垂直居中**；
**问题二 = 底栏玻璃胶囊"能被拖着走"这件事，去掉拖动**。

### 19.1 问题一：病根是「创建」那颗的白色圆底被算成了内容

四条独立来源互相咬合（**不是猜的**）：

| 来源 | 读数 |
|---|---|
| 日志 25 `[Tree]` #1–#3 | `UIVisualEffectView@51,-3,312,40` → 高 **40** |
| 日志 25 `[Tree]` #6 起（「创建」点开之后） | `UIVisualEffectView@51,-3,320,56` → 高 **56**、宽 +8 |
| 日志 25 `[TabBarDump]` #30 | `UIView frame=(32,4 40x40) bg=#FFFFFF a=1.00 corner=20.0 alpha=0.00` ← 「创建」那颗的白色圆底 |
| 照片 29 逐像素（PIL 扫列） | 胶囊 324…434px = **55pt**；图标中心比胶囊中心**高 8pt**（图标 343…384px） |

机制：v4.5 的胶囊尺寸来自 `contentBand` = **看得见的内容**的并集。文字藏着时带子只有
图标 24pt（→ 胶囊 40pt）；一按「创建」，那颗 40×40 白色圆底 alpha 0→1 就被并集收进去
→ 带子 **24 → 40pt** → 胶囊 **40 → 56pt**（宽也 +8pt，因为圆底比图标宽）。
图标没跟着动 → "玻璃高了一块、图标还挂在上面"。**文字开着的时候看不出来**：
那时带子是"图标 + 文字 44pt"，40pt 的圆底塞在里面不改变并集 —— 与用户"只在开了隐藏标签文字后出现"的描述完全一致。

### 19.2 修法（v4.6）

1. **另起一套量算**（`contentBands`）：只认两类节点 —— 图标（类名含 `EncoreIconView`）
   与文字（含 `EncoreLabel`）。白色圆底那种装饰天然不算内容；文字**藏没藏都算**
   （藏起来时 frame 仍然有效，真机 dump：`SPTEncoreLabel frame=(41,34 22x16) hidden`）
   → 量出来的**永远是有文字的版式**：与「隐藏标签文字」开关、与「创建」选中与否都无关。
2. **量算改读布局几何**：`layer.position` / `bounds`（CALayer 的 `position` 是布局位置，
   transform 绕 anchorPoint 施加、不动它），子树内部 `node.convert(node.bounds, to: item)`。
   为什么要换：v4.4 已经栽过一次（`frame` 带着我们上一轮写进去的位移）；v4.6 又要往
   transform 里加**纵向**位移，用老量法就会变成"胶囊跟着一起往下漂"。
3. **图标垂直居中**：`dy = 有文字带.midY − 图标带.midY`（真机 ≈ **+10.5pt**）。
   两个带子同时被 dy 平移 → 相减之后 dy 自己消掉：这是**常量**，一次算准、不自我反馈。
   有文字时 dy = 0（Spotify 自己的"图标 + 文字"版式本来就填满那条带子）。
4. **拖动整段删除**（见 19.3）。

按日志 25 的真数据推算，验收日志里应当**逐字**出现这一行（同值即为通过）：

```
[TabBarPlate] 胶囊 (51,-3 312x61) r=30.5 ← 有文字带 (71,5 272x45) 图标带 (71,5 272x24) dy=+10.5 [栏 414x83] 插在 NavigationUI_TabBarImpl.TabBarCompactView 里
```

（`r=` 是 `height/2` ⇒ 61pt → 30.5；`report` 的上限从 6 条放宽到 **10 条**，
免得像日志 25 那样"刚好看不到后面的状态"。）

### 19.3 问题二：拖动删掉（按下回弹保留）

用户选的是"底栏玻璃胶囊在创建页里能被拖着走"这一条。日志 25 的现场：
`[Tree]` #4 `UIVisualEffectView@75,21,312,40` + 四颗 `ElementContentView@55,24 …`；
#5 `@39,0` + `@19,3` —— 胶囊和四颗一起被拖到 **y=-27**（正好是 `dragLimit.height = 24` 的极限）。

v4.3 那一套（pan 手势 / `dragOffset` / `dragLimit` / `TabBarDragTarget` /
`updateDrag` / `endDrag` / 回弹动画）**全部删除**；
`UIGlassEffect.isInteractive`（按下回弹）**保留** —— 那才是"液态"的手感来源。
要恢复成"只能横推"的话：把那套加回来、把 `dy` 恒置 0 即可（`tightenRow(_:in:dx:dy:)` 的接口已经留好）。

### 19.4 这一版改了什么（1 个文件，本机检查器全过）

| 文件 | 改动 |
|---|---|
| `Sources/EeveeSpotify/Appearance/TabBarGlass.x.swift` | 新增 `tightenOffsets` / `contentBands` / `collectBandNodes` / `rowShiftForIcons`；`tightenRow(_:in:dx:dy:)`（原 `includeDrag` 参数去掉）；`report` 增加"图标带 + dy"并把上限 6→10；**删除拖动整套**；`contentBand` / `collectContent` 降级为**兜底**（类名对不上或四颗还没排时走它，行为与 v4.5 一致） |

自检：`orion_hook_guard.py` OK（309 文件）/ `swift_brace_check.py` OK（309）/
`swift_member_check.py` OK（254）/ `l10n_lint.py --locale en|zh-CN --quiet` 无输出（**没动文案**）。
本地编译仍然不可能（无 Mac）→ 编译只走 CI。

### 19.5 日志 26 要覆盖的清单（**一次装机 + 一份日志**验完两条）

**① 哪个 workflow / 哪些构建开关**：`.github/workflows/build-ipa-with-orion-patched.yml`
（`workflow_dispatch`），**`liquid_glass` 保持默认 `true`**（本地脚本等价物：`ALLOW_LIQUID_GLASS=1`）。
不需要任何 Flag 覆盖。

**② 设置里开哪几个开关**（写全路径）：
- 设置 → EeveeSpotify → 调试 → **开启日志记录**、**转储视图树**（两个都要开）；
- 设置 → EeveeSpotify → 扩展功能 → **标签栏**：**「标签用液态玻璃」开**、**「隐藏标签文字」开**（默认就是开）；
- 其余开关随意（本次不验）。

**③ 装完点哪些地方**（按顺序，中间**别重启** Spotify，转储器一次启动只有 20 份）：
1. 冷启动 → 在**主页**停 2 秒（这里是基准：胶囊高度应当是 61、图标居中）；
2. 点**「搜索」**、点**「音乐库」**各停 2 秒（确认高度不随页面变）；
3. **点「创建」**（会弹出"歌单 / 共建歌单"那张卡）→ 停 3 秒 —— **这一步就是问题一的现场**；
4. 在**创建页里**用手指在胶囊上/旁边划两下（上下、左右各一次）→ 停 2 秒 —— **问题二的现场**；
5. 点别的标签离开创建页 → 再回**主页**停 2 秒。

**④ 发什么**：一份导出日志（`eeveespotify_debug_shared 26.log`）+ 三张截图：
主页底栏、**创建页（含胶囊）**、以及"创建页里划过之后"的底栏。

**⑤ 我到时候看哪几行**（预期行先写在这儿）：

```
[TabBarPlate] installed (enabled=ON) …（v4.6：高度按「有文字」版式恒定、无拖动）
[TabBarPlate] 胶囊 (51,-3 312x61) … 图标带 (71,5 272x24) dy=+10.5 [栏 414x83]   ← 主页/搜索/音乐库都该是这个数
[TabBarPlate] 胶囊 (51,-3 312x61) …                                             ← 点「创建」之后**仍然是 61、不是 56**
[TabBarPlate] UIGlassEffect.isInteractive = true（按下会回弹）                    ← 回弹还在
[Tree] …12.UIVisualEffectView@51,-3,312,61                                        ← 树上也是 312x61
（不该再出现）[TabBarPlate] 拖动已装（…）                                          ← 拖动那行没了
（不该再出现）…320,56                                                             ← 宽的 320 / 高的 56 都不该出现
```

**通过判据（一句话）**：**不管在哪个标签页、点没点「创建」，`胶囊` 那一行的尺寸恒为 `312x61`；
四颗图标的 y 全程不再随页面/开关变化；栏上再也拖不动。**

### 19.6 还没做 / 记一笔

- **「选中胶囊」**（哪一颗被选中就给一颗小圆底）判据早就有（`UILabel.textColor` 白=选中 / 灰=未选中），
  样式等用户定（照片 25 那种"比胶囊亮一点的小圆底"）；本次不动。
- **标签栏"更像系统"**（放一条真 `UITabBar` / 让系统画）——§4 三条路 + 一个实验，仍然暂停。
- `TabBarRegularView` 那条只读探针（§4 路④）也没做。

---

## 20. v4.6.1：图标被顶高的真凶 —— 「创建」那颗的图标会**变大**（2026-10-02，照片 30/31/32 + 日志 26）

用户装机后的反馈（照片 30 = 正常、32 = 点开「创建」、31 = 关掉「创建」之后）：

> 30 是正常情况，32 是点击创建后的效果，可以看到剩下三个的图标高了。
> 31 是关闭创建后的效果。四个图标全部高了。

### 20.1 病根：一份日志里的两条自报，数值自己就招了

日志 26（`build` v4.6）同一台机器、同一次启动，**只差一次点按**：

| 时刻 | 自报 |
|---|---|
| 16:07:37（正常） | `胶囊 (51,-3 312x60) ← 有文字带 (71,5 272x44) 图标带 (71,5 272x24) dy=+10.0` |
| 16:07:50（点开「创建」） | `胶囊 (51,-3 317x60) ← 有文字带 (71,5 277x44) 图标带 (71,5 277x36) dy=+3.8` |

**图标带 `272x24` → `277x36`**：高度从 24 涨到 36、中心从 17 掉到 23。
同一份日志的 `[Tree] #7` 把原因写得很白：

```
#7 16.OBJC_ONLY_IconView@40,5,24,24,id=Encore.IconView      ← 主页 / 搜索 / 音乐库：24×24（三颗一样）
#7 16.OBJC_ONLY_IconView@35,7,33,33,id=Encore.IconView      ← ★「创建」那颗：菜单打开时变成 33×33！
#7 15.CreateMenuTabBarItemView@0,0,103,49,id=TabBar.Item.创建
```

v4.6 的 `dy` 是**四颗共用一个数**（`full.midY − icons.midY`）：那颗 33×33 一进来，
`icons.midY` 被拽下去 6pt → 共用的 `dy` 从 `+10.0` 缩到 `+3.8` → **另外三颗跟着被顶高 6pt**。
照片 32 逐像素量是 **7pt**，与日志完全吻合。关掉菜单后（照片 31）那一颗仍带着 33×33 的
过渡姿态，于是"四颗全部高了"。

### 20.2 修法（v4.6.1，两处）

1. **尺寸按中位归一化**（`unionNormalized`）：每块矩形都**用中位宽高重建、只保留自己的中心**，
   再求并集。于是「创建」那颗无论 24 还是 33，量出来的图标带恒为 `272x24`、
   胶囊恒为 `312x59`（v4.6 会 312 ↔ 317 跳）。位置仍跟真实中心走，不吃亏。
2. **纵向位移一颗一个数**（`rowShifts`）：基准是**每颗自己"看得见的内容"**（`visibleBand`，
   判据与老 `collectContent` 一致：`hidden` / `alpha≈0` 不算）——
   · 正常三颗：可见 = 24pt 图标 → 中心 17 → `dy = +9.5`；
   · 「创建」那颗开菜单时：可见 = 40×40 白圆底 ∪ 33×33 图标 → 中心 24 → `dy = +2.5`（圆底正中）；
   · 文字开着时：可见 = "图标 + 文字"整条 → 中心天然就是胶囊中心 → `dy ≈ 0`（不打扰原生版式）。
   于是**三个图标一动不动，圆底也居中** —— 谁也不去拽别人。

### 20.3 日志 27 的预期行（换成这台机器的真值推算）

```
[TabBarPlate] 胶囊 (51,-3 312x59) r=29.5 ← 有文字带 (71,5 272x43) 图标带 (71,5 272x24) dy=[+9.5,+9.5,+9.5,+9.5] …   ← 正常
[TabBarPlate] 胶囊 (51,-3 312x59) r=29.5 ← 有文字带 (71,5 271x43) 图标带 (71,5 271x24) dy=[+9.5,+9.5,+9.5,+2.5] …   ← 点开「创建」
```

**通过判据**：两行的 `胶囊` 尺寸**必须一样**（312x59 上下浮动 1pt 都可以），
且 `dy` 的**前三颗点开「创建」后不许变**（仍是 +9.5 上下）；只有第 4 颗会从 +9.5 变 +2.5。
三条 `[Tree]` 行也应当能对上：前三颗 `IconView@40,5,24,24`、创建那颗 `IconView@35,7,33,33`，
而四颗 `ElementContentView` 的 y 分别是 `10 / 10 / 10 / 3`（**前三颗必须一样**）。

其余流程与 §19.5 完全一样（同一个 workflow、同一批开关、同一串动作），无需改设置。

---

## 21. 迷你播放条也铺一层液态玻璃 + 两条胶囊**共用同一个高度**（2026-10-02，照片 33）

用户原话：

> 照片 33。这个迷你播放条也做成液态玻璃，然后高度，宽度什么的和下面的导航栏一样，能做吗
> （补充）选 a。但是你应该也能看出来，迷你条模块和导航栏模块，中间是有一点间隙的

### 21.1 照片 33 逐像素量出来的现场

| 元素 | 实测 |
|---|---|
| 迷你条（红色实心，封面色） | **56pt 高、398pt 宽**，左右各留 8pt |
| 两条之间 | **6.5pt 间隙**（用户特别点出：别粘上） |
| 标签栏胶囊 | **59–60pt 高、312pt 宽、r≈30**（屏幕 y 810…870） |
| 迷你条内容（视图树） | `UIView@0,0,398,56,id=SPTNowPlayingBar`：封面 40 + 歌名/歌手 250 + 连接键/播放键 88 + 底部 `382x2` 进度线 |

**宽度对不上是硬约束**：迷你条自己的内容就 398pt，塞进 312pt 得砍掉 86pt。
用户选了 **A 方案**：**等高、同圆角、同材质，宽度贴它自己的内容**。

### 21.2 这一版写了什么（4 个源文件 + 27 个语言 + 2 个新文件）

| 文件 | 作用 |
|---|---|
| `Sources/EeveeSpotify/Appearance/GlassCapsule.swift`（新） | **两条胶囊共用的一份定义**：`height = 60`（真机实测）、`cornerRadius = height/2`、`UIGlassEffect` + 0.75pt 描边高光的工厂（`wantsInteractive` 开关）。宽度**不共用**（各自贴自己的内容） |
| `Sources/EeveeSpotify/Appearance/MiniBarGlass.swift`（新） | 迷你条那条胶囊：认 `id=SPTNowPlayingBar` → 玻璃插在**它自己的 `subviews[0]`**（背景色之上、子视图之下）、**清掉封面色底**、**放开裁剪**、按内容宽 × 60 高摆位。`isUserInteractionEnabled = false`（**绝不吃点击**）。关开关**原样还原**底色与裁剪 |
| `TabBarGlass.x.swift` | 高度改用 `GlassCapsule.height`（把 `verticalPadding` 那个"胖瘦旋钮"撤了）；`makeGlassView` 改调公用工厂，**四行日志文案一字未动**（验收清单里那几行还在） |
| `DeclutterChrome.x.swift` | 迷你条的 `TouchPassthroughView` 已经被 `MiniPlayerBarHideHook` 钩住了 → **蹭它现成的布局回调**（一行 `onMainThreadSync { MiniBarGlassPlate.apply(...) }`），不新增 Orion hook（同一个类挂两个 ClassHook 是没验证过的行为） |
| `UserDefaults+Extension.swift` + `EeveeExtrasSettingsView.swift` | 新开关 `miniBarGlass`（**默认开**）+ 设置页新节「迷你播放条」；改完**当场落地**（`MiniBarGlassPlate.reconcileNow()`，与清爽那批同一招） |
| 27 × `Localizable.strings` | 3 个新键（zh-CN/zh-TW 中文，其余英文占位，与上一轮同一做法） |

**间隙**：新胶囊 60pt 高、内容 56pt → 上下各多 2pt → 两条之间 **6.5 → 4.5pt**，仍然分得开。

### 21.3 日志 27 要看的（与 §20.3 同一份日志，一次验完三件事）

```
[MiniBarGlass] installed (enabled=ON) — 迷你播放条铺一层系统真玻璃…，与标签栏同高 60、无按下回弹（不吃点击）
[MiniBarGlass] 已清掉迷你条的封面色底（关掉开关会原样还原）
[MiniBarGlass] 胶囊 (0,-2 398x60) r=30.0 ← 迷你条内容 398x56（与标签栏胶囊同高 60）；窗口里 (8,746 398x60)
[TabBarPlate] 胶囊 (51,-3 312x60) …                                  ← 下方那条还在，尺寸没变
```

**通过判据**：
1. `[MiniBarGlass] 胶囊` 那一行是 `398x60`（宽 = 迷你条内容宽、高 = 60 = 标签栏那条的高度）；
2. 窗口坐标里迷你条胶囊底边与标签栏胶囊顶边（窗口 y 810）之间**还有 ~4.5pt**；
3. 照片上：迷你条变成**半透明玻璃胶囊**（不再是实心封面色块）、封面/歌名/按钮**仍在玻璃之上**、
   点一下迷你条**照常进播放页**（这条最重要 —— 我们声明了不吃点击）；
4. 关掉「迷你播放条用液态玻璃」→ **当场**变回原来的实心封面色条。

---

## 22. v4.7.1：首帧盖不住的真凶 + 两条**等宽**（2026-10-02，照片 34/35 + 日志 27）

用户反馈三条：

> 1. 照片 34 是首次启动/第一次展示迷你条时候的样子，底下原本 Spotify 自己的盖不住。
>    开关一下那个开关，就没底了（照片 35）。
> 2. 这两个液态玻璃的长度不对，迷你条的要更宽。
> 3. 迷你条实际上还有一个展示歌曲当前播放进度的小条。这个小条怎么办？

用户的拍板（本轮问过）：
**宽度 = A「两条等宽（都是 312）」**；**进度小条 = A「保持原样，只把它对齐到胶囊的留白」**。

### 22.1 问题一：Spotify 把封面色**写回来了**（"清一次就完事"是错的）

日志 27 原文，四行就破案：

```
16:50:19  [MiniBarGlass] 已清掉迷你条的封面色底              ← 我们清掉了
16:50:20  #1 9.UIView@0,0,398,56,bg=#64204C,id=SPTNowPlayingBar   ← 它又写回来（照片 34 那块紫）
16:50:24  #2 … bg=#64204C
16:50:26  #3 … bg=#64204C
16:50:27  用户手动开关一次 → 再清一次 → #4 起树上**没有 bg** 了   ← 照片 35 才干净
```

v4.7 的写法是"关联对象挡住重复清理"（清一次就完事）—— 正好撞上仓库纪律里写过的
**"binder 写回"**坑。现在 `clearCoverColor(of:)`：

- **每次布局都跑**，值本来就是透明的就一个字节都不写（幂等）；
- 一旦发现被封面色写回 → 再清一次并**计数**（前 5 次各打一行，第 6 次起只说一次）；
- 记住"**最后一次看见的原色**"用于还原（Spotify 会随封面换色，记第一次那个是错的）。

### 22.2 问题二：两条等宽 = 把内容**等比缩到胶囊里**

日志 27 把"宽"这件事也写清楚了：

```
16:50:19  [MiniBarGlass] 胶囊 (0,-2 414x60) ← 迷你条内容 414x56    ← 首次出现时内容自己是通栏 414
16:50:27  [MiniBarGlass] 胶囊 (0,-2 398x60) ← 迷你条内容 398x56    ← 稳定后缩成 398（左右各 8）
```

两条自报说明 v4.7 的宽度是"贴内容"的 → 既**比胶囊宽不了**（内容 398 > 标签栏 312），
又会**跟着入场动画从 414 抽到 398**。用户要"两条等宽"，唯一不砍内容的办法：
**把整条内容等比缩到胶囊里**（`contentScale`，真机 `(312−16)/398 ≈ 0.74`）。

| 改动 | 说明 |
|---|---|
| 宽度来源 | `TabBarGlassPlate.capsuleWidthRatio`（标签栏那条 **宽 ÷ 栏宽**，真机 0.754）× 迷你条宿主宽 → 换设备也等宽；拿不到时兜底 `312/414`。**不再随入场动画抽动**（比例是常量） |
| 玻璃搬家 | 玻璃从"内容的 `subviews[0]`"搬到**宿主的 `subviews[0]`** —— 内容要缩放，玻璃不能再是它的子视图（否则一起缩）。层序不变：整条内容之下 |
| 内容缩放 | `content.transform = scale(0.74)`：只动 transform、**不动 Spotify 的布局**（与标签栏四颗的收紧同一纪律）；关开关回 `.identity`，无痕 |
| 宿主也不许裁剪 | 胶囊比内容高 4pt，且玻璃现在住宿主里 → 宿主的 `clipsToBounds` 也要放开并记住 |
| 进度小条 | 用户选"保持原样" → 它随内容一起缩到 ~284pt，仍在胶囊里（左右各留 ~14pt）✓ 不用额外处理 |

**副作用（说清楚）**：内容缩到 74% 后，封面 40→30、歌名/歌手小一圈、连接键/播放键 44→33、
进度线 382→284。这是"两条等宽"的代价，用户已知情并拍板。

### 22.3 日志 28 的预期行（这一轮一次验三件事）

```
[MiniBarGlass] installed (enabled=ON) — 迷你播放条铺一层系统真玻璃：与标签栏**等宽等高**（312x60）…
[MiniBarGlass] 封面色底写回第 1 次 — 已再清掉（首帧盖不住就是这个原因）     ← 有这行 = 修对了
[MiniBarGlass] 胶囊 (51,-2 312x60) r=30.0 ← 迷你条内容 398x56 缩到 0.74（与标签栏**等宽** 312、同高 60；宽度取自 标签栏那条的比例）；窗口里 (51,746 312x60)
[TabBarPlate] 胶囊 (51,-3 312x60) r=30.0 ← 有文字带 … 图标带 … dy=[+9.5,+9.5,+9.5,+9.5] …
[TabBarPlate] 胶囊 (51,-3 312x60) … dy=[+9.5,+9.5,+9.5,+2.5] …              ← 点开「创建」尺寸必须一样
```

**通过判据**：
1. 两条胶囊的 **x 与宽完全一致**（都是 `51…363`、`312`）—— 这才是用户要的"一对"；
2. 迷你条胶囊窗口 y ≈ 746…806，与标签栏胶囊顶边（810）之间**留 ~4.5pt**；
3. **冷启动第一次**看到迷你条时就**没有紫色/封面色底**（看 `[Tree]` 里 `id=SPTNowPlayingBar` 那行
   **不带 `bg=`**；如果有 `bg=`，看有没有"写回第 N 次"的日志）；
4. 迷你条内容缩小后**仍然清楚**（用户看观感）、点迷你条**照常进播放页**；
5. 关掉「迷你播放条用液态玻璃」→ 玻璃撤掉、内容**回原始大小**、封面色底**回来**。

---

## 23. v4.8：日志 28 判读 + 加宽 /「创建」被顶高 / 封面色底（2026-10-02，照片 36/37）

> 用户这一轮报了**四条**，对应 §23.2–§23.5。改动文件：
> `TabBarGlass.x.swift` / `MiniBarGlass.swift` / `DeclutterChrome.x.swift`（一行）+
> `GitHubHelper.swift` / `EeveeUpdatesSettingsView.swift` / l10n（en+zh-CN 手写、其余 25 个 locale 英文补齐）。

### 23.1 日志 28 判读：v4.6.1 / v4.7.1 哪些成立、哪两条不成立

`C:\dsh\ipa\eeveespotify_debug_shared 28.log`（5436 行 / 451 KB / 00:47:31–00:48:25，
玻璃构建 / Spotify 9.1.86 / iOS 27 / iPhone 11）。

| 项目 | 日志 28 的证据 | 判定 |
|---|---|---|
| 胶囊**高度恒定** | 两条上报都是 `312x60`（第 2 条 `图标带 …x32` 正是菜单开着那一刻） | ✅ v4.6/v4.6.1 成立 |
| 「创建」开菜单时**另外三颗不动** | `dy=[+10.0,+10.0,+10.0,+2.5]` —— 前三颗稳在 `+10` | ✅ v4.6.1 成立 |
| 迷你条与标签栏**等宽等高** | `[MiniBarGlass] 胶囊 (51,-2 312x60) …（与标签栏**等宽** 312、同高 60；宽度取自 标签栏那条的比例）` | ✅ v4.7.1 成立 |
| 封面色底写回**有**被清 | `封面色底写回第 1 次`（00:47:38）+ `第 2 次`（00:47:54） | ✅ 动作跑到了 |
| …但用户**仍然**看到那块蓝（照片 36） | 见 §23.4：写回**不伴随布局回合**，我们下一次清色晚了 8 秒 | ❌ 时机不对 |
| 「创建」**取消后被顶到"有文字"位置** | dump #4 `ElementContentView@279,10` → dump #5 起 `@279,2`，**#6–#13 一直是 2** | ❌ 见 §23.3 |
| 标签文字隐藏 | `[TabBarPlate] 标签文字已隐藏（4 个）` 一行 | ✅ |
| 玻璃来源 | `用的是系统真玻璃 UIGlassEffect` + `isInteractive = true` | ✅ |

**日志 28 顺带的新事实**：`ElementContentView` 在 `[Tree]` 里的坐标是**渲染后**的
（`dx`/`dy` 都算进去了）—— 四颗的 layout 原点是 `x = 0/104/207/310, y = 0`，
树上的 `31/113/196/279` 与 `10` 全是**我们写进去的 transform**。
所以"树上的 y 变了"既可能是我们的 `dy` 变了、也可能是 Spotify 的布局变了 ——
这正是 §23.3 里那条"dy 变了也要上报"的由来。

### 23.2 问题①：胶囊加宽 312 → **360**（用户：「宽度有点少，给它伸长一点」）

| | 值 | 说明 |
|---|---|---|
| 改的地方 | `TabBarGlassPlate.horizontalPadding` `20 → 44` | 一行常量 |
| 结果 | 真机带子 272 + 44×2 = **360pt**（屏宽 414 的 87%；v4.2–v4.7 是 312） | |
| 迷你条 | **自动跟随**（两条永远等宽，它按 `capsuleWidthRatio` 算） | |
| 副作用（好的那种） | 迷你条内容缩放从 `(312−16)/398 ≈ 0.74` 抬到 `(360−16)/398 ≈ 0.86` —— 封面/歌名/按钮都大一圈 | |
| 兜底比例 | `MiniBarGlass.fallbackWidthRatio` 同步改成 `360/414`（冷启动第一帧标签栏还没摆过时用它） | |

> 这是**唯一**的宽度旋钮：想再长/再短只改 `horizontalPadding`（上/下界分别是
> `band.width + 2×padding` 与 `栏宽 − 16`；本机栏宽 414 → 上限 398）。

### 23.3 问题②：隐藏标签文字时，点「创建」再取消，创建那颗**被顶到"有文字"的位置**

**现场（日志 28）**：

```
00:47:35  [TabBarPlate] 胶囊 (51,-3 312x60) … dy=[+10.0,+10.0,+10.0,+10.0]     ← 正常：四颗都在格子中心
00:47:54  [TabBarPlate] 胶囊 (51,-3 312x60) … dy=[+10.0,+10.0,+10.0,+2.5]     ← 菜单开着，创建那颗 33pt 图标居中
[Tree] #4 00:47:46  13.ElementContentView@279,10,103,49
[Tree] #5 00:47:56  13.ElementContentView@279,2,103,49                        ← 取消之后……没有回 +10
[Tree] #6..#13      13.ElementContentView@279,2,103,49                        ← 一直到日志结束都是 2
```

`dy = 27 − 24.5 = +2.5` 里的 **24.5 = 整颗 item 框（103×49）的中心** —— 也就是说
`visibleBand`（v4.6.1 的纵向基准）那一刻**把整颗 item 的框当成了"看得见的内容"**：
它的兜底分支是"子树里一个可见节点都没有时返回自己"，而「创建」那颗在菜单开合期间
**子树会整个不可见**。于是：

* 创建那颗的 `dy` 从 `+10` 掉到 `+2.5` → 它落在 **7.5pt 高**的位置；
* 有文字时 `dy = 0`、图标本来就在 `5…29` —— 所以用户看到的就是
  **"变成有文字的时候的高度"**，而另外三颗（`+10`）纹丝不动。

**修法（`TabBarGlass.x.swift`）**：纵向基准**分两支**，
判据是「隐藏标签文字」这个开关本身：

| 开关 | 基准 | 为什么 |
|---|---|---|
| **开着**（文字藏起来） | 这一颗**自己的图标**（`itemIconBands`，`EncoreIconView` 的并集） | 图标是唯一稳定的东西：白圆底（40×40、alpha 会停在 1）与"整颗 item 框"都进不来；菜单开着时它临时 33pt、跟着居中（对的），**取消后一定回到 `24×24@y=5` → `dy` 回到 `+10`** |
| **关掉**（文字显示） | v4.6.1 的老路（`visibleBand`：图标 ∪ 文字） | 那时必须让**文字**也留在胶囊里；拿图标当基准会把整颗往下推 10pt、文字被推出胶囊底 |

* 认不出图标的那一颗（类名换了）用**其余几颗的中位中心**兜底；一颗都认不出才返回 0。
* `report` 现在**`dy` 一变也打一行**，并多打一个 `基=图标/可见内容` 字段
  —— 日志 28 那次"只留下半句"的教训（frame 没变就不报，害得要靠 dump 反推）。

### 23.4 问题③：切歌/首帧那块**封面色底**（照片 36）为什么留着不走

**现场（日志 28 + 照片 36/37）**：

```
[Tree] #4 00:47:46  9.UIView@50,7,296,41,bg=#10346C,id=SPTNowPlayingBar   ← Spotify 写下封面色
[MiniBarGlass] 00:47:54  封面色底写回第 2 次 — 已再清掉                    ← 我们下一次"看见"它，是 8 秒后
[Tree] #5 00:47:56 起  id=SPTNowPlayingBar 那行不再带 bg=                   ← 照片 37
```

**病根**：清色的时机挂在**宿主自己的 `layoutSubviews`** 上，而 Spotify 写回封面色
**不一定会伴随宿主的布局回合** —— 于是"清一次就完事"的假设在这条路径上不成立：
写回之后可能很久都没有下一次布局（真机上是 8 秒），用户就一直看着那块蓝，
直到他碰巧点一下别处（创建 / 听歌页）触发了下一回合。

**修法（`MiniBarGlass.swift` + `DeclutterChrome.x.swift` 一行）**：两个驱动，都不是常驻轮询：

1. **短促重试**（`armColorGuard`）：清完色之后排 5 次"看一眼 + 幂等清"
   （0.05 / 0.15 / 0.35 / 0.7 / 1.2s）。**只排一轮、有节流不叠加**（`guardBurstUntil`）；
   某一次真清到了东西就再排一轮，没东西可清自然停手。
2. **蹭 `DeclutterChrome` 既有的 0.5s 复查节拍**（`reconcileCoverColor`）：
   一次属性读，开关关着 / 没迷你条时零开销。**不新开定时器。**
   → 即使一次布局回合都不来，最多 0.5s 也会被清掉（原来是最长 8 秒）。

> 残留（说清楚）：如果写回**恰好**发生在两次复查之间，用户理论上能看到 ≤0.5s 的色闪。
> 要再快只能上"写回即回调"（KVO / 全局 swizzle `setBackgroundColor:`）——
> 那两样在本仓库都算"没验证过的运行时招数"（崩过两次），**先不做**；真机看完再说。

### 23.5 问题④：「更新日志」显示"未能读取该数据，因为它的格式不正确"

**与外观无关，但同一天报的，记录在此；细节见 `SESSION_2026-10-02_HANDOFF.md` §7。**
一句话：`GitHubHelper.perform` 以前**完全不看 HTTP 状态码**，把错误响应体直接丢给
`JSONDecoder`。日志 28 的真身是：

```
[GitHub] GET /repos/zbzxbg/EeveeSpotify-ng-latest/releases/latest
[GitHub] /repos/zbzxbg/EeveeSpotify-ng-latest/releases/latest -> 280 bytes
[VersionCheck] Failed to fetch latest release: DecodingError.keyNotFound: Key 'tagName' not found
```

280 字节 = **GitHub 未登录限流的 403 响应体**（404 的响应体是 130 字节，实测过）。
修法：① 状态码先过闸（403/429 → 限流、404 → 没有 release）；② 仓库 slug 改用
构建期生成的 `EeveeSpotify.repoSlug`（仓库已改名 `zbzxbg/EeveeSpotifyEvolved`）；
③ ETag 条件请求 + 5 分钟缓存（304 不计额度），反复进出这一页不再烧那 60 次/小时。

### 23.6 下一份日志（日志 29）要看的行（验收判据）

```
[TabBarPlate] 胶囊 (51,-3 360x60) r=30.0 ← 有文字带 (71,5 272x44) 图标带 (71,5 272x24) dy=[+10.0,+10.0,+10.0,+10.0] 基=图标 [栏 414x83] …
[MiniBarGlass] 胶囊 (27,747 360x60) r=30.0 ← 迷你条内容 398x56 缩到 0.86（与标签栏**等宽** 360、同高 60 …）
```

1. **宽 = 360**、两条的 x 与宽完全一致（这是问题①的判据）；迷你条内容缩放 ≈ **0.86**；
2. 点开「创建」→ 再取消：日志里应当出现 `dy=[+10.0,+10.0,+10.0,+2.5]…基=图标`（开菜单）
   然后**回到** `dy=[+10.0,+10.0,+10.0,+10.0]`（取消）—— 四个图标齐平、创建那颗不再"变高"；
3. 冷启动第一次看到迷你条、以及**切歌瞬间**：`id=SPTNowPlayingBar` 那行**不带 `bg=`**
   （或者带 `bg=` 的那一份 dump 与"写回第 N 次 — 已再清掉"之间**不超过 ~0.5s**）；
4. 观感：胶囊比 v4.7.1 长一圈、四个图标仍然居中、两条之间仍有小间隙、点迷你条照常进播放页；
5. 新增的四条开关行为回归：关掉「迷你播放条用液态玻璃」→ 玻璃撤掉、内容回原始大小、
   封面色底回来（`[MiniBarGlass] 封面色底已还原`）。

---

## 24. v4.9：**基线换成 Spotify 9.1.88** + 日志 29 判读 +「创建」那颗上移的**真正**病根（2026-10-02）

> 输入：**日志 29**（`C:\dsh\ipa\eeveespotify_debug_shared 29.log`，9.1.88，02:14:48–02:15:10）+
> 新数据资产 `C:\dsh\ipa\dump-9.1.88.txt` / `Spotify-…_9.1.88_decrypted.ipa`。
> 用户："点击『创建』再取消，这个按钮看起来的高度还是有文字时一样（**上移**）；长度没问题了。"

### 24.1 基线 9.1.88：本改动依赖的类名/id **一个都没变**（已核）

| 名字 | 来源 | 9.1.88 状态 |
|---|---|---|
| `NavigationUI_TabBarImpl.TabBarView` | 日志 29 `[TabBarPlate] 玻璃胶囊已铺在 … 上` | ✅ 钩上了 |
| `tabs-container-view-identifier` | 日志 29 `图标带 (71,5 272x24)`（= 找到那条 stack 才量得出） | ✅ |
| `SPTEncoreIconView` / `id=Encore.IconView` | 日志 29 的 `[Tree]`：`16.OBJC_ONLY_IconView@40,5,24,24,id=Encore.IconView` | ✅ |
| `SPTEncoreLabel` / `id=Encore.Label` | 日志 29 `有文字带 (71,5 272x44)`（= 文字被算进带子） | ✅ |
| 结构 | `ElementContentView<…TabBarItemElement>@31,10,103,49` 四颗 + 图标 `@40,5,24,24` | ✅ 与 9.1.86 同形 |

> ⚠️ `dump-9.1.88.txt` 是**符号表**（`[classes]` 等 bucket），**不含**运行时视图类名/id
> —— `SPTEncoreIconView`、`tabs-container-view-identifier` 在里面查不到是正常的，
> **判据永远是真机 `[Tree]`**（这次就是上面那两行）。

### 24.2 日志 29 判读：①③④ 全好，② 没修好（但这次拿到了完整现场）

| # | 项目 | 日志 29 证据 | 判定 |
|---|---|---|---|
| ① | 两条胶囊加宽到 360 | `[TabBarPlate] 胶囊 (27,-3 360x60)` + `[MiniBarGlass] 胶囊 (27,-2 360x60)`（x、宽**完全一致**），迷你条内容缩到 **0.87** | ✅ |
| ③ | 封面色底 | 8 份 `[Tree]` 里 `id=SPTNowPlayingBar` **全部不带 `bg=`**；`封面色底写回第 1..4 次 — 已再清掉`（02:14:51–54） | ✅ |
| ④ | 更新日志/仓库名 | `[GitHub] GET /repos/zbzxbg/**EeveeSpotifyEvolved**/releases/latest` → `5863 bytes`（不再是 280 字节的限流体） | ✅（页面本身这次没打开） |
| ② | 「创建」取消后上移 | 见下 | ❌ **v4.9 修** |

**② 的完整现场**（这就是"上移"两个字的全部证据）：

```
02:14:51  [TabBarPlate] … dy=[+10.0,+10.0,+10.0,+10.0] 基=图标       ← 正常
02:14:53  [TabBarPlate] … dy=[+10.0,+10.0,+10.0,+2.5] 基=图标       ← 点开「创建」的那一刻（v4.8 的基准算对了）
02:14:53  [Tree] #1  …TabBarItemElement>@279,10,103,49              ← 还没动
02:14:54  [Tree] #2  …TabBarItemElement>@279,2,103,49               ← 之后 **7 份 dump 全是 2**
… 02:15:09 [Tree] #8  还是 @279,2                                     ← 16 秒没回来（用户拍照/肉眼看到的就是这个）
```

两条关键推理（都只用上面这些数）：

1. **渲染 y=2 是我们写的**，不是 Spotify 挪的：`ElementContentView` 是 `UIStackView`
   的 arranged subview，四颗都是 `103x49` 装在 `414x49` 的 stack 里 → **layout y 恒为 0**
   （横向等分，不分配纵向）。所以 `2 = 0 + dy` → `dy` 就是 `+2.5` 那一份；
2. **为什么回不来**：v4.8 是"一颗一个数"，那个 `+2.5` 写进了**创建那一颗**的 transform；
   而**菜单关掉时这条栏不一定再收到 `layoutSubviews`** —— 我们的 `apply` 就再也没跑过
   （日志 29 里 `[TabBarPlate]` 自报**只有两条**，之后再没有第三条），transform 于是永远停在那儿。

> ★ **教训（与"迷你条封面色底"同族，值得单列）**：
> **我们把"暂时态"写进别人的视图之后，必须有办法在暂时态结束时把它改回来。**
> 而"下一次布局回合"**不是**一个可以依赖的时机 —— 迷你条那次是"写回不伴随布局"，
> 这次是"状态结束不伴随布局"。判据：**凡是写进去的值依赖一个会变的状态，就得自己安排复核。**

### 24.3 v4.9 的修法：**四颗共用一个位移（中位数）** + 复核安全网

**主修（值的层面，不依赖任何时机）**：
「隐藏标签文字」开着时，纵向位移从"一颗一个数"改成**四颗共用一个数** ——
取每颗"按自己图标"算出来的期望值的**中位数**：

| 状态 | 四颗的期望值 | 中位数 | 写进 transform 的 dy |
|---|---|---|---|
| 平常 | `[+10, +10, +10, +10]` | `+10` | `[+10,+10,+10,+10]` |
| 点开「创建」 | `[+10, +10, +10, **+2.5**]` | **`+10`** | `[+10,+10,+10,+10]` ← 创建那颗**不再动** |

→ 菜单关掉时**即使一次布局回合都不来**，四个图标也仍然在同一个高度上（因为偏离值
**从来没被写出去过**）。这正是"上移"这个症状的根治。

> 与 v4.6.1 的关系：v4.6.1 发现"四颗共用**一个被拉偏的数**"会让另外三颗被顶高，于是改成
> 一颗一个数。**正解是"共用一个数 + 取中位数"** —— 4 颗里 1 颗偏离时，中位数天然不受影响
> （真机日志 29 的 `[+10,+10,+10,+2.5]` 就是 3:1，中位数稳在 `+10`）。

**安全网（万一将来有 2 颗以上同时偏离，把中位数也带偏了）**：
`hasDeviation(...)` 一旦发现这一行"明显不齐"，就置位 `rowIsTransient` 并

* 排一轮短促复核（`0.2 / 0.5 / 1.0 / 2.0 / 3.5s`，**只排一轮、不叠加**），每个时点
  **自己直接调 `apply`**（不等 `layoutSubviews`）；并打一行
  `[TabBarPlate] 这一行暂时不齐（多半是「创建」菜单开着）— 会在 ~0.5s 内自己复核…`；
* 蹭 `DeclutterChrome` **既有的 0.5s 复查节拍**（`TabBarGlassPlate.reconcileRowIfTransient()`）
  —— 菜单开着超过 3.5s 之后再关掉时，靠它兜住。

行一稳（`rowIsTransient == false`），两边都退化成**一次 bool 读**。**不新开定时器。**

### 24.4 下一份日志（日志 30）的判据

1. **点开「创建」→ 再取消**：日志里**应当只有一条 `[TabBarPlate] 胶囊 …` 行，且是四颗全同**：
   ```
   [TabBarPlate] … dy=[+10.0,+10.0,+10.0,+10.0] 基=图标·整行 …        ← 平常（也是唯一的一条）
   [TabBarPlate] 这一行暂时不齐（多半是「创建」菜单开着）— 会在 ~0.5s 内自己复核，不需要再有布局回合（v4.9）
   [Tree] #N 13.ElementContentView<…TabBarItemElement>@279,10,103,49   ← ★ 全程必须是 10（v4.8 时是死死在 @279,2）
   ```
   ⚠️ 点开「创建」时**不会**再出现第二条 `胶囊` 行 —— 因为这一版 `dy` 没变（四颗都还是 `+10`），
   而 `report` 只在"变了"时报。**"没有那一行"就是修好的样子**（v4.8 那版会在那里多打一行 `…,+2.5]`）。
   真正的判据是 `[Tree]` 里那一颗的渲染位置**始终 `@279,10`**。
2. 顺手回归 ①③④：`360x60` 两条等宽 / `SPTNowPlayingBar` 不带 `bg=` / 更新日志能列出 release。
3. ⚠️ 已知可接受现象：**菜单开着的时候**，创建那颗的圆底会比胶囊中心低 ~7pt（它 33pt 图标
   的中心本来就在 24.5，而我们整行只按 `+10` 走）。这是"整行不动"换来的代价，**菜单一关就看不到了**；
   如果用户觉得这个更不能忍，再改回"一颗一个数 + 更密的复核"（代价是今天这个 bug 有回来的风险）。




