import Orion
import SwiftUI
import UIKit

// Universal settings integration.
//
// ⚠️ 2026-10-02：老的 `ProfileSettingsSection` / `SettingsViewController` /
// `RootSettingsViewController` / "按标题猜设置"的兜底 hook **全部删除** ——
// 它们的入口类只在 Spotify 9.1.0 上存在（扫过 9.1.0 / 9.1.74 / 9.1.76 / 9.1.86 四个包），
// 在唯一的目标版本 9.1.86 上只会走到 `else` 分支打一行 `Skipped settings integration`。
// 9.1.44+ 唯一那条路是下面这个。
struct UniversalSettingsIntegrationListVCGroup: HookGroup { }

// （`ProfileSettingsSection` 那条老入口已于 2026-10-02 删除：入口类只在 Spotify 9.1.0 上存在。）


// MARK: - Global Helper to avoid Orion Hooking Issues with setupEeveeButton
// This logic is moved outside the ClassHook so Orion doesn't try to find it as an Obj-C method on the target class.
func injectEeveeButton(into target: UIViewController) {
    NSLog("[EeveeSpotify] injectEeveeButton called for \(String(describing: type(of: target)))")
    
    // Check if the button already exists in rightBarButtonItems
    if let rightItems = target.navigationItem.rightBarButtonItems {
        if rightItems.contains(where: { $0.tag == 1337 }) {
             NSLog("[EeveeSpotify] Button already exists (tag 1337)")
             return 
        }
    }

    NSLog("[EeveeSpotify] Creating and injecting button...")
    
    let button = UIButton(type: .system)
    // Use system image to guarantee visibility and avoid crashes
    let image = UIImage(systemName: "gearshape.fill") ?? UIImage()
    button.setImage(image, for: .normal)
    button.tintColor = .white
    
    let action = UIAction { [weak target] _ in
        guard let target = target, let navigationController = target.navigationController else { 
            NSLog("[EeveeSpotify] Navigation controller not found")
            return 
        }
        
        NSLog("[EeveeSpotify] Opening EeveeSettings...")
        
        let eeveeSettingsController = EeveeSettingsViewController(
            target.view.bounds,
            settingsView: AnyView(EeveeSettingsView(navigationController: navigationController)),
            navigationTitle: "EeveeSpotify"
        )
        
        // Add GitHub button to the Eevee settings page itself
        let subButton = UIButton(type: .system)
        
        // Try loading hex image, fallback to system "globe" if it fails or bundle is missing
        let bundleImage = BundleHelper.shared.uiImage("hex")
        // Check if the image returned from BundleHelper is valid (has a size)
        if let bundleImage = bundleImage, bundleImage.size != .zero {
            subButton.setImage(bundleImage.withRenderingMode(.alwaysOriginal), for: .normal)
        } else {
             subButton.setImage(UIImage(systemName: "globe"), for: .normal)
        }
        
        subButton.tintColor = .white
        
        let subAction = UIAction { [weak eeveeSettingsController] _ in
            eeveeSettingsController?.openRepositoryUrl(subButton)
        }
        subButton.addAction(subAction, for: .touchUpInside)
        
        let menuBarItem = UIBarButtonItem(customView: subButton)
        menuBarItem.customView?.heightAnchor.constraint(equalToConstant: 22).isActive = true
        menuBarItem.customView?.widthAnchor.constraint(equalToConstant: 22).isActive = true
        eeveeSettingsController.navigationItem.rightBarButtonItem = menuBarItem
        
        navigationController.pushViewController(eeveeSettingsController, animated: true)
    }
    
    button.addAction(action, for: .touchUpInside)
    
    let item = UIBarButtonItem(customView: button)
    item.tag = 1337 // Tag to prevent duplicate addition
    item.customView?.widthAnchor.constraint(equalToConstant: 22).isActive = true
    item.customView?.heightAnchor.constraint(equalToConstant: 22).isActive = true
    
    var items = target.navigationItem.rightBarButtonItems ?? []
    items.insert(item, at: 0) // Prepend instead of append to ensure visibility
    target.navigationItem.rightBarButtonItems = items
    
    NSLog("[EeveeSpotify] Button injected. Items count: \(items.count)")
}

// （`SettingsViewController` / `RootSettingsViewController` 两条老入口已于 2026-10-02 删除。）


class SettingsListViewControllerHook: ClassHook<UIViewController> {
    typealias Group = UniversalSettingsIntegrationListVCGroup
    static let targetName = "_TtC21Settings_PlatformImpl26SettingsListViewController"

    func viewDidLoad() {
        orig.viewDidLoad()
        injectEeveeButton(into: target)
    }

    func viewWillAppear(_ animated: Bool) {
        orig.viewWillAppear(animated)
        injectEeveeButton(into: target)
    }

    func viewDidLayoutSubviews() {
        orig.viewDidLayoutSubviews()
        injectEeveeInlineRow(into: target)
    }
}

private let eeveeInlineRowTag = 1338
private let eeveeInlineRowHeight: CGFloat = 68
private let eeveeInlineRowTitle = "EeveeSpotify"

func injectEeveeInlineRow(into vc: UIViewController) {
    // Each Spotify page sits in a MusicAppPageHostingViewController wrapper; the list VC is its child.
    // Inject only when this VC's enclosing wrapper is the earliest wrapper containing a SettingsListViewController.
    guard let stack = vc.navigationController?.viewControllers,
          let listClass = NSClassFromString("_TtC21Settings_PlatformImpl26SettingsListViewController") else { return }
    let enclosing = enclosingStackVC(of: vc, in: stack)
    let rootSettingsHost = stack.first { subtreeContains($0, ofClass: listClass) }
    guard let enclosing = enclosing, enclosing === rootSettingsHost else { return }
    guard let cv = findFirstCollectionView(in: vc.view) else {
        NSLog("[EeveeSpotify] inlineRow: no UICollectionView in view tree")
        return
    }
    if cv.viewWithTag(eeveeInlineRowTag) != nil { return }

    let row = UIButton(type: .custom)
    row.tag = eeveeInlineRowTag
    row.backgroundColor = .clear
    row.frame = CGRect(x: 0, y: -eeveeInlineRowHeight, width: cv.bounds.width, height: eeveeInlineRowHeight)
    row.autoresizingMask = [.flexibleWidth]

    let textWidth = cv.bounds.width - 60
    let title = UILabel(frame: CGRect(x: 20, y: 12, width: textWidth, height: 20))
    title.text = eeveeInlineRowTitle
    title.textColor = .white
    title.font = UIFont.systemFont(ofSize: 16)
    title.autoresizingMask = [.flexibleWidth]
    row.addSubview(title)

    let subtitle = UILabel(frame: CGRect(x: 20, y: 34, width: textWidth, height: 18))
    subtitle.text = "eevee_inline_subtitle_text".localized
    subtitle.textColor = UIColor(white: 1.0, alpha: 0.6)
    subtitle.font = UIFont.systemFont(ofSize: 13)
    subtitle.autoresizingMask = [.flexibleWidth]
    row.addSubview(subtitle)

    let chevron = UIImageView(image: UIImage(systemName: "chevron.right"))
    chevron.tintColor = UIColor(white: 1.0, alpha: 0.55)
    chevron.contentMode = .scaleAspectFit
    let chevSize: CGFloat = 14
    chevron.frame = CGRect(
        x: cv.bounds.width - 20 - chevSize,
        y: (eeveeInlineRowHeight - chevSize) / 2,
        width: chevSize,
        height: chevSize
    )
    chevron.autoresizingMask = [.flexibleLeftMargin]
    row.addSubview(chevron)

    let separator = UIView(frame: CGRect(
        x: 20,
        y: eeveeInlineRowHeight - 0.5,
        width: cv.bounds.width - 20,
        height: 0.5
    ))
    separator.backgroundColor = UIColor(white: 1.0, alpha: 0.08)
    separator.autoresizingMask = [.flexibleWidth]
    row.addSubview(separator)

    row.addAction(UIAction { [weak vc] _ in
        guard let vc = vc else { return }
        pushEeveeSettings(from: vc)
    }, for: .touchUpInside)

    cv.addSubview(row)

    var inset = cv.contentInset
    inset.top += eeveeInlineRowHeight
    cv.contentInset = inset
    var indicator = cv.verticalScrollIndicatorInsets
    indicator.top += eeveeInlineRowHeight
    cv.verticalScrollIndicatorInsets = indicator
    cv.setContentOffset(CGPoint(x: 0, y: -inset.top), animated: false)

    NSLog("[EeveeSpotify] Injected inline EeveeSpotify row into Settings list")
}

private func enclosingStackVC(of vc: UIViewController, in stack: [UIViewController]) -> UIViewController? {
    var cur: UIViewController? = vc
    while let c = cur {
        if stack.contains(where: { $0 === c }) { return c }
        cur = c.parent
    }
    return nil
}

private func subtreeContains(_ root: UIViewController, ofClass cls: AnyClass) -> Bool {
    if type(of: root) == cls { return true }
    for child in root.children {
        if subtreeContains(child, ofClass: cls) { return true }
    }
    return false
}

private func findFirstCollectionView(in view: UIView) -> UICollectionView? {
    if let cv = view as? UICollectionView { return cv }
    for sub in view.subviews {
        if let found = findFirstCollectionView(in: sub) { return found }
    }
    return nil
}

private func pushEeveeSettings(from vc: UIViewController) {
    guard let nav = vc.navigationController else { return }
    let host = EeveeSettingsViewController(
        vc.view.bounds,
        settingsView: AnyView(EeveeSettingsView(navigationController: nav)),
        navigationTitle: "EeveeSpotify"
    )

    let subButton = UIButton(type: .system)
    if let bundleImage = BundleHelper.shared.uiImage("hex"), bundleImage.size != .zero {
        subButton.setImage(bundleImage.withRenderingMode(.alwaysOriginal), for: .normal)
    } else {
        subButton.setImage(UIImage(systemName: "globe"), for: .normal)
    }
    subButton.tintColor = .white
    subButton.addAction(UIAction { [weak host] _ in
        host?.openRepositoryUrl(subButton)
    }, for: .touchUpInside)

    let menuBarItem = UIBarButtonItem(customView: subButton)
    menuBarItem.customView?.heightAnchor.constraint(equalToConstant: 22).isActive = true
    menuBarItem.customView?.widthAnchor.constraint(equalToConstant: 22).isActive = true
    host.navigationItem.rightBarButtonItem = menuBarItem

    nav.pushViewController(host, animated: true)
}

