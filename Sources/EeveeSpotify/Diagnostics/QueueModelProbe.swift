// 「队列数据从哪来」的**只读**探针（一次装机问完，不承载任何功能）。
//
// 横屏第二栏要的 up-next 需要三样东西：从播放器取到队列对象的入口、`nextTracks` 元素暴露的
// 字段、以及"跳到某首 / 移除"的动作。这三样在 9.2.2 的解密二进制里只能看到**名字**：
//
// · 协议 `SPTPlayerQueue`：`track` / `prevTracks` / `nextTracks` / `revision`（属性名解得出来，
//   方法名解不出来 —— 相对方法表的偏移基址对不上）；
// · 协议 `SPTPlayerQueueSnapshot`：`tracks` / `revision`；实现类 ivar 是 `_tracks` / `_revision`；
// · Swift 协议 `StatefulPlayerQueue`（`NowPlaying_PlatformImpl`）：`currentTrack` / `nextTrack` /
//   `numberOfNextTracks` / `isQueueInSync` … 但**播放器那个实例上到底有没有这些 getter** 未知；
// · `nextTracks` 的属性类型串只写 `NSArray`（没有泛型）⇒ 元素是什么类只能运行时看。
//
// 所以这里补的是**调用点**：`ClassDumper`（方法表 + ivar 表）早就写好了，但全仓没有任何地方
// 调它 —— 日志里连一行 `[Dump]` 都不可能出现。视图树那条路也读不到 `statefulPlayer`
// 这类非视图对象。
//
// 安全边界（与 `ClassDumper` 的纪律一致）：
// · 只读；只调**无参、返回对象**的选择器（先看 `method_getTypeEncoding` 的形状）；
// · 只试白名单里的名字，不做全类枚举、不 KVC（猜键会抛不可捕获的 NSException）；
// · 幂等：一个进程只跑一遍；「调试 → 启用日志记录」关着时零动作。
//
// 日志 tag：`[QueueModel]`。
import Foundation
import UIKit
import ObjectiveC.runtime

enum QueueModelProbe {

    static let logTag = "QueueModel"

    private static var didProbePlayer = false

    /// 候选选择器：只放**无参、返回对象**的那些（属性 getter 的形状）。
    private static let objectGetters = [
        "queue", "playerQueue", "queueSnapshot", "currentQueue", "snapshot",
        "track", "currentTrack", "playingTrack", "nextTrack",
        "nextTracks", "prevTracks", "tracks", "playerState",
    ]

    /// 每拍可调；只跑一次（播放器还没就绪时下一拍再试）。
    @MainActor
    static func probePlayerIfNeeded() {
        guard !didProbePlayer, UserDefaults.enableLogRecording else { return }
        guard let player = statefulPlayer else { return }
        didProbePlayer = true
        ClassDumper.dump("statefulPlayer", player)
        guard let object = player as? NSObject, let classOfPlayer = object_getClass(object) else {
            writeDebugLog("[\(logTag)] statefulPlayer is not an NSObject — cannot enumerate selectors")
            return
        }
        for name in objectGetters {
            let selector = Selector(name)
            guard let method = class_getInstanceMethod(classOfPlayer, selector) else { continue }
            let encoding = method_getTypeEncoding(method).map { String(cString: $0) } ?? "?"
            writeDebugLog("[\(logTag)] \(name) — \(encoding)")
            // 只调"返回对象、且只带 self + _cmd"的形状（`@16@0:8`）：参数表里多一个字符就跳过。
            guard encoding.hasPrefix("@"),
                  encoding.range(of: "^@[0-9]+@0:[0-9]+$", options: .regularExpression) != nil,
                  object.responds(to: selector) else { continue }
            guard let value = object.perform(selector)?.takeUnretainedValue() else {
                writeDebugLog("[\(logTag)] \(name) -> nil")
                continue
            }
            writeDebugLog("[\(logTag)] \(name) -> \(NSStringFromClass(type(of: value)))")
            if let array = value as? [Any] {
                writeDebugLog("[\(logTag)] \(name) count=\(array.count)")
                for (index, element) in array.prefix(3).enumerated() {
                    let item = element as AnyObject
                    writeDebugLog(
                        "[\(logTag)] \(name)[\(index)] class=\(NSStringFromClass(type(of: item)))"
                    )
                    ClassDumper.dump("\(name)[\(index)]", item)
                }
            } else {
                ClassDumper.dump(name, value as AnyObject)
            }
        }
    }
}
