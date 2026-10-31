import Foundation

/// 「这一次歌词请求要等多久」+「刚产出的 payload 直接复用」。
///
/// NPV 的模块列表是「组件加载完之后」才建的，而预览歌词卡片就是这次响应喂出来的。同一首「全网都没词」的歌实测：不回退 ≤1 秒（卡片在）、＋Genius 回退 4 秒（开始丢）、＋AMLL 优先 6 秒、多级回退（4 源串行）13 秒 ⇒ 响应晚于约 1~4 秒就赶不上建列表那一刻；「退出重进就好」是因为重进等于让列表重建一次。
///
/// 于是这里做两件事：
/// 1. **分档预算**：同一首歌的第一次请求只等 `firstAttemptBudget`，把占位早点交出去让卡片先建出来；后续请求才用长预算 —— 依据是 Spotify 在我们交完占位之后会立刻再请求一次，那一次正好把真词带上去。
/// 2. **单条结果备忘**：刚产出的 payload 直接复用 ⇒ 那第二次请求 0 等待。
///
/// 为什么是「单条备忘」而不是「按曲目做缓存」：只记住最近一次产出的 payload，并且要求「曲目 id + 设置签名」都对得上才复用。这样覆盖住了真正要救的那条路（同一首歌的立刻重请求），而 A→B→A 来回切不会命中（备忘里是 B）⇒ 照旧走完整条链，`resetWordByWordLyrics` / `currentLyricsDto` / 逐词层那套状态都会照常更新，不会出现「卡片换成了新歌、我们自己的层还挂着旧歌」；键里有 track id，也不会把别的歌的词串过来。
///
/// ⚠️ Spotify **自己**也按曲目缓存歌词（服务端响应头 `Cache-Control: public, max-age=3600`，而我们是伪装成那次响应交回去的）。那一份我们清不掉 —— 所以「改了歌词来源，已经听过的歌不会立刻重取」，只能重启 App。这里的设置签名只保证**我们自己这一层**不会拿旧设置的结果去糊弄。
final class LyricsResponseCache {

    static let shared = LyricsResponseCache()

    /// 第一次请求的等待上限 —— **18s，与后续请求相同**（早先试过 1.5s，已撤销）。
    ///
    /// ## 为什么把 1.5s 撤掉
    ///
    /// 所以这里回到"**只交**真结果"，代价是**响应时间 = 取词链的耗时**（本机实测 5~15s），
    /// 换来的是**卡片里不可能再锁死假状态**。备忘复用、计数、`[DL]/[HCUS]` 结果行全部保留。
    static let firstAttemptBudget: TimeInterval = 18

    /// 后续请求的等待上限：与第一次相同（留作可调点）。
    static let followUpBudget: TimeInterval = 18

    /// 结果备忘的有效期。只覆盖「立刻重请求」那一小段，避免拿旧结果糊弄人。
    private let ttl: TimeInterval = 60

    enum Plan: Equatable {
        /// 刚产出过、且曲目与设置都没变 → 直接交这份，一秒都不等。
        case cached(Data)
        /// 这首歌的第一次请求 → 短预算。
        case firstAttempt
        /// 后续请求（多半就是 Spotify 交完占位后的那次立刻重请求）→ 长预算。
        case followUp
    }

    /// 「这一次请求该怎么等」+「是这一首的第几次」+「用的是哪一档预算」。
    ///
    /// ⚠️追加（`HttpClientURLSessionHooks` 对齐用）：
    ///
    /// 这套调度**原先只长在 `DataLoaderServiceHooks`（`SPTDataLoaderService`）那一条路上**。
    /// 歌词响应走的是 `Connectivity_HttpClientKit.HttpClientURLSession`，
    /// 于是「分档预算 + 结果备忘」**一次都没有真正生效**。
    ///
    /// 现在两条路共用本类型（同一个共享实例、同一套计数），并且**两条路都打结果行**；
    struct BudgetPlan {
        /// 复用/短预算/长预算（语义同上面的 `Plan`）。
        let plan: Plan
        /// 这首曲目（同一个 `path`）在本轮里是第几次请求 —— 从 1 开始。
        let attempt: Int
        /// 本档预算（秒）。调用方**必须**拿它当 `semaphore.wait` 的上限。
        let budget: TimeInterval
        /// 「首次」还是「后续」—— 只用于日志。
        var isFirstAttempt: Bool { plan == .firstAttempt }
    }

    private struct Memo {
        let path: String
        let signature: String
        let payload: Data
        let storedAt: Date
    }

    private let lock = NSLock()
    private var memo: Memo?

    /// 上一次来的那条 URL（= 上一首）+ 它已经来过几次。
    ///
    /// ⚠️ 只在**同一首连续请求**时累加：一旦请求的是另一首就从头算。因为"第几次请求"的
    /// 语义是「这一首、这一轮播放里第几次」，不是「这首歌历史上一共几次」——
    /// 否则 A→B→A 回到 A 时会被判成"后续请求"→ 用长预算 → **又赶不上建列表那一刻**。
    private var currentPath: String?
    private var currentPathCount = 0

    /// 当前设置签名 —— 只包含**会改变 payload** 的项：来源 / Genius 兜底 / AMLL 优先 /
    /// 「实验 → Apple Music 官方 TTML」。
    ///
    /// 那个实验必须进来。它是**总覆盖**的开关，却**不改** `lyricsSource` ——
    /// 少了这一项，用户在 60 秒的备忘 TTL 内打开它、又重听同一首，交出去的还是刚才那个源
    /// 产出的 payload（看起来就是"实验没生效，要重启"）。
    static var currentSignature: String {
        let source = String(describing: UserDefaults.lyricsSource)
        let genius = UserDefaults.lyricsOptions.geniusFallback ? "1" : "0"
        let amll = NgzhwmSettingsViewModel.isAmllPreferred ? "1" : "0"
        let officialTtml = UserDefaults.experimentsOptions.appleMusicOfficialTtml ? "1" : "0"
        return "\(source)|\(genius)|\(amll)|\(officialTtml)"
    }

    /// 这一次请求该怎么等：直接交备忘 / 短预算 / 长预算 + 第几次 + 预算秒数。
    ///
    /// ⚠️ 计数只在**同一首连续请求**时累加（见 §「A→B→A」那段说明）；
    /// **命中备忘时不计数** —— 备忘命中是"结论"，不是"又试了一次"。
    func budgetPlan(forPath path: String, signature: String) -> BudgetPlan {
        lock.lock()
        defer { lock.unlock() }

        if currentPath != path {
            currentPath = path
            currentPathCount = 0
        }

        if let memo,
           memo.path == path,
           memo.signature == signature,
           Date().timeIntervalSince(memo.storedAt) < ttl {
            return BudgetPlan(plan: .cached(memo.payload), attempt: 0, budget: 0)
        }

        let count = currentPathCount
        currentPathCount += 1
        let plan: Plan = count == 0 ? .firstAttempt : .followUp
        return BudgetPlan(
            plan: plan,
            attempt: count + 1,
            budget: count == 0 ? Self.firstAttemptBudget : Self.followUpBudget
        )
    }

    /// 这一次请求最后交出去的是什么 —— **两条路都必须报**。
    ///
    /// 只有这样才能从日志分清三件事（这正是 v4.11 验收缺的那一块）：
    /// * 备忘命中（`memo hit`）→ 调度真的生效了；
    /// * 短预算超时后交占位（`placeholder (firstAttempt)`）→ 卡片保住了，
    /// **接下来那次请求必须把真词带上**；
    /// * 后续请求也超时（`placeholder (followUp)`）→ 这次只有占位，要盯着有没有第三次。
    enum Outcome {
        /// 备忘命中，一个字节都没等。
        case memoHit(bytes: Int)
        /// 真结果（含"查完确认没有词"的结论）：字节数 + 实际耗时。
        case fetched(bytes: Int, elapsed: TimeInterval)
        /// 预算内没结论 → 交了占位。
        case placeholder(dueToTimeout: Bool, elapsed: TimeInterval)
        /// 连占位都构造不出来 → 只能放行 Spotify 原始响应。
        case passthrough(hadData: Bool, timedOut: Bool, elapsed: TimeInterval)
    }

    func recordOutcome(_ outcome: Outcome, route: String, plan: BudgetPlan) {
        switch outcome {
        case let .memoHit(bytes):
            writeDebugLog("[\(route)] lyrics memo hit — \(bytes) bytes, 0 wait (request \(plan.attempt))")
        case let .fetched(bytes, elapsed):
            writeDebugLog(
                "[\(route)] lyrics fetched — \(bytes) bytes, \(Self.format(elapsed))s"
                    + " (request \(plan.attempt), \(plan.isFirstAttempt ? "first" : "follow-up"), budget \(plan.budget)s)"
            )
        case let .placeholder(dueToTimeout, elapsed):
            writeDebugLog(
                "[\(route)] ⚠️ no real lyrics this time (budget \(plan.budget)s, \(plan.isFirstAttempt ? "first" : "follow-up") request)"
                    + " - this route **only delivers real results**, so Spotify's original response passes through"
                    + (dueToTimeout ? " (timed out)" : " (fetch error)")
                    + " | \(Self.format(elapsed))s elapsed, request \(plan.attempt)"
            )
        case let .passthrough(hadData, timedOut, elapsed):
            writeDebugLog(
                "[\(route)] lyrics passthrough (original response passed through) — hadData=\(hadData) timedOut=\(timedOut)"
                    + " | \(Self.format(elapsed))s elapsed, request \(plan.attempt)"
            )
        }
    }

    private static func format(_ interval: TimeInterval) -> String {
        String(format: "%.1f", interval)
    }

    /// 记下这一次真正产出的 payload（**占位不要存** —— 那是「还不知道」，不是结论）。
    func store(_ payload: Data, forPath path: String, signature: String) {
        lock.lock()
        defer { lock.unlock() }
        memo = Memo(path: path, signature: signature, payload: payload, storedAt: Date())
    }

    /// 清空（目前只在「歌词功能被关掉」这类明确场景需要）。
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        memo = nil
        currentPath = nil
        currentPathCount = 0
    }
}
