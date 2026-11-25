import AppKit
import ApplicationServices

/**
 * @Author lt_xiaoyi
 * @Description 窗口位置预设：对应 iBar 右键菜单里的半屏 / 四角 / 三分之一 / 最大化等。
 * @Version 1.0
 */
enum WindowPreset: String, CaseIterable {
    case leftHalf = "左半屏"
    case rightHalf = "右半屏"
    case centerHalf = "中间半屏"
    case topHalf = "上半屏"
    case bottomHalf = "下半屏"
    case topLeft = "左上"
    case topRight = "右上"
    case bottomLeft = "左下"
    case bottomRight = "右下"
    case leftThird = "左侧 1/3"
    case centerThird = "中间 1/3"
    case rightThird = "右侧 1/3"
    case leftTwoThirds = "左侧 2/3"
    case rightTwoThirds = "右侧 2/3"
    case maximize = "最大化"
    case nearlyMaximize = "接近最大化"
    case maximizeHeight = "最大化高度"
    case minimize = "缩小"
    case zoom = "放大"
    case center = "居中"
    case restore = "恢复"

    // 菜单分组，用于构造层级菜单。
    var group: Int {
        switch self {
        case .leftHalf, .rightHalf, .centerHalf, .topHalf, .bottomHalf: return 0
        case .topLeft, .topRight, .bottomLeft, .bottomRight: return 1
        case .leftThird, .centerThird, .rightThird, .leftTwoThirds, .rightTwoThirds: return 2
        case .maximize, .nearlyMaximize, .maximizeHeight, .minimize, .zoom, .center: return 3
        case .restore: return 4
        }
    }
}

/**
 * @Author lt_xiaoyi
 * @Description 通过辅助功能接口调整应用窗口位置，需要辅助功能权限。
 * @Version 1.0
 */
final class WindowManager {
    static let shared = WindowManager()

    // 记录窗口被我们改变前的 frame，供「恢复」使用。key 为 AXWindow 的 hash。
    private var originalFrames: [Int: CGRect] = [:]

    var isTrusted: Bool { AXIsProcessTrusted() }

    func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    // 该 App 是否有可操作的窗口。
    func hasWindows(for bundleID: String) -> Bool {
        !windows(for: bundleID).isEmpty
    }

    private func windows(for bundleID: String) -> [AXUIElement] {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return [] }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value)
        guard result == .success, let list = value as? [AXUIElement] else { return [] }
        return list.filter { window in
            var subrole: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subrole)
            let role = subrole as? String ?? ""
            return role.isEmpty || role == "AXStandardWindow"   // 排除菜单、面板等
        }
    }

    @MainActor
    func apply(_ preset: WindowPreset, to bundleID: String) {
        guard isTrusted else { requestPermission(); return }
        let targets = windows(for: bundleID)
        guard !targets.isEmpty else { return }

        if preset == .restore {
            for window in targets {
                if let frame = originalFrames[window.hashValue] {
                    setFrame(frame, of: window)
                }
            }
            return
        }

        let screen = ScreenLocator.screenForMenuBarClick() ?? NSScreen.main ?? NSScreen.screens.first
        guard let area = screen?.visibleFrame else { return }   // 避开菜单栏和 Dock

        for window in targets {
            if originalFrames[window.hashValue] == nil {
                originalFrames[window.hashValue] = frame(of: window)
            }
            let target = frame(for: preset, in: area, current: frame(of: window))
            setFrame(target, of: window)
        }
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            app.activate(options: [.activateIgnoringOtherApps])
        }
    }

    private func frame(for preset: WindowPreset, in area: NSRect, current: CGRect) -> NSRect {
        let x = area.minX, y = area.minY, w = area.width, h = area.height
        switch preset {
        case .leftHalf:       return NSRect(x: x, y: y, width: w / 2, height: h)
        case .rightHalf:      return NSRect(x: x + w / 2, y: y, width: w / 2, height: h)
        case .centerHalf:     return NSRect(x: x + w / 4, y: y, width: w / 2, height: h)
        case .topHalf:        return NSRect(x: x, y: y + h / 2, width: w, height: h / 2)
        case .bottomHalf:     return NSRect(x: x, y: y, width: w, height: h / 2)
        case .topLeft:        return NSRect(x: x, y: y + h / 2, width: w / 2, height: h / 2)
        case .topRight:       return NSRect(x: x + w / 2, y: y + h / 2, width: w / 2, height: h / 2)
        case .bottomLeft:     return NSRect(x: x, y: y, width: w / 2, height: h / 2)
        case .bottomRight:    return NSRect(x: x + w / 2, y: y, width: w / 2, height: h / 2)
        case .leftThird:      return NSRect(x: x, y: y, width: w / 3, height: h)
        case .centerThird:    return NSRect(x: x + w / 3, y: y, width: w / 3, height: h)
        case .rightThird:     return NSRect(x: x + w * 2 / 3, y: y, width: w / 3, height: h)
        case .leftTwoThirds:  return NSRect(x: x, y: y, width: w * 2 / 3, height: h)
        case .rightTwoThirds: return NSRect(x: x + w / 3, y: y, width: w * 2 / 3, height: h)
        case .maximize:       return area
        case .nearlyMaximize: return area.insetBy(dx: w * 0.05, dy: h * 0.05)
        case .maximizeHeight: return NSRect(x: current.minX, y: y, width: current.width, height: h)
        case .minimize:       return NSRect(x: current.midX - w * 0.2, y: current.midY - h * 0.2, width: w * 0.4, height: h * 0.4)
        case .zoom:           return area.insetBy(dx: w * 0.1, dy: h * 0.1)
        case .center:         return NSRect(x: current.midX, y: current.midY, width: current.width, height: current.height).offsetBy(dx: -(current.width) / 2 + (area.midX - current.midX), dy: -(current.height) / 2 + (area.midY - current.midY))
        case .restore:        return current
        }
    }

    private func frame(of window: AXUIElement) -> CGRect {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        var pos = CGPoint.zero, size = CGSize.zero
        if AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef) == .success,
           let value = posRef, AXValueGetValue(value as! AXValue, .cgPoint, &pos) {
        }
        if AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
           let value = sizeRef, AXValueGetValue(value as! AXValue, .cgSize, &size) {
        }
        return CGRect(origin: pos, size: size)
    }

    private func setFrame(_ rect: CGRect, of window: AXUIElement) {
        var pos = CGPoint(x: rect.minX, y: rect.minY)
        var size = CGSize(width: rect.width, height: rect.height)
        if let p = AXValueCreate(.cgPoint, &pos) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, p)
        }
        if let s = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, s)
        }
    }
}
