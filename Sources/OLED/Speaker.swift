import Foundation
import AVFoundation
import ObjCSupport

/// OLED's voice: a British male system voice run through a robotic effect
/// (a very short feedback delay gives the metallic "AI" edge, plus a slight pitch drop).
/// If the effect path ever produces no sound, OLED falls back to speaking directly, so it is never silent.
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    private let effectSynth = AVSpeechSynthesizer()
    private let plainSynth = AVSpeechSynthesizer()
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let pitch = AVAudioUnitTimePitch()
    private let comb = AVAudioUnitDelay()
    private let room = AVAudioUnitReverb()
    private var connectedFormat: AVAudioFormat?

    private var pendingBuffers = 0
    private var receivedAudio = false
    private var synthesisEnded = false
    private var completion: (() -> Void)?
    private var session = 0
    private var effectWorks = true

    /// Last problem with the voice, shown in Settings → Status.
    private(set) var lastIssue: String?

    static let robotKey = "robotLevel"
    static let voiceKey = "voiceIdentifier"

    override init() {
        super.init()
        plainSynth.delegate = self
        engine.attach(player)
        engine.attach(pitch)
        engine.attach(comb)
        engine.attach(room)
        room.loadFactoryPreset(.smallRoom)
        applyRobotLevel()
    }

    /// 0 = plain voice, 1 = very robotic. Default 0.5.
    var robotLevel: Double {
        get { UserDefaults.standard.object(forKey: Self.robotKey) as? Double ?? 0.5 }
        set { UserDefaults.standard.set(newValue, forKey: Self.robotKey); applyRobotLevel() }
    }

    private func applyRobotLevel() {
        let level = max(0, min(1, robotLevel))
        comb.delayTime = 0.009
        comb.feedback = Float(45 + 30 * level)
        comb.lowPassCutoff = 9000
        comb.wetDryMix = Float(15 + 50 * level)
        pitch.pitch = Float(-60 - 120 * level)
        pitch.rate = 1.0
        room.wetDryMix = 8
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

    private func makeUtterance(_ text: String) -> AVSpeechUtterance {
        let utterance = AVSpeechUtterance(string: Self.spokenForm(of: text))
        utterance.voice = Self.selectedVoice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.98
        utterance.pitchMultiplier = 0.95
        utterance.volume = 1.0
        return utterance
    }

    // MARK: Speaking

    var isSpeaking: Bool { completion != nil }

    func speak(_ text: String, completion: @escaping () -> Void) {
        stop()
        session += 1
        let current = session
        self.completion = completion
        pendingBuffers = 0
        receivedAudio = false
        synthesisEnded = false

        guard effectWorks else {
            speakPlain(text)
            return
        }

        effectSynth.write(makeUtterance(text)) { [weak self] buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer else { return }
            let copy = Self.floatCopy(of: pcm)
            let isEnd = pcm.frameLength == 0
            DispatchQueue.main.async {
                guard let self, self.session == current else { return }
                if isEnd {
                    self.synthesisEnded = true
                    self.finishIfDone()
                } else if let copy {
                    self.schedule(copy, session: current)
                }
            }
        }

        // If the robotic path makes no sound quickly, speak directly instead.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.session == current, self.completion != nil, !self.receivedAudio else { return }
            self.lastIssue = "Robotic voice effect produced no audio, so OLED is using the plain voice."
            self.effectWorks = false
            self.effectSynth.stopSpeaking(at: .immediate)
            self.speakPlain(text)
        }
    }

    private func speakPlain(_ text: String) {
        plainSynth.stopSpeaking(at: .immediate)
        plainSynth.speak(makeUtterance(text))
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let done = self.completion else { return }
            self.completion = nil
            done()
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {}

    func stop() {
        session += 1
        effectSynth.stopSpeaking(at: .immediate)
        plainSynth.stopSpeaking(at: .immediate)
        let engine = self.engine, player = self.player
        try? OLEDSafe.run { if engine.isRunning { player.stop() } }
        pendingBuffers = 0
        synthesisEnded = false
        completion = nil
    }

    private func schedule(_ buffer: AVAudioPCMBuffer, session current: Int) {
        let engine = self.engine, player = self.player, pitch = self.pitch, comb = self.comb, room = self.room
        do {
            if connectedFormat == nil || connectedFormat! != buffer.format {
                try OLEDSafe.run {
                    if engine.isRunning { engine.stop() }
                    engine.disconnectNodeOutput(player)
                    engine.disconnectNodeOutput(pitch)
                    engine.disconnectNodeOutput(comb)
                    engine.disconnectNodeOutput(room)
                    engine.connect(player, to: pitch, format: buffer.format)
                    engine.connect(pitch, to: comb, format: buffer.format)
                    engine.connect(comb, to: room, format: buffer.format)
                    engine.connect(room, to: engine.mainMixerNode, format: buffer.format)
                }
                connectedFormat = buffer.format
            }
            if !engine.isRunning {
                var startError: Error?
                try OLEDSafe.run {
                    engine.prepare()
                    do { try engine.start() } catch { startError = error }
                }
                if let startError { throw startError }
            }
            try OLEDSafe.run {
                player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                    DispatchQueue.main.async {
                        guard let self, self.session == current else { return }
                        self.pendingBuffers = max(0, self.pendingBuffers - 1)
                        self.finishIfDone()
                    }
                }
                if !player.isPlaying { player.play() }
            }
            receivedAudio = true
            pendingBuffers += 1
        } catch {
            // Robotic path failed: the 1.5 s fallback speaks with the plain voice instead.
            lastIssue = "Robotic voice effect failed (\(error.localizedDescription)); using the plain voice."
            effectWorks = false
            connectedFormat = nil
        }
    }

    private func finishIfDone() {
        guard synthesisEnded, pendingBuffers == 0, receivedAudio, let done = completion else { return }
        completion = nil
        done()
    }

    /// Converts whatever the synthesiser produces into standard Float32 audio the effects can use.
    private static func floatCopy(of buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0 else { return nil }
        let src = buffer.format
        guard let dstFormat = AVAudioFormat(standardFormatWithSampleRate: src.sampleRate,
                                            channels: max(1, src.channelCount)),
              let out = AVAudioPCMBuffer(pcmFormat: dstFormat, frameCapacity: buffer.frameLength),
              let converter = AVAudioConverter(from: src, to: dstFormat) else { return nil }
        var supplied = false
        var error: NSError?
        _ = converter.convert(to: out, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        if error != nil || out.frameLength == 0 { return nil }
        return out
    }
}
