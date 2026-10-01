import SwiftUI
import UIKit

/// 「备份与重置」页：导出 / 导入本仓库的设置，以及"只重置我们的设置"。
///
/// ── 为什么用剪贴板而不是"存文件"──────────────────────────────────────────────
/// Spotify 的沙箱不对 Files app 开放，存进去用户**拿不出来**；剪贴板是这台设备上
/// 一定拿得到的通道（贴进备忘录、AirDrop、发给自己都行）。所以这一页的主按钮是
/// 「复制到剪贴板」，文本框只是让你看一眼、或者从别处粘贴进来。
///
/// ── 只碰我们自己的键 ────────────────────────────────────────────────────────
/// 导出/导入/重置都走 `UserDefaults.ownedKeys` 白名单（见 `SettingsBackup` 里的三条铁律）：
/// 这个进程的 `.standard` 里同时躺着 **Spotify 自己的偏好**，全删会把 Spotify 的设置
/// 一起清掉 —— 那是「重置 Spotify 状态」（另一个开关）的语义，不是这里。
struct EeveeBackupSettingsView: View {

    @State private var exportText = ""
    @State private var importText = ""
    @State private var status: String?
    @State private var confirmReset = false

    var body: some View {
        List {
            exportSection
            importSection
            resetSection

            if let status {
                Section {
                    Text(status)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .listStyle(GroupedListStyle())
        .onAppear { exportText = SettingsBackup.exportText() }
        .alert(isPresented: $confirmReset) {
            Alert(
                title: Text("backup_reset_confirm_title".localized),
                message: Text("backup_reset_confirm_message".localized),
                primaryButton: .destructive(Text("backup_reset".localized)) {
                    let removed = SettingsBackup.resetToStock()
                    exportText = SettingsBackup.exportText()
                    status = String(format: "backup_reset_done".localized, removed)
                },
                secondaryButton: .cancel()
            )
        }
    }

    // MARK: - 导出

    private var exportSection: some View {
        Section(
            header: Text("backup_export_section".localized),
            footer: Text("backup_export_footer".localized)
        ) {
            Button {
                exportText = SettingsBackup.exportText()
                status = "backup_regenerated".localized
            } label: {
                Label("backup_regenerate".localized, systemImage: "arrow.clockwise")
            }

            Button {
                exportText = SettingsBackup.exportText()
                UIPasteboard.general.string = exportText
                status = "backup_copied".localized
            } label: {
                Label("backup_copy".localized, systemImage: "doc.on.doc")
            }

            // 只读展示：能选中复制，但别让用户以为改这里能生效（生效靠导入）。
            // ⚠️ 不用 `.textSelection` —— 那是 iOS 15 的 API，这一页不值得抬高最低版本。
            Text(exportText)
                .font(.system(.caption2, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(8)
        }
    }

    // MARK: - 导入

    private var importSection: some View {
        Section(
            header: Text("backup_import_section".localized),
            footer: Text("backup_import_footer".localized)
        ) {
            TextEditor(text: $importText)
                .font(.system(.caption2, design: .monospaced))
                .frame(minHeight: 96)

            Button {
                let result = SettingsBackup.importText(importText)
                status = describe(result)
                exportText = SettingsBackup.exportText()
            } label: {
                Label("backup_import".localized, systemImage: "square.and.arrow.down")
            }
            .disabled(importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Button {
                if let clipboard = UIPasteboard.general.string {
                    importText = clipboard
                    status = "backup_pasted".localized
                } else {
                    status = "backup_clipboard_empty".localized
                }
            } label: {
                Label("backup_paste".localized, systemImage: "doc.on.clipboard")
            }
        }
    }

    private func describe(_ result: SettingsBackup.Result) -> String {
        switch result.message {
        case "ok":
            return String(format: "backup_import_done".localized, result.applied, result.skipped)
        case "empty":
            return "backup_import_empty".localized
        case "no_values":
            return "backup_import_not_a_backup".localized
        default:
            return "backup_import_unreadable".localized
        }
    }

    // MARK: - 重置

    private var resetSection: some View {
        Section(footer: Text("backup_reset_footer".localized)) {
            Button {
                confirmReset = true
            } label: {
                Label("backup_reset".localized, systemImage: "arrow.counterclockwise")
            }
            .foregroundColor(.red)
        }
    }
}
