import ShepCore
import SwiftUI

struct OnboardingView: View {
    @ObservedObject var model: PermissionModel
    var onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 16) {
                // Shep's home, with Shep asleep in it. It wakes when you call it (menu, shortcut, or holding Right Option).
                HouseHeaderView(themeName: ShepThemes.find(UserDefaults.standard.string(forKey: "shep.theme")).name)
                    .frame(width: 96, height: 84)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Set up Shep")
                        .font(.title2.bold())
                        .accessibilityAddTraits(.isHeader)
                    Text("Shep sleeps in its doghouse until you call it, then sits on the title bar of the window in front. It needs these permissions to see where that is and, later, to listen and look.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // Said once here instead of on every approval card and every spoken question.
            Label(OnboardingCopy.asksFirst, systemImage: "hand.raised")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(OnboardingCopy.asksFirst)

            PermissionRow(
                title: "Accessibility",
                detail: "Find the front window so Shep can sit on its title bar. Required.",
                state: model.accessibilityState,
                request: model.requestAccessibility,
                openSettings: model.openAccessibilitySettings)
            PermissionRow(
                title: "Screen Recording",
                detail: "Look at the front window when you ask about it. Not needed to dock.",
                state: model.screenRecordingState,
                request: model.requestScreenRecording,
                openSettings: model.openScreenRecordingSettings)
            PermissionRow(
                title: "Microphone",
                detail: "Hear you when you talk to Shep. Not needed to dock. You can also turn on \u{201C}Hey Shep\u{201D} in Settings.",
                state: model.microphoneState,
                request: model.requestMicrophone,
                openSettings: model.openMicrophoneSettings)
            PermissionRow(
                title: "Speech Recognition",
                detail: "Turn what you say into text. Not needed to dock.",
                state: model.speechState,
                request: model.requestSpeech,
                openSettings: model.openSpeechSettings)

            HStack {
                Text("macOS may ask you to quit and reopen Shep after you grant Accessibility or Screen Recording.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(model.allGranted ? "Done" : "Later", action: onDone)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityLabel(model.allGranted ? "Done" : "Set up later")
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let state: PermissionState
    let request: () -> Void
    let openSettings: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: state.isGranted ? "checkmark.circle.fill" : "exclamationmark.circle")
                .font(.title2)
                .foregroundStyle(state.isGranted ? Color.green : Color.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(state.label)
                    .font(.caption)
                    .foregroundStyle(state.isGranted ? Color.green : Color.orange)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(title). \(state.label). \(detail)")
            Spacer()
            VStack(spacing: 6) {
                if state == .notDetermined {
                    Button(state.requestTitle, action: request)
                        .accessibilityLabel("\(state.requestTitle) \(title)")
                        .accessibilityHint("Asks macOS for \(title) permission")
                }
                Button("Open Settings", action: openSettings)
                    .accessibilityLabel("Open System Settings for \(title)")
            }
        }
    }
}
