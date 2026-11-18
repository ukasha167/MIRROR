import SwiftUI
import MirrorCoreBridge

/// Floating HUD pill displaying extracted 2FA One-Time Passcodes with 60s expiry.
public struct OTPPillView: View {
    public let otp: OTPEvent
    public let onDismiss: () -> Void
    @State private var timeRemaining: TimeInterval

    public init(otp: OTPEvent, onDismiss: @escaping () -> Void) {
        self.otp = otp
        self.onDismiss = onDismiss
        self._timeRemaining = State(initialValue: otp.remainingSeconds())
    }

    public var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "key.fill")
                .foregroundStyle(MirrorTokens.accent)
                .font(.headline)

            VStack(alignment: .leading, spacing: 2) {
                Text(otp.service != nil ? "\(otp.service!) Code" : "Verification Code")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text(otp.code)
                    .font(.system(.title3, design: .monospaced).monospacedDigit())
                    .fontWeight(.bold)
            }

            Spacer()

            Button(action: copyCode) {
                Text("Copy")
                    .fontWeight(.semibold)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .tint(MirrorTokens.accent)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(MirrorTokens.cardSurface, in: RoundedRectangle(cornerRadius: MirrorTokens.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: MirrorTokens.cardRadius, style: .continuous)
                .stroke(MirrorTokens.hairlineBorder, lineWidth: 1)
        )
        .frame(maxWidth: .infinity)
        .onAppear {
            startTimer()
        }
    }

    private func copyCode() {
        let extractor = OTPExtractor()
        extractor.copyToPasteboard(event: otp)
        onDismiss()
    }

    private func startTimer() {
        Task { @MainActor in
            while true {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                let remaining = otp.remainingSeconds()
                timeRemaining = remaining
                if remaining <= 0 {
                    onDismiss()
                    break
                }
            }
        }
    }
}
