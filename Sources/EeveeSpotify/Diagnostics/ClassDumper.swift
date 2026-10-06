import Foundation
import ObjectiveC.runtime

/// 把任意**对象 / 类**摊开写进调试日志：类名 + 方法表 + ivar 表（含类型编码）。
///
/// ## 为什么需要它
///
/// 这个仓库的界面工作反复卡在同一句话上：**"这个视图/控制器到底是谁、有哪些成员"**
/// —— AMOLED 的导航栏、隐藏某个区块、播放器手势都卡过。
/// `ViewTreeDumper` 给的是**视图树**（谁在谁里面），答不了"某个类里有哪些方法 / ivar"。
///
/// 用法（一行）：
/// ```swift
/// ClassDumper.dump("navBar", someView)          // 有活对象
/// ClassDumper.dump("tabBar", class: someClass)  // 只有类
/// ```
///
/// ## 三条纪律（与 `EeveeProbes` 那种"什么都打"的探针**不一样**）
///
/// 1. **只读**：只用 runtime 的反射 API **枚举**，**绝不调用**找到的 selector。
///    猜 `value(forKey:)` 的键、键不存在时会抛**不可捕获**的 NSException ⇒ 直接把 Spotify
///    搞崩（本仓库吃过这个亏，见 `EeveeProbes` 那段注释）。
/// 2. **有界**：只处理这一次调用传进来的那个对象 / 类，**不做全类枚举**。
/// 3. 走 `writeDebugLog`：自带脱敏，且只在「启用日志记录」打开时才写；不进系统控制台
///    （`NSLog` 的东西进不了我们导出的那个日志文件）。
enum ClassDumper {

    /// 转储一个**活对象**的类。
    ///
    /// ⚠️ 用 `object_getClass` 而不是 `type(of:)`：前者拿的是**真实类**（KVO / 私有子类都能
    /// 看对），后者在 Swift 里会拿到静态类型那层。
    static func dump(_ label: String, _ object: AnyObject?) {
        guard let object else {
            writeDebugLog("[Dump] \(label): object is nil")
            return
        }
        guard let cls = object_getClass(object) else {
            writeDebugLog("[Dump] \(label): object_getClass returned nil")
            return
        }
        dump(label, class: cls)
    }

    /// 转储一个**类本身**（还没有活实例、或者实例拿不到时用）。
    static func dump(_ label: String, class cls: AnyClass?) {
        guard let cls else {
            writeDebugLog("[Dump] \(label): class is nil")
            return
        }

        writeDebugLog("[Dump] \(label): class=\(NSStringFromClass(cls))")

        var methodCount: UInt32 = 0
        if let methods = class_copyMethodList(cls, &methodCount) {
            var names: [String] = []
            names.reserveCapacity(Int(methodCount))
            for index in 0..<Int(methodCount) {
                names.append(NSStringFromSelector(method_getName(methods[index])))
            }
            free(methods)
            writeDebugLog("[Dump] \(label): methods=\(names.sorted())")
        }

        var ivarCount: UInt32 = 0
        if let ivars = class_copyIvarList(cls, &ivarCount) {
            var names: [String] = []
            names.reserveCapacity(Int(ivarCount))
            for index in 0..<Int(ivarCount) {
                let name = ivar_getName(ivars[index]).map { String(cString: $0) } ?? "?"
                let type = ivar_getTypeEncoding(ivars[index]).map { String(cString: $0) } ?? "?"
                names.append("\(name):\(type)")
            }
            free(ivars)
            writeDebugLog("[Dump] \(label): ivars=\(names)")
        }
    }

    /// 按**类名**转储（「调试」页那个输入框用）。
    ///
    /// 类名两种写法都收：运行期名（`_TtC23NavigationUI_TabBarImpl10TabBarView`）或
    /// 点号记法（`NavigationUI_TabBarImpl.TabBarView`）—— 后者是我们日志里更常见的写法。
    static func dump(name rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            writeDebugLog("[Dump] no class name given")
            return
        }
        guard let cls = NSClassFromString(name) else {
            writeDebugLog("[Dump] \(name): not registered in this Spotify build")
            return
        }
        dump(name, class: cls)
    }
}
