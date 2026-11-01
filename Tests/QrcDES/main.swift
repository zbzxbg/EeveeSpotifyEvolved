import Foundation

/// `QrcDES` 的断言程序（纯逻辑，CI 跑；见 `.github/workflows/tests.yml`）。
///
/// 为什么必须钉这一份：QQ 音乐加密 QRC 用的**不是标准 3DES**（S 盒 S4 有一处 `10`
/// 而不是 `1`、密钥扩展 PC-2 的 D 半段下标整体少 1），所以标准实现解出来是随机字节。
/// 本仓库那套 DES 是从 `L-1124/QQMusicApi` 的 Python 实现移植的 —— 512 个 S 盒数字
/// 加三组位置换，抄错一位就是"解密恒失败、但没有任何报错"（QRC 逐字档直接空转）。
///
/// 这里的两个向量由**同一份 Python 实现**生成，CI 里 `swiftc` 编起来跑：
/// 单块钉住 DES 本身，整段钉住"解密 + zlib 解压"这一条完整链路。
///
/// ⚠️ 本机（Windows）没有 Swift 工具链，这个测试只有在 CI 的 macOS runner 上才会跑。

var failures = 0

func require(_ condition: Bool, _ message: String) {
    if condition {
        print("  ok   \(message)")
    } else {
        failures += 1
        print("  FAIL \(message)")
    }
}

func hexBytes(_ text: String) -> [UInt8]? {
    var out: [UInt8] = []
    out.reserveCapacity(text.count / 2)
    var index = text.startIndex
    while index < text.endIndex {
        let next = text.index(index, offsetBy: 2)
        guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
        out.append(byte)
        index = next
    }
    return out
}

func hexString(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
}

// MARK: - 单块：加密 / 解密互逆

// 同一套算法（Python 参考实现）算出来的：3DES_ENCRYPT("QRC-TEST") = 8e2ef268ca4ba1bc
let plaintext = Array("QRC-TEST".utf8)
require(plaintext.count == 8, "test vector is one DES block")

if let cipher = QrcDES.encryptBlock(plaintext) {
    require(hexString(cipher) == "8e2ef268ca4ba1bc",
            "3DES-ENCRYPT of the reference block matches the Python implementation")
    require(cipher.count == 8, "ciphertext keeps the block size")
    require(QrcDES.decrypt(Data(cipher)) == Data(plaintext),
            "decrypt() inverts encryptBlock() for one block")
} else {
    require(false, "encryptBlock() rejected an 8-byte block")
}

// 非 8 字节必须被拒 —— 否则后面的整块循环会把半个块当数据算。
require(QrcDES.encryptBlock(Array("short".utf8)) == nil, "encryptBlock() rejects a short block")
require(QrcDES.decrypt(Data([0x00, 0x01, 0x02])) == nil, "decrypt() rejects a non-block-aligned input")

// MARK: - 整段：解密 → zlib → 正文

// 密文 32 字节，解压后应当正好是这一小段 QRC 正文。
let payloadCipherHex = "f2e3893cc3007ddb6c3485eeb7c080975c4ef10c68c415ea86c9bd33bd18b7c8"
let expectedPayload = "[ti:t]\n[0,100]a(0,100)\n"

if let cipherBytes = hexBytes(payloadCipherHex) {
    require(cipherBytes.count == 32, "payload vector is 4 DES blocks")

    if let decrypted = QrcDES.decrypt(Data(cipherBytes)) {
        let stream = [UInt8](decrypted)
        // 解出来的第一件事必须是 zlib 头；不是的话说明 DES 又抄错了。
        require(stream.count >= 2 && stream[0] == 0x78, "decrypted stream starts with the zlib header")

        if let inflated = ZlibInflate.inflate(stream) {
            require(String(data: inflated, encoding: .utf8) == expectedPayload,
                    "decrypt + inflate reproduces the reference QRC body")
        } else {
            require(false, "ZlibInflate rejected the decrypted stream")
        }
    } else {
        require(false, "decrypt() rejected a block-aligned payload")
    }
} else {
    require(false, "payload test vector is not valid hex")
}

// MARK: - 结果

if failures == 0 {
    print("QrcDES: all assertions passed")
} else {
    print("QrcDES: \(failures) assertion(s) FAILED")
    exit(1)
}
