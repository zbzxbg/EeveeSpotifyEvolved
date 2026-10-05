import Foundation
import ObjectiveC.runtime
import Orion

/// 歌单封面：**四宫格 → 第一张的单张封面**（用户第 5 轮问的那条）。
///
/// ── 那个四宫格是什么（IPA + 真机日志 73，都是硬证据）────────────────────────
///
/// **真机上流到图片加载器的地址是 `spotify:mosaic:` URI，不是 https**（日志 73 逐字）：
///
/// ```
/// spotify:mosaic:ab67616d00001e02633b4e9dbb7af4262218f665
///               :ab67616d00001e02a42f4473d0e9a69f6aa10304
///               :ab67616d00001e02266ae64ffdfa0869f675909a
///               :ab67616d00001e02fc734f1966145ffb54a82622
/// ```
///
/// ⚠️ 第一版只认 https 形态（`https://mosaic.scdn.co/<size>/<id1>…`，那是 API JSON 里的形态），
/// `url.host` 对 `spotify:` 这种 opaque URL **是 nil** ⇒ 判定落空、一条都没改
/// （日志 73 里只有 `numberOfParts=0 URL=spotify:mosaic:…`，没有一行 `rewrote`）。
/// **两种形态现在都认。**
///
/// https 形态那一侧的依据（仍然有效）：
///   · IPA 的 `__cstring` 里逐字有模板串 `https://mosaic.scdn.co/%lu/%@`（file 偏移 185784143），
///     `%lu` = 尺寸、`%@` = 拼在一起的 id 串；旁边还有 `spotify:mosaic:` / `mosaicImageURI`；
///   · 服务端实测：`mosaic.scdn.co/640/<1 个 id>` → 200 `image/jpeg` 640×640（单张封面）、
///     `<4 个 id>` → 200 640×640（四宫格）、`<2 个 id>` → **404**。
///   ⇒ 只要把 id 收到一个，两条路（客户端自己拼 / 服务端给成品）到的都是单张。
///
/// ── 客户端那一族类（从 IPA 的 ObjC 元数据逐个解出）──────────────────────────
///
/// `SPTMosaicImageLoaderRequest` 是真 ObjC 类，45 个自有方法，其中：
///   · `-load` / `-loadMosaic` / `-cancel` / **`-buildSingleImage`** / **`-buildMosaicImage`**
///     六个都是零参数 void（**它们共用同一条类型编码**，而 `.cxx_destruct` 必然是
///     `void(void)` ⇒ 这一族都是零参 void）；
///   · 属性表里逐字：`URL : T@"NSURL",R,N,V_URL`——**只读，没有 `setURL:`**
///     （真机也印证了：`[SingleCover] armed … setURL:=no`）、
///     `numberOfParts : TQ`、`mosaicParts : NSMutableDictionary`、
///     `mosaicRequests` / `mosaicErrors` : NSMutableArray。
///   · `numberOfParts` 在 `load` / `loadMosaic` **入口读到的是 0**（日志 73）⇒ 份数是
///     **在 `loadMosaic` 里面**才算的 ⇒ 在它之前把地址收窄**正好赶得上**。
///
/// ── 挂哪儿 ───────────────────────────────────────────────────────────────
///
/// 1. `load` / `loadMosaic`：入口收窄（真机顺序是 `load` 先、`loadMosaic` 后）；
/// 2. `URL` getter：`initWithURL:…` 里可能早就读过一次（那一读在 `load` 之前），
///    这一层把"更早的读者"也收进来；收窄结果**写回对象**，所以只会记一笔；
/// 3. `buildSingleImage` / `buildMosaicImage`：**只读判据**（只打日志、照样调 orig）——
///    它们直接告诉我们客户端最后走的是"单张"还是"拼图"那条路，不用靠肉眼猜。
///
/// ⚠️ **千万不要写 `setURL:`**：`URL` 是只读属性（`T@"NSURL",R,N,V_URL`），**它没有 setURL:**
/// （真机 `armed` 那行 `setURL:=no` 已确认）。唯一可行的是**直接写它的 ivar `_URL`**
/// （`object_setIvar`，ARC 正确），读不出来才退回 KVC。
///
/// 为什么不挂那两条"更正统"的：`SPTMosaicImageLoaderRequest` 的 11 参构造、以及
/// `SPTMosaicImageRequestFactory -provideImageLoaderRequestForURL:…`（12 参，工厂只有这一个方法）
/// —— 两个 `CGSize` 与 `double`/`BOOL` 夹在中间，本机没有 Swift 编译器，签名只能靠元数据核对，
/// **不冒这个险**。
///
/// ── 纪律 ─────────────────────────────────────────────────────────────────
///
/// · **只动两个能读懂的形态**：`spotify:mosaic:<40 位 hex>:…` 与 `mosaic.scdn.co/<size>/<40 位 hex>…`；
///   形状看不懂（含非 40 位 hex 的段）一律放过 —— 宁可不动，也不要拼出一个不存在的地址；
/// · 一路 `responds(to:)` 门禁：读不出来就当没这回事（不猜、不崩）；
/// · **开关关掉 = 一个字节都不改**（`UserDefaults.playlistSingleCover`）；
/// · 日志判据（下一份日志按这个读）：
///      · `rewrote N mosaic URL(s), 4 covers -> 1` ⇒ 改写生效；
///      · `buildSingleImage` 出现 ⇒ 客户端走了单张那条路（**成了**）；
///      · `buildMosaicImage` 出现 ⇒ 还是拼图那条路（那时才轮到更深的改法）。
///
/// 对照仓库（**spoti.pw 并没有这个功能**，用户以为它有）：v0.22.0 全树只有封面**显示**
/// 相关的做法（hero `followCover:`、"隐藏封面"collapsing、圆角），CHANGELOG / docs /
/// 全语言文案里都没有 mosaic 或单张封面。
struct PlaylistSingleCoverGroup: HookGroup {}

/// 纯函数：只认得"四宫格地址 → 第一张的地址"这两种形态。
enum SingleMosaicCover {
    /// https 形态的 host（API JSON 里的样子）。
    static let host = "mosaic.scdn.co"
    /// **真机上真正流过来的形态**（日志 73）。
    static let spotifyPrefix = "spotify:mosaic:"
    /// 一张专辑封面的 id 长度（`spotify:image:<16 位尺寸><24 位摘要>`，共 40 位十六进制）。
    static let idLength = 40

    /// 40 位十六进制（大小写都算）。
    static func isID(_ token: String) -> Bool {
        token.count == idLength && token.allSatisfy { $0.isHexDigit }
    }

    /// 这个地址里串着的那些 id；形状看不懂 → nil。
    ///   · `spotify:mosaic:<id1>:<id2>:…`
    ///   · `https://mosaic.scdn.co/<size>/<id1><id2>…`（末段是 40 的整数倍）
    static func idTokens(of url: URL) -> [String]? {
        let text = url.absoluteString

        if text.hasPrefix(spotifyPrefix) {
            let tail = String(text.dropFirst(spotifyPrefix.count))
            let tokens = tail.components(separatedBy: ":")
            guard tokens.count >= 2, tokens.allSatisfy({ isID($0) }) else { return nil }
            return tokens
        }

        guard url.host == host else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard let last = parts.last,
              last.count > idLength,
              last.count % idLength == 0,
              last.allSatisfy({ $0.isHexDigit })
        else { return nil }
        return stride(from: 0, to: last.count, by: idLength).map { offset in
            let start = last.index(last.startIndex, offsetBy: offset)
            let end = last.index(start, offsetBy: idLength)
            return String(last[start..<end])
        }
    }

    /// 四宫格地址 → 只含第一张的地址；两张以下 / 看不懂 → nil（**幂等**：一张的地址再收还是 nil）。
    static func single(from url: URL) -> URL? {
        guard let tokens = idTokens(of: url), tokens.count > 1 else { return nil }
        let text = url.absoluteString

        if text.hasPrefix(spotifyPrefix) {
            return URL(string: spotifyPrefix + tokens[0])
        }

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var parts = url.pathComponents.filter { $0 != "/" }
        parts[parts.count - 1] = tokens[0]
        components?.path = "/" + parts.joined(separator: "/")
        return components?.url
    }

    /// 这个地址里有几张（看不懂 → 0）。
    static func partCount(in url: URL) -> Int {
        idTokens(of: url)?.count ?? 0
    }
}

// MARK: - 门禁与日志（放文件作用域：hook 类里只留 Orion 认的那几样）

/// 改写了几条、报了几条、两个判据各出现几次。
private var singleCoverRewrites = 0
private var singleCoverPartReports = 0
private var singleCoverBuildLogs = 0

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

/// 把新地址写回去。**`URL` 是只读属性（没有 `setURL:`，真机已确认）** ⇒ 直接写它的 ivar `_URL`。
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
/// 返回 nil = 没动（开关关着 / 不是四宫格 / 看不懂 / 写不进去），调用方就当原来的地址用。
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

/// 报一次"这个请求此刻认为有几张"。真机上**入口读到的是 0**（份数在 `loadMosaic` 里面才算），
/// 所以 `(after)` 那一笔才是"拆分到底看没看见单张"的判据。
private func reportMosaicParts(of request: NSObject, at stage: String) {
    singleCoverPartReports += 1
    guard singleCoverPartReports <= 12 else { return }
    writeDebugLog(
        "[SingleCover] \(stage): numberOfParts=\(singleCoverPartCount(of: request))"
            + " URL=\(singleCoverURL(of: request)?.absoluteString ?? "(nil)")"
    )
}

/// **只读判据**：客户端最后走的是"单张"还是"拼图"那条路（只打日志，照样调 orig）。
private func reportBuild(_ name: String) {
    singleCoverBuildLogs += 1
    guard singleCoverBuildLogs <= 12 else { return }
    writeDebugLog("[SingleCover] build path: \(name)")
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
        reportMosaicParts(of: self.target, at: "load(before)")
        orig.load()
    }

    func loadMosaic() {
        if let url = singleCoverURL(of: self.target) {
            _ = narrowMosaicURL(url, of: self.target, at: "loadMosaic")
        }
        reportMosaicParts(of: self.target, at: "loadMosaic(before)")
        orig.loadMosaic()
        reportMosaicParts(of: self.target, at: "loadMosaic(after)")
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

/// **只读判据**：装了哪条路就报哪条（零参数 void，两个方法在 IPA 的方法表里都在）。
class SPTMosaicImageLoaderRequestBuildHook: ClassHook<NSObject> {
    typealias Group = PlaylistSingleCoverGroup
    static let targetName = "SPTMosaicImageLoaderRequest"

    func buildSingleImage() {
        reportBuild("buildSingleImage (one cover)")
        orig.buildSingleImage()
    }

    func buildMosaicImage() {
        reportBuild("buildMosaicImage (still a grid)")
        orig.buildMosaicImage()
    }
}

/// 装这一组。目标类缺失就只打一行日志、不留给 Orion 报非致命错误（本仓库既有做法）。
///
/// ⚠️ 装之前把"这一版依赖的前提"一次问完，免得下次还要再装一遍才知道：
///   · `_URL` ivar 在不在（不在就得退回 KVC / 换成构造那一条路）；
///   · `setURL:` 存不存在（**预期是不存在**：`URL` 只读）；
///   · `loadMosaic` / `buildSingleImage` / `buildMosaicImage` 在不在。
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

    let has: (String) -> Bool = { selector in
        class_getInstanceMethod(cls, NSSelectorFromString(selector)) != nil
    }
    let ivar = class_getInstanceVariable(cls, "_URL") != nil
    writeDebugLog(
        "[SingleCover] armed on \(name)"
            + " (switch=\(UserDefaults.playlistSingleCover ? "ON" : "OFF")"
            + " _URL ivar=\(ivar ? "yes" : "no")"
            + " setURL:=\(has("setURL:") ? "yes" : "no")"
            + " loadMosaic=\(has("loadMosaic") ? "yes" : "no")"
            + " buildSingleImage=\(has("buildSingleImage") ? "yes" : "no")"
            + " buildMosaicImage=\(has("buildMosaicImage") ? "yes" : "no"))"
    )
}
