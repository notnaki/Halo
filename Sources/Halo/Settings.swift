import AppKit

/// A small native settings panel for the common `halo-*` keys. Each control
/// writes straight to Halo's own config (creating it, seeded from ghostty).
/// Sidebar width applies live; colors/fonts/divider apply on relaunch.
@MainActor
final class SettingsWindowController: NSWindowController {
    private let onSidebarWidth: (CGFloat) -> Void
    private let onImport: () -> Void
    private let onOpenConfig: () -> Void
    private let onReload: () -> Void
    private var configView: NSTextView?   // full-config editor (any ghostty key)

    init(theme: Theme,
         onSidebarWidth: @escaping (CGFloat) -> Void,
         onImport: @escaping () -> Void,
         onOpenConfig: @escaping () -> Void,
         onReload: @escaping () -> Void) {
        self.onSidebarWidth = onSidebarWidth
        self.onImport = onImport
        self.onOpenConfig = onOpenConfig
        self.onReload = onReload
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 600),
                           styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        win.title = "Halo Settings"
        win.minSize = NSSize(width: 420, height: 460)
        super.init(window: win)
        build(theme: theme)
        win.center()
    }
    required init?(coder: NSCoder) { fatalError("no xib") }

    private func build(theme: Theme) {
        let cfg = HaloConfig.shared
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let accent = NSColorWell(); accent.color = cfg.accent ?? theme.accent
        accent.target = self; accent.action = #selector(accentChanged(_:))
        stack.addArrangedSubview(row("Accent", accent))

        let surface = NSColorWell(); surface.color = cfg.surface ?? theme.background
        surface.target = self; surface.action = #selector(surfaceChanged(_:))
        stack.addArrangedSubview(row("Surface", surface))

        stack.addArrangedSubview(row("Sidebar width",
            slider(Double(cfg.sidebarWidth), 160, 420, #selector(sidebarChanged(_:)))))
        stack.addArrangedSubview(row("Font size",
            slider(Double(cfg.fontScale * 13), 9, 22, #selector(fontChanged(_:)))))
        stack.addArrangedSubview(row("Divider width",
            slider(Double(cfg.dividerWidth), 1, 14, #selector(dividerChanged(_:)))))

        let note = NSTextField(labelWithString: "Sidebar width applies live; click Reload to apply colors, fonts, theme, and any edited config.")
        note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor
        note.lineBreakMode = .byWordWrapping; note.preferredMaxLayoutWidth = 340
        stack.addArrangedSubview(note)

        let btns = NSStackView(views: [
            button("Import ghostty config", #selector(importTapped)),
            button("Open config file", #selector(openTapped)),
            button("Reload", #selector(reloadTapped)),
        ])
        btns.orientation = .horizontal; btns.spacing = 8
        stack.addArrangedSubview(btns)

        // ── Full config editor — accepts ANY ghostty key (libghostty parses the
        // whole file), so this is the complete config surface, not just halo-*.
        let header = NSTextField(labelWithString: "Config — any ghostty option (see ghostty.org/docs/config)")
        header.font = .boldSystemFont(ofSize: 12)
        stack.addArrangedSubview(header)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let tv = NSTextView()
        tv.isRichText = false
        tv.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.string = currentConfigText()
        scroll.documentView = tv
        self.configView = tv
        stack.addArrangedSubview(scroll)
        stack.addArrangedSubview(button("Save config", #selector(saveConfigTapped)))

        let content = window!.contentView!
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),
        ])
    }

    /// Halo's current config text — the editable file if it exists, else the
    /// ghostty config it would import from, else empty.
    private func currentConfigText() -> String {
        if let t = try? String(contentsOfFile: haloConfigPath(), encoding: .utf8) { return t }
        if let src = ghosttyConfigPath(), let t = try? String(contentsOfFile: src, encoding: .utf8) { return t }
        return ""
    }

    private func row(_ label: String, _ control: NSView) -> NSView {
        let l = NSTextField(labelWithString: label)
        l.widthAnchor.constraint(equalToConstant: 110).isActive = true
        let r = NSStackView(views: [l, control])
        r.orientation = .horizontal; r.spacing = 10; r.alignment = .centerY
        return r
    }
    private func slider(_ v: Double, _ lo: Double, _ hi: Double, _ action: Selector) -> NSSlider {
        let s = NSSlider(value: v, minValue: lo, maxValue: hi, target: self, action: action)
        s.widthAnchor.constraint(equalToConstant: 200).isActive = true
        s.isContinuous = true
        return s
    }
    private func button(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        b.font = .systemFont(ofSize: 11)
        return b
    }

    // Each control persists immediately to Halo's config.
    @objc private func accentChanged(_ s: NSColorWell)  { setHaloConfigKey("halo-accent", hexString(s.color)) }
    @objc private func surfaceChanged(_ s: NSColorWell) { setHaloConfigKey("halo-surface", hexString(s.color)) }
    @objc private func sidebarChanged(_ s: NSSlider) {
        setHaloConfigKey("halo-sidebar-width", "\(Int(s.doubleValue))")
        onSidebarWidth(CGFloat(s.doubleValue))   // live
    }
    @objc private func fontChanged(_ s: NSSlider)    { setHaloConfigKey("halo-font-size", "\(Int(s.doubleValue))") }
    @objc private func dividerChanged(_ s: NSSlider) { setHaloConfigKey("halo-divider-width", "\(Int(s.doubleValue))") }
    /// Write the editor's full text to Halo's config, then offer to relaunch so
    /// libghostty re-reads it (colors/font/theme need a fresh config load).
    @objc private func saveConfigTapped() {
        guard let text = configView?.string else { return }
        let path = haloConfigPath()
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? text.write(toFile: path, atomically: true, encoding: .utf8)

        onReload()
    }

    @objc private func importTapped() { onImport() }
    @objc private func openTapped()   { onOpenConfig() }
    @objc private func reloadTapped() { onReload() }
}
