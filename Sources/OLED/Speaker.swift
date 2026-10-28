import Foundation
import AVFoundation
import AppKit

/// OLED's voice: a British male voice turned into a robotic AI voice.
///
/// How it works (built to never go silent):
/// 1. macOS's `say` command records the line with the chosen British voice to a temporary file.
/// 2. OLED processes that recording: a slightly deeper pitch, a metallic resonance and a gentle
///    robotic "ring" — the strength follows the Human ↔ Robotic slider in Settings.
/// 3. The finished sound is played with a standard audio player (which also drives the orb).
/// If any step fails, OLED simply speaks the line with the plain voice instead.
final class Speaker: NSObject, AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {
    private var player: AVAudioPlayer?
    private let plainSynth = AVSpeechSynthesizer()
    private var renderProcess: Process?
    private var completion: (() -> Void)?
    private var session = 0
    private var plainSpeaking = false
    private var lastWord = Date.distantPast

    /// Last problem with the voice, shown in Settings → Status.
    private(set) var lastIssue: String?

    static let robotKey = "robotVoiceLevel"
    static let voiceKey = "voiceIdentifier"

    override init() {
        super.init()
        plainSynth.delegate = self
    }

    /// 0 = natural voice, 1 = most robotic. Default 0.65 (clearly an AI, still easy to understand).
    /// Uses a new setting name so the robotic default applies even if the slider was moved before.
    var robotLevel: Double {
        get { UserDefaults.standard.object(forKey: Self.robotKey) as? Double ?? 0.65 }
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
        let spoken = Self.spokenForm(of: text)
        let level = max(0, min(1, robotLevel))

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("OLED-voice", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let raw = dir.appendingPathComponent("line-\(current).caf")
        let robot = dir.appendingPathComponent("line-\(current).wav")

        // 1. Record the line with the British voice.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        var args: [String] = []
        if let name = Self.selectedVoice?.name { args += ["-v", name] }
        args += ["-r", String(Int(178 - 18 * level)), "-o", raw.path, "--data-format=LEF32@22050", spoken]
        p.arguments = args
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.global(qos: .userInitiated).async {
                // 2. Make it robotic.
                let ok = proc.terminationStatus == 0 && Self.robotise(input: raw, output: robot, level: level)
                DispatchQueue.main.async {
                    guard let self, self.session == current else { return }
                    if ok {
                        self.play(robot, session: current, fallbackText: spoken)
                    } else {
                        self.lastIssue = "Robotic voice couldn't be made for that line, so OLED used the plain voice."
                        self.speakPlain(spoken)
                    }
                    try? FileManager.default.removeItem(at: raw)
                }
            }
        }
        renderProcess = p
        do { try p.run() } catch {
            lastIssue = "Couldn't record the voice: \(error.localizedDescription). Using the plain voice."
            speakPlain(spoken)
        }
    }

    // 3. Play the robotic recording.
    private func play(_ url: URL, session current: Int, fallbackText: String) {
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            player.isMeteringEnabled = true
            player.prepareToPlay()
            self.player = player
            if !player.play() { throw NSError(domain: "OLED", code: 2) }
        } catch {
            lastIssue = "Couldn't play the robotic voice, so OLED used the plain voice."
            speakPlain(fallbackText)
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        try? FileManager.default.removeItem(at: player.url ?? URL(fileURLWithPath: "/nonexistent"))
        finish()
    }

    private func speakPlain(_ text: String) {
        plainSpeaking = true
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.selectedVoice
        utterance.pitchMultiplier = 0.85
        plainSynth.speak(utterance)
        // If even this stays silent, don't leave OLED stuck "speaking".
        let current = session
        let words = max(1, text.split(separator: " ").count)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3 + Double(words) * 0.5) { [weak self] in
            guard let self, self.session == current, self.plainSpeaking else { return }
            self.finish()
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.lastWord = Date() }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in self?.finish() }
    }

    private func finish() {
        plainSpeaking = false
        guard let done = completion else { return }
        completion = nil
        done()
    }

    func stop() {
        session += 1
        if let p = renderProcess, p.isRunning { p.terminate() }
        renderProcess = nil
        player?.stop()
        player = nil
        plainSynth.stopSpeaking(at: .immediate)
        plainSpeaking = false
        completion = nil
    }

    /// How loud OLED is right now (0…1), so the orb moves with the voice.
    var voiceLevel: Double {
        guard completion != nil else { return 0 }
        if let player, player.isPlaying {
            player.updateMeters()
            let db = Double(player.averagePower(forChannel: 0)) // about -60 (quiet) … 0 (loud)
            return max(0, min(1, (db + 45) / 40))
        }
        if plainSpeaking {
            let since = Date().timeIntervalSince(lastWord)
            return since < 1.5 ? 0.25 + 0.75 * Foundation.exp(-since * 5) : 0.15
        }
        return 0
    }

    // MARK: The robotic effect

    /// Reads the recording, makes it sound like an AI and writes it out. Returns false on any problem.
    private static func robotise(input: URL, output: URL, level: Double) -> Bool {
        guard let file = try? AVAudioFile(forReading: input),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil,
              let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return false }

        let rate = file.processingFormat.sampleRate
        let n = Int(buffer.frameLength)
        let src = Array(UnsafeBufferPointer(start: channel, count: n))

        // Deeper: play slightly slower (lower pitch), more so when more robotic.
        let speed = 1.0 - 0.07 * level
        let outCount = Int(Double(n) / speed)
        var out = [Float](repeating: 0, count: outCount)
        for i in 0..<outCount {
            let pos = Double(i) * speed
            let j = Int(pos)
            let frac = Float(pos - Double(j))
            let a = src[min(j, n - 1)], b = src[min(j + 1, n - 1)]
            out[i] = a + (b - a) * frac
        }

        // Robotic ring: blend in the voice multiplied by a low tone.
        let ringMix = Float(0.15 + 0.4 * level)
        let ringHz = 52.0
        for i in 0..<outCount {
            let ring = Float(Foundation.sin(2 * Double.pi * ringHz * Double(i) / rate))
            out[i] = out[i] * (1 - ringMix) + out[i] * ring * ringMix
        }

        // Metallic resonance: a very short echo fed back on itself.
        let delay = max(1, Int(rate * 0.0075))
        let feedback = Float(0.3 + 0.3 * level)
        if outCount > delay {
            for i in delay..<outCount { out[i] += out[i - delay] * feedback }
        }

        // Even out the volume.
        let peak = out.reduce(0) { max($0, abs($1)) }
        guard peak > 0 else { return false }
        let gain = 0.9 / peak
        for i in 0..<outCount { out[i] *= gain }

        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
              let outBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(outCount)),
              let dest = outBuffer.floatChannelData?[0] else { return false }
        outBuffer.frameLength = AVAudioFrameCount(outCount)
        out.withUnsafeBufferPointer { dest.update(from: $0.baseAddress!, count: outCount) }
        try? FileManager.default.removeItem(at: output)
        guard let outFile = try? AVAudioFile(forWriting: output, settings: format.settings) else { return false }
        return (try? outFile.write(from: outBuffer)) != nil
    }
}
