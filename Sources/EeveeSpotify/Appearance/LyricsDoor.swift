import Foundation

/// 「歌词进播放器」这一层的**状态**——六个旗标的**唯一**存储（纯逻辑：没有 UIKit / Orion 依赖，
/// 所以进得了 CI 的 `swiftc` 链，见 `.github/workflows/tests.yml` 与 `Tests/LyricsDoor`）。
///
/// ## 为什么搬进来
///
/// 这六个数原来散在视图文件里，各自被三四次"修上一个回归"的补丁碰过 ⇒ 谁在什么时候被写、
/// 谁应该跟着谁一起清，只能靠读遍全文才知道；而且**同一条判据在七八处各写一遍**
/// （"屏幕上真的有我们的东西" = `coverHost != nil || lastContainer != nil`）。
/// 现在：
/// · **存储**只在这里（`isOpen` / `wantsOpen` / `intentUntil` / `retryUntil` / `pageLeaving` /
/// `coverGeneration`），"什么组合算哪一相"在 `LyricsDoorPhase.swift` 的规则里，
/// 而**整组一起改**的那几处（点开、过期、收尾、离开页面）是这里的方法 —— 调用方不再各抄一遍；
/// · 视图那边只把 UI 事实（`coverHost != nil || lastContainer != nil`）喂进 `phase(isLive:)`。
///
/// ## 两条窗口（都不是"状态"，是**时间**）
///
/// * `intentUntil`（1.0s）—— 「我们打算铺着」这件事**作数到什么时候**：进播放器的转场里
/// 第一拍常常量不到，但原生封面已经在动了，那一段只有"意图"能救它。
/// 铺上之后意图**一直作数**（`intentStillValid` 里 `isLive` 那一支），这是刻意的：
/// 那时按住原生封面本来就是对的。
/// * `retryUntil`（2.5s ≈ 5 拍）—— 「点了但这一拍没铺上」的**重试**窗口。
/// ⚠️ **只武装一次、不往后推**：每拍重写会让 2.5s 永远不到期，等于在听歌页上无限轮询。
///
/// ## 两个**不是**状态的（故意留在这里、但不是相位）
///
/// * `pageLeaving` —— "页面还在屏上、但正在走"：退出转场里我们**故意什么都不收**，
/// 好让整个动画都是我们的样子。它只作为 `.closing` 的来源出现在相位里。
/// * `coverGeneration` —— 异步收尾的**取消令牌**（收起动画没走完又被点开 ⇒ 这一次收尾作废）。
struct LyricsDoor {

    /// 意图的寿命（秒）。取 1.0：`retryWindow`（2.5s ≈ 5 拍）的第一拍就足够量到，
    /// 而 1s 之内量不到就说明这一程本来就不该铺（没图 / 没词 / 页面没布局完）。
    static let intentLifetime: CFAbsoluteTime = 1.0
    /// 重试窗口（秒）。2.5s ≈ 5 拍。
    static let retryWindow: CFAbsoluteTime = 2.5

    /// 「这次铺上没有回退过」。⚠️ 它在 `beginMountAttempt` 里**先置 true**、铺失败才回退 ——
    /// 所以 `isOpen == true` **不等于**"屏幕上真有东西"（那是 `phase(isLive:)` 的活）。
    var isOpen = false
    /// 「我们打算铺着」。比 `isOpen` 宽一档：意图一立就算数，哪怕这一拍什么都没铺上。
    var wantsOpen = false
    /// 意图作数到什么时候（见 `intentLifetime`）。
    var intentUntil: CFAbsoluteTime = 0
    /// 重试窗口的截止时刻（见 `retryWindow`）。
    var retryUntil: CFAbsoluteTime = 0
    /// 页面还在屏上、但正在离开（退出转场里**什么都不收**）。
    var pageLeaving = false
    /// 封面 morph 的取消令牌。
    var coverGeneration = 0

    // MARK: - 判据（全部转发到 `LyricsDoorRules`，只有一处实现）
    //
    // 这一拍处在哪一相。`isLive` = 屏幕上真有我们的东西（视图层喂进来）。
    func phase(isLive: Bool) -> LyricsDoorPhase {
        LyricsDoorRules.phase(isLive: isLive, wantsOpen: wantsOpen, pageLeaving: pageLeaving)
    }

    /// 意图**现在还作数吗**（铺上了就一直作数）。
    func intentStillValid(now: CFAbsoluteTime, isLive: Bool) -> Bool {
        LyricsDoorRules.intentStillValid(
            wantsOpen: wantsOpen,
            isLive: isLive,
            now: now,
            intentUntil: intentUntil
        )
    }

    /// 「点开了但这一拍没铺上」的重试窗口还开着吗。
    func retryWindowOpen(now: CFAbsoluteTime) -> Bool {
        LyricsDoorRules.retryWindowOpen(now: now, retryUntil: retryUntil)
    }

    // MARK: - 整组操作（调用方不再各抄一遍"这几个一起改"）
    //
    // 点开 / 记忆要展开：**意图 + 寿命一起立**（意图不许永久挂着）。
    mutating func openIntent(at now: CFAbsoluteTime) {
        wantsOpen = true
        intentUntil = now + Self.intentLifetime
    }

    /// 意图过期（铺不上而窗口已过）：调用方负责把原生封面写回去。
    mutating func expireIntent() {
        wantsOpen = false
        intentUntil = 0
    }

    /// 清掉重试窗口（铺上了 / 这一首没东西可画 / 用户被告知没词）。
    mutating func clearRetryWindow() {
        retryUntil = 0
    }

    /// 一次失败之后**按需**武装重试窗口 —— 只在窗口没开着的时候武装。
    mutating func armRetryWindowIfNeeded(at now: CFAbsoluteTime) {
        if now >= retryUntil { retryUntil = now + Self.retryWindow }
    }

    /// 全部归位（收尾 / 关开关 / 离开页面）。
    ///
    /// ⚠️ 这五样原来是在 `closeEverything` 里逐个写的，正是"漏写一个就留残迹"的形状 ——
    /// 收在这里之后，`Tests/LyricsDoor` 有一条用例专门钉"关完之后每一项都干净"。
    mutating func close() {
        isOpen = false
        wantsOpen = false
        intentUntil = 0
        retryUntil = 0
        pageLeaving = false
    }

    /// 进页面 = 这一程开始（上一次的"要走了"作废）。
    mutating func pageDidAppear() {
        pageLeaving = false
    }

    /// 收起转场开始（`viewWillDisappear`）：**只记一笔，什么都不收**。
    mutating func pageWillLeave() {
        pageLeaving = true
    }

    /// 取一个新的封面 morph 令牌（单调递增，永不重置）。
    mutating func nextCoverGeneration() -> Int {
        coverGeneration += 1
        return coverGeneration
    }
}
