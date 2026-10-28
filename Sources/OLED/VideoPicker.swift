import AppKit
import ApplicationServices

/// Clicks videos on YouTube and other video websites, and presses Play/Pause — through Accessibility,
/// like clicking with the mouse.
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

    static func click(_ el: AXUIElement) {
        if AXUIElementPerformAction(el, kAXPressAction as CFString) != .success {
            PageSearch.click(el)
        }
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
