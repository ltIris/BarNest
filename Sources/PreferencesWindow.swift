import AppKit

/**
 * @Author lt_xiaoyi
 * @Description 偏好设置：勾选要合并的 App，拖动调整顺序。
 * @Version 1.0
 */
@MainActor
final class PreferencesWindow: NSWindowController {
    static let shared = PreferencesWindow()

    private let selectedTable = NSTableView()
    private let selectedScroll = NSScrollView()
    private let candidateTable = NSTableView()
    private let candidateScroll = NSScrollView()
    private let searchField = NSSearchField()
    private var selected: [TrackedItem] = []
    private var candidates: [TrackedItem] = []
    /**
     * 打开窗口时扫描一次的完整图标快照（可见 + 溢出区）。
     * 搜索、拨开关、拖动排序都基于这份缓存，不再重复做全量 AX 扫描——
     * 那是之前「开关很卡」的根因（每拨一次要扫两遍菜单栏 + 重建整个表格）。
     */
    private var catalog: [TrackedItem] = []
    private var onChanged: (() -> Void)?
    private weak var hintLabel: NSTextField?
    private var refreshTimer: Timer?

    // 右侧候选列表列宽。开关按此宽度右对齐，并留出 18pt 右边距，
    // 避免开关贴着窗口边缘、整列显得拥挤。
    private static let candidateColumnWidth: CGFloat = 400
    private static let margin: CGFloat = 24
    private static let leftColumnWidth: CGFloat = 300

    private init() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 560),
                           styleMask: [.titled, .closable, .miniaturizable],
                           backing: .buffered, defer: false)
        win.title = "BarNest 偏好设置"
        // 用户常在其他 App 的全屏 Space 里点菜单栏，窗口若不跟随，
        // 会开在别的桌面，看起来就是「点了偏好设置没反应」。
        win.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        super.init(window: win)
        buildUI()

        // 窗口开着时也要跟上菜单栏变化：App 启动/退出立刻同步，
        // 另外每 3 秒轻量复查一次（App 可以随时增删状态项，不一定有启停通知）。
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(appListChanged),
                       name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        nc.addObserver(self, selector: #selector(appListChanged),
                       name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.mergeNewIcons() }
        }
        // 授权回来 / 从别的 App 切回来时立刻做一次深度扫描，不用等定时器。
        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidActivate),
            name: NSApplication.didBecomeActiveNotification, object: nil)
    }

    // 窗口可见时被激活 → 重新深度扫描一次（授权状态可能刚变）。
    @objc private func appDidActivate() {
        guard window?.isVisible == true else { return }
        rescanCatalog()
        reload()
    }

    private var tick = 0

    /**
     * 未授权时右侧列表读不到任何菜单栏图标（只剩已合并项），必须在界面上讲清楚，
     * 否则会让人以为「右边不支持实时刷新」。
     */
    private func updateHint() {
        if MenuBarScanner.isTrusted {
            hintLabel?.stringValue = "开关打开 = 收进工作台（从菜单栏隐藏）；关闭 = 留在菜单栏。列表每 2 秒自动刷新，系统图标（Wi-Fi / 蓝牙 / 播放 / 时钟等）从不参与收纳。"
            hintLabel?.textColor = .secondaryLabelColor
        } else {
            hintLabel?.stringValue = "⚠️ 未获得辅助功能授权，右侧暂时读不到菜单栏图标（只显示已收纳项）。点「窗口操作权限…」授权后会自动刷新。"
            hintLabel?.textColor = .systemOrange
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(onChanged: @escaping () -> Void) {
        self.onChanged = onChanged
        rescanCatalog()
        reload()
        updateHint()
        // 每次打开都从列表顶部开始：列表会随菜单栏增删行，停在旧位置
        // 就会出现「第一行被裁一半」的错觉。
        scrollBothToTop()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.center()
        // 布局完成后（窗口真正上屏）再滚一次才有效。
        DispatchQueue.main.async { [weak self] in self?.scrollBothToTop() }
    }

    private func scrollBothToTop() {
        for scroll in [selectedScroll, candidateScroll] {
            let clip = scroll.contentView
            clip.scroll(to: .zero)
            scroll.reflectScrolledClipView(clip)
        }
    }

    /**
     * 只在窗口打开时做一次深度扫描（含被收进溢出区的图标）。
     * 已退出的 App 一律不列入：否则关掉软件后它的图标还留在列表里，像删不掉一样。
     */
    private func rescanCatalog() {
        catalog = IconStore.candidates(includeHidden: true).filter {
            !NSRunningApplication.runningApplications(withBundleIdentifier: $0.bundleID).isEmpty
        }
    }

    /**
     * 窗口开着时同步新增/退出的图标。列表只在内容真的变化时才重建，
     * 避免频繁 reloadData 打断 NSSwitch 的切换动画（开关卡顿的老问题）。
     */
    private func mergeNewIcons() {
        guard window?.isVisible == true else { return }
        updateHint()
        tick += 1
        // 深度扫描会真的展开 « 溢出菜单，频繁做会让菜单栏闪，所以平时只轻扫；
        // 每 30 秒补一次深扫，把被挤进溢出区的图标也读出来。
        let deep = tick % 15 == 0
        let fresh = IconStore.candidates(includeHidden: deep)
        guard !fresh.isEmpty else { return }   // 未授权 / 扫描失败：保持现状
        let freshIDs = Set(fresh.map(\.bundleID))
        var changed = false

        // 新增：菜单栏上新出现的图标（新开的 App、App 新增状态项）
        for item in fresh where !catalog.contains(item) {
            catalog.append(item)
            changed = true
        }
        // 更新：名称或图标变了（App 改名、换了图标）
        for item in fresh {
            guard let i = catalog.firstIndex(of: item) else { continue }
            let cur = catalog[i]
            if cur.name != item.name || cur.icon !== item.icon {
                catalog[i] = item
                changed = true
            }
        }
        // 移除：已退出、且当前扫描也读不到
        let before = catalog.count
        catalog.removeAll { item in
            !freshIDs.contains(item.bundleID)
                && NSRunningApplication.runningApplications(withBundleIdentifier: item.bundleID).isEmpty
        }
        if catalog.count != before { changed = true }

        if changed { reload() }
    }

    /**
     * App 启停是最需要「立刻刷新」的时刻：新开的 App 图标会被收纳进溢出区，
     * 轻量扫描读不到，所以这里直接做一次深度扫描（频率很低，不会闪菜单栏）。
     */
    @objc private func appListChanged() {
        guard window?.isVisible == true else { return }
        rescanCatalog()
        reload()
    }

    // 手动刷新：做一次深度扫描，把被收进溢出区 / 被系统自动隐藏的图标也读出来。
    @objc private func refreshCatalog() {
        rescanCatalog()
        reload()
        updateHint()
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        let title = NSTextField(labelWithString: "当前菜单栏图标 · 决定是否收纳")
        title.font = .boldSystemFont(ofSize: 15)
        title.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(title)

        let hint = NSTextField(labelWithString: "开关打开 = 收进工作台（从菜单栏隐藏）；关闭 = 留在菜单栏。列表每 2 秒自动刷新，系统图标（Wi-Fi / 蓝牙 / 播放 / 时钟等）从不参与收纳。")
        self.hintLabel = hint
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(hint)

        // 已选列表（可拖动排序）
        selectedTable.rowHeight = 42
        selectedTable.headerView = nil
        selectedTable.dataSource = self
        selectedTable.delegate = self
        selectedTable.allowsMultipleSelection = false
        selectedTable.registerForDraggedTypes([.string])
        selectedTable.draggingDestinationFeedbackStyle = .gap
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("sel"))
        col.width = Self.leftColumnWidth
        selectedTable.addTableColumn(col)
        selectedTable.style = .plain
        selectedTable.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        selectedScroll.documentView = selectedTable
        selectedScroll.hasVerticalScroller = true
        // 关掉自动内边距：它会按安全区塞一段顶部 inset，把第一行顶出可视范围，
        // 看起来就像「列表第一行被标题栏吃掉一半」。
        selectedScroll.automaticallyAdjustsContentInsets = false
        // 顶部留 14pt：macOS 26 的 NSTableView 会把首行压到 clip 上沿，
        // 视觉上就像「第一行被搜索框裁掉一半」。留白同时让列表更透气。
        selectedScroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 6, right: 0)
        selectedScroll.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(selectedScroll)

        let selLabel = NSTextField(labelWithString: "已合并（拖动排序）")
        selLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        selLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(selLabel)

        // 候选列表
        candidateTable.rowHeight = 42
        candidateTable.headerView = nil
        candidateTable.dataSource = self
        candidateTable.delegate = self
        let col2 = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("cand"))
        col2.width = Self.candidateColumnWidth
        candidateTable.addTableColumn(col2)
        candidateTable.style = .plain
        candidateTable.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        candidateScroll.documentView = candidateTable
        candidateScroll.hasVerticalScroller = true
        candidateScroll.automaticallyAdjustsContentInsets = false
        candidateScroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 6, right: 0)
        candidateScroll.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(candidateScroll)

        let candLabel = NSTextField(labelWithString: "当前菜单栏图标（开关切换收纳）")
        candLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        candLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(candLabel)

        searchField.placeholderString = "搜索 App"
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.target = self
        searchField.action = #selector(searchChanged)
        content.addSubview(searchField)

        let removeBtn = NSButton(title: "移除选中", target: self, action: #selector(removeSelected))
        removeBtn.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(removeBtn)

        let refreshBtn = NSButton(title: "刷新图标", target: self, action: #selector(refreshCatalog))
        refreshBtn.bezelStyle = .rounded
        refreshBtn.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(refreshBtn)

        let doneBtn = NSButton(title: "完成", target: self, action: #selector(done))
        doneBtn.bezelStyle = .rounded
        doneBtn.keyEquivalent = "\r"
        doneBtn.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(doneBtn)

        let permBtn = NSButton(title: "窗口操作权限…", target: self, action: #selector(requestAX))
        permBtn.bezelStyle = .rounded
        permBtn.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(permBtn)

        let m = Self.margin
        let rightW = Self.candidateColumnWidth
        let rightLeading = -(m + rightW)

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: m),

            hint.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),
            hint.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: m),
            hint.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -m),

            selLabel.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 20),
            selLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: m),
            candLabel.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 20),
            candLabel.leadingAnchor.constraint(equalTo: content.trailingAnchor, constant: rightLeading),

            searchField.topAnchor.constraint(equalTo: candLabel.bottomAnchor, constant: 10),
            searchField.leadingAnchor.constraint(equalTo: content.trailingAnchor, constant: rightLeading),
            searchField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -m),
            searchField.heightAnchor.constraint(equalToConstant: 26),

            selectedScroll.topAnchor.constraint(equalTo: selLabel.bottomAnchor, constant: 10),
            selectedScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: m),
            selectedScroll.widthAnchor.constraint(equalToConstant: Self.leftColumnWidth),
            selectedScroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -66),

            candidateScroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 26),
            candidateScroll.leadingAnchor.constraint(equalTo: content.trailingAnchor, constant: rightLeading),
            candidateScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -m),
            candidateScroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -66),

            removeBtn.topAnchor.constraint(equalTo: selectedScroll.bottomAnchor, constant: 16),
            removeBtn.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: m),
            refreshBtn.topAnchor.constraint(equalTo: selectedScroll.bottomAnchor, constant: 16),
            refreshBtn.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: m + 100),
            permBtn.topAnchor.constraint(equalTo: selectedScroll.bottomAnchor, constant: 16),
            permBtn.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: m + 200),
            doneBtn.topAnchor.constraint(equalTo: candidateScroll.bottomAnchor, constant: 16),
            doneBtn.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -m),
            doneBtn.widthAnchor.constraint(equalToConstant: 88),
        ])
    }

    private static func isRunning(_ item: TrackedItem) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: item.bundleID).isEmpty
    }

    private func reload() {
        // 左侧「已合并」必须把用户操作过的全部列出来（含当前没运行的），
        // 否则关掉一个 App 后它就从排序列表里消失了，看起来像"合并丢了"。
        selected = IconConfig.shared.workbenchItems(fromCatalog: catalog, includeInactive: true)
        /**
         * 右侧「当前菜单栏图标」只列**此刻真的在运行**的 App：
         * 以前这里会把左侧配置过的项无条件补进来，结果一堆早就退出的软件
         * 也显示在「当前菜单栏图标」里，像是它们都在后台跑着。
         */
        var list = catalog.filter(Self.isRunning)
        for item in selected where Self.isRunning(item) && !list.contains(item) {
            list.append(item)
        }
        let query = searchField.stringValue.lowercased()
        candidates = list.filter { item in
            query.isEmpty || item.name.lowercased().contains(query) || item.bundleID.lowercased().contains(query)
        }
        selectedTable.reloadData()
        candidateTable.reloadData()
        // 列宽跟着可视区走：窗口里的垂直滚动条会吃掉 17pt，
        // 列宽若固定 400，表格就比可视区宽 —— 开关正好被右边裁掉一截。
        candidateTable.sizeLastColumnToFit()
        selectedTable.sizeLastColumnToFit()
        clampScrollOffsets()
    }

    /**
     * 表格重排后 clip 原点可能停在负值上（弹性滚动残留 / 行数变化），
     * 表现就是「第一行被标题栏裁掉一半」。这里把它拉回顶部对齐。
     */
    private func clampScrollOffsets() {
        for scroll in [selectedScroll, candidateScroll] {
            let clip = scroll.contentView
            guard clip.bounds.origin.y < 0 else { continue }
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: 0))
            scroll.reflectScrolledClipView(clip)
        }
    }

    @objc private func searchChanged() { reload() }

    @objc private func removeSelected() {
        let row = selectedTable.selectedRow
        guard row >= 0, row < selected.count else { return }
        let item = selected[row]
        IconConfig.shared.remove(item.bundleID)
        IconConfig.shared.setCollapsed(item.bundleID, on: false)
        var ids = IconConfig.shared.selectedBundleIDs
        ids.removeAll { $0 == item.bundleID }
        IconConfig.shared.selectedBundleIDs = ids
        NotificationCenter.default.post(name: .notchCollapseChanged, object: nil)
        reload()
        onChanged?()
    }

    @objc private func done() { window?.close() }

    // 自测：把窗口内容离屏渲染成 PNG（不依赖屏幕录制权限，也不受当前 Space 影响）。
    func debugSnapshot(to path: String) {
        if let win = window, let v = win.contentView {
            var info = "window=\(win.frame)\ncontent=\(v.frame)\n"
            info += "search=\(searchField.frame)\n"
            info += "candScroll=\(candidateScroll.frame)\n"
            info += "  clipBounds=\(candidateScroll.contentView.bounds) docFrame=\(candidateScroll.documentView?.frame ?? .zero)\n"
            info += "  tableBounds=\(candidateTable.bounds) colW=\(candidateTable.tableColumns.first?.width ?? -1) rows=\(candidateTable.numberOfRows)\n"
            info += "selScroll=\(selectedScroll.frame) clipBounds=\(selectedScroll.contentView.bounds)\n"
            for (i, it) in candidates.prefix(6).enumerated() {
                info += "  cand[\(i)] \(it.bundleID) collapsed=\(IconConfig.shared.isCollapsed(it.bundleID)) name=\(it.name)\n"
            }
            try? info.write(toFile: "/tmp/notchtool-prefs-geo.txt", atomically: true, encoding: .utf8)
        }
        guard let view = window?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    @objc private func requestAX() {
        let alert = NSAlert()
        alert.messageText = "辅助功能权限"
        alert.informativeText = "收纳图标、弹出原菜单、窗口位置操作（半屏/最大化等）都需要此权限。点「打开系统设置」会直接跳到授权页面，勾选 BarNest 后回到 App 即可。"
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "好")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            Self.openAccessibilitySettings()
        }
    }

    /**
     * 直达「辅助功能」授权页（macOS 27 里这页叫「设备控制和数据访问」）。
     *
     * 打开后必须再激活一次 System Settings：窗口会开在鼠标所在那块屏，
     * 而且可能是非前台的，用户看起来就像「点了没反应」。
     */
    static func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            NSRunningApplication
                .runningApplications(withBundleIdentifier: "com.apple.systempreferences")
                .first?
                .activate(options: [.activateAllWindows])
        }
    }
}

extension PreferencesWindow: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === selectedTable ? selected.count : candidates.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = tableView === selectedTable ? selected[row] : candidates[row]
        let cell = NSTableCellView()
        let rowH: CGFloat = 42
        let isCandidate = tableView === candidateTable

        // 图标垂直居中，左右留白更宽松。
        let iv = NSImageView(frame: NSRect(x: 10, y: (rowH - 26) / 2, width: 26, height: 26))
        iv.image = item.icon
        iv.imageScaling = .scaleProportionallyUpOrDown
        cell.addSubview(iv)

        let textX: CGFloat = 46
        let switchTrailing: CGFloat = 20
        // 开关尺寸交给 NSSwitch 自己算：macOS 26/27 把它做大了，硬编码 40×22
        // 会把它画成被裁一半的方块，看起来就是「开关溢出到窗口外」。
        let probe = NSSwitch()
        probe.sizeToFit()
        let switchW = probe.frame.width
        let switchH = probe.frame.height
        // cell 宽度 = 列宽（列会随表格自动拉伸），不能用旧常量硬算。
        let cellW = tableColumn?.width ?? tableView.bounds.width
        let textW = isCandidate
            ? max(120, cellW - textX - switchW - switchTrailing - 10)
            : max(120, cellW - textX - 16)
        let isRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: item.bundleID).isEmpty
        let displayName = (!isCandidate && !isRunning) ? "\(item.name)（未运行）" : item.name
        let tf = NSTextField(labelWithString: displayName)
        tf.frame = NSRect(x: textX, y: (rowH - 18) / 2, width: textW, height: 18)
        tf.lineBreakMode = .byTruncatingTail
        tf.font = .systemFont(ofSize: 13)
        if !isCandidate && !isRunning { tf.textColor = .secondaryLabelColor }
        cell.addSubview(tf)

        if isCandidate {
            // 开关右对齐并留出 16pt 右边距，不再贴着窗口边缘。
            let switchX = cellW - switchW - switchTrailing
            let toggle = NSSwitch(frame: NSRect(x: switchX,
                                                y: (rowH - switchH) / 2,
                                                width: switchW,
                                                height: switchH))
            toggle.state = IconConfig.shared.isCollapsed(item.bundleID) ? .on : .off
            toggle.target = self
            toggle.action = #selector(candidateSwitchChanged(_:))
            toggle.tag = row
            cell.addSubview(toggle)
        }
        cell.imageView = iv
        cell.textField = tf
        return cell
    }

    @objc private func candidateSwitchChanged(_ sender: NSSwitch) {
        let row = sender.tag
        guard row >= 0, row < candidates.count else { return }
        let item = candidates[row]
        // 开关 on = 收纳该图标；off = 恢复显示。改变后立即生效。
        IconConfig.shared.setCollapsed(item.bundleID, on: sender.state == .on)
        NotificationCenter.default.post(name: .notchCollapseChanged, object: nil)
        // 只刷新左侧「已合并」列表，让用户立刻看到收纳结果（拨开就出现、关掉就消失）。
        // 右侧表格绝不 reload：销毁正在做动画的 NSSwitch 正是「开关很卡」的根因。
        selected = IconConfig.shared.workbenchItems(fromCatalog: catalog, includeInactive: true)
        selectedTable.reloadData()
        onChanged?()
    }

    // 拖动排序
    func tableView(_ tableView: NSTableView, writeRowsWith rowIndexes: IndexSet, to pboard: NSPasteboard) -> Bool {
        guard tableView === selectedTable, let row = rowIndexes.first else { return false }
        pboard.setString(String(row), forType: .string)
        return true
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        guard tableView === selectedTable else { return [] }
        return operation == .above ? .move : []
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard tableView === selectedTable,
              let str = info.draggingPasteboard.string(forType: .string),
              let from = Int(str), from < selected.count else { return false }
        var order = selected.map(\.bundleID)
        let moved = order.remove(at: from)
        var to = row
        if from < to { to -= 1 }
        order.insert(moved, at: max(0, min(to, order.count)))
        IconConfig.shared.selectedBundleIDs = order
        reload()
        onChanged?()
        return true
    }
}
