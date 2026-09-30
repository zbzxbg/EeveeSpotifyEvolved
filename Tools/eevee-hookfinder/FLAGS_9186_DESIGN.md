# 9.1.86 设计类 flag 短名单（从解密 IPA 抽出）

> 2026-10-01。来源：`C:\dsh\ipa\Spotify- Music and Podcasts_9.1.86_decrypted.ipa`
> 的**主二进制**（`Payload/Spotify.app/Spotify`，230 MB），
> 用本仓库自己的工具 `Tools/eevee-hookfinder/extract_flags.py` 抽的字面量。
> **只读 IPA，没有改它，也没看 spoti.pw 的任何源码。**

## 为什么值得单独记一份

`Sources/EeveeSpotify/Flags/KnownFlagCatalog.swift` 里那 41 条是**从真机日志**攒的 ——
而 `DynamicPremium+ModifyingFunctions.swift` 只走「歌词」和「NPV」两条链路，
所以**新外观那几个 flag 在日志里永远不出现**。要拿到它们只能从二进制抽。

抽出来的总量（可复现）：

| 文件 | 内容 | 条数 |
|---|---|---|
| `.spotify-ipa/flag-table.txt` | `scope<TAB>name` 配对（二进制里的字面量 `scope.name`） | 2485 |
| `.spotify-ipa/flag-names.txt` | `*_enabled` / `*_disabled` 形态的名字 | 1273 |
| `.spotify-ipa/flag-scopes.txt` | `ios-…` 形态的 scope | 856 |
| `.spotify-ipa/flag-design.txt` | 上面三者的"设计相关"过滤结果 | 263 |

重新生成：

    python Tools/eevee-hookfinder/extract_flags.py "<ipa 路径>" -o .spotify-ipa --context 300
    python Tools/eevee-hookfinder/extract_flags.py "<ipa>" --list-only        # 只列候选条目
    python Tools/eevee-hookfinder/extract_flags.py "<ipa>" --probe ios-feature-canvas

## ★ 总开关：Spotify 自己的液态玻璃

| scope | name | 说明 |
|---|---|---|
| `ios-reprise-liquid-glass-override` | `mode` | **Spotify 内部对这套新设计的代号是 "Reprise"**，这个 flag 就是它的总开关 |

`mode` 的取值（从二进制里 `Reprise_LiquidGlassOverrideImpl` 那几个类名旁边的字符串读出，
**属于推断**）：`default` / `force_enabled` / `force_disabled`。

它旁边就是这两个类，进一步说明这不是我们猜的：

    _TtC31Reprise_LiquidGlassOverrideImpl25LiquidGlassOverrideDaemon
    _TtC31Reprise_LiquidGlassOverrideImpl44SPTReprise_LiquidGlassOverrideImplProperties

并列的还有 `ios-reprise-liquid-glass-properties` → `context_menu_in_navigation_bar_enabled`。

## 与 spoti.pw 文档里"它强制的那批 flag"对照

spoti.pw 的 `docs/tweaks.md` 说它的重设计强制打开「玻璃导航栏 / 新播放器滑块 / sheet 式播放器 /
queue 与 Connect sheet / 重设计播放器头 / 睡眠定时器选项 sheet」。在 9.1.86 上逐个对得上：

| spoti.pw 说的 | 我们在 9.1.86 抽到的 `scope.name` |
|---|---|
| 液态玻璃本体 | `ios-reprise-liquid-glass-override` → **`mode`** ★ |
| 玻璃导航栏（栏内 context menu） | `ios-reprise-liquid-glass-properties` → `context_menu_in_navigation_bar_enabled` |
| 新播放器滑块 | `ios-feature-encoreexperiments` → `new_npv_slider_enabled` |
| sheet 式播放器 / 原生 sheet | `ios-feature-share-menu` → `native_sheet_enabled`（另有 `settings_sheet_enabled`、`bottom_sheet_queue_enabled`、`disclosure_sheet_enabled`…） |
| 重设计播放器头 | `ios-feature-nowplaying` → `new_redesign_header_with_context_menu_enabled` |
| 睡眠定时器选项 sheet | `ios-feature-sleeptimer` → `use_options_sheet` |
| 全出血 header（歌单/专辑重设计） | `ios-listuxplatformconsumers-fullbleedheaderlayoutplugin-impl` → `enable_full_bleed_header_list_layout` |
| morph / 转场 | `ios-feature-nowplaying`、`ios-nowplaying-contentlayers-impl`、`ios-feature-canvas` → `mixing_transition_enabled`；`ios-feature-nowplaying-mixingtransition` → `use_wall_clock_implementation` / `use_image_data_element` |
| 布局迁移（玻璃栏高度补偿相关） | `ios-adaptivelayout-experimentationmanager` → `is_npb_app_root_layout_migration_on_mobile_enabled` / `is_npv_transition_app_root_layout_migration_on_mobile_enabled` |
| 锁屏动态封面 | `ios-feature-lockscreen` → `animated_artwork_enabled` ★ |
| Canvas | `ios-feature-canvas` → `canvas_enabled` / `canvas_enabled_ipad` |
| 首页筛选胶囊（Encore） | `ios-feature-home-funkispage` → `pills_encore_ui_enabled` |
| "现代"列表行 | 多个 scope → `modern_retrieval_row_ui_enabled` / `is_*_modern_retrieval_row_ui_enabled` |

## 怎么试（零代码，可逆）

设置 → EeveeSpotify → 扩展功能 → **Flag 覆盖** → 添加：

| 字段 | 值 |
|---|---|
| flag name | `mode` |
| scope | `ios-reprise-liquid-glass-override` |
| Value | **Set value** → `force_enabled` |

然后**重启 Spotify**（我们的 flag 覆盖在下次拉配置时生效）。

回退：删掉这条覆盖、重启，即回原样（或 `force_disabled`）。

## 三个诚实的提醒

1. `mode` 的三个取值是**推断**（虽然紧挨着 `Reprise_LiquidGlassOverrideImpl` 的类名）。
   试一次就知道，代价是重启一次。
2. 玻璃效果本身要 **iOS 26+**（目标机 iOS 27 ✓），但 9.1.86 上这套设计是 Spotify
   自己还在灰度/开发中的东西，**可能半成品或直接崩**——所以建议一次只开这一个开关。
3. 打开后**可能和我们自己的 hook 打架**（我们的 AMOLED 就挂在 `SPNavigationBar` 上、
   清爽挂在 `TouchPassthroughView` / `TabBarGradientView` 上）。真开起来时，
   先把 AMOLED / 清爽全关，看 Spotify 自己的原样，再决定我们的 hook 怎么让位。

## 为什么这条排进"液态玻璃"之前

如果 `force_enabled` 真的能把 Spotify 自己的玻璃外观打开，那"重绘整个 App"这件事就可能
**从自绘变成配置** —— 我们只需要在这个基础上做减法，而不是重画 10 个页面。
值得花一次重启去问清楚。

---

## 2026-10-01 实测结果与已做的改动

**实测：没反应。** 原因查清了，是**两道闸**，不是 flag 名猜错：

| 闸 | 事实（都查过） | 怎么解（已做） |
|---|---|---|
| **硬闸** | 解密 IPA 的 `Info.plist` 里 **`UIDesignRequiresCompatibility = True`** —— 这是 **Spotify 自己**写的，等于要求 iOS 26 用**兼容模式**跑它。整个 App 不进新设计语言，任何 flag 都不可能让它变玻璃。spoti.pw 的 `plist/` 覆盖干的就是这件事 | 打 IPA 时删掉这个键。已做成**构建开关**：CI 工作流新增 `liquid_glass` 布尔输入；本地脚本认 `ALLOW_LIQUID_GLASS=1`。**默认关** |
| **软闸** | 设置页的「写入指定值」原来映射到 `.setEnum`，**只改服务端已下发的条目、不会新增**；设计类 flag 服务端基本不下发 → 空枪。而且命中数只对歌词/NPV 打，连"是不是空枪"都看不见 | 新增 `.forceEnum`（没有就追加）；「写入指定值」改用它；并新增一行 `[Flags] override <scope>.<name> — N match(es)`，**所有**用户覆盖都打 |

### 怎么跑这个实验

- **CI**：跑 `Build IPA — patched` 时把 **liquid_glass** 勾上 → 产出的 IPA 里那个键已被删掉。
- **本地**：`ALLOW_LIQUID_GLASS=1 ./build-ipa-local.sh <vanilla.ipa>`。
- 装完**先不碰任何 flag**，看基线（有没有变玻璃 / 有没有错位）；确认不崩，再叠 `mode=force_enabled`。
- **回退**：重跑一次**不带**这个开关的构建即可，不用改代码。

### 这次日志里该看什么

```
[Flags] override ios-reprise-liquid-glass-override.mode — 0 match(es) (server did not send it; we append our own)
```

- `0 match(es) …` = 服务端没下发，我们**追加**了自己的那条（这就是 `.forceEnum` 的意义）；
- `1 match(es)` = 服务端下发了，我们改的就是它。

两种情况下界面都没变，才说明"这版 9.1.86 里没有那套玻璃"，可以安心走自绘路线。
