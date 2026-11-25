import AppKit
import ServiceManagement

/**
 * @Author lt_xiaoyi
 * @Description 菜单栏按钮 + 自定义面板。
 * 收纳：MenuBarBridge 让系统把第三方图标收进 « 菜单；
 * 展示：面板里只展示用户在偏好设置里勾选、排序好的 App 图标。
 * @Version 1.0
 */
@MainActor
final class StatusBarController: NSObject {
    private let toggleItem: NSStatusItem
    private let panel = PopupPanel()
    // 收纳状态统一由协调器持有，避免多处状态不一致。
    private var isRestricted: Bool { MenuBarAssertionCoordinator.shared.restricted }
    private var outsideClickMonitor: Any?
    // 工作台点开原菜单时的临时借用监控。
    private var menuCloseMonitor: Any?
    private var menuCloseTimer: Timer?
    // 面板可见时的实时刷新定时器；工作台内容快照，避免内容没变也重建面板。
    private var refreshTimer: Timer?
    private var lastWorkbenchIDs: [String] = []

    override init() {
        toggleItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        if let button = toggleItem.button {
            button.image = Self.symbol("square.grid.2x2")
            button.target = self
            button.action = #selector(toggleClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel("BarNest 工作台")
        }

        // 若还没辅助功能权限，主动弹一次系统授权（精确读取菜单栏图标必需）。
        if !MenuBarScanner.isTrusted {
            MenuBarScanner.requestPermission()
        }
        // 工作台数据源是「实时扫描 + 已收纳集合」，不再用硬编码的持久化名单。
        // 关键：绝不把当前扫描结果写死成配置——那会把假图标/一次性状态固化下来。
        // 顺手清掉历史版本误塞进收纳名单里的系统项（实时活动），它不属于这份名单。
        IconConfig.shared.purgeSystemEntries()
        IconConfig.shared.purgeLegacyStandIn()

        NotificationCenter.default.addObserver(
            self, selector: #selector(openPreferences), name: .notchOpenPreferences, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(collapseChanged), name: .notchCollapseChanged, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(liftEnded), name: .notchLiftEnded, object: nil
        )

        // 安全网：⌥⌘R 强制恢复；⌥⌘N 打开/关闭面板（按钮找不到也能用）。
        HotKeyMonitor.shared.install(
            onRestore: { [weak self] in MainActor.assumeIsolated { self?.forceRestore() } },
            onPanel: { [weak self] in MainActor.assumeIsolated { self?.togglePanel() } }
        )

        // 系统项点击中继：点时钟 / 控制中心时临时借用「无断言」状态，
        // 让通知中心组件能正常弹出；面板关闭后由中继自己归还。
        SystemItemClickBridge.shared.install()

        // 收纳态下的「正在播放」放进了工作台（常驻、不可关）——
        // 菜单栏那颗系统项被 assessment mode 连根拔掉，仿一颗永远是假的。

        // 重启后按已保存的收纳集合恢复状态。否则会出现「工作台里列着已收纳图标，
        // 但菜单栏上它们也还在」的不一致。无辅助功能授权时绝不自动收纳（避免误伤系统图标）。
        //
        // 时序刻意提前：App 刚启动时还没有断言，菜单栏上是「全部图标」，放不下就会冒出
        // « 溢出箭头。所以 250ms 就先收一次，再在 1.25s 校准后重建一次。
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self else { return }
            // 先校准系统扩展区边界，再决定收纳集合——否则「正在播放/实时活动」会被误判成第三方。
            self.calibrateSystemZone()
            guard MenuBarScanner.isTrusted, !self.effectiveHidden().isEmpty else { return }
            self.rebuildAllowList()
            try? await Task.sleep(for: .seconds(1.0))
            self.calibrateSystemZone()
            if self.isRestricted { self.rebuildAllowList() } else { self.setRestricted(true) }
            try? await Task.sleep(for: .seconds(1.0))
            self.dumpDiagnosticsOnce()
        }

        // 启动 4 秒后无条件导出一次真实菜单栏数据（不依赖收纳状态），
        // 用于确认「正在播放 / 实时活动」到底归谁、以及系统区边界是否取对。
        Timer.scheduledTimer(withTimeInterval: 4.0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.calibrateSystemZone()
                var extra: [String] = []
                extra.append("systemZoneMinX=\(MenuBarScanner.systemZoneMinX)")
                extra.append("ownButtonMinX=\(self.toggleItem.button?.window?.frame.minX ?? -1)")
                NSLog("BarNest AX %@", extra.joined(separator: " | "))
                self.dumpDiagnosticsOnce()
            }
        }

        // App 启动/退出时立刻刷新工作台与收纳白名单，不用重新打开面板。
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(appListChanged),
                       name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        nc.addObserver(self, selector: #selector(appListChanged),
                       name: NSWorkspace.didTerminateApplicationNotification, object: nil)

        // 菜单栏图标变化不一定伴随 App 启停（App 可随时增删状态项），
        // 面板打开期间每 2 秒轻量复查一次工作台内容。
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshIfVisible() }
        }

        // 白名单是「激活那一刻的快照」。macOS 27 的「正在播放 / 隔空播放」等
        // 控制中心模块是动态出现的：开始播放音乐时才加入菜单栏，此时没有 App
        // 启停事件，旧白名单会把它们挡在溢出区里，看起来就是「系统图标丢了」。
        // 低频（30s）复查；协调器带签名去重，内容没变时完全不碰断言，
        // 既不占 CPU 也不会让菜单栏闪。
        allowListTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAllowListIfNeeded() }
        }

        // 记住「最近一次被用户点开的是哪个音乐 App」。多个播放器同时开着、又都
        // 暂停时，NSWorkspace 给的运行列表顺序不保证，只有这个信号能挑对人。
        NowPlayingEntry.startTracking()

        // 调试钩子：往 /tmp/notchtool-debug 写关键字控制（生产环境没有这个文件，完全无副作用）。
        //  - panel：启动 3 秒后自动打开工作台（没有模拟点击权限时用来截图核对面板）
        //  - click：完整走一遍「点时间」链路（放开断言 → 重放 → 面板 → 归还 → 收敛校验）
        applyDebugHooks()
    }

    private var allowListTimer: Timer?

    // 调试钩子：文件触发的自动化脚本，只用于「没有模拟点击权限」时自测。
    private func applyDebugHooks() {
        guard let raw = try? String(contentsOfFile: "/tmp/notchtool-debug", encoding: .utf8) else { return }
        let flags = raw.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }

        func logGeo(_ tag: String) {
            let g = MenuBarScanner.geometry()
            let line = String(format: "geo[%@] items=%d leftmost=%.0f overflow=%@\n",
                              tag, g.itemCount, g.leftmostX, g.hasOverflow ? "YES" : "no")
            NSLog("BarNest DEBUG %@", line)
            if let h = FileHandle(forWritingAtPath: "/tmp/notchtool-geo.txt") {
                h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile()
            } else {
                try? line.write(toFile: "/tmp/notchtool-geo.txt", atomically: true, encoding: .utf8)
            }
        }
        func click(_ p: CGPoint) {
            CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                    mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
            usleep(80_000)
            CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                    mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        }

        if flags.contains("dump") {
            // 自测：把此刻扫描到的菜单栏图标（名字 + bundleID）落到文件里。
            let list = MenuBarScanner.scanAllIcons()
            let text = list.map { "\($0.name)\t\($0.bundleID)" }.joined(separator: "\n")
            try? text.write(toFile: "/tmp/notchtool-dump.txt", atomically: true, encoding: .utf8)
        }
        if flags.contains("npinfo") {
            // 自测：把「正在播放」这一格最终解析成谁、为什么，落到文件里。
            // 截图不可用时靠它核对判定链路。
            let it = NowPlayingEntry.item()
            let defaults = UserDefaults.standard
            let text = """
            name=\(it.name)
            hasIcon=\(it.icon != nil)
            isPlaying=\(NowPlayingEntry.isPlayingNow)
            lastPlayed=\(defaults.string(forKey: "notchtool.lastPlayedBundleID") ?? "nil")
            lastActivatedMusic=\(defaults.string(forKey: "notchtool.lastActivatedMusic") ?? "nil")
            recent=\(defaults.stringArray(forKey: "notchtool.recentPlayers")?.joined(separator: ",") ?? "nil")
            """
            try? text.write(toFile: "/tmp/notchtool-npinfo.txt", atomically: true, encoding: .utf8)
        }
        if flags.contains("npdemo") {
            // 自测：强制横条显示「正在播放」的样子（不真的去动用户的播放器）。
            NowPlayingEntry.forcePlayingDemo = true
        }
        if flags.contains("panel") {
            Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.openPanel() }
            }
            // 1 秒后把面板的真实状态写出来，用来确认「到底开没开、开在哪」。
            Timer.scheduledTimer(withTimeInterval: 4.0, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let p = self.panel
                    let text = "visible=\(p.isVisible)\nframes=\(p.frame)\nlevel=\(p.level.rawValue)\nscreens=\(NSScreen.screens.count)\n"
                    try? text.write(toFile: "/tmp/notchtool-panel.txt", atomically: true, encoding: .utf8)
                }
            }
        }
        if flags.contains("prefs") {
            Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.openPreferences() }
            }
            Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { _ in
                MainActor.assumeIsolated {
                    PreferencesWindow.shared.debugSnapshot(to: "/tmp/notchtool-prefs.png")
                }
            }
        }
        if flags.contains("geo") {
            // 只量一次菜单栏几何（含 « 溢出箭头是否存在），不点任何东西。
            Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { _ in
                MainActor.assumeIsolated {
                    logGeo("probe")
                    NSLog("BarNest NP collapsed=\(IconConfig.shared.collapsedIDs.count) restricted=\(MenuBarAssertionCoordinator.shared.restricted)")
                }
            }
        }
        if flags.contains("toggle") {
            // 收纳一次再放开，观察 « 溢出箭头会不会自己回来。
            Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.setRestricted(true) }
            }
            Timer.scheduledTimer(withTimeInterval: 6.0, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.setRestricted(false) }
            }
            Timer.scheduledTimer(withTimeInterval: 9.0, repeats: false) { _ in
                MainActor.assumeIsolated { logGeo("after-toggle") }
            }
        }
        if flags.contains("clickcell") {
            // 完整复刻用户操作：打开工作台 → 点「正在播放」横条。
            Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.openPanel() }
            }
            Timer.scheduledTimer(withTimeInterval: 5.5, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let p = self?.panel.debugNowPlayingBarCenter() else { return }
                    let screenH = NSScreen.screens.first?.frame.height ?? 0
                    // NS 坐标（左下原点）→ Quartz 坐标（左上原点）
                    click(CGPoint(x: p.x, y: screenH - p.y))
                }
            }
        }
        if flags.contains("nowplaying") {
            // 自测：不点界面，直接走一遍「工作台正在播放」的唤起链路。
            Timer.scheduledTimer(withTimeInterval: 4.0, repeats: false) { _ in
                MainActor.assumeIsolated { NowPlayingEntry.activate() }
            }
        }
        if flags.contains("click") {
            logGeo("start")
            // 点时间（Quartz 坐标：时钟中心 1425,14）
            Timer.scheduledTimer(withTimeInterval: 6.0, repeats: false) { _ in
                MainActor.assumeIsolated { click(CGPoint(x: 1425, y: 14)) }
            }
            Timer.scheduledTimer(withTimeInterval: 8.0, repeats: false) { _ in
                MainActor.assumeIsolated {
                    logGeo("panel-open")
                    // 关键验收点：收纳态下点时钟，通知中心 / 组件面板到底有没有弹出来。
                    let vis = SystemItemClickBridge.systemPanelVisible()
                    try? "panelVisible=\(vis)".write(toFile: "/tmp/notchtool-systempanel.txt",
                                                     atomically: true, encoding: .utf8)
                }
            }
            // 点桌面空白关闭面板，观察能否自动收回去
            Timer.scheduledTimer(withTimeInterval: 10.0, repeats: false) { _ in
                MainActor.assumeIsolated { click(CGPoint(x: 200, y: 800)) }
            }
            Timer.scheduledTimer(withTimeInterval: 14.0, repeats: false) { _ in
                MainActor.assumeIsolated { logGeo("after-close") }
            }
        }
    }


    /**
     * 只在收纳态、且没有正在借用「无断言」状态时复查白名单。
     *
     * assessment mode 的白名单是激活那一刻的快照，动态出现的模块（正在播放 /
     * 实时活动）需要靠「白名单内容变化」触发重建才能进快照。协调器内部按内容
     * 签名去重，所以内容没变时这里完全不碰断言——不占 CPU、也不会闪菜单栏。
     */
    private func refreshAllowListIfNeeded() {
        calibrateSystemZone()
        guard isRestricted, !MenuBarAssertionCoordinator.shared.isLifted else { return }
        let hidden = effectiveHidden()
        guard !hidden.isEmpty else { return }
        // 保底收敛：万一之前的归还被系统忽略（见 verifyCollapse），这里再补一次。
        MenuBarAssertionCoordinator.shared.verify(hidden: hidden)
        // 只在白名单内容真的变了才重建断言。
        // 以前这里无条件 forceReapply，等于每 15 秒让 MenuBarAgent 重排一次菜单栏，
        // 既白费 CPU，也会把实时活动这种宽组件挤进溢出区 —— 得不偿失。
        MenuBarAssertionCoordinator.shared.updateAllowList(Self.buildAllowList(hidden: hidden))
    }

    // MARK: - 收纳收敛校验

    private var verifyTimer: Timer?
    private var verifyTicks = 0

    @objc private func liftEnded() { startCollapseVerify() }

    /**
     * 归还断言后校验「被收走的图标是不是真的回到溢出区了」。
     *
     * 必须做：系统面板（时间组件 / 控制中心）还开着时，MenuBarAgent 会**忽略**收缩请求，
     * 菜单栏就停在「全部展开 + «」。这里每 0.7 秒看一次，面板一关就立刻重放断言，
     * 最多盯 20 次（约 14 秒），收干净就停 —— 空闲时完全不动。
     */
    private func startCollapseVerify() {
        guard isRestricted else { return }
        verifyTicks = 0
        verifyTimer?.invalidate()
        verifyTimer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.verifyTick() }
        }
    }

    private func verifyTick() {
        verifyTicks += 1
        guard isRestricted, MenuBarAssertionCoordinator.shared.isLifted == false else {
            verifyTimer?.invalidate(); verifyTimer = nil; return
        }
        // 面板还开着时系统必然拒绝收缩，别白费力气，等它关掉。
        if SystemItemClickBridge.systemPanelVisible() {
            if verifyTicks > 20 { verifyTimer?.invalidate(); verifyTimer = nil }
            return
        }
        let hidden = effectiveHidden()
        let clean = MenuBarAssertionCoordinator.shared.verify(hidden: hidden)
        if clean || verifyTicks > 20 {
            verifyTimer?.invalidate()
            verifyTimer = nil
        }
    }

    /**
     * 启动后无条件导出一份菜单栏真实数据（一次性），用于定位
     * 「正在播放 / 实时活动」这类动态模块的归属，避免盲改。
     * 只扫可见项，不打开溢出菜单，避免打扰。
     */
    func dumpDiagnosticsOnce() {
        var lines: [String] = []
        lines.append("time=\(Date())")
        lines.append("restricted=\(isRestricted)")
        lines.append("isTrusted=\(MenuBarScanner.isTrusted)")
        lines.append("collapsed=\(IconConfig.shared.collapsedIDs.sorted().joined(separator: ","))")
        let real = MenuBarScanner.scanRealIcons()
        lines.append("--- scanRealIcons (\(real.count)) ---")
        for it in real { lines.append("  \(it.bundleID) | \(it.name)") }
        // 工作台实际会画出来的内容（含系统常驻项），排查「收纳了却不显示」用。
        let bench = IconConfig.shared.workbenchItems()
        lines.append("--- 工作台 (\(bench.count)) ---")
        for it in bench { lines.append("  \(it.bundleID) | \(it.name)") }
        let live = MenuBarScanner.liveMenuBarBundleIDs()
        lines.append("--- liveMenuBarBundleIDs (\(live.count)) ---")
        lines.append("  " + live.sorted().joined(separator: "\n  "))
        lines.append("--- 当前白名单 (\(MenuBarBridge.shared.currentAllowList?.count ?? -1)) ---")
        if let al = MenuBarBridge.shared.currentAllowList {
            lines.append("  " + al.joined(separator: "\n  "))
        }
        let text = lines.joined(separator: "\n")
        NSLog("BarNest DIAG\n%@", text)
        try? text.write(toFile: "/tmp/notchtool-diag.txt", atomically: true, encoding: .utf8)
        let alt = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Logs/BarNest-diag.txt")
        try? text.write(toFile: alt, atomically: true, encoding: .utf8)
    }

    @objc private func appListChanged() {
        refreshIfVisible()
        // 白名单是激活那一刻的快照：新启动的 App 若不在里面，图标会被系统藏进溢出区。
        // 所以每次 App 启停都要按当前状态重建一次。
        if isRestricted { rebuildAllowList() }
    }

    private func togglePanel() {
        panel.isVisible ? closePanel() : openPanel()
    }

    // 强制恢复：释放断言、复位状态。供热键与退出路径调用。
    private func forceRestore() {
        clearMenuWatch()
        verifyTimer?.invalidate()
        verifyTimer = nil
        SystemItemClickBridge.shared.setEnabled(false)
        MenuBarAssertionCoordinator.shared.restore()
        updateIcon()
        closePanel()
    }

    @objc private func toggleClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
            return
        }
        panel.isVisible ? closePanel() : openPanel()
    }

    private func openPanel() {
        // 工作台 = 用户已收纳的图标（且 App 仍在运行）。不依赖当前菜单栏显示状态，
        // 也不需要每次展开溢出区做深度扫描——打开更快、不会闪菜单。
        let selected = panelItems()
        lastWorkbenchIDs = selected.map(\.bundleID)
        panel.configure(items: selected) { [weak self] item in self?.activate(item) }
        // 用点击时的鼠标位置判断在哪块屏，并把面板弹在菜单栏按钮旁边。
        let screen = ScreenLocator.screenForMenuBarClick() ?? NSScreen.main ?? NSScreen.screens.first
        let anchorX = ScreenLocator.menuBarItemCenterX()
        if let screen { panel.show(on: screen, anchorX: anchorX) }
        installOutsideClickMonitor()
    }

    /**
     * 点击面板图标：临时把该 App 的图标放回菜单栏 → 等它布局稳定 →
     * 再做 AXPress 弹出原菜单。这样菜单锚点是菜单栏上的真实位置，
     * 不会像以前那样因为图标藏在溢出区、AX 坐标为 (0,0) 而弹到屏幕左上角。
     */
    private func activate(_ item: TrackedItem) {
        let bid = item.bundleID
        // 常驻的「正在播放」不是真的 App 图标：借一次断言 → AXPress 真正的系统项，
        // 弹出系统原生播放面板。先收起工作台，免得两块面板叠在一起。
        if NowPlayingEntry.isPinned(bid) {
            closePanel()
            NowPlayingEntry.activate()
            return
        }
        let coordinator = MenuBarAssertionCoordinator.shared
        // 只有处于收纳态才需要临时放回；未收纳时图标本来就在菜单栏上。
        let needsLift = isRestricted && !MenuBarBridge.isSystemOwned(bid)
        if needsLift { coordinator.beginTemporaryAllow(bid) }

        Task { @MainActor [weak self] in
            guard let self else { return }
            // 等 MenuBarAgent 按新白名单重新布局，图标回到菜单栏。
            try? await Task.sleep(nanoseconds: needsLift ? 180_000_000 : 30_000_000)
            let pressed = MenuBarAction.pressMenuBarItem(for: bid)
            if !pressed { IconStore.launch(item) }
            if needsLift { self.restoreAfterMenu(bid: bid, pressed: pressed) }
        }
    }

    /**
     * 原菜单弹出后，等用户操作完（点击别处 / 关闭菜单 / 超时）再把图标收回。
     * 期间保持临时借用，避免菜单刚弹出就被收进溢出区导致窗口跳走。
     */
    private func restoreAfterMenu(bid: String, pressed: Bool) {
        clearMenuWatch()
        // AXPress 失败时没有菜单可等，立刻归还。
        guard pressed else {
            MenuBarAssertionCoordinator.shared.endTemporaryAllow(bid)
            return
        }
        menuCloseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .keyDown]
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                // 延迟一点，等这次点击把菜单真正关掉。
                self?.menuCloseTimer?.invalidate()
                self?.menuCloseTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated { self?.finishMenu(bid: bid) }
                }
            }
        }
        // 硬兜底：任何情况下 8 秒内必须归还，防止图标永久留在菜单栏。
        menuCloseTimer = Timer.scheduledTimer(withTimeInterval: 8.0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.finishMenu(bid: bid) }
        }
    }

    private func finishMenu(bid: String) {
        clearMenuWatch()
        MenuBarAssertionCoordinator.shared.endTemporaryAllow(bid)
    }

    private func clearMenuWatch() {
        if let monitor = menuCloseMonitor { NSEvent.removeMonitor(monitor); menuCloseMonitor = nil }
        menuCloseTimer?.invalidate()
        menuCloseTimer = nil
    }

    private func closePanel() {
        panel.orderOut(nil)
        removeOutsideClickMonitor()
    }

    @objc private func openPreferences() {
        closePanel()
        PreferencesWindow.shared.show { [weak self] in
            self?.refreshIfVisible()
        }
    }

    /**
     * 工作台内容 = 已收纳的图标 + 末尾那一格「播放器」。
     * 播放器格和标题下的横条同时存在：横条给状态，格子保留 App 原来的图标位置。
     */
    private func panelItems() -> [TrackedItem] {
        IconConfig.shared.workbenchItems() + [NowPlayingEntry.item()]
    }

    private func refreshIfVisible() {
        guard panel.isVisible else { return }
        // 横条内容独立刷新：换歌 / 换播放器时名字和图标要跟着变。
        panel.updateNowPlaying()
        let selected = panelItems()
        // 播放器那一格的名字会跟着「谁在放歌」变，名字也算进签名。
        let ids = selected.map { item in
            NowPlayingEntry.isPinned(item.bundleID) ? "\(item.bundleID):\(item.name)" : item.bundleID
        }
        // 内容没变就不重建：定时刷新时避免闪烁、打断拖拽或右键菜单。
        guard ids != lastWorkbenchIDs else { return }
        lastWorkbenchIDs = ids
        panel.configure(items: selected) { [weak self] item in self?.activate(item) }
        // 不重新 show()：定时刷新时鼠标可能已移走，按鼠标位置重定位会让面板跳到别的屏幕。
    }

    // MARK: - 收纳 / 恢复

    /**
     * 白名单 = 运行中 App ∪ 菜单栏上真实归属（含系统项 / 输入法 / 后台 agent）
     *          ∪ alwaysAllowed − 用户要收纳的第三方图标。
     * 关键：必须显式包含「此刻真的在菜单栏上的系统项」，否则激活断言时
     * 系统自带的「正在播放」等图标会被一起收走。
     */
    private static func buildAllowList(hidden: Set<String>) -> [String] {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })
        let live = MenuBarScanner.liveMenuBarBundleIDs()
        // 系统区里的动态模块（正在播放 / 实时活动 / 隔空播放）会带着发起它的
        // 第三方 App 的 bundleID，必须强制放行，否则收纳该 App 的图标时会把
        // 这些系统模块一起藏掉。
        let systemZone = MenuBarScanner.systemZoneBundleIDs()
        return running.union(live).union(systemZone).union(MenuBarBridge.alwaysAllowed)
            .subtracting(hidden.subtracting(systemZone)).sorted()
    }

    /**
     * 真正允许收纳的集合：用户勾选的 − 系统项 − 系统区动态模块。
     * 系统区里的动态模块（正在播放 / 隔空播放）绝不能被藏。
     */
    private func effectiveHidden() -> Set<String> {
        let systemZone = MenuBarScanner.systemZoneBundleIDs()
        return Set(IconConfig.shared.collapsedIDs.filter {
            !MenuBarBridge.isSystemOwned($0) && !systemZone.contains($0)
        })
    }

    /**
     * 校准系统区边界（自己状态栏按钮右侧 = 系统区）。
     * 重新测量系统扩展区（menu extras）左边界。
     *
     * 早先是拿「自己状态栏按钮的 x」当边界，纯属想当然：系统并不保证第三方
     * 状态项都排在我们左边，实测 BarNest 的按钮就排在微信左边，于是微信、
     * 飞书被当成系统区直接消失。现在改为实测：所有 `com.apple.menuextra.*`
     * 项里最靠左的那个 x 才是真正的边界。
     */
    private func calibrateSystemZone() {
        let measured = MenuBarScanner.measureSystemZoneMinX()
        if measured < .greatestFiniteMagnitude {
            MenuBarScanner.systemZoneMinX = measured
        }
    }

    /**
     * 白名单是激活那一刻的快照，App 启停 / 开关变化后必须重建，
     * 否则新出现的图标会被旧白名单挡在溢出区里，看起来就是「不会更新新增内容」。
     */
    private func rebuildAllowList() {
        guard MenuBarScanner.isTrusted else { return }
        let hidden = effectiveHidden()
        guard !hidden.isEmpty else {
            forceRestore()
            return
        }
        let allowList = Self.buildAllowList(hidden: hidden)
        if isRestricted {
            MenuBarAssertionCoordinator.shared.updateAllowList(allowList)
        } else {
            MenuBarAssertionCoordinator.shared.restrict(allowList: allowList)
            updateIcon()
            SystemItemClickBridge.shared.setEnabled(true)
        }
    }

    private func setRestricted(_ enabled: Bool) {
        if enabled {
            // 收纳依赖 AX 精确扫描。没有辅助功能授权时绝不能执行——
            // 否则私有断言会把系统图标（AirPlay/蓝牙等）连同第三方一起藏掉，
            // 而用户根本不知道为什么。先引导授权再重试。
            guard MenuBarScanner.isTrusted else {
                MenuBarScanner.requestPermission()
                showAlert("需要先授权辅助功能",
                          "收纳会操作真实的菜单栏图标，必须先授予辅助功能权限。\n请在「系统设置 → 隐私与安全性 → 辅助功能」勾选 BarNest，然后重试。")
                return
            }
            let hiddenIDs = effectiveHidden()
            guard !hiddenIDs.isEmpty else {
                showAlert("还没有选择要收纳的图标",
                          "请先在「偏好设置」里把要收纳的图标开关打开，再执行收纳。\n系统自带图标（播放 / 蓝牙 / Wi-Fi / 时钟等）永不参与收纳。")
                return
            }
            let allowList = Self.buildAllowList(hidden: hiddenIDs)
            NSLog("BarNest 收纳：隐藏 \(hiddenIDs.count) 个，白名单 \(allowList.count) 个")
            MenuBarAssertionCoordinator.shared.restrict(allowList: allowList) { [weak self] error in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let error {
                        self.showAlert("收纳失败", error.localizedDescription)
                        return
                    }
                    self.updateIcon()
                    self.closePanel()
                    SystemItemClickBridge.shared.setEnabled(true)
                    self.dumpDiagnosticsOnce()
                }
            }
        } else {
            forceRestore()
        }
    }

    private func updateIcon() {
        toggleItem.button?.image = Self.symbol(isRestricted ? "square.grid.2x2.fill" : "square.grid.2x2")
    }

    // MARK: - 右键菜单

    private func showMenu() {
        let menu = NSMenu()
        let open = NSMenuItem(title: "打开工作台", action: #selector(openPanelFromMenu), keyEquivalent: "n")
        open.target = self
        open.keyEquivalentModifierMask = [.option, .command]
        menu.addItem(open)

        menu.addItem(.separator())
        let prefs = NSMenuItem(title: "偏好设置…", action: #selector(openPreferences), keyEquivalent: ",")
        prefs.target = self
        menu.addItem(prefs)
        // 只统计「真的会被收走」的图标：系统项不算，它们永远留在菜单栏。
        let count = IconConfig.shared.collapsedIDs.filter {
            !MenuBarBridge.isSystemOwned($0)
        }.count
        let toggle = NSMenuItem(title: isRestricted ? "恢复菜单栏图标（或按 ⌥⌘R）" : "收纳已选图标（\(count) 个）",
                                action: #selector(toggleRestrict), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)
        menu.addItem(.separator())
        let ax = NSMenuItem(title: WindowManager.shared.isTrusted ? "窗口操作权限：已开启 ✓" : "开启窗口操作权限…",
                            action: #selector(requestAX), keyEquivalent: "")
        ax.target = self
        menu.addItem(ax)
        let diag = NSMenuItem(title: "诊断信息…", action: #selector(showDiagnostics), keyEquivalent: "")
        diag.target = self
        menu.addItem(diag)
        let login = NSMenuItem(title: "开机启动", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出 BarNest", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.autoenablesItems = false
        toggleItem.menu = menu
        toggleItem.button?.performClick(nil)
        toggleItem.menu = nil
    }

    // 偏好设置里拨动收纳开关后立即生效：已经在收纳态则按新集合重建白名单。
    @objc private func collapseChanged() {
        let hidden = effectiveHidden()
        if !isRestricted {
            // 从非收纳态拨开了第一个开关 → 自动进入收纳态
            if !hidden.isEmpty { setRestricted(true) }
            return
        }
        if hidden.isEmpty {
            // 全部开关关掉 → 恢复全部图标
            forceRestore()
            return
        }
        rebuildAllowList()
        refreshIfVisible()
    }

    /**
     * 点「开启窗口操作权限」= 直接跳到授权页。
     *
     * 不要用 `AXIsProcessTrustedWithOptions(prompt:)`：那个系统提示只在
     * 「从未授权过」时弹一次；一旦系统里已经有本 App 的记录、只是开关被关掉，
     * 它什么都不做，用户看到的就是「点了没反应」。
     */
    @objc private func requestAX() { PreferencesWindow.openAccessibilitySettings() }
    @objc private func openPanelFromMenu() { openPanel() }
    @objc private func toggleRestrict() { setRestricted(!isRestricted) }

    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch { NSLog("开机启动设置失败：\(error)") }
    }

    @objc private func showDiagnostics() {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let screens = NSScreen.screens.enumerated().map { i, s in
            "屏幕\(i + 1): \(Int(s.frame.width))x\(Int(s.frame.height)) origin=(\(Int(s.frame.minX)),\(Int(s.frame.minY)))\(s === NSScreen.main ? " [主屏]" : "")"
        }.joined(separator: "\n")
        let lines = [
            "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            "隐藏接口：\(MenuBarBridge.shared.isAvailable ? "可用" : "不可用")",
            "窗口操作权限：\(WindowManager.shared.isTrusted ? "已开启" : "未开启")",
            "当前状态：\(isRestricted ? "已收纳" : "未收纳")",
            "已选图标：\(IconConfig.shared.selectedBundleIDs.count) 个",
            screens,
        ]
        showAlert("BarNest 诊断", lines.joined(separator: "\n"))
    }

    private func showAlert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: - 点击外部关闭

    private func installOutsideClickMonitor() {
        removeOutsideClickMonitor()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            // 点菜单栏区域（含我们的按钮）时不要在这里关闭，
            // 交给按钮自己的 action 做 toggle，否则「再点一次关闭」会被抢先执行成开启。
            if let self, ScreenLocator.isInMenuBar(event.locationInWindow) {
                return
            }
            MainActor.assumeIsolated { self?.closePanel() }
        }
    }

    private func removeOutsideClickMonitor() {
        if let monitor = outsideClickMonitor { NSEvent.removeMonitor(monitor); outsideClickMonitor = nil }
    }

    func cleanup() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        allowListTimer?.invalidate()
        allowListTimer = nil
        verifyTimer?.invalidate()
        verifyTimer = nil
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        SystemItemClickBridge.shared.setEnabled(false)
        clearMenuWatch()
        MenuBarAssertionCoordinator.shared.restore()
        removeOutsideClickMonitor()
    }

    private static func symbol(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        image?.isTemplate = true
        return image
    }
}
