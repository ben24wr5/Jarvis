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
    private var pendingTyped: String?
    private var pendingPlace: KeyboardController.Place?
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

        // Only real "what's the time?" questions — not "what time does the match start".
        let timeQuestions = ["what time is it", "what's the time", "whats the time", "what is the time", "time",
                             "the time", "tell me the time", "what time is it now", "what's the time now",
                             "current time", "time now", "what time it is", "do you know the time", "got the time"]
        if timeQuestions.contains(words) {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_GB")
            f.dateFormat = "h:mm a"
            reply(Reply(text: "It's \(f.string(from: Date())).", expectsAnswer: false))
            return true
        }

        let dateQuestions = ["what's the date", "whats the date", "what is the date", "what's today's date",
                             "what is today's date", "today's date", "the date", "date", "what day is it", "what day is today",
                             "what's the date today", "what is the date today", "what day is it today", "what's today"]
        if dateQuestions.contains(words) {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_GB")
            f.dateFormat = "EEEE d MMMM yyyy"
            reply(Reply(text: "Today is \(f.string(from: Date())).", expectsAnswer: false))
            return true
        }

        // Weather — but not "what's the boiling temperature of water" or "how does a weather balloon work".
        let weatherWords = ["weather", "forecast", "going to rain", "gonna rain", "will it rain", "is it raining",
                            "is it cold", "is it hot", "is it warm", "need an umbrella", "need a coat", "temperature outside",
                            "temperature today", "temperature tomorrow", "temperature in ", "how hot is it", "how cold is it",
                            "is it sunny", "is it snowing", "will it snow"]
        let notWeather = ["how does", "how do", "what is a", "what's a", "weather balloon", "weather vane", "boiling", "melting",
                          "body temperature", "of water", "of the sun", "explain", "history of", "why does", "why do"]
        if weatherWords.contains(where: { words.contains($0) }), !notWeather.contains(where: { words.contains($0) }) {
            let tomorrow = words.contains("tomorrow")
            if let place = Self.placeIn(words) ?? Weather.homeTown {
                Weather.report(for: place, tomorrow: tomorrow) { reply(Reply(text: $0, expectsAnswer: false)) }
            } else {
                pendingWeatherTomorrow = tomorrow
                reply(Reply(text: "Which town or city should I check?", expectsAnswer: true))
            }
            return true
        }

        let jokeRequests = ["tell me a joke", "joke", "a joke", "another joke", "tell me another joke", "say a joke",
                            "make me laugh", "tell a joke", "know any jokes", "do you know any jokes", "got any jokes",
                            "tell me something funny", "say something funny", "give me a joke"]
        if jokeRequests.contains(words) || words.hasPrefix("tell me a joke") || words.hasPrefix("tell me a funny") {
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

    /// Shortcuts OLED only uses when you say them. (phrases, key, modifiers, what OLED says)
    private static let namedShortcuts: [([String], CGKeyCode, CGEventFlags, String)] = [
        (["new tab", "open a new tab", "open new tab", "open up a new tab", "a new tab", "new page", "open a new page"], 17, .maskCommand, "New tab."),
        (["close tab", "close this tab", "close the tab", "close page", "close this page"], 13, .maskCommand, "Closed."),
        (["new window", "open a new window", "open new window"], 45, .maskCommand, "New window."),
        (["copy", "copy that", "copy this", "copy it"], 8, .maskCommand, "Copied."),
        (["paste", "paste that", "paste it", "paste this"], 9, .maskCommand, "Pasted."),
        (["cut", "cut that", "cut this", "cut it"], 7, .maskCommand, "Cut."),
        (["undo", "undo that"], 6, .maskCommand, "Undone."),
        (["redo", "redo that"], 6, [.maskCommand, .maskShift], "Redone."),
        (["select all", "select everything", "highlight everything"], 0, .maskCommand, "Selected."),
        (["save", "save it", "save this", "save that"], 1, .maskCommand, "Saved."),
        (["refresh", "reload", "refresh the page", "reload the page", "refresh page", "reload page"], 15, .maskCommand, "Refreshing."),
        (["go back", "back", "previous page"], 33, .maskCommand, "Going back."),
        (["go forward", "forward", "next page"], 30, .maskCommand, "Going forward."),
        (["find on page", "find on this page", "search this page"], 3, .maskCommand, "Find."),
        (["print", "print this", "print it"], 35, .maskCommand, "Print."),
        (["minimise", "minimize", "minimise window", "minimize window", "minimise this", "minimize this"], 46, .maskCommand, "Minimised.")
    ]

    private static let cancelWords = ["cancel", "stop", "never mind", "nevermind", "forget it", "nothing", "no thanks"]
    private static let openVerbs = ["open up ", "open ", "launch ", "start up ", "start ", "run ", "go to ", "go on ", "visit ",
                                    "take me to ", "navigate to ", "show me ", "load ", "bring up "]

    func handle(_ raw: String, reply: @escaping (Reply) -> Void) {
        // "OLED, can you please open Safari" → "open safari"; "I want you to go to YouTube" → "go to youtube"
        let text = Self.normalise(raw)
        let politeStripped = Self.fromCommandVerb(text)

        // 1. Answering "Firefox or Safari?"
        if pendingURL != nil {
            reply(answerWeb(text)); return
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

        // 1b1. Videos on the page: "play the first video", "click on the Minecraft video", "pause"
        if let answer = videoCommand(politeStripped) { reply(answer); return }

        // 1b2. Searching inside a website's own search box (YouTube, BBC, Amazon, Netflix…)
        if let answer = siteSearch(politeStripped) { reply(answer); return }

        // 1c. Website requests that mention a browser or a new tab/window:
        //     "open a new window in Safari and type youtube.com and then enter"
        if Self.isCommand(politeStripped) || politeStripped.hasPrefix("new ") || politeStripped.hasPrefix("a new ")
            || politeStripped.hasPrefix("safari") || politeStripped.hasPrefix("firefox"),
           let plan = Self.parseWeb(politeStripped) {
            reply(runWeb(plan)); return
        }

        // 2. Keyboard shortcuts — only when you ask for them by name.
        //    "new tab", "copy", "paste", "close tab"… and "open a new tab and go to YouTube".
        for (phrases, key, flags, spoken) in Self.namedShortcuts {
            for phrase in phrases {
                if politeStripped == phrase || text == phrase {
                    guard AccessibilityPermission.isGranted else { reply(needAccessibility()); return }
                    keyboard.press(key: key, flags: flags)
                    reply(Reply(text: spoken, expectsAnswer: false)); return
                }
                for joiner in [" and ", " then "] where politeStripped.hasPrefix(phrase + joiner) {
                    guard AccessibilityPermission.isGranted else { reply(needAccessibility()); return }
                    keyboard.press(key: key, flags: flags)
                    let rest = String(politeStripped.dropFirst(phrase.count + joiner.count))
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                        self?.handle(rest, reply: reply)
                    }
                    return
                }
            }
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

        // 2b. Everyday questions answered right here on the Mac (like Siri) — unless it's clearly a command
        if !Self.isCommand(politeStripped), everyday(politeStripped, raw: raw, reply: reply) { return }

        // 2c. Searching: "search for cats", "google the weather in Paris", "search for music on YouTube"
        for prefix in ["search for ", "search ", "google ", "look for ", "find me "] where politeStripped.hasPrefix(prefix) {
            var query = String(politeStripped.dropFirst(prefix.count))
            var browser: Browser?
            for (phrase, b) in Self.browserSuffixes where query.hasSuffix(phrase) {
                query.removeLast(phrase.count); browser = b
            }
            reply(search(query.trimmingCharacters(in: .whitespaces), in: browser)); return
        }

        // 3. Typing
        for prefix in ["type out ", "type in ", "type ", "write "] where politeStripped.hasPrefix(prefix) {
            var spoken = String(politeStripped.dropFirst(prefix.count))
            // "type youtube.com in Safari" → open it in Safari
            for (phrase, browser) in Self.browserSuffixes + [(" into safari", Browser.safari), (" into firefox", Browser.firefox)]
            where spoken.hasSuffix(phrase) {
                spoken.removeLast(phrase.count)
                var target = spoken
                reply(open(&target, browser: browser, forceWeb: true)); return
            }
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

    private static let browserSuffixes: [(String, Browser)] = [
        (" in firefox", .firefox), (" on firefox", .firefox), (" with firefox", .firefox), (" using firefox", .firefox),
        (" in fire fox", .firefox), (" on fire fox", .firefox),
        (" in safari", .safari), (" on safari", .safari), (" with safari", .safari), (" using safari", .safari)
    ]

    /// Opens a browser and searches: types the words into the address bar like you would.
    private func search(_ query: String, in browser: Browser?, place: KeyboardController.Place? = nil) -> Reply {
        guard !query.isEmpty else { return Reply(text: "What should I search for?", expectsAnswer: false) }
        var q = query
        var url: URL?
        var typed = q
        if q.hasSuffix(" on youtube") {
            q.removeLast(" on youtube".count)
            var c = URLComponents(string: "https://www.youtube.com/results")!
            c.queryItems = [URLQueryItem(name: "search_query", value: q)]
            url = c.url
            typed = "youtube.com/results?search_query=" + (q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q)
        } else {
            var c = URLComponents(string: "https://www.google.com/search")!
            c.queryItems = [URLQueryItem(name: "q", value: q)]
            url = c.url
        }
        guard let url else { return Reply(text: "What should I search for?", expectsAnswer: false) }
        return startWeb(url, name: "a search for \(q)", typed: typed, browser: browser, place: place)
    }

    private func open(_ target: inout String, browser preset: Browser? = nil, forceWeb presetWeb: Bool = false) -> Reply {
        var forceWeb = presetWeb

        // Browser first: "Safari and go to YouTube", "Firefox then search for cats", "Safari youtube.com"
        if preset == nil {
            for (name, browser) in [("safari", Browser.safari), ("firefox", .firefox), ("fire fox", .firefox)] {
                for joiner in [" and ", " then ", " to ", " "] where target.hasPrefix(name + joiner) {
                    var rest = String(target.dropFirst(name.count + joiner.count)).trimmingCharacters(in: .whitespaces)
                    guard !rest.isEmpty else { continue }
                    for verb in ["and ", "then ", "go to ", "go on ", "open up ", "open ", "visit ", "load ", "navigate to ",
                                 "take me to ", "type in ", "type ", "put in "] where rest.hasPrefix(verb) {
                        rest.removeFirst(verb.count)
                    }
                    for verb in ["search for ", "search ", "google ", "look for "] where rest.hasPrefix(verb) {
                        return search(String(rest.dropFirst(verb.count)), in: browser)
                    }
                    var site = rest
                    return open(&site, browser: browser, forceWeb: true)
                }
            }
        }

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
        var chosen: Browser? = preset
        for (phrase, browser) in Self.browserSuffixes where target.hasSuffix(phrase) {
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
        // Any app on the Mac opens directly. Only if there's no such app is it treated as a website.
        if !forceWeb, !looksLikeAddress, let app = AppFinder.find(target, allowLoose: !Website.isKnownSite(target)) {
            AppFinder.open(app.url)
            return Reply(text: "Opening \(app.name).", expectsAnswer: false)
        }

        // Not an installed app, so treat it as a website — any website.
        guard let url = Website.url(from: target, force: true) else {
            return Reply(text: "What would you like me to open?", expectsAnswer: false)
        }
        return startWeb(url, name: Website.displayName(for: target), typed: nil, browser: chosen, place: nil)
    }

    /// Opens a website in Safari or Firefox.
    /// `place`: new tab / new window when you asked for one; nil means "you didn't say" — then OLED
    /// uses the current tab only if it's empty, and otherwise asks "new tab or new window?".
    private func openSite(_ url: URL, name: String, in browser: Browser, typed: String? = nil,
                          place: KeyboardController.Place? = nil, thenSearch: String? = nil, thenPlay: Bool = false) -> Reply {
        clearPending()
        // "…and search for X": once the site is open, type X into the site's own search box (and play it if asked).
        let afterOpen: (() -> Void)? = thenSearch.map { query in { PageSearch.run(query, in: browser, wait: 12, play: thenPlay) } }
        guard browser.appURL != nil else {
            return Reply(text: "\(browser.rawValue) doesn't seem to be installed on this Mac.", expectsAnswer: false)
        }
        let finalPlace = place ?? .current
        let keyboard = self.keyboard
        let go: (URL, String) -> Void = { siteURL, address in
            if AccessibilityPermission.isGranted {
                // Type the exact address (or the search words) into the browser for you.
                keyboard.typeAddress(address, url: siteURL, in: browser, place: finalPlace, afterOpen: afterOpen)
            } else {
                _ = browser.open(siteURL)
                if let afterOpen { DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: afterOpen) }
            }
        }
        if let typed {
            go(url, typed)
        } else {
            // Turn a site name into its real address first (e.g. "the guardian" → www.theguardian.com).
            Website.resolve(url, completion: go)
        }
        let placeText = finalPlace == .newTab ? " in a new tab" : (finalPlace == .newWindow ? " in a new window" : "")
        let searchText = thenSearch.map { thenPlay ? ", then playing \($0)" : ", then searching for \($0)" } ?? ""
        return Reply(text: "Opening \(name) in \(browser.rawValue)\(placeText)\(searchText).", expectsAnswer: false)
    }

    private func clearPending() {
        pendingURL = nil
        pendingName = ""
        pendingTyped = nil
        pendingPlace = nil
        pendingBrowser = nil
        pendingFollowUp = nil
        pendingFollowPlay = false
        webStage = .browser
        browserAsks = 0
    }

    // MARK: The website conversation
    //  1. "Safari or Firefox?"  2. "Already a tab open with another website?" yes → new tab
    //  3. (if no) "Open a new window in Safari?" yes → new window, no → nothing is typed.
    //  Anything already said in the command (browser, new tab/window) skips that question.

    private enum WebStage { case browser, existingTab, newWindow }
    private var webStage: WebStage = .browser
    private var pendingBrowser: Browser?

    private var pendingFollowUp: String?

    private var pendingFollowPlay = false

    private func startWeb(_ url: URL, name: String, typed: String?, browser: Browser?, place: KeyboardController.Place?,
                          thenSearch: String? = nil, thenPlay: Bool = false) -> Reply {
        clearPending()
        pendingFollowUp = thenSearch
        pendingFollowPlay = thenPlay
        pendingURL = url
        pendingName = name
        pendingTyped = typed
        pendingPlace = place
        pendingBrowser = browser
        return nextWebStep()
    }

    private func nextWebStep() -> Reply {
        guard let url = pendingURL else { return Reply(text: "Which website would you like?", expectsAnswer: false) }
        guard let browser = pendingBrowser else {
            webStage = .browser
            return Reply(text: "Do you want me to open it in Safari or Firefox?", expectsAnswer: true)
        }
        if let place = pendingPlace {
            return openSite(url, name: pendingName, in: browser, typed: pendingTyped, place: place, thenSearch: pendingFollowUp, thenPlay: pendingFollowPlay)
        }
        webStage = .existingTab
        return Reply(text: "Do you already have a tab open with another website?", expectsAnswer: true)
    }

    private static func isYes(_ t: String) -> Bool {
        let s = " " + t + " "
        return [" yes ", " yeah ", " yep ", " yup ", " sure ", " ok ", " okay ", " please ", " correct ", " i do ",
                " i have ", " do it ", " go ahead ", " affirmative ", " of course ", " yes please "].contains { s.contains($0) }
    }

    private static func isNo(_ t: String) -> Bool {
        let s = " " + t + " "
        return [" no ", " nope ", " nah ", " don't ", " dont ", " do not ", " not ", " i haven't ", " i don't ",
                " no thanks ", " negative "].contains { s.contains($0) }
    }

    /// Handles your answer to whichever website question OLED just asked.
    private func answerWeb(_ text: String) -> Reply {
        if ["cancel", "stop", "never mind", "nevermind", "forget it", "forget about it"].contains(where: { text.contains($0) }) {
            clearPending()
            return Reply(text: "Okay, I won't open anything.", expectsAnswer: false)
        }
        // You can always say it straight out: "a new window", "a new tab".
        if let place = Self.placeMentioned(in: text), place != .current { pendingPlace = place }

        switch webStage {
        case .browser:
            if text.contains("firefox") || text.contains("fire fox") || text.contains("fox") { pendingBrowser = .firefox }
            else if text.contains("safari") || text.contains("sa far") || text.contains("savari") { pendingBrowser = .safari }
            else {
                browserAsks += 1
                if browserAsks >= 3 { clearPending(); return Reply(text: "Never mind, I'll leave it for now.", expectsAnswer: false) }
                return Reply(text: "Sorry, Safari or Firefox?", expectsAnswer: true)
            }
            browserAsks = 0
            return nextWebStep()

        case .existingTab:
            if pendingPlace != nil { return nextWebStep() }
            if Self.isNo(text) {
                webStage = .newWindow
                let b = pendingBrowser?.rawValue ?? "the browser"
                return Reply(text: "Do you want me to open a new window in \(b)?", expectsAnswer: true)
            }
            if Self.isYes(text) {
                pendingPlace = .newTab
                return nextWebStep()
            }
            return Reply(text: "Sorry, do you already have a tab open with another website? Yes or no?", expectsAnswer: true)

        case .newWindow:
            if pendingPlace == .newTab { return nextWebStep() }
            if Self.isNo(text) {
                clearPending()
                return Reply(text: "Okay, I won't type anything.", expectsAnswer: false)
            }
            if Self.isYes(text) || pendingPlace == .newWindow {
                pendingPlace = .newWindow
                return nextWebStep()
            }
            let b = pendingBrowser?.rawValue ?? "the browser"
            return Reply(text: "Sorry, do you want me to open a new window in \(b)? Yes or no?", expectsAnswer: true)
        }
    }

    /// "new window" / "new tab" / "same tab" in what you said, if any.
    private static func placeMentioned(in t: String) -> KeyboardController.Place? {
        let s = " " + t + " "
        if s.contains(" new window") || s.contains(" another window") { return .newWindow }
        if s.contains(" new tab") || s.contains(" another tab") || s.contains(" new page") { return .newTab }
        if s.contains(" same tab") || s.contains(" this tab") || s.contains(" current tab") || s.contains(" same page")
            || s.contains(" same one") || s.contains(" this one") || s.contains(" here ") { return .current }
        return nil
    }

    // MARK: Searching inside websites

    private static func match(_ t: String, _ pattern: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) else { return nil }
        return (1..<m.numberOfRanges).map { i in
            Range(m.range(at: i), in: t).map { String(t[$0]) } ?? ""
        }
    }

    private static func cleanQuery(_ q: String) -> String {
        var s = q.trimmingCharacters(in: .whitespaces)
        for lead in ["for ", "up "] where s.hasPrefix(lead) { s.removeFirst(lead.count) }
        for tail in [" please", " for me"] where s.hasSuffix(tail) { s.removeLast(tail.count) }
        return s.trimmingCharacters(in: .whitespaces)
    }

    struct SearchRequest {
        var query: String
        var site: String?
        var play: Bool
        var mentionsSearchBox: Bool
        var verb: String
    }

    /// Pulls out ONLY the words to search for — no command words, no "enter", no site name:
    ///  "in YouTube type Minecraft" → Minecraft · "type iPhone Duo and then enter" → iPhone Duo
    ///  "go to YouTube and play Minecraft" → Minecraft (site YouTube, then play it)
    static func searchRequest(_ t: String) -> SearchRequest? {
        var s = " " + t.lowercased().replacingOccurrences(of: ",", with: " ").replacingOccurrences(of: "'s ", with: " ") + " "
        s = s.split(separator: " ").joined(separator: " ")
        s = " " + s + " "
        let verbs = [" search", " type ", " look for ", " find ", " play ", " write ", " look up ", " watch "]
        guard let verb = verbs.first(where: { s.contains($0) }) else { return nil }
        let play = s.hasPrefix(" play ") || s.hasPrefix(" watch ")
            || s.range(of: #" (and |then )+(play|click|open|watch)( it| the (first )?(video|one))? "#, options: .regularExpression) != nil
        let mentionsBox = s.range(of: #" search (bar|box|field) "#, options: .regularExpression) != nil

        // Which website (if any), and remove it from the words.
        var site: String?
        for name in PageSearch.siteNames.keys.sorted(by: { $0.count > $1.count }) {
            let escaped = NSRegularExpression.escapedPattern(for: name)
            let pattern = #" (?:(?:on|in|into|at|from|to|go to|open|search|inside) )?(?:the )?"# + escaped
                + #"(?: website| site| app)?(?: search(?: bar| box| field)?)? "#
            if let r = s.range(of: pattern, options: .regularExpression) {
                site = name
                s.replaceSubrange(r, with: " ")
                break
            }
        }
        // Remove "and then press enter", "and play it", "in the search bar"…
        for pattern in [#" (?:and )?(?:then )?(?:press |hit |click )?(?:enter|return)(?: key)?(?= |$)"#,
                        #" (?:and )?(?:then )?(?:play|click on|click|open|watch)(?: it| that| the (?:first )?(?:video|one|result))? $"#,
                        #" (?:in|into|on) (?:the |its )?search(?: bar| box| field)? "#, #" the search(?: bar| box| field)? "#,
                        #" search(?: bar| box| field) "#, #" please "#, #" for me "#] {
            s = s.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        s = s.split(separator: " ").joined(separator: " ")
        var changed = true
        while changed {
            changed = false
            for lead in ["and ", "then ", "go to ", "open ", "search for ", "search ", "type in ", "type out ", "type ",
                         "write ", "look for ", "look up ", "find me ", "find ", "play ", "watch ", "for ", "in ", "into ",
                         "on ", "it ", "the video ", "video of ", "a video of ", "videos of ", "video "] where s.hasPrefix(lead) {
                s.removeFirst(lead.count)
                changed = true
            }
        }
        for tail in [" and", " then", " in", " on", " it", " video", " videos", " please"] {
            while s.hasSuffix(tail) { s.removeLast(tail.count) }
        }
        let query = s.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return nil }
        return SearchRequest(query: query, site: site, play: play, mentionsSearchBox: mentionsBox,
                             verb: verb.trimmingCharacters(in: .whitespaces))
    }

    /// Searching inside a website's own search box (and playing a video if asked).
    private func siteSearch(_ t: String) -> Reply? {
        guard let req = Self.searchRequest(t) else { return nil }
        let browserNow = PageSearch.activeBrowser(lastApp: keyboard.lastExternalApp)
        let s = " " + t + " "
        let saidBrowser: Browser? = s.contains(" firefox") || s.contains(" fire fox") ? .firefox : (s.contains(" safari") ? .safari : nil)
        let saidPlace: KeyboardController.Place? = Self.placeMentioned(in: t)
        let action = req.play ? "Playing" : "Searching for"

        if let site = req.site, let address = PageSearch.siteAddress(for: site) {
            let root = address.split(separator: ".").suffix(2).joined(separator: ".")
            if saidPlace == nil, let browser = saidBrowser ?? browserNow,
               let host = PageSearch.currentPageHost(in: browser), host.hasSuffix(root) {
                guard AccessibilityPermission.isGranted else { return needAccessibility() }
                PageSearch.run(req.query, in: browser, play: req.play)
                return Reply(text: "\(action) \(req.query).", expectsAnswer: false)
            }
            guard let url = Website.url(from: address, force: true) else { return nil }
            return startWeb(url, name: Website.displayName(for: site), typed: nil, browser: saidBrowser, place: saidPlace,
                            thenSearch: req.query, thenPlay: req.play)
        }

        // No website named: use the website that's open now, if it has a search box.
        if let browser = browserNow, AccessibilityPermission.isGranted,
           req.mentionsSearchBox || ["search", "type", "look for", "find", "play", "watch", "write"].contains(req.verb),
           PageSearch.findSearchField(in: browser) != nil {
            PageSearch.run(req.query, in: browser, play: req.play)
            return Reply(text: "\(action) \(req.query).", expectsAnswer: false)
        }
        // "play Minecraft" with no website open: YouTube.
        if req.play, req.verb == "play" || req.verb == "watch",
           let url = Website.url(from: "youtube.com", force: true) {
            return startWeb(url, name: "YouTube", typed: nil, browser: saidBrowser, place: saidPlace,
                            thenSearch: req.query, thenPlay: true)
        }
        return nil
    }

    /// Clicking videos on the page, and play/pause.
    private func videoCommand(_ t: String) -> Reply? {
        guard let browser = PageSearch.activeBrowser(lastApp: keyboard.lastExternalApp) else { return nil }
        let playWords = ["play", "resume", "play the video", "play video", "unpause", "play it", "carry on playing", "start the video"]
        let pauseWords = ["pause", "pause the video", "pause video", "pause it", "stop the video", "stop video", "hold on"]
        if playWords.contains(t) || pauseWords.contains(t) {
            guard AccessibilityPermission.isGranted else { return needAccessibility() }
            let play = playWords.contains(t)
            if VideoPicker.setPlaying(play, in: browser) { return Reply(text: play ? "Playing." : "Paused.", expectsAnswer: false) }
            return Reply(text: "I can't find a video player on this page.", expectsAnswer: false)
        }
        let ordinals: [String: Int] = ["first": 1, "1st": 1, "second": 2, "2nd": 2, "third": 3, "3rd": 3, "fourth": 4, "4th": 4,
                                       "fifth": 5, "5th": 5, "sixth": 6, "seventh": 7, "eighth": 8, "ninth": 9, "tenth": 10, "top": 1]
        if let m = Self.match(t, #"^(?:play|click(?: on)?|open|watch|choose|pick|select) (?:the )?(\w+) (?:video|one|result|link)$"#),
           let n = ordinals[m[0]] {
            guard AccessibilityPermission.isGranted else { return needAccessibility() }
            return VideoPicker.clickVideo(named: nil, number: n, in: browser)
                ? Reply(text: "Playing the \(m[0]) video.", expectsAnswer: false)
                : Reply(text: "I can't find that video on this page.", expectsAnswer: false)
        }
        if let m = Self.match(t, #"^(?:click(?: on)?|open|play|watch|choose|pick|select) (?:the )?(?:video|one)(?: called| named| about| of| with)? (.+)$"#) {
            guard AccessibilityPermission.isGranted else { return needAccessibility() }
            return VideoPicker.clickVideo(named: m[0], number: nil, in: browser)
                ? Reply(text: "Playing it.", expectsAnswer: false)
                : Reply(text: "I can't find that video on this page.", expectsAnswer: false)
        }
        return nil
    }

    // MARK: Understanding website requests

    struct WebPlan {
        var browser: Browser?
        var place: KeyboardController.Place?
        var site: String?
        var search: String?
    }

    private static func replacing(_ s: String, _ pattern: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: " ")
    }

    /// Splits a sentence like "open a new window in Safari and type youtube.com and then enter" into its
    /// parts: browser = Safari, place = new window, site = youtube.com. Nil if it isn't a website request
    /// that mentions a browser or a new tab/window.
    static func parseWeb(_ t: String) -> WebPlan? {
        var s = " " + t + " "
        var plan = WebPlan()
        if s.range(of: #" (fire fox|firefox)('s)? "#, options: .regularExpression) != nil { plan.browser = .firefox }
        else if s.range(of: #" safari('s)? "#, options: .regularExpression) != nil { plan.browser = .safari }
        if s.range(of: #" new windows? "#, options: .regularExpression) != nil { plan.place = .newWindow }
        else if s.range(of: #" new (tabs?|page) "#, options: .regularExpression) != nil { plan.place = .newTab }
        guard plan.browser != nil || plan.place != nil else { return nil }

        // Remove "and then press enter", window/tab words and browser words — what's left is the website.
        s = replacing(s, #" (and )?(then )?(press |hit |click )?(enter|return)( key)? *$"#)
        s = replacing(s, #" please "#)
        s = replacing(s, #" (in|on|with|using|into) (a |an |another )?new (windows?|tabs?|page) "#)
        s = replacing(s, #" (open|launch|start|create|make)?( up)?( me)? ?(a |an |another )?new (windows?|tabs?|page)( (in|on|of|for) (safari|firefox|fire fox))? "#)
        s = replacing(s, #" (in|on|using|with|through) (safari|firefox|fire fox)('s)? "#)
        s = replacing(s, #" (open|launch|start|use|go to|go on)( up)? (safari|firefox|fire fox) "#)
        s = replacing(s, #" (safari|firefox|fire fox)('s)? "#)
        s = s.split(separator: " ").joined(separator: " ")

        var changed = true
        while changed {
            changed = false
            for lead in ["and ", "then ", "go to ", "go on ", "type in ", "type ", "put in ", "enter ", "visit ", "open up ",
                         "open ", "navigate to ", "take me to ", "load ", "bring up ", "show me ", "to ", "the website ",
                         "website ", "the site "] where s.hasPrefix(lead) {
                s.removeFirst(lead.count)
                changed = true
            }
        }
        for tail in [" and", " then", " website", " site", " in it"] where s.hasSuffix(tail) { s.removeLast(tail.count) }
        for verb in ["search for ", "search ", "google ", "look for "] where s.hasPrefix(verb) {
            plan.search = String(s.dropFirst(verb.count))
            return plan
        }
        // A web address said in the sentence wins: "…and type youtube.com and then enter" → youtube.com
        if let r = s.range(of: #"[a-z0-9-]+(\.[a-z0-9-]+)+(/\S*)?"#, options: .regularExpression) {
            plan.site = String(s[r])
        } else if !s.trimmingCharacters(in: .whitespaces).isEmpty {
            plan.site = s.trimmingCharacters(in: .whitespaces)
        }
        return plan.site == nil && plan.search == nil ? nil : plan
    }

    private func runWeb(_ plan: WebPlan) -> Reply {
        if let query = plan.search { return search(query, in: plan.browser, place: plan.place) }
        guard let site = plan.site, let url = Website.url(from: site, force: true) else {
            return Reply(text: "Which website would you like?", expectsAnswer: false)
        }
        return startWeb(url, name: Website.displayName(for: site), typed: nil, browser: plan.browser, place: plan.place)
    }

    private func needAccessibility() -> Reply {
        AccessibilityPermission.request()
        return Reply(text: "I need Accessibility access to use the keyboard. I've opened the settings for you. Switch me on, then ask again.", expectsAnswer: false)
    }

    // MARK: Helpers

    private static let commandVerbs = [
        "open up ", "open ", "launch ", "start up ", "start ", "run ", "go to ", "go on ", "visit ", "take me to ",
        "bring up ", "show me ", "load ", "navigate to ", "type out ", "type in ", "type ", "write ", "press ", "hit ",
        "push ", "search for ", "search ", "google ", "look for ", "find me "
    ]

    private static func isCommand(_ t: String) -> Bool {
        commandVerbs.contains { t.hasPrefix($0) }
    }

    /// Lower-cases, removes the name "OLED", punctuation and polite filler, keeping web addresses intact.
    static func normalise(_ raw: String) -> String {
        var t = WakeWord.strippedFromStart(raw).lowercased().replacingOccurrences(of: "’", with: "'")
        for mark in [",", "!", "?", ";", ":", "\""] { t = t.replacingOccurrences(of: mark, with: " ") }
        t = t.replacingOccurrences(of: ". ", with: " ")
        while t.hasSuffix(".") { t.removeLast() }
        while t.contains("  ") { t = t.replacingOccurrences(of: "  ", with: " ") }
        t = t.trimmingCharacters(in: .whitespaces)

        let leads = ["hey ", "okay ", "ok ", "so ", "um ", "uh ", "erm ", "right ", "and ", "can you please ",
                     "could you please ", "would you please ", "can you ", "could you ", "would you ", "will you ",
                     "please ", "just ", "now ", "i want you to ", "i need you to ", "i'd like you to ", "id like you to ",
                     "i would like you to ", "go ahead and ", "quickly ", "can u ", "for me "]
        var changed = true
        while changed {
            changed = false
            for lead in leads where t.hasPrefix(lead) {
                t.removeFirst(lead.count)
                changed = true
            }
        }
        for tail in [" please", " for me", " right now", " now", " thanks", " thank you", " quickly"] where t.hasSuffix(tail) {
            t.removeLast(tail.count)
        }
        return t.trimmingCharacters(in: .whitespaces)
    }

    /// "i'd really love it if you'd open safari" → "open safari" (a command verb near the start).
    static func fromCommandVerb(_ t: String) -> String {
        if isCommand(t) { return t }
        let questions = ["what", "who", "where", "when", "why", "how", "is", "are", "do", "does", "did", "tell",
                         "which", "define", "explain", "should", "could", "would"]
        if questions.contains(where: { t.hasPrefix($0 + " ") }) { return t }
        var best: Range<String.Index>?
        for verb in commandVerbs {
            if let r = t.range(of: " " + verb), best == nil || r.lowerBound < best!.lowerBound { best = r }
        }
        guard let r = best, t[..<r.lowerBound].split(separator: " ").count <= 8 else { return t }
        return String(t[t.index(after: r.lowerBound)...])
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
