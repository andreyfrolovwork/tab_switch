import AppKit
import ApplicationServices

struct WindowItem {
    let id: CGWindowID
    let pid: pid_t
    let appName: String
    var title: String
    let cgBounds: CGRect
    let icon: NSImage
    var thumbnail: NSImage?

    var showsTitle: Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.caseInsensitiveCompare(appName) != .orderedSame
    }
}

enum WindowLister {
    private static let blockedOwners: Set<String> = [
        "Window Server",
        "Dock",
        "SystemUIServer",
        "Control Center",
        "Notification Center",
        "Spotlight",
        "Wallpaper",
        "WindowManager",
        "Window Switcher",
        "WindowSwitcher",
    ]

    static func onScreenWindows() -> [WindowItem] {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        var items: [WindowItem] = []
        var seenStacks = Set<String>()
        items.reserveCapacity(list.count)

        for info in list {
            guard let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue, layer == 0 else { continue }
            guard let pidNumber = info[kCGWindowOwnerPID as String] as? NSNumber else { continue }
            let pid = pid_t(pidNumber.int32Value)
            if pid == 0 || pid == ownPID { continue }

            let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            if alpha < 0.05 { continue }

            let owner = (info[kCGWindowOwnerName as String] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if owner.isEmpty || blockedOwners.contains(owner) { continue }

            guard let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict) else { continue }
            if bounds.width < 80 || bounds.height < 48 { continue }
            let stack = "\(pid):\(Int(bounds.minX)):\(Int(bounds.minY)):\(Int(bounds.width)):\(Int(bounds.height))"
            if seenStacks.contains(stack) { continue }
            seenStacks.insert(stack)

            let windowID = CGWindowID((info[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0)
            if windowID == 0 { continue }

            let cgTitle = (info[kCGWindowName as String] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let app = NSRunningApplication(processIdentifier: pid)
            let icon = app?.icon ?? NSWorkspace.shared.icon(for: .applicationBundle)

            items.append(WindowItem(
                id: windowID,
                pid: pid,
                appName: owner,
                title: cgTitle,
                cgBounds: bounds,
                icon: icon,
                thumbnail: nil
            ))
        }
        return items
    }

    /// Fills empty titles from Accessibility. Geometry matches a Quartz window to an AX window.
    static func titles(for items: [WindowItem], primaryHeight: CGFloat) -> [CGWindowID: String] {
        var found: [CGWindowID: String] = [:]
        for (pid, group) in Dictionary(grouping: items, by: \.pid) {
            let application = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(application, 0.2)
            let windows = axWindows(application)
            for item in group where !item.showsTitle {
                guard let match = bestMatch(in: windows, for: item, primaryHeight: primaryHeight) else { continue }
                let title = axString(match, kAXTitleAttribute).trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty {
                    found[item.id] = title
                }
            }
        }
        return found
    }
}

enum WindowActivator {
    static func activate(_ item: WindowItem) {
        let application = AXUIElementCreateApplication(item.pid)
        AXUIElementSetMessagingTimeout(application, 0.25)
        if let window = bestMatch(in: axWindows(application), for: item, primaryHeight: primaryScreenHeight()) {
            AXUIElementSetMessagingTimeout(window, 0.25)
            let minimized = axBool(window, kAXMinimizedAttribute)
            if minimized {
                AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            }
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        }
        AXUIElementSetAttributeValue(application, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        NSRunningApplication(processIdentifier: item.pid)?.activate()
    }
}

func accessibilityTrusted(prompt: Bool) -> Bool {
    guard prompt else { return AXIsProcessTrusted() }
    let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    let options = [key: true] as CFDictionary
    return AXIsProcessTrustedWithOptions(options)
}

func openAccessibilitySettings() {
    openSettings([
        "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility",
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
    ])
}

func openScreenCaptureSettings() {
    openSettings([
        "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture",
        "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
    ])
}

private func openSettings(_ candidates: [String]) {
    for raw in candidates {
        guard let url = URL(string: raw) else { continue }
        if NSWorkspace.shared.open(url) { return }
    }
}

private func axWindows(_ application: AXUIElement) -> [AXUIElement] {
    var raw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &raw) == .success else {
        return []
    }
    return raw as? [AXUIElement] ?? []
}

private func bestMatch(in windows: [AXUIElement], for item: WindowItem, primaryHeight: CGFloat) -> AXUIElement? {
    let target = cocoaRect(fromQuartz: item.cgBounds, primaryHeight: primaryHeight)
    var best: (element: AXUIElement, score: CGFloat)?
    for window in windows {
        guard let frame = axFrame(window) else { continue }
        let score = abs(frame.midX - target.midX)
            + abs(frame.midY - target.midY)
            + abs(frame.width - target.width)
            + abs(frame.height - target.height)
        if score > 120 { continue }
        if best == nil || score < best!.score {
            best = (window, score)
        }
    }
    return best?.element
}

private func axFrame(_ window: AXUIElement) -> CGRect? {
    guard let origin = axPoint(window, kAXPositionAttribute),
          let size = axSize(window, kAXSizeAttribute),
          size.width > 1, size.height > 1 else { return nil }
    return CGRect(origin: origin, size: size)
}

private func axPoint(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
    guard let raw = axValue(element, attribute) else { return nil }
    var point = CGPoint.zero
    guard AXValueGetType(raw) == .cgPoint, AXValueGetValue(raw, .cgPoint, &point) else { return nil }
    return point
}

private func axSize(_ element: AXUIElement, _ attribute: String) -> CGSize? {
    guard let raw = axValue(element, attribute) else { return nil }
    var size = CGSize.zero
    guard AXValueGetType(raw) == .cgSize, AXValueGetValue(raw, .cgSize, &size) else { return nil }
    return size
}

private func axValue(_ element: AXUIElement, _ attribute: String) -> AXValue? {
    var raw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success, let raw else {
        return nil
    }
    guard CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
    return (raw as! AXValue)
}

private func axString(_ element: AXUIElement, _ attribute: String) -> String {
    var raw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success else { return "" }
    return raw as? String ?? ""
}

private func axBool(_ element: AXUIElement, _ attribute: String) -> Bool {
    var raw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success else { return false }
    return (raw as? Bool) ?? false
}

func primaryScreenHeight() -> CGFloat {
    NSScreen.screens.first { $0.frame.origin == .zero }?.frame.height
        ?? NSScreen.main?.frame.height
        ?? 0
}

/// Quartz window bounds use the top-left of the main display. Accessibility uses Cocoa points.
func cocoaRect(fromQuartz bounds: CGRect, primaryHeight: CGFloat) -> CGRect {
    CGRect(
        x: bounds.origin.x,
        y: primaryHeight - bounds.origin.y - bounds.height,
        width: bounds.width,
        height: bounds.height
    )
}
