import AppKit

/**
 * @Author lt_xiaoyi
 * @Description 判断「用户此刻在哪块屏幕上操作」，用于让弹窗跟随当前屏幕。
 * @Version 1.0
 */
enum ScreenLocator {

    // 菜单栏点击时的当前屏幕。优先用鼠标全局坐标，失败则用主屏。
    static func screenForMenuBarClick() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        if let hit = screen(containing: mouse) { return hit }
        return NSScreen.main ?? NSScreen.screens.first
    }

    // 判断某个点落在哪块屏（AppKit 坐标，原点左下）。
    static func screen(containing point: NSPoint) -> NSScreen? {
        // 优先精确命中；外接屏与内置屏拼接处可能有 1pt 缝隙，放宽到边框内 2pt。
        if let exact = NSScreen.screens.first(where: { $0.frame.contains(point) }) {
            return exact
        }
        return NSScreen.screens.first { screen in
            let f = screen.frame.insetBy(dx: -2, dy: -2)
            return f.contains(point)
        }
    }

    // 面板在该屏幕上的落点：默认贴菜单栏下方、水平居中。
    static func origin(forPanelSize size: NSSize, on screen: NSScreen) -> NSPoint {
        return origin(forPanelSize: size, on: screen, anchorX: nil)
    }

    /**
     * 面板落在菜单栏点击位置旁边：面板左边缘尽量对齐锚点（菜单栏按钮中心）。
     * 锚点为空时退回水平居中。最终会把面板夹在屏幕内、避开刘海。
     */
    static func origin(forPanelSize size: NSSize, on screen: NSScreen, anchorX: CGFloat?) -> NSPoint {
        let area = screen.frame
        /**
         * 面板紧贴锚点（菜单栏按钮）左下方：左边缘对齐锚点略靠左，
         * 不用「锚点居中」，否则锚点靠近屏幕右侧时面板会超出屏幕、右边几列被截掉。
         */
        var x = (anchorX ?? area.midX) - size.width * 0.25

        // 水平严格夹在屏幕内（含 12pt 边距），保证整块面板和底部数据条都完整可见。
        let margin: CGFloat = 12
        let minX = area.minX + margin
        let maxX = area.maxX - size.width - margin
        if maxX >= minX {
            x = min(max(x, minX), maxX)
        } else {
            x = minX
        }

        // 刘海屏：面板水平范围与刘海相交时，顶边压到刘海下方。
        let notch = screen.auxiliaryTopRightArea
        var topInset: CGFloat = 8
        if let notch, notch.width > 0 {
            let overlap = x < notch.maxX && x + size.width > notch.minX
            if overlap { topInset = max(topInset, notch.height + 6) }
        }

        let y = area.maxY - size.height - topInset
        return NSPoint(x: x, y: y)
    }

    // 判断点是否落在菜单栏区域（任意屏幕顶部 34pt 内）。
    static func isInMenuBar(_ point: NSPoint) -> Bool {
        guard let screen = screen(containing: point) else { return false }
        return point.y >= screen.frame.maxY - 34
    }

    // 菜单栏图标（状态项）在屏幕上的中心 x 坐标。用于在按钮旁边定位面板。
    static func menuBarItemCenterX() -> CGFloat? {
        let mouse = NSEvent.mouseLocation
        // 点击发生在菜单栏时，鼠标 x 就是按钮所在位置，直接用它最准确。
        if let screen = screen(containing: mouse),
           mouse.y >= screen.frame.maxY - 60 {
            return mouse.x
        }
        return nil
    }
}
