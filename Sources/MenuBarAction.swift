import AppKit
import ApplicationServices

/**
 * @Author lt_xiaoyi
 * @Description 复刻 iBar 的核心交互：点击面板里的图标时，对该 App 真实的菜单栏项做 AXPress，
 * 从而弹出 App 原本的菜单（例如 Logitech G HUB 的设备/配置文件菜单）。
 * @Version 1.0
 */
enum MenuBarAction {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    // 触发指定 App 菜单栏状态项的原始菜单。成功返回 true。
    //
    // macOS 27 上图标由 MenuBarAgent 统一合成，所以首选「在 MenuBarAgent 的 AX 树里
    // 按 PID 找到该 App 的图标按钮」——空文本图标（微信/Pane/QQ 等）也能精确命中。
    // 找不到再回退到 App 自己的 AXExtrasMenuBar。
    @discardableResult
    static func pressMenuBarItem(for bundleID: String) -> Bool {
        guard isTrusted else { return false }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return false }

        if let item = itemInMenuBarAgent(for: app.processIdentifier), press(item) { return true }
        if let item = itemInOwnExtrasMenuBar(app), press(item) { return true }
        return false
    }

    // 按 AXIdentifier 触发 MenuBarAgent 托管的系统菜单项（时钟 / 控制中心 / 蓝牙 / Wi-Fi…）。
    //
    // 这条通路的意义：它**不需要放开收纳断言**。以前点时钟要走「临时释放断言 → 重放鼠标事件」，
    // 一放开，被收走的 18 个图标全回到菜单栏，菜单栏被撑爆就冒出 « 溢出箭头。
    // AXPress 是直接给元素发动作，跟鼠标事件是两条路，实测在断言生效时也能触发。
    @discardableResult
    static func pressSystemMenuExtra(identifier: String) -> Bool {
        guard isTrusted else { return false }
        guard let agent = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.MenuBarAgent"
        }) else { return false }
        let axAgent = AXUIElementCreateApplication(agent.processIdentifier)
        AXUIElementSetMessagingTimeout(axAgent, 0.6)
        for window in children(axAgent) {
            for group in children(window) {
                for leaf in children(group) where string(leaf, "AXIdentifier") == identifier {
                    if press(leaf) { return true }
                }
            }
        }
        return false
    }

    // 在 MenuBarAgent 窗口树里，找到归属该 PID 的菜单栏图标元素。
    private static func itemInMenuBarAgent(for pid: pid_t) -> AXUIElement? {
        guard let agent = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.MenuBarAgent"
        }) else { return nil }
        let axAgent = AXUIElementCreateApplication(agent.processIdentifier)
        AXUIElementSetMessagingTimeout(axAgent, 0.4)
        for window in children(axAgent) {
            for group in children(window) {
                for leaf in children(group) {
                    let role = string(leaf, kAXRoleAttribute)
                    guard role == "AXButton" || role == "AXMenuBarItem" else { continue }
                    var p: pid_t = 0
                    AXUIElementGetPid(leaf, &p)
                    if p == pid { return leaf }
                }
            }
        }
        return nil
    }

    // 回退：App 自己的 AXExtrasMenuBar 状态项。
    private static func itemInOwnExtrasMenuBar(_ app: NSRunningApplication) -> AXUIElement? {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 0.3)
        var barRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXExtrasMenuBarAttribute as CFString, &barRef) == .success,
              let raw = barRef, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        let bar = raw as! AXUIElement
        return children(bar).first
    }

    // MARK: - 触发

    private static func press(_ item: AXUIElement) -> Bool {
        var actions: CFArray?
        guard AXUIElementCopyActionNames(item, &actions) == .success,
              let names = actions as? [String], names.contains("AXPress") else { return false }
        return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
    }

    private static func children(_ el: AXUIElement) -> [AXUIElement] {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &ref) == .success else { return [] }
        return ref as? [AXUIElement] ?? []
    }

    private static func string(_ el: AXUIElement, _ attr: String) -> String {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success, let raw = v else { return "" }
        return (raw as? String) ?? ""
    }

    private static func size(_ el: AXUIElement) -> CGSize {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &v) == .success,
              let raw = v, CFGetTypeID(raw) == AXValueGetTypeID() else { return .zero }
        var s = CGSize.zero
        return AXValueGetValue(raw as! AXValue, .cgSize, &s) ? s : .zero
    }
}
