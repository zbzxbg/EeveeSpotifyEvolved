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

// MARK: - 结果

if failures > 0 {
    print("AudioDSP tests: \(failures) failure(s)")
    exit(1)
}
print("AudioDSP tests: all passed")
