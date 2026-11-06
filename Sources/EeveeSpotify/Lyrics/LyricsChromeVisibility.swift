import UIKit

// ── 关于 main-actor 隔离：一个踩过的坑
//
// ⚠️ **不要在 Orion 的 hook 方法（覆写的那几个）上写 `@MainActor`。**
//
// Orion 会把 hook 类里的方法改写成 `override` + 一段 C 跳板，而它的代码生成器
// 是**按源码文本拼接**的：`@MainActor` 会被拼成 `@MainActoroverride`（非法属性），
// 连带 `override` 关键字一起丢掉，最后生成出一堆语法错误，
// 并且生成的跳板是**非隔离**的，同步调用被标成 `@MainActor` 的方法又成了隔离违规。
//
// 正确做法：hook 方法保持非隔离（Orion 生成什么就是什么），在方法体里用
// `onMainThreadSync { ... }` 把主线程这件事显式表达出来。
//
// ── 顺带说清"谁是主线程"
// UIKit 的生命周期回调（viewDidAppear / viewWillDisappear）本来就在主线程，
// 所以 `assumeIsolated` 不会失败；万一哪天不是，这里会退回 async 派发，而不是崩。
//
// 在 main actor 上**同步**执行一段代码。
//
// 用于 Orion 的 hook 方法体里：那些方法在编译期是"非隔离"的，不能直接碰
// `@MainActor` 的类型（例如 `WordByWordHost`、`AppleMusicLyricsOverlayHost`）。
// 已经是主线程时立即执行（不改变时序，`viewWillDisappear` 里的清理必须是同步的）；
// 万一不是，则异步派发到主线程。
func onMainThreadSync(_ body: @escaping @MainActor () -> Void) {
    if Thread.isMainThread {
        MainActor.assumeIsolated(body)
    } else {
        DispatchQueue.main.async {
            MainActor.assumeIsolated(body)
        }
    }
}

