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
    private var pendingWeatherTomorrow: Bool?
    private var pendingPower: PowerAction?

    /// Carries out a power action once OLED has finished saying goodbye.
    private func schedule(_ action: PowerAction) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { action.perform() }
    }

    private static let jokes = [
        "Why don't skeletons fight each other? They don't have the guts.",
        "I told my computer I needed a break. It said, no problem, I'll go to sleep.",
        "Why did the scarecrow win an award? Because he was outstanding in his field.",
        "What do you call a fake noodle? An impasta.",
        "Why do programmers prefer dark mode? Because light attracts bugs.",
        "I'm reading a book about anti-gravity. It's impossible to put down.",
        "Why did the bicycle fall over? It was two tired.",
        "What's orange and sounds like a parrot? A carrot."
    ]

    /// Greetings, goodbyes, time, date, weather and (offline) jokes. Returns true when it answered.
    private func everyday(_ text: String, raw: String, reply: @escaping (Reply) -> Void) -> Bool {
        let words = text.replacingOccurrences(of: "oled", with: "").trimmingCharacters(in: .whitespaces)

        let byes = ["bye", "goodbye", "good bye", "bye bye", "see you", "see ya", "see you later", "good night",
                    "night night", "that's all", "that is all", "thanks bye", "ok bye", "okay bye"]
        if byes.contains(words) || words.hasPrefix("bye ") || words.hasPrefix("goodbye ") {
            chat.reset()
            let night = Calendar.current.component(.hour, from: Date()) >= 20
            reply(Reply(text: night ? "Good night. Just say my name if you need me." : "Goodbye. Just say my name if you need me.", expectsAnswer: false))
            return true
        }

        let hellos = ["hi", "hello", "hey", "hiya", "hey there", "hi there", "hello there", "alright", "yo",
                      "good morning", "good afternoon", "good evening", "morning", "afternoon", "evening"]
        if hellos.contains(words) {
            let hour = Calendar.current.component(.hour, from: Date())
            let greeting = hour < 12 ? "Good morning" : (hour < 18 ? "Good afternoon" : "Good evening")
            reply(Reply(text: "\(greeting). How can I help?", expectsAnswer: true))
            return true
        }

        if ["thanks", "thank you", "cheers", "thank you very much", "thanks a lot", "nice one"].contains(words) {
            reply(Reply(text: "You're very welcome.", expectsAnswer: false))
            return true
        }

        if words.contains("what time") || words.contains("the time") || words == "time" {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_GB")
            f.dateFormat = "h:mm a"
            reply(Reply(text: "It's \(f.string(from: Date())).", expectsAnswer: false))
            return true
        }

        if words.contains("the date") || words.contains("what day is it") || words.contains("what day is today")
            || words.contains("today's date") {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_GB")
            f.dateFormat = "EEEE d MMMM yyyy"
            reply(Reply(text: "Today is \(f.string(from: Date())).", expectsAnswer: false))
            return true
        }

        let weatherWords = ["weather", "forecast", "temperature", "going to rain", "gonna rain", "will it rain",
                            "is it raining", "is it cold", "is it hot", "is it warm", "need an umbrella", "need a coat"]
        if weatherWords.contains(where: { words.contains($0) }) {
            let tomorrow = words.contains("tomorrow")
            if let place = Self.placeIn(words) ?? Weather.homeTown {
                Weather.report(for: place, tomorrow: tomorrow) { reply(Reply(text: $0, expectsAnswer: false)) }
            } else {
                pendingWeatherTomorrow = tomorrow
                reply(Reply(text: "Which town or city should I check?", expectsAnswer: true))
            }
            return true
        }

        if words.contains("joke"), KeyStore.apiKey == nil {
            reply(Reply(text: Self.jokes.randomElement()!, expectsAnswer: true))
            return true
        }
        return false
    }

    /// "what's the weather in leeds tomorrow" → "leeds"
    private static func placeIn(_ text: String) -> String? {
        var t = " " + text + " "
        for filler in [" tomorrow", " today", " right now", " now", " like", " this morning", " this afternoon",
                       " this evening", " tonight", " please", " outside"] {
            t = t.replacingOccurrences(of: filler + " ", with: " ")
        }
        t = t.trimmingCharacters(in: .whitespaces)
        for marker in [" in ", " for ", " at "] {
            if let r = t.range(of: marker, options: .backwards) {
                let place = cleanPlace(String(t[r.upperBound...]))
                if !place.isEmpty, !["the", "my area", "here", "my town"].contains(place.lowercased()) { return place }
            }
        }
        return nil
    }

    private static func cleanPlace(_ s: String) -> String {
        var p = s.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        for lead in ["in ", "for ", "it's ", "it is ", "i'm in ", "i live in "] where p.lowercased().hasPrefix(lead) {
            p = String(p.dropFirst(lead.count))
        }
        return p.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

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

        // 1a. Answering "Are you sure you want me to shut down / restart?"
        if let action = pendingPower {
            pendingPower = nil
            let yes = ["yes", "yeah", "yep", "yup", "sure", "do it", "go ahead", "confirm", "ok", "okay", "please", "affirmative", "of course"]
            if yes.contains(where: { text == $0 || text.hasPrefix($0 + " ") || text.hasSuffix(" " + $0) }) {
                schedule(action)
                reply(Reply(text: action.goodbye, expectsAnswer: false)); return
            }
            reply(Reply(text: "Okay, I won't.", expectsAnswer: false)); return
        }

        // 1b. Answering "Which town should I check?"
        if let tomorrow = pendingWeatherTomorrow {
            pendingWeatherTomorrow = nil
            if Self.cancelWords.contains(where: { text.contains($0) }) {
                reply(Reply(text: "Okay.", expectsAnswer: false)); return
            }
            let town = Self.cleanPlace(raw)
            Weather.homeTown = town
            Weather.report(for: town, tomorrow: tomorrow) { reply(Reply(text: $0, expectsAnswer: false)) }
            return
        }

        // 2. Cancel
        if Self.cancelWords.contains(politeStripped) {
            reply(Reply(text: "Okay.", expectsAnswer: false)); return
        }

        // 2a. Shut down, restart, sleep, lock
        if let action = PowerAction.from(politeStripped) {
            if let question = action.confirmQuestion {
                pendingPower = action
                reply(Reply(text: question, expectsAnswer: true)); return
            }
            if action == .lock, !AccessibilityPermission.isGranted { reply(needAccessibility()); return }
            schedule(action)
            reply(Reply(text: action.goodbye, expectsAnswer: false)); return
        }

        // 2b. Everyday questions answered right here on the Mac (like Siri)
        if everyday(politeStripped, raw: raw, reply: reply) { return }

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
        var forceWeb = false
        for filler in ["this website ", "the website ", "website ", "this site ", "the site ", "this link ", "this page "]
        where target.hasPrefix(filler) {
            target.removeFirst(filler.count)
            forceWeb = true
        }
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

        if chosen != nil { forceWeb = true }
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
        guard browser.appURL != nil else {
            return Reply(text: "\(browser.rawValue) doesn't seem to be installed on this Mac.", expectsAnswer: false)
        }
        if AccessibilityPermission.isGranted {
            // Type the address into the browser for you.
            var address = url.absoluteString
            for scheme in ["https://", "http://"] where address.hasPrefix(scheme) { address.removeFirst(scheme.count) }
            keyboard.typeAddress(address, in: browser)
        } else {
            _ = browser.open(url)
        }
        return Reply(text: "Opening \(name) in \(browser.rawValue).", expectsAnswer: false)
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
