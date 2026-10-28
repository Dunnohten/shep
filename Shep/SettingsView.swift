import AppKit
import ServiceManagement
import ShepCore
import SwiftUI

// Written for Shep.

/// The settings the window edits. Every change is saved at once (`SettingsStore`) and reported to the app with the old and
/// the new value, so the theme, the talk key, the shortcut and the rest take effect without a restart.
@MainActor
final class SettingsModel: ObservableObject {
    @Published var settings: ShepSettings {
        didSet {
            guard settings != oldValue else { return }
            // Only a valid address is stored; the field keeps what was typed so it can be corrected.
            if settings.glimmerURLIssue == nil || settings.glimmerURL == oldValue.glimmerURL { store.save(settings) }
            else { var kept = settings; kept.glimmerURL = oldValue.glimmerURL; store.save(kept) }
            onChange?(oldValue, settings)
        }
    }
    @Published var pingResult: GlimmerPing.Outcome?
    @Published var pinging = false
    /// Why "Hey Shep" is off when it could not be turned on (permission refused, on-device recognition missing).
    @Published var wakeWordNote: String?

    var onChange: ((ShepSettings, ShepSettings) -> Void)?
    private let store: SettingsStore

    init(store: SettingsStore = SettingsStore()) {
        self.store = store
        self.settings = store.load()
    }

    /// The environment the providers read, with the saved choices where the launch said nothing.
    func environment(_ base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        store.effectiveEnvironment(base)
    }

    func testConnection() {
        guard !pinging else { return }
        pinging = true
        pingResult = nil
        let text = settings.glimmerURL
        Task {
            let outcome = await GlimmerPing.run(urlText: text)
            pingResult = outcome
            pinging = false
        }
    }
}

/// Launch at login through SMAppService (macOS 13+; Shep targets 14).
@MainActor
enum LaunchAtLogin {
    static var status: SMAppService.Status { SMAppService.mainApp.status }
    static var isOn: Bool { status == .enabled }

    /// Registers or unregisters the app; throws what ServiceManagement throws.
    static func set(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }

    static var note: String? {
        switch status {
        case .requiresApproval: return "Allow Shep in System Settings > General > Login Items."
        case .notFound: return "macOS cannot find this build of Shep; run it from the Applications folder."
        default: return nil
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @State private var launchAtLogin = LaunchAtLogin.isOn
    @State private var launchError: String?

    private var environment: [String: String] { ProcessInfo.processInfo.environment }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    // The doghouse is the live preview: it takes the chosen colour straight away.
                    HouseHeaderView(themeName: model.settings.themeName)
                        .frame(width: 96, height: 84)
                    Picker("Colour", selection: $model.settings.themeName) {
                        ForEach(ShepThemes.all, id: \.name) { theme in
                            Text(theme.name).tag(theme.name)
                        }
                    }
                    .accessibilityHint("Changes Shep's colour at once")
                }
            } header: { Text("Look") }

            Section {
                Picker("Hold to talk", selection: $model.settings.pushToTalkKey) {
                    ForEach(PushToTalkKey.allCases, id: \.self) { key in Text(key.title).tag(key) }
                }
                Picker("Call Shep shortcut", selection: $model.settings.callShortcutID) {
                    ForEach(HotKeySpec.presets, id: \.id) { spec in Text(spec.name).tag(spec.id) }
                }
                Toggle("Listen for \u{201C}Hey Shep\u{201D}", isOn: $model.settings.wakeWord)
                    .accessibilityHint("Keeps the microphone open in the background so you can call Shep by voice. Recognition stays on this Mac. The menu bar icon shows a microphone while it listens")
                Text("Off by default. While it is on, Shep listens through the microphone whenever it is asleep in the doghouse. Nothing is recorded or sent anywhere.")
                    .font(.footnote).foregroundStyle(.secondary)
                if let note = model.wakeWordNote { Text(note).font(.footnote).foregroundStyle(.red) }
                Toggle("Speak replies", isOn: $model.settings.speakReplies)
                    .accessibilityHint("With VoiceOver running, VoiceOver announces replies and Shep stays quiet")
                Toggle("Bark when done", isOn: $model.settings.barkWhenDone)
                    .accessibilityHint("One short woof when a fix finishes. With VoiceOver running, it waits until VoiceOver has finished speaking")
                Slider(value: $model.settings.barkVolume, in: 0...1) { Text("Bark volume") }
                    .disabled(!model.settings.barkWhenDone)
                    .accessibilityLabel("Bark volume")
                    .accessibilityValue("\(Int((model.settings.barkVolume * 100).rounded())) percent")
            } header: { Text("Calling and voice") }

            Section {
                HStack {
                    TextField("Glimmer address", text: $model.settings.glimmerURL)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Glimmer server address")
                    Button(model.pinging ? "Testing…" : "Test", action: model.testConnection)
                        .disabled(model.pinging || model.settings.glimmerURLIssue != nil)
                        .accessibilityHint("Asks the server for its model list")
                }
                if let issue = model.settings.glimmerURLIssue {
                    Text(issue).font(.footnote).foregroundStyle(.red)
                } else if let result = model.pingResult {
                    Text(result.message).font(.footnote).foregroundStyle(result.ok ? Color.green : Color.red)
                        .accessibilityLabel(result.ok ? "Test passed. \(result.message)" : "Test failed. \(result.message)")
                }
                LabeledContent("Meta (cloud)") {
                    Text(ProviderAvailability.metaStatus(environment: environment))
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                }
                Toggle("Use SAM 3 as a second detector", isOn: $model.settings.sam3)
                Text(ProviderAvailability.sam3Note).font(.footnote).foregroundStyle(.secondary)
            } header: { Text("Providers") }

            Section {
                Toggle("Hide Shep from screen recordings", isOn: $model.settings.hideFromCapture)
                Toggle("Open Shep at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do { try LaunchAtLogin.set(on); launchError = LaunchAtLogin.note }
                        catch {
                            launchError = error.localizedDescription
                            launchAtLogin = LaunchAtLogin.isOn
                        }
                    }
                if let launchError { Text(launchError).font(.footnote).foregroundStyle(.red) }
                Text("Reduce Motion follows System Settings > Accessibility > Display. With it on, Shep fades out at the doghouse and in at the window instead of crossing the screen.")
                    .font(.footnote).foregroundStyle(.secondary)
            } header: { Text("General") }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }
}
