import Orion
import UIKit
import ObjectiveC
import SwiftUI

// MARK: - 逐字歌词渲染模块（MVP）
//
// 结构（按文件拆开，本文件只剩 Orion 挂载 hook）：
// WordByWord/WordByWordState.swift — 全局状态（取词进度、dto 归属）
// WordByWord/WordByWordPositionResolver.swift — 安全多策略定位播放进度 + 点行跳转
// WordByWord/WordByWordPlaybackClock.swift — CADisplayLink 时钟
// WordByWord/WordByWordLyricsFacts.swift — 逐词 / 逐行数据可用性判据（两层共用）
// WordByWord/LyricsWordByWordOverlayView.swift — UIKit 叠加视图
// WordByWord/WordByWordHost.swift — 挂载 / 卸载
//
// 前提（来自 Spotify 二进制逆向）：
// 进度候选：playbackPosition(Double)、currentPlaybackTime(Double)、currentTrackTimeSecs(Int64 秒)
// 挂载点：Lyrics_NPVCommunicatorImpl.LyricsOnlyViewController（新版）/ Lyrics_CoreImpl.LyricsOnlyViewController（iOS14）
// 开关：复用 ngzhwm_wordByWordLyrics
//
// MARK: - 挂载 hook（全屏歌词 VC）
//
// ⚠️⚠️ **绝对不要在这些覆写方法（或 hook 类）上写 `@MainActor`。**
//
// Orion 的代码生成器是按**源码文本**拼接的：给覆写方法加 `@MainActor`，生成的
// `EeveeSpotify.xc.swift` 里会拼出 `@MainActoroverride` 这种非法属性，`override`
// 关键字也一起丢掉，整个文件报一串语法错误；而且它生成的 C 跳板是非隔离的，
// 同步调用被标成 `@MainActor` 的方法又构成隔离违规。
//
// 正确的写法：方法保持非隔离，**在方法体里**用 `onMainThreadSync { }`
// （定义在 `LyricsChromeVisibility.swift`）把"这是主线程"表达出来。
// 它已经是主线程时是同步执行的，不改变任何时序；`viewWillDisappear` 里的清理
// 因此仍然是同步的。
//
// 顺带：**内嵌（预览）**那两处沿用原有的 `DispatchQueue.main.async` 延后一拍再挂载，
// 写在 `onMainThreadSync` 里面；**全屏**那两处已改到 `viewWillAppear` 里直接挂 ——
// 多拖一拍会让转场动画期间露出 Spotify 自己的全屏歌词（"进入时一闪"）。

class LyricsWordByWordModernHostHook: ClassHook<UIViewController> {
    // `Lyrics_NPVCommunicatorImpl.LyricsOnlyViewController` 在 9.1.x 上不存在
    // → 隔离组，永不激活。
    // 影响：内嵌（NPV）逐词歌词在 9.1.x 上不可用；9.1.x 可用的宿主是
    // LyricsWordByWordFullscreenModernHostHook 的 FullscreenElementViewController。
    typealias Group = V91UnavailableLyricsGroup
    static let targetName = "Lyrics_NPVCommunicatorImpl.LyricsOnlyViewController"

    func viewDidAppear(_ animated: Bool) {
        orig.viewDidAppear(animated)
        let vc = target
        onMainThreadSync {
            WordByWordHost.shared.rememberInlineController(vc)
            DispatchQueue.main.async {
                WordByWordHost.shared.attach(to: vc, showsTranslation: false)
            }
        }
    }

    func viewWillDisappear(_ animated: Bool) {
        orig.viewWillDisappear(animated)
        onMainThreadSync {
            WordByWordHost.shared.detach()
        }
    }
}

class LyricsWordByWordLegacyHostHook: ClassHook<UIViewController> {
    typealias Group = LegacyLyricsGroup
    static let targetName = "Lyrics_CoreImpl.LyricsOnlyViewController"

    func viewDidAppear(_ animated: Bool) {
        orig.viewDidAppear(animated)
        let vc = target
        onMainThreadSync {
            WordByWordHost.shared.rememberInlineController(vc)
            DispatchQueue.main.async {
                WordByWordHost.shared.attach(to: vc, showsTranslation: false)
            }
        }
    }

    func viewWillDisappear(_ animated: Bool) {
        orig.viewWillDisappear(animated)
        onMainThreadSync {
            WordByWordHost.shared.detach()
        }
    }
}

// MARK: - 全屏歌词挂载 hook（点击歌词框架展开后铺满的页面）

class LyricsWordByWordFullscreenModernHostHook: ClassHook<UIViewController> {
    typealias Group = ModernLyricsGroup
    static let targetName = "Lyrics_FullscreenElementPageImpl.FullscreenElementViewController"

    func viewWillAppear(_ animated: Bool) {
        orig.viewWillAppear(animated)
        let vc = target
        // 挂载点：**整屏的 vc.view**，除此之外什么都不做。
        //
        // 这里曾经把 overlay 挂到「歌词内容」子模块
        // `Lyrics_FullscreenElementPageImpl.LyricsView`（frame=0,104 414x570），
        // 后果是背景只能铺在 570pt 的容器内、容器边界上留一道"壳 / 肉"接缝 ——
        // 这是要消除的东西，所以改成挂整屏。
        //
        // ⚠️ 但"挂整屏"必须配上"不碰原生视图"。中间我试过更激进的一版
        // （隐藏歌词容器 + 把整层插到最底 + 清宿主底色），真机结果是**整页空白、
        // Spotify 菜单全没了**。原因见 `attach` 里的说明：这一页的 header / 歌词 /
        // 控件栏都不是 vc.view 的直接子视图，藏一个就等于藏整页。
        // 所以现在：原生 UI 一个都不动，靠我们自己的背景够暗来盖住它。
        // 全屏左边距用 24（贴近 Spotify 原生歌词内容的 24pt 内缩）
        //
        // ⚠️ 时机从 `viewDidAppear` 提前到 `viewWillAppear`：前者是**转场动画播完**
        // 才回调的，所以之前整段上滑动画期间露出的都是 Spotify 自己的全屏歌词
        // （纯专辑色背景 + 原生歌词），动画结束我们的层才贴上去 —— 就是"进入时一闪"。
        // 同时去掉 `DispatchQueue.main.async` 那一拍：它原本是"等布局"，而这一层的
        // 约束贴死 vc.view 四边，布局变化会自动跟随，不需要等。
        onMainThreadSync {
            WordByWordHost.shared.attach(
                to: vc,
                sideInset: 24,
                showsProviderFooter: true
            )
        }
    }

    func viewDidAppear(_ animated: Bool) {
        orig.viewDidAppear(animated)
        let vc = target
        onMainThreadSync {
            // 兜底：万一 viewWillAppear 时逐词数据还没就绪（歌词仍在路上），这里再挂一次。
            // 已经挂在同一宿主上时 `attach` 会直接 return，不会闪。
            WordByWordHost.shared.attach(
                to: vc,
                sideInset: 24,
                showsProviderFooter: true
            )
        }
    }

    func viewWillDisappear(_ animated: Bool) {
        orig.viewWillDisappear(animated)
        onMainThreadSync {
            // 全屏以 sheet 形式盖在内嵌之上，关闭时内嵌 VC 不会重新 viewDidAppear；
            // 用记住的内嵌 VC 把 overlay 挂回去。
            //
            // C2：交接前先在全屏页上留一张静态替身 —— 否则整段下滑动画期间露出的
            // 是 Spotify 原生歌词 + 纯专辑色背景，也就是"关闭时一闪"。
            WordByWordHost.shared.handOffToInlineKeepingStandIn()
        }
    }

    func viewDidDisappear(_ animated: Bool) {
        orig.viewDidDisappear(animated)
        onMainThreadSync {
            // 关闭动画结束，替身可以撤掉了。
            WordByWordHost.shared.removeStandIn()
        }
    }
}

class LyricsWordByWordFullscreenLegacyHostHook: ClassHook<UIViewController> {
    typealias Group = LegacyLyricsGroup
    static var targetName: String {
        switch EeveeSpotify.hookTarget {
        case .lastAvailableiOS14: return "Lyrics_CoreImpl.FullscreenViewController"
        default: return "Lyrics_FullscreenPageImpl.FullscreenViewController"
        }
    }

    func viewWillAppear(_ animated: Bool) {
        orig.viewWillAppear(animated)
        let vc = target
        // 挂到 vc.view（整屏）。
        //
        // ⚠️ 这里以前会取 `Ivars<UIView>(vc.view).headerView` 并当作
        // `keepAboveView` 传下去，想让原生 header 浮在我们的 overlay 之上。
        // 那个做法已被证伪，参数整个删掉了：
        // · Modern 全屏页上根本没有这个 ivar（`Ivars` 访问不存在的 ivar 是会崩的，
        // 靠的只是"老版本上恰好存在"这种运气）；
        // · 就算取到，原生控件也不在这条视图链上，抬层级影响不到它们。
        //
        // 现在旧 overlay 的显隐完全由"有没有逐词数据"决定：有就画（盖住原生歌词），
        // 没有就整层透明 + 触摸穿透（原生界面与控件原样可用）。
        //
        // ⚠️ 时机从 `viewDidAppear` 提前到 `viewWillAppear`（同 modern hook）：
        // 避免转场动画期间露出 Spotify 自己的全屏歌词。
        onMainThreadSync {
            WordByWordHost.shared.attach(
                to: vc,
                sideInset: 24,
                showsProviderFooter: true
            )
        }
    }

    func viewDidAppear(_ animated: Bool) {
        orig.viewDidAppear(animated)
        let vc = target
        onMainThreadSync {
            // 兜底重挂：已经挂在同一宿主上时 `attach` 会直接 return。
            WordByWordHost.shared.attach(
                to: vc,
                sideInset: 24,
                showsProviderFooter: true
            )
        }
    }

    func viewWillDisappear(_ animated: Bool) {
        orig.viewWillDisappear(animated)
        onMainThreadSync {
            // 同 modern hook：留静态替身 + 把 overlay 挂回内嵌歌词 VC。
            WordByWordHost.shared.handOffToInlineKeepingStandIn()
        }
    }

    func viewDidDisappear(_ animated: Bool) {
        orig.viewDidDisappear(animated)
        onMainThreadSync {
            WordByWordHost.shared.removeStandIn()
        }
    }
}
