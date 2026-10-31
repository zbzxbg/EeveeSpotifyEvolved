// 「iOS 27 听歌页」页内歌词模式下、缩略图右边那块**歌词署名**。
//
// 「展示歌词来源提供商/歌词由谁制作这个东西，要不：放在全溶封面的时候不是歌手名字/
// 艺人名字放在一个地方吗，然后歌曲名字的位置放歌词来源是谁，艺人名字放歌词提供者/
// 翻译提供者。而这个展示只在歌词展示的时候出现」
//
// 版式就照原生标题行那一块（缩略图右边、与缩略图顶对齐）：
// · 第一行（原来放歌名的位置）= **歌词来源**（`NetEase` / `AMLL` / `Spicy Lyrics`…）；
// · 第二行（原来放艺人的位置）= **上传者 / 制作者 / 翻译者**（有哪条写哪条）。
//
// 它只在 `NowPlayingIOS27.lyricsModeActive` 时可见；原生标题行在同一段里淡出
// （见 `NowPlayingIOS27.placeTitleRow`），收起歌词时两者一起还原。
import Foundation
import UIKit

/// 缩略图右边那块两行署名。
final class NowPlayingIOS27LyricsCreditView: UIView {

    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private var renderedTitle = ""
    private var renderedSubtitle = ""

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        accessibilityIdentifier = "eevee-ios27-lyrics-credit"
        isAccessibilityElement = false

        // 字号照歌词区底沿那行署名（不是标题行）：这是一条"来源/署名"页脚。
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = UIColor.white.withAlphaComponent(0.90)
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.accessibilityIdentifier = "eevee-ios27-lyrics-credit-title"

        subtitleLabel.font = .systemFont(ofSize: 11, weight: .regular)
        subtitleLabel.textColor = UIColor.white.withAlphaComponent(0.62)
        subtitleLabel.numberOfLines = 1
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.accessibilityIdentifier = "eevee-ios27-lyrics-credit-subtitle"

        addSubview(titleLabel)
        addSubview(subtitleLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(title: String, subtitle: String) {
        if renderedTitle != title {
            renderedTitle = title
            titleLabel.text = title
        }
        if renderedSubtitle != subtitle {
            renderedSubtitle = subtitle
            subtitleLabel.text = subtitle
        }
        subtitleLabel.isHidden = subtitle.isEmpty
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width
        titleLabel.frame = CGRect(x: 0, y: 0, width: width, height: 18)
        subtitleLabel.frame = CGRect(x: 0, y: 19, width: width, height: 16)
    }
}

// MARK: - 这块写什么
//
// 「缩略图右边那两行写什么」——只在这一处拼，视图负责显示。
//
// 第一行 = 歌词来源（`currentLyricsProvider`）；第二行 = 上传者 / 制作者 / 翻译者。
// **没有第二行就不画**（`subtitleLabel.isHidden`），不写"暂无署名"这种占位。
@MainActor
enum NowPlayingLyricsCreditInfo {

    /// 第一行：提供者短名。没有时用 `lyrics_source_unknown`（"source unknown"）。
    static var sourceName: String {
        let provider = currentLyricsProvider.trimmingCharacters(in: .whitespacesAndNewlines)
        return provider.isEmpty ? "lyrics_source_unknown".localized : provider
    }

    /// 第二行：有 contributors 就按角色拼；没有就退回 `providerCredit` 里 provider 之后的那段。
    static var rolesText: String {
        // （网易云感觉不展示歌词提供者/翻译提供者）：
        // 同一人既是上传者又是翻译者时合并成 `上传者/翻译者 X`（网易云常见），
        // 不同的人仍是 `上传者 A · 制作者 B`。拼接规则只留一份 —— 与听歌页底沿、
        // 自绘歌词页页脚共用 `combinedLyricsContributorText`。
        let roles = combinedLyricsContributorText()
        if !roles.isEmpty { return roles }

        // AMLL 这一类没有 `providerContributors`：仓库把作者拼进 `providerCredit`
        // （"AMLL · @author"）。剥掉最前面的 provider，剩下的就是署名。
        let provider = currentLyricsProvider.trimmingCharacters(in: .whitespacesAndNewlines)
        var credit = (currentLyricsDto?.providerCredit ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !credit.isEmpty, credit != provider else { return "" }
        if !provider.isEmpty, credit.hasPrefix(provider) {
            credit = String(credit.dropFirst(provider.count))
        }
        credit = credit.trimmingCharacters(in: .whitespacesAndNewlines)
        while credit.hasPrefix("·") {
            credit = String(credit.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return credit
    }
}
