import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 「听歌统计」页。
///
/// 数据来自 `ListeningStatsStore`（`Application Support/EeveeSpotify/listening-stats.json`），
/// 聚合在 `ListeningStatsViewModel` 里跑在后台队列上 —— 本文件只负责画。
///
/// 版式与「睡眠定时器」页同一套语言：`List` + `InsetGroupedListStyle()`，说明文字全部放
/// `footer`。唯一会弹东西的地方是「清除统计数据」的 `confirmationDialog` 与导入选择器。
struct EeveeListeningStatsSettingsView: View {

    @StateObject private var viewModel = ListeningStatsViewModel()

    @State private var isEnabled = UserDefaults.listeningStatsEnabled
    @State private var period: ListeningStatsPeriod = .week
    @State private var isConfirmingClear = false

    @State private var isImporting = false
    @State private var importMessage: String?
    @State private var importFailed = false

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

            importSection

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
            Button("clear_button".localized, role: .destructive) {
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
            // 为什么在总览最前面放这一行：30 天 / 一年 / 全部 三档在**只有最近几天数据**时
            // 与 7 天档的数字完全一样（同一个集合），看起来就像"切换没反应"。
            // 把库里最早的那天写出来，用户一眼就知道是"更早没有数据"，不是开关坏了。
            if let firstDay = viewModel.firstDayKey {
                overviewRow("listening_stats_overview_since".localized, firstDay)
            }

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

    // MARK: - 柱子（粒度随范围变）

    /// 表头跟着范围变：7 天沿用原来那句（各语言都翻过），其余用范围名。
    /// 柱子本身的粒度由 `buckets` 决定（日 / 月 / 年），两者永远一致。
    private var chartSection: some View {
        Section(header: Text(chartHeaderText)) {
            if viewModel.buckets.isEmpty {
                if viewModel.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                } else {
                    Color.clear.frame(height: 1)
                }
            } else {
                ListeningStatsBars(
                    points: viewModel.buckets,
                    unit: viewModel.bucketUnit,
                    period: period
                )
                .padding(.vertical, 4)
            }
        }
    }

    private var chartHeaderText: String {
        period == .week ? "listening_stats_last_7_days".localized : periodLabel(period)
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

    // MARK: - 导入历史

    private var importSection: some View {
        Section(
            header: Text("listening_stats_import_title".localized),
            // 页脚里的「申请扩展流媒体历史」要能直接点开：文案写成 markdown 链接
            // （`[spotify.com/account/privacy](https://www.spotify.com/account/privacy)`），
            // 这里按 markdown 解析成 `AttributedString` —— `Text(String)` **不解析** markdown，
            // 那样只会把方括号和括号原样画出来。
            footer: Text(Self.markdownFooter("listening_stats_import_footer".localized))
        ) {
            Button {
                StreamingHistoryFilePickerPresenter.present { urls in
                    importStreamingHistory(urls)
                }
            } label: {
                HStack(spacing: 8) {
                    Label(
                        "listening_stats_import_button".localized,
                        systemImage: "square.and.arrow.down"
                    )
                    Spacer(minLength: 8)
                    if isImporting {
                        ProgressView()
                    }
                }
            }
            .disabled(isImporting)

            if let importMessage {
                Text(importMessage)
                    .font(.footnote)
                    .foregroundColor(importFailed ? Color.red : Color.secondary)
            }
        }
    }

    /// 把页脚文案当 markdown 解析（只解析行内语法，保留空白）。
    ///
    /// 解析失败退回纯文本 —— 一个链接不值得让整块页脚消失。与歌词来源页脚（
    /// `EeveeLyricsSettingsView+lyricsSourceSection`）用的是同一套解析选项。
    private static func markdownFooter(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        return (try? AttributedString(markdown: text, options: options))
            ?? AttributedString(text)
    }

    /// 读文件 → 解析 → 并进 store。
    ///
    /// 解析走全局队列（ZIP 解压 + 逐条 JSON 都在那儿），写盘仍由 store 自己的串行队列负责，
    /// 所以导入期间录音器的增量不会丢。
    private func importStreamingHistory(_ urls: [URL]) {
        guard !urls.isEmpty else { return }

        isImporting = true
        importMessage = "listening_stats_importing".localized
        importFailed = false
        writeDebugLog(
            "[Stats] import start — \(urls.map(\.lastPathComponent).joined(separator: ", "))"
        )

        let calendar = Calendar.current
        let store = ListeningStatsStore.shared

        DispatchQueue.global(qos: .userInitiated).async {
            // 已知来源在解析前读一次：指纹没变的文件连解析都不必重跑。
            let known = store.loadSynchronously().importedSources ?? [:]
            let batch = StreamingHistoryImporter.parse(urls: urls, known: known, calendar: calendar)

            // `asCopy: true` 让系统先把文件导进 App 的临时目录（iCloud 里的也会先下载），
            // 解析完就没用了 —— 十年的导出包几十 MB，留着只会把空间慢慢吃光。
            // 只删临时目录里的副本：万一某个系统版本把副本放去了别处，宁可留着也
            // 不能误删用户自己的文件。
            let temporaryRoot = FileManager.default.temporaryDirectory.standardizedFileURL.path
            for url in urls where url.standardizedFileURL.path.hasPrefix(temporaryRoot) {
                try? FileManager.default.removeItem(at: url)
            }

            DispatchQueue.main.async {
                store.importStreamingHistory(batch.additions) { entries in
                    isImporting = false
                    importMessage = importMessageText(for: batch)
                    importFailed = batch.additions.isEmpty && !batch.failures.isEmpty
                    viewModel.reload(period: period)

                    writeDebugLog(
                        "[Stats] import: files=\(batch.filesRead)"
                            + " skipped=\(batch.filesSkipped)"
                            + " records=\(batch.records)"
                            + " duplicates=\(batch.duplicates)"
                            + " entries=\(entries)"
                            + " failures=\(batch.failures.count)"
                    )
                }
            }
        }
    }

    /// 把解析结果拼成给用户看的两三行字。**不猜**：没有条目时只说没找到/没新增。
    private func importMessageText(for batch: StreamingHistoryImportBatch) -> String {
        var lines: [String] = []

        if !batch.additions.isEmpty, let earliest = batch.earliestDay, let latest = batch.latestDay {
            lines.append(
                String(
                    format: "listening_stats_import_result_format".localized,
                    "\(batch.plays)",
                    "\(batch.additions.count)",
                    "\(earliest) – \(latest)"
                )
            )
        }

        if batch.filesSkipped > 0 {
            lines.append(
                String(
                    format: "listening_stats_import_skipped_format".localized,
                    "\(batch.filesSkipped)"
                )
            )
        }

        if batch.duplicates > 0 {
            lines.append(
                String(
                    format: "listening_stats_import_duplicate_format".localized,
                    "\(batch.duplicates)"
                )
            )
        }

        if let failure = batch.failures.first {
            lines.append(failureText(failure))
        }

        if lines.isEmpty {
            lines.append("listening_stats_import_nothing".localized)
        }

        return lines.joined(separator: "\n")
    }

    private func failureText(_ failure: StreamingHistoryFailure) -> String {
        switch failure.kind {
        case .unreadableArchive:
            return String(format: "listening_stats_import_error_zip".localized, failure.name)
        case .unsupportedArchive:
            return String(format: "listening_stats_import_error_zip_unsupported".localized, failure.name)
        case .unreadableFile:
            return String(format: "listening_stats_import_error_file".localized, failure.name)
        case .noHistoryFile:
            return String(format: "listening_stats_import_error_none".localized, failure.name)
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
            return String(format: "duration_minutes_format".localized, total / 60)
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

// MARK: - 柱子

/// 一组柱子，全部用 SwiftUI 的形状自己画。
///
/// 刻意**不用 `Charts`**：那会多一条系统框架依赖，而这里要的只是几个矩形和它们的短标签。
/// 粒度由 `unit` 决定：7/30 天是日柱（7 根标星期、30 根每 5 天标一个），一年是 12 根月柱，
/// 全部是一年一根。
private struct ListeningStatsBars: View {

    let points: [ListeningStatsBucket]
    let unit: ListeningStatsBucketUnit
    let period: ListeningStatsPeriod

    /// 30 根日柱时只标一部分：1、5、10 … 30。全标会糊成一排。
    private var labelsEveryDay: Bool { period == .week }

    private var peak: Double {
        max(points.map { $0.seconds }.max() ?? 0, 1)
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: unit == .day && !labelsEveryDay ? 2 : 6) {
            ForEach(points) { point in
                VStack(spacing: 6) {
                    GeometryReader { proxy in
                        VStack(spacing: 0) {
                            Spacer(minLength: 0)
                            RoundedRectangle(cornerRadius: unit == .day && !labelsEveryDay ? 2 : 4, style: .continuous)
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

                    Text(label(for: point))
                        .font(.caption2)
                        .foregroundColor(point.seconds > 0 ? .primary : .secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
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

    /// 柱子下面那一行字。
    ///
    /// · 日柱（7 天）：星期缩写，取自 `Calendar` 自带的数组，跟着系统语言走；
    /// · 日柱（30 天）：几号，只在 1/5/10/…/30 上标；
    /// · 月柱：月份数字；
    /// · 年柱：年份后两位。
    private func label(for point: ListeningStatsBucket) -> String {
        let calendar = Calendar.current
        switch unit {
        case .day:
            if labelsEveryDay {
                return weekdayInitial(for: point.date)
            }
            let day = calendar.component(.day, from: point.date)
            return (day == 1 || day % 5 == 0) ? String(day) : ""
        case .month:
            return String(calendar.component(.month, from: point.date))
        case .year:
            return String(calendar.component(.year, from: point.date) % 100)
        }
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

// MARK: - 历史文件选择器

/// 直接从**最上层 VC** 弹 `UIDocumentPickerViewController`。
///
/// 为什么不用 SwiftUI `.sheet` 再包一层 `UIViewControllerRepresentable`：设置页本身就在
/// Spotify 的一个 sheet 里，而文档选择器是系统的**远程 VC** —— 把它塞进另一层 sheet 的
/// hosting controller 当子 VC 时，点「打开 / 确定」可能根本不回调 delegate，手指按下去
/// 没有任何反应。这里与偏移面板、艺人简介同一套 present 方式：从窗口根往下一层层取到
/// 最上面那个 VC，由它 present。
///
/// `asCopy: true`：`asCopy: false` 时，选中的文件如果还在 iCloud 里（没下载到本机），
/// 点「打开」可能两个 delegate 回调都不来（选中与取消都没有）—— 手指按下去没有任何反应，
/// 最后只能自己点左上角取消。交给系统先导出/下载一份到 App 容器，回调一定会来；
/// 代价是几十 MB 的副本，导入完成后由 `importStreamingHistory` 删掉。文件夹也算一种
/// 可选项，所以 `.folder` 也在允许的类型里。
enum StreamingHistoryFilePickerPresenter {

    /// 选择器的 delegate 是 weak：present 期间必须有人强引用它。
    private static var activeCoordinator: Coordinator?

    static func present(
        onPick: @escaping ([URL]) -> Void,
        onCancel: @escaping () -> Void = {}
    ) {
        guard let window = EntityPageAppearance.frontWindow(),
              var host = window.rootViewController else {
            writeDebugLog("[Stats] import picker skipped — no front window")
            return
        }
        while let presented = host.presentedViewController, !presented.isBeingDismissed {
            host = presented
        }

        let types: [UTType] = [.zip, .folder, .json]
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.allowsMultipleSelection = true

        let coordinator = Coordinator(
            onPick: { urls in
                activeCoordinator = nil
                let names = urls.map(\.lastPathComponent).joined(separator: ", ")
                writeDebugLog("[Stats] import picker picked \(urls.count) item(s): \(names)")
                onPick(urls)
            },
            onCancel: {
                activeCoordinator = nil
                writeDebugLog("[Stats] import picker cancelled")
                onCancel()
            }
        )
        activeCoordinator = coordinator
        picker.delegate = coordinator
        host.present(picker, animated: true)
        writeDebugLog(
            "[Stats] import picker presented from \(NSStringFromClass(type(of: host)))"
        )
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let pick: ([URL]) -> Void
        private let cancel: () -> Void

        init(onPick: @escaping ([URL]) -> Void, onCancel: @escaping () -> Void) {
            self.pick = onPick
            self.cancel = onCancel
        }

        func documentPicker(
            _ controller: UIDocumentPickerViewController,
            didPickDocumentsAt urls: [URL]
        ) {
            guard !urls.isEmpty else {
                cancel()
                return
            }
            pick(urls)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            cancel()
        }
    }
}
