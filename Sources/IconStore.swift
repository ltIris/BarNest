import AppKit

/**
 * @Author lt_xiaoyi
 * @Description 一个可收纳的菜单栏图标项。
 * @Version 1.0
 */
struct TrackedItem: Identifiable, Equatable, Hashable {
    let bundleID: String
    let name: String
    let icon: NSImage?
    var id: String { bundleID }

    static func == (lhs: TrackedItem, rhs: TrackedItem) -> Bool {
        lhs.bundleID == rhs.bundleID
    }
    func hash(into hasher: inout Hasher) { hasher.combine(bundleID) }
}

/**
 * @Author lt_xiaoyi
 * @Description 将菜单栏 Helper 进程映射到最外层应用，以显示正确的名称和图标。
 * @Version 1.0
 */
enum AppIdentity {
    /**
     * 宿主 App 的显示名与真实路径。
     *
     * 名字优先用**宿主 App 进程的 localizedName**（微信就是「微信」而不是
     * 文件名的「WeChat」），其次读宿主 bundle 的本地化名称，最后才退回路径名。
     */
    static func host(for app: NSRunningApplication) -> (name: String, url: URL)? {
        guard let url = app.bundleURL else {
            return app.localizedName.map { ($0, URL(fileURLWithPath: "/Applications")) }
        }
        let hostURL = outermostApp(startingAt: url) ?? url
        return (displayName(forAppAt: hostURL), hostURL)
    }

    // 取某个 .app 的本地化显示名。
    static func displayName(forAppAt url: URL) -> String {
        if let bundle = Bundle(url: url),
           let bid = bundle.bundleIdentifier,
           let running = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first,
           let name = running.localizedName, !name.isEmpty {
            return name
        }
        if let bundle = Bundle(url: url),
           let name = (bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String)
                        ?? (bundle.localizedInfoDictionary?["CFBundleName"] as? String)
                        ?? (bundle.infoDictionary?["CFBundleDisplayName"] as? String),
           !name.isEmpty {
            return name
        }
        return FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
    }

    /**
     * 从（可能嵌套的）`.app` 一路向上，返回最外层的那个 `.app`。
     * 普通 App（/Applications/WeChat.app）会原样返回自己。
     */
    static func outermostApp(startingAt url: URL) -> URL? {
        guard url.pathExtension == "app" else { return nil }
        var candidate = url
        var cursor = url.deletingLastPathComponent()
        while cursor.path != "/" && !cursor.path.isEmpty {
            if cursor.pathExtension == "app" { candidate = cursor }
            cursor = cursor.deletingLastPathComponent()
        }
        return candidate
    }
}

/**
 * @Author lt_xiaoyi
 * @Description 从菜单栏扫描结果收集可收纳的应用图标。
 * @Version 1.0
 */
enum IconStore {
    private static let excluded: Set<String> = [
        "com.apple.MenuBarAgent", "com.apple.controlcenter", "com.apple.systemuiserver",
        "com.apple.TextInputMenuAgent", "com.apple.notificationcenterui", "com.apple.wifi.WiFiAgent",
        "com.apple.loginwindow", "com.apple.WindowManager", "com.apple.dock",
        "com.apple.WebKit.Networking", "com.apple.CoreLocationAgent",
        "com.notchtool.app",
    ]
    private static let backgroundKeywords = ["helper", "renderer", "browser", "extension", "plugin"]

    /**
     * 面板/收纳用的真实数据源：此刻真的在菜单栏上有图标的 App（AX 扫描）。
     * 没有辅助功能权限时返回空集——绝不用「运行中的 App」兜底，
     * 否则会把备忘录/访达/Safari 这类根本不在菜单栏的软件塞进面板。
     *
     * - Parameter includeHidden: true 时额外读出被收进溢出区的图标
     *   （收纳后的、或菜单栏空间不足被系统自动隐藏的）。会临时展开溢出菜单再关闭。
     */
    static func candidates(includeHidden: Bool = false) -> [TrackedItem] {
        guard MenuBarScanner.isTrusted else { return [] }
        return includeHidden ? MenuBarScanner.scanAllIcons() : MenuBarScanner.scanRealIcons()
    }

    // 兼容旧调用：当前可作为候选的图标集合。
    static func collect() -> [TrackedItem] { candidates() }

    // 配置里记录了 bundleID 但 App 没在运行时，用已安装路径补出图标。
    static func item(forBundleID bid: String) -> TrackedItem? {
        if let running = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bid }),
           let host = AppIdentity.host(for: running) {
            return TrackedItem(bundleID: bid, name: host.name, icon: icon(for: host.url.path))
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
            let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            return TrackedItem(bundleID: bid, name: name, icon: icon(for: url.path))
        }
        return TrackedItem(bundleID: bid, name: (bid as NSString).lastPathComponent,
                           icon: NSWorkspace.shared.icon(forFile: "/Applications"))
    }

    // 供配置界面：所有已安装的 App（/Applications + 系统 Applications）。
    static func installedApps() -> [TrackedItem] {
        var seen = Set<String>()
        var result: [TrackedItem] = []
        let dirs = ["/Applications", "/System/Applications", "/System/Library/CoreServices"]
        for dir in dirs {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
            for file in files where file.hasSuffix(".app") {
                let path = (dir as NSString).appendingPathComponent(file)
                guard let bundle = Bundle(path: path),
                      let bid = bundle.object(forInfoDictionaryKey: "CFBundleIdentifier") as? String,
                      !seen.contains(bid), !excluded.contains(bid), bid != Bundle.main.bundleIdentifier else { continue }
                let lower = bid.lowercased()
                if backgroundKeywords.contains(where: { lower.contains($0) }) { continue }
                seen.insert(bid)
                let name = FileManager.default.displayName(atPath: path).replacingOccurrences(of: ".app", with: "")
                result.append(TrackedItem(bundleID: bid, name: name, icon: icon(for: path)))
            }
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func icon(for path: String?) -> NSImage? {
        guard let path else { return nil }
        return NSWorkspace.shared.icon(forFile: path)
    }

    static func launch(_ item: TrackedItem) {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: item.bundleID).first {
            app.activate()
            return
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: item.bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }
}
