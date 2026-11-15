import SwiftUI

/// 「听歌统计」页。
///
/// 数据来自 `ListeningStatsStore`（`Application Support/EeveeSpotify/listening-stats.json`），
/// 聚合在 `ListeningStatsViewModel` 里跑在后台队列上 —— 本文件只负责画。
///
/// 版式与「睡眠定时器」页同一套语言：`List` + `InsetGroupedListStyle()`，说明文字全部放
/// `footer`。唯一会弹东西的地方是「清除统计数据」的 `confirmationDialog`。
struct EeveeListeningStatsSettingsView: View {

    @StateObject private var viewModel = ListeningStatsViewModel()

    @State private var isEnabled = UserDefaults.listeningStatsEnabled
    @State private var period: ListeningStatsPeriod = .week
    @State private var isConfirmingClear = false

    var body: some View {
        List {
            Section(footer: Text("listening_stats_enabled_footer".localized)) {
                Toggle("listening_stats_enabled".localized, isOn: $isEnabled)
                    .onChange(of: isEnabled) { value in
                        // 键是实时读的：拨完就生效，不用重启 Spotify。
                        UserDefaults.listeningStatsEnabled = value
                        ListeningStatsRecorder.shared.settingsDidChange()
                    }
            }

            Section {
                Picker("listening_stats_period".localized, selection: $period) {
                    ForEach(ListeningStatsPeriod.allCases, id: \.self) { value in
                        Text(periodLabel(value)).tag(value)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: period) { value in
                    viewModel.reload(period: value)
                }
            }

            overviewSection

            chartSection

            if viewModel.summary.isEmpty {
                emptySection
            } else {
                topSongsSection
                topArtistsSection
            }

            clearSection
        }
        .listStyle(InsetGroupedListStyle())
        .onAppear {
            // 备份导入 / 别处改过键时，页面显示的值也跟着盘上那份走。
            isEnabled = UserDefaults.listeningStatsEnabled
            viewModel.reload(period: period)
        }
        .confirmationDialog(
            "listening_stats_clear_title".localized,
            isPresented: $isConfirmingClear,
            titleVisibility: .visible
        ) {
            Button("listening_stats_clear_confirm".localized, role: .destructive) {
                // 先丢掉正在攒的那一段（它可能已经排进 store 的写队列），否则清完又会被
                // 下一次 flush 带回来一部分。下一拍会在当前位置重开会话。
                ListeningStatsRecorder.shared.discardCurrentSession()
                viewModel.clear()
            }
            Button("Cancel".localized, role: .cancel) {}
        } message: {
            Text("listening_stats_clear_message".localized)
        }
    }

    // MARK: - 总览

    private var overviewSection: some View {
        Section {
            overviewRow("listening_stats_overview_total_time".localized, durationText(viewModel.summary.totalSeconds))
            overviewRow("listening_stats_overview_plays".localized, playsText(viewModel.summary.totalPlays))
            overviewRow("listening_stats_overview_tracks".localized, "\(viewModel.summary.uniqueTracks)")
            overviewRow("listening_stats_overview_artists".localized, "\(viewModel.summary.uniqueArtists)")
        }
    }

    private func overviewRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer(minLength: 8)
            Text(value)
                .foregroundColor(.secondary)
                .monospacedDigit()
        }
    }

    // MARK: - 近 7 天

    private var chartSection: some View {
        Section(header: Text("listening_stats_last_7_days".localized)) {
            if viewModel.dailyTotals.isEmpty {
                if viewModel.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                } else {
                    Color.clear.frame(height: 1)
                }
            } else {
                ListeningStatsWeekBars(points: viewModel.dailyTotals)
                    .padding(.vertical, 4)
            }
        }
    }

    // MARK: - 榜单

    private var topSongsSection: some View {
        Section(header: Text("listening_stats_top_songs".localized)) {
            ForEach(viewModel.summary.topTracks) { stat in
                songRow(stat)
            }
        }
    }

    private var topArtistsSection: some View {
        Section(header: Text("listening_stats_top_artists".localized)) {
            ForEach(viewModel.summary.topArtists) { stat in
                artistRow(stat)
            }
        }
    }

    private func songRow(_ stat: ListeningStatsTrackStat) -> some View {
        HStack(spacing: 10) {
            rankText(trackRank(stat.trackID))
            artworkView(stat.artworkURL)

            VStack(alignment: .leading, spacing: 2) {
                Text(stat.title.isEmpty ? "—" : stat.title)
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(stat.artist)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 8)

            Text(playsAndTimeText(plays: stat.plays, seconds: stat.seconds))
                .font(.caption)
                .foregroundColor(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private func artistRow(_ stat: ListeningStatsArtistStat) -> some View {
        HStack(spacing: 10) {
            rankText(artistRank(stat.name))

            Text(stat.name)
                .font(.subheadline)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 8)

            Text(playsAndTimeText(plays: stat.plays, seconds: stat.seconds))
                .font(.caption)
                .foregroundColor(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private func rankText(_ rank: Int) -> some View {
        Text("\(rank)")
            .font(.footnote)
            .monospacedDigit()
            .foregroundColor(.secondary)
            .frame(width: 18, alignment: .leading)
    }

    private func trackRank(_ trackID: String) -> Int {
        (viewModel.summary.topTracks.firstIndex { $0.trackID == trackID } ?? 0) + 1
    }

    private func artistRank(_ name: String) -> Int {
        (viewModel.summary.topArtists.firstIndex { $0.name == name } ?? 0) + 1
    }

    @ViewBuilder
    private func artworkView(_ urlString: String?) -> some View {
        if let urlString, !urlString.isEmpty, let url = URL(string: urlString) {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    artworkPlaceholder
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            artworkPlaceholder
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private var artworkPlaceholder: some View {
        ZStack {
            Color.secondary.opacity(0.15)
            Image(systemName: "music.note")
                .font(.system(size: 18))
                .foregroundColor(.secondary)
        }
    }

    // MARK: - 空状态 / 清除

    private var emptySection: some View {
        Section {
            VStack(spacing: 10) {
                Image(systemName: "music.note.list")
                    .font(.system(size: 28))
                    .foregroundColor(.secondary)
                Text("listening_stats_empty".localized)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
        }
    }

    private var clearSection: some View {
        Section {
            // 不按当前时间范围禁用：总览只显示选中的那一段，窗外可能还有数据要清。
            Button(role: .destructive) {
                isConfirmingClear = true
            } label: {
                Text("listening_stats_clear".localized)
            }
        }
    }

    // MARK: - 文案

    private func periodLabel(_ period: ListeningStatsPeriod) -> String {
        switch period {
        case .week: return "listening_stats_period_week".localized
        case .month: return "listening_stats_period_month".localized
        case .year: return "listening_stats_period_year".localized
        case .all: return "listening_stats_period_all".localized
        }
    }

    /// 时长按「小时 + 分 / 分 / 秒」三档显示，不把原始秒数丢给用户。
    private func durationText(_ seconds: Double) -> String {
        let total = max(Int(seconds.rounded()), 0)

        if total >= 3600 {
            let hours = total / 3600
            let minutes = (total % 3600) / 60
            guard minutes > 0 else {
                return String(format: "listening_stats_hours_only_format".localized, hours)
            }
            return String(format: "listening_stats_hours_format".localized, hours, minutes)
        }
        if total >= 60 {
            return String(format: "listening_stats_minutes_format".localized, total / 60)
        }
        return String(format: "listening_stats_seconds_format".localized, total)
    }

    private func playsText(_ count: Int) -> String {
        String(format: "listening_stats_plays_format".localized, count)
    }

    /// 榜单行尾那一段：「N 次 · X 分」。
    private func playsAndTimeText(plays: Int, seconds: Double) -> String {
        String(
            format: "listening_stats_combo_format".localized,
            playsText(plays),
            durationText(seconds)
        )
    }
}

// MARK: - 近 7 天柱状图

/// 7 根柱子，全部用 SwiftUI 的形状自己画。
///
/// 刻意**不用 `Charts`**：那会多一条系统框架依赖，而这里要的只是 7 个矩形和 7 个星期缩写。
private struct ListeningStatsWeekBars: View {

    let points: [ListeningStatsDayTotal]

    private var peak: Double {
        max(points.map { $0.seconds }.max() ?? 0, 1)
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            ForEach(points) { point in
                VStack(spacing: 6) {
                    GeometryReader { proxy in
                        VStack(spacing: 0) {
                            Spacer(minLength: 0)
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Color.accentColor.opacity(point.seconds > 0 ? 0.85 : 0.18))
                                .frame(
                                    height: barHeight(
                                        seconds: point.seconds,
                                        available: proxy.size.height
                                    )
                                )
                        }
                    }
                    .frame(height: 84)

                    Text(weekdayInitial(for: point.date))
                        .font(.caption2)
                        .foregroundColor(point.seconds > 0 ? .primary : .secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.top, 6)
        .accessibilityElement(children: .combine)
    }

    private func barHeight(seconds: Double, available: CGFloat) -> CGFloat {
        guard seconds > 0, available > 0 else { return 2 }
        return max(available * CGFloat(seconds / peak), 4)
    }

    /// 星期缩写取自 `Calendar` 自带的星期名数组，跟着系统语言走，不用自己维护一套。
    private func weekdayInitial(for date: Date) -> String {
        let calendar = Calendar.current
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let index = calendar.component(.weekday, from: date) - 1
        guard symbols.indices.contains(index) else { return "" }
        return symbols[index]
    }
}
