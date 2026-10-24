import AppKit
import CoreGraphics

final class KeyMonitor {
    private weak var switcher: Switcher?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var commandIsDown = false
    private var optionIsDown = false
    private var disabledSystemSwitch = false

    init(switcher: Switcher) {
        self.switcher = switcher
    }

    var isInstalled: Bool { tap != nil }

    @discardableResult
    func start() -> Bool {
        if tap != nil { return true }
        let mask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: keyTapCallback,
            userInfo: userInfo
        ) else {
            return false
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        SystemHotkeys.setCommandTabEnabled(false)
        disabledSystemSwitch = true
        return true
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        tap = nil
        source = nil
        if disabledSystemSwitch {
            SystemHotkeys.setCommandTabEnabled(true)
            disabledSystemSwitch = false
        }
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard let switcher else { return Unmanaged.passUnretained(event) }
        if consume(type: type, event: event, switcher: switcher) {
            return nil
        }
        return Unmanaged.passUnretained(event)
    }

    private func consume(type: CGEventType, event: CGEvent, switcher: Switcher) -> Bool {
        let flags = event.flags
        let option = flags.contains(.maskAlternate)
        let command = flags.contains(.maskCommand)
        let control = flags.contains(.maskControl)
        let shift = flags.contains(.maskShift)
        let key = event.getIntegerValueField(.keyboardEventKeycode)

        if type == .flagsChanged {
            let wasCommand = commandIsDown
            let wasOption = optionIsDown
            commandIsDown = command
            optionIsDown = option
            if switcher.isShown && wasCommand && !command {
                switcher.modifierReleased(command: true)
            } else if switcher.isShown && wasOption && !option {
                switcher.modifierReleased(command: false)
            }
            return false
        }
        guard type == .keyDown else { return false }
        if command { commandIsDown = true }
        if option { optionIsDown = true }

        if !switcher.isShown {
            guard key == Key.tab, !control else { return false }
            if command {
                switcher.open(forward: !shift, gesture: .command)
                return true
            }
            if option {
                switcher.open(forward: !shift, gesture: .option)
                return true
            }
            return false
        }

        switch key {
        case Key.tab:
            switcher.move(by: shift ? -1 : 1)
            return true
        case Key.left:
            switcher.move(by: -1)
            return true
        case Key.right:
            switcher.move(by: 1)
            return true
        case Key.up:
            switcher.moveLine(by: -1)
            return true
        case Key.down:
            switcher.moveLine(by: 1)
            return true
        case Key.return, Key.keypadEnter:
            switcher.confirm()
            return true
        case Key.escape:
            switcher.cancel()
            return true
        default:
            return true
        }
    }
}

private enum Key {
    static let tab: Int64 = 48
    static let escape: Int64 = 53
    static let `return`: Int64 = 36
    static let keypadEnter: Int64 = 76
    static let left: Int64 = 123
    static let right: Int64 = 124
    static let down: Int64 = 125
    static let up: Int64 = 126
}

private func keyTapCallback(
    _ proxy: CGEventTapProxy,
    _ type: CGEventType,
    _ event: CGEvent,
    _ userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<KeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
    return monitor.handle(type: type, event: event)
}
