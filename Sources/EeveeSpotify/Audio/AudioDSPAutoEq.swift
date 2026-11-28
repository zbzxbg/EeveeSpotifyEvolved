import Foundation

/// 导入的 AutoEq 参数均衡档。
///
/// 盘上只存文本（`ParametricEQ.txt` 原文）与文件名：解析规则以后会改，存原文能用新规则
/// 重读；读不出来时按"没装"处理，回到两个架式 + 十段的默认链，不会把半截曲线留在链上。
///
/// 这一层只做存储与解析，系数与实时线程在 `AudioDSP` 里。
enum AudioDSPAutoEq {

    /// 上一次导入是否失败（设置页据此显示一行提示）。成功或移除后清空。
    private(set) static var lastImportFailed = false

    /// 已经装上的档名；`nil` = 没装。
    static var name: String? { UserDefaults.dspAutoEqName }

    static var hasProfile: Bool { name != nil }

    /// 启动与设置改动后接上当前该生效的那条自定义链：图形均衡优先，其次 AutoEq 档。
    /// `AudioDSP.syncWithSettings()` 会调它，重复调用没有副作用。
    static func applyStoredChain() {
        if UserDefaults.dspGraphicEQEnabled {
            AudioDSP.applyChain(AudioDSPGraphicEQ.chain(gains: UserDefaults.dspGraphicEQGains))
            return
        }
        guard let text = UserDefaults.dspAutoEqText else {
            AudioDSP.applyChain(nil)
            return
        }
        AudioDSP.applyChain(AudioDSPFilterChain.autoeq(text))
    }

    /// 导入一份 AutoEq 文本。解析成功才落盘并接到链上。
    @discardableResult
    static func importProfile(text: String, name: String) -> Bool {
        guard let chain = AudioDSPFilterChain.autoeq(text) else {
            lastImportFailed = true
            return false
        }
        lastImportFailed = false
        UserDefaults.dspAutoEqText = text
        UserDefaults.dspAutoEqName = name
        AudioDSP.applyChain(chain)
        return true
    }

    static func removeProfile() {
        lastImportFailed = false
        UserDefaults.dspAutoEqText = nil
        UserDefaults.dspAutoEqName = nil
        AudioDSP.applyChain(nil)
    }
}
