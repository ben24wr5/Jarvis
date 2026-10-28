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

// MARK: - Power: shut down, restart, sleep, lock

enum PowerAction {
    case shutDown, restart, logOut, sleep, lock

    var confirmQuestion: String? {
        switch self {
        case .shutDown: return "Are you sure you want me to shut down your Mac?"
        case .restart: return "Are you sure you want me to restart your Mac?"
        case .logOut: return "Are you sure you want me to log you out?"
        default: return nil
        }
    }

    var goodbye: String {
        switch self {
        case .shutDown: return "Shutting down. Goodbye."
        case .restart: return "Restarting. See you in a moment."
        case .logOut: return "Logging you out. Goodbye."
        case .sleep: return "Putting your Mac to sleep."
        case .lock: return "Locking the screen."
        }
    }

    /// Recognises "shut down", "turn off the computer", "restart", "reboot", "sleep", "lock the screen"…
    static func from(_ text: String) -> PowerAction? {
        let t = " " + text + " "
        let machine = ["mac", "computer", "laptop", "macbook", "imac", "system", "pc"]
        let mentionsMachine = machine.contains { t.contains(" \($0) ") || t.contains(" \($0)") }
        if t.contains(" shut down") || t.contains(" shutdown") || t.contains(" power off") || t.contains(" power down")
            || (t.contains(" turn off") && mentionsMachine) || (t.contains(" switch off") && mentionsMachine) {
            return .shutDown
        }
        if t.contains(" restart") || t.contains(" reboot") { return .restart }
        if t.contains(" log out") || t.contains(" logout") || t.contains(" log me out") || t.contains(" log off")
            || t.contains(" sign out") || t.contains(" sign me out") {
            return .logOut
        }
        if t.contains(" lock") && (t.contains(" screen") || mentionsMachine || text.trimmingCharacters(in: .whitespaces) == "lock") {
            return .lock
        }
        if (t.contains(" sleep") && (mentionsMachine || text.trimmingCharacters(in: .whitespaces) == "sleep"))
            || t.contains(" sleep mode") {
            return .sleep
        }
        return nil
    }

    func perform() {
        switch self {
        case .shutDown: Self.runAppleScript("tell application \"System Events\" to shut down")
        case .restart: Self.runAppleScript("tell application \"System Events\" to restart")
        case .logOut:
            // Log out straight away (already confirmed by voice), without macOS's extra dialog.
            Self.run("/usr/bin/osascript", ["-e", "tell application \"loginwindow\" to «event aevtrlgo»"])
        case .sleep: Self.run("/usr/bin/pmset", ["sleepnow"])
        case .lock:
            // Control-Command-Q: the standard macOS "Lock Screen" shortcut.
            KeySender.combo(12, [.maskCommand, .maskControl])
        }
    }

    private static func runAppleScript(_ source: String) {
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if error != nil {
            // Fallback if Automation permission was refused: ask the login window directly.
            run("/usr/bin/osascript", ["-e", source.contains("restart")
                ? "tell application \"loginwindow\" to «event aevtrrst»"
                : "tell application \"loginwindow\" to «event aevtrsdn»"])
        }
    }

    private static func run(_ path: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        try? p.run()
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

    /// What people say vs. what the app is called (or how speech recognition writes it).
    private static let aliases: [String: String] = [
        "whatsup": "whatsapp", "whatsapp": "whatsapp", "whatsupp": "whatsapp", "whatsap": "whatsapp",
        "settings": "systemsettings", "systempreferences": "systemsettings", "preferences": "systemsettings",
        "vscode": "visualstudiocode", "vs": "visualstudiocode", "code": "visualstudiocode",
        "word": "microsoftword", "excel": "microsoftexcel", "powerpoint": "microsoftpowerpoint",
        "outlook": "microsoftoutlook", "teams": "microsoftteams", "onenote": "microsoftonenote",
        "chrome": "googlechrome", "google": "googlechrome", "edge": "microsoftedge",
        "files": "finder", "finder": "finder", "terminal": "terminal", "the terminal": "terminal",
        "appstore": "appstore", "store": "appstore", "itunes": "music", "applemusic": "music",
        "appletv": "tv", "imessage": "messages", "message": "messages", "text": "messages",
        "photo": "photos", "picture": "photos", "pictures": "photos", "camera": "photobooth",
        "calculator": "calculator", "calc": "calculator", "clock": "clock", "alarm": "clock",
        "activitymonitor": "activitymonitor", "taskmanager": "activitymonitor",
        "facetime": "facetime", "zoom": "zoomus", "capcut": "capcut", "steam": "steam",
        "notes": "notes", "note": "notes", "reminder": "reminders", "calendar": "calendar",
        "mail": "mail", "email": "mail", "maps": "maps", "map": "maps", "weatherapp": "weather"
    ]

    private static var cache: [(name: String, key: String, url: URL)] = []
    private static var cacheTime = Date.distantPast

    /// Every app on the Mac: the usual folders plus everything Spotlight knows about.
    static func allApps() -> [(name: String, key: String, url: URL)] {
        if Date().timeIntervalSince(cacheTime) < 60, !cache.isEmpty { return cache }
        let fm = FileManager.default
        var urls = Set<URL>()
        for folder in searchFolders {
            guard let items = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { continue }
            for item in items where item.pathExtension == "app" { urls.insert(item.resolvingSymlinksInPath()) }
            for sub in items where sub.pathExtension.isEmpty {
                if let inner = try? fm.contentsOfDirectory(at: sub, includingPropertiesForKeys: nil) {
                    for item in inner where item.pathExtension == "app" { urls.insert(item.resolvingSymlinksInPath()) }
                }
            }
        }
        for path in spotlightApps() { urls.insert(URL(fileURLWithPath: path)) }

        var result: [(String, String, URL)] = []
        for url in urls {
            // Skip helper apps buried inside other apps.
            if url.path.components(separatedBy: ".app/").count > 1 { continue }
            var names = [url.deletingPathExtension().lastPathComponent]
            if let bundle = Bundle(url: url) {
                for key in ["CFBundleDisplayName", "CFBundleName"] {
                    if let n = bundle.localizedInfoDictionary?[key] as? String ?? bundle.infoDictionary?[key] as? String {
                        names.append(n)
                    }
                }
            }
            names.append(FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""))
            for n in Set(names) where !simplify(n).isEmpty {
                result.append((n, simplify(n), url))
            }
        }
        cache = result
        cacheTime = Date()
        return result
    }

    /// Asks Spotlight for every application on the Mac.
    private static func spotlightApps() -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        p.arguments = ["kMDItemContentType == 'com.apple.application-bundle'"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
            .filter { $0.hasSuffix(".app") && !$0.contains("/Library/Developer/") }
    }

    /// Finds the installed app that best matches a spoken name.
    /// `allowLoose: false` only accepts an exact name or nickname — used when the words are also a
    /// well-known website ("gmail" shouldn't open Mail, "bbc news" shouldn't open Apple News).
    static func find(_ spoken: String, allowLoose: Bool = true) -> (name: String, url: URL)? {
        var target = simplify(spoken)
        guard !target.isEmpty else { return nil }
        let apps = allApps()
        func pick(_ list: [(name: String, key: String, url: URL)]) -> (name: String, url: URL)? {
            guard let best = list.min(by: { $0.key.count < $1.key.count }) else { return nil }
            return (best.name, best.url)
        }

        // 1. Exact name (then a known nickname: "settings" → System Settings, "what's up" → WhatsApp)
        if let exact = pick(apps.filter { $0.key == target }) { return exact }
        if let alias = aliases[target] {
            target = alias
            if let exact = pick(apps.filter { $0.key == target }) { return exact }
        }
        guard allowLoose else { return nil }
        // 2. Starts with what was said: "spot" → Spotify, "microsoft" → Microsoft Word…
        if target.count >= 3, let prefix = pick(apps.filter { $0.key.hasPrefix(target) }) { return prefix }
        // 3. Contains it: "word" → Microsoft Word
        if target.count >= 4, let contains = pick(apps.filter { $0.key.contains(target) }) { return contains }
        // 4. What was said contains the app's name: "the spotify music app" → Spotify
        //    (the app's name must be most of what was said, so "bbc news" doesn't open Apple News)
        if let reverse = apps.filter({ $0.key.count >= 4 && target.contains($0.key)
                                       && Double($0.key.count) >= Double(target.count) * 0.6 })
            .max(by: { $0.key.count < $1.key.count }) { return (reverse.name, reverse.url) }
        // 5. Every spoken word appears in the name: "studio code" → Visual Studio Code
        let words = spoken.lowercased().split(separator: " ").map { simplify(String($0)) }.filter { $0.count >= 2 }
        if words.count >= 2, let all = pick(apps.filter { app in words.allSatisfy { app.key.contains($0) } }) { return all }
        // 6. Close spelling (speech recognition is rarely letter-perfect): "spotfy", "discored"
        let allowed = target.count <= 4 ? 1 : (target.count <= 8 ? 2 : 3)
        let close = apps.map { ($0, distance(target, $0.key)) }.filter { $0.1 <= allowed }
        if let best = close.min(by: { $0.1 < $1.1 || ($0.1 == $1.1 && $0.0.key.count < $1.0.key.count) }) {
            return (best.0.name, best.0.url)
        }
        // 7. Last try: ask macOS itself to resolve the name.
        if let url = launchServicesApp(named: spoken) {
            return (url.deletingPathExtension().lastPathComponent, url)
        }
        return nil
    }

    /// Lets macOS look an app up by name, the same way `open -a Name` does.
    private static func launchServicesApp(named name: String) -> URL? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              let path = NSWorkspace.shared.fullPath(forApplication: trimmed) else { return nil }
        return URL(fileURLWithPath: path)
    }

    private static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        if abs(a.count - b.count) > 3 { return 99 }
        var prev = Array(0...b.count)
        for i in 1...a.count {
            var cur = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[b.count]
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
        "bbc iplayer": "https://www.bbc.co.uk/iplayer",
        "bbc weather": "https://www.bbc.co.uk/weather",
        "youtube music": "https://music.youtube.com",
        "google drive": "https://drive.google.com",
        "google docs": "https://docs.google.com",
        "google translate": "https://translate.google.com",
        "the guardian": "https://www.theguardian.com",
        "guardian": "https://www.theguardian.com",
        "sky news": "https://news.sky.com",
        "sky sports": "https://www.skysports.com",
        "itv": "https://www.itv.com",
        "itvx": "https://www.itv.com",
        "channel 4": "https://www.channel4.com",
        "argos": "https://www.argos.co.uk",
        "tesco": "https://www.tesco.com",
        "asda": "https://www.asda.com",
        "sainsburys": "https://www.sainsburys.co.uk",
        "john lewis": "https://www.johnlewis.com",
        "currys": "https://www.currys.co.uk",
        "rightmove": "https://www.rightmove.co.uk",
        "pinterest": "https://www.pinterest.com",
        "snapchat": "https://www.snapchat.com",
        "discord": "https://discord.com",
        "roblox": "https://www.roblox.com",
        "apple": "https://www.apple.com",
        "microsoft": "https://www.microsoft.com",
        "yahoo": "https://www.yahoo.com",
        "bing": "https://www.bing.com",
        "duckduckgo": "https://duckduckgo.com",
        "paypal": "https://www.paypal.com",
        "nhs": "https://www.nhs.uk",
        "gov uk": "https://www.gov.uk",
        "gov.uk": "https://www.gov.uk",
        "premier league": "https://www.premierleague.com",
        "espn": "https://www.espn.com",
        "imdb": "https://www.imdb.com",
        "deliveroo": "https://deliveroo.co.uk",
        "just eat": "https://www.just-eat.co.uk",
        "uber eats": "https://www.ubereats.com",
        "booking": "https://www.booking.com",
        "airbnb": "https://www.airbnb.co.uk"
    ]

    /// Turns spoken words like "youtube", "bbc dot co dot uk" or "apple.com" into a web address.
    static func url(from spoken: String, force: Bool) -> URL? {
        var s = spoken.lowercased()
            .replacingOccurrences(of: " dot ", with: ".")
            .replacingOccurrences(of: " slash ", with: "/")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ",!?")))
        if let k = known[s] { return URL(string: k) }
        if s.hasPrefix("the "), let k = known[String(s.dropFirst(4))] { return URL(string: k) }
        let compact = s.replacingOccurrences(of: " ", with: "")
        if let k = known[compact] { return URL(string: k) }
        if s.contains(".") {
            s = compact
            if !s.hasPrefix("http") { s = "https://" + s }
            return URL(string: s)
        }
        guard !compact.isEmpty else { return nil }
        _ = force
        // Any other site by name ("the guardian", "argos"): its real address is found when opening it.
        var c = URLComponents()
        c.scheme = lookupScheme
        c.host = "site"
        c.queryItems = [URLQueryItem(name: "name", value: s)]
        return c.url
    }

    static let lookupScheme = "oled-lookup"

    /// For a website given by name, finds its real address — e.g. "the guardian" → theguardian.com —
    /// by checking which address actually exists and following it to the site's own address.
    /// Gives back the URL and the exact text to type. If no site exists, it's a Google search.
    static func resolve(_ url: URL, completion: @escaping (URL, String) -> Void) {
        guard url.scheme == lookupScheme,
              let name = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value else {
            var typed = url.absoluteString
            for scheme in ["https://", "http://"] where typed.hasPrefix(scheme) { typed.removeFirst(scheme.count) }
            if typed.hasSuffix("/") { typed.removeLast() }
            completion(url, typed)
            return
        }
        var words = name.lowercased()
        for tail in [" website", " web site", " site", " homepage", " home page"] where words.hasSuffix(tail) {
            words.removeLast(tail.count)
        }
        let compact = words.filter { $0.isLetter || $0.isNumber }
        let noThe = words.hasPrefix("the ") ? String(words.dropFirst(4)).filter { $0.isLetter || $0.isNumber } : compact
        let uk = Locale.current.region?.identifier == "GB"
        let endings = uk ? ["co.uk", "com", "org.uk", "org", "net", "tv", "io"] : ["com", "co.uk", "org", "net", "tv", "io"]
        var candidates: [String] = []
        for base in [compact, noThe] where !base.isEmpty {
            for e in endings {
                let d = "\(base).\(e)"
                if !candidates.contains(d) { candidates.append(d) }
            }
        }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 4
        let session = URLSession(configuration: config)

        func tryNext(_ index: Int) {
            guard index < candidates.count else {
                // No website by that name: search for exactly what was said.
                var g = URLComponents(string: "https://www.google.com/search")!
                g.queryItems = [URLQueryItem(name: "q", value: name)]
                DispatchQueue.main.async { completion(g.url!, name) }
                return
            }
            guard let probe = URL(string: "https://\(candidates[index])") else { tryNext(index + 1); return }
            var request = URLRequest(url: probe)
            request.httpMethod = "GET"
            request.setValue("Mozilla/5.0 (Macintosh) OLED", forHTTPHeaderField: "User-Agent")
            session.dataTask(with: request) { _, response, error in
                guard error == nil, let http = response as? HTTPURLResponse, http.statusCode < 500,
                      let final = http.url ?? Optional(probe), let host = final.host else {
                    tryNext(index + 1); return
                }
                // Type the site's own address (after any redirect), e.g. www.theguardian.com
                let siteURL = URL(string: "https://\(host)") ?? probe
                DispatchQueue.main.async { completion(siteURL, host) }
            }.resume()
        }
        tryNext(0)
    }

    /// True for well-known websites ("youtube", "gmail", "bbc news"…).
    static func isKnownSite(_ spoken: String) -> Bool {
        let s = spoken.lowercased().trimmingCharacters(in: .whitespaces)
        return known[s] != nil || known[s.replacingOccurrences(of: " ", with: "")] != nil
    }

    static func displayName(for spoken: String) -> String {
        spoken.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}

// MARK: - Keyboard

final class KeyboardController {
    private(set) var lastExternalApp: NSRunningApplication?
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
        // If OLED's own window is in front, hand the keys back to the app you were using.
        if NSApp.isActive, let target = lastExternalApp, !target.isTerminated {
            if #available(macOS 14.0, *) {
                NSApp.yieldActivation(to: target)
                target.activate()
            } else {
                target.activate(options: [.activateIgnoringOtherApps])
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
        }
    }

    /// Opens the browser, starts a new tab, types the address and presses Return — like doing it on the keyboard.
    /// Opens the browser, makes sure it's really in front, then presses Command-T, types the address and
    /// presses Return — exactly like doing it on the keyboard. If the browser can't be brought to the
    /// front, the website is opened in it directly instead, so you always end up on the site.
    /// Where to open a website: a new tab, a new window, or the current (empty) tab.
    enum Place { case newTab, newWindow, current }

    /// `afterOpen` runs once the website has been opened (e.g. to then search inside the page).
    func typeAddress(_ address: String, url: URL, in browser: Browser, place: Place = .current,
                     afterOpen: (() -> Void)? = nil) {
        let opened: () -> Void = { if let afterOpen { DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: afterOpen) } }
        guard let appURL = browser.appURL else { return }
        let alreadyRunning = NSRunningApplication.runningApplications(withBundleIdentifier: browser.bundleID)
            .contains { !$0.isTerminated }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: appURL, configuration: config) { app, _ in
            DispatchQueue.main.async { Self.bringToFront(browser, app: app) }
        }

        Self.waitUntilFront(browser, until: Date().addingTimeInterval(6)) { inFront in
            guard inFront else {
                // Couldn't get the browser in front: open the website in it directly.
                _ = browser.open(url); opened()
                return
            }
            // A freshly opened browser needs a moment for its window to be ready.
            let settle = alreadyRunning ? 0.35 : 1.5
            DispatchQueue.main.asyncAfter(deadline: .now() + settle) {
                guard Self.isFront(browser) else { _ = browser.open(url); opened(); return }
                // You asked for a new tab or window: open it first (that's the only time OLED uses a shortcut).
                var wait = 0.0
                switch place {
                case .newWindow: KeySender.combo(45, .maskCommand); wait = 1.0   // Command-N
                case .newTab: KeySender.combo(17, .maskCommand); wait = 0.8      // Command-T
                case .current: break
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
                    // Click straight into the address bar (no shortcut), empty it, type exactly the address,
                    // check it's right, then press Return.
                    guard Self.isFront(browser), let field = AddressBar.field(in: browser) else {
                        _ = browser.open(url); opened() // couldn't reach the address bar: open the site directly
                        return
                    }
                    DispatchQueue.global(qos: .userInitiated).async {
                        CarefulTyping.enter(address, into: field, pressReturn: true)
                        DispatchQueue.main.async {
                            Self.makeSureItOpened(url, in: browser)
                            opened()
                        }
                    }
                }
            }
        }
    }

    /// After pressing Return the page should load and the cursor leaves the address bar. If it's still
    /// sitting in the address bar, press Return once more so the website really opens.
    private static func makeSureItOpened(_ url: URL, in browser: Browser) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            guard isFront(browser), AddressBar.isEditing(in: browser) else { return }
            post(key: 36, flags: [])
        }
    }

    private static func isFront(_ browser: Browser) -> Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == browser.bundleID
    }

    /// Uses every method macOS allows to bring the browser to the front.
    private static func bringToFront(_ browser: Browser, app: NSRunningApplication?) {
        let running = app ?? NSRunningApplication.runningApplications(withBundleIdentifier: browser.bundleID).first
        if let running {
            if #available(macOS 14.0, *) {
                NSApp.yieldActivation(to: running)
                running.activate()
            } else {
                running.activate(options: [.activateIgnoringOtherApps])
            }
        }
        // Apple's scripting "activate" is always allowed to bring an app forward.
        var error: NSDictionary?
        NSAppleScript(source: "tell application id \"\(browser.bundleID)\" to activate")?.executeAndReturnError(&error)
    }

    private static func waitUntilFront(_ browser: Browser, until deadline: Date, then done: @escaping (Bool) -> Void) {
        if isFront(browser) { done(true); return }
        if Date() > deadline { done(false); return }
        // Keep nudging it forward while waiting (it may still be launching).
        if Int(Date().timeIntervalSince1970 * 10) % 10 == 0 { bringToFront(browser, app: nil) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            waitUntilFront(browser, until: deadline, then: done)
        }
    }

    private static func post(key: CGKeyCode, flags: CGEventFlags) {
        KeySender.combo(key, flags)
    }

    private static func typeNow(_ text: String) {
        KeySender.type(text, delay: 30_000)
    }

    func press(key: CGKeyCode, flags: CGEventFlags) {
        bringBackTargetApp { KeySender.combo(key, flags) }
    }

    func type(_ text: String) {
        bringBackTargetApp {
            DispatchQueue.global(qos: .userInitiated).async { KeySender.type(text, delay: 15_000) }
        }
    }
}

/// Finds Safari's or Firefox's address bar through Accessibility and puts the cursor in it, empty,
/// the same as clicking on it — without using any keyboard shortcut.
enum AddressBar {
    static func field(in browser: Browser) -> AXUIElement? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: browser.bundleID)
            .first(where: { !$0.isTerminated }) else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        for attr in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            var windowRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(axApp, attr as CFString, &windowRef) == .success,
               let windowRef, CFGetTypeID(windowRef) == AXUIElementGetTypeID(),
               let found = findField(from: windowRef as! AXUIElement) {
                return found
            }
        }
        return nil
    }

    /// True when the browser's current tab already shows a website (so typing there would replace it).
    /// False when there's no window, or the tab is empty / a start page.
    static func currentTabHasWebsite(in browser: Browser) -> Bool {
        guard AccessibilityPermission.isGranted, let field = field(in: browser) else { return false }
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(field, kAXValueAttribute as CFString, &value)
        let text = ((value as? String) ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        let empty = ["", "favorites", "favourites", "start page", "about:blank", "about:newtab", "about:home",
                     "search or enter website name", "search with google or enter address", "top sites"]
        return !empty.contains(text) && !text.hasPrefix("about:")
    }

    /// True while the cursor is still in the address bar (i.e. the website hasn't been opened yet).
    static func isEditing(in browser: Browser) -> Bool {
        guard let field = field(in: browser) else { return false }
        var focused: CFTypeRef?
        AXUIElementCopyAttributeValue(field, kAXFocusedAttribute as CFString, &focused)
        return (focused as? Bool) ?? false
    }

    static func focus(in browser: Browser) -> Bool {
        guard let field = field(in: browser) else { return false }

        AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        // Empty it so the new address replaces the old one rather than being added to it.
        if AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, "" as CFString) != .success {
            var value: CFTypeRef?
            AXUIElementCopyAttributeValue(field, kAXValueAttribute as CFString, &value)
            let length = (value as? String)?.utf16.count ?? 0
            var range = CFRange(location: 0, length: length)
            if let rangeValue = AXValueCreate(.cfRange, &range) {
                AXUIElementSetAttributeValue(field, kAXSelectedTextRangeAttribute as CFString, rangeValue)
            }
        }
        // Confirm it really has the cursor.
        var focused: CFTypeRef?
        AXUIElementCopyAttributeValue(field, kAXFocusedAttribute as CFString, &focused)
        return (focused as? Bool) ?? true
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> String {
        var ref: CFTypeRef?
        AXUIElementCopyAttributeValue(element, name as CFString, &ref)
        return (ref as? String) ?? ""
    }

    /// Searches the window's controls (not the web page itself) for the address field.
    private static func findField(from window: AXUIElement) -> AXUIElement? {
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var fallback: AXUIElement?
        var visited = 0
        while !queue.isEmpty, visited < 600 {
            let (element, depth) = queue.removeFirst()
            visited += 1
            let role = attribute(element, kAXRoleAttribute)
            if role == "AXWebArea" { continue } // skip the page content
            if role == kAXTextFieldRole as String || role == kAXComboBoxRole as String {
                let id = attribute(element, "AXIdentifier").lowercased()
                let desc = (attribute(element, kAXDescriptionAttribute) + " " + attribute(element, kAXTitleAttribute)
                            + " " + attribute(element, "AXPlaceholderValue")).lowercased()
                if id.contains("address") || id.contains("url") || desc.contains("address") || desc.contains("search or enter")
                    || desc.contains("search with") || desc.contains("smart search") || desc.contains("url") {
                    return element
                }
                if fallback == nil { fallback = element }
            }
            guard depth < 14 else { continue }
            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
               let list = children as? [AXUIElement] {
                queue.append(contentsOf: list.map { ($0, depth + 1) })
            }
        }
        return fallback
    }
}

/// Sends key presses exactly like a real keyboard: modifier keys (Command, Shift…) are pressed down
/// AND released, and plain typing never carries a held modifier. (Before, Command stayed "held" after
/// Command-T, so typing "youtube.com" became Command-Y, Command-O, Command-T… — beeps and extra tabs.)
enum KeySender {
    /// Its own private keyboard, so the real keyboard's state can't leak in.
    private static let source = CGEventSource(stateID: .privateState)

    private static let modifierKeys: [(CGEventFlags, CGKeyCode)] = [
        (.maskCommand, 55), (.maskShift, 56), (.maskAlternate, 58), (.maskControl, 59)
    ]

    private static let letterCodes: [Character: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
        "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
        "9": 25, "7": 26, "8": 28, "0": 29, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40,
        "n": 45, "m": 46, ".": 47, "/": 44, "-": 27, " ": 49
    ]

    private static func send(_ key: CGKeyCode, down: Bool, flags: CGEventFlags, unicode: UniChar? = nil) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { return }
        event.flags = flags
        if var u = unicode { event.keyboardSetUnicodeString(stringLength: 1, unicodeString: &u) }
        event.post(tap: .cghidEventTap)
    }

    /// A shortcut such as Command-T: hold the modifiers, tap the key, then let go of the modifiers.
    static func combo(_ key: CGKeyCode, _ flags: CGEventFlags) {
        var held: CGEventFlags = []
        let used = modifierKeys.filter { flags.contains($0.0) }
        for (flag, code) in used {
            held.insert(flag)
            send(code, down: true, flags: held)
            usleep(8_000)
        }
        send(key, down: true, flags: flags)
        usleep(15_000)
        send(key, down: false, flags: flags)
        usleep(8_000)
        for (flag, code) in used.reversed() {
            held.remove(flag)
            send(code, down: false, flags: held)
            usleep(8_000)
        }
    }

    /// Types text with no modifier keys held.
    static func type(_ text: String, delay: useconds_t) {
        for ch in text {
            let code = letterCodes[Character(ch.lowercased())] ?? 0
            for unit in String(ch).utf16 {
                send(code, down: true, flags: [], unicode: unit)
                send(code, down: false, flags: [], unicode: unit)
            }
            usleep(delay)
        }
    }
}
