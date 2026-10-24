import AppKit
import Darwin
import ScreenCaptureKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var switcher: Switcher!
    private var keys: KeyMonitor!
    private var accessItem: NSMenuItem!
    private var captureItem: NSMenuItem!
    private var lastNote = ""
    private var lastCaptureNote = ""
    var previewAndQuit = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        switcher = Switcher()
        keys = KeyMonitor(switcher: switcher)
        buildStatusItem()
        SystemHotkeys.installQuitHandler { [weak self] in
            self?.keys?.stop()
            NSApp.terminate(nil)
        }
        if previewAndQuit {
            switcher.open(forward: true, gesture: .none)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                fputs("preview-window \(self.switcher.panelWindowNumber)\n", stdout)
                fflush(stdout)
            }
            Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { _ in
                NSApp.terminate(nil)
            }
            return
        }
        askForMissingPermissions()
        refreshAccess()
        Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.refreshAccess()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        keys?.stop()
    }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let image = NSImage(systemSymbolName: "square.stack.3d.up.fill", accessibilityDescription: "Tab Switch") {
            image.isTemplate = true
            statusItem.button?.image = image
        } else {
            statusItem.button?.title = "⌥"
        }

        let menu = NSMenu()
        let show = menu.addItem(withTitle: "Switch Windows", action: #selector(showSwitcher), keyEquivalent: "")
        show.target = self
        menu.addItem(.separator())
        accessItem = menu.addItem(withTitle: "Accessibility", action: nil, keyEquivalent: "")
        captureItem = menu.addItem(withTitle: "Screen Recording", action: nil, keyEquivalent: "")
        let settings = menu.addItem(withTitle: "Open Accessibility Settings…", action: #selector(openAccess), keyEquivalent: "")
        settings.target = self
        let capture = menu.addItem(withTitle: "Open Screen Recording Settings…", action: #selector(openCapture), keyEquivalent: "")
        capture.target = self
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "Quit Tab Switch", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        statusItem.menu = menu
    }

    private func refreshAccess() {
        let trusted = accessibilityTrusted(prompt: false)
        accessItem?.title = trusted
            ? "Accessibility: on"
            : "Accessibility needed for ⌘Tab"
        let capture = CGPreflightScreenCaptureAccess()
        captureItem?.title = capture
            ? "Screen Recording: on"
            : "Screen Recording needed for previews"
        let captureNote = capture ? "capture on" : "capture off"
        if captureNote != lastCaptureNote {
            lastCaptureNote = captureNote
            note(captureNote)
        }
        if trusted {
            if !keys.isInstalled {
                let started = keys.start()
                remember(started ? "hotkey on" : "hotkey failed")
            }
        } else if keys.isInstalled {
            keys.stop()
            remember("hotkey off")
        } else {
            remember("needs access")
        }
    }

    private func remember(_ message: String) {
        guard message != lastNote else { return }
        lastNote = message
        note(message)
    }

    @objc private func showSwitcher() {
        switcher.open(forward: true, gesture: .none)
    }

    @objc private func openCapture() {
        requestScreenCaptureIfNeeded()
    }

    @objc private func openAccess() {
        _ = accessibilityTrusted(prompt: true)
        openAccessibilitySettings()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

/// Runs on every launch. The system shows its own screen recording prompt only once per app,
/// so when something is still missing we explain it ourselves and open the right settings.
func askForMissingPermissions() {
    let trusted = accessibilityTrusted(prompt: false)
    let capture = CGPreflightScreenCaptureAccess()
    guard !trusted || !capture else {
        NSApp.setActivationPolicy(.accessory)
        return
    }

    var missing: [String] = []
    if !trusted { missing.append("• Accessibility — to catch ⌘Tab and bring the chosen window forward") }
    if !capture { missing.append("• Screen Recording — to show window previews") }

    NSApp.setActivationPolicy(.regular)
    NSApp.activate()
    let alert = NSAlert()
    alert.messageText = "Tab Switch needs permissions"
    alert.informativeText = missing.joined(separator: "\n")
        + "\n\nTurn on Tab Switch in System Settings → Privacy & Security. "
        + "If it isn't listed, add it with the + button: \(Bundle.main.bundlePath)"
    alert.addButton(withTitle: "Open Settings")
    alert.addButton(withTitle: "Later")
    let answer = alert.runModal()

    guard answer == .alertFirstButtonReturn else {
        NSApp.setActivationPolicy(.accessory)
        return
    }
    if !trusted {
        _ = accessibilityTrusted(prompt: true)
    }
    if !capture {
        requestScreenCaptureIfNeeded()
    } else {
        NSApp.setActivationPolicy(.accessory)
        openAccessibilitySettings()
    }
}

func requestScreenCaptureIfNeeded() {
    guard !CGPreflightScreenCaptureAccess() else {
        NSApp.setActivationPolicy(.accessory)
        return
    }
    // A background-only app never gets a row in Screen Recording. Ask as a normal app.
    NSApp.setActivationPolicy(.regular)
    NSApp.activate()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
        _ = CGRequestScreenCaptureAccess()
        requestScreenCaptureViaSkyLight()
        Task {
            _ = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            DispatchQueue.main.async {
                NSApp.setActivationPolicy(.accessory)
                if !CGPreflightScreenCaptureAccess() {
                    openScreenCaptureSettings()
                }
            }
        }
    }
}

private func requestScreenCaptureViaSkyLight() {
    let handle = dlopen("/System/Library/Frameworks/ScreenCaptureKit.framework/ScreenCaptureKit", RTLD_LAZY)
    typealias Request = @convention(c) () -> UInt8
    guard let symbol = dlsym(handle, "SLSRequestScreenCaptureAccess") else { return }
    let request = unsafeBitCast(symbol, to: Request.self)
    _ = request()
}

private func note(_ message: String) {
    fputs("windowswitcher: \(message)\n", stderr)
    let path = "/tmp/windowswitcher.log"
    let line = "\(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    if FileManager.default.fileExists(atPath: path),
       let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
    } else {
        try? data.write(to: URL(fileURLWithPath: path))
    }
}

private func dumpWindows() {
    _ = NSApplication.shared
    let items = WindowLister.onScreenWindows()
    fputs("windows \(items.count)  ax \(accessibilityTrusted(prompt: false))\n", stdout)
    for item in items {
        let title = item.showsTitle ? item.title : "—"
        let b = item.cgBounds
        fputs(
            String(
                format: "%5u  pid %-6d  %5.0fx%-5.0f @ %5.0f,%-5.0f  %@  %@\n",
                item.id, item.pid, b.width, b.height, b.origin.x, b.origin.y, item.appName, title
            ),
            stdout
        )
    }
    let titles = WindowLister.titles(for: items, primaryHeight: primaryScreenHeight())
    fputs("ax titles \(titles.count)\n", stdout)
    for item in items {
        guard let title = titles[item.id] else { continue }
        fputs("  \(item.id)  \(item.appName)  \(title)\n", stdout)
    }
}

let arguments = CommandLine.arguments
if arguments.contains("--dump") {
    dumpWindows()
    exit(0)
}
if arguments.contains("--thumbs") {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let ids = WindowLister.onScreenWindows().map(\.id)
    fputs("capture \(CGPreflightScreenCaptureAccess()) windows \(ids.count)\n", stdout)
    Task {
        let batch = await Thumbnails.capture(ids)
        fputs("thumbs \(batch.images.count)/\(ids.count) \(batch.error ?? "")\n", stdout)
        for id in ids.sorted() {
            guard let image = batch.images[id] else { continue }
            fputs("  \(id) \(image.width)x\(image.height)\n", stdout)
        }
        fflush(stdout)
        exit(0)
    }
    app.run()
}

let app = NSApplication.shared
let delegate = AppDelegate()
delegate.previewAndQuit = arguments.contains("--preview")
app.delegate = delegate
if CGPreflightScreenCaptureAccess() {
    app.setActivationPolicy(.accessory)
}
app.run()
