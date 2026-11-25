import AppKit
import ApplicationServices

/**
 * @Author lt_xiaoyi
 * @Description 通过 MenuBarAgent 的辅助功能树读取菜单栏图标。
 * 元素可能缺少标题，因此优先使用所属进程识别应用；系统项不纳入第三方图标列表。
 * @Version 1.0
 */
enum MenuBarScanner {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /**
     * 系统扩展区的左边界，取所有 com.apple.menuextra.* 元素中最小的 x。
     * 不使用 BarNest 按钮作边界，因为它与第三方图标的相对位置可能变化。
     */
    static var systemZoneMinX: CGFloat = .greatestFiniteMagnitude

    /**
     * 重新测量系统扩展区左边界。测不到时返回无限大，等于关闭位置过滤
     * （此时仍有 pid / bundleID 两道关卡，系统项不会被误收）。
     */
    static func measureSystemZoneMinX() -> CGFloat {
        guard isTrusted else { return .greatestFiniteMagnitude }
        guard let agent = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.MenuBarAgent"
        }) else { return .greatestFiniteMagnitude }
        let axAgent = AXUIElementCreateApplication(agent.processIdentifier)
        AXUIElementSetMessagingTimeout(axAgent, 0.6)
        var minX = CGFloat.greatestFiniteMagnitude
        for leaf in menuBarButtons(axAgent) {
            guard string(leaf, "AXIdentifier").hasPrefix("com.apple.menuextra.") else { continue }
            if let x = positionX(leaf) { minX = min(minX, x) }
        }
        return minX
    }

    /**
     * 这个元素是不是落在系统扩展区里（时钟、控制中心、Wi-Fi、正在播放、实时活动…）。
     *
     * 两道判据：
     * 1. 位置 >= 系统扩展区左边界（主判据，几何事实）。
     * 2. 兜底：宽度 >= 100 且贴在屏幕最右端 —— 实时活动这类超宽胶囊即便没有
     *    `com.apple.menuextra` 标识、挂着第三方 App 的 pid，也一定不能收纳。
     */
    static func isSystemZoneElement(_ leaf: AXUIElement) -> Bool {
        guard let x = positionX(leaf) else { return false }
        if systemZoneMinX < .greatestFiniteMagnitude, x >= systemZoneMinX - 2 { return true }
        if let w = width(leaf), w >= 100, let screen = NSScreen.main,
           x >= screen.frame.width - 460 {
            return true
        }
        return false
    }

    /**
     * 位于系统区（自己按钮右侧）的那些元素的归属 bundleID。
     * 构造收纳白名单时并入，并保证这些 App 永不被收纳。
     *
     * 判定用位置而不是宽度：实时活动/正在播放这类动态模块会挂**第三方 App 的 PID**，
     * 只有「它在自己按钮右边」这一点是稳定的几何事实。
     */
    static func systemZoneBundleIDs() -> Set<String> {
        guard isTrusted, systemZoneMinX < .greatestFiniteMagnitude else { return [] }
        guard let agent = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.MenuBarAgent"
        }) else { return [] }
        let axAgent = AXUIElementCreateApplication(agent.processIdentifier)
        AXUIElementSetMessagingTimeout(axAgent, 0.6)
        var result = Set<String>()
        for leaf in menuBarButtons(axAgent) {
            guard isSystemZoneElement(leaf) else { continue }
            let p = pid(of: leaf)
            guard p > 0 else { continue }
            if let bid = NSRunningApplication(processIdentifier: p)?.bundleIdentifier {
                result.insert(bid)
            } else if p == agent.processIdentifier {
                result.insert("com.apple.MenuBarAgent")
            }
        }
        return result
    }

    /**
     * 菜单栏此刻是不是真的显示着。
     *
     * 有 App 全屏时菜单栏会自动隐藏，此时不该把任何东西画在屏幕顶端。
     * 判据很直接：系统菜单栏那一层窗口（Window Server、layer 24）还在不在屏幕上。
     */
    static func isMenuBarVisible() -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return true }
        for window in list {
            let owner = window[kCGWindowOwnerName as String] as? String ?? ""
            let layer = window[kCGWindowLayer as String] as? Int ?? -1
            let bounds = window[kCGWindowBounds as String] as? [String: Any] ?? [:]
            let height = bounds["Height"] as? Double ?? 0
            if owner == "Window Server", layer == 24, height > 10 { return true }
        }
        return false
    }

    /**
     * 菜单栏第三方图标簇里最靠左的那个 x（不含我们自己的图标）。
     *
     * 替身播放图标要贴在它的左边——那正是系统分配给新状态项的那一格。
     */
    static func leftmostItemX() -> CGFloat? {
        guard isTrusted else { return nil }
        guard let agent = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.MenuBarAgent"
        }) else { return nil }
        let axAgent = AXUIElementCreateApplication(agent.processIdentifier)
        AXUIElementSetMessagingTimeout(axAgent, 0.6)
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var minX = CGFloat.greatestFiniteMagnitude
        for leaf in menuBarButtons(axAgent) {
            if isSystemZoneElement(leaf) { continue }
            let p = pid(of: leaf)
            guard p > 0, p != ownPID, p != agent.processIdentifier else { continue }
            if let x = positionX(leaf) { minX = min(minX, x) }
        }
        return minX < .greatestFiniteMagnitude ? minX : nil
    }

    /**
     * 菜单栏上此刻是否存在指定 AXIdentifier 的系统项（例如 `com.apple.menuextra.now-playing`）。
     *
     * 收纳生效时「正在播放」会被 assessment mode 的 AV module 断言彻底移除（不是挤进
     * 溢出菜单），所以在收纳态下这个方法天然返回 false —— 正好可以用来判断
     * 「用户看不见它，需要补一颗替代图标」。
     */
    static func hasMenuExtra(identifier: String) -> Bool {
        guard isTrusted else { return false }
        guard let agent = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.MenuBarAgent"
        }) else { return false }
        let axAgent = AXUIElementCreateApplication(agent.processIdentifier)
        AXUIElementSetMessagingTimeout(axAgent, 0.5)
        for leaf in menuBarButtons(axAgent) where string(leaf, "AXIdentifier") == identifier {
            return true
        }
        return false
    }

    static func requestPermission() {        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    /**
     * 调试：把 MenuBarAgent 的菜单栏树逐项导出（角色 / 位置 / 宽度 / 归属 bundle），
     * 用来定位 « 溢出箭头到底在哪儿、宽度多少、是不是真的会被画出来。
     */
    static func debugDumpTree() -> String {
        guard isTrusted else { return "untrusted" }
        guard let agent = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.MenuBarAgent"
        }) else { return "no agent" }
        let axAgent = AXUIElementCreateApplication(agent.processIdentifier)
        AXUIElementSetMessagingTimeout(axAgent, 0.8)
        var lines: [String] = []
        for (wi, window) in children(axAgent).enumerated() {
            for (gi, group) in children(window).enumerated() {
                let gid = string(group, "AXIdentifier")
                if !gid.isEmpty { lines.append("group[\(wi)/\(gi)] id=\(gid)") }
                for leaf in children(group) {
                    let p = pid(of: leaf)
                    let bid = NSRunningApplication(processIdentifier: p)?.bundleIdentifier ?? "-"
                    let w = width(leaf) ?? -1
                    let x = positionX(leaf) ?? -1
                    let hidd = bool(leaf, "AXHidden")
                    lines.append(String(format: "  leaf role=%@ x=%.0f w=%.0f hidden=%@ pid=%d bid=%@ id=%@",
                                        string(leaf, kAXRoleAttribute), x, w, hidd ? "Y" : "n", p, bid,
                                        string(leaf, "AXIdentifier")))
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func bool(_ el: AXUIElement, _ attr: String) -> Bool {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return false }
        return (v as? Bool) ?? false
    }

    /**
     * @Author lt_xiaoyi
     * @Description 保存菜单栏图标位置和溢出状态，用于区分空间不足与收纳异常。
     * @Version 1.0
     */
    struct Geometry {
        var screenWidth: CGFloat = 0
        var leftmostX: CGFloat = .greatestFiniteMagnitude
        var itemCount = 0
        var widestItem: CGFloat = 0
        var hasOverflow = false
    }

    static func geometry() -> Geometry {
        var g = Geometry()
        if let screen = NSScreen.main { g.screenWidth = screen.frame.width }
        guard isTrusted else { return g }
        guard let agent = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.MenuBarAgent"
        }) else { return g }
        let axAgent = AXUIElementCreateApplication(agent.processIdentifier)
        AXUIElementSetMessagingTimeout(axAgent, 0.6)
        for leaf in menuBarButtons(axAgent) {
            g.itemCount += 1
            if let x = positionX(leaf) { g.leftmostX = min(g.leftmostX, x) }
            g.widestItem = max(g.widestItem, width(leaf) ?? 0)
        }
        g.hasOverflow = overflowIndicator(axAgent) != nil
        return g
    }

    // 快速扫描：只读「此刻可见」的菜单栏图标，不打扰系统（无任何 UI 弹出）。
    static func scanRealIcons() -> [TrackedItem] {
        scan(includeHidden: false)
    }

    /**
     * 深度扫描：额外把「被藏进溢出区」的图标也读出来（收纳后、或菜单栏空间不足被系统自动隐藏的）。
     * 实现方式是临时展开 MenuBarAgent 的溢出菜单、读完立刻关掉，全程约 0.3 秒。
     */
    static func scanAllIcons() -> [TrackedItem] {
        scan(includeHidden: true)
    }

    /**
     * 当前菜单栏上所有图标的归属 bundleID（含系统项、输入法、后台型 agent）。
     * 用于构造收纳白名单：只要此刻真的在菜单栏上、又不是用户要收纳的，就必须允许显示。
     * 比 NSWorkspace.runningApplications 可靠——后者不一定收录所有后台菜单栏进程，
     * 一旦漏掉，激活断言后那个图标（例如系统「正在播放」）就会被一起收走。
     */
    static func liveMenuBarBundleIDs() -> Set<String> {
        guard isTrusted else { return [] }
        guard let agent = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.MenuBarAgent"
        }) else { return [] }
        let axAgent = AXUIElementCreateApplication(agent.processIdentifier)
        AXUIElementSetMessagingTimeout(axAgent, 0.6)
        var result = Set<String>()
        for window in children(axAgent) {
            for group in children(window) {
                for leaf in children(group) {
                    let p = pid(of: leaf)
                    guard p > 0, let bid = NSRunningApplication(processIdentifier: p)?.bundleIdentifier else { continue }
                    result.insert(bid)
                }
            }
        }
        return result
    }

    // MARK: - 实现

    private static func scan(includeHidden: Bool) -> [TrackedItem] {
        guard isTrusted else { return [] }
        guard let agent = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.MenuBarAgent"
        }) else { return [] }

        let axAgent = AXUIElementCreateApplication(agent.processIdentifier)
        AXUIElementSetMessagingTimeout(axAgent, 1.0)

        var ordered: [(item: TrackedItem, x: CGFloat, hidden: Bool)] = []
        var seen = Set<String>()
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let agentPID = agent.processIdentifier

        // 收集当前树里所有可识别的第三方图标。
        func collect(hidden: Bool) {
            for leaf in menuBarButtons(axAgent) {
                let leafX = positionX(leaf)
                // 系统扩展区（时钟、控制中心、电池、Wi-Fi、蓝牙、正在播放、实时活动
                // 胶囊）一律不算第三方图标。判据是位置：>= 最靠左的系统项。
                // 微信、飞书这类第三方图标即使在系统项左边挨得很紧，也不会被误伤。
                if isSystemZoneElement(leaf) { continue }
                let pid = pid(of: leaf)
                guard pid > 0, pid != ownPID, pid != agentPID else { continue }
                guard let app = NSRunningApplication(processIdentifier: pid),
                      let bid = app.bundleIdentifier,
                      bid != Bundle.main.bundleIdentifier,
                      !bid.hasPrefix("com.apple.") else { continue }
                guard !seen.contains(bid) else { continue }
                seen.insert(bid)
                // 名字和图标都从「宿主 App」取：飞书这类由 Helper 承载状态项的
                // 情况，否则列表里会显示成「Lark Helper」而不是「飞书」。
                let host = AppIdentity.host(for: app)
                let name = host?.name ?? app.localizedName ?? (bid as NSString).lastPathComponent
                let img = host.flatMap { NSWorkspace.shared.icon(forFile: $0.url.path) }
                ordered.append((TrackedItem(bundleID: bid, name: name, icon: img),
                                leafX ?? .greatestFiniteMagnitude, hidden))
            }
        }

        collect(hidden: false)

        if includeHidden, let overflow = overflowIndicator(axAgent) {
            _ = AXUIElementPerformAction(overflow, kAXPressAction as CFString)
            usleep(220_000)              // 等溢出菜单展开
            collect(hidden: true)
            // 立刻关闭：再按一次折叠；ESC 兜底。
            _ = AXUIElementPerformAction(overflow, kAXPressAction as CFString)
            usleep(60_000)
            postEscape()
        }

        // 可见图标按菜单栏上的真实位置从左到右排序；隐藏图标排在其后。
        return ordered
            .sorted { a, b in
                if a.hidden != b.hidden { return !a.hidden }
                return a.x < b.x
            }
            .map(\.item)
    }

    // 遍历 MenuBarAgent 窗口树，取出所有 AXButton / AXMenuBarItem 图标元素。
    private static func menuBarButtons(_ axAgent: AXUIElement) -> [AXUIElement] {
        var result: [AXUIElement] = []
        for window in children(axAgent) {
            for group in children(window) {
                for leaf in children(group) {
                    let role = string(leaf, kAXRoleAttribute)
                    if role == "AXButton" || role == "AXMenuBarItem" {
                        result.append(leaf)
                    }
                }
            }
        }
        return result
    }

    // 菜单栏右侧的「显示隐藏菜单栏项目」按钮（溢出区入口）。
    private static func overflowIndicator(_ axAgent: AXUIElement) -> AXUIElement? {
        for window in children(axAgent) {
            for group in children(window) {
                if string(group, "AXIdentifier") == "menu-bar-overflow-indicator" { return group }
                for leaf in children(group) where string(leaf, "AXIdentifier") == "menu-bar-overflow-indicator" {
                    return leaf
                }
            }
        }
        return nil
    }

    private static func postEscape() {
        let down = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true)
        down?.post(tap: .cghidEventTap)
        let up = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: false)
        up?.post(tap: .cghidEventTap)
    }

    private static func children(_ el: AXUIElement) -> [AXUIElement] {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &ref) == .success else { return [] }
        return ref as? [AXUIElement] ?? []
    }

    private static func pid(of el: AXUIElement) -> pid_t {
        var p: pid_t = 0
        AXUIElementGetPid(el, &p)
        return p
    }

    private static func string(_ el: AXUIElement, _ attr: String) -> String {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success, let raw = v else { return "" }
        return (raw as? String) ?? ""
    }

    private static func width(_ el: AXUIElement) -> CGFloat? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &v) == .success,
              let raw = v, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(raw as! AXValue, .cgSize, &s) ? s.width : nil
    }

    private static func positionX(_ el: AXUIElement) -> CGFloat? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &v) == .success,
              let raw = v, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let ax = raw as! AXValue
        var p = CGPoint.zero
        return AXValueGetValue(ax, .cgPoint, &p) ? p.x : nil
    }
}
