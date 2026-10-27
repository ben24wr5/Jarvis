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
    private let router = CommandRouter()
    private var started = false

    init() {
        listener.onWake = { [weak self] in self?.heardName() }
        listener.onCommand = { [weak self] text in self?.run(text) }
        listener.onTimeout = { [weak self] in self?.goToSleep() }
    }

    // MARK: Lifecycle

    func startAssistant() {
        guard !started else { return }
        started = true
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

    private func run(_ command: String) {
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
        AVCaptureDevice.requestAccess(for: .audio) { micOK in
            SFSpeechRecognizer.requestAuthorization { status in
                DispatchQueue.main.async { completion(micOK && status == .authorized) }
            }
        }
    }
}
