import Foundation
import ObjectiveC.runtime

/// **只读**探针：这一版（Spotify 9.1.88 / iOS 27）的**封面图**到底由哪个类、哪个选择器加载。
///
/// ── 为什么要它（用户 2026-10-13 的那个问题）─────────────────────────────────
/// 「Spotify 的歌单封面是歌单里**前四首歌**拼成的一个大封面，有没有办法只显示一首歌的专辑封面？」
///
/// **已经查清的事实**（真实数据，不是推测 —— 见 `Tools/eevee-hookfinder/` 那一轮的记录）：
/// 那个四宫格**不是客户端拼的**，而是**服务端拼好的一张图**，URL 里就把四张图的 id 串在一起：
///
/// ```
/// https://mosaic.scdn.co/640/ab67616d0000b27307a7a809c3f77c61fe31e05f   ← 第 1 张
///                          ab67616d0000b2730a719f2817838a22e6a7e8c9   ← 第 2 张
///                          ab67616d0000b273587227ac29ff1f83ccbd1623   ← 第 3 张
///                          ab67616d0000b27362a13d5041f79075d4e317f0   ← 第 4 张
/// ```
/// （每张 40 个 hex；`i.scdn.co/image/<那 40 个 hex>` 就是单张封面的地址 ——
///   本仓库 `LyricsBackdropArtworkView` 拼的就是这个形式。）
///
/// ⇒ **要"只显示一张"，最干净的改法是把进入图片加载器的 URL 改写成其中第一张**
/// （`mosaic.scdn.co/<size>/<id1>…` → `i.scdn.co/image/<id1>`），
/// 而不是去动视图层（视图那边拿到的就是一张成品图）。
///
/// ── 这个探针解决的就是"改写点在哪" ─────────────────────────────────────────
/// `dump-9.1.88.txt` 的 `[classes]` 桶里有那一族类名、`[selectors]` 桶里有那一族选择器名，
/// 但**两边没有对应关系**（`[methods]` 桶里其实是类型名，不是"类 → 方法"）
/// ⇒ 只能上设备问一次：候选类在不在、它们认不认那几个"URL 在最前面"的选择器。
///
/// ⚠️ **纯只读**：`NSClassFromString` + `class_getInstanceMethod`，**不 hook、不调用、不改任何东西**。
/// 下一轮照这一行的结果去 hook 真正的那一个（并带上"Mosaic 改写开关"）。
enum ImagePipelineProbe {

    /// 候选类（`dump-9.1.88.txt` 的 `[classes]` 桶里逐字存在的那些）。
    private static let classCandidates = [
        "ImageLoader_ImageLoaderKit.SPTImageLoaderImpl",
        "ImageLoader_ImageLoadingServiceImpl.SPTImageLoadingServiceImplementation",
        "ImageLoader_ImageLoadingServiceImpl.SPTImageLoadingSessionServiceImplementation",
        "ImageLoader_CoreImageLoaderImpl.SPTCoreImageLoaderService",
        "ImageLoader_ECMImageLoader.ECMImageLoader",
        "ImageLoader_ECMImageLoader.ImageLoaderTask",
        "ImageLoader_ECMImageLoader.EncoreImageLoaderTask",
        "CreativeWorkPlatform_ECMKit.ImageLoaderEffect",
        "Betamax_ImageLoaderImpl.ImageLoaderServiceImpl",
    ]

    /// 候选入口（`dump-9.1.88.txt` 的 `[selectors]` 桶里逐字存在；挑 URL 在第一个参数的）。
    private static let selectorCandidates = [
        "loadImageForURL:sourceIdentifier:size:scale:allowUpscaling:context:callback:persistenceKey:",
        "loadImageForURL:sourceIdentifier:size:scale:context:",
        "loadImageForURL:sourceIdentifier:size:context:",
        "loadImageForURL:sourceIdentifier:size:onCompletion:",
        "loadImageForURL:targetSize:context:",
        "loadImageContentWithURL:imageLoader:",
        "fetchImageForURL:completion:",
        "imageURLFromMetadata:withImageHints:",
    ]

    /// 跑一次，把"谁在、认哪些选择器"打进日志。**只报一次**（启动时调用）。
    static func probeOnce() {
        var present = 0

        for name in classCandidates {
            guard let cls: AnyClass = NSClassFromString(name) else { continue }
            present += 1
            let answers = selectorCandidates.filter { selector in
                class_getInstanceMethod(cls, NSSelectorFromString(selector)) != nil
            }
            writeDebugLog(
                "[ImageProbe] \(shortName(name)) is here — answers: "
                    + (answers.isEmpty
                        ? "none of the \(selectorCandidates.count) candidate selectors"
                        : answers.joined(separator: " | "))
            )
        }

        guard present == 0 else { return }
        writeDebugLog(
            "[ImageProbe] ⚠️ none of the \(classCandidates.count) candidate image classes is on this build"
                + " — the cover URL cannot be rewritten at the loader here; the view layer would be the only way"
        )
    }

    /// `ImageLoader_ImageLoaderKit.SPTImageLoaderImpl` → `SPTImageLoaderImpl`（日志短一点）。
    private static func shortName(_ name: String) -> String {
        name.components(separatedBy: ".").last ?? name
    }
}
