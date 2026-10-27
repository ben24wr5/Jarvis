import Foundation
import AVFoundation

/// OLED's voice: a British male system voice run through a light robotic effect
/// (a very short feedback delay gives the metallic "AI" edge, plus a slight pitch drop).
final class Speaker {
    private let synth = AVSpeechSynthesizer()
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let pitch = AVAudioUnitTimePitch()
    private let comb = AVAudioUnitDelay()
    private let room = AVAudioUnitReverb()
    private var connectedFormat: AVAudioFormat?

    private var pendingBuffers = 0
    private var synthesisEnded = false
    private var completion: (() -> Void)?
    private var session = 0

    static let robotKey = "robotLevel"
    static let voiceKey = "voiceIdentifier"

    init() {
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
        if let id = UserDefaults.standard.string(forKey: voiceKey),
           let voice = AVSpeechSynthesisVoice(identifier: id) {
            return voice
        }
        if let best = britishVoices.first(where: { $0.gender == .male }) { return best }
        if let daniel = AVSpeechSynthesisVoice(identifier: "com.apple.voice.compact.en-GB.Daniel") { return daniel }
        return AVSpeechSynthesisVoice(language: "en-GB")
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
        pendingBuffers = 0
        synthesisEnded = false

        let utterance = AVSpeechUtterance(string: Self.spokenForm(of: text))
        utterance.voice = Self.selectedVoice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.98
        utterance.pitchMultiplier = 0.95
        utterance.postUtteranceDelay = 0.05

        synth.write(utterance) { [weak self] buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer else { return }
            let copy = Self.floatCopy(of: pcm)
            DispatchQueue.main.async {
                guard let self, self.session == current else { return }
                if pcm.frameLength == 0 || copy == nil {
                    if pcm.frameLength == 0 {
                        self.synthesisEnded = true
                        self.finishIfDone()
                    }
                    return
                }
                self.schedule(copy!, session: current)
            }
        }

        // Safety net: never leave the app stuck "speaking".
        let words = max(1, text.split(separator: " ").count)
        let limit = 4 + Double(words) * 0.6
        DispatchQueue.main.asyncAfter(deadline: .now() + limit) { [weak self] in
            guard let self, self.session == current, self.completion != nil else { return }
            if !self.player.isPlaying || self.pendingBuffers == 0 {
                self.synthesisEnded = true
                self.pendingBuffers = 0
                self.finishIfDone()
            }
        }
    }

    func stop() {
        session += 1
        synth.stopSpeaking(at: .immediate)
        if engine.isRunning {
            player.stop()
        }
        pendingBuffers = 0
        synthesisEnded = false
        completion = nil
    }

    private func schedule(_ buffer: AVAudioPCMBuffer, session current: Int) {
        if connectedFormat == nil || connectedFormat! != buffer.format {
            if engine.isRunning { engine.stop() }
            engine.disconnectNodeOutput(player)
            engine.disconnectNodeOutput(pitch)
            engine.disconnectNodeOutput(comb)
            engine.disconnectNodeOutput(room)
            engine.connect(player, to: pitch, format: buffer.format)
            engine.connect(pitch, to: comb, format: buffer.format)
            engine.connect(comb, to: room, format: buffer.format)
            engine.connect(room, to: engine.mainMixerNode, format: buffer.format)
            connectedFormat = buffer.format
        }
        if !engine.isRunning {
            engine.prepare()
            do { try engine.start() } catch {
                NSLog("OLED: speaker engine failed: \(error.localizedDescription)")
                synthesisEnded = true
                pendingBuffers = 0
                finishIfDone()
                return
            }
        }
        pendingBuffers += 1
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.session == current else { return }
                self.pendingBuffers = max(0, self.pendingBuffers - 1)
                self.finishIfDone()
            }
        }
        if !player.isPlaying { player.play() }
    }

    private func finishIfDone() {
        guard synthesisEnded, pendingBuffers == 0, let done = completion else { return }
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
