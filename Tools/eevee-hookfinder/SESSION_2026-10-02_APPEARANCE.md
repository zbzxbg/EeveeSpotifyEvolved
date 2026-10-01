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
