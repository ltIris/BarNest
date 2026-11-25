import AppKit

/**
 * @Author lt_xiaoyi
 * @Description 工作台标题下方那一条「正在播放」横条。
 *
 * 为什么不放在图标网格里：它在网格中会和真实 App 的格子混在一起，用户得猜
 * 哪一个才是「特制」的；单独一条横条就是一行信息，跟蓝牙/Wi-Fi 这种系统项
 * 是同一种读法 —— 一行、一个图标、一句状态，点一下展开。
 *
 * 内容永远是「谁在出声」：`[播放器图标]  网易云音乐   · 正在播放  ›`
 * 没有播放器时沿用上一次那个（跨启动记住），横条不消失、不换脸。
 * @Version 1.0
 */
@MainActor
final class NowPlayingBar: NSView {
    var onClick: (() -> Void)?

    private let iconView = NSImageView()
    private let badge = PlayBadgeView(frame: .zero)
    private let nameLabel = NSTextField(labelWithString: "")
    private let tagLabel = NSTextField(labelWithString: "正在播放")
    private let chevron = NSImageView()
    private var tracking: NSTrackingArea?

    // 徽标直径：够看清三角，又不会盖住 App 图标本身。
    private static let badgeSize: CGFloat = 13

    // 横条高度：比图标格子矮，是「一行信息」而不是「一个格子」。
    static let barHeight: CGFloat = 34

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.07).cgColor

        iconView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(iconView)

        // 图标右上角那颗圆形 ▶ 徽标：一眼看出这一行是「播放器 / 正在播放」，
        // 又不用给图标本身换皮（图标永远是播放器自己的真实图标）。
        addSubview(badge)

        nameLabel.font = .systemFont(ofSize: 12.5, weight: .semibold)
        nameLabel.textColor = NSColor.white.withAlphaComponent(0.95)
        nameLabel.lineBreakMode = .byTruncatingTail
        addSubview(nameLabel)

        tagLabel.font = .systemFont(ofSize: 10, weight: .medium)
        tagLabel.textColor = NSColor.white.withAlphaComponent(0.42)
        tagLabel.alignment = .right
        addSubview(tagLabel)

        chevron.imageScaling = .scaleProportionallyUpOrDown
        chevron.image = Self.tintedSymbol("chevron.right", pointSize: 9,
                                          color: NSColor.white.withAlphaComponent(0.32))
        addSubview(chevron)
    }

    required init?(coder: NSCoder) { nil }

    /**
     * 换内容：图标用播放器自己的真实图标，名字用播放器名。
     * 徽标和右侧文字一起表示状态：在播 → ▶ 正在播放，暂停 → ⏸ 已暂停。
     */
    func update(name: String, icon: NSImage?, isPlaying: Bool = true) {
        iconView.image = icon
        nameLabel.stringValue = name
        tagLabel.stringValue = isPlaying ? "正在播放" : "已暂停"
        badge.isPlaying = isPlaying
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        iconView.frame = NSRect(x: 11, y: (h - 19) / 2, width: 19, height: 19)
        // 徽标压在图标右上角，略微出边，像 App 图标上的角标。
        let bs = Self.badgeSize
        badge.frame = NSRect(x: iconView.frame.maxX - bs + 3,
                             y: iconView.frame.maxY - bs + 3,
                             width: bs, height: bs)
        let tagW: CGFloat = 56
        let chevW: CGFloat = 11
        nameLabel.frame = NSRect(x: 38, y: (h - 17) / 2,
                                 width: max(20, bounds.width - 38 - tagW - chevW - 26), height: 17)
        tagLabel.frame = NSRect(x: bounds.width - tagW - chevW - 14, y: (h - 14) / 2,
                                width: tagW, height: 14)
        chevron.frame = NSRect(x: bounds.width - chevW - 12, y: (h - chevW) / 2,
                               width: chevW, height: chevW)
    }

    // MARK: - 悬停 / 点击

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    // 系统符号涂成指定颜色（模板图直接 image.tint 不生效，得自己画一遍）。
    private static func tintedSymbol(_ name: String, pointSize: CGFloat, color: NSColor) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return nil }
        let image = NSImage(size: base.size)
        image.lockFocus()
        base.draw(in: NSRect(origin: .zero, size: base.size))
        color.set()
        NSRect(origin: .zero, size: base.size).fill(using: .sourceAtop)
        image.unlockFocus()
        return image
    }
}

/**
 * @Author lt_xiaoyi
 * @Description 绘制播放状态徽标，并用深色底保证在玻璃面板上可见。
 * @Version 1.0
 */
private final class PlayBadgeView: NSView {
    override var isFlipped: Bool { false }

    // true 画 ▶（在播），false 画 ⏸（暂停），和右侧文字一致。
    var isPlaying = true {
        didSet { if oldValue != isPlaying { needsDisplay = true } }
    }

    override func draw(_ dirtyRect: NSRect) {
        let box = bounds.insetBy(dx: 0.75, dy: 0.75)
        let ring = NSBezierPath(ovalIn: box)
        NSColor(calibratedWhite: 0.07, alpha: 0.92).setFill()
        ring.fill()
        NSColor.white.withAlphaComponent(0.9).setStroke()
        ring.lineWidth = 1.1
        ring.stroke()

        let d = box.width
        let cx = box.midX
        let cy = box.midY
        let r = d * 0.27
        NSColor.white.setFill()

        if isPlaying {
            // 实心三角（等比于圆环直径），视觉重心略微右移才像「播放」而不是「警告」。
            let shift = d * 0.035
            let tri = NSBezierPath()
            tri.move(to: NSPoint(x: cx - r * 0.8 + shift, y: cy + r))
            tri.line(to: NSPoint(x: cx - r * 0.8 + shift, y: cy - r))
            tri.line(to: NSPoint(x: cx + r + shift, y: cy))
            tri.close()
            tri.fill()
        } else {
            // 两根竖条 = 暂停。
            let barW = d * 0.13
            let gap = d * 0.10
            for offset in [-gap / 2 - barW / 2, gap / 2 + barW / 2] {
                let rect = NSRect(x: cx + offset - barW / 2, y: cy - r, width: barW, height: r * 2)
                NSBezierPath(roundedRect: rect, xRadius: barW / 2, yRadius: barW / 2).fill()
            }
        }
    }
}
