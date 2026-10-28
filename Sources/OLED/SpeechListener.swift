import Foundation
import AVFoundation
import Speech
import ObjCSupport

/// Listens to the microphone and turns speech into commands.
/// In `.wake` mode it waits for the name "OLED"; in `.direct` mode everything heard is the command.
///
/// The microphone itself stays open the whole time OLED is running; only the speech-recognition
/// *sessions* start and stop. Switching the mic off and on would flip AirPods between music mode and
/// phone-call mode every time OLED speaks, which interrupts listening. Keeping it open avoids that.
final class SpeechListener {
    enum Mode { case wake, direct }

    var onWake: (() -> Void)?
    var onCommand: ((String) -> Void)?
    /// Nothing usable was said. `heardSound` says whether the microphone picked up any sound at all.
    var onTimeout: ((_ heardSound: Bool) -> Void)?
    /// Listening keeps failing; the text is the reason Apple gave.
    var onFailure: ((String) -> Void)?
    /// Plain-English status for Settings → Status.
    var onStatus: ((String) -> Void)?

    /// Why listening can't work, in a form OLED can say out loud.
    enum Blocker { case microphone, speechRecognition, dictation, noMicrophone, silentMicrophone }
    var onBlocked: ((Blocker) -> Void)?

    /// The last thing the recogniser heard, and the current mic level (0–1), for Settings → Status.
    private(set) var lastHeard = ""
    private(set) var micLevel: Float = 0

    static var isAuthorized: Bool {
        SFSpeechRecognizer.authorizationStatus() == .authorized &&
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    // MARK: - Recognition state

    private let recognizers: [SFSpeechRecognizer] = [
        SFSpeechRecognizer(locale: Locale(identifier: "en-GB")),
        SFSpeechRecognizer(),
        SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    ].compactMap { $0 }
    private var useOnDevice = true

    /// British English if it's ready, otherwise the Mac's own language, otherwise US English.
    private func currentRecognizer() -> SFSpeechRecognizer? {
        recognizers.first(where: { $0.isAvailable })
    }

    private var task: SFSpeechRecognitionTask?
    private let requestLock = NSLock()
    private var _request: SFSpeechAudioBufferRecognitionRequest?
    private var request: SFSpeechAudioBufferRecognitionRequest? {
        get { requestLock.lock(); defer { requestLock.unlock() }; return _request }
        set { requestLock.lock(); _request = newValue; requestLock.unlock() }
    }

    private var mode: Mode = .wake
    private var woke = false
    private var commandText = ""
    private var generation = 0
    private var silenceTimer: Timer?
    private var giveUpTimer: Timer?
    private var refreshTimer: Timer?
    /// True while a listening session is meant to be running (it pauses while OLED speaks).
    private var isActive = false

    private var sessionStarted = Date()
    private var gotText = false
    private var fastFailures = 0
    private var sessionPeak: Float = 0
    private var heardSound: Bool { sessionPeak > 0.02 }

    /// How long to wait for a command after waking, or after a question.
    var directTimeout: TimeInterval = 7

    private func report(_ status: String) {
        if Thread.isMainThread { onStatus?(status) } else {
            DispatchQueue.main.async { [weak self] in self?.onStatus?(status) }
        }
    }

    // MARK: - The microphone (stays open)

    private var engine: AVAudioEngine?
    private var configObserver: NSObjectProtocol?
    private var deviceWatchInstalled = false
    private var rebuildPending = false
    private var recentRebuilds: [Date] = []
    private var noMicRetries = 0
    private var currentFormat: AVAudioFormat?

    /// Makes sure the microphone is running. Returns false if it can't be started right now.
    private func ensureAudio() -> Bool {
        watchDefaultMicrophone()
        if let engine, engine.isRunning { return true }
        if engine != nil { shutDownAudio() }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        // Optional: listen with the Mac's own microphone while AirPods are connected (off by default).
        if let device = AudioDevices.microphoneToUse, let unit = input.audioUnit {
            AudioDevices.use(device, on: unit)
        }
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else { return false }

        do {
            try OLEDSafe.run {
                input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                    self?.feed(buffer)
                }
            }
            try OLEDSafe.run { engine.prepare() }
            var startError: Error?
            try OLEDSafe.run { do { try engine.start() } catch { startError = error } }
            if let startError { throw startError }
        } catch {
            report("Microphone couldn't start: \(error.localizedDescription)")
            try? OLEDSafe.run {
                if engine.isRunning { engine.stop() }
                input.removeTap(onBus: 0)
            }
            return false
        }

        self.engine = engine
        currentFormat = format
        configObserver.map(NotificationCenter.default.removeObserver)
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in self?.audioConfigurationChanged() }
        return true
    }

    private func shutDownAudio() {
        guard let engine else { return }
        self.engine = nil
        currentFormat = nil
        configObserver.map(NotificationCenter.default.removeObserver)
        configObserver = nil
        try? OLEDSafe.run {
            if engine.isRunning { engine.stop() }
            engine.inputNode.removeTap(onBus: 0)
        }
        micLevel = 0
    }

    private func feed(_ buffer: AVAudioPCMBuffer) {
        request?.append(buffer)
        measureLevel(buffer)
    }

    /// Fires when the Mac switches microphone (AirPods in or out, a headset plugged in).
    private func watchDefaultMicrophone() {
        guard !deviceWatchInstalled else { return }
        deviceWatchInstalled = true
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main) { [weak self] _, _ in
            self?.rebuildAudio(reason: "Microphone changed – switching over")
        }
    }

    /// AirPods changing mode (music ↔ phone call) changes the audio format and stops the engine.
    /// Rebuild straight away on the same microphone and carry on — no long pause, no loop.
    private func audioConfigurationChanged() {
        rebuildAudio(reason: "Adjusting to the microphone")
    }

    private func rebuildAudio(reason: String) {
        silentSeconds = 0 // a switching microphone can be briefly silent; that's not a blocked mic
        guard !rebuildPending else { return }
        rebuildPending = true
        report(reason)
        // Safety net against any switching loop: if this keeps happening, slow right down.
        let now = Date()
        recentRebuilds = recentRebuilds.filter { now.timeIntervalSince($0) < 10 } + [now]
        let pause = recentRebuilds.count > 4 ? 3.0 : 0.35
        // A short pause lets macOS finish switching (AirPods take a moment), then rebuild once.
        DispatchQueue.main.asyncAfter(deadline: .now() + pause) { [weak self] in
            guard let self else { return }
            self.rebuildPending = false
            self.shutDownAudio()
            guard self.isActive else { _ = self.ensureAudio(); return }
            let remaining = self.giveUpTimer?.fireDate.timeIntervalSinceNow ?? self.directTimeout
            let mode = self.mode
            let wasWoke = self.woke
            self.start(mode: mode, timeout: max(3, remaining))
            if wasWoke && mode == .wake { self.woke = true; self.armGiveUp() }
        }
    }

    // MARK: - Mic level and blocked-mic detection

    /// A real microphone always picks up some faint noise. Seconds of perfect silence mean macOS is
    /// blocking the microphone for this copy of OLED, even if System Settings shows it switched on.
    private var silentSeconds: Double = 0
    private var everHeardSignal = false
    private var reportedSilence = false

    private func measureLevel(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        var peak: Float = 0
        for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(data[i])) }
        micLevel = peak
        if peak > sessionPeak { sessionPeak = peak }

        if peak > 0 {
            everHeardSignal = true
        } else if !everHeardSignal, !reportedSilence {
            silentSeconds += Double(buffer.frameLength) / max(1, buffer.format.sampleRate)
            if silentSeconds >= 6 {
                reportedSilence = true
                DispatchQueue.main.async { [weak self] in
                    self?.report("Microphone is giving pure silence – permission is blocked for this copy of OLED")
                    self?.onBlocked?(.silentMicrophone)
                }
            }
        }
    }

    /// Errors that happen in normal use (silence, restarts) and aren't worth showing.
    private static func isRoutine(_ error: NSError) -> Bool {
        if error.domain == "kAFAssistantErrorDomain", [203, 209, 216, 301, 1101, 1107, 1110].contains(error.code) { return true }
        let d = error.localizedDescription.lowercased()
        return d.contains("canceled") || d.contains("cancelled") || d.contains("no speech")
    }

    // MARK: - Listening sessions

    /// Starts listening. Returns false (and calls `onBlocked`) when something stops it working.
    @discardableResult
    func start(mode: Mode, timeout: TimeInterval = 7) -> Bool {
        stop()
        if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
            report("Microphone access is off")
            shutDownAudio()
            onBlocked?(.microphone)
            return false
        }
        if SFSpeechRecognizer.authorizationStatus() != .authorized {
            report("Speech Recognition access is off")
            shutDownAudio()
            onBlocked?(.speechRecognition)
            return false
        }
        guard let recognizer = currentRecognizer() else {
            report("Apple speech recognition isn't available right now – retrying")
            let gen = generation
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, self.generation == gen else { return }
                self.start(mode: mode, timeout: timeout)
            }
            return mode == .wake
        }

        self.mode = mode
        self.directTimeout = timeout
        isActive = true
        woke = (mode == .direct)
        commandText = ""
        sessionStarted = Date()
        gotText = false
        sessionPeak = 0
        let gen = generation

        guard ensureAudio() else {
            // Often just a microphone mid-switch (AirPods connecting): wait and try again quietly first.
            if noMicRetries < 5 {
                noMicRetries += 1
                report("Waiting for the microphone to connect…")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                    guard let self, self.generation == gen else { return }
                    self.start(mode: mode, timeout: timeout)
                }
                return true
            }
            noMicRetries = 0
            isActive = false
            report("No microphone found – check System Settings → Sound → Input")
            onBlocked?(.noMicrophone)
            return false
        }
        noMicRetries = 0

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // On-device first (works even with Siri/Dictation off); online if the on-device model fails.
        request.requiresOnDeviceRecognition = useOnDevice && recognizer.supportsOnDeviceRecognition
        if #available(macOS 13, *) { request.addsPunctuation = false }
        request.contextualStrings = ["OLED", "Oled", "O.L.E.D.", "O L E D", "Hey OLED", "Oh LED",
                                     "Firefox", "Safari", "open", "press", "type", "go to", "search for", "weather"]
        self.request = request

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let nsError = error as NSError?
            DispatchQueue.main.async {
                guard let self, self.generation == gen else { return }
                if let text, !text.isEmpty {
                    self.lastHeard = text
                    self.gotText = true
                    self.fastFailures = 0
                    self.handle(text: text)
                }
                if let nsError {
                    let message = nsError.localizedDescription.lowercased()
                    let detail = "\(nsError.localizedDescription) [\(nsError.domain) \(nsError.code)]"
                    if message.contains("disabled") || message.contains("siri") || message.contains("dictation") {
                        self.report("Speech recognition error: \(detail)")
                        self.useOnDevice = true
                        self.stop()
                        self.onBlocked?(.dictation)
                        return
                    }
                    // An error straight after starting, before hearing anything, means this way of
                    // recognising doesn't work on this Mac: switch between on-device and online.
                    let fast = !self.gotText && Date().timeIntervalSince(self.sessionStarted) < 2.5
                    if fast {
                        self.fastFailures += 1
                        self.useOnDevice.toggle()
                        self.report("Speech recognition error: \(detail) – trying another way")
                        if self.fastFailures >= 4 {
                            self.fastFailures = 0
                            self.stop()
                            self.onFailure?(nsError.localizedDescription)
                            return
                        }
                    } else if !Self.isRoutine(nsError) {
                        self.report("Speech recognition error: \(detail)")
                    }
                }
                if isFinal || nsError != nil { self.recognitionEnded() }
            }
        }
        report(mode == .wake ? "Listening for “OLED”" : "Listening for your command")

        if mode == .direct {
            armGiveUp()
        } else {
            // Recognition sessions have a time limit, so refresh quietly while waiting for the name.
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 45, repeats: false) { [weak self] _ in
                guard let self, self.generation == gen, !self.woke else { return }
                self.start(mode: .wake)
            }
        }
        return true
    }

    /// Closes the microphone completely, so the next session opens it fresh (e.g. after a settings change).
    func resetAudio() {
        stop()
        shutDownAudio()
    }

    /// Ends the current listening session. The microphone stays open so AirPods don't switch modes.
    func stop() {
        generation += 1
        isActive = false
        silenceTimer?.invalidate(); silenceTimer = nil
        giveUpTimer?.invalidate(); giveUpTimer = nil
        refreshTimer?.invalidate(); refreshTimer = nil
        task?.cancel(); task = nil
        request?.endAudio()
        request = nil
    }

    // MARK: - Handling speech

    /// Returns the text spoken after the name "OLED", or nil if the name wasn't said.
    static func textAfterWakeWord(in text: String) -> String? {
        WakeWord.textAfter(in: text)
    }

    /// While OLED is talking, this holds what it's saying, so it can tell its own voice from yours.
    /// You can still talk over it: say "OLED" and a command and it stops and does it.
    var echoText: String?

    /// True if the words after the name are just OLED hearing itself through the speakers.
    private func isEcho(_ after: String) -> Bool {
        guard let echo = echoText else { return false }
        let said = WakeWord.tokens(of: after).filter { !$0.isEmpty }
        guard !said.isEmpty else { return true } // only the name so far: wait for the command
        let echoTokens = WakeWord.tokens(of: echo)
        if (" " + echoTokens.joined(separator: " ") + " ").contains(" " + said.joined(separator: " ") + " ") { return true }
        let echoSet = Set(echoTokens)
        let overlap = Double(said.filter { echoSet.contains($0) }.count) / Double(said.count)
        return said.count >= 3 && overlap >= 0.8
    }

    private func handle(text: String) {
        var command: String
        if mode == .direct {
            command = text
        } else {
            guard let after = Self.textAfterWakeWord(in: text) else { return }
            if !woke, isEcho(after) { return }
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
                let heard = self.heardSound
                self.stop()
                self.onTimeout?(heard)
            }
        }
    }

    private func finish() {
        let command = commandText
        let heard = heardSound
        stop()
        if command.isEmpty {
            onTimeout?(heard)
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
                    let peak = sessionPeak
                    start(mode: .direct, timeout: remaining)
                    sessionPeak = max(sessionPeak, peak)
                } else {
                    let heard = heardSound
                    stop()
                    onTimeout?(heard)
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
