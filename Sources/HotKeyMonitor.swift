import AppKit
import Carbon.HIToolbox

/**
 * @Author lt_xiaoyi
 * @Description 全局热键：
 * - ⌥⌘R：强制恢复所有图标（收纳后无法恢复的兜底安全网）
 * - ⌥⌘N：打开/关闭面板（菜单栏按钮找不到或点不动时的可靠入口）
 * @Version 1.0
 */
final class HotKeyMonitor {
    static let shared = HotKeyMonitor()

    private var restoreRef: EventHotKeyRef?
    private var panelRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var onRestore: (() -> Void)?
    private var onPanel: (() -> Void)?

    private init() {}

    func install(onRestore: @escaping () -> Void, onPanel: @escaping () -> Void) {
        self.onRestore = onRestore
        self.onPanel = onPanel
        guard handlerRef == nil else { return }

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            if hotKeyID.id == 1 { HotKeyMonitor.shared.fireRestore() }
            else if hotKeyID.id == 2 { HotKeyMonitor.shared.firePanel() }
            return noErr
        }, 1, &eventType, nil, &handlerRef)

        let mods = UInt32(optionKey | cmdKey)
        RegisterEventHotKey(UInt32(kVK_ANSI_R), mods,
                            EventHotKeyID(signature: OSType(0x4E544F54), id: 1),
                            GetApplicationEventTarget(), 0, &restoreRef)
        RegisterEventHotKey(UInt32(kVK_ANSI_N), mods,
                            EventHotKeyID(signature: OSType(0x4E544F54), id: 2),
                            GetApplicationEventTarget(), 0, &panelRef)
    }

    fileprivate func fireRestore() { Task { @MainActor in onRestore?() } }
    fileprivate func firePanel() { Task { @MainActor in onPanel?() } }

    deinit {
        if let restoreRef { UnregisterEventHotKey(restoreRef) }
        if let panelRef { UnregisterEventHotKey(panelRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
