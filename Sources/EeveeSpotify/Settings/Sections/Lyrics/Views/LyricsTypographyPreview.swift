import SwiftUI

/// 设置页「歌词 → 文字」那一块里的实时预览。
///
/// 直接把**生产那一页**（`AppleMusicLyricsPage`）缩小塞进来，而不是另画一份替身：
/// 字号 / 行距的全部效果 —— 折行位置、译文行跟着缩、块与块之间那道空隙 —— 都发生在
/// 那一页里。替身只能预览出"看起来差不多、真机上差很多"，而这恰好是设置项最需要说清的。
///
/// 代价有两个，都是刻意接受的：
/// · 要 iOS 26（那一页本身就门禁在 26，调用点先 `#available`）；
/// · 页面里带着 `ScrollView` 与点行跳转，所以预览整体 `allowsHitTesting(false)` ——
///   手指落在预览上时应该滚**设置页**，而不是把这块小卡片里的歌词滚走。
@available(iOS 26.0, *)
struct LyricsTypographyPreview: View {

    /// 当前两档倍率套上全屏分档之后的排版。由设置页传进来，滑一下就会重算。
    let typography: LyricsTypographyScale

    /// 预览用的三句样例，取《アルビレオ》里连续的三句（每句都是**罗马音 + 原文 + 译文**
    /// 三层都在，和真实歌词行的层次一样），第二句是焦点行。
    ///
    /// 三句都用日文：以前前后两句是英文样例，混在正文上下会把"正在看的是哪一句"搅乱。
    /// 前后两句也不能省 —— 焦点行在中间，它们同时演示了「行距」那一档（块与块之间的
    /// 间距）和焦点行的前后两句如何变淡；只剩一句时，行距滑块在预览里就看不出效果。
    private static let lines: [LyricLine] = [
        LyricLine(
            time: 0,
            text: "心が余った言い訳を",
            romanization: "Ko ko ro ga a ma 't ta i i wa ke wo",
            translation: "心中多余的借口"
        ),
        LyricLine(
            time: 6,
            text: "君は藍に浮かんだアルビレオ",
            romanization: "Ki mi ha a i ni u ka n da a ru bi re o",
            translation: "你就是浮现在蔚蓝中的天鹅座β"
        ),
        LyricLine(
            time: 12,
            text: "この心を奪ったまま",
            romanization: "Ko no ko ko ro wo u ba 't ta ma ma",
            translation: "已将我的心完全占据"
        )
    ]

    var body: some View {
        AppleMusicLyricsPage(
            lines: Self.lines,
            // 停在第二句中间：焦点行与普通行同时在场，才看得出焦点那一档的观感。
            playbackTime: 6.4,
            background: AnyView(Color.black),
            contentInsets: EdgeInsets(top: 20, leading: 16, bottom: 20, trailing: 16),
            typography: typography,
            // 译文开着：这一项最容易和字号打架（译文不跟着缩就会顶掉正文的高度）。
            showsTranslation: true
        )
        .allowsHitTesting(false)
        .frame(height: 210)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
