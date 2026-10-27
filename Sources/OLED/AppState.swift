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
        listener.onTimeout = { [weak self] in self?.goToSleep() }
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
        // Coming back from System Settings with permissions switched on: start listening straight away.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.started, self.stage == .asleep,
                  self.listenStatus.contains("off") || self.listenStatus.contains("couldn't") else { return }
            if Self.microphoneGranted { self.restartListening() }
        }
    }

    // MARK: Lifecycle

    func startAssistant() {
        guard !started else { return }
        started = true
        updater.startAutomaticChecks()
        ensurePermissions { [weak self] ok in
            guard let self else { return }
            if ok {
                self.say("OLED online. Say my name whenever you need me.", thenListen: false)
            } else {
                self.say("I can't hear you yet. Please allow the microphone and speech recognition for me in System Settings. I've opened it for you.", thenListen: false)
                Self.openPrivacy(Self.microphoneStatusOK ? "Privacy_SpeechRecognition" : "Privacy_Microphone")
            }
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
    func orbTapped() {
        speaker.stop()
        NSSound(named: "Tink")?.play()
        stage = .wake
        listener.start(mode: .direct, timeout: 7)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            if self?.stage == .wake { self?.stage = .listening }
        }
    }

    private func heardName() {
        NSSound(named: "Tink")?.play()
        stage = .wake
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            if self?.stage == .wake { self?.stage = .listening }
        }
    }

    /// Runs `work` once OLED isn't busy talking or listening.
    private func whenIdle(_ work: @escaping () -> Void) {
        if stage == .asleep && !speaker.isSpeaking {
            work()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.whenIdle(work) }
        }
    }

    func checkForUpdates() {
        updater.check(userAsked: true) { [weak self] text in
            self?.say(text, thenListen: false)
        }
    }

    private func run(_ command: String) {
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
