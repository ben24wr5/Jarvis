import AppKit
import ApplicationServices

// MARK: - Accessibility permission

enum AccessibilityPermission {
    static var isGranted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt and opens System Settings at Privacy & Security → Accessibility.
    static func request() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        openSettings()
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Opening apps

enum AppFinder {
    private static var searchFolders: [URL] {
        let fm = FileManager.default
        var folders = [
            "/Applications", "/Applications/Utilities",
            "/System/Applications", "/System/Applications/Utilities",
            "/System/Library/CoreServices/Applications"
        ].map { URL(fileURLWithPath: $0) }
        folders.append(fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications"))
        return folders
    }

    static func simplify(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    static func allApps() -> [(name: String, url: URL)] {
        let fm = FileManager.default
        var result: [(String, URL)] = []
        for folder in searchFolders {
            guard let items = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { continue }
            for item in items where item.pathExtension == "app" {
                result.append((item.deletingPathExtension().lastPathComponent, item))
            }
            // One level of sub-folders (e.g. "/Applications/Microsoft Office/…")
            for sub in items where sub.pathExtension.isEmpty {
                if let inner = try? fm.contentsOfDirectory(at: sub, includingPropertiesForKeys: nil) {
                    for item in inner where item.pathExtension == "app" {
                        result.append((item.deletingPathExtension().lastPathComponent, item))
                    }
                }
            }
        }
        return result
    }

    /// Finds the installed app that best matches a spoken name.
    static func find(_ spoken: String) -> (name: String, url: URL)? {
        let target = simplify(spoken)
        guard !target.isEmpty else { return nil }
        let apps = allApps()
        if let exact = apps.first(where: { simplify($0.name) == target }) { return exact }
        if let prefix = apps.filter({ simplify($0.name).hasPrefix(target) })
            .min(by: { $0.name.count < $1.name.count }) { return prefix }
        if target.count >= 4,
           let contains = apps.filter({ simplify($0.name).contains(target) })
            .min(by: { $0.name.count < $1.name.count }) { return contains }
        // e.g. "visual studio code" said as "vs code"
        if let reverse = apps.first(where: { let n = simplify($0.name); n.count >= 4 && target.contains(n) }) { return reverse }
        return nil
    }

    static func open(_ url: URL) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config, completionHandler: nil)
    }
}

// MARK: - Browsers and websites

enum Browser: String {
    case firefox = "Firefox"
    case safari = "Safari"

    var bundleID: String {
        switch self {
        case .firefox: return "org.mozilla.firefox"
        case .safari: return "com.apple.Safari"
        }
    }

    var appURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    func open(_ url: URL) -> Bool {
        guard let appURL else { return false }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: config, completionHandler: nil)
        return true
    }
}

enum Website {
    static let known: [String: String] = [
        "youtube": "https://www.youtube.com",
        "google": "https://www.google.com",
        "gmail": "https://mail.google.com",
        "google maps": "https://maps.google.com",
        "maps": "https://maps.google.com",
        "netflix": "https://www.netflix.com",
        "facebook": "https://www.facebook.com",
        "instagram": "https://www.instagram.com",
        "twitter": "https://x.com",
        "x": "https://x.com",
        "reddit": "https://www.reddit.com",
        "amazon": "https://www.amazon.co.uk",
        "ebay": "https://www.ebay.co.uk",
        "bbc": "https://www.bbc.co.uk",
        "bbc news": "https://www.bbc.co.uk/news",
        "bbc sport": "https://www.bbc.co.uk/sport",
        "wikipedia": "https://www.wikipedia.org",
        "github": "https://github.com",
        "linkedin": "https://www.linkedin.com",
        "tiktok": "https://www.tiktok.com",
        "twitch": "https://www.twitch.tv",
        "chatgpt": "https://chatgpt.com",
        "claude": "https://claude.ai",
        "outlook": "https://outlook.live.com",
        "whatsapp": "https://web.whatsapp.com",
        "spotify web": "https://open.spotify.com",
        "disney plus": "https://www.disneyplus.com",
        "prime video": "https://www.primevideo.com",
        "iplayer": "https://www.bbc.co.uk/iplayer",
        "bbc iplayer": "https://www.bbc.co.uk/iplayer"
    ]

    /// Turns spoken words like "youtube", "bbc dot co dot uk" or "apple.com" into a web address.
    static func url(from spoken: String, force: Bool) -> URL? {
        var s = spoken.lowercased()
            .replacingOccurrences(of: " dot ", with: ".")
            .replacingOccurrences(of: " slash ", with: "/")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ",!?")))
        if let k = known[s] { return URL(string: k) }
        let compact = s.replacingOccurrences(of: " ", with: "")
        if let k = known[compact] { return URL(string: k) }
        if s.contains(".") {
            s = compact
            if !s.hasPrefix("http") { s = "https://" + s }
            return URL(string: s)
        }
        if force, !compact.isEmpty {
            return URL(string: "https://www.\(compact).com")
        }
        return nil
    }

    static func displayName(for spoken: String) -> String {
        spoken.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}

// MARK: - Keyboard

final class KeyboardController {
    private var lastExternalApp: NSRunningApplication?
    private var observer: NSObjectProtocol?

    init() {
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
            self?.lastExternalApp = app
        }
    }

    private static let keyCodes: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26,
        "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
        "return": 36, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43,
        "/": 44, "n": 45, "m": 46, ".": 47, "tab": 48, "space": 49, "`": 50,
        "delete": 51, "escape": 53,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100,
        "f9": 101, "f10": 109, "f11": 103, "f12": 111,
        "forwarddelete": 117, "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
        "left": 123, "right": 124, "down": 125, "up": 126
    ]

    /// Spoken words that mean a key.
    private static let aliases: [String: String] = [
        "enter": "return", "return": "return", "esc": "escape", "escape": "escape",
        "backspace": "delete", "delete": "delete", "spacebar": "space", "space": "space", "tab": "tab",
        "comma": ",", "period": ".", "full stop": ".", "dot": ".", "slash": "/", "minus": "-",
        "equals": "=", "plus": "=", "semicolon": ";", "quote": "'", "backslash": "\\",
        "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4", "five": "5",
        "six": "6", "seven": "7", "eight": "8", "nine": "9",
        "tea": "t", "tee": "t", "see": "c", "sea": "c", "you": "u", "why": "y", "are": "r", "ar": "r",
        "eye": "i", "oh": "o", "queue": "q", "cue": "q", "bee": "b", "be": "b", "pea": "p", "pee": "p",
        "jay": "j", "kay": "k", "el": "l", "em": "m", "en": "n", "ex": "x", "zed": "z", "zee": "z",
        "dee": "d", "ee": "e", "eff": "f", "gee": "g", "aitch": "h", "vee": "v", "ess": "s",
        "double you": "w", "doubleyou": "w",
        "arrow up": "up", "up arrow": "up", "arrow down": "down", "down arrow": "down",
        "arrow left": "left", "left arrow": "left", "arrow right": "right", "right arrow": "right",
        "page up": "pageup", "page down": "pagedown", "forward delete": "forwarddelete"
    ]

    private static let modifiers: [String: CGEventFlags] = [
        "command": .maskCommand, "cmd": .maskCommand, "commands": .maskCommand,
        "shift": .maskShift, "option": .maskAlternate, "alt": .maskAlternate,
        "control": .maskControl, "ctrl": .maskControl, "function": .maskSecondaryFn, "fn": .maskSecondaryFn
    ]

    /// Parses e.g. "command shift 4" or "command tea" into a key + modifiers.
    static func parseCombo(_ spoken: String) -> (CGKeyCode, CGEventFlags)? {
        var text = spoken.lowercased()
        for ch in ["+", "-", ",", "!", "?"] { text = text.replacingOccurrences(of: ch, with: " ") }
        text = text.replacingOccurrences(of: " and ", with: " ")
        for (phrase, key) in aliases where phrase.contains(" ") {
            text = text.replacingOccurrences(of: phrase, with: key)
        }
        var flags: CGEventFlags = []
        var key: CGKeyCode?
        for raw in text.split(separator: " ").map(String.init) {
            var word = raw.trimmingCharacters(in: .punctuationCharacters)
            if word.isEmpty { word = raw }
            if ["the", "key", "keys", "button", "please", "press", "hit"].contains(word) { continue }
            if let m = modifiers[word] { flags.insert(m); continue }
            let name = aliases[word] ?? word
            if let code = keyCodes[name] { key = code }
        }
        guard let key else { return nil }
        return (key, flags)
    }

    private func bringBackTargetApp(then work: @escaping () -> Void) {
        if NSApp.isActive, let target = lastExternalApp, !target.isTerminated {
            target.activate(options: [.activateIgnoringOtherApps])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
        }
    }

    func press(key: CGKeyCode, flags: CGEventFlags) {
        bringBackTargetApp {
            let src = CGEventSource(stateID: .hidSystemState)
            let down = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true)
            let up = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false)
            down?.flags = flags
            up?.flags = flags
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
        }
    }

    func type(_ text: String) {
        bringBackTargetApp {
            DispatchQueue.global(qos: .userInitiated).async {
                let src = CGEventSource(stateID: .hidSystemState)
                for scalar in text.utf16 {
                    var ch = scalar
                    let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true)
                    let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false)
                    down?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &ch)
                    up?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &ch)
                    down?.post(tap: .cghidEventTap)
                    up?.post(tap: .cghidEventTap)
                    usleep(12_000)
                }
            }
        }
    }
}
