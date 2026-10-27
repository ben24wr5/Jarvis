import Foundation
import AVFoundation
import Speech

/// Listens to the microphone and turns speech into commands.
/// In `.wake` mode it waits for the name "OLED"; in `.direct` mode everything heard is the command.
final class SpeechListener {
    enum Mode { case wake, direct }

    var onWake: (() -> Void)?
    var onCommand: ((String) -> Void)?
    var onTimeout: (() -> Void)?

    private let recognizer: SFSpeechRecognizer? =
        SFSpeechRecognizer(locale: Locale(identifier: "en-GB")) ?? SFSpeechRecognizer()
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    private var mode: Mode = .wake
    private var woke = false
    private var commandText = ""
    private var generation = 0
    private var silenceTimer: Timer?
    private var giveUpTimer: Timer?
    private var refreshTimer: Timer?
    private var tapInstalled = false

    /// How long to wait for a command after waking, or after a question.
    var directTimeout: TimeInterval = 7

    static var isAuthorized: Bool {
        SFSpeechRecognizer.authorizationStatus() == .authorized &&
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    // MARK: Control

    func start(mode: Mode, timeout: TimeInterval = 7) {
        stop()
        guard Self.isAuthorized, let recognizer, recognizer.isAvailable else {
            // Try again shortly (e.g. recogniser still warming up).
            if Self.isAuthorized {
                let gen = generation
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    guard let self, self.generation == gen else { return }
                    self.start(mode: mode, timeout: timeout)
                }
            }
            return
        }

        self.mode = mode
        self.directTimeout = timeout
        woke = (mode == .direct)
        commandText = ""
        let gen = generation

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        request.contextualStrings = ["OLED", "O L E D", "Firefox", "Safari", "open", "press", "type"]
        self.request = request

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else { return }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak request] buffer, _ in
            request?.append(buffer)
        }
        tapInstalled = true

        engine.prepare()
        do {
            try engine.start()
        } catch {
            NSLog("OLED: audio engine failed to start: \(error.localizedDescription)")
            cleanUpAudio()
            return
        }

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failed = error != nil
            DispatchQueue.main.async {
                guard let self, self.generation == gen else { return }
                if let text { self.handle(text: text) }
                if isFinal || failed { self.recognitionEnded() }
            }
        }

        if mode == .direct {
            armGiveUp()
        } else {
            // Recognition sessions have a time limit, so refresh quietly while waiting for the name.
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 45, repeats: false) { [weak self] _ in
                guard let self, self.generation == gen, !self.woke else { return }
                self.start(mode: .wake)
            }
        }
    }

    func stop() {
        generation += 1
        silenceTimer?.invalidate(); silenceTimer = nil
        giveUpTimer?.invalidate(); giveUpTimer = nil
        refreshTimer?.invalidate(); refreshTimer = nil
        task?.cancel(); task = nil
        request?.endAudio(); request = nil
        cleanUpAudio()
    }

    private func cleanUpAudio() {
        if engine.isRunning { engine.stop() }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
    }

    // MARK: Handling speech

    private static let wakePattern = try! NSRegularExpression(
        pattern: "\\bo\\.?\\s*l\\.?\\s*e\\.?\\s*d\\b\\.?,?",
        options: [.caseInsensitive])

    /// Returns the text spoken after the name "OLED", or nil if the name wasn't said.
    static func textAfterWakeWord(in text: String) -> String? {
        let cleaned = text.replacingOccurrences(of: "-", with: " ")
        let ns = cleaned as NSString
        guard let match = wakePattern.firstMatch(in: cleaned, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        let end = match.range.location + match.range.length
        return ns.substring(from: end)
    }

    private func handle(text: String) {
        var command: String
        if mode == .direct {
            command = text
        } else {
            guard let after = Self.textAfterWakeWord(in: text) else { return }
            if !woke {
                woke = true
                refreshTimer?.invalidate()
                onWake?()
                armGiveUp()
            }
            command = after
        }
        command = command.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        commandText = command

        silenceTimer?.invalidate()
        guard !command.isEmpty else { return }
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 1.3, repeats: false) { [weak self] _ in
            self?.finish()
        }
    }

    private func armGiveUp() {
        giveUpTimer?.invalidate()
        let gen = generation
        giveUpTimer = Timer.scheduledTimer(withTimeInterval: directTimeout, repeats: false) { [weak self] _ in
            guard let self, self.generation == gen else { return }
            if self.commandText.isEmpty {
                self.stop()
                self.onTimeout?()
            }
        }
    }

    private func finish() {
        let command = commandText
        stop()
        if command.isEmpty {
            onTimeout?()
        } else {
            onCommand?(command)
        }
    }

    private func recognitionEnded() {
        if woke {
            if !commandText.isEmpty {
                finish()
            } else {
                // Keep waiting for the command until the give-up timer fires.
                let timer = giveUpTimer
                giveUpTimer = nil
                let remaining = timer?.fireDate.timeIntervalSinceNow ?? 3
                timer?.invalidate()
                if remaining > 1 {
                    start(mode: .direct, timeout: remaining)
                } else {
                    stop()
                    onTimeout?()
                }
            }
        } else {
            let gen = generation
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self, self.generation == gen else { return }
                self.start(mode: .wake)
            }
        }
    }
}
