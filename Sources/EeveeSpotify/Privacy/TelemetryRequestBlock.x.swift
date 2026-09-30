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
///   · 命中功能白名单的请求一律放行（`TelemetryEndpointRules` 里优先级最高的那条），
///     所以播放 / 歌词 / 登录 / 曲库不可能被这里 cancel 掉；
///   · 这条 hook **总是装**（不随开关启停），因为它的守卫只是两次 UserDefaults 读，
///     代价可忽略，换来的是"开关一打开就生效"—— 隐私开关要重启才生效体验很差。
///
/// 已知的两处边角（都往"放行"倾斜，不会误伤）：
///   · 少数 task 的 `currentRequest` 与 `originalRequest` 都为空（例如 `resumeData:`
///     建的 task）—— 这里放行，交给响应侧兜底；
///   · `cancel()` 一个还没 resume 的 task 是本文件里唯一**没法离线验证**的行为。
///     预期它表现为一次 cancelled 错误完成；真机上要确认一次"cancel 之后调用方不会
///     永远等一个不会来的 completion"。
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
