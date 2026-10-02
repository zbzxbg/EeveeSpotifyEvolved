import Foundation

/// 「这一次歌词请求要等多久」+「刚产出的 payload 直接复用」（v4.11）。
///
/// ## 为什么需要它（真机证据：2026-10-02 日志 34，Spotify 9.1.88）
///
/// NPV 的模块列表是**「组件加载完之后」**才建的（`…WithDidLoadComponents…`），而那张
/// 预览歌词卡片就是**我们这次响应**喂出来的。同一首「全网都没词」的歌，四档实测：
///
/// | 歌词回退设置 | 首轮 请求→响应 | 卡片 |
/// |---|---|---|
/// | 不回退 | **≤1 秒** | 在 |
/// | ＋Genius 回退 | 4 秒 | 开始丢 |
/// | ＋AMLL 优先 | 6 秒 | 更差 |
/// | 多级回退（4 源串行） | **13 秒** | 最差 |
///
/// ⇒ 响应晚于大约 **1~4 秒**就赶不上建列表那一刻；「退出重进就好」是因为重进等于让列表
/// 重建一次（那时连接和结果都热了）。
///
/// ## 于是这里做两件事
///
/// 1. **分档预算**：同一首歌的**第一次**请求只等 `firstAttemptBudget` —— 把占位早点交出去，
///    让卡片先建出来；**后续**请求才用长预算。依据是 Spotify 在我们交完占位之后会
///    **立刻**再请求一次（日志 34 里 4/4 都来了），那一次正好把真词带上去。
/// 2. **单条结果备忘**：刚产出的 payload 直接复用 → 那第二次请求 **0 等待**
///    （日志 34 里它白跑了整条链，整整 4 秒）。
///
/// ## 为什么是「单条备忘」而不是「按曲目做缓存」
///
/// 只记住**最近一次**产出的 payload，并且要求「曲目 id + 设置签名」都对得上才复用：
///
/// * 覆盖住了真正要救的那条路（同一首歌的立刻重请求）；
/// * **A→B→A 这种来回切不会命中**（备忘里是 B）→ 照旧走完整条链，于是
///   `resetWordByWordLyrics` / `currentLyricsDto` / 逐词层那套状态都会照常更新，
///   不会出现「卡片换成了新歌、我们自己的层还挂着旧歌」；
/// * **绝不会把别的歌的词串过来**（键里有 track id）。
///
/// ⚠️ 另外要记住：Spotify **自己**也按曲目缓存歌词（服务端响应头
/// `Cache-Control: public, max-age=3600`，而我们是**伪装成那次响应**交回去的）。
/// 那一份我们清不掉 —— 所以「改了歌词来源，已经听过的歌不会立刻重取」，只能重启 App
/// （详见 `SESSION_2026-10-02_HANDOFF.md` §14）。这里的设置签名只保证**我们自己这一层**
/// 不会拿旧设置的结果去糊弄。
final class LyricsResponseCache {

    static let shared = LyricsResponseCache()

    /// 第一次请求的等待上限。
    ///
    /// 取 1.5s：档① 的「≤1 秒 → 卡片一定在」是实测安全区，而 4 秒那一档已经开始丢，
    /// 1.5s 留了余量又没越界。注意 `getLyricsDataForCurrentTrack` 内部还有一段最多
    /// **3 秒**的「等播放器元数据跟上」的循环（切歌瞬间常会吃掉一部分），所以这首歌的
    /// 第一次请求大概率交的是占位 —— 那正是我们要的：**先把卡片建出来**，
    /// 内容交给紧接着的第二次请求。
    static let firstAttemptBudget: TimeInterval = 1.5

    /// 后续请求的等待上限：沿用原来的 18 秒。卡片此时已经建出来了，晚到只影响内容。
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

    /// 当前设置签名 —— 只包含**会改变 payload** 的项：来源 / Genius 兜底 / AMLL 优先。
    static var currentSignature: String {
        let source = String(describing: UserDefaults.lyricsSource)
        let genius = UserDefaults.lyricsOptions.geniusFallback ? "1" : "0"
        let amll = NgzhwmSettingsViewModel.isAmllPreferred ? "1" : "0"
        return "\(source)|\(genius)|\(amll)"
    }

    /// 这一次请求该怎么等：直接交备忘 / 短预算 / 长预算。
    func plan(forPath path: String, signature: String) -> Plan {
        lock.lock()
        defer { lock.unlock() }

        if currentPath != path {
            currentPath = path
            currentPathCount = 0
        }
        let count = currentPathCount
        currentPathCount += 1

        if let memo,
           memo.path == path,
           memo.signature == signature,
           Date().timeIntervalSince(memo.storedAt) < ttl {
            return .cached(memo.payload)
        }

        return count == 0 ? .firstAttempt : .followUp
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
