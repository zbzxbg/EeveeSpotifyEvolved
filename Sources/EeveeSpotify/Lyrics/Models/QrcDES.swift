import Foundation

/// QQ 音乐**加密 QRC** 用的 DES 变体。
///
/// ## 为什么不能用 CommonCrypto 的 3DES
///
/// QQ 这套实现不是标准 DES：S 盒 S4 的第 3 行有一个 `10`（标准是 `1`），
/// 密钥扩展里 PC-2 的 D 半段下标整体少 1（`keyCompression[j] - 27`，标准是 `- 28`）。
/// 两个偏差不会互相抵消 —— 标准 3DES 解出来的首块是随机字节，永远不是 zlib 的 `78 9c`。
/// 这就是「明明有 key 却解不开」的唯一原因。
///
/// ## 出处
///
/// 算法照 `L-1124/QQMusicApi` 的 `qqmusic_api/algorithms/tripledes.py` 移植
/// （那个文件逐行注明了上面两个 bug，并注明来自 C# 的 `WXRIW/QQMusicDecoder`）。
/// 表与三个位置置换（IP / IP⁻¹ / P）由脚本从那份 Python 源码直接生成，
/// 免得手抄 512 个 S 盒数字时错一位。
///
/// ## 用法
///
/// `decrypt(_:)` 吃**整段密文**（hex / base64 由调用方解），按 8 字节块做 3DES；
/// 出来的是 zlib 流，交给 `ZlibInflate`（与酷狗 KRC 共用）。
enum QrcDES {

    /// 24 字节 = k1|k2|k3。QQ 所有客户端内置的同一串，不按用户/曲目变。
    private static let key: [UInt8] = Array("!@#)(*$%123ZXC!@!@#)(NHL".utf8)

    /// S 盒：8×64。**S4 的一个位置是 10 而不是标准 DES 的 1** —— 那不是笔误，
    /// QQ 的客户端实现就是这样（两个 bug 相互抵消不了，标准 3DES 解不开）。
    private static let sbox: [UInt8] = [
        14, 4, 13, 1, 2, 15, 11, 8, 3, 10, 6, 12, 5, 9, 0, 7,
        0, 15, 7, 4, 14, 2, 13, 1, 10, 6, 12, 11, 9, 5, 3, 8,
        4, 1, 14, 8, 13, 6, 2, 11, 15, 12, 9, 7, 3, 10, 5, 0,
        15, 12, 8, 2, 4, 9, 1, 7, 5, 11, 3, 14, 10, 0, 6, 13,
        15, 1, 8, 14, 6, 11, 3, 4, 9, 7, 2, 13, 12, 0, 5, 10,
        3, 13, 4, 7, 15, 2, 8, 15, 12, 0, 1, 10, 6, 9, 11, 5,
        0, 14, 7, 11, 10, 4, 13, 1, 5, 8, 12, 6, 9, 3, 2, 15,
        13, 8, 10, 1, 3, 15, 4, 2, 11, 6, 7, 12, 0, 5, 14, 9,
        10, 0, 9, 14, 6, 3, 15, 5, 1, 13, 12, 7, 11, 4, 2, 8,
        13, 7, 0, 9, 3, 4, 6, 10, 2, 8, 5, 14, 12, 11, 15, 1,
        13, 6, 4, 9, 8, 15, 3, 0, 11, 1, 2, 12, 5, 10, 14, 7,
        1, 10, 13, 0, 6, 9, 8, 7, 4, 15, 14, 3, 11, 5, 2, 12,
        7, 13, 14, 3, 0, 6, 9, 10, 1, 2, 8, 5, 11, 12, 4, 15,
        13, 8, 11, 5, 6, 15, 0, 3, 4, 7, 2, 12, 1, 10, 14, 9,
        10, 6, 9, 0, 12, 11, 7, 13, 15, 1, 3, 14, 5, 2, 8, 4,
        3, 15, 0, 6, 10, 10, 13, 8, 9, 4, 5, 11, 12, 7, 2, 14,
        2, 12, 4, 1, 7, 10, 11, 6, 8, 5, 3, 15, 13, 0, 14, 9,
        14, 11, 2, 12, 4, 7, 13, 1, 5, 0, 15, 10, 3, 9, 8, 6,
        4, 2, 1, 11, 10, 13, 7, 8, 15, 9, 12, 5, 6, 3, 0, 14,
        11, 8, 12, 7, 1, 14, 2, 13, 6, 15, 0, 9, 10, 4, 5, 3,
        12, 1, 10, 15, 9, 2, 6, 8, 0, 13, 3, 4, 14, 7, 5, 11,
        10, 15, 4, 2, 7, 12, 9, 5, 6, 1, 13, 14, 0, 11, 3, 8,
        9, 14, 15, 5, 2, 8, 12, 3, 7, 0, 4, 10, 1, 13, 11, 6,
        4, 3, 2, 12, 9, 5, 15, 10, 11, 14, 1, 7, 6, 0, 8, 13,
        4, 11, 2, 14, 15, 0, 8, 13, 3, 12, 9, 7, 5, 10, 6, 1,
        13, 0, 11, 7, 4, 9, 1, 10, 14, 3, 5, 12, 2, 15, 8, 6,
        1, 4, 11, 13, 12, 3, 7, 14, 10, 15, 6, 8, 0, 5, 9, 2,
        6, 11, 13, 8, 1, 4, 10, 7, 9, 5, 0, 15, 14, 2, 3, 12,
        13, 2, 8, 4, 6, 15, 11, 1, 10, 9, 3, 14, 5, 0, 12, 7,
        1, 15, 13, 8, 10, 3, 7, 4, 12, 5, 6, 11, 0, 14, 9, 2,
        7, 11, 4, 1, 9, 12, 14, 2, 0, 6, 10, 13, 15, 3, 5, 8,
        2, 1, 14, 7, 4, 10, 8, 13, 15, 12, 9, 0, 3, 5, 6, 11,
    ]

    private static let keyRndShift: [UInt8] = [
        1, 1, 2, 2, 2, 2, 2, 2, 1, 2, 2, 2, 2, 2, 2, 1
    ]

    private static let keyPermC: [UInt8] = [
        56, 48, 40, 32, 24, 16, 8, 0, 57, 49, 41, 33, 25, 17, 9, 1, 58, 50, 42, 34, 26, 18, 10, 2, 59, 51, 43, 35
    ]

    private static let keyPermD: [UInt8] = [
        62, 54, 46, 38, 30, 22, 14, 6, 61, 53, 45, 37, 29, 21, 13, 5, 60, 52, 44, 36, 28, 20, 12, 4, 27, 19, 11, 3
    ]

    private static let keyCompression: [UInt8] = [
        13, 16, 10, 23, 0, 4, 2, 27, 14, 5, 20, 9, 22, 18, 11, 3, 25, 7, 15, 6, 26, 19, 12, 1, 40, 51, 30, 36, 46, 54, 29, 39, 50, 44, 32, 47, 43, 48, 38, 55, 33, 52, 45, 41, 49, 35, 28, 31
    ]


    // MARK: - 入口

    /// 整段密文 → 解密后的 zlib 流（**未解压**）。长度必须是 8 的倍数。
    static func decrypt(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count >= 8, bytes.count % 8 == 0 else { return nil }

        let setup = keySetup(decrypt: true)
        var out = [UInt8]()
        out.reserveCapacity(bytes.count)

        var offset = 0
        while offset < bytes.count {
            out.append(contentsOf: tripleCrypt(Array(bytes[offset..<offset + 8]), setup: setup))
            offset += 8
        }
        return Data(out)
    }

    /// 只给测试用：按同一套 DES 加密一个 8 字节块（与 `decrypt` 互逆）。
    static func encryptBlock(_ block: [UInt8]) -> [UInt8]? {
        guard block.count == 8 else { return nil }
        return tripleCrypt(block, setup: keySetup(decrypt: false))
    }

    // MARK: - 单块

    private static func crypt(_ input: [UInt8], schedule: [[UInt8]]) -> [UInt8] {
        var (s0, s1) = initialPermutation(input)
        for round in 0..<15 {
            let previous = s1
            s1 = f(s1, key: schedule[round]) ^ s0
            s0 = previous
        }
        s0 = f(s1, key: schedule[15]) ^ s0
        return inversePermutation(s0, s1)
    }

    private static func tripleCrypt(_ block: [UInt8], setup: [[[UInt8]]]) -> [UInt8] {
        var current = block
        for stage in 0..<3 {
            current = crypt(current, schedule: setup[stage])
        }
        return current
    }

    /// 标准 DES 的初始置换（按位取值展开写，表见 `initialPermutation` 的位号）。
    private static func initialPermutation(_ input: [UInt8]) -> (UInt32, UInt32) {
        let v0 = UInt32(input[0]) | (UInt32(input[1]) << 8) | (UInt32(input[2]) << 16) | (UInt32(input[3]) << 24)
        let v1 = UInt32(input[4]) | (UInt32(input[5]) << 8) | (UInt32(input[6]) << 16) | (UInt32(input[7]) << 24)
        let s0 =
            ((v1 >> 6) & 1) << 31
            | ((v1 >> 14) & 1) << 30
            | ((v1 >> 22) & 1) << 29
            | ((v1 >> 30) & 1) << 28
            | ((v0 >> 6) & 1) << 27
            | ((v0 >> 14) & 1) << 26
            | ((v0 >> 22) & 1) << 25
            | ((v0 >> 30) & 1) << 24
            | ((v1 >> 4) & 1) << 23
            | ((v1 >> 12) & 1) << 22
            | ((v1 >> 20) & 1) << 21
            | ((v1 >> 28) & 1) << 20
            | ((v0 >> 4) & 1) << 19
            | ((v0 >> 12) & 1) << 18
            | ((v0 >> 20) & 1) << 17
            | ((v0 >> 28) & 1) << 16
            | ((v1 >> 2) & 1) << 15
            | ((v1 >> 10) & 1) << 14
            | ((v1 >> 18) & 1) << 13
            | ((v1 >> 26) & 1) << 12
            | ((v0 >> 2) & 1) << 11
            | ((v0 >> 10) & 1) << 10
            | ((v0 >> 18) & 1) << 9
            | ((v0 >> 26) & 1) << 8
            | ((v1 >> 0) & 1) << 7
            | ((v1 >> 8) & 1) << 6
            | ((v1 >> 16) & 1) << 5
            | ((v1 >> 24) & 1) << 4
            | ((v0 >> 0) & 1) << 3
            | ((v0 >> 8) & 1) << 2
            | ((v0 >> 16) & 1) << 1
            | ((v0 >> 24) & 1)
        let s1 =
            ((v1 >> 7) & 1) << 31
            | ((v1 >> 15) & 1) << 30
            | ((v1 >> 23) & 1) << 29
            | ((v1 >> 31) & 1) << 28
            | ((v0 >> 7) & 1) << 27
            | ((v0 >> 15) & 1) << 26
            | ((v0 >> 23) & 1) << 25
            | ((v0 >> 31) & 1) << 24
            | ((v1 >> 5) & 1) << 23
            | ((v1 >> 13) & 1) << 22
            | ((v1 >> 21) & 1) << 21
            | ((v1 >> 29) & 1) << 20
            | ((v0 >> 5) & 1) << 19
            | ((v0 >> 13) & 1) << 18
            | ((v0 >> 21) & 1) << 17
            | ((v0 >> 29) & 1) << 16
            | ((v1 >> 3) & 1) << 15
            | ((v1 >> 11) & 1) << 14
            | ((v1 >> 19) & 1) << 13
            | ((v1 >> 27) & 1) << 12
            | ((v0 >> 3) & 1) << 11
            | ((v0 >> 11) & 1) << 10
            | ((v0 >> 19) & 1) << 9
            | ((v0 >> 27) & 1) << 8
            | ((v1 >> 1) & 1) << 7
            | ((v1 >> 9) & 1) << 6
            | ((v1 >> 17) & 1) << 5
            | ((v1 >> 25) & 1) << 4
            | ((v0 >> 1) & 1) << 3
            | ((v0 >> 9) & 1) << 2
            | ((v0 >> 17) & 1) << 1
            | ((v0 >> 25) & 1)
        return (s0, s1)
    }


    private static func inversePermutation(_ s0: UInt32, _ s1: UInt32) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: 8)
        data[0] = UInt8((
            ((s1 >> 27) & 1) << 7
            | ((s0 >> 27) & 1) << 6
            | ((s1 >> 19) & 1) << 5
            | ((s0 >> 19) & 1) << 4
            | ((s1 >> 11) & 1) << 3
            | ((s0 >> 11) & 1) << 2
            | ((s1 >> 3) & 1) << 1
            | ((s0 >> 3) & 1)
        ) & 0xFF)

        data[1] = UInt8((
            ((s1 >> 26) & 1) << 7
            | ((s0 >> 26) & 1) << 6
            | ((s1 >> 18) & 1) << 5
            | ((s0 >> 18) & 1) << 4
            | ((s1 >> 10) & 1) << 3
            | ((s0 >> 10) & 1) << 2
            | ((s1 >> 2) & 1) << 1
            | ((s0 >> 2) & 1)
        ) & 0xFF)

        data[2] = UInt8((
            ((s1 >> 25) & 1) << 7
            | ((s0 >> 25) & 1) << 6
            | ((s1 >> 17) & 1) << 5
            | ((s0 >> 17) & 1) << 4
            | ((s1 >> 9) & 1) << 3
            | ((s0 >> 9) & 1) << 2
            | ((s1 >> 1) & 1) << 1
            | ((s0 >> 1) & 1)
        ) & 0xFF)

        data[3] = UInt8((
            ((s1 >> 24) & 1) << 7
            | ((s0 >> 24) & 1) << 6
            | ((s1 >> 16) & 1) << 5
            | ((s0 >> 16) & 1) << 4
            | ((s1 >> 8) & 1) << 3
            | ((s0 >> 8) & 1) << 2
            | ((s1 >> 0) & 1) << 1
            | ((s0 >> 0) & 1)
        ) & 0xFF)

        data[4] = UInt8((
            ((s1 >> 31) & 1) << 7
            | ((s0 >> 31) & 1) << 6
            | ((s1 >> 23) & 1) << 5
            | ((s0 >> 23) & 1) << 4
            | ((s1 >> 15) & 1) << 3
            | ((s0 >> 15) & 1) << 2
            | ((s1 >> 7) & 1) << 1
            | ((s0 >> 7) & 1)
        ) & 0xFF)

        data[5] = UInt8((
            ((s1 >> 30) & 1) << 7
            | ((s0 >> 30) & 1) << 6
            | ((s1 >> 22) & 1) << 5
            | ((s0 >> 22) & 1) << 4
            | ((s1 >> 14) & 1) << 3
            | ((s0 >> 14) & 1) << 2
            | ((s1 >> 6) & 1) << 1
            | ((s0 >> 6) & 1)
        ) & 0xFF)

        data[6] = UInt8((
            ((s1 >> 29) & 1) << 7
            | ((s0 >> 29) & 1) << 6
            | ((s1 >> 21) & 1) << 5
            | ((s0 >> 21) & 1) << 4
            | ((s1 >> 13) & 1) << 3
            | ((s0 >> 13) & 1) << 2
            | ((s1 >> 5) & 1) << 1
            | ((s0 >> 5) & 1)
        ) & 0xFF)

        data[7] = UInt8((
            ((s1 >> 28) & 1) << 7
            | ((s0 >> 28) & 1) << 6
            | ((s1 >> 20) & 1) << 5
            | ((s0 >> 20) & 1) << 4
            | ((s1 >> 12) & 1) << 3
            | ((s0 >> 12) & 1) << 2
            | ((s1 >> 4) & 1) << 1
            | ((s0 >> 4) & 1)
        ) & 0xFF)

        return data
    }

    /// 轮函数 F：E 扩展 → 与子密钥异或 → S 盒 → P 置换。
    private static func f(_ state: UInt32, key: [UInt8]) -> UInt32 {
        let t1 = ((state & 1) << 31)
            | ((state & 0xF800_0000) >> 1)
            | ((state & 0x1F80_0000) >> 3)
            | ((state & 0x01F8_0000) >> 5)
            | ((state & 0x001F_8000) >> 7)
        let t2 = ((state & 0x0001_F800) << 15)
            | ((state & 0x0000_1F80) << 13)
            | ((state & 0x0000_01F8) << 11)
            | ((state & 0x0000_001F) << 9)
            | ((state & 0x8000_0000) >> 23)

        let k0 = UInt32((t1 >> 24) & 0xFF) ^ UInt32(key[0])
        let k1 = UInt32((t1 >> 16) & 0xFF) ^ UInt32(key[1])
        let k2 = UInt32((t1 >> 8) & 0xFF) ^ UInt32(key[2])
        let k3 = UInt32((t2 >> 24) & 0xFF) ^ UInt32(key[3])
        let k4 = UInt32((t2 >> 16) & 0xFF) ^ UInt32(key[4])
        let k5 = UInt32((t2 >> 8) & 0xFF) ^ UInt32(key[5])

        // 8 个 S 盒是**平铺**在 `sbox` 里的（每个 64 项），所以下标要加 `盒号 * 64`：
        // 一律从第 0 盒取的话，它仍然"能跑"、只是解出来是随机字节 —— 静默失败那种错。
        let state2 =
            (UInt32(sbox[0 * 64 + sboxBit(Int(k0 >> 2))]) << 28)
            | (UInt32(sbox[1 * 64 + sboxBit(Int(((k0 & 0x03) << 4) | (k1 >> 4)))]) << 24)
            | (UInt32(sbox[2 * 64 + sboxBit(Int(((k1 & 0x0F) << 2) | (k2 >> 6)))]) << 20)
            | (UInt32(sbox[3 * 64 + sboxBit(Int(k2 & 0x3F))]) << 16)
            | (UInt32(sbox[4 * 64 + sboxBit(Int(k3 >> 2))]) << 12)
            | (UInt32(sbox[5 * 64 + sboxBit(Int(((k3 & 0x03) << 4) | (k4 >> 4)))]) << 8)
            | (UInt32(sbox[6 * 64 + sboxBit(Int(((k4 & 0x0F) << 2) | (k5 >> 6)))]) << 4)
            | UInt32(sbox[7 * 64 + sboxBit(Int(k5 & 0x3F))])

        return (
            ((state2 >> 16) & 1) << 31
            | ((state2 >> 25) & 1) << 30
            | ((state2 >> 12) & 1) << 29
            | ((state2 >> 11) & 1) << 28
            | ((state2 >> 3) & 1) << 27
            | ((state2 >> 20) & 1) << 26
            | ((state2 >> 4) & 1) << 25
            | ((state2 >> 15) & 1) << 24
            | ((state2 >> 31) & 1) << 23
            | ((state2 >> 17) & 1) << 22
            | ((state2 >> 9) & 1) << 21
            | ((state2 >> 6) & 1) << 20
            | ((state2 >> 27) & 1) << 19
            | ((state2 >> 14) & 1) << 18
            | ((state2 >> 1) & 1) << 17
            | ((state2 >> 22) & 1) << 16
            | ((state2 >> 30) & 1) << 15
            | ((state2 >> 24) & 1) << 14
            | ((state2 >> 8) & 1) << 13
            | ((state2 >> 18) & 1) << 12
            | ((state2 >> 0) & 1) << 11
            | ((state2 >> 5) & 1) << 10
            | ((state2 >> 29) & 1) << 9
            | ((state2 >> 23) & 1) << 8
            | ((state2 >> 13) & 1) << 7
            | ((state2 >> 19) & 1) << 6
            | ((state2 >> 2) & 1) << 5
            | ((state2 >> 26) & 1) << 4
            | ((state2 >> 10) & 1) << 3
            | ((state2 >> 21) & 1) << 2
            | ((state2 >> 28) & 1) << 1
            | ((state2 >> 7) & 1)
        )
    }

    /// S 盒查表的「行列换位」：DES 的 6 bit 输入要拆成 2 bit 行号 + 4 bit 列号。
    private static func sboxBit(_ value: Int) -> Int {
        (value & 32) | ((value & 31) >> 1) | ((value & 1) << 4)
    }

    // MARK: - 密钥扩展

    /// DES 密钥扩展。`decrypt` 只影响 16 轮子密钥的**排列顺序**（第 16 轮先用）。
    private static func keySchedule(_ key: ArraySlice<UInt8>, decrypt: Bool) -> [[UInt8]] {
        let bytes = Array(key)
        let v0 = UInt32(bytes[0]) | (UInt32(bytes[1]) << 8) | (UInt32(bytes[2]) << 16) | (UInt32(bytes[3]) << 24)
        let v1 = UInt32(bytes[4]) | (UInt32(bytes[5]) << 8) | (UInt32(bytes[6]) << 16) | (UInt32(bytes[7]) << 24)

        func bit(_ index: Int) -> UInt32 {
            index < 32
                ? ((v0 >> UInt32(31 - index)) & 1)
                : ((v1 >> UInt32(63 - index)) & 1)
        }

        var c: UInt32 = 0
        for (i, position) in keyPermC.enumerated() {
            c |= bit(Int(position)) << UInt32(31 - i)
        }
        var d: UInt32 = 0
        for (i, position) in keyPermD.enumerated() {
            d |= bit(Int(position)) << UInt32(31 - i)
        }

        var schedule = [[UInt8]](repeating: [0, 0, 0, 0, 0, 0], count: 16)
        for round in 0..<16 {
            let shift = Int(keyRndShift[round])
            c = ((c << UInt32(shift)) | (c >> UInt32(28 - shift))) & 0xFFFF_FFF0
            d = ((d << UInt32(shift)) | (d >> UInt32(28 - shift))) & 0xFFFF_FFF0

            let target = decrypt ? 15 - round : round
            schedule[target] = [0, 0, 0, 0, 0, 0]

            for j in 0..<24 {
                let value = (c >> UInt32(31 - Int(keyCompression[j]))) & 1
                schedule[target][j / 8] |= UInt8(value << UInt32(7 - (j % 8)))
            }
            // ⚠️ D 半段的下标是 `- 27`（标准 DES 是 `- 28`）—— 见文件头那个 bug。
            for j in 24..<48 {
                let value = (d >> UInt32(31 - (Int(keyCompression[j]) - 27))) & 1
                schedule[target][j / 8] |= UInt8(value << UInt32(7 - (j % 8)))
            }
        }
        return schedule
    }

    /// 三把子密钥：解密是 k3 D → k2 E → k1 D（与加密互为逆序）。
    private static func keySetup(decrypt: Bool) -> [[[UInt8]]] {
        if decrypt {
            return [
                keySchedule(key[16..<24], decrypt: true),
                keySchedule(key[8..<16], decrypt: false),
                keySchedule(key[0..<8], decrypt: true)
            ]
        }
        return [
            keySchedule(key[0..<8], decrypt: false),
            keySchedule(key[8..<16], decrypt: true),
            keySchedule(key[16..<24], decrypt: false)
        ]
    }
}
