enum EeveePropertyModification {
    case remove
    case setBool(Bool)
    case setEnum(String)
    // Flip if present, append if missing (needs name + scope).
    case forceBool(Bool)
    // Set the enum if present, **append if missing** (needs name + scope).
    //
    // 为什么需要它（2026-10-01）：`.setEnum` 只改服务端**已经下发**的条目，
    // 而"新设计"那批实验 flag 服务端基本不会下发 → 用户在图里写的那条覆盖永远是空枪，
    // 且**一点痕迹都没有**。`.forceBool` 早就有"没有就追加"的能力，enum 这边缺一个
    // 对等的。见 `Tools/eevee-hookfinder/FLAGS_9186_DESIGN.md`。
    case forceEnum(String)

    // Set the int if present, **append if missing** (needs name + scope).
    //
    // 为什么需要它（2026-10-02）：Spotify 自己的"减少打扰"
    // （`ios-messaging-reduceinterventions-impl`）里有一批**整数**开关
    // （节流秒数、次数上限、`max_account_age_days` 之类），设置页只有 bool/enum 两档
    // 时这些只能看不能改。与 `.forceEnum` 对等：命中就覆盖、没有就追加。
    case forceInt(Int32)
}

struct EeveePropertyReplacement {
    let scope: String?
    let name: String?
    let modification: EeveePropertyModification
    
    init(name: String? = nil, scope: String? = nil, modification: EeveePropertyModification) {
        self.name = name
        self.scope = scope
        self.modification = modification
    }
}
