# 过时清单（2026-10-02 审计）

> 工具：`Tools/eevee-hookfinder/audit_stale_targets.py`（本次新增）。
> 复跑（**关键是要给 `--ipa`**，不给它 ObjC 那半只能算"嫌疑"）：
>
> ```
> python Tools/eevee-hookfinder/audit_stale_targets.py \
>     --ipa "<data-dir>\ipa\Spotify- Music and Podcasts_9.1.86_decrypted.ipa"
> ```
>
> 与 `Scripts/diff-symbol-dumps.py`（CI `binary-diff.yml` 用的那个）的分工：
> 那个是 **dump 对 dump**、**只看 Swift**；本工具是 **时点核对 + ObjC + IPA 字节**。

## 三份真相来源，可信度不一样

| 来源 | 覆盖 | 能不能用来判"不存在" |
|---|---|---|
| `dump-9.1.86.txt` 的 `[classes]` | **只有 Swift**（16930 条 `_TtC…`） | ✅ 能（Swift 类） |
| `.spotify-ipa/objc-classnames-by-image.txt` | ObjC，但**只覆盖 2 个镜像**（`Spotify` / `SpotifyShared`，5837 条） | ❌ 不能：它连真机上明明跑着的 `SPTEncoreLabel`、`SPTNowPlayingBar` 都没有 |
| `--ipa`（在解密 IPA 的所有二进制里按字节搜名字） | 全包（本次扫了 ~290MB） | ✅ 能（搜不到 = 整个 App 里都没这个名字） |

⚠️ 字节搜索的两个偏差：**搜到 ≠ 定义在此包**（可能是引用，也可能是别的名字的子串 ——
`SettingsViewController` 就是这么命中的）；**搜不到 ⇒ 确实不存在**，这条方向可靠。

## 一、确认过时（整个 9.1.86 IPA 里都没有这个名字）

> ✅ **2026-10-02 已按死代码删除**（用户明确：**本仓库只服务 9.1.86，不打算适配更早的版本**）。
> 判据来自把 9.1.0 / 9.1.74 / 9.1.76 / 9.1.86 四个包的主二进制各扫一遍：
> `ProfileSettingsSection`、`RootSettingsViewController`、`SPTSharingSDK`、
> `SPTShare_FoundationImplProperties`、`LyricsOnlyViewController` **只在 9.1.0 里存在**；
> `StreamQualitySettingsSection` **四个版本都没有**。

| 名字 | 位置 | 说明 | 处置 |
|---|---|---|---|
| `SPTSharingSDK`、`SPTShare_FoundationImplProperties` | `Experiments/Instagram/`（整个目录） | 老 `SPTSharingSDK*` 已换成 `Share_SharingSDKSwift*`（dump:3172–3211） | ⚠️ **删的是"实现"，不是"功能"**（见下面 1.2）：9.1.86 里三个 handler 都还在，开关变成了初始化参数 |
| `StreamQualitySettingsSection` | `Premium/ServerSidedReminder.x.swift` | 四个版本都没有；同文件另两条目标**还在** | ✅ **只删那一个 class**，同文件的 `ListRowInteractionListenerViewHook` / 两个 offline hook 原样保留 |
| `ProfileSettingsSection`、`RootSettingsViewController`、`SettingsViewController`（只经老入口可达） | `Settings/EeveeSettings.x.swift`（整文件）、`Settings/EeveeSettingsUniversal.x.swift`、`Tweak.x.swift` | **9.1.0 的设置入口**；9.1.86 用的是 `Settings_PlatformImpl.SettingsListViewController` | ✅ 删了 4 个老 hook 类 + 4 个 HookGroup + Tweak 里两处激活；**保留** `UniversalSettingsIntegrationListVCGroup` 与 `injectEeveeButton`（9.1.44+ 那条路要用） |
| `Lyrics_CoreImpl.LyricsOnlyViewController`、`Lyrics_NPVCommunicatorImpl.LyricsOnlyViewController` | `Lyrics/LyricsWordByWord.x.swift` | 老版本歌词页宿主 | ⏳ **本轮未删**：它们挂在 `LegacyLyricsGroup`（**9.1.86 上真的被激活**）与 `V91UnavailableLyricsGroup`（隔离组，永不激活）上，删它们要连组一起重构 → 归入第二轮"版本分支清理" |
| `FLEXManager` | `EeveeFlex.x.swift:22,40` | ✅ **不是过时**：FLEX 是外挂调试库，本来就不在 IPA 里；代码自己会打 `libFLEX NOT loaded — auto-open dormant` | 别动 |

### 1.1 顺手清掉的其它死重

| 项目 | 情况 |
|---|---|
| `classes_910.txt`（仓库根） | **0 字节空文件** → ✅ 已删 |
| `class_comparison.md`（仓库根） | 9.1.0 vs 9.1.6 时代的分析，结论已错 → ✅ 已删 |
| `NewDesignYield.x.swift` 开头"标签栏自带 `UIVisualEffectView`" | 与真机矛盾（日志 20 全树只有我们那块）→ ✅ 已改正为更正说明 |
| `EeveeSettings91x.x.swift`（79 行的版本 banner） | **`V91SettingsIntegrationGroup()` 全仓库没有任何激活点** → 从来没显示过。属于"9.1.x 自己的死代码"而非老版本兼容 → **本轮保留**，要不要删/要不要真启用请用户定 |

**另外 6 处"两份清单没命中、但 IPA 里其实有"的**（不算过时）：
`SPTAdsProductState`、`SPTEncorePopUpDialog`、`SPTEncorePopUpDialogModel`、`SPTEncorePopUpPresenter`、
`SettingsViewController`。
—— 也就是说 **`UpsellPopupBlocker` 不是过时**（虽然第二份清单里没有它那三个类，但 IPA 里有）。

### 1.2 ★「显示 Instagram 分享目标」：删掉的是**实现**，不是**功能**（2026-10-02 追查）

差点把它当成"没用"清掉。查完 9.1.86 的符号表：**能力还在，只是全部改了名字**。

| 老（≤9.1.0） | 9.1.86 上的对应物 |
|---|---|
| `SPTSharingSDK.canHandleShareDestination(_:)` | 三个独立 handler 类：`Share_SharingSDKSwift.InstagramNotesShareHandler` / `.InstagramStoriesShareHandler` / `.InstagramDirectMessageShareHandler`（dump:3201/3207/3209） |
| `SPTShare_FoundationImplProperties.isInstagramStoriesCanvasSharingEnabled()` / `isInstagramDirectMessageSharingEnabled()` | 同类名套路的 **`Share_FoundationSwiftImpl.SPTShare_FoundationSwiftImplProperties`**（dump:6176）；开关变成了**初始化参数**：`initWithIsInstagramDirectMessageSharingEnabled:isInstagramStoriesCanvasSharingEnabled:…`（dump:26048 —— 整个二进制里唯一带 Instagram 的 selector） |

**两条恢复路径**：

1. **零代码（先试这条）**：Flag 覆盖（通道 2026-10-01 已修好并验证）加
   - `ios-feature-share` → `is_instagram_direct_message_sharing_enabled`
   - `ios-feature-share-menu` → `is_instagram_stories_canvas_sharing_enabled`
   - （另有 `ios-share-destinationhandler-impl` → `is_instagram_notes_enabled`，那是"分享到 IG Notes"）
   加完重启 Spotify，看分享面板里有没有 Instagram。
2. **按新类名重写**（原文在 git 里，删掉的那个文件 25 行）：挂
   `SPTShare_FoundationSwiftImplProperties` 的对应 getter，或挂那个 `initWithIsInstagram…`；
   ⚠️ 挂之前要先用探针确认那个 init 的**宿主类**（dump 的 `[methods]` 桶里没有它，只有 `[selectors]`）。

## 二、新设计基线（`liquid_glass` 构建，现在是默认）下变成空操作的功能

| 功能 | 证据 | 状态 |
|---|---|---|
| 「深色栏底色」(AMOLED) | `AmoledTheme.x.swift:106,374`：`if NewDesignLanguage.isActive { reportYieldingOnce(by: "AMOLED"); return }` | ✅ **已删除（2026-10-02）**：纯空操作 + 21KB 死代码。它承担的"运行期观察新设计"兜底信号已搬到 `NewDesignYield.observeNewDesignMarkersIfNeeded` |
| 「听歌页外观（样品）」（顶部大标题） | 只画 `applyLegacyTitle`，与壳自己的顶栏标题**重复**（两个都开就画两遍） | ✅ **已删除（2026-10-02）**（文件 + 设置开关 + UserDefaults 键） |
| 「背景跟封面取色」 | 壳给它 `isBackdropOpaque = false`，而这一档在 `LyricsBackdropArtworkView` 里是"整块背景（含封面层与暗化渐变）一起透明" | ✅ **已删除（2026-10-02）**：一直是"假开关"（视觉上等于没做）。要真做是"半透明档"（§2.3 唯一没试过的一档），另开一轮 |
| 「隐藏标签栏渐隐」 | 已删（`SESSION_2026-10-01.md` §2.2） | 已清理 |
| 「Flag 覆盖」 | 2026-10-01 已修；日志 20/23 有 100+ 条 `[Flags]` + `[CustomizeSeed]` | **不再是假开关** |
| 「AM 式头部」（音乐库大标题） | 日志 23：`[Library] 大标题已换成 AM 档：24pt → 30pt` | ✅ **在役、有效**（保留） |
| 清爽五件套 / 双击手势 / 屏蔽艺人 | 日志 20/23 全部 `installed`、无 `missing` | 在役 |

## 三、过时的文档 / 资产

| 资产 | 问题 |
|---|---|
| `classes_910.txt`（仓库根） | **0 字节的空文件** |
| `class_comparison.md`（仓库根） | 9.1.0 vs 9.1.6 时代的分析；结论（"9.1.x 关掉歌词"）现在已经是错的 |
| `NewDesignYield.x.swift` 开头注释 | "标签栏自带 `UIVisualEffectView` + `_UIVisualEffectBackdropView`"与真机矛盾：日志 20 全树 dump 里 `UIVisualEffectView` **只有我们那一块** |
| `.spotify-ipa/objc-classnames-by-image.txt` | 只覆盖 2 个镜像 → 当"不存在"的证据用会误判（工具里已标） |
| `FLAGS_9186_DESIGN.md`「实测没反应」段、`SESSION_2026-10-01.md` §2.9 | 已自我标注过时，保留作记录即可 |

## 四、这一轮的数字（免得下次重查）

- 81 处 hook 目标 / 运行时类名字面量：**Swift 命中 38 ｜ ObjC 线索命中 13 ｜ IPA 字节命中 6 ｜
  系统私有 11 ｜ 过时 13**。
- 那 13 处去重后是 **8 个名字**：`FLEXManager`（设计如此）、`ProfileSettingsSection`、
  `RootSettingsViewController`、`Lyrics_CoreImpl.LyricsOnlyViewController`、
  `Lyrics_NPVCommunicatorImpl.LyricsOnlyViewController`（四个都是老版本兼容）、
  `SPTSharingSDK`、`SPTShare_FoundationImplProperties`（Instagram 实验）、
  `StreamQualitySettingsSection`（服务端提醒）。
  ⇒ **真正该动的只有后两组（3 个名字）**，前两组要么别动、要么先定"还支不支持老版本"。
- `KnownFlagCatalog` 41 条 **全部命中** 9.1.86 的字面量表（2485 条）✓
