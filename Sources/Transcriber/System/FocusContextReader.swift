import AppKit
import ApplicationServices
import CoreGraphics
import TranscriberAPI

/// Reads which apps surround a take, kept as data only. Reads app names, window
/// titles and web page addresses. Never reads document text, field values or
/// selections, and never activates an app. Not main-actor isolated, so the async
/// reads run off the main actor and another app's AX IPC never stalls the UI.
enum FocusContextReader {
    /// Focus and the open apps when a take starts.
    static func startContext() async -> AppContext {
        let open = openApplications()
        return AppContext(start: await snapshot(), openApplications: open.isEmpty ? nil : open)
    }

    /// Regular apps: apps with on-screen windows front to back, then the rest by name.
    static func openApplications() -> [ApplicationIdentity] {
        // Owner PIDs need no Screen Recording permission. Window names are never read.
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        var rank: [pid_t: Int] = [:]
        for window in windows where window[kCGWindowLayer as String] as? Int == 0 {
            if let pid = window[kCGWindowOwnerPID as String] as? pid_t, rank[pid] == nil { rank[pid] = rank.count }
        }
        let own = ProcessInfo.processInfo.processIdentifier
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != own }
            .sorted { lhs, rhs in
                switch (rank[lhs.processIdentifier], rank[rhs.processIdentifier]) {
                case let (left?, right?): left < right
                case (_?, nil): true
                case (nil, _?): false
                case (nil, nil): (lhs.localizedName ?? "").localizedStandardCompare(rhs.localizedName ?? "") == .orderedAscending
                }
            }
        return Array(apps.lazy.compactMap(identity(of:)).prefix(256))
    }

    /// Where keyboard focus is now. Every AX read has a short timeout and the
    /// whole read stops near 0.7 s, so a hung app cannot hold it past 1 s.
    static func snapshot() async -> FocusSnapshot? {
        let deadline = ProcessInfo.processInfo.systemUptime + 0.7
        func canRead() -> Bool { !Task.isCancelled && ProcessInfo.processInfo.systemUptime < deadline }
        func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
            guard canRead() else { return nil }
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
        }
        func element(_ name: String, of element: AXUIElement) -> AXUIElement? {
            guard let value = attribute(name, of: element), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return (value as! AXUIElement)
        }

        var application: NSRunningApplication?
        var window: AXUIElement?
        var webAddress: (url: String, host: String)?
        if AXIsProcessTrusted() {
            let system = AXUIElementCreateSystemWide()
            AXUIElementSetMessagingTimeout(system, 0.2)
            var pid: pid_t = 0
            if let app = element(kAXFocusedApplicationAttribute, of: system),
               AXUIElementGetPid(app, &pid) == .success, pid > 0 {
                application = NSRunningApplication(processIdentifier: pid)
                AXUIElementSetMessagingTimeout(app, 0.2)
                window = element(kAXFocusedWindowAttribute, of: app)
                // The web page that holds focus: walk up to its web area.
                var current = element(kAXFocusedUIElementAttribute, of: app)
                for _ in 0..<40 {
                    guard let node = current else { break }
                    AXUIElementSetMessagingTimeout(node, 0.05)
                    let role = attribute(kAXRoleAttribute, of: node) as? String
                    if role == "AXWebArea" { webAddress = sanitizedWebAddress(attribute(kAXURLAttribute, of: node)); break }
                    if role == nil || role == kAXWindowRole || role == kAXApplicationRole { break }
                    current = element(kAXParentAttribute, of: node)
                }
            }
        }
        guard !Task.isCancelled else { return nil }
        if application == nil { application = NSWorkspace.shared.frontmostApplication }
        guard let application, let identity = identity(of: application) else { return nil }
        let title = window.flatMap { attribute(kAXTitleAttribute, of: $0) as? String }.flatMap { clipped($0, to: 1_024) }
        if webAddress == nil, let window { webAddress = sanitizedWebAddress(attribute(kAXDocumentAttribute, of: window)) }
        return FocusSnapshot(capturedAt: Date(), application: identity, windowTitle: title,
                             url: webAddress?.url, host: webAddress?.host)
    }

    private static func identity(of application: NSRunningApplication) -> ApplicationIdentity? {
        // A cut bundle ID would name another app, so an overlong one is dropped.
        let bundleID = application.bundleIdentifier.flatMap { $0.utf16.count <= 255 ? clipped($0, to: 255) : nil }
        let name = application.localizedName.flatMap { clipped($0, to: 255) }
        guard bundleID != nil || name != nil else { return nil }
        return ApplicationIdentity(bundleID: bundleID, name: name)
    }

    /// Trims, drops an empty value and cuts whole characters to the UTF-16 limit.
    private static func clipped(_ value: String, to limit: Int) -> String? {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.utf16.count > limit { text.removeLast() }
        return text.isEmpty ? nil : text
    }

    /// Scheme, host, port and path of an http or https address only.
    private static func sanitizedWebAddress(_ value: CFTypeRef?) -> (url: String, host: String)? {
        guard let address = (value as? URL) ?? (value as? String).flatMap(URL.init(string:)),
              var components = URLComponents(url: address, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host?.lowercased(), !host.isEmpty, host.utf16.count <= 255 else { return nil }
        components.scheme = scheme
        components.user = nil; components.password = nil
        components.query = nil; components.fragment = nil
        guard let url = components.string, url.utf16.count <= 2_048 else { return nil }
        return (url, host)
    }
}
