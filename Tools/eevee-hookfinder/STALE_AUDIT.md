# 过时清单（2026-10-02 审计）

> 工具：`Tools/eevee-hookfinder/audit_stale_targets.py`（本次新增）。
> 复跑（**关键是要给 `--ipa`**，不给它 ObjC 那半只能算"嫌疑"）：
>
> ```
> python Tools/eevee-hookfinder/audit_stale_targets.py \
>     --ipa "C:\dsh\ipa\Spotify- Music and Podcasts_9.1.86_decrypted.ipa"
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

| 名字 | 位置 | 说明 | 建议 |
|---|---|---|---|
| `SPTSharingSDK`、`SPTShare_FoundationImplProperties` | `Experiments/Instagram/ShowInstagramDestination.x.swift:8,21` | 9.1.86 的分享 SDK 已经换成 `Share_SharingSDKSwift*`（dump:3172–3211） | 实验在 9.1.86 上**永远不可能生效** → 删掉，或按新类名重写 |
| `StreamQualitySettingsSection` | `Premium/ServerSidedReminder.x.swift:26` | 该类没了；同文件另外两条目标**还在**（`Settings_ECMKit.ListRowInteractionListenerView`、`Offline_ContentOffliningUIImpl.ContentOffliningUIHelperImplementation`） | 找新入口类，或删这一条（属"部分失效"） |
| `ProfileSettingsSection`、`RootSettingsViewController` | `Settings/EeveeSettings.x.swift:10`、`Settings/EeveeSettingsUniversal.x.swift:19,197`、`Tweak.x.swift:615,627,677` | **老版 Spotify 的设置入口**；9.1.86 用的是 `Settings_PlatformImpl.SettingsListViewController`（已命中，日志 20 里设置页正常） | 属**多版本兼容**：还发老版本就留；只服务 9.1.86 就可以删 |
| `Lyrics_CoreImpl.LyricsOnlyViewController`、`Lyrics_NPVCommunicatorImpl.LyricsOnlyViewController` | `Lyrics/LyricsWordByWord.x.swift:2664,2687` | 同上：老版本歌词页的宿主 | 同上 |
| `FLEXManager` | `EeveeFlex.x.swift:22,40` | ✅ **不是过时**：FLEX 是外挂调试库，本来就不在 IPA 里；代码自己会打 `libFLEX NOT loaded — auto-open dormant` | 别动 |

**另外 6 处"两份清单没命中、但 IPA 里其实有"的**（不算过时）：
`SPTAdsProductState`、`SPTEncorePopUpDialog`、`SPTEncorePopUpDialogModel`、`SPTEncorePopUpPresenter`、
`SettingsViewController`。
—— 也就是说 **`UpsellPopupBlocker` 不是过时**（虽然第二份清单里没有它那三个类，但 IPA 里有）。

## 二、新设计基线（`liquid_glass` 构建，现在是默认）下变成空操作的功能

| 功能 | 证据 | 状态 |
|---|---|---|
| 「深色栏底色」(AMOLED) | `AmoledTheme.x.swift:106,374`：`if NewDesignLanguage.isActive { reportYieldingOnce(by: "AMOLED"); return }` | **对你自己的构建永远是空操作** → 建议：开关置灰/隐藏，或整条线删掉 |
| 「听歌页外观（样品）」 | v1 背景已删，只剩 `applyLegacyTitle`；已被「听歌页自绘壳」取代 | 冗余开关（默认关） |
| 「隐藏标签栏渐隐」 | 已删（`SESSION_2026-10-01.md` §2.2） | 已清理 |
| 「Flag 覆盖」 | 2026-10-01 已修；日志 20 有 100+ 条 `[Flags]` + `[CustomizeSeed]` | **不再是假开关** |
| 清爽五件套 / 双击手势 / 屏蔽艺人 | 日志 20 全部 `installed`、无 `missing` | 在役 |

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
