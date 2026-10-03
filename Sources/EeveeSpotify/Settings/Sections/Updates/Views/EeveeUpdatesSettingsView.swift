import SwiftUI
import UIKit

/// 「更新日志」页：列出本仓库最近 30 个 release（含正文），点一条用系统浏览器打开。
///
/// 与根页那条"有没有新版"是同一份数据源（`GitHubHelper`，仓库写死）。
/// 根页只解 `tagName`，这里多解 `name` / `body` / `htmlUrl` / `publishedAt` / `prerelease`，
/// 全部可选 —— 某个 release 少字段不影响这一页，也不影响版本检查。
///
/// ⚠️ ★ 2026-10-11 更正：这里用的是**列表**接口 `/repos/<slug>/releases` ——
/// 仓库存在但**没有 release** 时它回的是 **200 + `[]`**，走下面的
/// `.loaded(...) where isEmpty` ⇒ 显示 `updates_empty`，**不是 404**。
/// 404 只在仓库**不存在 / 改名 / 转私有**时出现，那时显示 `updates_error_not_found`
/// （文案已按"找不到仓库"改写）。
/// 无论哪种，这一页都不会空转圈（与 `EeveeSettingsVersionView` 的兜底同一条纪律）。
struct EeveeUpdatesSettingsView: View {

    private enum LoadState {
        case loading
        case loaded([GitHubRelease])
        case failed(String)
    }

    @State private var state: LoadState = .loading

    var body: some View {
        List {
            switch state {
            case .loading:
                Section {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("updates_loading".localized)
                            .foregroundColor(.secondary)
                    }
                }

            case .failed(let reason):
                Section(footer: Text("updates_failed_footer".localized)) {
                    Text(reason)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    // 限流（未登录 60 次/小时）是**会自己恢复**的失败，所以给一个重试入口 ——
                    // 不然用户只能杀掉 App 再进。重试走的是同一条 `load()`（带 5 分钟缓存，
                    // 缓存还新鲜时根本不发请求）。
                    Button("updates_retry".localized) {
                        state = .loading
                        Task { await load() }
                    }
                    .font(.subheadline)
                }

            case .loaded(let releases) where releases.isEmpty:
                Section(footer: Text("updates_failed_footer".localized)) {
                    Text("updates_empty".localized)
                        .foregroundColor(.secondary)
                }

            case .loaded(let releases):
                ForEach(Array(releases.enumerated()), id: \.offset) { _, release in
                    Section {
                        row(release)
                    }
                }
            }
        }
        .listStyle(GroupedListStyle())
        // ⚠️ 用 `onAppear` + `Task` 而不是 `.task {}`：后者要 iOS 15，
        // 本仓库的最低版本由 Theos 的 spm_config 给（历史上低到 iOS 14），别为这一页抬线。
        .onAppear {
            guard case .loading = state else { return }
            Task { await load() }
        }
    }

    // MARK: - 行

    @ViewBuilder
    private func row(_ release: GitHubRelease) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(release.tagName)
                    .font(.system(.body, design: .monospaced))
                    .bold()

                if release.prerelease == true {
                    Text("updates_prerelease".localized)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.2))
                        .cornerRadius(4)
                }

                Spacer()

                if let publishedAt = release.publishedAt, publishedAt.count >= 10 {
                    Text(verbatim: String(publishedAt.prefix(10)))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            if let name = release.name, !name.isEmpty, name != release.tagName {
                Text(name)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            if let body = release.body, !body.isEmpty {
                // Markdown 原文**原样**展示（不做渲染）：渲染要引第三方库，
                // 而这一页的用处是"看清单"，纯文本足够且不会骗人。
                Text(body)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(12)
            }

            if let urlString = release.htmlUrl, let url = URL(string: urlString) {
                Button {
                    UIApplication.shared.open(url)
                } label: {
                    Label("updates_open".localized, systemImage: "safari")
                        .font(.caption)
                }
            }
        }
    }

    // MARK: - 取数

    private func load() async {
        do {
            let releases = try await GitHubHelper.shared.getReleases()
            state = .loaded(releases)
        } catch {
            writeDebugLog("[Updates] fetching releases failed: \(error)")
            state = .failed(message(for: error))
        }
    }

    /// 失败原因 → 人话。
    ///
    /// ⚠️ **别再直接把 `error.localizedDescription` 怼给用户**：2026-10-02 用户看到的是
    /// 「未能读取该数据，因为它的格式不正确」——那是 `DecodingError` 的文案，而真因在
    /// HTTP 层（GitHub 未登录限流，日志 28 里那次请求只回了 280 字节的 403 响应体）。
    /// 见 `GitHubAPIError` 里那段说明。
    private func message(for error: Error) -> String {
        guard let apiError = error as? GitHubAPIError else {
            return error.localizedDescription
        }

        switch apiError {
        case .rateLimited(let reset):
            guard let reset, reset.timeIntervalSinceNow > 0 else {
                return "updates_error_rate_limit".localized
            }
            let minutes = max(1, Int((reset.timeIntervalSinceNow / 60).rounded(.up)))
            return "updates_error_rate_limit_reset".localizeWithFormat(minutes)

        case .notFound:
            return "updates_error_not_found".localized

        case .transport:
            return "updates_error_network".localized

        case .decoding(let detail):
            return "updates_error_format".localized + "\n" + detail

        case .httpStatus(let status):
            return "updates_error_status".localizeWithFormat(status)
        }
    }
}
