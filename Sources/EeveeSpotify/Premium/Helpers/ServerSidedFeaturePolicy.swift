import Foundation

struct ServerSidedFeaturePolicy {
    struct RemoteFlag: Equatable {
        let scope: String
        let name: String
    }

    // These values are real account entitlements. Spoofing them only exposes
    // incomplete UI; Spotify's backend still rejects the operation.
    static let serverAuthoritativeAccountAttributes: Set<String> = [
        "offline",
        "can-use-offline",
        "has-offline-state",
        "max-offline-downloads-per-device",
        "max-offline-tracks",
        "offline-backup",
        "lyrics-offline",
        "very-high-bitrate",
        "audio-quality",
        "social-session",
        "social-session-free-tier",
        "jam-social-session",
    ]

    // Hide only remote/Premium Jam hosting. Spotify's separate in-person join
    // and free-user hosting flag remains controlled by the live configuration.
    static let premiumGatedJamEntryPoint = RemoteFlag(
        scope: "ios-sociallistening-configuration-impl",
        name: "premium_gated_start_jam_buttons_enabled"
    )

    static func shouldOverwriteResolvedConfiguration(requested: Bool) -> Bool {
        requested
    }

    // MARK: - "这个账号在服务端本来就是 Premium 吗"（2026-10-12）

    /// ★★ **判据只有这一处**：这一份 payload 要不要下 premium 伪装。`false` = **一个字段都不改**。
    ///
    /// ── 为什么要有它（用户 2026-10-12 那轮 A/B 的结论 + 仓库自己的老账）────────────
    ///   · 用户原话：「**和 A 没关系，和 B 有关系**。不启用 Premium 补丁时正常，**打了补丁才灰**」
    ///     ⇒ 症状属于"我们改账号态"这一层（`modifyAttributes`），不是 flag 覆盖那一层；
    ///   · `EeveePremiumForce.x.swift:88` 早就写过同一个现象：
    ///     *"Over-seeding caused greyed-out tracks (streaming-rules mismatch)"* ——
    ///     而 `modifyAttributes` 恰恰把 `streaming-rules` **清成空串**、把
    ///     `subscription-enddate` / `product-expiry` 改成"一年后"（真 Premium 账号本来就有真值）；
    ///   · 上游那条 `have_premium_popup`（"你已经是真的 Premium 了，那就不打补丁"）用的**就是**
    ///     这个信号（`DynamicPremium+ModifyBootstrap.x.swift:71-84` 读 bootstrap 的 `type`），
    ///     但它**只在 `patchType == .notSet` 的那一瞬间**看一眼 —— 而那条路在本机从未触发
    ///     （全部 30 多份日志里 `[BOOTSTRAP]` 零命中）⇒ 真订阅账号每次都被照盖不误。
    ///
    /// ── 判据 ────────────────────────────────────────────────────────────────
    ///   `type == premium` **且**（`catalogue == premium` 或 `player-license == premium`）。
    ///   两道佐证是为了"某个免费账号的 payload 恰好写着 premium"时别把整条路废掉。
    ///   `attributes` 为空 = 随包快照（`.bnk` 组装出来的种子，那一次还没见过账号态）
    ///   ⇒ 用**上次记住的**结论（`UserDefaults.serverSaidPremium`，见那里的说明）。
    ///
    /// ⚠️ 只判**改写之前**的 attributes（调用方必须在 `modifyAttributes` 之前读它）。
    static func shouldSpoofPremium(_ attributes: [String: AccountAttribute]) -> Bool {
        if attributes.isEmpty {
            let remembered = UserDefaults.serverSaidPremium
            reportPremiumDecision(premium: remembered, spoof: !remembered, source: "the bundled seed (no account state of its own)")
            return !remembered
        }

        let type = attributes["type"]?.stringValue.lowercased() ?? "(absent)"
        let catalogue = attributes["catalogue"]?.stringValue.lowercased() ?? "(absent)"
        let license = attributes["player-license"]?.stringValue.lowercased() ?? "(absent)"
        let premium = type == "premium" && (catalogue == "premium" || license == "premium")

        UserDefaults.serverSaidPremium = premium
        reportPremiumDecision(
            premium: premium,
            spoof: !premium,
            source: "the live payload (type=\(type) catalogue=\(catalogue) player-license=\(license))"
        )
        return !premium
    }

    /// 结论**只在翻转时**报一行（这份 payload 每来一次都会问一遍，不能刷屏）。
    ///
    /// 判读下一份日志：
    ///   · `no spoof … the account is already premium` + 之后 `[REVERT_WATCH][init]` 里的
    ///     `subscription-enddate` **不再等于"一年后"**（真值动不了）⇒ 用户确实是真订阅，
    ///     症状的根因就是这份伪装；
    ///   · `spoofing … the account is not premium on the wire` ⇒ 账号是免费档，
    ///     那"打补丁才灰"要往别处查（`pay`/地区/产品态那几条线）。
    private static var lastReportedPremiumDecision: Bool?

    private static func reportPremiumDecision(premium: Bool, spoof: Bool, source: String) {
        guard lastReportedPremiumDecision != premium else { return }
        lastReportedPremiumDecision = premium
        writeDebugLog(
            "[Premium] \(spoof ? "spoofing the account attributes" : "no spoof — the account is already premium")"
                + " (from \(source))"
                + (spoof
                    ? " — this is the free-tier path, unchanged"
                    : " — its own entitlements stay exactly as sent, so nothing here can grey the lists out")
        )
    }
}
