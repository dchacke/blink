import AppKit

/// The search panel: a text field over up to eight results. It never
/// activates Blink, so the app you were in keeps its menu bar and gets focus
/// back when the panel closes.
final class SearchController: NSObject, NSTextFieldDelegate, NSWindowDelegate {
    private enum Result {
        case calculation(String)
        case app(App)
    }

    private static let width: CGFloat = 640
    private static let fieldHeight: CGFloat = 57
    private static let rowHeight: CGFloat = 44
    private static let inset: CGFloat = 8
    private static let maxResults = 8
    private static let cornerRadius: CGFloat = 16

    private let index: AppIndex
    private let panel = Panel(
        contentRect: .zero,
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: false
    )
    private let field = NSTextField()
    private let separator = NSBox()
    private var rows: [ResultRow] = []
    private var results: [Result] = []
    private var selection = 0
    private var topLeft = NSPoint.zero

    init(index: AppIndex) {
        self.index = index
        super.init()
    }

    /// Builds the panel up front so the first ⌘Space is as fast as the rest.
    func prepare() {
        panel.isFloatingPanel = true
        panel.level = .modalPanel
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.delegate = self

        let content = FlippedView()
        content.autoresizingMask = [.width, .height]

        field.frame = NSRect(
            x: 18, y: (Self.fieldHeight - 30) / 2, width: Self.width - 36, height: 30
        )
        field.font = .systemFont(ofSize: 24)
        field.placeholderString = "Search apps or do math"
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.delegate = self
        content.addSubview(field)

        separator.boxType = .separator
        separator.frame = NSRect(x: 0, y: Self.fieldHeight, width: Self.width, height: 1)
        content.addSubview(separator)

        for i in 0..<Self.maxResults {
            let row = ResultRow(frame: NSRect(
                x: Self.inset,
                y: Self.fieldHeight + Self.inset + CGFloat(i) * Self.rowHeight,
                width: Self.width - 2 * Self.inset,
                height: Self.rowHeight
            ))
            row.onClick = { [weak self] in self?.activate(i) }
            rows.append(row)
            content.addSubview(row)
        }

        let blur = NSVisualEffectView()
        blur.material = .popover
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = Self.cornerRadius
        blur.layer?.masksToBounds = true
        // The layer's corner radius doesn't round the blur of what's behind
        // the window, only a mask does.
        blur.maskImage = Self.roundedMask()
        panel.contentView = blur

        if #available(macOS 26, *) {
            // Regular glass frosts over as the panel grows with results;
            // clear glass looks the same at any size. The blur under it keeps
            // text behind the panel from competing with the query.
            let glass = NSGlassEffectView()
            glass.style = .clear
            glass.cornerRadius = Self.cornerRadius
            glass.contentView = content
            glass.autoresizingMask = [.width, .height]
            blur.addSubview(glass)
        } else {
            blur.addSubview(content)
        }
    }

    private static func roundedMask() -> NSImage {
        let r = cornerRadius
        let mask = NSImage(size: NSSize(width: 2 * r + 1, height: 2 * r + 1), flipped: false) {
            NSBezierPath(roundedRect: $0, xRadius: r, yRadius: r).fill()
            return true
        }
        mask.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        mask.resizingMode = .stretch
        return mask
    }

    func toggle() {
        panel.isVisible ? hide() : show()
    }

    private func show() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        // Where Spotlight opens: 289 points above the middle of the screen.
        topLeft = NSPoint(
            x: visible.midX - Self.width / 2,
            y: screen.frame.midY + 289
        )
        field.stringValue = ""
        update()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
    }

    private func hide() {
        panel.orderOut(nil)
    }

    private func update() {
        let query = field.stringValue
        results = []
        if let value = Calculator.evaluate(query) {
            results.append(.calculation(Calculator.format(value)))
        }
        results += index.search(query, limit: Self.maxResults - results.count).map(Result.app)
        selection = 0

        for (i, row) in rows.enumerated() {
            row.isHidden = i >= results.count
            guard i < results.count else { continue }
            switch results[i] {
            case .calculation(let value): row.show(title: value, icon: ResultRow.calculatorIcon)
            case .app(let app): row.show(title: app.name, icon: app.icon)
            }
            row.isSelected = i == selection
        }

        separator.isHidden = results.isEmpty
        var height = Self.fieldHeight
        if !results.isEmpty { height += 2 * Self.inset + CGFloat(results.count) * Self.rowHeight }
        let frame = NSRect(x: topLeft.x, y: topLeft.y - height, width: Self.width, height: height)
        panel.setFrame(frame, display: true)
        panel.invalidateShadow()
    }

    private func select(_ i: Int) {
        guard !results.isEmpty else { return }
        selection = min(max(i, 0), results.count - 1)
        for (i, row) in rows.enumerated() { row.isSelected = i == selection }
    }

    // Opens the app, or copies the calculation's result.
    private func activate(_ i: Int) {
        guard results.indices.contains(i) else { return }
        hide()
        switch results[i] {
        case .calculation(let value):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
        case .app(let app):
            index.recordLaunch(of: app)
            let configuration = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.openApplication(at: app.url, configuration: configuration)
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        update()
    }

    func control(
        _ control: NSControl, textView: NSTextView, doCommandBy selector: Selector
    ) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): select(selection + 1)
        case #selector(NSResponder.moveUp(_:)): select(selection - 1)
        case #selector(NSResponder.insertNewline(_:)): activate(selection)
        case #selector(NSResponder.cancelOperation(_:)): hide()
        default: return false
        }
        return true
    }

    func windowDidResignKey(_ notification: Notification) {
        hide()
    }
}

private final class Panel: NSPanel {
    override var canBecomeKey: Bool { true }

    // Blink has no menu bar, which normally provides these shortcuts.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let actions = [
            "x": #selector(NSText.cut(_:)),
            "c": #selector(NSText.copy(_:)),
            "v": #selector(NSText.paste(_:)),
            "a": #selector(NSText.selectAll(_:)),
        ]
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           let action = event.charactersIgnoringModifiers.flatMap({ actions[$0] }),
           NSApp.sendAction(action, to: nil, from: self) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

private final class ResultRow: NSView {
    static let calculatorIcon = NSImage(
        systemSymbolName: "equal.circle.fill",
        accessibilityDescription: "Result"
    )!.withSymbolConfiguration(.init(pointSize: 26, weight: .regular))!

    var onClick: (() -> Void)?
    var isSelected = false {
        didSet {
            layer?.backgroundColor = isSelected ? NSColor.controlAccentColor.cgColor : nil
            title.textColor = isSelected ? .white : .labelColor
            icon.contentTintColor = isSelected ? .white : .secondaryLabelColor
        }
    }

    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
        icon.frame = NSRect(x: 8, y: bounds.midY - 16, width: 32, height: 32)
        icon.imageScaling = .scaleProportionallyUpOrDown
        title.frame = NSRect(x: 50, y: bounds.midY - 11, width: bounds.width - 60, height: 22)
        title.font = .systemFont(ofSize: 17)
        title.lineBreakMode = .byTruncatingTail
        addSubview(icon)
        addSubview(title)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(title: String, icon: NSImage) {
        self.title.stringValue = title
        self.icon.image = icon
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}
