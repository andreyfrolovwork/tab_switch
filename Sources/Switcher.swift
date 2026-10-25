import AppKit

final class SwitcherPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

enum SwitcherGesture {
    case command
    case option
    case none
}

final class Switcher {
    private let panel: SwitcherPanel
    private let view = SwitcherView()
    private(set) var isShown = false
    var panelWindowNumber: Int { panel.windowNumber }
    private var items: [WindowItem] = []
    private var selection = 0
    private var gesture = SwitcherGesture.none
    private var generation = 0

    init() {
        panel = SwitcherPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 160),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = false
        panel.level = .popUpMenu
        panel.contentView = Self.waterBackdrop(around: view)
        view.onSelect = { [weak self] index in
            self?.selection = index
            self?.confirm()
        }
        view.onHover = { [weak self] index in
            self?.selection = index
        }
    }

    /// Clear Liquid Glass on macOS 26: windows behind show through refracted, like under water.
    private static func waterBackdrop(around view: SwitcherView) -> NSView {
        let radius: CGFloat = 18
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .clear
            glass.cornerRadius = radius
            glass.tintColor = NSColor(srgbRed: 0.04, green: 0.13, blue: 0.2, alpha: 0.4)
            glass.contentView = view
            view.backgroundAlpha = 0.38
            return glass
        }
        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.maskImage = NSImage(size: NSSize(width: radius * 2 + 1, height: radius * 2 + 1), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        blur.maskImage?.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        blur.maskImage?.resizingMode = .stretch
        view.autoresizingMask = [.width, .height]
        blur.addSubview(view)
        view.backgroundAlpha = 0.35
        return blur
    }

    func open(forward: Bool, gesture: SwitcherGesture) {
        generation += 1
        items = WindowLister.onScreenWindows()
        for index in items.indices {
            items[index].thumbnail = ThumbnailCache.image(for: items[index].id)
        }
        if items.isEmpty {
            selection = 0
        } else if !forward {
            selection = items.count - 1
        } else if items.count == 1 {
            selection = 0
        } else {
            selection = 1
        }
        self.gesture = gesture
        isShown = true
        publish()
        placeOnMouseScreen()
        panel.level = .popUpMenu
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.08
            panel.animator().alphaValue = 1
        }
        let token = generation
        let primaryHeight = primaryScreenHeight()
        enrichTitles(generation: token, primaryHeight: primaryHeight)
        loadThumbnails(generation: token)
    }

    func move(by delta: Int) {
        guard isShown, !items.isEmpty else { return }
        selection = (selection + delta % items.count + items.count) % items.count
        publish()
    }

    func moveLine(by delta: Int) {
        guard isShown, !items.isEmpty else { return }
        let next = selection + delta * view.layout.columns
        guard items.indices.contains(next) else { return }
        selection = next
        publish()
    }

    func confirm() {
        guard isShown else { return }
        let chosen = items.indices.contains(selection) ? items[selection] : nil
        dismiss()
        guard let chosen else { return }
        fputs("windowswitcher: confirm\n", stderr)
        WindowActivator.activate(chosen)
    }

    func cancel() {
        guard isShown else { return }
        fputs("windowswitcher: cancel\n", stderr)
        dismiss()
    }

    func modifierReleased(command: Bool) {
        guard isShown else { return }
        if command, gesture == .command { confirm() }
        if !command, gesture == .option { confirm() }
    }

    private func dismiss() {
        generation += 1
        isShown = false
        gesture = .none
        panel.orderOut(nil)
    }

    private func publish() {
        view.items = items
        view.selection = selection
        view.needsDisplay = true
    }

    private func placeOnMouseScreen() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        // Keep clear space on both sides; extra windows wrap into more rows instead.
        let maxSize = CGSize(
            width: min(visible.width * 0.72, visible.width - 96),
            height: visible.height * 0.82
        )
        let layout = SwitcherLayout.make(count: items.count, maxSize: maxSize)
        view.layout = layout
        let origin = CGPoint(
            x: visible.midX - layout.size.width / 2,
            y: visible.midY - layout.size.height / 2
        )
        panel.setFrame(NSRect(origin: origin, size: layout.size), display: false)
        view.frame = NSRect(origin: .zero, size: layout.size)
        view.needsDisplay = true
    }

    private func loadThumbnails(generation: Int) {
        let ids = items.map(\.id)
        Task {
            let batch = await Thumbnails.capture(ids)
            let images = batch.images.mapValues { image in
                NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, generation == self.generation, self.isShown else { return }
                var applied = 0
                for index in self.items.indices {
                    guard let image = images[self.items[index].id] else { continue }
                    self.items[index].thumbnail = image
                    ThumbnailCache.store(self.items[index].id, image)
                    applied += 1
                }
                let detail = batch.error ?? ""
                fputs("windowswitcher: thumbs \(applied)/\(ids.count) \(detail)\n", stderr)
                self.view.needsCapture = applied == 0 && detail == "no screen capture access"
                if applied > 0 || self.view.needsCapture { self.publish() }
            }
        }
    }

    private func enrichTitles(generation: Int, primaryHeight: CGFloat) {
        let snapshot = items
        DispatchQueue.global(qos: .userInitiated).async {
            let titles = WindowLister.titles(for: snapshot, primaryHeight: primaryHeight)
            DispatchQueue.main.async { [weak self] in
                guard let self, generation == self.generation, self.isShown, !titles.isEmpty else { return }
                for index in self.items.indices {
                    if let title = titles[self.items[index].id] {
                        self.items[index].title = title
                    }
                }
                self.publish()
            }
        }
    }
}
