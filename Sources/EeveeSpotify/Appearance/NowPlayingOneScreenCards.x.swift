import Orion
import UIKit

/// 把听歌页列表里**每一种卡片**的高度报成 0 —— 列表于是自己合拢，播放器就是一屏。
///
/// 借鉴：**spoti.pw v0.21.1**（GPL-3.0）`tweak/Sources/Redesigned/Player/PlayerCards.x`；
/// 落地是我们的 Swift 实现。评估见 `Tools/eevee-hookfinder/SPOTIPW_0211_PORT_ASSESSMENT.md`。
///
/// ## 为什么是"拦所有卡片"，而不是"点名藏掉几种"
///
/// 卡片是**服务端**决定给哪几张的（`[NPVModule]` / scrollsita 那套元素树），
/// Spotify 以后加一种新卡不该又冒到播放器底下。**拦一个类别，比列一张名单耐用。**
///
/// ## 判据（pw 的真机树结论，日志 38 的树也吻合）
///
/// 每张卡片都是 `Element_List.CollectionViewCell`（9.1.88 dump 里在，line 189），
/// 它的第一个子视图是**命名 `NowPlaying_ScrollAPI`** 的 `ElementContentView`。
/// 卡片**内部**那些列表的 cell 命的是别的 API（`WatchFeed_ComponentAPI`），
/// 所以不会被误伤 —— 这正是"只认播放器那张列表"的判据。
///
/// ## 纪律
///
/// * 开关（`UserDefaults.nowPlayingOneScreen`）是在**方法体内**读的：关掉即立刻不再折叠，
///   不需要重启（`apply`/`restore` 那边负责把 inset 写回）；
/// * 只改**我们返回的那份** `UICollectionViewLayoutAttributes` —— Spotify 自己的布局属性
///   我们一字节都不动；
/// * 判据按**内容视图的类**缓存（pw 同做法）：一次字符串判断之后就是两次集合查找。
class PlayerCardCollapseHook: ClassHook<UICollectionViewCell> {
    typealias Group = ModernLyricsGroup

    static var targetName = "_TtC12Element_List18CollectionViewCell"

    /// 判据只跟"内容视图的类"有关 ⇒ 按类缓存结论，两种类各一个集合。
    private static var playerCardClasses: Set<ObjectIdentifier> = []
    private static var otherCardClasses: Set<ObjectIdentifier> = []
    /// 已经上报过的卡片种类（只上报前若干种，够看清"拦到了什么"就行）。
    private static var loggedRoots: Set<String> = []
    private static let maxLoggedRoots = 24

    func preferredLayoutAttributesFittingAttributes(
        _ attributes: UICollectionViewLayoutAttributes
    ) -> UICollectionViewLayoutAttributes {
        let result = orig.preferredLayoutAttributesFittingAttributes(attributes)

        guard NowPlayingOneScreen.isEnabled else { return result }
        // ⚠️ hook 方法里钩到的对象是 **`self.target`**，`self` 是 hook 类自己 ——
        // 写成 `self` 会编不过（`PlayerCardCollapseHook` 不是 UIView）。
        // 仓库里既有的 hook（`DeclutterChrome` / `TabBarGlass` / `LibraryAppearance` …）
        // 全是 `self.target` 这个写法；本仓库的 `orion_hook_guard.py` 现在也会拦这一条。
        guard PlayerCardCollapseHook.isPlayerCard(self.target) else { return result }

        // 高度报 0 ⇒ 列表把它当"没有这张卡"，自己合拢。
        result.size = CGSize(width: result.size.width, height: 0)
        self.target.clipsToBounds = true
        PlayerCardCollapseHook.reportOnce(self.target)

        // ★ 折完立刻请"钉住"那边重算一次（合并、异步一帧）。
        //   为什么不能只靠进页面那一次：卡片**是播放器之后很久才到的**，
        //   那时按公式算出来是"内容还没到一屏高 ⇒ 不压"，之后就没机会改了 ——
        //   用户实测的表现就是"卡片没了，但还能往下滑"（2026-10-03 夜）。
        NowPlayingOneScreen.noteCardCollapsed()
        return result
    }

    /// 这个 cell 装的是不是播放器那张列表里的卡片。
    ///
    /// **两条判据，任一命中就算**（第一条最硬，跟类名怎么变都无关）：
    ///
    /// 1. **它挂在 `NowPlayingOneScreen` 钉住的那张列表下面** —— 我们是从
    ///    `accessibilityIdentifier` 认列表的（日志 38 的树里就有），不依赖任何类名。
    /// 2. pw 那条：内容视图的**混淆类名**里含 `NowPlaying_ScrollAPI`。
    ///    ⚠️ 9.1.88 上我们只证到**反混淆**形态：真机树里是
    ///    `ElementContentView<ItemIdentifier, AnyBaseElement<NowPlayingScrollData, NoData>>`
    ///    （日志 38 的 #7/#8/#9）—— 而 `NSStringFromClass` 给的是**混淆名**
    ///    （`_TtGC13Element_UIKit18ElementContentView…`），模块名会不会漂没有证据。
    ///    所以这里**两个串都认**，第一条兜底。
    private static func isPlayerCard(_ cell: UICollectionViewCell) -> Bool {
        if NowPlayingOneScreen.isInsidePinnedList(cell) { return true }

        guard let content = cell.subviews.first else { return false }

        let key = ObjectIdentifier(type(of: content))
        if otherCardClasses.contains(key) { return false }
        if playerCardClasses.contains(key) { return true }

        let name: String = NSStringFromClass(type(of: content))
        let isPlayer: Bool = name.contains("NowPlaying_ScrollAPI")
            || name.contains("NowPlayingScrollData")

        if isPlayer {
            playerCardClasses.insert(key)
        } else {
            otherCardClasses.insert(key)
        }
        return isPlayer
    }

    /// 每种卡片只报一次根类名 —— 日志里能看清"到底拦到了哪些卡"，且不刷屏。
    private static func reportOnce(_ cell: UICollectionViewCell) {
        guard loggedRoots.count < maxLoggedRoots else { return }
        guard let content = cell.subviews.first else { return }
        guard let inner = content.subviews.first, let root = inner.subviews.first else { return }

        let name = NSStringFromClass(type(of: root))
        guard !loggedRoots.contains(name) else { return }
        loggedRoots.insert(name)
        writeDebugLog("[OneScreen] collapsed card root \(name)（第 \(loggedRoots.count) 种）")
    }
}
