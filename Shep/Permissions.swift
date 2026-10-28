import AVFoundation
import AppKit
import ApplicationServices
import CoreGraphics
import ShepCore
import Speech

/// Live status of the permissions Shep needs, plus the actions that request them or open the right System Settings pane.
@MainActor
final class PermissionModel: ObservableObject {
    @Published private(set) var accessibility = false
    @Published private(set) var screenRecording = false
    @Published private(set) var microphone: AVAuthorizationStatus = .notDetermined
    @Published private(set) var speech: SFSpeechRecognizerAuthorizationStatus = .notDetermined

    private var timer: Timer?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    var microphoneGranted: Bool { microphone == .authorized }
    var speechGranted: Bool { speech == .authorized }
    var allGranted: Bool { accessibility && screenRecording && microphoneGranted && speechGranted }

    // Words for the setup window and VoiceOver. Accessibility and Screen Recording have no "denied": macOS only says trusted or not.
    var accessibilityState: PermissionState { accessibility ? .granted : .notDetermined }
    var screenRecordingState: PermissionState { screenRecording ? .granted : .notDetermined }
    var microphoneState: PermissionState {
        switch microphone {
        case .authorized: return .granted
        case .denied: return .denied
        case .restricted: return .restricted
        default: return .notDetermined
        }
    }
    var speechState: PermissionState {
        switch speech {
        case .authorized: return .granted
        case .denied: return .denied
        case .restricted: return .restricted
        default: return .notDetermined
        }
    }

    func refresh() {
        let ax = AXIsProcessTrusted()
        let sr = CGPreflightScreenCaptureAccess()
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        if ax != accessibility { accessibility = ax }
        if sr != screenRecording { screenRecording = sr }
        if mic != microphone { microphone = mic }
        let sp = SFSpeechRecognizer.authorizationStatus()
        if sp != speech { speech = sp }
    }

    // MARK: requests

    func requestAccessibility() {
        // "AXTrustedCheckOptionPrompt" is the string value of kAXTrustedCheckOptionPrompt.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        openAccessibilitySettings()
    }

    func requestScreenRecording() {
        _ = CGRequestScreenCaptureAccess()
        refresh()
    }

    func requestMicrophone() {
        if microphone == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        } else {
            openMicrophoneSettings()
        }
    }

    func requestSpeech() {
        if speech == .notDetermined {
            SFSpeechRecognizer.requestAuthorization { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        } else {
            openSpeechSettings()
        }
    }

    // MARK: System Settings panes

    func openAccessibilitySettings() { Self.open("Privacy_Accessibility") }
    func openScreenRecordingSettings() { Self.open("Privacy_ScreenCapture") }
    func openMicrophoneSettings() { Self.open("Privacy_Microphone") }
    func openSpeechSettings() { Self.open("Privacy_SpeechRecognition") }

    private static func open(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}
