import Foundation

/// 「这一行该贴哪一边」—— 按**歌词内容**判定，不看系统语言。
///
/// ── 为什么需要它（2026-10-02，用户报的原话）──────────────────────────────────
/// 「逐词歌词的时间轴没问题，就是它是**贴左**的，不是贴右的」（阿拉伯语歌）。
///
/// 病根不是 bidi：词的顺序、连写、逐词高亮的**行进方向**早就对了 ——
/// AM 渲染器读的是 SwiftUI `Text.Layout.Run.layoutDirection`（按内容逐 run 给），
/// 旧 overlay 也是按**字符串区间**上色（`wordRanges`），都不做"左边就是第一个词"的假设。
/// 错的是**整行贴哪一边**：对齐用的是 SwiftUI `Alignment.leading` / `TextAlignment.leading`，
/// 它解析用的是**环境 layoutDirection**，而环境方向来自**系统语言** ——
/// 于是"中文界面 + 阿拉伯语歌词"必然被排到左边。
///
/// ── 判定规则 ────────────────────────────────────────────────────────────────
/// 照搬 UAX#9 的 P2/P3（CoreText / TextKit 自己决定段落基方向用的就是这条）：
/// **跳过数字、标点、空白、符号、emoji，取第一个"强方向"字符** ——
/// 它在从右往左的区段里就整段按 RTL 排，否则按 LTR 排。
///
/// ⚠️ 刻意**只做码点区段判断**，不使用 `Unicode.Scalar.Properties.bidiClass`：
/// 后者在 stdlib 里的成员名/可用性写法各家工具链不一致，而本仓库没有 Mac 可以编译试错
/// （一次 CI 编译很贵）。区段表是死的，写错了肉眼可查。
extension String {

    /// 这一行是不是应当**从右往左**排（阿拉伯语、希伯来语、波斯语、乌尔都语…）。
    ///
    /// 用于替代"跟系统语言走"的 `.leading`：调用方拿它决定把行贴到哪一边，
    /// 这样中文界面看阿拉伯语歌词也能贴右。
    var prefersRightToLeftLayout: Bool {
        for scalar in unicodeScalars {
            if Self.isRightToLeftLetterScalar(scalar) { return true }
            // 是字母、又不在 RTL 区段 → 强 LTR（拉丁 / 希腊 / 西里尔 / CJK / 假名 / 谚文…）。
            // 数字、标点、空白、emoji 都不是 `letters`，按 P2 跳过。
            if CharacterSet.letters.contains(scalar) { return false }
        }
        // 整行只有数字/标点/符号（纯音乐、`♪`、时间戳…）：按 LTR 处理，与系统默认一致。
        return false
    }

    /// 该码点是不是**从右往左书写系统里的字母**。
    private static func isRightToLeftLetterScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        // ⚠️ 阿拉伯-印度数字（٠-٩ U+0660–0669 / ۰-۹ U+06F0–06F9）在阿拉伯区段里，
        //    但它们是**弱方向**字符（UAX#9 里是 AN），P2 要求跳过 ——
        //    否则"١٢٣ bottles"这种行的首个强方向字符会被误判成阿拉伯文。
        case 0x0660...0x0669, 0x06F0...0x06F9:
            return false

        case 0x0590...0x05FF,   // 希伯来文
             0x0600...0x06FF,   // 阿拉伯文
             0x0700...0x074F,   // 叙利亚文
             0x0750...0x077F,   // 阿拉伯文补充
             0x0780...0x07BF,   // 塔纳文（迪维希语）
             0x07C0...0x07FF,   // 西非书面文（NKo）
             0x0800...0x083F,   // 撒玛利亚文
             0x0840...0x085F,   // 曼达文
             0x08A0...0x08FF,   // 阿拉伯文扩展-A
             0xFB1D...0xFB4F,   // 希伯来文呈现形式
             0xFB50...0xFDFF,   // 阿拉伯文呈现形式 A
             0xFE70...0xFEFF:   // 阿拉伯文呈现形式 B
            return true

        default:
            return false
        }
    }
}
