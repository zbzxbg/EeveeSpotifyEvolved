// The Live Activity's face: a lock screen card plus the Dynamic Island's compact, minimal and
// expanded presentations for whatever track Spotify is playing.
//
// This file belongs to the WidgetKit extension process only (EeveeLiveActivity.appex). It shares
// NowPlayingActivityAttributes with the app: Scripts/build-live-activity-appex.sh compiles both
// source files into one module, so the type is in scope here without an `import`.
//
// The progress never comes from the app. ContentState carries only startedAt + duration and the
// timer views below let the system advance the numbers locally, so the app updates once per track
// change and once per play/pause instead of driving a timer through ActivityKit.
//
// Display only: no artwork image, no buttons, no AppIntent. That also means no App Intents metadata
// has to be merged into the host app, which is why the extension builds with plain swiftc.
import ActivityKit
import Foundation
import SwiftUI
import WidgetKit

private typealias State = NowPlayingActivityAttributes.ContentState

private let accent = Color(red: 0.12, green: 0.84, blue: 0.38)
private let idle = Color.white.opacity(0.16)

// Every view needs the track's end; nil means "no usable progress" - an unknown duration, or one
// that has already run out.
private func trackEnd(_ state: State) -> Date? {
    guard state.duration > 1 else { return nil }
    let end = state.startedAt.addingTimeInterval(state.duration)
    return end > Date() ? end : nil
}

private func displayTitle(_ state: State) -> String {
    state.title.isEmpty ? "Now playing" : state.title
}

private func displayArtist(_ state: State) -> String {
    state.artist.isEmpty ? " " : state.artist
}

@main
struct EeveeLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        NowPlayingLiveActivity()
    }
}

struct NowPlayingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NowPlayingActivityAttributes.self) { context in
            LockScreenView(state: context.state)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .foregroundStyle(.white)
                .activityBackgroundTint(Color.black.opacity(0.6))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(URL(string: "spotify:"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 8) {
                        StateGlyph(state: context.state)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(displayTitle(context.state))
                                .font(.headline)
                                .lineLimit(1)
                            Text(displayArtist(context.state))
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.6))
                                .lineLimit(1)
                        }
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if let end = trackEnd(context.state) {
                        Text(timerInterval: context.state.startedAt...end, countsDown: true)
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(accent)
                            .frame(maxWidth: 56)
                    } else {
                        Image(systemName: context.state.isPlaying ? "waveform" : "pause.fill")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ProgressLine(state: context.state)
                        .padding(.horizontal, 4)
                        .padding(.top, 2)
                }
            } compactLeading: {
                Image(systemName: "music.note")
                    .foregroundStyle(accent)
            } compactTrailing: {
                if context.state.isPlaying, let end = trackEnd(context.state) {
                    Text(timerInterval: context.state.startedAt...end, countsDown: true)
                        .monospacedDigit()
                        .foregroundStyle(accent)
                        .frame(maxWidth: 44)
                } else {
                    Image(systemName: context.state.isPlaying ? "waveform" : "pause.fill")
                        .foregroundStyle(accent)
                }
            } minimal: {
                Image(systemName: "music.note")
                    .foregroundStyle(accent)
            }
            .widgetURL(URL(string: "spotify:"))
        }
    }
}

private struct LockScreenView: View {
    let state: State

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                StateGlyph(state: state)
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayTitle(state))
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    Text(displayArtist(state))
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            ProgressLine(state: state)
        }
    }
}

// v1 draws no cover art: the payload is capped, and a rendered image would have to travel through a
// shared container. The glyph only carries play/pause, so the card still reads at a glance.
private struct StateGlyph: View {
    let state: State

    var body: some View {
        Image(systemName: state.isPlaying ? "waveform" : "pause.fill")
            .font(.title3.weight(.semibold))
            .foregroundStyle(accent)
            .frame(width: 30, height: 30)
            .background(Circle().fill(idle))
    }
}

// Elapsed on the left, remaining on the right, a bar in between. Both numbers are timer views, so
// the system advances them while the widget is not rendering; the bar is filled at render time and
// only has to look right next to them.
private struct ProgressLine: View {
    let state: State

    var body: some View {
        if let end = trackEnd(state) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(timerInterval: state.startedAt...end, countsDown: false)
                        .monospacedDigit()
                    Spacer(minLength: 8)
                    Text(timerInterval: state.startedAt...end, countsDown: true)
                        .monospacedDigit()
                }
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.65))
                TrackBar(fraction: fraction())
            }
        } else {
            Text(state.isPlaying ? "Playing" : "Paused")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.65))
        }
    }

    private func fraction() -> Double {
        guard state.duration > 0 else { return 0 }
        let elapsed = Date().timeIntervalSince(state.startedAt)
        return min(max(elapsed / state.duration, 0), 1)
    }
}

private struct TrackBar: View {
    let fraction: Double

    var body: some View {
        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
            .fill(idle)
            .frame(height: 3)
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(accent)
                    .scaleEffect(x: CGFloat(fraction), y: 1, anchor: .leading)
            }
    }
}
