import AppKit

/// A non-modal, plugin-controlled floating panel: a titled box of text lines pinned to a
/// corner of the window. Plugins build custom UI with it — a live git panel, a clock, a
/// dashboard — and update it on a `halo.timer`. Unlike the picker it doesn't dim the
/// screen or steal focus, so the terminal stays usable underneath.
final class PanelOverlay: NSView {
    enum Corner: String { case topright, topleft, bottomright, bottomleft }

    private let theme: Theme
    let corner: Corner
    private let titleLabel = NSTextField(labelWithString: "")
    private let lineStack = NSStackView()

    init(theme: Theme, title: String, lines: [String], corner: Corner) {
        self.theme = theme
        self.corner = corner
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.11, alpha: 0.96).cgColor
        layer?.cornerRadius = 9
        layer?.borderWidth = 1
        layer?.borderColor = theme.accent.withAlphaComponent(0.5).cgColor
        translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = theme.accent
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        lineStack.orientation = .vertical
        lineStack.alignment = .leading
        lineStack.spacing = 2
        lineStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(titleLabel)
        addSubview(lineStack)
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
            lineStack.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            lineStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            lineStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            lineStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
            widthAnchor.constraint(lessThanOrEqualToConstant: 460),
        ])
        update(title: title, lines: lines)
    }
    required init?(coder: NSCoder) { fatalError() }

    // Non-modal: clicks pass through to the terminal underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(title: String, lines: [String]) {
        titleLabel.stringValue = title
        titleLabel.isHidden = title.isEmpty
        lineStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for line in lines.prefix(40) {
            let l = NSTextField(labelWithString: line)
            l.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            l.textColor = NSColor(white: 0.9, alpha: 1)
            l.lineBreakMode = .byTruncatingTail
            lineStack.addArrangedSubview(l)
        }
    }

    /// Pin this panel into `host`'s chosen corner (called once when added).
    func pin(into host: NSView) {
        let m: CGFloat = 16
        var cons: [NSLayoutConstraint] = []
        switch corner {
        case .topright:    cons = [topAnchor.constraint(equalTo: host.topAnchor, constant: m + 28),
                                   trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -m)]
        case .topleft:     cons = [topAnchor.constraint(equalTo: host.topAnchor, constant: m + 28),
                                   leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: m)]
        case .bottomright: cons = [bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -m),
                                   trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -m)]
        case .bottomleft:  cons = [bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -m),
                                   leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: m)]
        }
        NSLayoutConstraint.activate(cons)
    }
}
