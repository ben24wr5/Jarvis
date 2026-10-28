import Foundation

/// Spots the name "OLED" in whatever Apple's speech recognition wrote down.
///
/// "OLED" isn't a normal word, so Apple writes it many ways: "OLED", "Oled", "O.L.E.D.", "O L E D",
/// "oh LED", "Oh lead", "old", "Oleg", "Olay", "a led", "oh el ee dee"… This matcher accepts all of
/// them (and anything one letter away), so the name works for anyone, with or without AirPods.
enum WakeWord {
    /// Spellings that are clearly the name.
    private static let known: Set<String> = [
        "oled", "oleds", "ohled", "olead", "ohlead", "oleed", "oheld", "olid", "ohlid", "olet", "ohlet",
        "oleg", "olay", "olaid", "olayed", "aled", "alled", "allied", "olied", "oiled", "ollied", "oloed",
        "oheleedee", "oleedee", "oheleed", "oheled", "oelled", "olled", "owled", "oled's", "olead's"
    ]
    /// Close-enough targets for fuzzy matching (one letter different).
    private static let targets = ["oled", "ohled", "olead", "ohlead", "oleed"]
    /// First words that can begin a name spoken in pieces ("o l e d", "oh led", "a led", "ole d").
    private static let starters: Set<String> = ["o", "oh", "ole", "oll", "a", "al", "all", "ol"]
    /// "old" is a real word, so only count it when it isn't used as one ("how old", "years old"…).
    private static let oldBlockers: Set<String> = [
        "how", "years", "year", "so", "too", "very", "an", "the", "my", "your", "his", "her", "their", "our",
        "is", "was", "are", "were", "get", "getting", "grow", "growing", "good", "same", "be", "that", "this",
        "months", "weeks", "days", "as", "of", "really", "pretty", "quite", "an", "these", "those"
    ]

    /// The words as spoken (kept for the command, so "youtube.com" stays intact)…
    static func words(of text: String) -> [String] {
        text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).map(String.init)
    }

    /// …and a simplified copy of each word for matching: "O.L.E.D.," → "oled", "Oh," → "oh".
    static func tokens(of text: String) -> [String] {
        words(of: text).map(simplify)
    }

    private static func simplify(_ word: String) -> String {
        word.lowercased()
            .replacingOccurrences(of: "é", with: "e")
            .filter { $0.isLetter || $0.isNumber }
    }

    /// Real words that are one letter away from the name but aren't it.
    private static let realWords: Set<String> = [
        "lead", "plead", "bleed", "fled", "sled", "bled", "owed", "oped", "lied", "oles", "olea", "oleo",
        "ole", "oped", "olden", "older", "holed", "poled", "soled", "doled", "ogled", "boled", "oiler"
    ]

    /// Where the name is (first token, token just after it), using the LAST time it was said.
    static func findName(in tokens: [String]) -> (start: Int, end: Int)? {
        var found: (Int, Int)?
        for i in tokens.indices {
            // Single word
            let w = tokens[i]
            if isName(w) || (w == "old" && (i == 0 || !oldBlockers.contains(tokens[i - 1]))) {
                found = (i, i + 1)
                continue
            }
            // Name spoken in pieces: "oh led", "o l e d", "oh el ee dee"
            guard starters.contains(w) else { continue }
            var joined = w
            for j in (i + 1)..<min(tokens.count, i + 4) {
                joined += tokens[j].replacingOccurrences(of: "'", with: "")
                if isName(joined) { found = (i, j + 1); break }
            }
        }
        return found
    }

    private static func isName(_ word: String) -> Bool {
        let w = word.replacingOccurrences(of: "'", with: "")
        if known.contains(w) { return true }
        if realWords.contains(w) { return false }
        guard w.count >= 4, w.count <= 7 else { return false }
        return targets.contains { distance(w, $0) <= 1 }
    }

    /// Text after the name (as spoken), or nil if the name wasn't said.
    static func textAfter(in text: String) -> String? {
        let w = words(of: text)
        guard let name = findName(in: w.map(simplify)) else { return nil }
        return w[name.end...].joined(separator: " ")
    }

    /// Removes the name (and "hey"/"okay" before it) from the start of a command:
    /// "Hey OLED, open Safari" → "open Safari".
    static func strippedFromStart(_ text: String) -> String {
        let w = words(of: text)
        let t = w.map(simplify)
        guard let name = findName(in: Array(t.prefix(6))) else { return text }
        let before = t[..<name.start].filter { !["hey", "hi", "ok", "okay", "yo", "oi", "so", "right", "and"].contains($0) }
        // Only strip when the name really was at the start (nothing meaningful before it).
        guard before.isEmpty else { return text }
        return w[name.end...].joined(separator: " ")
    }

    /// Number of single-letter edits between two words.
    private static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
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
}
