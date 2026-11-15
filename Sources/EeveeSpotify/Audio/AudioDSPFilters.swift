import Foundation

/// 二阶滤波器的系数（转置直接 II 型）：
/// `y = b0·x + z1`、`z1 = b1·x − a1·y + z2`、`z2 = b2·x − a2·y`。
///
/// 这一层**只做数学**，不碰 AudioToolbox / 线程 / UserDefaults —— `Tests/AudioDSP` 会在
/// CI 里直接编译并断言它（本机没有 Swift 工具链，这是这段公式唯一的类型检查与行为检查）。
struct BiquadCoefficients: Equatable {
    var b0: Double = 1
    var b1: Double = 0
    var b2: Double = 0
    var a1: Double = 0
    var a2: Double = 0

    /// 直通。系数全 0 会让输出恒为 0，所以"不处理"必须显式用这一组。
    static let bypass = BiquadCoefficients()

    var isBypass: Bool { self == BiquadCoefficients.bypass }

    /// RBJ Audio EQ Cookbook 的 peaking EQ。
    ///
    /// - Parameters:
    ///   - frequency: 中心频率（Hz）。
    ///   - gainDb: 该频点的增益（dB，正 = 抬、负 = 削）。
    ///   - q: 品质因数；倍频程间隔的图形均衡器取 ≈1.41。
    ///   - sampleRate: 采样率（Hz）。
    static func peaking(frequency: Double,
                        gainDb: Double,
                        q: Double,
                        sampleRate: Double) -> BiquadCoefficients {
        guard sampleRate > 0,
              frequency > 0,
              frequency < sampleRate * 0.5,
              q > 0,
              gainDb.isFinite else {
            return .bypass
        }
        if abs(gainDb) < 0.01 { return .bypass }

        let a = pow(10, gainDb / 40)
        let omega = 2 * Double.pi * frequency / sampleRate
        let alpha = sin(omega) / (2 * q)
        let cosOmega = cos(omega)
        let a0 = 1 + alpha / a

        var coefficients = BiquadCoefficients()
        coefficients.b0 = (1 + alpha * a) / a0
        coefficients.b1 = (-2 * cosOmega) / a0
        coefficients.b2 = (1 - alpha * a) / a0
        coefficients.a1 = (-2 * cosOmega) / a0
        coefficients.a2 = (1 - alpha / a) / a0
        return coefficients
    }
}

/// 一个声道上、一个滤波器的状态。
///
/// 拖尾进入 denormal 时 FPU 会慢一个数量级，所以状态小于 1e-15 就直接清零 —— 这段代码
/// 跑在实时线程上，单拍算久了就是爆音。
struct BiquadState {
    var z1 = 0.0
    var z2 = 0.0

    mutating func reset() {
        z1 = 0
        z2 = 0
    }

    @inline(__always)
    mutating func process(_ x: Double, _ c: BiquadCoefficients) -> Double {
        let y = c.b0 * x + z1
        z1 = c.b1 * x - c.a1 * y + z2
        z2 = c.b2 * x - c.a2 * y
        if abs(z1) < 1e-15 { z1 = 0 }
        if abs(z2) < 1e-15 { z2 = 0 }
        return y
    }
}

/// 十段图形均衡器的频点与范围。
enum AudioDSPBands {
    /// 标准十段：倍频程间距。
    static let frequencies: [Double] = [31.5, 63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    /// 相邻两段"互不太串"的 Q（≈ 一个倍频程）。
    static let q: Double = 1.41
    static let count = frequencies.count
    static let minGainDb: Double = -12
    static let maxGainDb: Double = 12

    /// 把界面上的频点写成人能读的标签（`31 Hz` / `1 kHz` / `16 kHz`）。
    static func label(for frequency: Double) -> String {
        if frequency >= 1000 {
            let value = frequency / 1000
            return value == value.rounded()
                ? "\(Int(value)) kHz"
                : String(format: "%.1f kHz", value)
        }
        return frequency == frequency.rounded()
            ? "\(Int(frequency)) Hz"
            : String(format: "%.1f Hz", frequency)
    }
}

/// 预设：一组 10 段增益 + 一个前置增益（dB）。
///
/// 只做"听起来合理"的档位，不做听感调校；用户随时可以在十段上自己改。
enum AudioDSPPreset: String, CaseIterable {
    case flat
    case bass
    case vocal
    case rock
    case podcast

    var gainsDb: [Double] {
        switch self {
        case .flat:
            return [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        case .bass:
            return [7, 6, 4, 1, 0, 0, 0, 0, 0, 0]
        case .vocal:
            return [-3, -2, 0, 2, 4, 4, 2, 0, -1, -2]
        case .rock:
            return [5, 4, 2, -1, -2, 0, 2, 4, 5, 4]
        case .podcast:
            return [-8, -5, -2, 1, 3, 4, 3, 1, -1, -3]
        }
    }

    var preampDb: Double {
        switch self {
        case .flat: return -4
        case .bass: return -8
        case .vocal: return -4
        case .rock: return -7
        case .podcast: return -4
        }
    }

    /// 设置页上的 l10n 键。
    var titleKey: String { "audio_effects_preset_\(rawValue)" }
}
