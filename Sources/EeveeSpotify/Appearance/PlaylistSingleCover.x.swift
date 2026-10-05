import Foundation
import ObjectiveC.runtime
import Orion

/// 歌单封面：**四宫格 → 第一张的单张封面**（用户第 5 轮问的那条）。
///
/// ── 那个四宫格是什么（2026-10-13 用 IPA 与真地址查清，不是推测）──────────────
///
/// 1. **不是视图层拼的**，地址里就串着四张图的 id：
///    `https://mosaic.scdn.co/<size>/<id1><id2><id3><id4>`（每张 40 位十六进制）。
///    IPA 的 `__cstring` 里逐字有模板串 `https://mosaic.scdn.co/%lu/%@`
///    （file 偏移 185784143，紧挨着 `https://i.scdn.co/image/%@`）。
/// 2. **服务端本来就有"只有一张"的那一档**（本机实测，`curl` 的结果逐字如下）：
///      · `mosaic.scdn.co/640/<1 个 id>` → 200 `image/jpeg`，640×640，88 KB ← **正常单张封面**
///      · `mosaic.scdn.co/300/<1 个 id>` → 200 `image/jpeg`，300×300
///      · `mosaic.scdn.co/640/<4 个 id>` → 200 `image/jpeg`，640×640，98 KB（四宫格）
///      · `mosaic.scdn.co/640/<2 个 id>` → **404**
///    ⇒ **把路径截到第一个 40 位 id 就是"只显示一首"**：不换 host、不自己裁图。
/// 3. 负责这件事的类（从 IPA 的 ObjC 元数据里**逐个解出来**的，不是猜的）：
///    `SPTMosaicImageLoaderRequest`，45 个自有方法，其中：
///      · `-initWithURL:sourceIdentifier:downloadSize:requestedSize:scale:allowUpscaling:`
///        `context:dataLoader:delegate:callback:baseImageLoader:`（构造时就带 URL）
///      · `-load` / `-loadMosaic`（两个都零参数）、`-cancel`
///      · **`-buildSingleImage` / `-buildMosaicImage`** —— "只有一张时怎么装"这条路
///        本来就存在，我们收窄 URL 之后走的就是 Spotify 自己写的那条。
///    它自己的断言串也在：`com.spotify.imageloader.mosaic` + `SPTMosaicImageLoaderRequest.m`
///    + `!imageURL.isMosaicURL`（⇒ 它拿到的一定已经是 mosaic 地址，我们改这里正对）。
///
/// ── 挂哪儿：`load` / `loadMosaic` / `URL` ─────────────────────────────────
///
/// 在它**把路径拆成 `mosaicParts` 之前**把地址收成第一张。三个入口都挂、且幂等
/// （第一张的地址再收一次还是它自己），因为"拆路径到底发生在哪一步"只有真机日志能判：
///   · `load` / `loadMosaic` 是加载入口；
///   · `URL` 的 getter 是**更早的读者**（`initWithURL:…` 里就可能读过一次，那一读在 load 之前）。
/// 收窄之后**写回对象的 `_URL`**（不是只在 getter 里换个返回值）—— 这样后面任何
/// 读 ivar 的代码拿到的也已经是那一张。
///
/// ⚠️⚠️ **千万不要写 `setURL:`**（上一版就是这么写的，那条路是死的）：
/// 这个类的 `URL` 在 IPA 属性表里逐字是 `T@"NSURL",R,N,V_URL` —— `R` = **只读**，
/// 它**没有** `setURL:`。上一版的 `guard request.responds(to: "setURL:") else { return }`
/// 会**每次都提前返回**，一个字节都改不到（看起来"装上了但没效果"）。
/// 现在改成**直接写它的 ivar `_URL`**（`object_setIvar`，ARC 正确），
/// 读不出来才退回 KVC（KVC 对只读属性会走 `_URL` 的 ivar 兜底）。
///
/// 为什么不挂那两条"更正统"的路（都在 IPA 里，签名也核过）：
///   · `SPTMosaicImageLoaderRequest` 的 11 参构造、以及
///     `SPTMosaicImageRequestFactory -provideImageLoaderRequestForURL:…`（12 参，工厂只有这一个方法）：
///     两个 `CGSize` 与 `double`/`BOOL` 夹在中间，本机**没有 Swift 编译器**，
///     类型只能靠读元数据核对 ⇒ 签名越短越不可能在 Orion 代码生成上出错。**不冒这个险**。
///
/// ── 纪律 ─────────────────────────────────────────────────────────────────
///
/// · **只动 `mosaic.scdn.co` 这一个 host**，而且只在"末段是 40 的整数倍、且比 40 长"时动；
///   看不懂的形状一律放过 —— 宁可不动，也不要拼出一个不存在的地址；
/// · 一路 `responds(to:)` + KVC/ivar 门禁：读不出来就当没这回事（不猜、不崩）；
/// · **开关关掉 = 一个字节都不改**（`UserDefaults.playlistSingleCover`）；
/// · 日志里 `rewrote N mosaic URL(s)` 是验收判据；`numberOfParts` 是"拆在哪一步"的判据：
///      · 在 `loadMosaic` 那一行读到 **1** ⇒ 拆路径是懒的，本版生效；
///      · 读到 **4** ⇒ 构造时就拆好了 ⇒ 下一版才轮到去挂那个 11 参构造。
///
/// 对照仓库（**spoti.pw 并没有这个功能**，用户以为它有）：v0.22.0（2026-09-23）全树只有
/// 封面**显示**相关的做法（`PlaylistHeader.x` 的 `followCover:` hero、`Native/Playlist/Playlist.x`
/// 的"隐藏封面"collapsing、`Redesigned/*` 的圆角），CHANGELOG 与 docs 全篇没有
/// mosaic / 单张封面；全语言文案里也没有这一条。
struct PlaylistSingleCoverGroup: HookGroup {}

/// 纯函数：只认得"四宫格地址 → 第一张的地址"这一种改写，其余一律 nil。
enum SingleMosaicCover {
    static let host = "mosaic.scdn.co"
    /// 一张专辑封面的 id 长度（`spotify:image:<16 位尺寸><24 位摘要>`，共 40 位十六进制）。
    static let idLength = 40

    /// 路径里那串拼起来的 id（`<id1><id2>…`）；看不懂 → nil。
    static func packedIDs(of url: URL) -> String? {
        guard url.host == host else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard let last = parts.last,
              last.count > idLength,
              last.count % idLength == 0,
              last.allSatisfy({ $0.isHexDigit })
        else { return nil }
        return last
    }

    /// 四宫格地址 → 只含第一张的地址；不是四宫格 / 看不懂 / 本来就只有一张 → nil。
    static func single(from url: URL) -> URL? {
        guard let packed = packedIDs(of: url), packed.count > idLength else { return nil }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var parts = url.pathComponents.filter { $0 != "/" }
        parts[parts.count - 1] = String(packed.prefix(idLength))
        components?.path = "/" + parts.joined(separator: "/")
        return components?.url
    }

    /// 这个地址里有几张（看不懂 → 0）。
    static func partCount(in url: URL) -> Int {
        guard let packed = packedIDs(of: url) else { return 0 }
        return packed.count / idLength
    }
}

// MARK: - 门禁与日志（放文件作用域：hook 类里只留 Orion 认的那几样）

/// 这一场里改写了几条、报了几条（日志只报前几条，避免刷屏）。
private var singleCoverRewrites = 0
private var singleCoverReports = 0

/// 对象上的 `URL`（读不出来 → nil）。
private func singleCoverURL(of request: NSObject) -> URL? {
    guard request.responds(to: NSSelectorFromString("URL")) else { return nil }
    return request.value(forKey: "URL") as? URL
}

/// 对象上的 `numberOfParts`（读不出来 → -1）。
private func singleCoverPartCount(of request: NSObject) -> Int {
    guard request.responds(to: NSSelectorFromString("numberOfParts")) else { return -1 }
    return (request.value(forKey: "numberOfParts") as? NSNumber)?.intValue ?? -1
}

/// 把新地址写回去。**`URL` 是只读属性（没有 `setURL:`）** ⇒ 直接写它的 ivar `_URL`。
/// 返回 false = 两条路都不通（那就什么都不改）。
private func writeSingleCoverURL(_ url: URL, to request: NSObject) -> Bool {
    if let ivar = class_getInstanceVariable(type(of: request), "_URL") {
        object_setIvar(request, ivar, url as NSURL)
        return true
    }
    guard request.responds(to: NSSelectorFromString("setURL:")) else { return false }
    request.setValue(url as NSURL, forKey: "URL")
    return true
}

/// 收窄一个地址并**写回对象**（幂等）。
/// 返回 nil = 没动（开关关着 / 不是四宫格 / 写不进去），调用方就当原来的地址用。
private func narrowMosaicURL(_ url: URL, of request: NSObject, at stage: String) -> URL? {
    guard UserDefaults.playlistSingleCover else { return nil }
    let parts = SingleMosaicCover.partCount(in: url)
    guard parts > 1, let single = SingleMosaicCover.single(from: url) else { return nil }
    guard writeSingleCoverURL(single, to: request) else { return nil }

    singleCoverRewrites += 1
    if singleCoverRewrites <= 8 {
        writeDebugLog(
            "[SingleCover] \(stage): rewrote \(singleCoverRewrites) mosaic URL(s), \(parts) covers -> 1"
                + " (\(url.absoluteString) -> \(single.absoluteString))"
        )
    } else if singleCoverRewrites % 50 == 0 {
        writeDebugLog("[SingleCover] rewrote \(singleCoverRewrites) mosaic URL(s) so far")
    }
    return single
}

/// 报一次"这个请求此刻认为有几张"——判"拆路径发生在哪一步"的**唯一**判据。
/// 打在 `orig` **之前**：那正是加载代码马上要读到的那个值。
private func reportMosaicParts(of request: NSObject, at stage: String) {
    singleCoverReports += 1
    guard singleCoverReports <= 8 else { return }
    writeDebugLog(
        "[SingleCover] \(stage): numberOfParts=\(singleCoverPartCount(of: request))"
            + " URL=\(singleCoverURL(of: request)?.absoluteString ?? "(nil)")"
    )
}

// MARK: - 歌单封面的请求

/// 加载入口：拆路径之前先把地址收成第一张。
class SPTMosaicImageLoaderRequestHook: ClassHook<NSObject> {
    typealias Group = PlaylistSingleCoverGroup
    static let targetName = "SPTMosaicImageLoaderRequest"

    func load() {
        if let url = singleCoverURL(of: self.target) {
            _ = narrowMosaicURL(url, of: self.target, at: "load")
        }
        reportMosaicParts(of: self.target, at: "load")
        orig.load()
    }

    func loadMosaic() {
        if let url = singleCoverURL(of: self.target) {
            _ = narrowMosaicURL(url, of: self.target, at: "loadMosaic")
        }
        reportMosaicParts(of: self.target, at: "loadMosaic")
        orig.loadMosaic()
    }
}

/// `URL` 的 getter：`initWithURL:…` 里就可能读过一次地址（那一读在 `load` 之前），
/// 这一层把"更早的读者"也一起收进来，并且**写回对象**（所以只会记一笔，不会每次都记）。
/// ⚠️ 这里**不读 KVC**（那会再调一次本 getter）—— 只用 `orig.URL()` 的原值。
class SPTMosaicImageLoaderRequestURLHook: ClassHook<NSObject> {
    typealias Group = PlaylistSingleCoverGroup
    static let targetName = "SPTMosaicImageLoaderRequest"

    func URL() -> NSURL? {
        guard let original = orig.URL() else { return nil }
        guard let narrowed = narrowMosaicURL(original as URL, of: self.target, at: "URL") else {
            return original
        }
        return narrowed as NSURL
    }
}

/// 装这一组。目标类缺失就只打一行日志、不留给 Orion 报非致命错误（本仓库既有做法）。
///
/// ⚠️ 装之前把"这一版依赖的两个前提"一次问完，免得下次还要再装一遍才知道：
///   · `_URL` ivar 在不在（不在就得退回 KVC / 换成构造那一条路）；
///   · `setURL:` 存不存在（**预期是不存在**：`URL` 只读。它若存在说明版本变了，要重新核）。
func activatePlaylistSingleCover() {
    let name = SPTMosaicImageLoaderRequestHook.targetName
    guard let cls = NSClassFromString(name) else {
        writeDebugLog(
            "[SingleCover] missing \(name)"
                + " — the playlist mosaic keeps its four covers"
        )
        return
    }

    PlaylistSingleCoverGroup().activate()

    let ivar = class_getInstanceVariable(cls, "_URL") != nil
    let setter = class_getInstanceMethod(cls, NSSelectorFromString("setURL:")) != nil
    let loader = class_getInstanceMethod(cls, NSSelectorFromString("loadMosaic")) != nil
    writeDebugLog(
        "[SingleCover] armed on \(name)"
            + " (switch=\(UserDefaults.playlistSingleCover ? "ON" : "OFF")"
            + " _URL ivar=\(ivar ? "yes" : "no")"
            + " setURL:=\(setter ? "yes" : "no")"
            + " loadMosaic=\(loader ? "yes" : "no"))"
    )
}
