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
