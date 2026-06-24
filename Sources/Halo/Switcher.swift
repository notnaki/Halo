import AppKit

/// One row in the session switcher. The injection point for M3: detached
/// daemon sessions are appended as rows with `detached: true` and an
/// `activate` closure that reattaches — the overlay treats every row the same.
struct SessionRow {
    let title: String        // session name or derived label
    let subtitle: String     // window/project context + cwd
    let detached: Bool       // M3: true ⇒ a daemon session with no live pane
    let activate: () -> Void // jump to (M3: attach) this session
    let paneID: String?      // M4: the focused pane's stable id (nil for browser leaves)
}

/// Fuzzy-filter switcher overlay: a centered panel listing every session
/// across all windows/projects. Type to filter, ↑/↓ to move, Enter to jump,
/// Esc to close. Reuses TerminalPane's search-bar visual tokens.
@MainActor
final class SwitcherOverlay: NSView, NSTextFieldDelegate {
    private let theme: Theme
    private let allRows: [SessionRow]
    private var shown: [SessionRow] = []
    private var selected = 0

    private let input = NSTextField()
    private let listStack = NSStackView()
    private let onClose: () -> Void
    /// M4: Called when the user presses Cmd-Enter on a row with a paneID.
    var onMirror: ((SessionRow) -> Void)?

    init(theme: Theme, rows: [SessionRow], onClose: @escaping () -> Void) {
        self.theme = theme
        self.allRows = rows
        self.onClose = onClose
        super.init(frame: .zero)
        build()
        apply(query: "")
    }
    required init?(coder: NSCoder) { fatalError() }

    // Dim scrim over the whole window; click-through-to-dismiss.
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.35).setFill()
        dirtyRect.fill()
    }
    override func mouseDown(with event: NSEvent) {
        // Click outside the panel closes; clicks on the panel are caught by it.
        onClose()
    }

    private func build() {
        wantsLayer = true
        autoresizingMask = [.width, .height]

        let panel = NSView()
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.wantsLayer = true
        panel.layer?.backgroundColor = NSColor(white: 0.13, alpha: 0.97).cgColor
        panel.layer?.cornerRadius = 8
        panel.layer?.borderWidth = 1
        panel.layer?.borderColor = NSColor(white: 1, alpha: 0.12).cgColor
        addSubview(panel)

        input.placeholderString = "Jump to session"
        input.delegate = self
        input.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        input.focusRingType = .none
        input.isBezeled = false
        input.drawsBackground = false
        input.textColor = NSColor(white: 0.93, alpha: 1)
        input.translatesAutoresizingMaskIntoConstraints = false

        let hair = NSView()
        hair.translatesAutoresizingMaskIntoConstraints = false
        hair.wantsLayer = true
        hair.layer?.backgroundColor = NSColor(white: 1, alpha: 0.08).cgColor

        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 1
        listStack.translatesAutoresizingMaskIntoConstraints = false

        panel.addSubview(input)
        panel.addSubview(hair)
        panel.addSubview(listStack)

        NSLayoutConstraint.activate([
            panel.centerXAnchor.constraint(equalTo: centerXAnchor),
            panel.topAnchor.constraint(equalTo: topAnchor, constant: 120),
            panel.widthAnchor.constraint(equalToConstant: 460),

            input.topAnchor.constraint(equalTo: panel.topAnchor, constant: 14),
            input.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 16),
            input.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -16),

            hair.topAnchor.constraint(equalTo: input.bottomAnchor, constant: 12),
            hair.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            hair.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            hair.heightAnchor.constraint(equalToConstant: 1),

            listStack.topAnchor.constraint(equalTo: hair.bottomAnchor, constant: 8),
            listStack.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 8),
            listStack.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -8),
            listStack.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -10),
        ])
    }

    /// Re-filter against the query and rebuild the visible rows.
    private func apply(query: String) {
        shown = fuzzyFilter(allRows, query: query, key: { $0.title + " " + $0.subtitle })
        selected = 0
        rebuildList()
    }

    private func rebuildList() {
        listStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if shown.isEmpty {
            let empty = NSTextField(labelWithString: "no sessions")
            empty.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            empty.textColor = NSColor(white: 0.46, alpha: 1)
            listStack.addArrangedSubview(rowView(empty, highlighted: false))
            return
        }
        for (i, r) in shown.enumerated() {
            let title = NSTextField(labelWithString: r.detached ? "○ " + r.title : r.title)
            title.font = .monospacedSystemFont(ofSize: 13, weight: i == selected ? .medium : .regular)
            title.textColor = i == selected ? NSColor(white: 0.97, alpha: 1) : NSColor(white: 0.78, alpha: 1)
            let sub = NSTextField(labelWithString: r.subtitle)
            sub.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
            sub.textColor = NSColor(white: 0.5, alpha: 1)
            let line = NSStackView(views: [title, sub])
            line.orientation = .horizontal
            line.spacing = 8
            listStack.addArrangedSubview(rowView(line, highlighted: i == selected))
        }
    }

    /// Wrap a row's content with a rounded highlight using theme.accent.
    private func rowView(_ content: NSView, highlighted: Bool) -> NSView {
        let wrap = NSView()
        wrap.translatesAutoresizingMaskIntoConstraints = false
        wrap.wantsLayer = true
        wrap.layer?.cornerRadius = 5
        wrap.layer?.backgroundColor = highlighted
            ? theme.accent.withAlphaComponent(0.16).cgColor
            : NSColor.clear.cgColor
        content.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 10),
            content.trailingAnchor.constraint(lessThanOrEqualTo: wrap.trailingAnchor, constant: -10),
            content.topAnchor.constraint(equalTo: wrap.topAnchor, constant: 5),
            content.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -5),
            wrap.widthAnchor.constraint(equalTo: listStack.widthAnchor, constant: -16),
        ])
        return wrap
    }

    /// Make the input first responder once we're in a window.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(input)
    }

    // Live filter on each keystroke.
    func controlTextDidChange(_ obj: Notification) { apply(query: input.stringValue) }

    // Enter = jump; Esc = close; ↑/↓ move selection.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(insertNewline(_:)):
            guard shown.indices.contains(selected) else { return true }
            let r = shown[selected]
            // Cmd-Enter: mirror the highlighted session's focused pane into the active window.
            if NSApp.currentEvent?.modifierFlags.contains(.command) == true {
                if r.paneID != nil { onClose(); onMirror?(r) }
            } else {
                onClose(); r.activate()
            }
            return true
        case #selector(cancelOperation(_:)):
            onClose(); return true
        case #selector(moveDown(_:)):
            if !shown.isEmpty { selected = (selected + 1) % shown.count; rebuildList() }
            return true
        case #selector(moveUp(_:)):
            if !shown.isEmpty { selected = (selected - 1 + shown.count) % shown.count; rebuildList() }
            return true
        default:
            return false
        }
    }
}
