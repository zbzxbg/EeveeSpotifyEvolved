/// 匿名令牌这条路的失败原因。
///
/// 只留一个 case：对调用方来说"没换成"就够了 —— 具体是三个 app_id 全 403、响应不是 JSON、
/// 还是拿到了 `UpgradeRequired`，都记在日志里（`AnonymousTokenHelper.token(from:appId:status:)`）。
/// 弹窗只需要知道"失败"。
enum AnonymousTokenError: Swift.Error {
    case invalidResponse
}
