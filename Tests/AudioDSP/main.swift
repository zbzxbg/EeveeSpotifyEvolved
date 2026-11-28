import Foundation

/// `AudioDSPFilters` 的断言程序（纯逻辑，CI 跑；见 `.github/workflows/tests.yml`）。
///
/// 为什么单钉这一份：EQ 的系数是盲写公式，本机又没有 Swift 工具链 —— 符号错、a0 漏除、
/// 正值当负值，全都只会表现为"声音不对/爆音"，而不是编译错。这里用可算的稳态响应与稳定性
/// 条件把它钉住：
/// · 直通必须逐样本相等；
/// · 每个频点、每个增益下系数有限、极点稳定（|a2| < 1）；
/// · 1 kHz 上 +6 dB / −6 dB 的稳态增益要贴近 10^(±6/20)；
/// · 十段全 +12 dB 串联不许出 NaN、不许无界放大；
/// · 预设形状正确（10 段、在范围内、前置留下余量）。

var failures = 0

func require(_ condition: Bool, _ message: String) {
    if condition {
        print("  ok   \(message)")
    } else {
        failures += 1
        print("  FAIL \(message)")
    }
}

let sampleRate = 44100.0

// MARK: - 直通

var bypassState = BiquadState()
var bypassOk = true
for value in [-1.0, -0.25, 0.0, 0.5, 1.0] {
    let output = bypassState.process(value, .bypass)
    if abs(output - value) > 1e-12 { bypassOk = false }
}
require(bypassOk, "bypass passes every sample through unchanged")
require(BiquadCoefficients.bypass.isBypass, "the bypass coefficients are the identity")
require(BiquadCoefficients.peaking(frequency: 1000, gainDb: 0, q: 1.41, sampleRate: sampleRate).isBypass,
        "0 dB designs the identity, not a near-identity")

// MARK: - 系数：有限、稳定

var coefficientsFinite = true
var coefficientsStable = true
for gain in [-12.0, -6.0, -0.5, 0.5, 6.0, 12.0] {
    for frequency in AudioDSPBands.frequencies {
        let c = BiquadCoefficients.peaking(
            frequency: frequency, gainDb: gain, q: AudioDSPBands.q, sampleRate: sampleRate)
        if !(c.b0.isFinite && c.b1.isFinite && c.b2.isFinite && c.a1.isFinite && c.a2.isFinite) {
            coefficientsFinite = false
        }
        // 二阶 IIR 的极点判据：|a2| < 1 且 |a1| < 1 + a2（三角条件），这里用前者当粗筛。
        if abs(c.a2) >= 1 { coefficientsStable = false }
    }
}
require(coefficientsFinite, "every band/gain combination designs finite coefficients")
require(coefficientsStable, "every band/gain combination stays inside the stability bound")

// 采样率高于 Nyquist 的频点必须被拒（16 kHz 在 32 kHz 采样下无效）。
require(
    BiquadCoefficients.peaking(frequency: 16000, gainDb: 6, q: 1.41, sampleRate: 32000).isBypass,
    "a band above Nyquist falls back to bypass instead of producing garbage"
)

// MARK: - 稳态增益

/// 用正弦稳态的 RMS 比测增益：跑两遍半拍，后半段统计（避开起始瞬态）。
///
/// 两个频率分开：`filterFrequency` 是滤波器的中心，`probeFrequency` 是喂进去的正弦。
/// 只测"中心处增益"时两者相等；测"别的频点受影响多少"时把 `probeFrequency` 挪开。
func steadyStateGain(filterFrequency: Double,
                     probeFrequency: Double,
                     gainDb: Double) -> Double {
    let c = BiquadCoefficients.peaking(
        frequency: filterFrequency, gainDb: gainDb, q: AudioDSPBands.q, sampleRate: sampleRate)
    var state = BiquadState()
    let omega = 2 * Double.pi * probeFrequency / sampleRate
    let total = 8192
    var inputSquares = 0.0
    var outputSquares = 0.0
    for index in 0..<total {
        let input = sin(omega * Double(index))
        let output = state.process(input, c)
        if index > total / 2 {
            inputSquares += input * input
            outputSquares += output * output
        }
    }
    guard inputSquares > 0 else { return 0 }
    return (outputSquares / inputSquares).squareRoot()
}

let boost = steadyStateGain(filterFrequency: 1000, probeFrequency: 1000, gainDb: 6)
let expectedBoost = pow(10, 6.0 / 20)
require(abs(boost - expectedBoost) / expectedBoost < 0.05,
        "1 kHz +6 dB boosts by ~2x (got \(String(format: "%.3f", boost)))")

let cut = steadyStateGain(filterFrequency: 1000, probeFrequency: 1000, gainDb: -6)
let expectedCut = pow(10, -6.0 / 20)
require(abs(cut - expectedCut) / expectedCut < 0.05,
        "1 kHz -6 dB cuts to ~0.5x (got \(String(format: "%.3f", cut)))")

// 1 kHz 那一段不该把 8 kHz 带起来：三段倍频程之外应接近 1。
let offBand = steadyStateGain(filterFrequency: 1000, probeFrequency: 8000, gainDb: 6)
require(offBand < 1.35, "a 1 kHz boost leaves 8 kHz mostly alone (got \(String(format: "%.3f", offBand)))")

// MARK: - 十段串联

var chain = Array(repeating: BiquadState(), count: AudioDSPBands.count)
var cascadeFinite = true
var cascadePeak = 0.0
let cascadeCoefficients = AudioDSPBands.frequencies.map {
    BiquadCoefficients.peaking(frequency: $0, gainDb: 12, q: AudioDSPBands.q, sampleRate: sampleRate)
}
for index in 0..<2048 {
    var value = sin(2 * Double.pi * 1000 / sampleRate * Double(index)) * 0.5
    for band in 0..<AudioDSPBands.count {
        value = chain[band].process(value, cascadeCoefficients[band])
    }
    if !value.isFinite { cascadeFinite = false; break }
    cascadePeak = max(cascadePeak, abs(value))
}
require(cascadeFinite, "a cascade of all ten bands at +12 dB stays finite")
require(cascadePeak < 64, "the cascade does not run away (peak \(String(format: "%.2f", cascadePeak)))")

// 全部 0 dB 时级联必须逐样本等于输入（系数是 identity）。
var flatChain = Array(repeating: BiquadState(), count: AudioDSPBands.count)
var flatOk = true
for index in 0..<64 {
    let input = sin(2 * Double.pi * 440 / sampleRate * Double(index))
    var value = input
    for band in 0..<AudioDSPBands.count {
        value = flatChain[band].process(value, .bypass)
    }
    if abs(value - input) > 1e-12 { flatOk = false }
}
require(flatOk, "ten bypassed bands leave the signal bit-exact")

// MARK: - 预设

var presetsOk = true
for preset in AudioDSPPreset.allCases {
    let gains = preset.gainsDb
    if gains.count != AudioDSPBands.count { presetsOk = false }
    if gains.contains(where: { $0 < AudioDSPBands.minGainDb || $0 > AudioDSPBands.maxGainDb }) {
        presetsOk = false
    }
    if preset.preampDb > 0 { presetsOk = false }
    if !preset.titleKey.hasPrefix("audio_effects_preset_") { presetsOk = false }
}
require(presetsOk, "every preset has ten in-range bands, leaves preamp headroom and a title key")

// MARK: - 标签

require(AudioDSPBands.label(for: 1000) == "1 kHz", "1 kHz formats without a decimal")
require(AudioDSPBands.label(for: 16000) == "16 kHz", "16 kHz formats without a decimal")
require(AudioDSPBands.label(for: 31.5) == "31.5 Hz", "31.5 Hz keeps one decimal")
require(AudioDSPBands.label(for: 63) == "63 Hz", "63 Hz formats without a decimal")

// MARK: - 架式（低音 / 清晰度）

/// 任意二阶系数在某个频点的稳态增益（正弦 RMS 比，跳过起始瞬态）。
func measuredGain(_ coefficients: BiquadCoefficients, probeFrequency: Double) -> Double {
    var state = BiquadState()
    let omega = 2 * Double.pi * probeFrequency / sampleRate
    let total = 8192
    var inputSquares = 0.0
    var outputSquares = 0.0
    for index in 0..<total {
        let input = sin(omega * Double(index))
        let output = state.process(input, coefficients)
        if index >= total / 2 {
            inputSquares += input * input
            outputSquares += output * output
        }
    }
    guard inputSquares > 0, outputSquares > 0 else { return 0 }
    return sqrt(outputSquares / inputSquares)
}

require(
    BiquadCoefficients.lowShelf(frequency: AudioDSPShelves.lowFrequency, gainDb: 0,
                                slope: AudioDSPShelves.slope, sampleRate: sampleRate).isBypass,
    "0 dB designs the identity for the low shelf"
)
require(
    BiquadCoefficients.highShelf(frequency: AudioDSPShelves.highFrequency, gainDb: 0,
                                 slope: AudioDSPShelves.slope, sampleRate: sampleRate).isBypass,
    "0 dB designs the identity for the high shelf"
)
require(
    BiquadCoefficients.highShelf(frequency: AudioDSPShelves.highFrequency, gainDb: 6,
                                 slope: AudioDSPShelves.slope, sampleRate: 8000).isBypass,
    "a shelf above Nyquist falls back to bypass"
)

let lowShelfBoost = BiquadCoefficients.lowShelf(
    frequency: AudioDSPShelves.lowFrequency, gainDb: 6,
    slope: AudioDSPShelves.slope, sampleRate: sampleRate)
let lowShelfGainAtBass = measuredGain(lowShelfBoost, probeFrequency: 40)
let lowShelfGainAtTreble = measuredGain(lowShelfBoost, probeFrequency: 12000)
require(
    abs(lowShelfGainAtBass - pow(10, 6.0 / 20)) < 0.30,
    "a +6 dB low shelf lifts 40 Hz by about 6 dB (measured \(lowShelfGainAtBass))"
)
require(
    abs(lowShelfGainAtTreble - 1) < 0.05,
    "the low shelf leaves 12 kHz alone (measured \(lowShelfGainAtTreble))"
)

let highShelfBoost = BiquadCoefficients.highShelf(
    frequency: AudioDSPShelves.highFrequency, gainDb: 6,
    slope: AudioDSPShelves.slope, sampleRate: sampleRate)
let highShelfGainAtTreble = measuredGain(highShelfBoost, probeFrequency: 12000)
let highShelfGainAtBass = measuredGain(highShelfBoost, probeFrequency: 100)
require(
    abs(highShelfGainAtTreble - pow(10, 6.0 / 20)) < 0.35,
    "a +6 dB high shelf lifts 12 kHz by about 6 dB (measured \(highShelfGainAtTreble))"
)
require(
    abs(highShelfGainAtBass - 1) < 0.05,
    "the high shelf leaves 100 Hz alone (measured \(highShelfGainAtBass))"
)

var shelvesStable = true
for gain in [-12.0, -6.0, 6.0, 12.0] {
    let designs = [
        BiquadCoefficients.lowShelf(frequency: AudioDSPShelves.lowFrequency, gainDb: gain,
                                    slope: AudioDSPShelves.slope, sampleRate: sampleRate),
        BiquadCoefficients.highShelf(frequency: AudioDSPShelves.highFrequency, gainDb: gain,
                                     slope: AudioDSPShelves.slope, sampleRate: sampleRate),
    ]
    for coefficients in designs {
        let finite = coefficients.b0.isFinite && coefficients.b1.isFinite
            && coefficients.b2.isFinite && coefficients.a1.isFinite && coefficients.a2.isFinite
        // 极点都在单位圆内的充要条件（二阶实系数）：三个三角不等式同时成立。
        let insideUnitCircle = 1 + coefficients.a1 + coefficients.a2 > 0
            && 1 - coefficients.a1 + coefficients.a2 > 0
            && 1 - coefficients.a2 > 0
        if !finite || !insideUnitCircle {
            shelvesStable = false
        }
    }
}
require(shelvesStable, "every shelf design is finite and keeps its poles inside the unit circle")

// MARK: - 压缩器

require(AudioDSPCompander.parameters(amount: 0, sampleRate: sampleRate).isBypass,
        "0 % compander amount is a bypass")
require(AudioDSPCompander.parameters(amount: 1, sampleRate: sampleRate).isBypass == false,
        "100 % compander amount is active")

let heavyCompander = AudioDSPCompander.parameters(amount: 1, sampleRate: sampleRate)
require(heavyCompander.thresholdDb < -20 && heavyCompander.ratio > 3.5,
        "the top of the range is a low threshold and a high ratio")
require(heavyCompander.attackCoefficient > 0, "the attack coefficient is positive")
require(heavyCompander.attackCoefficient < heavyCompander.releaseCoefficient,
        "attack is faster than release")

var bypassEnvelope = AudioDSPCompander.Envelope()
require(bypassEnvelope.gain(for: 0.9, parameters: .bypass) == 1,
        "a bypassed compander returns unity gain")

var loudEnvelope = AudioDSPCompander.Envelope()
var loudGain = 1.0
for _ in 0..<Int(sampleRate) {
    loudGain = loudEnvelope.gain(for: 0.5, parameters: heavyCompander)
}
require(loudGain.isFinite, "the compander gain stays finite under a steady loud tone")
require(loudGain < 0.9, "a steady loud tone is pulled down (gain \(loudGain))")
require(loudGain > 0.05, "the compander does not mute the material (gain \(loudGain))")

var quietEnvelope = AudioDSPCompander.Envelope()
var quietGain = 1.0
for _ in 0..<Int(sampleRate) {
    quietGain = quietEnvelope.gain(for: 0.001, parameters: heavyCompander)
}
require(quietGain >= 1, "quiet material only sees the makeup gain")
require(quietGain.isFinite && quietGain < 8, "the makeup gain stays inside its cap")

// MARK: - 交叉馈送

require(AudioDSPCrossfeed.settings(level: 0, sampleRate: sampleRate).isBypass,
        "level 0 turns crossfeed off")

let crossfeedLevels = (1..<AudioDSPCrossfeed.levelCount).map {
    AudioDSPCrossfeed.settings(level: $0, sampleRate: sampleRate)
}

/// 交叉馈送那条支路的直流增益（`a0 / (1 − b1)`）：混过去的那一份到底有多响。
func crossfeedLowBandGain(_ settings: AudioDSPCrossfeed.Settings) -> Double {
    settings.lowFilterGain / (1 - settings.lowFilterPole)
}

var crossfeedValid = true
for settings in crossfeedLevels {
    if settings.isBypass { crossfeedValid = false }
    if !(settings.lowFilterGain > 0 && settings.lowFilterGain < 1) { crossfeedValid = false }
    if !(settings.lowFilterPole > 0 && settings.lowFilterPole < 1) { crossfeedValid = false }
    if !(settings.highFilterGain > 0 && settings.highFilterGain < 1) { crossfeedValid = false }
    if !(settings.highFilterPole > 0 && settings.highFilterPole < 1) { crossfeedValid = false }
    if !(settings.highFilterFeedForward < 0) { crossfeedValid = false }
    if !(settings.makeup > 0 && settings.makeup < 1) { crossfeedValid = false }
    // highboost 的截止必须高于低通：极点离 1 更远。
    if !(settings.highFilterPole < settings.lowFilterPole) { crossfeedValid = false }
}
require(crossfeedValid, "every crossfeed preset has sane gains, poles and a makeup under unity")

require(crossfeedLowBandGain(crossfeedLevels[0]) > crossfeedLowBandGain(crossfeedLevels[2]),
        "the strongest preset attenuates the crossfed band more than the default one")

require(AudioDSPCrossfeed.settings(level: 1, sampleRate: 1000).isBypass,
        "a sample rate below the bs2b range falls back to bypass")
require(AudioDSPCrossfeed.settings(level: 1, sampleRate: 500000).isBypass,
        "a sample rate above the bs2b range falls back to bypass")
require(AudioDSPCrossfeed.settings(level: 99, sampleRate: sampleRate)
            == AudioDSPCrossfeed.settings(level: 3, sampleRate: sampleRate),
        "an out-of-range level clamps to the loudest preset")

// 同一档在不同采样率下只有极点变，直流增益不变：这是 bs2b 把截止换算成极点的结果。
let default44 = crossfeedLevels[0]
let default48 = AudioDSPCrossfeed.settings(level: 1, sampleRate: 48000)
require(abs(crossfeedLowBandGain(default44) - crossfeedLowBandGain(default48)) < 1e-9,
        "the crossfed band keeps its level across sample rates")
require(default48.lowFilterPole > default44.lowFilterPole,
        "a higher sample rate puts the same cutoff closer to one")

// MARK: - 限幅

let limiterRelease = AudioDSPLimiter.releaseCoefficient(sampleRate: sampleRate)
require(limiterRelease > 0 && limiterRelease < 1,
        "the release coefficient sits strictly inside (0, 1) (got \(limiterRelease))")
require(AudioDSPLimiter.ceilingLinear < 1 && AudioDSPLimiter.ceilingLinear > 0.9,
        "the ceiling sits just under full scale (\(AudioDSPLimiter.ceilingLinear))")
require(AudioDSPLimiter.releaseCoefficient(sampleRate: 48000) > limiterRelease,
        "a higher sample rate takes smaller steps per sample, the same 150 ms in seconds")
require(AudioDSPLimiter.releaseCoefficient(sampleRate: 0) < 1,
        "an unknown sample rate still yields a decaying release")

// 2.5 倍满刻度的正弦：没有限幅的话输出会顶到 ±1 并被钳掉。
var limiterGain = 1.0
var limiterPeak = 0.0
for index in 0..<4096 {
    let input = 2.5 * sin(2 * Double.pi * 220 * Double(index) / sampleRate)
    limiterGain = AudioDSPLimiter.nextGain(current: limiterGain, peak: abs(input), release: limiterRelease)
    limiterPeak = max(limiterPeak, abs(input) * limiterGain)
}
require(limiterPeak <= AudioDSPLimiter.ceilingLinear + 1e-9,
        "a signal far over full scale never crosses the ceiling (peak \(limiterPeak))")
require(limiterGain.isFinite && limiterGain > 0 && limiterGain < 1,
        "the gain settles below unity while the signal stays loud")

// 安静下来以后按 150 ms 的时间常数回到单位增益。
var recoveringGain = limiterGain
for _ in 0..<Int(sampleRate) {
    recoveringGain = AudioDSPLimiter.nextGain(
        current: recoveringGain, peak: AudioDSPLimiter.ceilingLinear * 0.5, release: limiterRelease)
}
require(recoveringGain > 0.99, "one second of quiet recovers the gain to unity (got \(recoveringGain))")

// 一步之内不能跳回 1：那样每个峰值都会变一次增益，听起来是抽吸。
let oneStep = AudioDSPLimiter.nextGain(current: 0.5, peak: 0.1, release: limiterRelease)
require(oneStep < 0.51, "the release is gradual, not a single-step jump (got \(oneStep))")

let throughZero = AudioDSPLimiter.nextGain(current: 0.4, peak: 0, release: limiterRelease)
require(throughZero > 0.4 && throughZero < 0.45,
        "a zero crossing releases gradually instead of snapping back to unity (got \(throughZero))")
require(AudioDSPLimiter.nextGain(current: 0.2, peak: .nan, release: limiterRelease) == 0.2,
        "a non-finite peak keeps the held gain instead of propagating NaN")
require(AudioDSPLimiter.nextGain(current: 1, peak: 1, release: limiterRelease) < 1,
        "a full-scale sample is still pulled to the ceiling")

// MARK: - AutoEq 参数均衡

/// AutoEq 的真实输出（crinacle / 711 in-ear / Apple AirPods Pro，MIT，Jaakko Pasanen）。
let autoeqText = """
Preamp: -6.0 dB
Filter 1: ON LSC Fc 105 Hz Gain 2.6 dB Q 0.70
Filter 2: ON PK Fc 514 Hz Gain -4.4 dB Q 0.68
Filter 3: ON PK Fc 8903 Hz Gain 6.0 dB Q 1.66
Filter 4: ON PK Fc 183 Hz Gain 2.0 dB Q 0.77
Filter 5: ON PK Fc 4613 Hz Gain 3.4 dB Q 2.46
Filter 6: ON HSC Fc 10000 Hz Gain -0.5 dB Q 0.70
Filter 7: ON PK Fc 1517 Hz Gain -1.0 dB Q 2.33
Filter 8: ON PK Fc 929 Hz Gain 1.2 dB Q 2.75
Filter 9: ON PK Fc 44 Hz Gain -0.5 dB Q 2.16
Filter 10: ON PK Fc 618 Hz Gain -0.5 dB Q 2.86
"""

let autoeq = AudioDSPFilterChain.autoeq(autoeqText)
require(autoeq != nil, "the AutoEq ParametricEQ sample parses")
require(autoeq?.preampDb == -6, "the preamp line is read (-6 dB)")
require(autoeq?.filters.count == 10, "all ten filters are kept")
require(autoeq?.filters.filter { $0.kind == .lowShelf }.count == 1, "the LSC line becomes a low shelf")
require(autoeq?.filters.filter { $0.kind == .highShelf }.count == 1, "the HSC line becomes a high shelf")
require(autoeq?.filters.filter { $0.kind == .peaking }.count == 8, "the PK lines become peaking bands")

let firstFilter = autoeq?.filters.first
require(firstFilter?.frequency == 105, "the first filter keeps its frequency")
require(firstFilter?.gainDb == 2.6, "the first filter keeps its gain")
require(firstFilter?.q == 0.70, "the first filter keeps its Q")

let thirdFilter = autoeq?.filters.dropFirst(2).first
require(thirdFilter?.kind == .peaking && thirdFilter?.frequency == 8903 && thirdFilter?.gainDb == 6,
        "a peaking line in the middle of the file reads back intact")

let preampLinear = autoeq?.preampLinear ?? 0
require(abs(preampLinear - 0.501187) < 1e-5, "-6 dB of preamp is a half-amplitude gain (\(preampLinear))")

let shelfSlope = autoeq?.filters.first?.shelfSlope ?? 0
require(shelfSlope > 0.9 && shelfSlope <= 1,
        "a shelf written as Q 0.70 lands just under slope 1 (got \(shelfSlope))")

var autoeqCoefficientsOk = true
for rate in [44100.0, 48000.0] {
    guard let coefficients = autoeq?.coefficients(sampleRate: rate) else { continue }
    for c in coefficients {
        if !(c.b0.isFinite && c.b1.isFinite && c.b2.isFinite && c.a1.isFinite && c.a2.isFinite) {
            autoeqCoefficientsOk = false
        }
        if abs(c.a2) >= 1 { autoeqCoefficientsOk = false }
    }
}
require(autoeqCoefficientsOk, "every AutoEq filter designs finite, stable coefficients at 44.1 and 48 kHz")

require(AudioDSPFilterChain.autoeq("") == nil, "an empty file is rejected")
require(AudioDSPFilterChain.autoeq("Preamp: -3 dB\n") == nil, "a file with no filter line is rejected")

let offLine = """
Preamp: -4.0 dB
Filter 1: ON PK Fc 514 Hz Gain -4.4 dB Q 0.68
Filter 2: OFF PK Fc 1000 Hz Gain 3.0 dB Q 1.00
"""
let offParsed = AudioDSPFilterChain.autoeq(offLine)
require(offParsed?.filters.count == 1, "an OFF filter is skipped instead of applied")

require(AudioDSPFilterChain.autoeq("Filter 1: ON PK Fc 514 Hz Gain -4.4 dB") != nil,
        "a filter line on its own is enough, with no preamp line")

require(AudioDSPFilterChain.autoeq("Filter 1: ON PK Gain -4.4 dB Q 0.7") == nil,
        "a filter without a frequency is rejected instead of guessed")

let noQ = AudioDSPFilterChain.autoeq("Filter 1: ON PK Fc 514 Hz Gain -4.4 dB")
require(noQ?.filters.first?.q == AudioDSPFilterChain.defaultQ, "a missing Q falls back to the default")

require(AudioDSPFilterChain.autoeq("Filter 1: ON XX Fc 514 Hz Gain 1 dB Q 1") == nil,
        "an unknown filter type is rejected")

let manyFilters = (1...20).map { "Filter \($0): ON PK Fc \(100 * $0) Hz Gain 1.0 dB Q 1.0" }
let truncated = AudioDSPFilterChain.autoeq("Preamp: 0 dB\n" + manyFilters.joined(separator: "\n"))
require(truncated?.filters.count == AudioDSPFilterChain.maxFilters,
        "a file with more filters than the chain holds is truncated")

let slopeSpec = AudioDSPFilterSpec.shelf(kind: .lowShelf, frequency: 150, gainDb: 6, slope: 0.9)
require(abs(slopeSpec.shelfSlope - 0.9) < 1e-9,
        "a shelf built from a slope reads that slope back (got \(slopeSpec.shelfSlope))")
require(slopeSpec.coefficients(sampleRate: sampleRate)
            == BiquadCoefficients.lowShelf(
                frequency: 150, gainDb: 6, slope: 0.9, sampleRate: sampleRate),
        "the shelf spec and the direct design agree to the last bit")

let flatSpecChain = AudioDSPFilterChain(
    preampDb: 0,
    filters: AudioDSPBands.frequencies.map {
        AudioDSPFilterSpec(kind: .peaking, frequency: $0, gainDb: 0, q: AudioDSPBands.q)
    }
)
require(flatSpecChain.coefficients(sampleRate: sampleRate).allSatisfy(\.isBypass),
        "0 dB filters on every band design bypass coefficients")

// MARK: - 左右平衡

let centredBalance = AudioDSPBalance.gains(balance: 0)
require(centredBalance.left == 1 && centredBalance.right == 1,
        "centre is unity on both channels")

let hardLeft = AudioDSPBalance.gains(balance: -1)
require(hardLeft.left == 1 && hardLeft.right == 0, "hard left mutes the right channel")

let hardRight = AudioDSPBalance.gains(balance: 1)
require(hardRight.left == 0 && hardRight.right == 1, "hard right mutes the left channel")

let quarterLeft = AudioDSPBalance.gains(balance: -0.25)
require(quarterLeft.left == 1 && abs(quarterLeft.right - 0.75) < 1e-12,
        "a quarter left keeps the left at unity and pulls the right to 0.75")

require(AudioDSPBalance.gains(balance: -5) == AudioDSPBalance.gains(balance: -1),
        "an out-of-range balance clamps to the extreme")
require(AudioDSPBalance.gains(balance: .nan) == AudioDSPBalance.gains(balance: 0),
        "a non-finite balance falls back to centre")

// MARK: - 结果

if failures > 0 {
    print("AudioDSP tests: \(failures) failure(s)")
    exit(1)
}
print("AudioDSP tests: all passed")
