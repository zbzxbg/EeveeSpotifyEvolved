import SwiftUI
import UIKit 

class EeveeSettingsViewController: SPTPageViewController {
    let settingsView: AnyView
    private var hasShownSpecialLicense = false
    
    init(_ frame: CGRect, settingsView: AnyView, navigationTitle: String) {
        self.settingsView = settingsView
        super.init(nibName: nil, bundle: nil)
        
        title = navigationTitle
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        let hostingController = UIHostingController(rootView: settingsView)
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        hostingController.view.backgroundColor = .clear
        
        view.addSubview(hostingController.view)
        addChild(hostingController)
        hostingController.didMove(toParent: self)
        
        NSLayoutConstraint.activate([
            hostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
            hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Become first responder so we can receive motion events
        becomeFirstResponder()
    }

    // MARK: - 底部内边距：Spotify 的标签栏不在安全区里

    /// Spotify 的标签栏（`id=elements-tabs-view-identifier`）与它上方那条迷你播放条
    /// （类名正好是 `TouchPassthroughView`）都是**它自己的视图**，不参与 `safeAreaInsets`。
    /// 结果：宿主里那个 SwiftUI `List` 的底部安全区是 0 —— 内容一直滚到标签栏**下面**去，
    /// 最后一行/脚注既看不见、也滚不上来。
    ///
    /// 用户 2026-10-01 的反馈就是这个：「扩展功能」页看不到隐私/触感/Flag 覆盖那三行的说明，
    /// 而且 Flag 页最底下一行会被挡。
    ///
    /// 做法：每次布局量一次底部 chrome 的顶边，折算成 `additionalSafeAreaInsets.bottom`
    /// （减掉系统本来就给的那份）。`UIHostingController` 会把它翻成 SwiftUI 的安全区，
    /// `List` 于是自动多出这段可滚动空间 —— **六个设置页全都受益**，不用逐页改。
    ///
    /// 为什么不写死 83pt：有没有 home indicator、迷你条在不在、iPhone 还是 iPad，遮挡都不一样。
    private static let tabBarIdentifier = "elements-tabs-view-identifier"

    /// ⚠️ 必须**精确相等**，不能用 `hasSuffix` —— UIKit 自己有个 `_UITouchPassthroughView`
    /// （日志 9 里它 414x896，整屏那么高），后缀匹配会把它当成迷你条，算出一个巨大的内边距。
    private static let miniBarClassName = "TouchPassthroughView"

    /// 量出来的遮挡再留一点余量，免得最后一行正好贴着标签栏顶边。
    private static let bottomBreathingRoom: CGFloat = 8

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateBottomInset()
    }

    private func updateBottomInset() {
        guard let window = view.window, view.bounds.height > 0 else { return }

        var chromeTop: CGFloat?
        var queue: [UIView] = [window]
        var visited = 0

        while !queue.isEmpty, visited < 2000 {
            let node = queue.removeFirst()
            visited += 1
            queue.append(contentsOf: node.subviews)

            let isBottomChrome = node.accessibilityIdentifier == Self.tabBarIdentifier
                || String(describing: type(of: node)) == Self.miniBarClassName
            guard isBottomChrome, !node.isHidden, node.alpha > 0.01 else { continue }

            let frameInView = node.convert(node.bounds, to: view)
            guard frameInView.height > 0, frameInView.minY < view.bounds.maxY else { continue }

            chromeTop = min(chromeTop ?? frameInView.minY, frameInView.minY)
        }

        let overlap = chromeTop.map { max(0, view.bounds.maxY - $0) } ?? 0

        // 系统已经给的那份 = 解析后的安全区 − 我们自己加的那份。
        // 这样既不会把余量叠加两次，也不会因为我们自己改了 `additionalSafeAreaInsets`
        // 而越算越大（那个会让布局反复触发，最后停在某个错的值上）。
        let systemBottom = max(0, view.safeAreaInsets.bottom - additionalSafeAreaInsets.bottom)
        let wanted = overlap > 0
            ? max(0, overlap + Self.bottomBreathingRoom - systemBottom)
            : 0

        // 只在真的变了才写 —— 写 `additionalSafeAreaInsets` 会再触发一次布局。
        guard abs(additionalSafeAreaInsets.bottom - wanted) > 0.5 else { return }
        additionalSafeAreaInsets.bottom = wanted
    }

    override var canBecomeFirstResponder: Bool { true }
    
    override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        super.motionEnded(motion, with: event)
        // （已移除：摇一摇触发的 "Special License Detected / Hysan" 彩蛋）
    }
    
    @objc func openRepositoryUrl(_ sender: UIButton) {
        // 设置页右上角那颗「小球」（bundle 里的 `github` 图）：
        // 指向**本仓库**，而不是上游 `jaydenjcpy/EeveeSpotifyReincarnated`。
        //
        // 这里刻意写死而不是用 `EeveeSpotify.repoSlug`：那颗球是"我是谁"的入口，
        // 不该随构建机的 git remote 漂移（改名/换 fork 时容易指到别人仓库）。
        //
        // ⚠️ 2026-10-02：仓库从 `EeveeSpotify-ng-latest` 改名成 **`EeveeSpotifyEvolved`**，
        // 这里跟着改（改名前 GitHub 会 302，但用户看到的名字应当是新的那个）。
        UIApplication.shared.open(URL(string: "https://github.com/zbzxbg/EeveeSpotifyEvolved")!)
    }
}
