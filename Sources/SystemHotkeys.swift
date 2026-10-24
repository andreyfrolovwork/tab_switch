import Darwin
import Foundation

/// Turns the system Command-Tab switcher off while this app owns that shortcut.
/// The setting survives quitting, so it is always turned back on before exit.
enum SystemHotkeys {
    private typealias SetFn = @convention(c) (Int32, Bool) -> Int32

    private static let setFn: SetFn? = {
        let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY)
        guard let symbol = dlsym(handle, "CGSSetSymbolicHotKeyEnabled") else { return nil }
        return unsafeBitCast(symbol, to: SetFn.self)
    }()

    private static var sources: [DispatchSourceSignal] = []

    static func setCommandTabEnabled(_ enabled: Bool) {
        guard let setFn else {
            fputs("windowswitcher: cmd-tab symbol missing\n", stderr)
            return
        }
        _ = setFn(1, enabled) // Command-Tab
        _ = setFn(2, enabled) // Shift-Command-Tab
        fputs(enabled ? "windowswitcher: system cmd-tab on\n" : "windowswitcher: system cmd-tab off\n", stderr)
    }

    static func installQuitHandler(_ body: @escaping () -> Void) {
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        for sig in [SIGTERM, SIGINT] {
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler(handler: body)
            source.resume()
            sources.append(source)
        }
    }
}
