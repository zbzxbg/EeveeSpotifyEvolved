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

    /// 每个预设自带的前置增益（dB）。
    ///
    /// `flat` 是 **0 dB**：全 0 dB + 前置 0 时整条链逐位等于原声（系数是恒等，前置是 1.0）——
    /// 打开 DSP 之后不做任何事就应该是"什么都没变"，这是判断"效果链有没有偷偷染色"的基准。
    var preampDb: Double {
        switch self {
        case .flat: return 0
        case .bass: return -6
        case .vocal: return -2
        case .rock: return -5
        case .podcast: return -2
        }
    }

    /// 设置页上的 l10n 键。
    var titleKey: String { "audio_effects_preset_\(rawValue)" }
}

// MARK: - 低架 / 高架（「低音」「清晰度」两颗滑杆）

/// 「低音 / 高音」两颗架式滤波器的频点与范围。
///
/// 与十段 peaking 的区别在于形状：peaking 只抬中心附近、两端回 0 dB；架式把**一侧全部**
/// 抬起来（低频架抬 150 Hz 以下、高频架抬 6 kHz 以上），这才是"低音增强 / 清晰度"的听感。
/// 两者串在同一条链上，频点刻意不重叠。
enum AudioDSPShelves {
    static let lowFrequency: Double = 150
    static let highFrequency: Double = 6000
    /// 架式斜率：1 = 最平缓，越小越陡。0.9 抬起来不出现明显的"中间凸起"。
    static let slope: Double = 0.9
    static let minGainDb: Double = -12
    static let maxGainDb: Double = 12
    /// 链上的两个位置：0 = 低频架，1 = 高频架。
    static let count = 2
}

extension BiquadCoefficients {
    /// RBJ Audio EQ Cookbook 的 low shelf。
    static func lowShelf(frequency: Double,
                         gainDb: Double,
                         slope: Double,
                         sampleRate: Double) -> BiquadCoefficients {
        guard sampleRate > 0,
              frequency > 0,
              frequency < sampleRate * 0.5,
              slope > 0,
              gainDb.isFinite else {
            return .bypass
        }
        if abs(gainDb) < 0.01 { return .bypass }

        let a = pow(10, gainDb / 40)
        let omega = 2 * Double.pi * frequency / sampleRate
        let cosOmega = cos(omega)
        let sinOmega = sin(omega)
        let alpha = sinOmega / 2 * sqrt((a + 1 / a) * (1 / slope - 1) + 2)
        let beta = 2 * sqrt(a) * alpha

        let b0 = a * ((a + 1) - (a - 1) * cosOmega + beta)
        let b1 = 2 * a * ((a - 1) - (a + 1) * cosOmega)
        let b2 = a * ((a + 1) - (a - 1) * cosOmega - beta)
        let a0 = (a + 1) + (a - 1) * cosOmega + beta
        let a1 = -2 * ((a - 1) + (a + 1) * cosOmega)
        let a2 = (a + 1) + (a - 1) * cosOmega - beta
        return normalized(b0: b0, b1: b1, b2: b2, a0: a0, a1: a1, a2: a2)
    }

    /// RBJ Audio EQ Cookbook 的 high shelf。
    static func highShelf(frequency: Double,
                          gainDb: Double,
                          slope: Double,
                          sampleRate: Double) -> BiquadCoefficients {
        guard sampleRate > 0,
              frequency > 0,
              frequency < sampleRate * 0.5,
              slope > 0,
              gainDb.isFinite else {
            return .bypass
        }
        if abs(gainDb) < 0.01 { return .bypass }

        let a = pow(10, gainDb / 40)
        let omega = 2 * Double.pi * frequency / sampleRate
        let cosOmega = cos(omega)
        let sinOmega = sin(omega)
        let alpha = sinOmega / 2 * sqrt((a + 1 / a) * (1 / slope - 1) + 2)
        let beta = 2 * sqrt(a) * alpha

        let b0 = a * ((a + 1) + (a - 1) * cosOmega + beta)
        let b1 = -2 * a * ((a - 1) + (a + 1) * cosOmega)
        let b2 = a * ((a + 1) + (a - 1) * cosOmega - beta)
        let a0 = (a + 1) - (a - 1) * cosOmega + beta
        let a1 = 2 * ((a - 1) - (a + 1) * cosOmega)
        let a2 = (a + 1) - (a - 1) * cosOmega - beta
        return normalized(b0: b0, b1: b1, b2: b2, a0: a0, a1: a1, a2: a2)
    }

    /// 按 a0 归一化。除零 / 非有限一律退回直通 —— 实时线程上宁可不出声的"原声"，
    /// 也不要让 NaN 进滤波器状态（那会一直卡在 NaN 上）。
    private static func normalized(b0: Double,
                                   b1: Double,
                                   b2: Double,
                                   a0: Double,
                                   a1: Double,
                                   a2: Double) -> BiquadCoefficients {
        guard a0.isFinite, abs(a0) > 1e-12 else { return .bypass }
        var coefficients = BiquadCoefficients()
        coefficients.b0 = b0 / a0
        coefficients.b1 = b1 / a0
        coefficients.b2 = b2 / a0
        coefficients.a1 = a1 / a0
        coefficients.a2 = a2 / a0
        guard coefficients.b0.isFinite,
              coefficients.b1.isFinite,
              coefficients.b2.isFinite,
              coefficients.a1.isFinite,
              coefficients.a2.isFinite else {
            return .bypass
        }
        return coefficients
    }
}

// MARK: - 压缩器

/// 单频段向下压缩：包络跟随 + 软拐点前的线性区 + makeup。
///
/// 只做"把响的地方压回来"这一件事：没有膝部（knee）、没有侧链。参数由设置页的
/// 一个「强度」滑杆映射，0 = 直通。包络跟随用一阶攻击/释放（系数 = e^(-1/(sr·τ))），
/// 释放比攻击慢一个量级，避免压出"抽气感"。
enum AudioDSPCompander {
    struct Parameters: Equatable {
        var thresholdDb: Double
        var ratio: Double
        var makeupDb: Double
        var attackCoefficient: Double
        var releaseCoefficient: Double
        var isBypass: Bool

        static let bypass = Parameters(
            thresholdDb: 0,
            ratio: 1,
            makeupDb: 0,
            attackCoefficient: 0,
            releaseCoefficient: 0,
            isBypass: true
        )
    }

    /// `amount`：0 = 直通，1 = 最重（阈值 -24 dB、4:1）。
    static func parameters(amount: Double, sampleRate: Double) -> Parameters {
        let clamped = min(max(amount, 0), 1)
        guard clamped > 0.001, sampleRate > 0 else { return .bypass }

        let threshold = -10 - 14 * clamped
        let ratio = 1 + 3 * clamped
        // 补偿一半的压缩量：压满时仍能听出"更紧"，而不是整体变小。
        let makeup = -threshold * (1 - 1 / ratio) * 0.5
        let attackSeconds = 0.003
        let releaseSeconds = 0.120
        return Parameters(
            thresholdDb: threshold,
            ratio: ratio,
            makeupDb: makeup,
            attackCoefficient: exp(-1 / (sampleRate * attackSeconds)),
            releaseCoefficient: exp(-1 / (sampleRate * releaseSeconds)),
            isBypass: false
        )
    }

    /// 每个声道一份包络状态。
    struct Envelope {
        var magnitude: Double = 0

        /// 输入一个样本，返回这一拍的增益（线性）。
        @inline(__always)
        mutating func gain(for input: Double, parameters: Parameters) -> Double {
            guard !parameters.isBypass else { return 1 }

            let target = abs(input)
            let coefficient = target > magnitude
                ? parameters.attackCoefficient
                : parameters.releaseCoefficient
            magnitude += (target - magnitude) * (1 - coefficient)
            // 拖尾进 denormal：置零，别让 FPU 在实时线程上慢一个数量级。
            if magnitude < 1e-9 { magnitude = 0 }

            let makeup = pow(10, parameters.makeupDb / 20)
            guard magnitude > 0 else { return makeup }

            let levelDb = 20 * log10(magnitude)
            let overDb = levelDb - parameters.thresholdDb
            guard overDb > 0 else { return makeup }

            let gainDb = -overDb * (1 - 1 / parameters.ratio) + parameters.makeupDb
            // 上限 +18 dB：强行喂 0 dBFS 也不该把静音段放大成噪声墙。
            return min(pow(10, gainDb / 20), 8)
        }
    }
}

// MARK: - 交叉馈送

/// 耳机串扰（bs2b 那类）：把对侧声道经一个低通、延迟几拍之后混一点过来。
///
/// 只做"听起来不偏在头两侧"这一件事：对侧信号走 700 Hz 一阶低通（模拟头颅对高频的
/// 遮蔽）+ 0.3 ms 延迟（双耳时间差），混入量按档位。不做电平补偿 —— 混入量最大 0.36，
/// 中频最多 +1 dB 左右，还在硬限幅的余量里。
enum AudioDSPCrossfeed {
    /// 0 = 关，1…3 = 逐级加强。
    static let levelCount = 4
    /// 环形缓冲上界：48 kHz 下 0.3 ms 只有约 15 个样本，64 足够。
    static let maxDelaySamples = 64
    static let lowpassFrequency: Double = 700
    static let interauralDelaySeconds: Double = 0.0003

    struct Settings: Equatable {
        var feed: Double
        var lowpassCoefficient: Double
        var delaySamples: Int
        var isBypass: Bool
    }

    static let bypass = Settings(
        feed: 0,
        lowpassCoefficient: 0,
        delaySamples: 1,
        isBypass: true
    )

    private static let feedByLevel: [Double] = [0, 0.16, 0.26, 0.36]

    static func settings(level: Int, sampleRate: Double) -> Settings {
        let clamped = min(max(level, 0), levelCount - 1)
        guard clamped > 0, sampleRate > 0 else { return bypass }

        let coefficient = min(max(1 - exp(-2 * Double.pi * lowpassFrequency / sampleRate), 0.001), 0.999)
        var delay = Int((interauralDelaySeconds * sampleRate).rounded())
        delay = min(max(delay, 1), maxDelaySamples)
        return Settings(
            feed: feedByLevel[clamped],
            lowpassCoefficient: coefficient,
            delaySamples: delay,
            isBypass: false
        )
    }

    /// 设置页 Picker 的 l10n 键。
    static func titleKey(for level: Int) -> String {
        switch min(max(level, 0), levelCount - 1) {
        case 1: return "audio_effects_crossfeed_low"
        case 2: return "audio_effects_crossfeed_medium"
        case 3: return "audio_effects_crossfeed_high"
        default: return "audio_effects_crossfeed_off"
        }
    }
}