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

    // MARK: - 账号档位取证（2026-10-12，**只记不改**）

    /// 把**改写之前**那份账号态里的档位打一行（`type` / `catalogue` / `player-license`）。
    ///
    /// ── 为什么需要它 ────────────────────────────────────────────────────────
    /// 用户 2026-10-12 那轮 A/B 说"和不启用 Premium 补丁有关"，但他随后说明
    /// **自己没有真会员** ⇒ 那句只能读成"**灰 = 伪装没生效的那一档**"
    /// （免费号不打补丁本来就会灰、会放不动），而在此之前我们**没有一行日志**能回答
    /// "这次启动到底有没有看到账号态、看到的是什么档"。
    ///
    /// ── 判读下一份日志 ──────────────────────────────────────────────────────
    ///   · `type=free` **且**后面 `[Flags] …` 有行 ⇒ 伪装链路是通的，症状要往别处查
    ///     （`SESSION_2026-10-12_NIGHT.md` §10：内容请求到底拿到了多少）；
    ///   · `type=premium` ⇒ 服务端本来就给 premium（只有一个真订阅账号才会这样）；
    ///   · 这一行**一次都不出现** ⇒ 这次启动我们**根本没拿到 customize 响应体** ——
    ///     那正是 §9.2 那条"304 没有 body ⇒ 交不出配置 ⇒ 整库发灰 / 歌曲消失 / 放不动"的现场
    ///     （`[DL] customize 304 -> replaying the seed` / `[HCUS] …` 那两行是同一件事的另一半）。
    ///
    /// ⚠️ **只记不改**：`modifyAttributes` 照旧无条件跑。
    ///    2026-10-12 曾短暂加过一道"服务端说 premium 就不下伪装"的闸门，**已撤**：
    ///    前提（用户可能是真订阅）被用户否掉，而那道闸门唯一可能的副作用恰好是
    ///    "把伪装关掉 ⇒ 又变成免费档 ⇒ 正是用户报的那个症状"。
    static func reportServerAccountTier(_ attributes: [String: AccountAttribute]) {
        guard !attributes.isEmpty else { return }
        let type = attributes["type"]?.stringValue.lowercased() ?? "(absent)"
        guard type != lastReportedTier else { return }
        lastReportedTier = type

        let catalogue = attributes["catalogue"]?.stringValue.lowercased() ?? "(absent)"
        let license = attributes["player-license"]?.stringValue.lowercased() ?? "(absent)"
        writeDebugLog(
            "[Premium] the account state on the wire: type=\(type)"
                + " catalogue=\(catalogue) player-license=\(license)"
                + " — we rewrite it right after this line"
        )
    }

    /// 只在档位**变了**的时候报（这份 payload 每来一次都会问一遍，不能刷屏）。
    private static var lastReportedTier: String?
}
