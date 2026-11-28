import Foundation

// 「最新发布」按名字搜到**多位同名艺人**时的消歧（纯逻辑，CI 可测）。
//
// 同名不同人是这张卡最容易犯的错：Spotify 的搜索按相关度排，第一位不一定就是这一页的人
// （`MIMI` / `Mimì` 这种只差一个变音符号的名字尤其）。艺人页上显示的是**目录里的原名**，
// 所以第一步先要求**逐字相等**（见 `ArtistReleasesFromSpotify`）；如果仍有多个，
// 就用**页面上看得见的文字**投票：哪位候选的 top tracks 在这个页面上出现过，就选哪位。
enum ArtistReleaseDisambiguation {

    /// 参与比较的文本：小写、只留字母数字（空格 / 标点 / "次播放"这类文字全部去掉）。
    ///
    /// **不去变音符号**：两边都来自同一份目录，`Mimì` 与 `MIMI` 必须保持不同。
    static func normalized(_ text: String) -> String {
        text.lowercased().filter { character in
            character.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) }
        }
    }

    /// 候选的 top tracks 里，有几首出现在页面文字中（只看前 `limit` 首）。
    ///
    /// 太短的标题（< 3 字符）不参与：它们在页面任何位置都可能撞上，投出来的票没有意义。
    static func score(titles: [String], pageText: String, limit: Int = 10) -> Int {
        let page = normalized(pageText)
        guard !page.isEmpty else { return 0 }
        var hits = 0
        for title in titles.prefix(max(limit, 0)) {
            let wanted = normalized(title)
            guard wanted.count >= 3 else { continue }
            if page.contains(wanted) { hits += 1 }
        }
        return hits
    }

    /// 唯一最高、且不低于 `minimum` 的那一位；并列 / 不够 / 空 → `nil`（**不猜**）。
    static func bestIndex(scores: [Int], minimum: Int = 2) -> Int? {
        var best: (index: Int, score: Int)?
        var tied = false
        for (index, score) in scores.enumerated() {
            guard score >= minimum else { continue }
            if let current = best {
                if score > current.score {
                    best = (index, score)
                    tied = false
                } else if score == current.score {
                    tied = true
                }
            } else {
                best = (index, score)
            }
        }
        guard let best, !tied else { return nil }
        return best.index
    }
}
