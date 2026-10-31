// 队列弹窗（Spotify **自己的**「队列」底部卡片）的**只读**探针。
//
// Spotify 自己的队列页 —— 点右下角那个「像服务器」的键（`QueueButtonNowPlaying`）弹出来的
// 底部卡片：顶上当前歌 + 一排圆按钮（随机 / 循环 / 自动播放 / 定时器），下面是队列列表。
// 目标是把它做成 MeloX 那种形态。
//
// 要做那件事，先得知道**这一页的视图树**（我们从来没过抓过它）：
// · 顶部的「队列 / 编辑 / 正在播放 N」是哪几个视图；
// · 底部那三颗（随机播放 / 循环播放 / 定时器）挂在哪个容器上、有没有 id；
// · 列表是 UITableView 还是 collection view、cell 的类名。
//
// ⚠️上一版把类名写成“…Impl18QueueViewController”，而 9.1.88 的
// 真实名字是 **19**（`_TtC14Queue_ViewImpl19QueueViewController`，19 = "QueueViewController"
// 的长度）⇒ 每次都打一行 `[QueueProbe] missing … — no queue tree this build`，
// 队列卡片因此**从来没被转储过**。已修正。
//
// 这个文件**只做一件事**：把 `Queue_ViewImpl.QueueViewController` 的 view 登记给
// `ViewTreeDumper`（与听歌页 `NPVScrollViewControllerHook` 用同一条路）。于是——
// · 「调试 → 转储视图树」打开时，
// （`dumpPage` 的预算比整窗那趟大得多，足够覆盖整张卡片）；
// · 开关关着时**零动作**（`ViewTreeDumper` 自己不看这个登记）。
//
// 纪律：
// · **只读**：只登记一个指针，不改任何视图、不读任何内容；
// · 目标类不在（换版 / 改名）就只记一行日志，不留给 Orion 报非致命错误；
// · 关掉卡片时把登记清掉（否则转储会一直对着一个离开屏幕的页面跑）。
import Foundation
import Orion
import UIKit

struct QueueSheetProbeGroup: HookGroup {}

class QueueViewControllerProbeHook: ClassHook<UIViewController> {
    typealias Group = QueueSheetProbeGroup
    static let targetName = "_TtC14Queue_ViewImpl19QueueViewController"

    func viewDidAppear(_ animated: Bool) {
        orig.viewDidAppear(animated)
        guard let view = target.viewIfLoaded else { return }
        ViewTreeDumper.setPage(view)
        writeDebugLog("[QueueProbe] queue sheet registered for the tree dump")
    }

    func viewWillDisappear(_ animated: Bool) {
        orig.viewWillDisappear(animated)
        ViewTreeDumper.setPage(nil)
    }
}

func activateQueueSheetProbe() {
    if NSClassFromString(QueueViewControllerProbeHook.targetName) != nil {
        QueueSheetProbeGroup().activate()
        writeDebugLog("[QueueProbe] armed on \(QueueViewControllerProbeHook.targetName)")
    } else {
        writeDebugLog("[QueueProbe] missing \(QueueViewControllerProbeHook.targetName) — no queue tree this build")
    }
}
