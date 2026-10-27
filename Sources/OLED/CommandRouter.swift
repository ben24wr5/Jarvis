import Foundation
import AppKit

/// Works out what a spoken command means and carries it out.
/// The reply is what OLED says back; `expectsAnswer` keeps the mic open for a reply without the wake word.
final class CommandRouter {
    struct Reply {
        var text: String
        var expectsAnswer: Bool
    }

    private let keyboard = KeyboardController()
    private let chat = ChatClient()

    private var pendingURL: URL?
    private var pendingName = ""
    private var browserAsks = 0

    private static let cancelWords = ["cancel", "stop", "never mind", "nevermind", "forget it", "nothing", "no thanks"]
    private static let openVerbs = ["open up ", "open ", "launch ", "start ", "run ", "go to ", "visit ", "show me ", "load ", "bring up "]

    func handle(_ raw: String, reply: @escaping (Reply) -> Void) {
        let text = raw.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".,!?")))
        let politeStripped = Self.stripPoliteness(text)

        // 1. Answering "Firefox or Safari?"
        if let url = pendingURL {
            if text.contains("firefox") || text.contains("fire fox") {
                reply(openSite(url, name: pendingName, in: .firefox)); return
            }
            if text.contains("safari") {
                reply(openSite(url, name: pendingName, in: .safari)); return
            }
            if Self.cancelWords.contains(where: { text.contains($0) }) {
                clearPending()
                reply(Reply(text: "Okay, I won't open it.", expectsAnswer: false)); return
            }
            browserAsks += 1
            if browserAsks < 3 {
                reply(Reply(text: "Sorry, Firefox or Safari?", expectsAnswer: true)); return
            }
            clearPending()
            reply(Reply(text: "Never mind, I'll leave it for now.", expectsAnswer: false)); return
        }

        // 2. Cancel
        if Self.cancelWords.contains(politeStripped) {
            reply(Reply(text: "Okay.", expectsAnswer: false)); return
        }

        // 3. Typing
        for prefix in ["type out ", "type ", "write "] where politeStripped.hasPrefix(prefix) {
            let original = Self.originalTail(of: raw, after: prefix)
            guard AccessibilityPermission.isGranted else { reply(needAccessibility()); return }
            keyboard.type(original)
            reply(Reply(text: "Done.", expectsAnswer: false)); return
        }

        // 4. Key presses
        for prefix in ["press ", "hit ", "push "] where politeStripped.hasPrefix(prefix) {
            let spoken = String(politeStripped.dropFirst(prefix.count))
            guard let combo = KeyboardController.parseCombo(spoken) else {
                reply(Reply(text: "I didn't catch which keys to press.", expectsAnswer: false)); return
            }
            guard AccessibilityPermission.isGranted else { reply(needAccessibility()); return }
            keyboard.press(key: combo.0, flags: combo.1)
            reply(Reply(text: "Done.", expectsAnswer: false)); return
        }

        // 5. Opening apps and websites
        for verb in Self.openVerbs where politeStripped.hasPrefix(verb) {
            var target = String(politeStripped.dropFirst(verb.count))
            reply(open(&target)); return
        }

        // 6. Anything else: have a conversation
        chat.reply(to: raw) { answer in
            reply(Reply(text: answer, expectsAnswer: true))
        }
    }

    // MARK: Opening

    private func open(_ target: inout String) -> Reply {
        for filler in ["the ", "my ", "up "] where target.hasPrefix(filler) { target.removeFirst(filler.count) }
        for filler in [" please", " for me", " app", " application"] where target.hasSuffix(filler) {
            target.removeLast(filler.count)
        }

        // Browser said up front: "open YouTube in Firefox"
        var chosen: Browser?
        let browserPhrases: [(String, Browser)] = [
            (" in firefox", .firefox), (" on firefox", .firefox), (" with firefox", .firefox),
            (" in safari", .safari), (" on safari", .safari), (" with safari", .safari)
        ]
        for (phrase, browser) in browserPhrases where target.hasSuffix(phrase) {
            target.removeLast(phrase.count)
            chosen = browser
        }

        var forceWeb = chosen != nil
        for word in [" website", " web site", " site", " web page", " page", " link"] where target.hasSuffix(word) {
            target.removeLast(word.count)
            forceWeb = true
        }
        target = target.trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return Reply(text: "What would you like me to open?", expectsAnswer: false) }

        let looksLikeAddress = target.contains(".") || target.contains(" dot ")
        if !forceWeb, !looksLikeAddress, let app = AppFinder.find(target) {
            AppFinder.open(app.url)
            return Reply(text: "Opening \(app.name).", expectsAnswer: false)
        }

        // Not an installed app, so treat it as a website — any website.
        guard let url = Website.url(from: target, force: true) else {
            return Reply(text: "What would you like me to open?", expectsAnswer: false)
        }
        let name = Website.displayName(for: target)
        if let chosen { return openSite(url, name: name, in: chosen) }

        pendingURL = url
        pendingName = name
        browserAsks = 0
        return Reply(text: "Do you want me to open it in Firefox or Safari?", expectsAnswer: true)
    }

    private func openSite(_ url: URL, name: String, in browser: Browser) -> Reply {
        clearPending()
        if browser.open(url) {
            return Reply(text: "Opening \(name) in \(browser.rawValue).", expectsAnswer: false)
        }
        return Reply(text: "\(browser.rawValue) doesn't seem to be installed on this Mac.", expectsAnswer: false)
    }

    private func clearPending() {
        pendingURL = nil
        pendingName = ""
        browserAsks = 0
    }

    private func needAccessibility() -> Reply {
        AccessibilityPermission.request()
        return Reply(text: "I need Accessibility access to use the keyboard. I've opened the settings for you. Switch me on, then ask again.", expectsAnswer: false)
    }

    // MARK: Helpers

    private static func stripPoliteness(_ text: String) -> String {
        var t = text
        for lead in ["can you ", "could you ", "would you ", "will you ", "please ", "just ", "now "] {
            while t.hasPrefix(lead) { t.removeFirst(lead.count) }
        }
        if t.hasSuffix(" please") { t.removeLast(" please".count) }
        return t.trimmingCharacters(in: .whitespaces)
    }

    /// The words after a prefix, keeping the user's original capitalisation (for typing).
    private static func originalTail(of raw: String, after prefix: String) -> String {
        let lower = raw.lowercased()
        guard let range = lower.range(of: prefix) else { return raw }
        let offset = lower.distance(from: lower.startIndex, to: range.upperBound)
        let start = raw.index(raw.startIndex, offsetBy: min(offset, raw.count))
        return String(raw[start...]).trimmingCharacters(in: .whitespaces)
    }
}
