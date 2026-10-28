import SwiftUI
import AppKit
import AVFoundation
import Speech

final class AppState: ObservableObject {
    enum Stage { case asleep, wake, listening, working, speaking }

    @Published var stage: Stage = .asleep
    @Published var setupDone: Bool = UserDefaults.standard.bool(forKey: "setupDone") {
        didSet { UserDefaults.standard.set(setupDone, forKey: "setupDone") }
    }

    let listener = SpeechListener()
    let speaker = Speaker()
    let updater = Updater()
    @Published var updateStatus = "Up to date"
    private let router = CommandRouter()
    private var started = false

    /// Plain-English status shown in Settings → Status.
    @Published var listenStatus = "Starting…"

    init() {
        listener.onWake = { [weak self] in self?.heardName() }
        listener.onCommand = { [weak self] text in self?.run(text) }
        listener.onTimeout = { [weak self] heardSound in self?.nothingUsableHeard(heardSound) }
        listener.onFailure = { [weak self] reason in self?.listeningFailed(reason) }
        listener.onStatus = { [weak self] status in self?.listenStatus = status }
        updater.onStatus = { [weak self] status in self?.updateStatus = status }
        updater.willInstall = { [weak self] _, proceed in
            self?.whenIdle {
                guard let self else { proceed(); return }
                self.listener.stop()
                self.stage = .working
                self.speaker.speak("I've got an update. I'll be right back.") { proceed() }
            }
        }
        listener.onBlocked = { [weak self] blocker in self?.handleBlocked(blocker) }
        // Coming back from System Settings with permissions switched on: start listening straight away.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.started, self.lastBlocked != nil, self.stage == .asleep else { return }
            self.lastBlocked = nil
            self.restartListening()
        }
    }

    // MARK: When listening can't work, say why (once) and open the right settings

    private var lastBlocked: SpeechListener.Blocker?

    private func handleBlocked(_ blocker: SpeechListener.Blocker) {
        // Permission not asked yet: ask now, then try again.
        if (blocker == .microphone && AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined) ||
           (blocker == .speechRecognition && SFSpeechRecognizer.authorizationStatus() == .notDetermined) {
            Self.requestMicrophone { [weak self] _ in self?.restartListening() }
            return
        }
        if lastBlocked == blocker {
            stage = .asleep // already told the user; wait until they come back from Settings
            return
        }
        lastBlocked = blocker
        let message: String
        switch blocker {
        case .microphone:
            message = "I can't use the microphone. Please switch me on under Microphone in System Settings. I've opened it for you."
            Self.openPrivacy("Privacy_Microphone")
        case .speechRecognition:
            message = "I'm not allowed to use speech recognition. Please switch me on under Speech Recognition in System Settings. I've opened it for you."
            Self.openPrivacy("Privacy_SpeechRecognition")
        case .dictation:
            message = "Speech recognition is switched off on this Mac. Please turn on Dictation in System Settings, under Keyboard. I've opened it for you."
            if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
                NSWorkspace.shared.open(url)
            }
        case .noMicrophone:
            message = "I can't find a microphone. Please check the sound input in System Settings."
        case .silentMicrophone:
            let key = "permissionResetBuild"
            if UserDefaults.standard.integer(forKey: key) != Updater.currentBuild {
                // First time for this version: repair the permissions ourselves and reopen.
                UserDefaults.standard.set(Updater.currentBuild, forKey: key)
                listener.stop()
                stage = .speaking
                speaker.speak("My microphone permission got stuck after the update. I'm fixing it now. When your Mac asks, click Allow.") {
                    Self.resetPermissionsAndRelaunch()
                }
                return
            }
            message = "My microphone is still blocked. In System Settings, under Privacy and Security, then Microphone, switch me off and on again. I've opened it for you."
            Self.openPrivacy("Privacy_Microphone")
        }
        listener.stop()
        stage = .speaking
        speaker.speak(message) { [weak self] in self?.stage = .asleep }
    }

    // MARK: Lifecycle

    func startAssistant() {
        guard !started else { return }
        started = true
        updater.startAutomaticChecks()
        ensurePermissions { [weak self] _ in
            // Speak first (proves the voice works), then start listening; any problem is explained out loud.
            self?.say("OLED online. Say my name whenever you need me.", thenListen: false)
        }
    }

    /// Asks for any permission not decided yet; reports whether listening can work.
    func ensurePermissions(_ done: @escaping (Bool) -> Void) {
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        let speech = SFSpeechRecognizer.authorizationStatus()
        if mic == .notDetermined || speech == .notDetermined {
            Self.requestMicrophone { ok in done(ok) }
        } else {
            done(Self.microphoneGranted)
        }
    }

    /// Clears OLED's stale Microphone, Speech Recognition and Accessibility entries, then reopens,
    /// so macOS asks again and grants them to this version of the app.
    static func resetPermissionsAndRelaunch() {
        let id = Bundle.main.bundleIdentifier ?? "com.ben24wr5.oled"
        for service in ["Microphone", "SpeechRecognition", "Accessibility"] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            p.arguments = ["reset", service, id]
            try? p.run()
            p.waitUntilExit()
        }
        UserDefaults.standard.set(false, forKey: "setupDone") // show the two setup steps again
        let path = Bundle.main.bundlePath
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "sleep 1; /usr/bin/open \"\(path)\""]
        try? relaunch.run()
        NSApp.terminate(nil)
    }

    static var microphoneStatusOK: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }
    static var speechStatusOK: Bool { SFSpeechRecognizer.authorizationStatus() == .authorized }

    static func openPrivacy(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Restarts listening (e.g. after permissions were switched on in System Settings).
    func restartListening() {
        speaker.stop()
        goToSleep()
    }

    func finishSetup() {
        setupDone = true
        startAssistant()
    }

    // MARK: Interaction

    /// Clicking the orb works just like saying "OLED".
    /// Loudness for the orb: OLED's own voice while speaking, otherwise your voice from the microphone.
    var voiceLevel: Double {
        if stage == .speaking { return speaker.voiceLevel }
        // Microphone peaks are small numbers; scale so normal talking fills the range.
        let mic = Double(listener.micLevel)
        return min(1, max(0, (mic - 0.01) * 6))
    }

    /// True while OLED is waiting for something the user started (a click, its name, or a question it asked).
    private var expectingSpeech = false
    private var failureAnnounced = false

    private func nothingUsableHeard(_ heardSound: Bool) {
        guard expectingSpeech else { goToSleep(); return }
        expectingSpeech = false
        if heardSound {
            say("Sorry, I didn't catch that.", thenListen: false)
        } else {
            say("I can't hear anything from the microphone. Please check the sound input in System Settings.", thenListen: false)
        }
    }

    private func listeningFailed(_ reason: String) {
        expectingSpeech = false
        if failureAnnounced && stage == .asleep {
            // Already explained; try again quietly in a little while.
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
                if self?.stage == .asleep { self?.listener.start(mode: .wake) }
            }
            return
        }
        failureAnnounced = true
        listener.stop()
        stage = .speaking
        let message = "I couldn't start listening. Apple's speech recognition said: \(reason). Please turn on Dictation in System Settings, under Keyboard, then try again. I've opened it for you."
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
        speaker.speak(message) { [weak self] in
            self?.stage = .asleep
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
                if self?.stage == .asleep { self?.listener.start(mode: .wake) }
            }
        }
    }

    func orbTapped() {
        speaker.stop()
        expectingSpeech = true
        failureAnnounced = false
        lastBlocked = nil // a click always gets an answer, even if a problem was already explained
        NSSound(named: "Tink")?.play()
        stage = .wake
        listener.start(mode: .direct, timeout: 7)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            if self?.stage == .wake { self?.stage = .listening }
        }
    }

    private func heardName() {
        expectingSpeech = true
        NSSound(named: "Tink")?.play()
        stage = .wake
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            if self?.stage == .wake { self?.stage = .listening }
        }
    }

    /// Runs `work` once OLED isn't busy talking or listening.
    private func whenIdle(_ work: @escaping () -> Void, waited: TimeInterval = 0) {
        // Never wait more than a minute, so an update can't get stuck behind a busy state.
        if (stage == .asleep && !speaker.isSpeaking) || waited >= 60 {
            work()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.whenIdle(work, waited: waited + 5) }
        }
    }

    func checkForUpdates() {
        updater.check(userAsked: true) { [weak self] text in
            self?.say(text, thenListen: false)
        }
    }

    private func run(_ command: String) {
        expectingSpeech = false
        let lower = command.lowercased()
        if lower.contains("update") && (lower.contains("check") || lower.contains("yourself") || lower.contains("install")
                                        || lower.trimmingCharacters(in: .whitespaces) == "update") {
            stage = .working
            checkForUpdates()
            return
        }
        stage = .working
        router.handle(command) { [weak self] reply in
            self?.say(reply.text, thenListen: reply.expectsAnswer)
        }
    }

    func say(_ text: String, thenListen: Bool) {
        listener.stop()
        stage = .speaking
        speaker.speak(text) { [weak self] in
            guard let self else { return }
            if thenListen {
                self.stage = .listening
                self.listener.start(mode: .direct, timeout: 6)
            } else {
                self.goToSleep()
            }
        }
    }

    private func goToSleep() {
        stage = .asleep
        listener.start(mode: .wake)
    }

    // MARK: Permissions

    static var microphoneGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized &&
        SFSpeechRecognizer.authorizationStatus() == .authorized
    }

    static func requestMicrophone(completion: @escaping (Bool) -> Void) {
        // Ask one at a time on the main thread so both macOS prompts appear reliably.
        DispatchQueue.main.async {
            AVCaptureDevice.requestAccess(for: .audio) { micOK in
                DispatchQueue.main.async {
                    SFSpeechRecognizer.requestAuthorization { status in
                        DispatchQueue.main.async { completion(micOK && status == .authorized) }
                    }
                }
            }
        }
    }
}
