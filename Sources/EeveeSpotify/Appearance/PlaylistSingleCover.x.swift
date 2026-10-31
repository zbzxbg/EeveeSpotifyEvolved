import Foundation
import ObjectiveC.runtime
import Orion

/// 歌单封面：把四宫格 mosaic 换成单张封面。
///
/// 四宫格不是视图拼的，地址本身就串着四张图的 id：
/// `https://mosaic.scdn.co/<size>/<id1><id2><id3><id4>`（每张 40 位十六进制）。
/// 服务端本来就支持只传一个 id —— 那时返回 640×640 的单张 JPEG（传两个反而 404），
/// 所以把 id 收成一个即可：不换 host、不自己裁图。
///
/// 有两条不同的路，本文件两条都堵：
/// ① 实体页（歌单页 / 音乐库）：地址是 `spotify:mosaic:<id>:…`，流经
///    `SPTMosaicImageLoaderRequest`，挂它的 `load` / `loadMosaic` / `URL` getter；
/// ② 主页卡片（你的歌单 / 最近播放 / 回味无穷）：feed 直接给服务端拼好的普通图片地址，
///    请求层的钩子看不见，于是另挂在 `+[NSURL spt_URLMosaicWithImageURLs:]`（客户端自己拼
///    地址的构造点）与 `-[NSURL initWithString:]`（现成字符串那条）上。
///
/// ⚠️ 钩子里**绝不能自己造 URL**：`URL(string:)` 会再进来一次 → 无限递归。
/// 收窄一律走 `SingleMosaicCover.narrowedString`（纯字符串处理）。
///
/// 只处理能读懂的两条形状（`spotify:mosaic:<40 位 hex>:…` 与
/// `https://mosaic.scdn.co/<size>/<40 位 hex>…`），形状对不上一律放过 ——
/// 宁可不动，也不要拼出一个不存在的地址。读不出来的 API 走 `responds(to:)` /
/// `class_getInstanceMethod` 门禁，当没这回事。开关 `UserDefaults.playlistSingleCover`
/// 关掉时一个字节都不改。
struct PlaylistSingleCoverGroup: HookGroup {}

/// 主页那条路（地址字符串层）。单独一组：它挂的是 `NSURL`，与请求层互不影响。
struct MosaicURLStringGroup: HookGroup {}

/// 只读探针：`NSURL -spt_isMosaicURL`（**只打日志，不改任何东西**）。
struct MosaicURLProbeGroup: HookGroup {}

/// 纯函数：只认得"四宫格地址 → 第一张的地址"这一种改写，其余一律 nil。
enum SingleMosaicCover {
    /// https 形态的 host（API JSON / feed 里的样子）。
    static let host = "mosaic.scdn.co"
    /// **实体那条路上真正流过来的形态**。
    static let spotifyPrefix = "spotify:mosaic:"
    /// 一张专辑封面的 id 长度（`spotify:image:<16 位尺寸><24 位摘要>`，共 40 位十六进制）。
    static let idLength = 40

    /// 40 位十六进制（大小写都算）。
    static func isID(_ token: String) -> Bool {
        token.count == idLength && token.allSatisfy { $0.isHexDigit }
    }

    /// 这个地址里串着的那些 id；形状看不懂 → nil。
    /// · `spotify:mosaic:<id1>:<id2>:…`
    /// · `https://mosaic.scdn.co/<size>/<id1><id2>…`（末段是 40 的整数倍）
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

    // MARK: 纯字符串版（给 `NSURL` 的 init 钩子用 —— 那里**不能造 URL**）
    //
    // 四宫格**字符串** → 只含第一张的字符串；两张以下 / 看不懂 → nil。
    // 全程只做字符串切分，不碰 `URL` / `URLComponents`（否则会递归回 init 钩子）。
    static func narrowedString(_ text: String) -> String? {
        if text.hasPrefix(spotifyPrefix) {
            let tail = String(text.dropFirst(spotifyPrefix.count))
            let tokens = tail.components(separatedBy: ":")
            guard tokens.count > 1, tokens.allSatisfy({ isID($0) }) else { return nil }
            return spotifyPrefix + tokens[0]
        }

        let prefix = "https://" + host + "/"
        guard text.hasPrefix(prefix) else { return nil }
        let rest = String(text.dropFirst(prefix.count))
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        let size = String(rest[rest.startIndex..<slash])
        let packed = String(rest[rest.index(after: slash)...])
        guard !size.isEmpty,
              !packed.contains("?"),
              !packed.contains("#"),
              packed.count > idLength,
              packed.count % idLength == 0,
              packed.allSatisfy({ $0.isHexDigit })
        else { return nil }
        return prefix + size + "/" + String(packed.prefix(idLength))
    }

    /// 纯字符串版：这个地址里有几张（看不懂 → 0）。只给日志用。
    static func partCountString(_ text: String) -> Int {
        if text.hasPrefix(spotifyPrefix) {
            let tokens = String(text.dropFirst(spotifyPrefix.count)).components(separatedBy: ":")
            return tokens.allSatisfy({ isID($0) }) ? tokens.count : 0
        }
        let prefix = "https://" + host + "/"
        guard text.hasPrefix(prefix) else { return 0 }
        let rest = String(text.dropFirst(prefix.count))
        guard let slash = rest.firstIndex(of: "/") else { return 0 }
        let packed = String(rest[rest.index(after: slash)...])
        guard !packed.isEmpty,
              !packed.contains("?"),
              !packed.contains("#"),
              packed.count % idLength == 0
        else { return 0 }
        return packed.count / idLength
    }
}

// MARK: - 门禁与日志（放文件作用域：hook 类里只留 Orion 认的那几样）
//
// 改写了几条、报了几条、字符串层看见过几条、探针问过几次。
private var singleCoverRewrites = 0
private var singleCoverPartReports = 0
private var singleCoverBuildLogs = 0
private var singleCoverStrings = 0
private var singleCoverChecks = 0
private var singleCoverBuilds = 0
private var singleCoverMakerLogs = 0
private var singleCoverIDReports = 0

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

/// 记一条改写（两层的日志格式一致，方便 grep）。
private func reportRewrite(parts: Int, from: String, to: String, at stage: String) {
    singleCoverRewrites += 1
    if singleCoverRewrites <= 10 {
        writeDebugLog(
            "[SingleCover] \(stage): rewrote \(singleCoverRewrites) mosaic URL(s), \(parts) covers -> 1"
                + " (\(from) -> \(to))"
        )
    } else if singleCoverRewrites % 50 == 0 {
        writeDebugLog("[SingleCover] rewrote \(singleCoverRewrites) mosaic URL(s) so far")
    }
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
    reportRewrite(parts: parts, from: url.absoluteString, to: single.absoluteString, at: stage)
    return single
}

/// **字符串层**：收窄一个"要变成 URL 的字符串"，没动就原样返回（init 钩子直接把它喂给 orig）。
private func narrowMosaicString(_ string: NSString, at stage: String) -> NSString {
    guard UserDefaults.playlistSingleCover else { return string }
    let text = string as String
    /// 便宜的先验：不含 `mosaic` 就立刻返回（这个钩子非常热）。
    guard text.count > 24, text.contains("mosaic") else { return string }

    guard let narrowed = SingleMosaicCover.narrowedString(text) else {
        /// 看见一条 mosaic 地址但没动它 —— 这一行是"主页那条路到底长什么样"的证据。
        singleCoverStrings += 1
        if singleCoverStrings <= 10 {
            writeDebugLog("[SingleCover] \(stage): saw \(singleCoverStrings) mosaic string(s), left as is (\(text))")
        }
        return string
    }

    reportRewrite(
        parts: SingleMosaicCover.partCountString(text),
        from: text,
        to: narrowed,
        at: stage
    )
    return narrowed as NSString
}

/// 只读探针：`spt_isMosaicURL` 认不认 https 那种形态。
private func reportMosaicCheck(_ url: NSURL, result: Bool) {
    singleCoverChecks += 1
    guard singleCoverChecks <= 12 else { return }
    writeDebugLog("[SingleCover] mosaic check: \(result ? "YES" : "no") — \(url.absoluteString)")
}

/// 报一次"这个请求此刻认为有几张"——判"拆路径发生在哪一步"的判据。
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

// MARK: - ① 实体那条路（歌单页 / 音乐库）：请求层
//
// 加载入口：拆路径之前先把地址收成第一张。
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
/// ⚠️ 这里**不读 KVC**（那会再调一次本 getter）—— 只用 `orig.URL` 的原值。
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

/// **只读判据**：客户端走了哪条 build 路（零参 void，两个方法在 IPA 的方法表里都在，
/// 而且与 `.cxx_destruct` 共用同一条类型编码 ⇒ 签名确定）。
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

// MARK: - ② 主页那三个模块：地址字符串层
//
// `NSURL` 的 `initWithString:` / `initWithString:relativeToURL:`：
// **feed 给过来的那条普通地址唯一的缝**（见文件头 ②）。
//
// ⚠️ 这个钩子里**不能造 URL**（`URL(string:)` 会再进来一次 → 无限递归），
// 所以收窄全走 `SingleMosaicCover.narrowedString`（纯字符串切分）。
class MosaicURLStringHook: ClassHook<NSURL> {
    typealias Group = MosaicURLStringGroup
    static let targetName = "NSURL"

    func initWithString(_ string: NSString) -> NSURL? {
        orig.initWithString(narrowMosaicString(string, at: "initWithString"))
    }

    func initWithString(_ string: NSString, relativeToURL baseURL: NSURL?) -> NSURL? {
        orig.initWithString(
            narrowMosaicString(string, at: "initWithString:relativeToURL:"),
            relativeToURL: baseURL
        )
    }
}

// MARK: - ②′ 主页那条路的**构造点**：`+[NSURL spt_URLMosaicWithImageURLs:]`
//
// `+[NSURL spt_URLMosaicWithImageURLs:]`（**`BetamaxSDK` 分类，类方法**，从 IPA 的
// `__objc_catlist` 里逐字解出来的）—— 拿 N 张图片 URL 拼出
// `https://mosaic.scdn.co/<size>/<id1><id2>…`。
//
// 这是"客户端自己拼四宫格地址"的那条路：**只留第一张**，拼出来的地址就只有一个 id
// （服务端对一个 id 的 mosaic 地址回的就是单张封面，本机实测过）。
//
// 为什么这里不用 Orion：它是**类方法**，而本仓库现成的类方法写法就是手写 swizzle
// （`CleanShareLinks.x.swift` / `EeveePremiumForce.x.swift` 都是这个 idiom）。
private var originalMosaicBuilderIMP: IMP?

/// 只留数组里的第一张图片 URL（≤1 张时原样返回）。
private func narrowMosaicImageURLs(_ urls: NSArray) -> NSArray {
    guard UserDefaults.playlistSingleCover else { return urls }
    guard urls.count > 1 else { return urls }
    singleCoverBuilds += 1
    return NSArray(object: urls.object(at: 0))
}

/// 报一次"拼出来的 mosaic 地址长什么样"——**这一段是判"主页那排长方形卡片有没有被拦到"的唯一判据**：
/// 地址里那个尺寸段（`mosaic.scdn.co/<size>/…`）就是"哪一档卡片在要图"的指纹
/// （首页顶部那排 187×48 的小卡与「你的歌单」的大方卡尺寸不同）。
private func reportMosaicBuilt(inputCount: Int, output: NSURL?) {
    singleCoverMakerLogs += 1
    guard singleCoverMakerLogs <= 14 else { return }
    writeDebugLog(
        "[SingleCover] mosaic build #\(singleCoverMakerLogs): \(inputCount) image(s) ->"
            + " \(output?.absoluteString ?? "(nil)")"
    )
}

/// 装上就返回 true；`NSURL` 上没有这个方法就返回 false（只打日志、不崩）。
func installMosaicURLBuilderHook() -> Bool {
    let sel = NSSelectorFromString("spt_URLMosaicWithImageURLs:")
    guard let method = class_getClassMethod(NSURL.self, sel) else { return false }
    guard originalMosaicBuilderIMP == nil else { return true }

    let origIMP = method_getImplementation(method)
    originalMosaicBuilderIMP = origIMP
    // ⚠️ 与 `CleanShareLinks.x.swift` 同一条注意：ObjC 调进来的 receiver 是**类对象**，
    // 参数是对象指针 ⇒ 一律用 `AnyObject`，不能用 Swift 的 `Any`（那是存在性容器）。
    let block: @convention(block) (AnyObject, NSArray) -> AnyObject? = { receiver, urls in
        typealias OrigFn = @convention(c) (AnyObject, Selector, NSArray) -> AnyObject?
        let callOrig = unsafeBitCast(origIMP, to: OrigFn.self)
        let inputCount = urls.count
        let narrowed = narrowMosaicImageURLs(urls)
        let built = callOrig(receiver, sel, narrowed)
        reportMosaicBuilt(inputCount: inputCount, output: built as? NSURL)
        return built
    }
    method_setImplementation(method, imp_implementationWithBlock(block as Any))
    return true
}

// MARK: - ③ 只读探针：`spt_isMosaicURL` 认哪些形态
//
// 只打日志、不改任何东西。它回答的是"https 那种形态在 Spotify 眼里算不算 mosaic"
// —— 决定了 ② 到底该在字符串层做，还是该让 Spotify 自己走 mosaic 那条路。
class NSURLMosaicCheckHook: ClassHook<NSURL> {
    typealias Group = MosaicURLProbeGroup
    static let targetName = "NSURL"

    func spt_isMosaicURL() -> Bool {
        let result = orig.spt_isMosaicURL()
        reportMosaicCheck(self.target, result: result)
        return result
    }
}

/// 只读探针：`NSURL -spt_imageIDs`（**只打日志**）。
/// 单独一组：`spt_imageIDs` 在不在与 `spt_isMosaicURL` 是两件事，缺一个不该拖累另一个。
struct MosaicURLIDsProbeGroup: HookGroup {}

/// 它返回的是 **App 自己**从这个地址里解出来的 image id 列表：
/// 返回 ≥2 个 ⇒ 这个地址真的串着多张图（mosaic）；只有 1 个 ⇒ 这个地址本身就是一张成品图
/// （**服务端已经拼好的那种 —— 改地址没用，只能改视图层**）。
/// 这一行能一句话判死"主页那排长方形卡片"到底走的哪条路。
class NSURLImageIDsHook: ClassHook<NSURL> {
    typealias Group = MosaicURLIDsProbeGroup
    static let targetName = "NSURL"

    func spt_imageIDs() -> NSArray? {
        let ids = orig.spt_imageIDs()
        if let ids = ids, ids.count > 1 {
            singleCoverIDReports += 1
            if singleCoverIDReports <= 12 {
                writeDebugLog(
                    "[SingleCover] imageIDs: \(ids.count) id(s) — \(self.target.absoluteString)"
                )
            }
        }
        return ids
    }
}

// MARK: - 装
//
// 装这几组。每一组都先问"它的前提在不在"，缺了就只打一行日志
// （不留给 Orion 报非致命错误 —— 本仓库既有做法）。
func activatePlaylistSingleCover() {
    let switchState = UserDefaults.playlistSingleCover ? "ON" : "OFF"
    let name = SPTMosaicImageLoaderRequestHook.targetName

    if let cls = NSClassFromString(name) {
        PlaylistSingleCoverGroup().activate()
        let has: (String) -> Bool = { selector in
            class_getInstanceMethod(cls, NSSelectorFromString(selector)) != nil
        }
        let ivar = class_getInstanceVariable(cls, "_URL") != nil
        writeDebugLog(
            "[SingleCover] armed on \(name)"
                + " (switch=\(switchState)"
                + " _URL ivar=\(ivar ? "yes" : "no")"
                + " setURL:=\(has("setURL:") ? "yes" : "no")"
                + " loadMosaic=\(has("loadMosaic") ? "yes" : "no")"
                + " buildSingleImage=\(has("buildSingleImage") ? "yes" : "no")"
                + " buildMosaicImage=\(has("buildMosaicImage") ? "yes" : "no"))"
        )
    } else {
        writeDebugLog(
            "[SingleCover] missing \(name)"
                + " — the playlist mosaic keeps its four covers"
        )
    }

    // ② 地址字符串层（主页那三个模块）—— 前提是 `NSURL` 认这两个 init。
    let initSelector = NSSelectorFromString("initWithString:")
    if class_getInstanceMethod(NSURL.self, initSelector) != nil {
        MosaicURLStringGroup().activate()
        writeDebugLog("[SingleCover] armed on NSURL initWithString: (switch=\(switchState))")
    } else {
        writeDebugLog("[SingleCover] missing NSURL initWithString: — the home cards keep their four covers")
    }

    // ②′ 构造点：`+[NSURL spt_URLMosaicWithImageURLs:]`（类方法，手写 swizzle）——
    // **主页那三个模块最可能的缝**：客户端自己拼四宫格地址时只留第一张图。
    if installMosaicURLBuilderHook() {
        writeDebugLog("[SingleCover] armed on +[NSURL spt_URLMosaicWithImageURLs:] (switch=\(switchState))")
    } else {
        writeDebugLog(
            "[SingleCover] missing +[NSURL spt_URLMosaicWithImageURLs:]"
                + " — the home cards keep their four covers"
        )
    }

    // ③ 只读探针。
    let checkSelector = NSSelectorFromString("spt_isMosaicURL")
    if class_getInstanceMethod(NSURL.self, checkSelector) != nil {
        MosaicURLProbeGroup().activate()
        writeDebugLog("[SingleCover] armed on NSURL spt_isMosaicURL (probe, read-only)")
    } else {
        writeDebugLog("[SingleCover] no NSURL spt_isMosaicURL on this build (probe skipped)")
    }

    let idSelector = NSSelectorFromString("spt_imageIDs")
    if class_getInstanceMethod(NSURL.self, idSelector) != nil {
        MosaicURLIDsProbeGroup().activate()
        writeDebugLog("[SingleCover] armed on NSURL spt_imageIDs (probe, read-only)")
    } else {
        writeDebugLog("[SingleCover] no NSURL spt_imageIDs on this build (probe skipped)")
    }
}
