import AppKit
import ApplicationServices

/// Types into a website's OWN search box (YouTube's search bar, BBC's search field…), not the browser's
/// address bar. Finds the box through Accessibility, clicks into it, types and presses Return.
/// If the page has no reachable search box, it goes to that site's own search results page instead.
enum PageSearch {
    /// Search results pages for well-known sites, used only when the search box can't be reached.
    private static let resultsPages: [(host: String, url: String)] = [
        ("youtube.com", "https://www.youtube.com/results?search_query=%@"),
        ("bbc.co.uk", "https://www.bbc.co.uk/search?q=%@"),
        ("bbc.com", "https://www.bbc.com/search?q=%@"),
        ("wikipedia.org", "https://en.wikipedia.org/w/index.php?search=%@"),
        ("amazon.co.uk", "https://www.amazon.co.uk/s?k=%@"),
        ("amazon.com", "https://www.amazon.com/s?k=%@"),
        ("ebay.co.uk", "https://www.ebay.co.uk/sch/i.html?_nkw=%@"),
        ("ebay.com", "https://www.ebay.com/sch/i.html?_nkw=%@"),
        ("netflix.com", "https://www.netflix.com/search?q=%@"),
        ("reddit.com", "https://www.reddit.com/search/?q=%@"),
        ("twitch.tv", "https://www.twitch.tv/search?term=%@"),
        ("x.com", "https://x.com/search?q=%@"),
        ("imdb.com", "https://www.imdb.com/find/?q=%@"),
        ("spotify.com", "https://open.spotify.com/search/%@"),
        ("google.com", "https://www.google.com/search?q=%@"),
        ("bing.com", "https://www.bing.com/search?q=%@"),
        ("github.com", "https://github.com/search?q=%@"),
        ("tiktok.com", "https://www.tiktok.com/search?q=%@"),
        ("pinterest.com", "https://www.pinterest.com/search/pins/?q=%@"),
        ("argos.co.uk", "https://www.argos.co.uk/search/%@/"),
        ("theguardian.com", "https://www.google.com/search?q=site%3Atheguardian.com+%@"),
        // Video and TV
        ("vimeo.com", "https://vimeo.com/search?q=%@"),
        ("dailymotion.com", "https://www.dailymotion.com/search/%@"),
        ("primevideo.com", "https://www.primevideo.com/search?phrase=%@"),
        ("crunchyroll.com", "https://www.crunchyroll.com/search?q=%@"),
        ("channel4.com", "https://www.channel4.com/search?q=%@"),
        ("kick.com", "https://kick.com/search?query=%@"),
        ("ted.com", "https://www.ted.com/search?q=%@"),
        ("rumble.com", "https://rumble.com/search/all?q=%@"),
        // Music
        ("soundcloud.com", "https://soundcloud.com/search?q=%@"),
        ("deezer.com", "https://www.deezer.com/search/%@"),
        ("music.apple.com", "https://music.apple.com/search?term=%@"),
        // Shopping
        ("etsy.com", "https://www.etsy.com/search?q=%@"),
        ("walmart.com", "https://www.walmart.com/search?q=%@"),
        ("aliexpress.com", "https://www.aliexpress.com/wholesale?SearchText=%@"),
        ("temu.com", "https://www.temu.com/search_result.html?search_key=%@"),
        ("tesco.com", "https://www.tesco.com/groceries/en-GB/search?query=%@"),
        ("johnlewis.com", "https://www.johnlewis.com/search?search-term=%@"),
        ("currys.co.uk", "https://www.currys.co.uk/search?q=%@"),
        ("apple.com", "https://www.apple.com/search/%@"),
        // Social
        ("facebook.com", "https://www.facebook.com/search/top/?q=%@"),
        ("linkedin.com", "https://www.linkedin.com/search/results/all/?keywords=%@"),
        ("quora.com", "https://www.quora.com/search?q=%@"),
        ("medium.com", "https://medium.com/search?q=%@"),
        ("stackoverflow.com", "https://stackoverflow.com/search?q=%@"),
        // Travel
        ("booking.com", "https://www.booking.com/searchresults.html?ss=%@"),
        ("tripadvisor.co.uk", "https://www.tripadvisor.co.uk/Search?q=%@"),
        ("tripadvisor.com", "https://www.tripadvisor.com/Search?q=%@"),
        // Games
        ("steampowered.com", "https://store.steampowered.com/search/?term=%@"),
        // News, learning and services
        ("cnn.com", "https://edition.cnn.com/search?q=%@"),
        ("nhs.uk", "https://www.nhs.uk/search/results?q=%@"),
        ("gov.uk", "https://www.gov.uk/search/all?keywords=%@"),
        ("khanacademy.org", "https://www.khanacademy.org/search?page_search_query=%@"),
        // Other search engines
        ("yahoo.com", "https://search.yahoo.com/search?p=%@"),
        ("duckduckgo.com", "https://duckduckgo.com/?q=%@")
    ]

    /// Site names you can say ("search YouTube for…", "…on Netflix") and their addresses.
    static let siteNames: [String: String] = [
        "youtube": "youtube.com", "bbc": "bbc.co.uk", "bbc news": "bbc.co.uk", "bbc sport": "bbc.co.uk",
        "iplayer": "bbc.co.uk", "bbc iplayer": "bbc.co.uk", "wikipedia": "wikipedia.org", "amazon": "amazon.co.uk",
        "ebay": "ebay.co.uk", "netflix": "netflix.com", "reddit": "reddit.com", "twitch": "twitch.tv",
        "twitter": "x.com", "x": "x.com", "imdb": "imdb.com", "spotify": "open.spotify.com", "github": "github.com",
        "tiktok": "tiktok.com", "pinterest": "pinterest.com", "argos": "argos.co.uk", "vimeo": "vimeo.com",
        "dailymotion": "dailymotion.com", "prime video": "primevideo.com", "crunchyroll": "crunchyroll.com",
        "channel 4": "channel4.com", "kick": "kick.com", "ted": "ted.com", "rumble": "rumble.com",
        "soundcloud": "soundcloud.com", "deezer": "deezer.com", "apple music": "music.apple.com", "etsy": "etsy.com",
        "walmart": "walmart.com", "aliexpress": "aliexpress.com", "temu": "temu.com", "tesco": "tesco.com",
        "john lewis": "johnlewis.com", "currys": "currys.co.uk", "apple": "apple.com", "facebook": "facebook.com",
        "linkedin": "linkedin.com", "quora": "quora.com", "medium": "medium.com", "stack overflow": "stackoverflow.com",
        "booking": "booking.com", "booking.com": "booking.com", "tripadvisor": "tripadvisor.co.uk", "steam": "store.steampowered.com",
        "cnn": "cnn.com", "nhs": "nhs.uk", "gov uk": "gov.uk", "khan academy": "khanacademy.org", "yahoo": "yahoo.com",
        "duckduckgo": "duckduckgo.com", "bing": "bing.com", "the guardian": "theguardian.com", "guardian": "theguardian.com",
        "disney plus": "disneyplus.com", "sky news": "news.sky.com", "instagram": "instagram.com"
    ]

    /// "youtube", "bbc news", "amazon.co.uk" → the site's address, if it's a website.
    static func siteAddress(for spoken: String) -> String? {
        let s = spoken.lowercased().trimmingCharacters(in: .whitespaces)
        let plain = s.hasPrefix("the ") && siteNames[s] == nil ? String(s.dropFirst(4)) : s
        if let known = siteNames[plain] { return known }
        if plain.range(of: #"^[a-z0-9-]+(\.[a-z0-9-]+)+$"#, options: .regularExpression) != nil { return plain }
        return nil
    }

    /// The address of the page open in the browser right now, if any.
    static func currentPageHost(in browser: Browser) -> String? { currentHost(in: browser) }

    /// The browser you're using right now (front, or the one you used last).
    static func activeBrowser(lastApp: NSRunningApplication?) -> Browser? {
        for app in [NSWorkspace.shared.frontmostApplication, lastApp].compactMap({ $0 }) {
            if app.bundleIdentifier == Browser.safari.bundleID { return .safari }
            if app.bundleIdentifier == Browser.firefox.bundleID { return .firefox }
        }
        return nil
    }

    /// Searches inside the page open in `browser`. Waits up to `wait` seconds for the page (and its
    /// search box) to load — used straight after opening a website.
    static func run(_ query: String, in browser: Browser, wait: TimeInterval = 2) {
        let deadline = Date().addingTimeInterval(wait)
        func attempt() {
            if let field = findSearchField(in: browser) {
                typeInto(field, query: query, browser: browser)
                return
            }
            if Date() < deadline {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { attempt() }
            } else {
                goToResultsPage(for: query, in: browser)
            }
        }
        bringForward(browser) { attempt() }
    }

    // MARK: Finding the search box

    private static func webArea(of browser: Browser) -> AXUIElement? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: browser.bundleID)
            .first(where: { !$0.isTerminated }) else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        // Firefox only builds its page Accessibility tree once asked to.
        AXUIElementSetAttributeValue(axApp, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              let windowRef, CFGetTypeID(windowRef) == AXUIElementGetTypeID() else { return nil }
        // Find the page itself (the "web area") inside the window.
        var queue: [(AXUIElement, Int)] = [(windowRef as! AXUIElement, 0)]
        var seen = 0
        while !queue.isEmpty, seen < 800 {
            let (el, depth) = queue.removeFirst()
            seen += 1
            if string(el, kAXRoleAttribute) == "AXWebArea" { return el }
            guard depth < 16 else { continue }
            queue.append(contentsOf: children(of: el).map { ($0, depth + 1) })
        }
        return nil
    }

    private static func string(_ el: AXUIElement, _ attr: String) -> String {
        var ref: CFTypeRef?
        AXUIElementCopyAttributeValue(el, attr as CFString, &ref)
        return (ref as? String) ?? ""
    }

    private static func children(of el: AXUIElement) -> [AXUIElement] {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &ref) == .success else { return [] }
        return (ref as? [AXUIElement]) ?? []
    }

    /// The page's own search box: a search field, or a text box labelled "search".
    static func findSearchField(in browser: Browser) -> AXUIElement? {
        guard AXIsProcessTrusted(), let page = webArea(of: browser) else { return nil }
        var queue: [(AXUIElement, Int)] = [(page, 0)]
        var labelled: AXUIElement?
        var firstBox: AXUIElement?
        var seen = 0
        while !queue.isEmpty, seen < 4000 {
            let (el, depth) = queue.removeFirst()
            seen += 1
            let role = string(el, kAXRoleAttribute)
            if role == kAXTextFieldRole as String || role == kAXComboBoxRole as String || role == "AXSearchField" {
                if string(el, kAXSubroleAttribute) == "AXSearchField" || role == "AXSearchField" { return el }
                let label = [kAXDescriptionAttribute, kAXTitleAttribute, "AXPlaceholderValue", "AXIdentifier",
                             "AXDOMIdentifier", kAXHelpAttribute, kAXRoleDescriptionAttribute]
                    .map { string(el, $0) }.joined(separator: " ").lowercased()
                if label.contains("search") || label.contains("find") { if labelled == nil { labelled = el } }
                if firstBox == nil { firstBox = el }
            }
            guard depth < 40 else { continue }
            queue.append(contentsOf: children(of: el).map { ($0, depth + 1) })
        }
        return labelled ?? firstBox
    }

    // MARK: Typing into it

    private static func typeInto(_ field: AXUIElement, query: String, browser: Browser) {
        // Put the cursor in the box: ask nicely first, and if that doesn't take, click on it like you would.
        AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            var focused: CFTypeRef?
            AXUIElementCopyAttributeValue(field, kAXFocusedAttribute as CFString, &focused)
            if (focused as? Bool) != true { click(field) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                // Empty the box first so the new search replaces any old one.
                if AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, "" as CFString) != .success {
                    var value: CFTypeRef?
                    AXUIElementCopyAttributeValue(field, kAXValueAttribute as CFString, &value)
                    var range = CFRange(location: 0, length: (value as? String)?.utf16.count ?? 0)
                    if let r = AXValueCreate(.cfRange, &range) {
                        AXUIElementSetAttributeValue(field, kAXSelectedTextRangeAttribute as CFString, r)
                    }
                }
                DispatchQueue.global(qos: .userInitiated).async {
                    KeySender.type(query, delay: 30_000)
                    usleep(250_000)
                    KeySender.combo(36, []) // Return
                }
            }
        }
    }

    private static func click(_ el: AXUIElement) {
        var posRef: CFTypeRef?, sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef, let sizeRef else { return }
        var pos = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &pos)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        let point = CGPoint(x: pos.x + size.width / 2, y: pos.y + size.height / 2)
        let src = CGEventSource(stateID: .privateState)
        CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    // MARK: Fallback: the site's own results page

    private static func currentHost(in browser: Browser) -> String? {
        guard let page = webArea(of: browser) else { return nil }
        var ref: CFTypeRef?
        AXUIElementCopyAttributeValue(page, "AXURL" as CFString, &ref)
        if let url = ref as? URL { return url.host }
        if let s = ref as? String { return URL(string: s)?.host }
        return nil
    }

    private static func goToResultsPage(for query: String, in browser: Browser) {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let host = (currentHost(in: browser) ?? "").lowercased()
        var target: URL?
        if let match = resultsPages.first(where: { host.hasSuffix($0.host) }) {
            target = URL(string: String(format: match.url, encoded))
        } else if !host.isEmpty {
            target = URL(string: "https://www.google.com/search?q=site%3A\(host)+\(encoded)")
        } else {
            target = URL(string: "https://www.google.com/search?q=\(encoded)")
        }
        guard let target else { return }
        // Go there in the same tab: type it into the address bar (no shortcuts).
        if AddressBar.focus(in: browser) {
            var address = target.absoluteString
            if address.hasPrefix("https://") { address.removeFirst(8) }
            DispatchQueue.global(qos: .userInitiated).async {
                KeySender.type(address, delay: 20_000)
                usleep(200_000)
                KeySender.combo(36, [])
            }
        } else {
            _ = browser.open(target)
        }
    }

    private static func bringForward(_ browser: Browser, then: @escaping () -> Void) {
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == browser.bundleID { then(); return }
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: browser.bundleID).first {
            if #available(macOS 14.0, *) {
                NSApp.yieldActivation(to: app)
                app.activate()
            } else {
                app.activate(options: [.activateIgnoringOtherApps])
            }
        }
        var error: NSDictionary?
        NSAppleScript(source: "tell application id \"\(browser.bundleID)\" to activate")?.executeAndReturnError(&error)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: then)
    }
}
