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
                    .help("Say “OLED” or click the orb. Right-click for Settings.")
                    .contextMenu {
                        OpenSettingsButton()
                        Button("Repair permissions") { AppState.resetPermissionsAndRelaunch() }
                    }
                Spacer(minLength: 20)
                CommandField()
                    .frame(maxWidth: 640)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 32)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay(alignment: .topTrailing) {
            SettingsGearButton()
                .padding(.top, 18)
                .padding(.trailing, 22)
        }
        .background(Theme.background)
        .onAppear { app.startAssistant() }
    }
}

/// The text box at the bottom: type anything you'd say, press Return, and OLED says its answer and does it.
struct CommandField: View {
    @EnvironmentObject var app: AppState
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "keyboard")
                .font(.system(size: 15))
                .foregroundColor(Theme.muted)
                .accessibilityHidden(true)
            TextField("", text: $text, prompt: Text("Type anything you'd say to OLED, then press Return")
                .foregroundColor(Theme.muted))
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .foregroundColor(Theme.title)
                .focused($focused)
                .onSubmit(send)
                .accessibilityLabel("Type a command or question")
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 22))
                    .foregroundColor(text.trimmingCharacters(in: .whitespaces).isEmpty ? Theme.muted.opacity(0.5) : Theme.accent)
            }
            .buttonStyle(.plain)
            .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            .accessibilityLabel("Send")
        }
        .padding(.horizontal, 16)
        .frame(height: 46)
        .background(RoundedRectangle(cornerRadius: 23).fill(Theme.fieldFill))
        .overlay(RoundedRectangle(cornerRadius: 23)
            .stroke(focused ? Theme.accent.opacity(0.9) : Theme.fieldBorder, lineWidth: 1))
        .shadow(color: focused ? Theme.accent.opacity(0.35) : .clear, radius: 10)
    }

    private func send() {
        let command = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }
        text = ""
        app.typed(command)
    }
}

/// Opens OLED's Settings window (works on macOS 13 and later).
struct OpenSettingsButton: View {
    var body: some View {
        if #available(macOS 14, *) {
            SettingsLink { Text("Settings…") }
        } else {
            Button("Settings…") {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
        }
    }
}

/// A standard macOS "Settings" button in the top-right corner.
struct SettingsGearButton: View {
    private var label: some View {
        Image(systemName: "gearshape")
            .font(.system(size: 15, weight: .medium))
            .frame(width: 22, height: 26)
            .accessibilityLabel("Settings")
    }

    var body: some View {
        Group {
            if #available(macOS 14, *) {
                SettingsLink { label }
            } else {
                Button { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) } label: { label }
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .help("Open OLED's Settings")
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
                .foregroundColor(Theme.muted)

            VStack(spacing: 14) {
                Text(step == 1 ? "Let OLED hear you" : "Let OLED work your Mac")
                    .font(.system(size: 40, weight: .light))
                    .tracking(2)
                    .foregroundColor(Theme.title)
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
                .foregroundColor(Theme.soft)
                .padding(.vertical, 16)
                .padding(.horizontal, 26)
                .background(RoundedRectangle(cornerRadius: 14).fill(Theme.fieldFill))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.fieldBorder, lineWidth: 1))
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
    @ObservedObject private var theme = ThemeStore.shared
    @State private var robot = UserDefaults.standard.object(forKey: Speaker.robotKey) as? Double ?? 0.65
    @State private var voiceID = Speaker.selectedVoice?.identifier ?? ""
    @State private var homeTown = Weather.homeTown ?? ""
    @State private var preferBuiltInMic = AudioDevices.preferBuiltInWithBluetooth
    @State private var openAtLogin = LaunchAtLogin.wanted
    private let voices = Speaker.britishVoices

    var body: some View {
        Form {
            Section("Status") {
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                    VStack(alignment: .leading, spacing: 6) {
                        statusRow("Microphone", ok: AppState.microphoneStatusOK)
                        statusRow("Speech Recognition", ok: AppState.speechStatusOK)
                        statusRow("Accessibility (keyboard & typing)", ok: AccessibilityPermission.isGranted)
                        statusRow("Apple Intelligence (answers any question)", ok: ChatClient.appleAIAvailable)
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
                HStack {
                    Button("Restart listening") { app.restartListening() }
                    Button("Repair permissions") { AppState.resetPermissionsAndRelaunch() }
                }
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
                Toggle("With AirPods in, listen through the Mac's microphone instead", isOn: $preferBuiltInMic)
                    .onChange(of: preferBuiltInMic) { on in
                        AudioDevices.preferBuiltInWithBluetooth = on
                        app.restartListening()
                    }
                Text("Off: OLED listens through your AirPods. On: OLED uses the Mac's microphone and your AirPods keep their best sound quality.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Button("Test voice") {
                    app.say("Hello. I'm OLED. Just say my name whenever you need me.", thenListen: false)
                }
                Text("Tip: for the most natural sound, download a Premium or Enhanced British male voice in System Settings → Accessibility → Spoken Content → System Voice → Manage Voices.")
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

            Section("Startup") {
                Toggle("Open OLED when my Mac starts", isOn: $openAtLogin)
                    .onChange(of: openAtLogin) { on in LaunchAtLogin.wanted = on }
            }

            Section("Themes") {
                ForEach(Palette.all) { palette in
                    Button {
                        theme.current = palette
                    } label: {
                        HStack(spacing: 12) {
                            HStack(spacing: -6) {
                                ForEach([palette.primary, palette.secondary, palette.tertiary, palette.light], id: \.self) { hex in
                                    Circle()
                                        .fill(Color(hex: hex))
                                        .frame(width: 18, height: 18)
                                        .overlay(Circle().stroke(Color.black.opacity(0.35), lineWidth: 1))
                                }
                            }
                            .padding(6)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color(hex: palette.bgCenter)))
                            .accessibilityHidden(true)
                            Text(palette.name)
                                .foregroundColor(.primary)
                            Spacer()
                            if theme.current.id == palette.id {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(Color(hex: palette.primary))
                                    .accessibilityLabel("Selected")
                            }
                        }
                        .contentShape(Rectangle())
                        .frame(minHeight: 32)
                    }
                    .buttonStyle(.plain)
                }
                Text("Version \(Updater.currentBuild) · updates install automatically")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Permissions") {
                Button("Open Accessibility settings") { AccessibilityPermission.request() }
                Button("Run first-launch setup again") { app.setupDone = false }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .tint(Theme.accent)
        .frame(width: 560, height: 760)
        .id(theme.current.id) // re-colour the Settings window straight away too
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
