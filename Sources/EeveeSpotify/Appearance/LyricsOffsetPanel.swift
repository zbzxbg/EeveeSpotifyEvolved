import SwiftUI

/// 听歌页 `⋯` 菜单里那一行「歌词偏移」点开的**紧凑面板**。
///
/// 为什么要有它：完整那一页（`EeveeLyricsOffsetSettingsView`，397 行）是"管理所有已存条目"的地方，
/// 而用户真正会动的场景只有一个 —— **正在听的这一首差半拍**。那种时候翻设置页太远，
/// 所以把它挪到播放器里、紧挨着 `⋯`。
///
/// 三条约束（都是照仓库既有纪律来的）：
///   · **改了立刻生效**：每次调整都写 `LyricsTimingOffset` 再调 `reapplyLyricsTimingOffset()`，
///     不重新取词、不重建歌词页（那条函数只平移时间轴并自增版本号）；
///   · **只动当前这一首**：键是「曲目 + 源」，与设置页那一套完全同一份数据，两边看到的是同一个值；
///   · **Genius 不参与**：`LyricsTimingOffset.supportsOffset` 已经挡掉，这里只在入口处问一句，
///     不支持就整行不出现（见 `LyricsOffsetMenuRow`）。
struct LyricsOffsetPanel: View {

    private let trackId: String
    private let source: LyricsSource
    private let song: String

    @State private var offsetMs: Int
    @Environment(\.dismiss) private var dismiss

    init(trackId: String, source: LyricsSource, song: String) {
        self.trackId = trackId
        self.source = source
        self.song = song
        _offsetMs = State(initialValue: LyricsTimingOffset.offsetMs(forTrackId: trackId, source: source))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 14) {
                        Text(value)
                            .font(.system(size: 34, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText())

                        HStack(spacing: 24) {
                            stepButton("−25", by: -25)
                            stepButton("+25", by: 25)
                        }

                        // 细调：滑杆只给"大概位置"，精确到 25ms 靠上面两颗。
                        Slider(
                            value: Binding(
                                get: { Double(offsetMs) },
                                set: { apply(Int($0.rounded())) }
                            ),
                            in: -1000...1000,
                            step: 25
                        )
                    }
                    .padding(.vertical, 6)
                } header: {
                    Text(song)
                } footer: {
                    Text("lyrics_offset_autosave_hint".localized)
                }

                Section {
                    Button(role: .destructive) {
                        LyricsTimingOffset.clearOverride(forTrackId: trackId, source: source)
                        offsetMs = 0
                        reapplyLyricsTimingOffset()
                        writeDebugLog("[LyricsOffset] cleared from the player — \(trackId) / \(source.description)")
                    } label: {
                        Label("lyrics_offset_reset".localized, systemImage: "arrow.counterclockwise")
                    }
                }
            }
            .navigationTitle("lyrics_offset_title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("lyrics_offset_done".localized) { dismiss() }
                }
            }
        }
    }

    /// `+125 ms` / `0 ms` / `−75 ms` —— 正负号用真正的减号（`−`），不用连字符。
    private var value: String {
        offsetMs == 0 ? "0 ms" : "\(offsetMs > 0 ? "+" : "−")\(abs(offsetMs)) ms"
    }

    private func stepButton(_ title: String, by delta: Int) -> some View {
        Button {
            apply(offsetMs + delta)
        } label: {
            Text(title)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .frame(minWidth: 84, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
    }

    /// 写盘 + 立刻重放。`trackTitle` 传"歌名 — 歌手"，这样设置页那张"已保存"列表里认得出是谁。
    private func apply(_ value: Int) {
        let clamped = max(-1000, min(1000, value))
        guard clamped != offsetMs else { return }
        offsetMs = clamped
        LyricsTimingOffset.setOffset(clamped, forTrackId: trackId, source: source, trackTitle: song)
        reapplyLyricsTimingOffset()
    }
}

extension LyricsOffsetPanel {

    /// 包成 `UIHostingController` 再 present。宿主 VC 从窗口根往下取最上面那个 ——
    /// `⋯` 菜单自己正在收起，不能从它身上 present。
    ///
    /// ⚠️ 不加 `@MainActor`：调用点在 `DispatchQueue.main.asyncAfter` 里，
    /// 而本仓库是 Swift 5 的并发检查档位，加了反而要额外跳一次隔离。
    static func present(trackId: String, source: LyricsSource, song: String) {
        guard let window = EntityPageAppearance.frontWindow(),
              var host = window.rootViewController else { return }
        while let presented = host.presentedViewController, !presented.isBeingDismissed {
            host = presented
        }
        let panel = LyricsOffsetPanel(trackId: trackId, source: source, song: song)
        let controller = UIHostingController(rootView: panel)
        controller.view.backgroundColor = .clear
        if let sheet = controller.sheetPresentationController {
            sheet.detents = [.medium()]
            sheet.prefersGrabberVisible = true
        }
        host.present(controller, animated: true)
        writeDebugLog(
            "[LyricsOffset] panel opened from the player — \(trackId) / \(source.description)"
        )
    }
}
