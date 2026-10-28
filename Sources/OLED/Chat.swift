import Foundation
import Security
import ObjCSupport
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Removes any Claude API key saved by older versions of OLED. OLED no longer uses one.
enum LegacyKeyCleanup {
    static func run() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "OLED",
            kSecAttrAccount as String: "anthropic-api-key"
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// Answers anything that isn't a Mac command — with no API key and nothing to pay for.
/// 1. Small talk and maths, built in.
/// 2. Apple's on-device AI (Apple Intelligence) when the Mac has it — free, private, offline.
/// 3. Otherwise free lookups: Wikipedia for people, places and things; a free dictionary for meanings.
final class ChatClient {
    static let instructions = """
    You are OLED, a voice assistant on the user's Mac. Your name is always pronounced letter by letter, O-L-E-D. \
    You speak with a calm, polite British manner and a little dry wit. Help with anything: general knowledge, \
    people, places, history, science, films, cartoons, sport, maths, definitions, ideas and casual chat. \
    Everything you say is spoken aloud, so reply in plain sentences with no lists, markdown, emoji or links. \
    Keep replies short, one to three sentences, unless asked for more. If something is very recent and you \
    can't know it, say so briefly.
    """

    #if canImport(FoundationModels)
    private var sessionStore: Any?
    #endif

    func reset() {
        #if canImport(FoundationModels)
        sessionStore = nil
        #endif
    }

    func reply(to message: String, completion: @escaping (String) -> Void) {
        let done: (String) -> Void = { text in DispatchQueue.main.async { completion(text) } }
        let lower = message.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))

        if let quick = Self.smallTalk(lower) { done(quick); return }
        if let sum = Self.maths(lower) { done(sum); return }

        askAppleAI(message) { answer in
            if let answer { done(answer); return }
            Self.lookUp(lower, done: done)
        }
    }

    // MARK: Apple's on-device AI

    private func askAppleAI(_ message: String, completion: @escaping (String?) -> Void) {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            guard case .available = SystemLanguageModel.default.availability else { completion(nil); return }
            let session: LanguageModelSession
            if let existing = sessionStore as? LanguageModelSession {
                session = existing
            } else {
                session = LanguageModelSession(instructions: Self.instructions)
                sessionStore = session
            }
            Task {
                do {
                    let response = try await session.respond(to: message)
                    let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                    completion(text.isEmpty ? nil : text)
                } catch {
                    // e.g. conversation too long: start fresh next time, fall back to lookups now.
                    await MainActor.run { self.sessionStore = nil }
                    completion(nil)
                }
            }
            return
        }
        #endif
        completion(nil)
    }

    // MARK: Built-in answers

    private static func smallTalk(_ t: String) -> String? {
        let replies: [([String], [String])] = [
            (["how are you", "how are you doing", "how's it going", "how is it going", "you alright", "are you ok", "how's your day", "how is your day"],
             ["All systems running smoothly, thank you. How can I help?", "Very well, thanks for asking. What can I do for you?"]),
            (["who are you", "what are you", "what's your name", "what is your name", "introduce yourself"],
             ["I'm OLED, your Mac assistant. I can open apps and websites, use the keyboard, check the weather and answer questions."]),
            (["what can you do", "help", "what do you do", "what can i say"],
             ["I can open apps and websites, type and press keys, tell you the time and weather, tell jokes, answer questions, and shut down, restart, sleep or lock your Mac."]),
            (["who made you", "who created you", "who built you"],
             ["I was built for you, to run right here on your Mac."]),
            (["i love you", "love you"],
             ["That's very kind. I'm rather fond of you too."]),
            (["you're good", "good job", "well done", "you're amazing", "you're the best", "nice"],
             ["Thank you. I do try."]),
            (["what's up", "whats up", "sup"],
             ["Not much, just keeping your Mac company. What can I do for you?"]),
            (["are you there", "you there"],
             ["Always. What do you need?"])
        ]
        for (phrases, answers) in replies where phrases.contains(t) {
            return answers.randomElement()
        }
        return nil
    }

    /// "what's 12 times 7", "15 plus 27", "100 divided by 4", "square root of 81", "20 percent of 150"
    private static func maths(_ t: String) -> String? {
        var s = " " + t + " "
        for lead in [" what's ", " what is ", " whats ", " calculate ", " how much is ", " work out "] {
            s = s.replacingOccurrences(of: lead, with: " ")
        }
        if let r = s.range(of: #"square root of ([0-9.]+)"#, options: .regularExpression) {
            let n = Double(s[r].replacingOccurrences(of: "square root of ", with: "")) ?? 0
            return "The square root of \(format(n)) is \(format(n.squareRoot()))."
        }
        if let r = s.range(of: #"([0-9.]+) percent of ([0-9.]+)"#, options: .regularExpression) {
            let parts = s[r].components(separatedBy: " percent of ")
            if parts.count == 2, let a = Double(parts[0]), let b = Double(parts[1]) {
                return "\(format(a)) percent of \(format(b)) is \(format(a * b / 100))."
            }
        }
        let words: [(String, String)] = [
            (" multiplied by ", " * "), (" times ", " * "), (" x ", " * "), (" divided by ", " / "),
            (" over ", " / "), (" plus ", " + "), (" add ", " + "), (" minus ", " - "), (" take away ", " - "),
            (" squared ", " ** 2 "), (" cubed ", " ** 3 ")
        ]
        for (w, op) in words { s = s.replacingOccurrences(of: w, with: op) }
        let expr = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "?", with: "")
        guard expr.range(of: #"^[0-9.\s+\-*/()]+$"#, options: .regularExpression) != nil,
              expr.rangeOfCharacter(from: CharacterSet(charactersIn: "+-*/")) != nil,
              expr.rangeOfCharacter(from: .decimalDigits) != nil else { return nil }
        // Make every whole number a decimal so 7 / 2 gives 3.5, not 3.
        let decimal = expr.replacingOccurrences(of: #"(?<![\d.])(\d+)(?![\d.])"#, with: "$1.0", options: .regularExpression)
        var result: Double?
        // NSExpression raises an Objective-C exception on bad input; catch it instead of crashing.
        try? OLEDSafe.run {
            let value = NSExpression(format: decimal).expressionValue(with: nil, context: nil)
            result = (value as? NSNumber)?.doubleValue
        }
        guard let value = result, value.isFinite else { return nil }
        return "That's \(format(value))."
    }

    static func format(_ n: Double) -> String {
        if n == n.rounded() && abs(n) < 1e15 { return String(Int(n)) }
        let f = NumberFormatter()
        f.maximumFractionDigits = 4
        f.minimumFractionDigits = 0
        return f.string(from: NSNumber(value: n)) ?? String(n)
    }

    // MARK: Free lookups (no key)

    private static func getJSON(_ url: URL, completion: @escaping (Any?) -> Void) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("OLED-Mac-assistant/1.0", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, _, _ in
            completion(data.flatMap { try? JSONSerialization.jsonObject(with: $0) })
        }.resume()
    }

    private static func lookUp(_ t: String, done: @escaping (String) -> Void) {
        // Meanings: "what does X mean", "define X", "meaning of X"
        for pattern in [#"^(?:define|definition of|meaning of|what's the meaning of|what is the meaning of) (.+)$"#,
                        #"^what does (.+) mean$"#] {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let m = regex.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
               let r = Range(m.range(at: 1), in: t) {
                define(String(t[r]), done: done)
                return
            }
        }
        // People, places, things: strip the question words and ask Wikipedia.
        var topic = t
        for lead in ["tell me about ", "tell me something about ", "who is ", "who was ", "who are ", "what is a ", "what is an ",
                     "what is ", "what's a ", "what's an ", "what's ", "what are ", "where is ", "where's ", "when was ", "when is ",
                     "how does ", "how do ", "why is ", "why do ", "explain ", "do you know ", "search for ", "look up ", "who's "]
        where topic.hasPrefix(lead) {
            topic = String(topic.dropFirst(lead.count))
            break
        }
        for tail in [" please", " for me"] where topic.hasSuffix(tail) { topic.removeLast(tail.count) }
        wikipedia(topic.isEmpty ? t : topic, done: done)
    }

    private static func define(_ word: String, done: @escaping (String) -> Void) {
        let w = word.trimmingCharacters(in: .whitespaces)
        guard let encoded = w.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://api.dictionaryapi.dev/api/v2/entries/en/\(encoded)") else {
            wikipedia(w, done: done); return
        }
        getJSON(url) { json in
            guard let entries = json as? [[String: Any]],
                  let meanings = entries.first?["meanings"] as? [[String: Any]],
                  let first = meanings.first,
                  let defs = first["definitions"] as? [[String: Any]],
                  let definition = defs.first?["definition"] as? String else {
                wikipedia(w, done: done); return
            }
            let kind = (first["partOfSpeech"] as? String).map { " is a \($0) meaning" } ?? " means"
            done("\(w.capitalized)\(kind): \(definition)")
        }
    }

    private static func wikipedia(_ topic: String, done: @escaping (String) -> Void) {
        var search = URLComponents(string: "https://en.wikipedia.org/w/api.php")!
        search.queryItems = [
            URLQueryItem(name: "action", value: "query"), URLQueryItem(name: "list", value: "search"),
            URLQueryItem(name: "srsearch", value: topic), URLQueryItem(name: "srlimit", value: "1"),
            URLQueryItem(name: "format", value: "json")
        ]
        getJSON(search.url!) { json in
            guard let query = (json as? [String: Any])?["query"] as? [String: Any],
                  let results = query["search"] as? [[String: Any]],
                  let title = results.first?["title"] as? String,
                  let encoded = title.replacingOccurrences(of: " ", with: "_")
                    .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                  let summaryURL = URL(string: "https://en.wikipedia.org/api/rest_v1/page/summary/\(encoded)") else {
                done("I'm not sure about that one. Try asking it a different way.")
                return
            }
            getJSON(summaryURL) { json in
                guard let extract = (json as? [String: Any])?["extract"] as? String, !extract.isEmpty else {
                    done("I'm not sure about that one. Try asking it a different way.")
                    return
                }
                done(firstSentences(of: extract, count: 2))
            }
        }
    }

    private static func firstSentences(of text: String, count: Int) -> String {
        var sentences: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { sub, _, _, stop in
            if let sub { sentences.append(sub.trimmingCharacters(in: .whitespaces)) }
            if sentences.count >= count { stop = true }
        }
        let result = sentences.joined(separator: " ")
        return result.isEmpty ? text : result
    }
}
