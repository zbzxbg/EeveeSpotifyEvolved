// CADisplayLink 时钟：把播放进度喂给叠加视图 / Apple Music 渲染层。
import Orion
import UIKit
import ObjectiveC
import SwiftUI

// MARK: - 播放时钟

final class WordByWordPlaybackClock {
    static let shared = WordByWordPlaybackClock()

    private var displayLink: CADisplayLink?
    private(set) var currentMs: Double = 0
    var onChange: ((Double) -> Void)?
    var onChangeIsVisible: (() -> Bool)?
    var tickHandlerIsVisible: (() -> Bool)?

    private init() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(suspend),
            name: UIApplication.willResignActiveNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(suspend),
            name: UIApplication.didEnterBackgroundNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(resume),
            name: UIApplication.didBecomeActiveNotification, object: nil
        )
    }

    func start() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.isPaused = UIApplication.shared.applicationState != .active
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func suspend() {
        displayLink?.isPaused = true
    }

    @objc private func resume() {
        guard let displayLink else { return }
        displayLink.isPaused = false
        tick()
    }

    // Reject only demonstrably hidden/clipped views; partial visibility still needs full-rate rendering.
    static func canRender(_ view: UIView?) -> Bool {
        guard let view, let window = view.window else { return false }
        var visible = view.convert(view.bounds, to: window).intersection(window.bounds)
        var ancestor: UIView? = view
        while let node = ancestor {
            guard !node.isHidden, node.alpha > 0 else { return false }
            if node.clipsToBounds {
                visible = visible.intersection(node.convert(node.bounds, to: window))
            }
            ancestor = node.superview
        }
        return !visible.isNull && !visible.isEmpty
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        onChangeIsVisible = nil
        tickHandlerIsVisible = nil
    }

    /// 供 Apple Music 渲染层使用的每帧回调。
    /// 与 `onChange` 互斥：挂载时只会设置其中一个。
    var tickHandler: ((Double) -> Void)?

    @objc private func tick() {
        guard UIApplication.shared.applicationState == .active else { return }
        // Keep checking visibility each frame so scrolling back needs no new lifecycle hook.
        // Visible paused lyrics keep sampling: seeks and playback projection timeouts still need ticks.
        let deliverOnChange = onChange != nil && onChangeIsVisible?() != false
        let deliverTickHandler = tickHandler != nil && tickHandlerIsVisible?() != false
        guard deliverOnChange || deliverTickHandler else { return }
        let ms: Double
        if let seconds = WordByWordPositionResolver.shared.currentPositionSeconds() {
            ms = seconds * 1000
        } else {
            ms = currentMs
        }
        currentMs = ms
        if deliverOnChange { onChange?(ms) }
        if deliverTickHandler { tickHandler?(ms) }
    }
}
