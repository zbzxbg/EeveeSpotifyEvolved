import SwiftUI
import UniformTypeIdentifiers

/// 「歌词 → 导入歌词」页。
///
/// 只做两件事：把用户自己的歌词文件拷进 `Documents/EeveeSpotifyLyrics/`，以及管理这个目录。
/// 匹配是自动的（`ImportedLyricsStore.match`），所以这里不提供"绑定到某首歌" ——
/// 文件名或元信息对不上时，改文件名比在设置页里翻曲库快。
struct EeveeImportedLyricsSettingsView: View {

    private static let ownedKeys = ["importedLyricsEnabled"]

    @State private var enabled = UserDefaults.importedLyricsEnabled
    @State private var records: [ImportedLyricsFileRecord] = []
    @State private var isPresentingPicker = false
    @State private var lastError: String?

    private let store = ImportedLyricsStore.shared

    var body: some View {
        List {
            Section(footer: Text("imported_lyrics_enabled_description".localized)) {
                Toggle("imported_lyrics_enabled".localized, isOn: $enabled)
                    .onChange(of: enabled) { value in
                        UserDefaults.importedLyricsEnabled = value
                        // 备忘里可能还压着这一首上一份 payload（60 秒 TTL）：开关一变就清掉。
                        LyricsResponseCache.shared.reset()
                    }
            }

            Section(
                header: Text("imported_lyrics_files".localized),
                footer: Text("imported_lyrics_formats_description".localized)
            ) {
                Button {
                    isPresentingPicker = true
                } label: {
                    Label("imported_lyrics_import".localized, systemImage: "square.and.arrow.down")
                }

                if records.isEmpty {
                    Text("imported_lyrics_empty".localized)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(records, id: \.name) { record in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(record.name)
                                Text(record.url.pathExtension.uppercased())
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                delete(record)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }

            if let lastError {
                Section {
                    Text(lastError)
                        .font(.footnote)
                        .foregroundColor(.red)
                }
            }

            SettingsResetSection(
                keys: Self.ownedKeys,
                afterReset: {
                    enabled = UserDefaults.importedLyricsEnabled
                }
            )
        }
                // inset-grouped（胶囊卡片）—— 为什么、怎么做的见 `EeveeSettingsView` 顶部那段
        .listStyle(InsetGroupedListStyle())
        .onAppear(perform: refresh)
        .sheet(isPresented: $isPresentingPicker) {
            LyricsFilePicker(
                onPick: { url in
                    isPresentingPicker = false
                    importFile(url)
                },
                onCancel: {
                    isPresentingPicker = false
                }
            )
        }
    }

    private func refresh() {
        enabled = UserDefaults.importedLyricsEnabled
        records = store.list()
    }

    private func importFile(_ url: URL) {
        do {
            let record = try store.importFile(at: url)
            lastError = nil
            writeDebugLog("[Import] imported \(record.name)")
        } catch {
            lastError = "imported_lyrics_import_failed".localized
            writeDebugLog("[Import] failed to import \(url.lastPathComponent)")
        }
        LyricsResponseCache.shared.reset()
        refresh()
    }

    private func delete(_ record: ImportedLyricsFileRecord) {
        try? store.delete(record)
        writeDebugLog("[Import] deleted \(record.name)")
        LyricsResponseCache.shared.reset()
        refresh()
    }
}

/// `UIDocumentPickerViewController` 的 SwiftUI 外壳。
///
/// `asCopy: true`：选择器先把文件复制到临时目录再交给我们，随后 `ImportedLyricsStore`
/// 再拷进自己的目录。两份拷贝是有意的 —— 选择器给的临时授权过了这次会话就失效。
struct LyricsFilePicker: UIViewControllerRepresentable {

    var onPick: (URL) -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // 这些扩展名在 UTType 里不一定有注册类型，拿不到就退回纯文本 —— 选择器仍会
        // 按扩展名过滤不了的部分交给 `ImportedLyricsStore.importFile` 再拒一次。
        let types = ["lrc", "spl", "yrc", "lys", "lyl"].compactMap {
            UTType(filenameExtension: $0) ?? .plainText
        }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let parent: LyricsFilePicker

        init(_ parent: LyricsFilePicker) {
            self.parent = parent
        }

        func documentPicker(
            _ controller: UIDocumentPickerViewController,
            didPickDocumentsAt urls: [URL]
        ) {
            guard let url = urls.first else {
                parent.onCancel()
                return
            }
            parent.onPick(url)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.onCancel()
        }
    }
}
