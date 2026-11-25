import AppKit
import CoreGraphics

/**
 * @Author lt_xiaoyi
 * @Description 在收纳断言生效期间转发系统菜单栏项的点击。
 * 点击时暂时释放断言，系统面板关闭后再恢复，确保时钟和控制中心仍可交互。
 * 事件坐标与屏幕边界统一使用 Quartz 坐标系，避免 AppKit 的 Y 轴方向差异。
 * @Version 1.0
 */
final class SystemItemClickBridge: NSObject {
    static let shared = SystemItemClickBridge()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    // 事件拦截被系统停用后必须自己拉起来，否则「点时钟不出组件」会永久复现。
    private var healthTimer: Timer?
    private var installAttempts = 0
    private let stateLock = NSLock()
    private var isEnabled = false
    private var replaying = false
    private var pendingDown: CGEvent?
    // 重放事件的标记，避免被自己再次拦截。
    private let marker: Int64 = 0x4E544F54434C4B00

    // 一次「系统项点击」会话的状态。
    private var liftToken: String?
    private var watchTimer: Timer?
    private var liftStarted: Date?
    private var sawPanel = false

    private override init() { super.init() }

    func install() {
        guard eventTap == nil else { return }
        let mask: CGEventMask = (1 << CGEventType.leftMouseDown.rawValue) |
                                (1 << CGEventType.leftMouseUp.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                          place: .headInsertEventTap,
                                          options: .defaultTap,
                                          eventsOfInterest: mask,
                                          callback: { (_, type, event, _) -> Unmanaged<CGEvent>? in
            SystemItemClickBridge.shared.handle(type: type, event: event)
        }, userInfo: nil) else {
            // 授权可能在启动后才生效，延迟重试可避免要求用户重启应用。
            installAttempts += 1
            if installAttempts <= 40 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in self?.install() }
            } else {
                NSLog("BarNest: 事件拦截创建失败（已重试 %d 次），时钟点击中继不可用", installAttempts)
            }
            return
        }
        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        runLoopSource = source
        CGEvent.tapEnable(tap: tap, enable: true)
        installAttempts = 0
        startHealthWatch()
        NSLog("BarNest: 事件拦截已就绪（时钟 / 控制中心点击中继可用）")
    }

    /**
     * 系统会因为在回调里耗时略长而停用 tap（kCGEventTapDisabledByTimeout），
     * 且停用后不会自己恢复。没有这个守护，就会出现「用一阵子后点时钟再也不弹组件」。
     */
    private func startHealthWatch() {
        healthTimer?.invalidate()
        healthTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: true) { [weak self] _ in
            self?.ensureTapEnabled()
        }
        if let healthTimer { RunLoop.main.add(healthTimer, forMode: .common) }
    }

    private func ensureTapEnabled() {
        guard let tap = eventTap else { install(); return }
        if !CGEvent.tapIsEnabled(tap: tap) {
            CGEvent.tapEnable(tap: tap, enable: true)
            NSLog("BarNest: 事件拦截被系统停用，已自动重新启用")
        }
    }

    func setEnabled(_ value: Bool) {
        stateLock.lock()
        isEnabled = value
        if !value { pendingDown = nil }
        stateLock.unlock()
        if !value { finishLift() }
        // 开启中继时顺手确认拦截还活着（可能刚授权完，或之前被系统停用过）。
        if value {
            if Thread.isMainThread {
                ensureTapEnabled()
                startHealthWatch()
            } else {
                DispatchQueue.main.async { [weak self] in
                    self?.ensureTapEnabled()
                    self?.startHealthWatch()
                }
            }
        }
    }

    /**
     * 系统项区域：任意屏幕菜单栏最右侧（时钟 / 控制中心 / 通知中心 / 蓝牙 / Wi-Fi）。
     * 全部使用 Quartz 全局坐标，与 CGEvent.location 同源。
     */
    private func isSystemZone(_ p: CGPoint) -> Bool {
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            let b = CGDisplayBounds(CGDirectDisplayID(number.uint32Value))
            guard p.x >= b.minX, p.x <= b.maxX, p.y >= b.minY, p.y <= b.maxY else { continue }
            // 顶部 34pt 菜单栏、右侧 320pt 系统区。
            return p.y <= b.minY + 34 && p.x >= b.maxX - 320
        }
        return false
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // 系统停用 tap 时会单独派发这两种事件。必须立刻重新启用，
        // 并把半截的点击状态清干净，否则接下来所有点击都不再经过中继。
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            stateLock.lock()
            pendingDown = nil
            stateLock.unlock()
            NSLog("BarNest: 事件拦截被系统停用（%d），已立即重新启用", type.rawValue)
            DispatchQueue.main.async { [weak self] in self?.finishLift() }
            return Unmanaged.passUnretained(event)
        }

        // 重放的事件直接放行。
        if event.getIntegerValueField(.eventSourceUserData) == marker {
            return Unmanaged.passUnretained(event)
        }

        stateLock.lock()
        let enabled = isEnabled
        let busy = replaying || liftToken != nil
        stateLock.unlock()
        // 已经处于「借出」状态时一律放行，避免自己拦截自己、或重复开启会话。
        guard enabled, !busy else { return Unmanaged.passUnretained(event) }

        if type == .leftMouseDown {
            guard isSystemZone(event.location) else {
                // 在系统区外按下：清掉可能残留的按下事件，避免下次误触发。
                clearPendingDown()
                return Unmanaged.passUnretained(event)
            }
            stateLock.lock()
            pendingDown = event.copy()
            stateLock.unlock()
            return nil   // 扣住按下
        }

        if type == .leftMouseUp {
            // 无论抬起落在哪里，都要消费掉这次按下，避免状态残留。
            stateLock.lock()
            let down = pendingDown
            pendingDown = nil
            stateLock.unlock()
            guard let down, isSystemZone(event.location) else {
                return Unmanaged.passUnretained(event)
            }
            replaying = true
            let token = "system-click-\(UUID().uuidString)"
            setLiftToken(token)

            guard let up = event.copy() else { return Unmanaged.passUnretained(event) }
            Task { @MainActor [weak self] in
                guard let self else { return }
                // 借用「无断言」状态：系统区交互恢复，通知中心组件能正常弹出。
                MenuBarAssertionCoordinator.shared.beginLift(token)
                try? await Task.sleep(nanoseconds: 120_000_000)   // 等 MenuBarAgent 响应释放
                self.postReplay(down)
                self.postReplay(up)
                self.setReplaying(false)
                self.startWatching(token: token)
            }
            return nil   // 扣住抬起
        }

        return Unmanaged.passUnretained(event)
    }

    private func clearPendingDown() {
        stateLock.lock()
        pendingDown = nil
        stateLock.unlock()
    }

    private func setReplaying(_ value: Bool) {
        stateLock.lock()
        replaying = value
        stateLock.unlock()
    }

    private func setLiftToken(_ token: String?) {
        stateLock.lock()
        liftToken = token
        stateLock.unlock()
    }

    // 面板可见期间保持借出；面板关闭后延迟一点再归还，避免刚弹出就被收走。
    private func startWatching(token: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.liftToken == token else { return }
            self.liftStarted = Date()
            self.sawPanel = false
            self.watchTimer?.invalidate()
            self.watchTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkPanel(token: token) }
            }
        }
    }

    private func checkPanel(token: String) {
        guard liftToken == token else { finishLift(); return }
        let elapsed = Date().timeIntervalSince(liftStarted ?? Date())
        let visible = Self.systemPanelVisible()
        if visible {
            sawPanel = true
        } else if sawPanel {
            // 面板刚关闭，稍等一下再恢复收纳，避免闪烁。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.liftToken == token else { return }
                    self.finishLift()
                }
            }
            return
        }
        // 从未检测到面板（可能只是点了某个开关）：给用户 3 秒操作时间。
        // 12 秒为硬兜底，任何情况下都必须归还断言，避免图标永久展开。
        if (!sawPanel && elapsed > 3.0) || elapsed > 12.0 { finishLift() }
    }

    private func finishLift() {
        watchTimer?.invalidate()
        watchTimer = nil
        stateLock.lock()
        let token = liftToken
        liftToken = nil
        replaying = false
        stateLock.unlock()
        sawPanel = false
        liftStarted = nil
        if let token {
            if Thread.isMainThread {
                MainActor.assumeIsolated { MenuBarAssertionCoordinator.shared.endLift(token) }
            } else {
                Task { @MainActor in MenuBarAssertionCoordinator.shared.endLift(token) }
            }
        }
        // 归还只是「发出了收缩请求」。系统面板还开着时 MenuBarAgent 会忽略它，
        // 所以这里通知上层做一段短时的收敛校验（见 StatusBarController.verifyCollapse）。
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .notchLiftEnded, object: nil)
        }
    }

    // 通知中心 / 控制中心面板是否正在显示。用窗口列表即可，无需额外权限。
    static func systemPanelVisible() -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return false }
        for w in list {
            guard let owner = w[kCGWindowOwnerName as String] as? String else { continue }
            let n = owner.lowercased()
            guard n.contains("notification") || n.contains("control center") ||
                  n.contains("controlcenter") || n.contains("通知") || n.contains("控制中心") else { continue }
            let bounds = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
            let h = (bounds["Height"] as? Double) ?? 0
            let width = (bounds["Width"] as? Double) ?? 0
            // 只看真正的面板窗口；菜单栏上的小图标窗口高度通常 < 40。
            if h > 120 && width > 200 { return true }
        }
        return false
    }

    private func postReplay(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: marker)
        event.post(tap: .cgSessionEventTap)
    }

    deinit {
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
    }
}
