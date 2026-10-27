import Foundation
import AVFoundation
import AppKit

/// OLED's voice: a British male voice, tuned slightly lower and steadier for an AI feel.
/// It speaks with Apple's speech synthesiser, and if that ever stays silent it falls back to
/// macOS's built-in `say` command, so OLED always talks.
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    private let synth = AVSpeechSynthesizer()
    private var sayProcess: Process?
    private var completion: (() -> Void)?
    private var session = 0
    private var started = false
    private var synthWorks = true

    /// Last problem with the voice, shown in Settings → Status.
    private(set) var lastIssue: String?

    static let robotKey = "robotLevel"
    static let voiceKey = "voiceIdentifier"

    override init() {
        super.init()
        synth.delegate = self
    }

    /// 0 = natural voice, 1 = most robotic (lower, flatter). Default 0.5.
    var robotLevel: Double {
        get { UserDefaults.standard.object(forKey: Self.robotKey) as? Double ?? 0.5 }
        set { UserDefaults.standard.set(newValue, forKey: Self.robotKey) }
    }

    // MARK: Voices

    static var britishVoices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language == "en-GB" }
            .sorted { a, b in
                if a.gender != b.gender { return a.gender == .male }
                return a.quality.rawValue > b.quality.rawValue
            }
    }

    static var selectedVoice: AVSpeechSynthesisVoice? {
        if let id = UserDefaults.standard.string(forKey: voiceKey), !id.isEmpty,
           let voice = AVSpeechSynthesisVoice(identifier: id) {
            return voice
        }
        if let best = britishVoices.first(where: { $0.gender == .male }) { return best }
        if let daniel = AVSpeechSynthesisVoice(identifier: "com.apple.voice.compact.en-GB.Daniel") { return daniel }
        if let gb = AVSpeechSynthesisVoice(language: "en-GB") { return gb }
        return AVSpeechSynthesisVoice(language: "en-US")
    }

    /// Makes sure the name is always said letter by letter: "O-L-E-D".
    static func spokenForm(of text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "\\bO\\.?L\\.?E\\.?D\\b\\.?", options: [.caseInsensitive]) else {
            return text
        }
        let ns = text as NSString
        return regex.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: ns.length), withTemplate: "O. L. E. D.")
    }

    // MARK: Speaking

    var isSpeaking: Bool { completion != nil }

    func speak(_ text: String, completion: @escaping () -> Void) {
        stop()
        session += 1
        let current = session
        self.completion = completion
        started = false
        let spoken = Self.spokenForm(of: text)

        guard synthWorks else {
            speakWithSay(spoken, session: current)
            return
        }

        let level = max(0, min(1, robotLevel))
        let utterance = AVSpeechUtterance(string: spoken)
        utterance.voice = Self.selectedVoice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * Float(0.98 - 0.08 * level)
        utterance.pitchMultiplier = Float(1.0 - 0.25 * level)
        utterance.volume = 1.0
        synth.speak(utterance)

        // If nothing has started after a moment, use the built-in `say` command instead.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, self.session == current, !self.started, self.completion != nil else { return }
            self.lastIssue = "Apple's speech synthesiser stayed silent, so OLED is using the built-in say command."
            self.synthWorks = false
            self.synth.stopSpeaking(at: .immediate)
            self.speakWithSay(spoken, session: current)
        }
    }

    private func speakWithSay(_ text: String, session current: Int) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        var args: [String] = []
        if let name = Self.selectedVoice?.name { args += ["-v", name] }
        let wpm = Int(185 - 25 * max(0, min(1, robotLevel)))
        args += ["-r", String(wpm), text]
        p.arguments = args
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self, self.session == current else { return }
                if proc.terminationStatus != 0, args.first == "-v" {
                    // Voice name not recognised by `say`: try once more with the default voice.
                    let retry = Process()
                    retry.executableURL = URL(fileURLWithPath: "/usr/bin/say")
                    retry.arguments = [text]
                    retry.terminationHandler = { _ in DispatchQueue.main.async { self.finish(current) } }
                    self.sayProcess = retry
                    try? retry.run()
                    return
                }
                self.finish(current)
            }
        }
        sayProcess = p
        do { try p.run() } catch {
            lastIssue = "Couldn't start speech: \(error.localizedDescription)"
            finish(current)
        }
    }

    private func finish(_ current: Int) {
        guard session == current, let done = completion else { return }
        completion = nil
        done()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.started = true }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let current = session
        DispatchQueue.main.async { [weak self] in
            guard let self, self.started else { return }
            self.finish(current)
        }
    }

    func stop() {
        session += 1
        synth.stopSpeaking(at: .immediate)
        if let p = sayProcess, p.isRunning { p.terminate() }
        sayProcess = nil
        completion = nil
    }
}
