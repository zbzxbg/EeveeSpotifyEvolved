import Foundation
import SwiftUI

/// 「按歌排除源」：让**这一首歌**不用某几个歌词源。
///
/// 为什么不做在歌词页上：那一条路要往 Spotify 的播放页里加控件（碰它的视图树），
/// 而设置页本来就会读当前曲目（「歌词偏移」那一页也是这么取的）—— 同一份数据、
/// 零视图风险。
///
/// 只对**自动优选**生效：用户点名选了某个源时，点名优先（那是显式选择，
/// 不是"随便挑一个"）。页脚把这一点写明，免得被当成"按了没反应"。
struct EeveeLyricsSongExclusionsView: View {

    @State private var currentTrackId = ""
    @State private var currentTitle = ""
    @State private var currentArtist = ""
    @State private var withheld: Set<LyricsSource> = []
    @State private var entries: [LyricsSongSourceExclusions.Entry] = []

    var body: some View {
        List {
            currentSongSection()
            savedSongsSection()

            NonIPadSpacerView()
        }
        .listStyle(InsetGroupedListStyle())
        .navigationTitle("lyrics_song_exclusions_title".localized)
        .onAppear(perform: reload)
    }

    // MARK: - 当前播放

    @ViewBuilder private func currentSongSection() -> some View {
        Section {
            if currentTrackId.isEmpty {
                Text("lyrics_song_exclusions_no_current".localized)
                    .foregroundColor(.secondary)
            } else {
                Text(currentSongDisplayName)
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                // 顺序跟用户在「歌词源顺序」里排的一致：这一列就是自动优选会问的那条链。
                ForEach(LyricsSourceOrder.current, id: \.self) { source in
                    Toggle(source.description, isOn: binding(for: source))
                }
            }
        } header: {
            Text("lyrics_song_exclusions_current_header".localized)
        } footer: {
            Text("lyrics_song_exclusions_description".localized)
        }
    }

    // MARK: - 已排除的歌曲

    @ViewBuilder private func savedSongsSection() -> some View {
        Section {
            if entries.isEmpty {
                Text("lyrics_song_exclusions_empty".localized)
                    .foregroundColor(.secondary)
            } else {
                ForEach(entries, id: \.trackId) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(displayName(for: entry))
                            .font(.subheadline)
                            .lineLimit(1)
                        Text(entry.sources.map(\.description).joined(separator: " · "))
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
                .onDelete(perform: deleteEntries)

                Button("lyrics_song_exclusions_clear_all".localized) {
                    LyricsSongSourceExclusions.clearAll()
                    reload()
                }
                .foregroundColor(.red)
            }
        } header: {
            Text("lyrics_song_exclusions_saved_header".localized)
        }
    }

    // MARK: - 数据

    private var currentSongDisplayName: String {
        [currentTitle, currentArtist]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " — ")
    }

    private func displayName(for entry: LyricsSongSourceExclusions.Entry) -> String {
        let stored = (entry.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard stored.isEmpty else { return stored }
        return "lyrics_offset_unknown_song".localized
            + " · "
            + LyricsSongSourceExclusions.shortened(entry.trackId)
    }

    /// 勾上 = 这首歌**不用**这个源。写入是立即的；当前这份歌词要等下一次取词
    /// （切歌、或重新打开歌词页）才会换成新的源。
    private func binding(for source: LyricsSource) -> Binding<Bool> {
        Binding(
            get: { withheld.contains(source) },
            set: { isOn in
                if isOn {
                    withheld.insert(source)
                } else {
                    withheld.remove(source)
                }
                LyricsSongSourceExclusions.setSources(
                    withheld,
                    forTrackId: currentTrackId,
                    title: currentSongDisplayName
                )
                entries = LyricsSongSourceExclusions.entries
                writeDebugLog(
                    "[Lyrics] per-song exclusions for \(LyricsSongSourceExclusions.shortened(currentTrackId)): "
                        + (withheld.isEmpty
                            ? "none"
                            : withheld.map(\.offsetStorageKey).sorted().joined(separator: ", "))
                )
            }
        )
    }

    private func deleteEntries(at offsets: IndexSet) {
        for index in offsets {
            guard index < entries.count else { continue }
            LyricsSongSourceExclusions.clear(trackId: entries[index].trackId)
        }
        reload()
    }

    private func reload() {
        let track = statefulPlayer?.currentTrack() ?? nowPlayingScrollViewController?.loadedTrack
        currentTrackId = track?.trackIdentifier ?? ""
        currentTitle = track?.string(ifResponding: "trackTitle") ?? ""
        currentArtist = track?.string(ifResponding: "artistName")
            ?? track?.string(ifResponding: "artistTitle")
            ?? ""

        withheld = LyricsSongSourceExclusions.sources(forTrackId: currentTrackId)
        entries = LyricsSongSourceExclusions.entries
    }
}
