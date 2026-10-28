import SwiftUI
import AVFoundation

// MARK: - Main window: title + orb only

struct MainView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        GeometryReader { geo in
            let orbSize = min(geo.size.width * 0.42, geo.size.height * 0.62, 460)
            VStack(spacing: 0) {
                TitleView()
                    .padding(.top, max(48, geo.size.height * 0.1))
                Spacer(minLength: 20)
                OrbView(stage: app.stage, voiceLevel: { [weak app] in app?.voiceLevel ?? 0 })
                    .frame(width: orbSize, height: orbSize)
                    .contentShape(Circle())
                    .onTapGesture { app.orbTapped() }
                    .help("Say “OLED” or click the orb")
                Spacer(minLength: 20)
                Spacer(minLength: 20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.background)
        .onAppear { app.startAssistant() }
    }
}

// MARK: - First launch setup

struct SetupView: View {
    @EnvironmentObject var app: AppState
    @State private var step = 1
    @State private var pollTimer: Timer?

    var body: some View {
        VStack(spacing: 26) {
            Spacer()
            OrbView(stage: .asleep)
                .frame(width: 160, height: 160)
            Text("SETUP · STEP \(step) OF 2")
                .font(.system(size: 14, weight: .semibold))
                .tracking(5)
                .foregroundColor(Color(hex: 0x5F93B3))

            VStack(spacing: 14) {
                Text(step == 1 ? "Let OLED hear you" : "Let OLED work your Mac")
                    .font(.system(size: 40, weight: .light))
                    .tracking(2)
                    .foregroundColor(Color(hex: 0x8FDCFF))
                    .shadow(color: Theme.accent.opacity(0.45), radius: 12)
                Text(step == 1
                     ? "OLED needs your microphone so it can hear its name and your commands. Your Mac will ask you to allow it."
                     : "To open apps, press keys and type for you, macOS needs you to switch on Accessibility access for OLED.")
                    .font(.system(size: 19))
                    .foregroundColor(Theme.soft)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 620)
            }

            if step == 2 {
                VStack(alignment: .leading, spacing: 8) {
                    Text("1.  Click the button below to open System Settings")
                    Text("2.  Find OLED in the Accessibility list")
                    Text("3.  Switch it on, then come back here")
                }
                .font(.system(size: 17))
                .foregroundColor(Color(hex: 0xBCDCEE))
                .padding(.vertical, 16)
                .padding(.horizontal, 26)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color(hex: 0x081E3C, opacity: 0.45)))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color(hex: 0x12385C), lineWidth: 1))
            }

            VStack(spacing: 10) {
                Button(action: primary) {
                    Text(step == 1 ? "ALLOW MICROPHONE" : "OPEN ACCESSIBILITY SETTINGS")
                        .font(.system(size: 16, weight: .semibold))
                        .tracking(2)
                        .foregroundColor(.white)
                        .padding(.horizontal, 34)
                        .frame(minHeight: 50)
                        .background(Capsule().fill(Theme.button))
                        .shadow(color: Theme.accent.opacity(0.5), radius: 14)
                }
                .buttonStyle(.plain)

                Button(step == 1 ? "Not now" : "Skip for now") { secondary() }
                    .buttonStyle(.plain)
                    .foregroundColor(Theme.muted)
                    .font(.system(size: 16))
                    .frame(minHeight: 40)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .onDisappear { pollTimer?.invalidate() }
    }

    private func primary() {
        if step == 1 {
            AppState.requestMicrophone { _ in goToAccessibility() }
        } else {
            AccessibilityPermission.request()
            pollTimer?.invalidate()
            pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { timer in
                if AccessibilityPermission.isGranted {
                    timer.invalidate()
                    NSApp.activate(ignoringOtherApps: true)
                    app.finishSetup()
                }
            }
        }
    }

    private func secondary() {
        if step == 1 { goToAccessibility() } else { app.finishSetup() }
    }

    private func goToAccessibility() {
        if AccessibilityPermission.isGranted {
            app.finishSetup()
        } else {
            withAnimation(.easeInOut(duration: 0.3)) { step = 2 }
        }
    }
}

// MARK: - Settings (OLED → Settings…, or Command-comma)

struct SettingsView: View {
    @EnvironmentObject var app: AppState
    @State private var apiKey = KeyStore.apiKey ?? ""
    @State private var saved = false
    @State private var robot = UserDefaults.standard.object(forKey: Speaker.robotKey) as? Double ?? 0.5
    @State private var voiceID = Speaker.selectedVoice?.identifier ?? ""
    @State private var homeTown = Weather.homeTown ?? ""
    private let voices = Speaker.britishVoices

    var body: some View {
        Form {
            Section("Status") {
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                    VStack(alignment: .leading, spacing: 6) {
                        statusRow("Microphone", ok: AppState.microphoneStatusOK)
                        statusRow("Speech Recognition", ok: AppState.speechStatusOK)
                        statusRow("Accessibility (keyboard & typing)", ok: AccessibilityPermission.isGranted)
                        Text("Listening: \(app.listenStatus)")
                        HStack(spacing: 8) {
                            Text("Mic level")
                            ProgressView(value: Double(min(1, app.listener.micLevel * 3)))
                        }
                        if !app.listener.lastHeard.isEmpty {
                            Text("Last heard: “\(app.listener.lastHeard)”").foregroundColor(.secondary)
                        }
                        if let issue = app.speaker.lastIssue {
                            Text("Voice: \(issue)").foregroundColor(.orange)
                        }
                    }
                    .font(.callout)
                }
                HStack {
                    Button("Microphone settings") { AppState.openPrivacy("Privacy_Microphone") }
                    Button("Speech Recognition settings") { AppState.openPrivacy("Privacy_SpeechRecognition") }
                }
                Button("Restart listening") { app.restartListening() }
            }

            Section("Voice") {
                Picker("British voice", selection: $voiceID) {
                    ForEach(voices, id: \.identifier) { v in
                        Text(label(for: v)).tag(v.identifier)
                    }
                }
                .onChange(of: voiceID) { id in UserDefaults.standard.set(id, forKey: Speaker.voiceKey) }

                HStack {
                    Text("Human")
                    Slider(value: $robot, in: 0...1)
                        .onChange(of: robot) { v in app.speaker.robotLevel = v }
                    Text("Robotic")
                }
                Button("Test voice") {
                    app.say("Hello. I'm OLED. Just say my name whenever you need me.", thenListen: false)
                }
                Text("Tip: for the most natural sound, download a Premium or Enhanced British male voice in System Settings → Accessibility → Spoken Content → System Voice → Manage Voices.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Conversation") {
                SecureField("Claude API key", text: $apiKey)
                HStack {
                    Button("Save key") {
                        KeyStore.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                        saved = true
                    }
                    if saved { Text("Saved").foregroundColor(.secondary) }
                }
                Text("Needed only for chatting. Opening apps, websites and keyboard commands work without it.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Weather") {
                TextField("Home town or city", text: $homeTown)
                    .onChange(of: homeTown) { t in Weather.homeTown = t }
                Text("Used when you ask “what's the weather?” without naming a place.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Weather") {
                TextField("Home town (e.g. London)", text: $homeTown)
                    .onChange(of: homeTown) { t in Weather.homeTown = t }
                Text("Used when you ask “what's the weather?” without naming a place.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Updates") {
                Text("Version \(Updater.currentBuild) · \(app.updateStatus)")
                Button("Check for updates") { app.checkForUpdates() }
                Text("OLED checks for updates by itself and installs them when it's idle. You can also say “OLED, update yourself”.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Permissions") {
                Button("Open Accessibility settings") { AccessibilityPermission.request() }
                Button("Run first-launch setup again") { app.setupDone = false }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 760)
    }

    private func statusRow(_ name: String, ok: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundColor(ok ? .green : .red)
            Text(name)
            Text(ok ? "Allowed" : "Not allowed").foregroundColor(.secondary)
        }
    }

    private func label(for v: AVSpeechSynthesisVoice) -> String {
        let quality: String
        switch v.quality {
        case .premium: quality = "Premium"
        case .enhanced: quality = "Enhanced"
        default: quality = "Standard"
        }
        let gender = v.gender == .male ? "Male" : (v.gender == .female ? "Female" : "")
        return "\(v.name) – \(gender) \(quality)"
    }
}
