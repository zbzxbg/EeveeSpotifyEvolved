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

// MARK: - AutoEq 参数均衡

/// 滤波器的种类。AutoEq 的 `ParametricEQ.txt` 只用这三种：`PK`、`LSC`、`HSC`。
enum AudioDSPFilterKind: String, Equatable {
    case peaking
    case lowShelf
    case highShelf
}

/// 一条滤波器的描述。频率、增益、Q 都是文件里的原值，换算到系数时再看采样率。
struct AudioDSPFilterSpec: Equatable {
    var kind: AudioDSPFilterKind
    /// 中心频率（peaking）或转折频率（架式），Hz。
    var frequency: Double
    /// 该点的增益（dB）。
    var gainDb: Double
    /// 品质因数；架式用它折成斜率（见 `shelfSlope`）。
    var q: Double

    /// 架式的 alpha 可以用 Q 表达，而 `lowShelf` / `highShelf` 用的是斜率 S：
    /// `alpha = sin/2·√((A + 1/A)(1/S − 1) + 2)`；令它等于 `sin/(2Q)` 得
    /// `S = 1 / (1 + (1/Q² − 2)/(A + 1/A))`，其中 `A = 10^(gain/40)`。
    /// Q = 0.7071 正好是 S = 1（AutoEq 的架式一般写 Q 0.70）。
    var shelfSlope: Double {
        let a = pow(10, gainDb / 40)
        guard q > 0, a.isFinite, a > 0 else { return 1 }
        let sum = a + 1 / a
        guard sum > 0 else { return 1 }
        let slope = 1 / (1 + (1 / (q * q) - 2) / sum)
        guard slope.isFinite else { return 1 }
        return min(max(slope, 0.05), 4)
    }

    /// 由斜率反推 Q：`shelfSlope` 的逆运算（`Q = 1/√((1/S − 1)(A + 1/A) + 2)`）。
    ///
    /// 设置页的两个架式一直用斜率描述，进链时换成 Q，再由 `shelfSlope` 换回去。
    static func shelf(kind: AudioDSPFilterKind,
                      frequency: Double,
                      gainDb: Double,
                      slope: Double) -> AudioDSPFilterSpec {
        let a = pow(10, gainDb / 40)
        let sum = a + 1 / a
        let inverse = (1 / max(slope, 0.001) - 1) * sum + 2
        let q = inverse > 0 ? 1 / sqrt(inverse) : defaultShelfQ
        return AudioDSPFilterSpec(
            kind: kind,
            frequency: frequency,
            gainDb: gainDb,
            q: q.isFinite && q > 0 ? q : defaultShelfQ
        )
    }

    /// 斜率换算失效时的兜底：Q 0.7071（RBJ 的 S = 1）。
    static let defaultShelfQ: Double = 0.7071

    func coefficients(sampleRate: Double) -> BiquadCoefficients {
        switch kind {
        case .peaking:
            return .peaking(
                frequency: frequency, gainDb: gainDb, q: q, sampleRate: sampleRate
            )
        case .lowShelf:
            return .lowShelf(
                frequency: frequency, gainDb: gainDb, slope: shelfSlope, sampleRate: sampleRate
            )
        case .highShelf:
            return .highShelf(
                frequency: frequency, gainDb: gainDb, slope: shelfSlope, sampleRate: sampleRate
            )
        }
    }
}

/// 一条完整的参数均衡链：一个前置增益 + 若干条滤波器。
///
/// AutoEq 的 `ParametricEQ.txt` 就是它的文本形态：`Preamp:` 一行，随后每行一条 `Filter`。
/// 这层只做解析与系数，不碰 UserDefaults、文件与实时线程。
struct AudioDSPFilterChain: Equatable {

    /// 链上最多几条。AutoEq 的标准输出是 10 条，余量留给手改过的文件。
    static let maxFilters = 16

    /// Q 缺省值：架式的 RBJ 换算在 0.7071 处等于斜率 1。
    static let defaultQ: Double = 0.7071

    var preampDb: Double
    var filters: [AudioDSPFilterSpec]

    var preampLinear: Double { pow(10, preampDb / 20) }

    func coefficients(sampleRate: Double) -> [BiquadCoefficients] {
        filters.map { $0.coefficients(sampleRate: sampleRate) }
    }

    /// 解析 AutoEq 的 `ParametricEQ.txt`。
    ///
    /// 认的形状：`Preamp: -6.0 dB` 与 `Filter 1: ON PK Fc 514 Hz Gain -4.4 dB Q 0.68`。
    /// · `OFF` 的滤波器跳过（用户手工关掉的那几条）；
    /// · `Q` 缺省时按 `defaultQ`；
    /// · 超过 `maxFilters` 的截断。
    ///
    /// 空文本、没有一条可用的 Filter、或者某条 Filter 读不出频率/增益 —— 返回 nil。
    /// 不做"猜一半"的部分解析：半截的校正曲线听着不对，却很难判断问题出在中括号还是文件。
    static func autoeq(_ text: String) -> AudioDSPFilterChain? {
        var preampDb = 0.0
        var specs: [AudioDSPFilterSpec] = []
        var sawFilter = false

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            if line.lowercased().hasPrefix("preamp:") {
                let rest = String(line.dropFirst("preamp:".count))
                guard let value = firstNumber(in: rest), value.isFinite else { return nil }
                preampDb = value
                continue
            }

            guard line.lowercased().hasPrefix("filter") else { continue }
            if isFilterLineOff(line) { continue }
            sawFilter = true
            guard let spec = parseFilterLine(line) else { return nil }
            if specs.count < maxFilters {
                specs.append(spec)
            }
        }

        guard sawFilter, !specs.isEmpty else { return nil }
        return AudioDSPFilterChain(preampDb: min(max(preampDb, -30), 12), filters: specs)
    }

    /// `Filter 3: OFF ...` —— AutoEq 的输出里用户手工关掉的那几条，整行跳过。
    private static func isFilterLineOff(_ line: String) -> Bool {
        let tokens = line.split { $0 == " " || $0 == "\t" || $0 == "," }
        return tokens.count > 2 && tokens[2].lowercased() == "off"
    }

    /// 一条 `Filter N: ON <TYPE> Fc <f> Hz Gain <g> dB Q <q>`。
    ///
    /// 只按关键字定位数值（`Fc` / `Gain` / `Q`），不依赖字段顺序与列宽；
    /// `ON` 的判定放在这里，`OFF` 在上层已跳过。
    private static func parseFilterLine(_ line: String) -> AudioDSPFilterSpec? {
        let tokens = line.split { $0 == " " || $0 == "\t" || $0 == "," }
        guard tokens.count >= 5 else { return nil }

        guard let fcIndex = tokens.firstIndex(where: { $0.lowercased() == "fc" }),
              fcIndex > 0,
              fcIndex + 1 < tokens.count,
              let frequency = Double(tokens[fcIndex + 1]),
              frequency > 0,
              let gainIndex = tokens.firstIndex(where: { $0.lowercased() == "gain" }),
              gainIndex + 1 < tokens.count,
              let gainDb = Double(tokens[gainIndex + 1]),
              gainDb.isFinite,
              let kind = kind(forToken: tokens[fcIndex - 1].lowercased()) else {
            return nil
        }

        var q = defaultQ
        if let qIndex = tokens.firstIndex(where: { $0.lowercased() == "q" }),
           qIndex + 1 < tokens.count,
           let parsed = Double(tokens[qIndex + 1]),
           parsed > 0 {
            q = parsed
        }

        return AudioDSPFilterSpec(kind: kind, frequency: frequency, gainDb: gainDb, q: q)
    }

    /// AutoEq 的写法是 `PK` / `LSC` / `HSC`；rest 里也认常见的别名。
    private static func kind(forToken token: String) -> AudioDSPFilterKind? {
        switch token {
        case "pk", "peak", "peq":
            return .peaking
        case "lsc", "ls", "lsf", "lowshelf":
            return .lowShelf
        case "hsc", "hs", "hsf", "highshelf":
            return .highShelf
        default:
            return nil
        }
    }

    /// 一行里的第一个数（`-6.0 dB` → `-6.0`）。
    private static func firstNumber(in text: String) -> Double? {
        for token in text.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
            if let value = Double(token) { return value }
        }
        return nil
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

/// 耳机串扰，按 bs2b 的做法（libbs2b，MIT，© 2005 Boris Mikhaylov）。
///
/// 一个低通把对侧声音滤掉高频后再混过来，一个 highboost 一阶差分把本侧的高频补回去，
/// 两路相加再乘一个补偿增益。档位决定"低通截止 + 混入量"这一对参数：
/// 截止越低、混入越多，声场越近；`gain` 把低频被叠加的那部分抵消掉。
///
/// 三个预置（截止 Hz / 混入 0.1 dB）：
/// · default：700 / 45（4.5 dB）
/// · CMOY：700 / 60（6 dB）
/// · JMeier：650 / 95（9.5 dB）
///
/// 双耳时间差不靠延迟线：低通的相位滞后本身就是它，所以这里没有环形缓冲。
enum AudioDSPCrossfeed {
    /// 0 = 关，1…3 = 逐级加强。
    static let levelCount = 4
    /// bs2b 的采样率上下界：出了这个范围就退回直通（系数会失真）。
    static let minSampleRate: Double = 2000
    static let maxSampleRate: Double = 384000

    struct Settings: Equatable {
        /// 低通：`y = a0·x + b1·y₋₁`
        var lowFilterGain: Double
        var lowFilterPole: Double
        /// highboost：`y = a0·x + a1·x₋₁ + b1·y₋₁`
        var highFilterGain: Double
        var highFilterFeedForward: Double
        var highFilterPole: Double
        /// 低频叠加的补偿增益（小于 1）。
        var makeup: Double
        var isBypass: Bool
    }

    static let bypass = Settings(
        lowFilterGain: 0,
        lowFilterPole: 0,
        highFilterGain: 1,
        highFilterFeedForward: 0,
        highFilterPole: 0,
        makeup: 1,
        isBypass: true
    )

    /// 索引 = 档位 − 1。
    private static let presets: [(frequency: Double, feedTenthDb: Double)] = [
        (700, 45),
        (700, 60),
        (650, 95),
    ]

    static func settings(level: Int, sampleRate: Double) -> Settings {
        let clamped = min(max(level, 0), levelCount - 1)
        guard clamped > 0,
              sampleRate >= minSampleRate,
              sampleRate <= maxSampleRate else {
            return bypass
        }

        let preset = presets[clamped - 1]
        let feed = preset.feedTenthDb / 10
        // 两条支路的电平：低频按 −5/6 分、高频按 +1/6 分，都把 −3 dB 的基准点带上；
        // 两者的差正好是"混入量"，所以 bs2b 用同一个数推三样东西。
        let lowDb = feed * -5 / 6 - 3
        let highDb = feed / 6 - 3
        let lowGainLinear = pow(10, lowDb / 20)
        let highGainLinear = 1 - pow(10, highDb / 20)
        guard lowGainLinear > 0, highGainLinear > 0, highGainLinear < 1 else { return bypass }

        // highboost 的截止跟着两条支路差出来：GB_lo 与 20·log10(G_hi) 的差每 12 dB 翻一倍。
        let highFrequency = preset.frequency
            * pow(2, (lowDb - 20 * log10(highGainLinear)) / 12)
        guard highFrequency.isFinite, highFrequency > 0 else { return bypass }

        let lowPole = exp(-2 * Double.pi * preset.frequency / sampleRate)
        let highPole = exp(-2 * Double.pi * highFrequency / sampleRate)
        let makeup = 1 / (1 - highGainLinear + lowGainLinear)
        guard lowPole > 0, lowPole < 1, highPole > 0, highPole < 1,
              makeup.isFinite, makeup > 0 else {
            return bypass
        }

        return Settings(
            lowFilterGain: lowGainLinear * (1 - lowPole),
            lowFilterPole: lowPole,
            highFilterGain: 1 - highGainLinear * (1 - highPole),
            highFilterFeedForward: -highPole,
            highFilterPole: highPole,
            makeup: makeup,
            isBypass: false
        )
    }

    /// 设置页 Picker 的 l10n 键：`audio_effects_crossfeed_` + 档位后缀。
    ///
    /// 用前缀拼接而不是四条字面量，`Tools/l10n_lint.py` 才认得出这四条键是活的
    /// （它的用法扫描只认"字面量 + `.localized`"、"实参位置"和"前缀 + 运行时拼接"三种形状；
    /// 函数体里 `return "…"` 的字面量不在其中）。
    static func titleKey(for level: Int) -> String {
        let suffix: String
        switch min(max(level, 0), levelCount - 1) {
        case 1: suffix = "low"
        case 2: suffix = "medium"
        case 3: suffix = "high"
        default: suffix = "off"
        }
        return "audio_effects_crossfeed_" + suffix
    }
}

// MARK: - 左右平衡

/// 左右平衡：0 = 居中，−1 = 只剩左声道，+1 = 只剩右声道。
///
/// 对侧那一路乘 `1 − |v|`（线性衰减），不做等功率补偿：平衡滑杆是用来纠"一边偏响"的，
/// 等功率会让中间几个位置整体变响，反而更难和另一边对上。
enum AudioDSPBalance {

    static func gains(balance: Double) -> (left: Double, right: Double) {
        guard balance.isFinite else { return (1, 1) }
        let clamped = min(max(balance, -1), 1)
        return (min(1, 1 - clamped), min(1, 1 + clamped))
    }
}

/// 输出端的峰值限幅。EQ、架式、压缩器都把电平往上推，推过满刻度的部分原来被 ±1 钳掉：
/// 削波产生的是奇次谐波，听感是"炸"而不是"响"。这里把峰值压回目标电平，钳位退化成安全网。
///
/// · 目标 −0.5 dBFS：给 DAC 与系统重采样留一点过冲余量；
/// · 瞬时 attack：看到超标的帧立刻压，宁可削一点瞬态也要保证不越界（可预测 > 保真）；
/// · 指数释放：150 ms 回到单位增益，避免增益跟波形抖动出"抽吸"声；
/// · 左右**共用**一个增益：只压峰值一侧会让人声/鼓的声像跟着电平跑。
enum AudioDSPLimiter {

    static let ceilingDb: Double = -0.5

    static let ceilingLinear: Double = pow(10, ceilingDb / 20)

    static let releaseSeconds: Double = 0.15

    /// 每样本的释放系数：`gain = 1 + (gain − 1) × release`；采样率未知时给一个 44.1 kHz 附近的保守值。
    static func releaseCoefficient(sampleRate: Double) -> Double {
        guard sampleRate > 0 else { return 0.99987 }
        return exp(-1 / (releaseSeconds * sampleRate))
    }

    /// 下一帧的增益。`peak` 是这一帧左右两个声道绝对值的较大者。
    ///
    /// 超过目标就压到 `ceiling / peak`，且**不高于当前增益**（已经在压的时候就继续压，
    /// 免得一个低峰把增益立刻放回来）；没超过就按释放系数往回爬 —— 包括 `peak == 0` 的
    /// 那一帧：过零点也走释放，否则每个波形过零都把增益弹回 1，等于给自己加了一层调制。
    /// 返回值恒在 0…1。
    static func nextGain(current: Double, peak: Double, release: Double) -> Double {
        let held = current.isFinite ? min(max(current, 0), 1) : 1
        guard peak.isFinite else { return held }
        if peak > ceilingLinear {
            return min(held, ceilingLinear / peak)
        }
        let recovered = 1 + (held - 1) * min(max(release, 0), 1)
        return min(max(recovered, 0), 1)
    }
}
