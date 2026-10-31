// 安全多策略定位播放进度（运行时探测，responds / ivar 检查后再读，绝不裸调）+ 点行跳转。
import Orion
import UIKit
import ObjectiveC
import SwiftUI

// MARK: - 位置解析

@objc protocol WordByWordPositionDoubleGetter { func playbackPosition() -> Double }
@objc protocol WordByWordCurrentPlaybackTimeDoubleGetter { func currentPlaybackTime() -> Double }
@objc protocol WordByWordCurrentTrackTimeSecsGetter { func currentTrackTimeSecs() -> Int64 }
@objc protocol WordByWordPlayerPositionGetter { func position() -> Double }
@objc protocol WordByWordSeekProtocol { func seekTo(_ seconds: Double) }

final class WordByWordPositionResolver {
    static let shared = WordByWordPositionResolver()

    private var getter: (() -> Double)?
    private(set) var sourceLabel: String = "unresolved"
    private var sampleCount = 0
    private var didLogUnresolved = false

    /// 逐策略探测：先试方法（responds 检查后 Dynamic.convert 调用），再试 ivar（class_getInstanceVariable 检查后读取）。
    /// 任一环节检查不通过就跳过，保证永不因猜错签名崩溃。
    func resolve() {
        // 首选：statefulPlayer.position —— 已由 runtime dump 确认（d16@0:8 = double 无参，秒）
        if let p = statefulPlayer as? NSObject, p.responds(to: Selector("position")) {
            let g = Dynamic.convert(p, to: WordByWordPlayerPositionGetter.self)
            getter = { g.position() }
            sourceLabel = "statefulPlayer.position() -> Double"
            writeDebugLog("[WordByWord] position source: \(sourceLabel)")
            return
        }

        var candidates: [(String, NSObject)] = []
        if let p = statefulPlayer as? NSObject { candidates.append(("statefulPlayer", p)) }
        if let vc = nowPlayingScrollViewController as? NSObject {
            candidates.append(("scrollVC", vc))
            let vm = Ivars<NSObject>(vc).scrollViewModel
            candidates.append(("scrollViewModel", vm))
        }
        if let npv = npvScrollViewController as? NSObject { candidates.append(("npvVC", npv)) }

        for (label, obj) in candidates {
            if obj.responds(to: Selector("playbackPosition")) {
                let g = Dynamic.convert(obj, to: WordByWordPositionDoubleGetter.self)
                getter = { g.playbackPosition() }
                sourceLabel = "\(label).playbackPosition() -> Double"
                writeDebugLog("[WordByWord] position source: \(sourceLabel)")
                return
            }
        }
        for (label, obj) in candidates {
            if obj.responds(to: Selector("currentPlaybackTime")) {
                let g = Dynamic.convert(obj, to: WordByWordCurrentPlaybackTimeDoubleGetter.self)
                getter = { g.currentPlaybackTime() }
                sourceLabel = "\(label).currentPlaybackTime() -> Double"
                writeDebugLog("[WordByWord] position source: \(sourceLabel)")
                return
            }
        }
        for (label, obj) in candidates {
            if let value = ivarInt64(obj, "currentTrackTimeSecs") {
                getter = { Double(value) }
                sourceLabel = "\(label).currentTrackTimeSecs -> Int64(秒)"
                writeDebugLog("[WordByWord] position source: \(sourceLabel)")
                return
            }
            if let value = ivarDouble(obj, "playbackPosition") {
                getter = { value }
                sourceLabel = "\(label).playbackPosition ivar -> Double"
                writeDebugLog("[WordByWord] position source: \(sourceLabel)")
                return
            }
        }
        if !didLogUnresolved {
            didLogUnresolved = true
            writeDebugLog("[WordByWord] no position source resolved — will retry on next tick")
        }
    }

    /// 返回秒（双精度）。源不可用返回 nil。
    /// 启动时候选对象（statefulPlayer/scrollViewModel 等）可能还没就绪，
    /// 未解析成功时每次调用都重试一次，直到命中某个策略。
    func currentPositionSeconds() -> Double? {
        if getter == nil { resolve() }
        guard let getter else { return nil }
        let raw = getter()
        if sampleCount < 5 {
            sampleCount += 1
            writeDebugLog("[WordByWord] pos sample \(sampleCount): \(raw)")
        }
        return raw
    }

    private func ivarInt64(_ obj: NSObject, _ name: String) -> Int64? {
        for ivarName in [name, "_\(name)"] {
            guard let ivar = class_getInstanceVariable(type(of: obj), ivarName) else { continue }
            guard let rawPointer = object_getIvar(obj, ivar) as AnyObject? else { return nil }
            return unsafeBitCast(rawPointer, to: Int64.self)
        }
        return nil
    }

    private func ivarDouble(_ obj: NSObject, _ name: String) -> Double? {
        for ivarName in [name, "_\(name)"] {
            guard let ivar = class_getInstanceVariable(type(of: obj), ivarName) else { continue }
            guard let rawPointer = object_getIvar(obj, ivar) as AnyObject? else { return nil }
            return unsafeBitCast(rawPointer, to: Double.self)
        }
        return nil
    }
}

// MARK: - 点行跳转

final class WordByWordSeeker {
    static func seek(toMs ms: Int) {
        guard let player = statefulPlayer as? NSObject, player.responds(to: Selector("seekTo:")) else {
            writeDebugLog("[WordByWord] seekTo: unavailable on statefulPlayer")
            return
        }
        let g = Dynamic.convert(player, to: WordByWordSeekProtocol.self)
        g.seekTo(Double(ms) / 1000)
        writeDebugLog("[WordByWord] seek to \(ms)ms")
    }
}
