import AppKit

/**
 * @Author lt_xiaoyi
 * @Description 原创设计的深色玻璃面板：标题栏 + 自选 App 图标网格 + 系统信息条。
 * @Version 1.0
 */
@MainActor
final class PopupPanel: NSPanel {
    private var items: [TrackedItem] = []
    private var onActivate: ((TrackedItem) -> Void)?
    private var refreshTimer: Timer?
    private var infoLabels: [Int: NSTextField] = [:]
    private var infoChips: [Int: NSView] = [:]
    private let gridHost = GridDropView()
    private let nowPlayingBar = NowPlayingBar(frame: .zero)
    private let stats = SystemStats.shared
    private let timeLabel = NSTextField(labelWithString: "")
    private let dateLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "工作台")
    private let headerDot = NSView()

    private let columns = 5
    private let cellW: CGFloat = 70
    private let cellH: CGFloat = 74
    private let headerH: CGFloat = 58
    private let footerH: CGFloat = 58
    // 横条与网格之间的空隙。
    private let barGap: CGFloat = 8

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        buildUI()
    }

    private func buildUI() {
        let effect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.appearance = NSAppearance(named: .darkAqua)
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 18
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 1
        effect.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        contentView = effect

        // 标题区（具体 y 坐标在 layout() 里按面板高度确定）
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = .white
        effect.addSubview(titleLabel)

        headerDot.wantsLayer = true
        headerDot.layer?.cornerRadius = 3.5
        headerDot.layer?.backgroundColor = NSColor.systemGreen.cgColor
        effect.addSubview(headerDot)

        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = .white.withAlphaComponent(0.55)
        effect.addSubview(countLabel)

        dateLabel.font = .systemFont(ofSize: 10)
        dateLabel.textColor = .white.withAlphaComponent(0.5)
        dateLabel.alignment = .right
        effect.addSubview(dateLabel)
        timeLabel.font = .systemFont(ofSize: 20, weight: .light)
        timeLabel.textColor = .white
        timeLabel.alignment = .right
        effect.addSubview(timeLabel)

        // 「正在播放」常驻横条：标题下方独立一行，不属于图标网格。
        // 它替代的是收纳时被系统连根拔掉的菜单栏系统项，所以没有开关、不能删。
        nowPlayingBar.onClick = { [weak self] in self?.nowPlayingTapped() }
        effect.addSubview(nowPlayingBar)

        // 图标网格容器（支持接收拖拽 reorder）
        gridHost.frame = .zero
        gridHost.columns = columns
        gridHost.cellW = cellW
        gridHost.cellH = cellH
        gridHost.onDrop = { [weak self] bundleID, toIndex in
            self?.moveItem(bundleID, to: toIndex)
        }
        effect.addSubview(gridHost)

        // 系统信息条
        let infoBar = NSView()
        infoBar.wantsLayer = true
        infoBar.layer?.cornerRadius = 10
        infoBar.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.07).cgColor
        effect.addSubview(infoBar)
        infoBar.frame = NSRect(x: 14, y: 12, width: 100, height: footerH - 20)
        self.infoBar = infoBar

        let fields: [(String, Int)] = [("处理器", 0), ("内存", 1), ("网络", 2), ("磁盘", 3)]
        for (name, idx) in fields {
            let chip = NSView(frame: .zero)
            let t = NSTextField(labelWithString: name)
            t.font = .systemFont(ofSize: 9, weight: .medium)
            t.textColor = .white.withAlphaComponent(0.55)
            t.alignment = .center
            chip.addSubview(t)
            let v = NSTextField(labelWithString: "—")
            v.font = .systemFont(ofSize: 12, weight: .semibold)
            v.textColor = .white
            v.alignment = .center
            chip.addSubview(v)
            infoLabels[idx] = v
            infoChips[idx] = chip
            infoBar.addSubview(chip)
        }

        stats.start()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        refresh()
    }

    private var infoBar: NSView = NSView()

    func configure(items: [TrackedItem], onActivate: @escaping (TrackedItem) -> Void) {
        self.items = items
        self.onActivate = onActivate
        updateNowPlaying()
        rebuildGrid()
        layout()
    }

    // 刷新横条内容（谁在放歌 / 播哪首由调用方定时喂进来）。
    func updateNowPlaying() {
        let snap = NowPlayingEntry.item()
        nowPlayingBar.update(name: snap.name, icon: snap.icon,
                             isPlaying: NowPlayingEntry.isPlayingNow)
    }

    // 点横条：先收工作台，再让系统原生的播放面板原地弹出。
    private func nowPlayingTapped() {
        orderOut(nil)
        NowPlayingEntry.activate()
    }

    private func rebuildGrid() {
        for v in gridHost.subviews { v.removeFromSuperview() }
        // 常驻的「播放器」那一格不算「已收纳的应用」，计数时剔掉。
        let realCount = items.filter { !NowPlayingEntry.isPinned($0.bundleID) }.count
        if items.isEmpty {
            if !MenuBarScanner.isTrusted {
                countLabel.stringValue = "⚠️ 需先授权 → 窗口操作权限"
            } else if IconConfig.shared.collapsedIDs.isEmpty {
                // 工作台为空不等于「菜单栏没图标」：只是还没收纳任何图标。
                countLabel.stringValue = "尚未收纳 · 右键 → 偏好设置"
            } else {
                countLabel.stringValue = "已收纳应用未运行 → 偏好设置"
            }
        } else {
            countLabel.stringValue = "\(realCount) 个已收纳 · 点击打开原菜单"
        }

        let rows = (items.count + columns - 1) / columns
        let gridH = CGFloat(rows) * cellH
        // 关键：这里只按 gridH 计算每个格子「在网格内部」的位置，
        // gridHost 自身的 frame（尤其 origin）一律由 layout() 统一设置。
        // 以前在这里写 gridHost.frame = (0, 0, ...)，拖拽重排后不调 layout()，
        // 网格就会整体下移、最后一行压到信息条上。
        for (i, item) in items.enumerated() {
            let col = i % columns
            let row = i / columns
            let x = CGFloat(col) * cellW
            // AppKit 坐标，底部为 0：第一行在最上面
            let y = gridH - CGFloat(row + 1) * cellH
            let cell = IconCell(item: item,
                                frame: NSRect(x: x, y: y, width: cellW, height: cellH),
                                detail: nil)
            // 常驻的播放器格：跟别的格子长得一样，但不能被拖走、也没有右键菜单。
            cell.isDraggable = !NowPlayingEntry.isPinned(item.bundleID)
            cell.onActivate = { [weak self] in self?.activate(item) }
            cell.onContextMenu = { [weak self] point in self?.showItemMenu(item, from: cell, at: point) }
            gridHost.addSubview(cell)
        }
    }

    /**
     * 拖拽到位后重排：只改顺序，不动收藏状态。持久化到 IconConfig。
     *
     * 常驻的播放器格固定排在最后：它不参与重排，别的图标也插不到它后面。
     */
    private func moveItem(_ bundleID: String, to index: Int) {
        guard !NowPlayingEntry.isPinned(bundleID),
              items.contains(where: { $0.bundleID == bundleID }) else { return }
        let pinned = items.filter { NowPlayingEntry.isPinned($0.bundleID) }
        var ids = items.filter { !NowPlayingEntry.isPinned($0.bundleID) }.map(\.bundleID)
        ids.removeAll { $0 == bundleID }
        let target = max(0, min(index, ids.count))
        ids.insert(bundleID, at: target)
        IconConfig.shared.selectedBundleIDs = ids
        // 按新顺序重排当前数据并刷新（下拉顺序即新顺序）。
        items = ids.compactMap { id in self.items.first { $0.bundleID == id } } + pinned
        rebuildGrid()
        layout()   // 重排后必须重新定位网格，否则 gridHost 会掉回原点、与信息条重叠
    }

    // 调试用：横条在屏幕坐标里的中心点（自测「点横条弹出原生面板」链路）。
    func debugNowPlayingBarCenter() -> NSPoint? {
        guard nowPlayingBar.window != nil else { return nil }
        let inWindow = nowPlayingBar.convert(NSPoint(x: nowPlayingBar.bounds.midX,
                                                     y: nowPlayingBar.bounds.midY), to: nil)
        return convertPoint(toScreen: inWindow)
    }

    private func layout() {
        let rows = (items.count + columns - 1) / columns
        let usedCols = min(columns, max(1, items.count))
        let gridW = CGFloat(usedCols) * cellW
        let gridH = CGFloat(rows) * cellH
        let barH = NowPlayingBar.barHeight
        let width = max(340, gridW + 28)
        let height = headerH + barH + barGap + gridH + footerH

        // 实时刷新导致图标增减时，保持面板顶边贴着菜单栏不动，避免上下跳动。
        let savedTop = frame.maxY
        setContentSize(NSSize(width: width, height: height))
        contentView?.frame = NSRect(x: 0, y: 0, width: width, height: height)
        if savedTop > 0 {
            setFrameOrigin(NSPoint(x: frame.minX, y: savedTop - frame.height))
        }

        // 标题区固定在面板顶部（AppKit 原点左下，顶部 y = height - ...）
        headerDot.frame = NSRect(x: 16, y: height - 24, width: 7, height: 7)
        titleLabel.frame = NSRect(x: 30, y: height - 29, width: 120, height: 20)
        countLabel.frame = NSRect(x: 16, y: height - 44, width: 180, height: 14)
        timeLabel.frame = NSRect(x: width - 108, y: height - 40, width: 92, height: 28)
        dateLabel.frame = NSRect(x: width - 108, y: height - 16, width: 92, height: 14)

        // 从下往上：信息条 → 网格 → 播放横条 → 标题区。
        let gridBottom = footerH + 2
        let barBottom = gridBottom + gridH + (gridH > 0 ? barGap : 0)
        gridHost.frame = NSRect(x: 14, y: gridBottom, width: gridW, height: gridH)
        gridHost.isHidden = items.isEmpty
        nowPlayingBar.frame = NSRect(x: 14, y: barBottom, width: width - 28, height: barH)
        infoBar.frame = NSRect(x: 14, y: 12, width: width - 28, height: footerH - 20)

        // 4 个状态格子按信息条实际宽度等分，中文标签也不会挤在一起。
        let chipW = (width - 36) / 4
        for (idx, chip) in infoChips {
            chip.frame = NSRect(x: CGFloat(idx) * chipW + 10, y: 6, width: chipW, height: footerH - 30)
            if let label = chip.subviews[0] as? NSTextField {
                label.frame = NSRect(x: 0, y: chip.frame.height - 13, width: chipW, height: 12)
            }
            if let value = chip.subviews[1] as? NSTextField {
                value.frame = NSRect(x: 0, y: 0, width: chipW, height: chip.frame.height - 14)
            }
        }
    }

    // 在指定屏幕弹出，面板紧贴点击的菜单栏按钮旁边。
    func show(on screen: NSScreen, anchorX: CGFloat? = nil) {
        layout()
        let origin = ScreenLocator.origin(forPanelSize: frame.size, on: screen, anchorX: anchorX)
        setFrameOrigin(origin)
        orderFront(nil)
    }

    private func activate(_ item: TrackedItem) {
        orderOut(nil)
        onActivate?(item)
    }

    private func showItemMenu(_ item: TrackedItem, from cell: NSView, at point: NSPoint?) {
        // 常驻的「正在播放」用单独的菜单：没有「隐藏 / 退出 / 从工作台移除」——
        // 它不允许被关掉（关掉就等于又丢一次播放入口），但右键必须能用，
        // 否则用户点右键毫无反应，像是坏了。
        if NowPlayingEntry.isPinned(item.bundleID) {
            showNowPlayingMenu(item, from: cell, at: point)
            return
        }
        let menu = NSMenu()
        let app = NSRunningApplication.runningApplications(withBundleIdentifier: item.bundleID).first

        let open = NSMenuItem(title: "打开 / 激活", action: #selector(openItem), keyEquivalent: "")
        open.target = self
        open.representedObject = item
        menu.addItem(open)

        if let app, !app.isHidden {
            let hide = NSMenuItem(title: "隐藏 \(app.localizedName ?? "")", action: #selector(hideItem), keyEquivalent: "")
            hide.target = self; hide.representedObject = item
            menu.addItem(hide)
        }
        if app != nil {
            let quit = NSMenuItem(title: "退出", action: #selector(quitItem), keyEquivalent: "")
            quit.target = self; quit.representedObject = item
            menu.addItem(quit)
        }
        menu.addItem(.separator())

        let winMenu = NSMenu()
        var group = -1
        for preset in WindowPreset.allCases {
            if preset.group != group {
                if group >= 0 { winMenu.addItem(.separator()) }
                group = preset.group
            }
            let mi = NSMenuItem(title: preset.rawValue, action: #selector(windowAction), keyEquivalent: "")
            mi.target = self
            mi.representedObject = ["item": item, "preset": preset] as [String: Any]
            winMenu.addItem(mi)
        }
        if !WindowManager.shared.isTrusted {
            let tip = NSMenuItem(title: "⚠️ 需先授权辅助功能", action: #selector(openAXSettings), keyEquivalent: "")
            tip.target = self
            winMenu.addItem(.separator())
            winMenu.addItem(tip)
        }
        let winItem = NSMenuItem(title: "窗口位置", action: nil, keyEquivalent: "")
        winItem.submenu = winMenu
        menu.addItem(winItem)

        menu.addItem(.separator())
        let prefs = NSMenuItem(title: "偏好设置…", action: #selector(openPrefs), keyEquivalent: ",")
        prefs.target = self
        menu.addItem(prefs)

        // event.locationInWindow 转成 cell 局部坐标；这样点哪一列菜单就在哪一列弹出。
        let localPoint: NSPoint
        if let point, let win = cell.window {
            localPoint = cell.convert(point, from: win.contentView)
        } else {
            localPoint = NSPoint(x: cell.bounds.midX, y: cell.bounds.minY + 6)
        }
        menu.popUp(positioning: nil, at: localPoint, in: cell)
    }

    /**
     * 常驻「正在播放」格的右键菜单。
     *
     * 只放「怎么用它」的动作，不放任何开关：这一格不提供隐藏/移除。
     */
    private func showNowPlayingMenu(_ item: TrackedItem, from cell: NSView, at point: NSPoint?) {
        let menu = NSMenu()

        let openApp = NSMenuItem(title: "打开 \(item.name)", action: #selector(openNowPlayingApp), keyEquivalent: "")
        openApp.target = self
        menu.addItem(openApp)

        let openPanel = NSMenuItem(title: "打开系统播放面板", action: #selector(openNowPlayingPanel), keyEquivalent: "")
        openPanel.target = self
        menu.addItem(openPanel)

        menu.addItem(.separator())
        let prefs = NSMenuItem(title: "偏好设置…", action: #selector(openPrefs), keyEquivalent: ",")
        prefs.target = self
        menu.addItem(prefs)

        let localPoint: NSPoint
        if let point, let win = cell.window {
            localPoint = cell.convert(point, from: win.contentView)
        } else {
            localPoint = NSPoint(x: cell.bounds.midX, y: cell.bounds.minY + 6)
        }
        menu.popUp(positioning: nil, at: localPoint, in: cell)
    }

    @objc private func openNowPlayingApp() {
        orderOut(nil)
        NowPlayingEntry.openCurrentPlayer()
    }

    @objc private func openNowPlayingPanel() {
        orderOut(nil)
        NowPlayingEntry.activate()
    }

    @objc private func openItem(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? TrackedItem else { return }
        activate(item)
    }
    @objc private func hideItem(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? TrackedItem,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: item.bundleID).first else { return }
        app.hide()
    }
    @objc private func quitItem(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? TrackedItem,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: item.bundleID).first else { return }
        app.terminate()
    }
    @objc private func windowAction(_ sender: NSMenuItem) {
        guard let dict = sender.representedObject as? [String: Any],
              let item = dict["item"] as? TrackedItem, let preset = dict["preset"] as? WindowPreset else { return }
        WindowManager.shared.apply(preset, to: item.bundleID)
    }
    @objc private func requestAX() { WindowManager.shared.requestPermission() }
    @objc private func openAXSettings() { PreferencesWindow.openAccessibilitySettings() }
    @objc private func openPrefs() {
        orderOut(nil)
        NotificationCenter.default.post(name: .notchOpenPreferences, object: nil)
    }

    private func refresh() {
        infoLabels[0]?.stringValue = "\(Int(stats.cpuUsage))%"
        infoLabels[1]?.stringValue = "\(Int(stats.memoryUsed / 1024 / 1024 / 1024))%"
        infoLabels[2]?.stringValue = "↑\(Int(stats.netUp)) ↓\(Int(stats.netDown))"
        infoLabels[3]?.stringValue = "\(Int(stats.diskUsed))%"
        let f = DateFormatter(); f.dateFormat = "HH:mm"; timeLabel.stringValue = f.string(from: Date())
        let d = DateFormatter(); d.dateFormat = "M月d日 EEE"; dateLabel.stringValue = d.string(from: Date())
    }

    override func close() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        super.close()
    }
}

/**
 * @Author lt_xiaoyi
 * @Description 展示单个应用图标，并处理点击、右键菜单和拖动。
 * @Version 1.0
 */
@MainActor
final class IconCell: NSView, NSDraggingSource {
    let item: TrackedItem
    // 常驻格设 false：不参与拖拽重排。
    var isDraggable = true
    // 第二行小字（只有「正在播放」格用）。
    let detail: String?
    private var dragOrigin: NSPoint?
    var onActivate: (() -> Void)?
    var onContextMenu: ((NSPoint) -> Void)?
    private let hover = NSView()

    init(item: TrackedItem, frame: NSRect, detail: String? = nil) {
        self.item = item
        self.detail = detail
        super.init(frame: frame)
        wantsLayer = true

        hover.wantsLayer = true
        hover.layer?.cornerRadius = 12
        hover.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.0).cgColor
        hover.frame = NSRect(x: 4, y: 4, width: frame.width - 8, height: frame.height - 8)
        addSubview(hover)

        let iv = NSImageView(frame: NSRect(x: (frame.width - 40) / 2, y: frame.height - 50, width: 40, height: 40))
        iv.image = item.icon
        iv.imageScaling = .scaleProportionallyUpOrDown
        addSubview(iv)

        // 常驻的「正在播放」格多一行小字说明，否则它和普通 App 图标长得一样，
        // 用户根本看不出这一格点下去会弹系统播放面板。
        let hasDetail = detail != nil
        if hasDetail {
            iv.frame = NSRect(x: (frame.width - 34) / 2, y: frame.height - 46, width: 34, height: 34)
        }

        let name = NSTextField(labelWithString: item.name)
        name.font = .systemFont(ofSize: 10)
        name.textColor = .white.withAlphaComponent(0.85)
        name.alignment = .center
        name.lineBreakMode = .byTruncatingTail
        name.frame = NSRect(x: 2, y: hasDetail ? 17 : 8, width: frame.width - 4, height: 14)
        addSubview(name)

        if let detail {
            let sub = NSTextField(labelWithString: detail)
            sub.font = .systemFont(ofSize: 9, weight: .medium)
            sub.textColor = NSColor.systemGreen.withAlphaComponent(0.95)
            sub.alignment = .center
            sub.lineBreakMode = .byTruncatingTail
            sub.frame = NSRect(x: 2, y: 5, width: frame.width - 4, height: 11)
            addSubview(sub)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        // 记录按下位置；拖动超过阈值才发起拖拽，否则抬起视为点击。
        dragOrigin = convert(event.locationInWindow, from: nil)
    }
    override func mouseDragged(with event: NSEvent) {
        guard isDraggable else { return }
        guard let origin = dragOrigin else { return }
        let p = convert(event.locationInWindow, from: nil)
        guard hypot(p.x - origin.x, p.y - origin.y) > 6 else { return }
        dragOrigin = nil
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(item.bundleID, forType: .string)
        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
        draggingItem.setDraggingFrame(bounds, contents: item.icon)
        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }
    override func mouseUp(with event: NSEvent) {
        defer { dragOrigin = nil }
        let p = convert(event.locationInWindow, from: nil)
        if bounds.contains(p), event.buttonNumber == 0 {
            onActivate?()
        }
    }

    // MARK: NSDraggingSource
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        return .move
    }
    func draggingSession(_ session: NSDraggingSession, endedAt point: NSPoint, operation: NSDragOperation) {
        dragOrigin = nil
    }
    override func rightMouseDown(with event: NSEvent) {
        onContextMenu?(event.locationInWindow)
    }
    override func mouseEntered(with event: NSEvent) { setHover(0.12) }
    override func mouseExited(with event: NSEvent) { setHover(0.0) }
    private func setHover(_ alpha: CGFloat) {
        hover.layer?.backgroundColor = NSColor.white.withAlphaComponent(alpha).cgColor
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for t in trackingAreas { removeTrackingArea(t) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp], owner: self, userInfo: nil))
    }
}

/**
 * @Author lt_xiaoyi
 * @Description 接收图标拖动并计算网格中的目标位置。
 * @Version 1.0
 */
@MainActor
final class GridDropView: NSView {
    var columns: Int = 5
    var cellW: CGFloat = 70
    var cellH: CGFloat = 74
    var onDrop: ((String, Int) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.string])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.string(forType: .string) == nil ? [] : .move
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .move }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let bundleID = sender.draggingPasteboard.string(forType: .string) else { return false }
        // sender.draggingLocation 是本视图坐标（左下原点）；把中心点换算成网格索引。
        let p = convert(sender.draggingLocation, from: nil)
        let col = max(0, min(columns - 1, Int(p.x / cellW)))
        // AppKit y 自下而上，第一行在顶部：row 0 = 最上面一行。
        let row = max(0, Int((bounds.height - p.y) / cellH))
        let index = row * columns + col
        onDrop?(bundleID, index)
        return true
    }
}

extension Notification.Name {
    static let notchOpenPreferences = Notification.Name("notchOpenPreferences")
    static let notchCollapseChanged = Notification.Name("notchCollapseChanged")
    // 系统项点击的「借用断言」结束 → 上层开始校验收纳是否真的收住了。
    static let notchLiftEnded = Notification.Name("notchLiftEnded")
}
