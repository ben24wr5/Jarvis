import AppKit
import ApplicationServices

/// The visible mouse pointer: glides smoothly to a spot and clicks there, so you can see what OLED clicks.
enum Pointer {
    private static let source = CGEventSource(stateID: .hidSystemState)

    static var current: CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    /// Moves the pointer to `target` over about half a second.
    static func glide(to target: CGPoint) {
        let start = current
        let steps = 30
        for i in 1...steps {
            let t = Double(i) / Double(steps)
            let ease = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2 // smooth start and stop
            let p = CGPoint(x: start.x + (target.x - start.x) * ease, y: start.y + (target.y - start.y) * ease)
            CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?
                .post(tap: .cghidEventTap)
            usleep(16_000)
        }
    }

    static func click(at point: CGPoint) {
        usleep(120_000)
        CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        usleep(60_000)
        CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }
}

/// Clicks videos on YouTube and other video websites, and presses Play/Pause — by moving the mouse
/// pointer to them and clicking, like a person would.
enum VideoPicker {
    struct Candidate {
        let element: AXUIElement
        let label: String
        let url: String
    }

    private static let videoPathHints = ["/watch", "/video", "/videos/", "/episode", "/programmes/", "/iplayer/episode",
                                         "/title/", "/play/", "/shorts/", "/clip", "/v/", "/movie", "/series/"]

    private static func label(of el: AXUIElement) -> String {
        var parts = [PageSearch.text(el, kAXTitleAttribute), PageSearch.text(el, kAXDescriptionAttribute)]
        if parts.allSatisfy({ $0.isEmpty }) {
            // Use the text inside the link.
            for child in PageSearch.kids(el).prefix(6) {
                parts.append(PageSearch.text(child, kAXValueAttribute))
                parts.append(PageSearch.text(child, kAXTitleAttribute))
            }
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func urlString(of el: AXUIElement) -> String {
        var ref: CFTypeRef?
        AXUIElementCopyAttributeValue(el, "AXURL" as CFString, &ref)
        if let u = ref as? URL { return u.absoluteString }
        return (ref as? String) ?? ""
    }

    /// Video links on the page, top to bottom.
    static func videoLinks(in browser: Browser) -> [Candidate] {
        guard let page = PageSearch.pageArea(of: browser) else { return [] }
        var found: [Candidate] = []
        var seenURLs = Set<String>()
        var queue: [(AXUIElement, Int)] = [(page, 0)]
        var visited = 0
        while !queue.isEmpty, visited < 6000 {
            let (el, depth) = queue.removeFirst()
            visited += 1
            if PageSearch.text(el, kAXRoleAttribute) == "AXLink" {
                let url = urlString(of: el)
                let text = label(of: el)
                let looksLikeVideo = videoPathHints.contains { url.lowercased().contains($0) }
                if looksLikeVideo, text.count >= 4, !seenURLs.contains(url) {
                    seenURLs.insert(url)
                    found.append(Candidate(element: el, label: text, url: url))
                }
            }
            guard depth < 45 else { continue }
            queue.append(contentsOf: PageSearch.kids(el).map { ($0, depth + 1) })
        }
        return found
    }

    private static func words(_ s: String) -> Set<String> {
        Set(s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count >= 2 })
    }

    /// The video whose title best matches what you said (first one on the page if nothing matches better).
    static func best(matching request: String, in links: [Candidate]) -> Candidate? {
        let wanted = words(request)
        guard !wanted.isEmpty else { return links.first }
        var bestScore = -1.0
        var best: Candidate?
        for (i, link) in links.enumerated() {
            let have = words(link.label)
            let overlap = Double(wanted.intersection(have).count) / Double(wanted.count)
            let score = overlap - Double(i) * 0.002 // prefer higher up the page when equal
            if score > bestScore { bestScore = score; best = link }
        }
        return best
    }

    /// Clicks like a person: scrolls the video into view, glides the mouse pointer onto it, then clicks.
    static func click(_ el: AXUIElement) {
        AXUIElementPerformAction(el, "AXScrollToVisible" as CFString)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            guard let target = centre(of: el) else {
                AXUIElementPerformAction(el, kAXPressAction as CFString)
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                Pointer.glide(to: target)
                Pointer.click(at: target)
            }
        }
    }

    private static func centre(of el: AXUIElement) -> CGPoint? {
        var posRef: CFTypeRef?, sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef, let sizeRef else { return nil }
        var pos = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &pos)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        guard size.width > 2, size.height > 2 else { return nil }
        return CGPoint(x: pos.x + size.width / 2, y: pos.y + size.height / 2)
    }

    /// After a search: wait for results, click the best-matching video, then make sure it plays.
    static func pickAfterResults(matching query: String, in browser: Browser) {
        let started = Date()
        let deadline = started.addingTimeInterval(14)
        let startURL = currentURL(in: browser)
        func attempt() {
            // Wait until the results page has loaded (the address changed, or a few seconds passed) and has videos.
            let loaded = currentURL(in: browser) != startURL || Date().timeIntervalSince(started) > 3
            let links = loaded ? videoLinks(in: browser) : []
            if loaded, !links.isEmpty, let pick = best(matching: query, in: links) {
                click(pick.element)
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { ensurePlaying(in: browser) }
                return
            }
            if Date() < deadline {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { attempt() }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { attempt() }
    }

    private static func currentURL(in browser: Browser) -> String {
        guard let page = PageSearch.pageArea(of: browser) else { return "" }
        return urlString(of: page)
    }

    /// Clicks a video on the page now: by name ("the minecraft one") or by position (1 = first).
    @discardableResult
    static func clickVideo(named request: String?, number: Int?, in browser: Browser) -> Bool {
        let links = videoLinks(in: browser)
        guard !links.isEmpty else { return false }
        let pick: Candidate?
        if let number { pick = number >= 1 && number <= links.count ? links[number - 1] : nil }
        else { pick = best(matching: request ?? "", in: links) }
        guard let pick else { return false }
        click(pick.element)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { ensurePlaying(in: browser) }
        return true
    }

    // MARK: Play / pause

    private static func playerButtons(in browser: Browser) -> [(AXUIElement, String)] {
        guard let page = PageSearch.pageArea(of: browser) else { return [] }
        var result: [(AXUIElement, String)] = []
        var queue: [(AXUIElement, Int)] = [(page, 0)]
        var visited = 0
        while !queue.isEmpty, visited < 5000 {
            let (el, depth) = queue.removeFirst()
            visited += 1
            if PageSearch.text(el, kAXRoleAttribute) == kAXButtonRole as String {
                let l = (PageSearch.text(el, kAXDescriptionAttribute) + " " + PageSearch.text(el, kAXTitleAttribute)
                         + " " + PageSearch.text(el, kAXHelpAttribute)).lowercased()
                if (l.contains("play") || l.contains("pause")) && !l.contains("playlist") && !l.contains("autoplay")
                    && !l.contains("playback") && !l.contains("player settings") && !l.contains("play all") {
                    result.append((el, l))
                }
            }
            guard depth < 45 else { continue }
            queue.append(contentsOf: PageSearch.kids(el).map { ($0, depth + 1) })
        }
        return result
    }

    /// Video websites: if the video isn't playing yet, press its Play button.
    static func ensurePlaying(in browser: Browser) {
        let buttons = playerButtons(in: browser)
        if buttons.contains(where: { $0.1.hasPrefix("pause") || $0.1.contains(" pause") }) { return } // already playing
        if let play = buttons.first(where: { $0.1.contains("play") }) { click(play.0) }
    }

    /// "play" / "pause" said on a video page. Returns false if there's no video player.
    @discardableResult
    static func setPlaying(_ playing: Bool, in browser: Browser) -> Bool {
        let buttons = playerButtons(in: browser)
        let wanted = playing ? "play" : "pause"
        if let button = buttons.first(where: { $0.1.hasPrefix(wanted) || $0.1.contains(" " + wanted) || $0.1.contains(wanted) }) {
            click(button.0)
            return true
        }
        return false
    }
}
