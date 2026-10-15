import EquinoxCore
import SwiftUI

struct OnboardingView: View {
    @Bindable var model: AppModel
    var spectrum: SpectrumModel
    @Environment(\.dismiss) private var dismiss
    @State private var started = false

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "waveform.circle.fill").font(.system(size: 56)).foregroundStyle(Theme.accent)
            Text("Welcome to Equinox").font(.system(.largeTitle, design: .rounded).weight(.bold))
            Text("Equinox shapes everything your Mac plays. macOS will ask for **System Audio Recording** permission — that lets Equinox process your audio. Nothing is recorded or saved.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 420)

            if started {
                VStack(spacing: 10) {
                    Text("Play some music — these bars should move.").font(.callout)
                    MeterView(spectrum: spectrum).frame(width: 300)
                    Button("No movement? Open Privacy Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!)
                    }.buttonStyle(.link)
                }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction).controlSize(.large)
            } else {
                Button("Enable Equinox") { model.completeOnboarding(); started = true }
                    .keyboardShortcut(.defaultAction).controlSize(.large)
            }
        }
        .padding(36)
        .frame(width: 520)
        .preferredColorScheme(.dark)
    }
}
