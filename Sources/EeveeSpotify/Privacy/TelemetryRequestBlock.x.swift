import Foundation
import Orion

/// 上报拦截的**请求侧**：在任务出网之前 `cancel()` 掉命中规则的请求。
///
/// 为什么需要这一层：`SpotifyResponsePatcher.shouldBlock` 是响应侧的（从
/// `didReceiveData` / `didCompleteWithError` 进来），那时 POST body 早就发出去了 ——
/// 只丢回复不叫"拦截上报"。这里挂在 `-[NSURLSessionTask resume]` 上，与仓库既有的
/// `URLSessionTaskResumeHook`（`SessionProtection.x.swift`）同一个目标，
/// Orion 会把两条 hook 串起来。
///
/// 三个安全点：
///   · 判据只有一处 —— `TelemetryBlocker`，与响应侧、设置页共用同一张表；
///   · 开关与观察模式**都关**时这个 group 根本不装（见 `activateTelemetryRequestBlock`）；
///   · 命中功能白名单的请求一律放行（`TelemetryEndpointRules` 里那条优先级最高的规则），
///     所以播放 / 歌词 / 登录 / 曲库不可能被这里 cancel 掉。
struct TelemetryRequestBlockGroup: HookGroup {}

class TelemetryTaskResumeHook: ClassHook<NSObject> {
    typealias Group = TelemetryRequestBlockGroup
    static let targetName = "NSURLSessionTask"

    func resume() {
        guard UserDefaults.blockTelemetry || UserDefaults.telemetryObserveOnly,
              let task = target as? URLSessionTask,
              let url = task.currentRequest?.url ?? task.originalRequest?.url else {
            orig.resume()
            return
        }

        guard TelemetryBlocker.shouldBlockRequest(url) else {
            orig.resume()
            return
        }

        // 不 resume，直接 cancel：请求不出网。客户端会把这次上报当成一次失败，
        // 而这类端点本来就是 fire-and-forget（真机日志里响应体恒为 0 字节）。
        task.cancel()
    }
}

func activateTelemetryRequestBlock() {
    // **总是装**，哪怕两个开关都关着：这条 hook 的守卫只是两次 UserDefaults 读
    // （进程内缓存），代价可以忽略，换来的是「开关一打开就生效」——
    // 隐私开关要重启才生效是很糟的体验。开关关着时它什么都不做。
    TelemetryRequestBlockGroup().activate()
    writeDebugLog(
        "[Telemetry] request-side hook installed (block="
            + "\(UserDefaults.blockTelemetry ? "ON" : "OFF")"
            + " observeOnly=\(UserDefaults.telemetryObserveOnly ? "ON" : "OFF"))"
    )
}
