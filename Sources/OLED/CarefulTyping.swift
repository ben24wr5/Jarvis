import AppKit
import ApplicationServices

/// Types text into a box (a website's search bar or the browser's address bar) the careful way:
/// 1. waits until the box REALLY has the cursor (clicking it if needed) — never types into thin air,
/// 2. empties it completely,
/// 3. types at a steady pace,
/// 4. checks the box now holds exactly the words; if not, clears it and types again (then, as a last
///    resort, puts the words in directly), and only then presses Return.
/// Runs on a background thread (it waits between steps).
enum CarefulTyping {
    private static func value(of field: AXUIElement) -> String {
        var ref: CFTypeRef?
        AXUIElementCopyAttributeValue(field, kAXValueAttribute as CFString, &ref)
        return (ref as? String) ?? ""
    }

    private static func isFocused(_ field: AXUIElement) -> Bool {
        var ref: CFTypeRef?
        AXUIElementCopyAttributeValue(field, kAXFocusedAttribute as CFString, &ref)
        return (ref as? Bool) ?? false
    }

    private static func onMain<T>(_ work: () -> T) -> T {
        Thread.isMainThread ? work() : DispatchQueue.main.sync(execute: work)
    }

    /// Gets the cursor into the box. Returns false if it just won't take it.
    @discardableResult
    static func focus(_ field: AXUIElement) -> Bool {
        for attempt in 0..<6 {
            onMain {
                AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                if attempt >= 1 { PageSearch.click(field) }
            }
            for _ in 0..<5 {
                usleep(80_000)
                if isFocused(field) { usleep(150_000); return true }
            }
        }
        return false
    }

    /// Empties the box: directly if allowed, otherwise by selecting everything in it so typing replaces it.
    static func clear(_ field: AXUIElement) {
        onMain {
            if AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, "" as CFString) != .success
                || !value(of: field).isEmpty {
                var range = CFRange(location: 0, length: value(of: field).utf16.count)
                if let r = AXValueCreate(.cfRange, &range) {
                    AXUIElementSetAttributeValue(field, kAXSelectedTextRangeAttribute as CFString, r)
                }
            }
        }
        usleep(120_000)
    }

    private static func normalised(_ s: String) -> String {
        s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Types `text` into `field` and makes sure that's exactly what's in it before pressing Return.
    static func enter(_ text: String, into field: AXUIElement, pressReturn: Bool) {
        guard focus(field) else {
            NSLog("OLED: the box wouldn't take the cursor; not typing")
            return
        }
        for attempt in 0..<3 {
            clear(field)
            if attempt < 2 {
                KeySender.type(text, delay: 45_000)
            } else {
                // Last resort: put the words straight into the box.
                onMain { _ = AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, text as CFString) }
            }
            usleep(300_000)
            let now = value(of: field)
            // Some boxes don't report what's in them; then trust the typing.
            // (The address bar may add a suggested ending after the typed text; that's fine.)
            if now.isEmpty || normalised(now) == normalised(text) || normalised(now).hasPrefix(normalised(text)) { break }
            NSLog("OLED: box held \"\(now)\" instead of \"\(text)\" — retyping")
            _ = focus(field)
        }
        if pressReturn {
            usleep(150_000)
            KeySender.combo(36, [])
        }
    }
}
