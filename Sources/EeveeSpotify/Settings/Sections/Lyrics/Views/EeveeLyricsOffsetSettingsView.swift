import Foundation
import SwiftUI

/// 「歌词偏移」独立页从歌词设置页里拆出来；从"只做网易云"改成所有源）。
///
/// 为什么单独一页（设置页里面放个可点击进去的页面吧，和那些功能一样——
/// 这个功能会随听歌不断长出新的条目，内嵌在歌词页里越拖越长；拆成子页之后
/// 入口和「歌词 / 听歌页 / 补丁」那些在同一组，页内只留这一件事。
///
/// 「把歌词偏移这个东西做成对全部歌词源都生效，但记录的时候，
/// 要连带把歌词源记录，genius不用歌词偏移这个东西」。于是：
/// · 每一条记录都是「源 + 曲目」，行里把源名画出来（同一首歌换源就是另一条）；
/// · Genius 进来时只显示一句说明，不给 ± 按钮（它没有可信时间轴，挪了没意义）。
///
/// 只有**单条偏移**去掉「默认偏移」）：默认值是"所有歌词一起挪"，
/// 实际没什么用，还会让"这首歌到底存了多少"更难看清。
struct EeveeLyricsOffsetSettingsView: View {

    @State private var currentSongTrackId = ""
    @State private var currentSongOffsetMs = 0
    @State private var currentSongHasOverride = false
    /// 当前播放这首的显示名（只给"当前歌曲"那一行做副标题，不改任何存储）。
    @State private var currentSongTitle = ""
    @State private var currentSongArtist = ""
    /// 当前这份歌词是哪个源给的（nil = 没有我们的歌词）。
    @State private var currentSongSource: LyricsSource?
    /// 已保存的偏移（**不含当前播放这条**；它在上面单独一行，避免同一首出现两次）。
    @State private var savedEntries: [SavedEntry] = []
    /// 搜索词（歌名 / 歌手 / 曲目 id / 源名）。
    @State private var query = ""

    /// 保存的条目多到一屏看不完时才显示搜索框（太少时它只是噪音）；
    /// 已经在搜索时**保持显示**，否则清空后框会突然消失。
    private let searchAppearsAt = 6

    private var showsSearchField: Bool {
        !savedEntries.isEmpty && (savedEntries.count >= searchAppearsAt || !query.isEmpty)
    }

    private struct SavedEntry: Identifiable {
        let trackId: String
        let source: LyricsSource
        let title: String
        let offsetMs: Int
        var id: String { LyricsTimingOffset.storageKey(trackId: trackId, source: source) }
    }

    var body: some View {
        List {
            currentSongSection()
            savedEntriesSection()
            NonIPadSpacerView()
        }
        // inset-grouped（胶囊卡片）—— 与其它自定义页保持一致。
        .listStyle(InsetGroupedListStyle())
        .onAppear { refreshCurrentSongOffset() }
    }

    // MARK: - 当前歌曲

    @ViewBuilder private func currentSongSection() -> some View {
        Section {
            if currentSongTrackId.isEmpty {
                Text("lyrics_offset_no_track".localized)
                    .font(.footnote)
                    .foregroundColor(.secondary)
            } else if !currentSongSupportsOffset {
                // 能走到这里只可能是 Genius（我们自己的 dto 一定有源）。
                Text("lyrics_offset_genius_excluded".localized)
                    .font(.footnote)
                    .foregroundColor(.secondary)
            } else {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("lyrics_offset_current_song".localized)
                        HStack(spacing: 6) {
                            sourceBadge(currentSongSource)
                            if !currentSongDisplayName.isEmpty {
                                Text(currentSongDisplayName)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    Spacer()
                    Text(formattedOffset(currentSongOffsetMs))
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
                HStack(spacing: 12) {
                    Button("-0.1s") { adjustCurrentSong(by: -100) }
                    Button("+0.1s") { adjustCurrentSong(by: 100) }
                    Spacer()
                    if currentSongHasOverride {
                        Button {
                            clearCurrentSongOverride()
                        } label: {
                            Image(systemName: "trash")
                        }
                        .foregroundColor(.red)
                        .accessibilityLabel(Text("lyrics_offset_delete_entry".localized))
                    } else {
                        Button("lyrics_offset_save_song".localized) { saveCurrentSong() }
                            .font(.caption)
                        Text("lyrics_offset_autosave_hint".localized)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .buttonStyle(.borderless)
            }
        } footer: {
            Text("lyrics_offset_description".localized)
        }
    }

    /// 当前这份歌词能不能调（Genius 不能；没有 dto 也不能）。
    private var currentSongSupportsOffset: Bool {
        guard let source = currentSongSource else { return false }
        return LyricsTimingOffset.supportsOffset(source: source)
    }

    /// 源名小胶囊。没有源就什么都不画（不编造）。
    @ViewBuilder private func sourceBadge(_ source: LyricsSource?) -> some View {
        if let source {
            Text(source.description)
                .font(.caption2)
                .foregroundColor(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.15))
                .clipShape(Capsule())
        }
    }

    // MARK: - 已保存
    //
    // 搜索过滤后的那一列。空搜索词 = 全部。
    private var visibleSavedEntries: [SavedEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return savedEntries }
        let needle = searchKey(trimmed)
        guard !needle.isEmpty else { return savedEntries }
        let rawNeedle = trimmed.lowercased()
        return savedEntries.filter { entry in
            searchKey(entry.title).contains(needle)
                || searchKey(entry.source.description).contains(needle)
                || entry.trackId.lowercased().contains(rawNeedle)
        }
    }

    /// 搜索归一化：**大小写 / 全角半角 / 变音符号都不敏感**，并且把平假名折成片假名
    /// （「ふり」与「フリ」互搜得到 —— 日文标题两种写法都常见）。
    private func searchKey(_ text: String) -> String {
        let folded = text.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: nil
        )
        var result = ""
        for scalar in folded.unicodeScalars {
            if (0x3041...0x3096).contains(scalar.value),
               let katakana = Unicode.Scalar(scalar.value + 0x60) {
                result.unicodeScalars.append(katakana)
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    @ViewBuilder private func savedEntriesSection() -> some View {
        if showsSearchField {
            Section {
                TextField("lyrics_offset_search".localized, text: $query)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
            }
        }

        // ⚠️ 这里必须用 `Section(header:footer:content:)`（header/footer 是 **View**、content 是
        // 尾随闭包）—— `Section(header: X) { … } footer: { … }` 这种写法在本仓库的
        // SwiftUI 版本里没有对应重载，会被解析成 `init(header:footer:content:)` 而编译失败
        // 实测：「incorrect argument label … have 'header:_:footer:'」）。
        Section(
            header: Text("lyrics_offset_saved".localized),
            footer: Text("lyrics_offset_saved_count".localizeWithFormat(savedEntries.count))
        ) {
            if savedEntries.isEmpty {
                Text(currentSongHasOverride
                     ? "lyrics_offset_saved_only_current".localized
                     : "lyrics_offset_saved_empty".localized)
                    .font(.footnote)
                    .foregroundColor(.secondary)
            } else if visibleSavedEntries.isEmpty {
                Text("lyrics_offset_no_matches".localized)
                    .font(.footnote)
                    .foregroundColor(.secondary)
            } else {
                ForEach(visibleSavedEntries) { entry in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.title)
                                .font(.subheadline)
                                .lineLimit(1)
                            HStack(spacing: 6) {
                                sourceBadge(entry.source)
                                Text(formattedOffset(entry.offsetMs))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .monospacedDigit()
                            }
                        }
                        Spacer()
                        Button("-0.1s") { adjustSavedEntry(entry, by: -100) }
                        Button("+0.1s") { adjustSavedEntry(entry, by: 100) }
                        Button {
                            LyricsTimingOffset.clearOverride(
                                forTrackId: entry.trackId,
                                source: entry.source
                            )
                            reapplyLyricsTimingOffset()
                            refreshCurrentSongOffset()
                        } label: {
                            Image(systemName: "trash")
                        }
                        .foregroundColor(.red)
                        .accessibilityLabel(Text("lyrics_offset_delete_entry".localized))
                    }
                    .buttonStyle(.borderless)
                }
                .onDelete(perform: deleteVisibleEntries)
            }

            // 只要**还存着任何一条**就给这颗键（含上面「当前歌曲」那一条 ——
            // 它不在 `savedEntries` 里，但同样属于"全部"）。
            if !LyricsTimingOffset.entries.isEmpty {
                Button("lyrics_offset_clear_all".localized) {
                    LyricsTimingOffset.clearAllOverrides()
                    reapplyLyricsTimingOffset()
                    refreshCurrentSongOffset()
                }
                .foregroundColor(.red)
            }
        }
    }

    // MARK: - 数据

    private func formattedOffset(_ milliseconds: Int) -> String {
        String(format: "%+.2fs", Double(milliseconds) / 1000)
    }

    /// `"歌名 — 歌手"`（缺一项就只留另一项；两项都空 = 空串）。
    private var currentSongDisplayName: String {
        [currentSongTitle, currentSongArtist]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " — ")
    }

    /// 「当前歌曲」那一行：取**当前这份歌词**的曲目 id 与源。
    ///
    /// 以前只在"当前歌词来自网易云"时才取得到 track id；现在任何源都取，
    /// Genius 也取（但要靠 `currentSongSupportsOffset` 把 ± 按钮挡住）。
    private func refreshCurrentSongOffset() {
        let track = statefulPlayer?.currentTrack() ?? nowPlayingScrollViewController?.loadedTrack
        currentSongTitle = track?.string(ifResponding: "trackTitle") ?? ""
        currentSongArtist = track?.string(ifResponding: "artistName")
            ?? track?.string(ifResponding: "artistTitle")
            ?? ""

        let source = currentLyricsSource
        let trackId = currentLyricsDtoTrackId
        currentSongSource = source
        currentSongTrackId = trackId

        if let source, !trackId.isEmpty, LyricsTimingOffset.supportsOffset(source: source) {
            currentSongHasOverride = LyricsTimingOffset.hasOverride(
                forTrackId: trackId,
                source: source
            )
            currentSongOffsetMs = LyricsTimingOffset.offsetMs(forTrackId: trackId, source: source)
        } else {
            currentSongHasOverride = false
            currentSongOffsetMs = 0
        }

        let currentKey: String
        if !trackId.isEmpty, let source {
            currentKey = LyricsTimingOffset.storageKey(trackId: trackId, source: source)
        } else {
            currentKey = ""
        }
        refreshSavedEntries(excluding: currentKey)
    }

    /// 已保存那一列：**不含 `currentKey` 那一条**（它在上面单独一行，避免同一条出现两次）。
    ///
    /// 显式传 key 而不是读 `@State`：这一列是 `refreshCurrentSongOffset` 里刚算完
    /// 当前那条之后紧接着刷的，读 state 虽然也能拿到新值，但"传进来"这件事本身
    /// 就把"排除哪一条"写死在调用点上了，不容易被后来的改动弄错。
    private func refreshSavedEntries(excluding currentKey: String) {
        let unknownName = "lyrics_offset_unknown_song".localized

        savedEntries = LyricsTimingOffset.entries.compactMap { entry -> SavedEntry? in
            if !currentKey.isEmpty, entry.key == currentKey { return nil }
            let stored = LyricsTimingOffset
                .title(forTrackId: entry.trackId, source: entry.source)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let name = stored.isEmpty ? unknownName + " · " + shortTrackId(entry.trackId) : stored
            return SavedEntry(
                trackId: entry.trackId,
                source: entry.source,
                title: name,
                offsetMs: entry.offsetMs
            )
        }
        .sorted { lhs, rhs in
            let byTitle = lhs.title.localizedStandardCompare(rhs.title)
            if byTitle != .orderedSame { return byTitle == .orderedAscending }
            return lhs.source.description.localizedStandardCompare(rhs.source.description)
                == .orderedAscending
        }
    }

    /// 老数据没有存过歌名：只显示 track id 的后 6 位，不编造。
    private func shortTrackId(_ trackId: String) -> String {
        let trimmed = trackId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 8 else { return trimmed }
        return String(trimmed.suffix(6))
    }

    private func adjustCurrentSong(by deltaMs: Int) {
        guard let source = currentSongSource, !currentSongTrackId.isEmpty else { return }
        guard LyricsTimingOffset.supportsOffset(source: source) else { return }
        let base = LyricsTimingOffset.offsetMs(forTrackId: currentSongTrackId, source: source)
        LyricsTimingOffset.setOffset(
            base + deltaMs,
            forTrackId: currentSongTrackId,
            source: source,
            trackTitle: currentSongDisplayName
        )
        reapplyLyricsTimingOffset()
        refreshCurrentSongOffset()
    }

    /// 显式的「保存」：为当前这条建一条覆盖（值 = 当前生效值）。
    ///
    /// 有它是因为 ±0.1s 虽然**当场就存**，但用户看不到"保存"这个动作，以为没存上。
    /// 存完 `currentSongHasOverride` 变真 ⇒ 这颗键换成删除键，列表里也多一行。
    private func saveCurrentSong() {
        guard let source = currentSongSource, !currentSongTrackId.isEmpty else { return }
        guard LyricsTimingOffset.supportsOffset(source: source) else { return }
        let value = LyricsTimingOffset.offsetMs(forTrackId: currentSongTrackId, source: source)
        LyricsTimingOffset.setOffset(
            value,
            forTrackId: currentSongTrackId,
            source: source,
            trackTitle: currentSongDisplayName
        )
        reapplyLyricsTimingOffset()
        refreshCurrentSongOffset()
    }

    private func clearCurrentSongOverride() {
        guard let source = currentSongSource, !currentSongTrackId.isEmpty else { return }
        LyricsTimingOffset.clearOverride(forTrackId: currentSongTrackId, source: source)
        reapplyLyricsTimingOffset()
        refreshCurrentSongOffset()
    }

    /// 已保存列表里的某一条：改的**不是当前播放这条**，不传歌名（保持已存的名字）。
    private func adjustSavedEntry(_ entry: SavedEntry, by deltaMs: Int) {
        let base = LyricsTimingOffset.offsetMs(forTrackId: entry.trackId, source: entry.source)
        LyricsTimingOffset.setOffset(
            base + deltaMs,
            forTrackId: entry.trackId,
            source: entry.source
        )
        reapplyLyricsTimingOffset()
        refreshCurrentSongOffset()
    }

    /// 左滑删除：索引是**过滤后**那一列的位置，所以必须用 `visibleSavedEntries` 取 id。
    private func deleteVisibleEntries(at offsets: IndexSet) {
        for index in offsets where visibleSavedEntries.indices.contains(index) {
            let entry = visibleSavedEntries[index]
            LyricsTimingOffset.clearOverride(forTrackId: entry.trackId, source: entry.source)
        }
        reapplyLyricsTimingOffset()
        refreshCurrentSongOffset()
    }
}
