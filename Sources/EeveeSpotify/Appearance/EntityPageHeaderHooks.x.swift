// 页头挂点 + 「关于艺人」那一族 hook。从 `EntityPageHeader.x.swift` 原样拆出。
import Foundation
import Orion
import UIKit
import ObjectiveC.runtime

struct EntityPageHeaderGroup: HookGroup {}

/// 主挂点：那一块的布局视图每一拍都会走这里。
///
/// ⚠️ hook 类**不能加 `final`/`private`/`fileprivate`** —— Orion 会生成自己的胶水子类，
/// 2026-10-13 实测报错：`A class hook cannot be private, fileprivate, or final`。
/// 本机 `orion_hook_guard.py` 已加这条规则（规则 5）。
class EntityPageHeaderLayoutHook: ClassHook<UIView> {
    typealias Group = EntityPageHeaderGroup
    static let targetName = "_TtC28EncoreConsumerMobile_BaseKit19HeaderContentLayout"

    func layoutSubviews() {
        orig.layoutSubviews()
        // ★ 2026-10-13：**满幅封面那条路也挂在这一拍上** —— 页面出现的第一帧就把 Spotify 那张
        //   262×262 的小封面藏掉。原来只有 `EntityPageAppearance` 的 0.6s tick 会藏，
        //   而第一帧封面已经画出来了 ⇒ 用户看到的"刚进歌单页小封面短暂展现一会"。
        //   `layoutPass` 是幂等且便宜的（缓存了封面引用），重活仍在 tick 里。
        EntityPageAppearance.layoutPass(in: target)
        EntityPageHeaderManager.apply(in: target)
    }
}

/// ★★ 2026-10-30：**官方生成歌单（This Is / 电台）的备用挂点**。
///
/// 主挂点 `HeaderContentLayout` 在普通歌单页上每帧都来；但这一版 Spotify 的
/// 官方生成歌单有一部分走 `SPTFreeTierPlaylistHeader`（类名在二进制里，
/// 见 `.spotify-ipa/objc-classnames.txt`）。它不一定经过 `HeaderContentLayout`，
/// 所以单独挂一条 `layoutSubviews`。**单独一组** + 装之前先问 `NSClassFromString`：
/// 类不在就只是少一条事件线，不连累主组。
struct EntityPageHeaderExtraGroup: HookGroup {}

class SPTFreeTierPlaylistHeaderLayoutHook: ClassHook<UIView> {
    typealias Group = EntityPageHeaderExtraGroup
    static let targetName = "SPTFreeTierPlaylistHeader"

    func layoutSubviews() {
        orig.layoutSubviews()
        EntityPageAppearance.layoutPass(in: target)
        EntityPageHeaderManager.apply(in: target)
    }
}

/// Spotify 自己那颗 Play：会在前景区晚一步出现，所以它自己那一拍也要补一次。
class EntityPagePlayButtonHook: ClassHook<UIView> {
    typealias Group = EntityPageHeaderGroup
    static let targetName = "_TtC28EncoreConsumerMobile_BaseKit14PlayButtonView"

    func layoutSubviews() {
        orig.layoutSubviews()
        EntityPageHeaderManager.concealPlayButtonIfNeeded(target)
    }
}

/// ★ 2026-10-13：**专辑页的主挂点**。pw 的 `Album/AlbumHeader.x` 也挂在这一拍上
/// （它的 `applyPage` 就是从 `%hook _TtC28CreativeWorkPlatform_PageKit24CreativeWorkTemplateView
/// - (void)layoutSubviews` 进来的）—— 歌单页那个 `HeaderContentLayout` 覆盖的是"那一块"，
/// 而专辑页要的是**整个头**（标题、艺人、kind·日期和操作行分在两个 group 里）。
class EntityPageAlbumLayoutHook: ClassHook<UIView> {
    typealias Group = EntityPageHeaderGroup
    static let targetName = "_TtC28CreativeWorkPlatform_PageKit24CreativeWorkTemplateView"

    func layoutSubviews() {
        orig.layoutSubviews()
        EntityPageHeaderManager.applyToAlbumPage(target)
    }
}

/// ★ 2026-10-13：**艺人页的主挂点**。pw 的 `ArtistField.x` 挂在同一个类上（判据就是页面自己的
/// `accessibilityIdentifier == "creator-page"`，见 `EntityPageHeaderManager.applyToArtistPage`）。
class EntityPageArtistLayoutHook: ClassHook<UIView> {
    typealias Group = EntityPageHeaderGroup
    static let targetName = "_TtC32CreativeWorkPlatform_TemplateKit12TemplateView"

    func layoutSubviews() {
        orig.layoutSubviews()
        EntityPageHeaderManager.applyToArtistPage(target)
    }
}

/// ★★ 2026-10-18 第二轮：**"关于艺人"那一块**（`SPTArtistAboutBiographyView`）自己那一拍 ——
/// 它一出现就把引用交给管理器，`i` 那颗按键才有东西可转发（见 `artistBiographyAppeared`）。
///
/// 这个类**没有 accessibility id**，从页面根 BFS 又太深（深度 20，日志 97 的 `leading MISSING` 就是它），
/// 所以挂它自己：事件驱动、零搜索。
///
/// ⚠️ 家族里的同名卡在别的页面上也有（比如听歌页的"了解艺人"），所以管理器里还有一道
/// `creator-page` 祖先判据 —— 不在艺人页上一个字节都不动。
class ArtistBiographyViewHook: ClassHook<UIView> {
    typealias Group = EntityPageHeaderGroup
    static let targetName = "SPTArtistAboutBiographyView"

    func layoutSubviews() {
        orig.layoutSubviews()
        EntityPageHeaderManager.artistBiographyAppeared(target)
    }
}

/// ★★ 2026-10-11（**日志 101 逐字**）：**这一版真正装着正文的那张卡**。
///
/// 日志 101 两行就是判决：
///   · 迈克尔·杰克逊那次 —— `about-artist found without scrolling —`
///     `_TtC14Creator_ECMKitP33_9A9A9C9886A2DEDE51521D11F82E7F9026CreatorBiographyCardLayout`；
///   · 奈奈塚那次 —— 同一个读者什么都没找到，因为**那一刻卡片还没建出来**。
///
/// 也就是说 `SPTArtistAboutBiographyView` 这个类在这一版页面上**根本不露头**
/// （启动日志里那句 `about-artist hook on` 只说明"类在二进制里"，不等于它会出现）
/// ⇒ "出现即认下"这条事件线一直是**空的**，只有进页面 1.5s 那次扫列表在干活，
/// 而卡片什么时候建出来完全看用户滚不滚。
/// 两个类都挂：**谁先露头谁把正文交出来**（`captureBioTextOnSight`）。
///
/// ⚠️ 它**自己一组**（`ArtistBioCardHookGroup`），**不并进 `EntityPageHeaderGroup`**：
/// 上面那个名字里带 `P33_…` 的私有类，Spotify 换一版就可能改名 —— 并进共用组的话，
/// 一个解析不到的名字有把**整组页头钩子**（页头 / 取色底 / 状态栏）一起拖下水的风险。
/// 单独一组 + 装之前先问一句 `NSClassFromString`（与上游 `ArtistHides` / 本仓库
/// `activatePlayerCardsDeclutter` 同一条纪律）⇒ 最坏情况只是少这一条事件线，日志里写着 MISSING。
struct ArtistBioCardHookGroup: HookGroup {}

/// ★★ 2026-10-18：**Spotify 自己那条"关于艺人"的数据线**（`SPTArtistAboutDataLoader`）。
///
/// 二进制的类 → 方法表（`objc_dump` 脚本解出来的，逐字）：
/// ```
/// - (void)fetchArtistAboutForArtist:(id)artist
///                    withCompletion:(void (^)(SPTArtistAbout *, NSError *))completion
/// 类型编码 v32@0:8@16@?24         ← 第 3 个参数 @? = block
/// 块签名   v24@?0@"SPTArtistAbout"8@"NSError"16
/// ```
/// 装得成 ⇒ `ArtistBioSheet` 的正文与链接直接来自模型（见 `artistAboutDidLoad`），
/// 不再依赖"界面上那张卡建出来没有"。
///
/// ⚠️ 两条如实说：
///   · 这是本仓库**第一个"带 block 参数、还要把替身 block 交给 `orig`"**的 hook —— 参数个数与
///     位置已按类型编码核对（第 3 个是块、第 2 个是对象），但**只有真机能验**；
///   · 所以它**自己一组**、装之前先问 `NSClassFromString`（与 `ArtistBioCardHookGroup` 同一条纪律）
///     ⇒ 类不在/换名 = 只是少这条线，绝不连累页头那一组。
struct ArtistAboutDataHookGroup: HookGroup {}

/// `SPTArtistAboutDataLoader` 的**运行时形状探测**（装 hook 之前问一次）。
///
/// ⚠️ 必须放在 hook 类**外面**：Orion 的预处理会把 `ClassHook` 里的 `static func`
/// 当成"类方法 hook"，直接报
/// `A method hook/addition cannot be static. … If this is a helper function, declare it as private or fileprivate.`
/// —— 而且是在生成 `EeveeSpotify.xc.swift` 那一步就拒绝，后面整条 make 全部连锁失败
/// （2026-10-17 CI 实测）。标 `private` 能过 Orion，但那样又跨不了文件、`EntityPageHeader.x.swift`
/// 里的调用点就取不到 ⇒ 只能搬到类外。守卫见 `Tools/eevee-hookfinder/orion_hook_guard.py` 规则 6。
enum ArtistAboutDataLoaderProbe {

    /// 二进制的类 → 方法表里逐字的那两个名字（别改）。
    static let selectorName = "fetchArtistAboutForArtist:withCompletion:"

    /// 判据只有两条，都从**真实方法**上读（不看我们的声明）：
    ///   · 选择器 `fetchArtistAboutForArtist:withCompletion:` 存在；
    ///   · 类型编码的**形状**对得上：`v`（void 返回）… `@?`（有一个块参数）。
    ///
    /// 真机上是 `v32@0:8@16@?24`（二进制的类 → 方法表逐字），这里只认形状、不认具体数字，
    /// 换一版 Spotify 只要仍是"对象 + 块"就继续装。
    static func canInstall(className: String) -> Bool {
        guard let cls = NSClassFromString(className),
              let method = class_getInstanceMethod(cls, NSSelectorFromString(selectorName)),
              let raw = method_getTypeEncoding(method) else {
            return false
        }
        let encoding = String(cString: raw)
        return encoding.hasPrefix("v") && encoding.contains("@?")
    }

    /// 运行时类型编码（只进日志，排障用）。
    static func typeEncoding(className: String) -> String {
        guard let cls = NSClassFromString(className),
              let method = class_getInstanceMethod(cls, NSSelectorFromString(selectorName)),
              let raw = method_getTypeEncoding(method) else {
            return "-"
        }
        return String(cString: raw)
    }
}

class SPTArtistAboutDataLoaderHook: ClassHook<NSObject> {
    typealias Group = ArtistAboutDataHookGroup
    static let targetName = "SPTArtistAboutDataLoader"

    // ⚠️ 这个类里**只放 hook 方法**：任何 `static func` 都会让 Orion 拒绝生成，
    // 形状探测那两条因此搬去了上面的 `ArtistAboutDataLoaderProbe`。
    func fetchArtistAbout(
        forArtist artist: AnyObject,
        withCompletion completion: @escaping (AnyObject?, Error?) -> Void
    ) {
        orig.fetchArtistAbout(forArtist: artist) { about, error in
            // 只读：先把模型交给管理器（它自己切主线程），再把结果**原样**转发给 Spotify ——
            // 我们不改这次请求的任何语义。
            EntityPageHeaderManager.artistAboutDidLoad(about)
            completion(about, error)
        }
    }
}

class ArtistBiographyCardLayoutHook: ClassHook<UIView> {
    typealias Group = ArtistBioCardHookGroup
    static let targetName =
        "_TtC14Creator_ECMKitP33_9A9A9C9886A2DEDE51521D11F82E7F9026CreatorBiographyCardLayout"

    func layoutSubviews() {
        orig.layoutSubviews()
        EntityPageHeaderManager.artistBiographyAppeared(target)
    }
}
