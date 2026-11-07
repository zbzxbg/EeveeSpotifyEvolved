import Foundation
import Orion
import UIKit
import ObjectiveC.runtime

// MARK: - 挂点

func activateEntityPageHeader() {
    // 两个开关共用这一条每帧的布局拍：AM 页头（`entityPageAMHeader`）与"满幅封面 + 取色底"
    // （`entityPageDissolve`）。**任一打开这条钩子就得在**，否则满幅封面那条路又退回 0.6s 的 tick。
    guard EntityPageHeaderManager.isEnabled || EntityPageAppearance.isEnabled else { return }

    let required = [
        EntityPageHeaderLayoutHook.targetName,
        EntityPagePlayButtonHook.targetName,
    ]
    let missing = required.filter { NSClassFromString($0) == nil }
    guard missing.isEmpty else {
        writeDebugLog("[EntityPageHeader] skipped — missing \(missing.joined(separator: ", "))")
        return
    }

    EntityPageHeaderGroup().activate()
    // 专辑页 / 艺人页那两条路都是**可选**的：类不在就少做一页（不能因为一个可选的类把整组拖垮）。
    let album = NSClassFromString(EntityPageAlbumLayoutHook.targetName) != nil
    let artist = NSClassFromString(EntityPageArtistLayoutHook.targetName) != nil
    // **生成歌单（This Is / 电台）的备用入口** —— 同样可选、同样单独一组。
    // 它不在 = 只影响"页头换了一套布局类名"那种情况；共用组里那几页照常。
    let playlistPage = NSClassFromString(EntityPagePlaylistPageHook.targetName) != nil
    if playlistPage { EntityPagePlaylistPageHookGroup().activate() }
    let bio = NSClassFromString(ArtistBiographyViewHook.targetName) != nil
    let bioCard = NSClassFromString(ArtistBiographyCardLayoutHook.targetName) != nil
    // ⚠️ 这一组**单独装**（见 `ArtistBioCardHookGroup` 的说明）：名字里带私有哈希，
    // 换一版就可能解析不到 —— 解析不到就只是少一条事件线，不能连累共用组。
    if bioCard { ArtistBioCardHookGroup().activate() }
    // Spotify 自己的「关于艺人」数据线（`SPTArtistAboutDataLoader`）——
    // 装得上就等于"一进页面就有**完整正文 + 真链接**"；装不上就退回界面读文字那条老路
    // ⚠️ 探测在 `ArtistAboutDataLoaderProbe` 里、不在 hook 类里 —— Orion 不准 hook 类
    // 带 `static func`（见那个 enum 的说明）。
    let aboutLoader = ArtistAboutDataLoaderProbe.canInstall(
        className: SPTArtistAboutDataLoaderHook.targetName
    )
    if aboutLoader { ArtistAboutDataHookGroup().activate() }
    let aboutEncoding = ArtistAboutDataLoaderProbe.typeEncoding(
        className: SPTArtistAboutDataLoaderHook.targetName
    )
    writeDebugLog(
        "[EntityPageHeader] on — AM header \(EntityPageHeaderManager.isEnabled ? "ON" : "OFF"),"
            + " page look \(EntityPageAppearance.isEnabled ? "ON" : "OFF")"
            + " (one layout pass drives both; playlist pages"
            + (album ? " + album pages" : "; album hook missing")
            + (artist ? " + artist pages)" : "; artist hook missing")
            + (bio ? "; about-artist hook on" : "; about-artist hook MISSING")
            + (bioCard ? " + card-layout hook on" : " + card-layout hook MISSING")
            + (aboutLoader ? " + about-data hook on" : " + about-data hook MISSING")
            + " (encoding \(aboutEncoding))"
            + (playlistPage ? "; playlist-page hook on" : "; playlist-page hook MISSING")
    )
}
