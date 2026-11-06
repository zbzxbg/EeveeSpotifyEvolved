import Foundation

struct PetitSong: Codable {
    var lyricsId: Int
    var title: String
    var availableLyricsType: PetitLyricsType
    var lyricsType: PetitLyricsType
    var lyricsData: String

    /// 作詞者（站点上「作詞：」那一栏）。搜索与取词两个接口的 `<song>` 节点都带，
    /// 但**可能为空元素**（有的歌这一栏就是空的）⇒ 一律当可选字符串读。
    var writer: String?

    /// 把这条词投到 PetitLyrics 的账号昵称。官方词条这一栏固定是 `PetitLyrics`，
    /// 那不是一个人，署名时跳过。
    var postUserName: String?
}
