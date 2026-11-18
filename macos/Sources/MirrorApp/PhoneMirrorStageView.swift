import SwiftUI
import MirrorRenderer

/// Embedded interactive Android mirror stage wrapped in a dimensionally fitted phone chassis.
public struct PhoneMirrorStageView: View {
    @ObservedObject var agent: MirrorAppAgent

    public init(agent: MirrorAppAgent) {
        self.agent = agent
    }

    public var body: some View {
        VStack(spacing: MirrorTokens.space3) {
            telemetryHeader
            GeometryReader { proxy in
                let metrics = PhoneChassisMetrics.fit(
                    videoSize: agent.effectiveVideoDimensions,
                    in: proxy.size
                )
                chassisView(metrics: metrics)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
            if agent.isConnected {
                controlDock
            }
        }
        .padding(MirrorTokens.space4)
        .background(MirrorTokens.stageBg)
    }

    private var telemetryHeader: some View {
        HStack(spacing: MirrorTokens.space2) {
            Circle()
                .fill(agent.isMirroring ? MirrorTokens.positive : (agent.isConnected ? MirrorTokens.accent : MirrorTokens.warning.opacity(0.6)))
                .frame(width: 8, height: 8)
            Text(agent.isMirroring ? "Live Screen Mirror" : (agent.isConnected ? "Mirror Stage Ready" : "Standby"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)

            Spacer()

            let dims = agent.effectiveVideoDimensions
            Text("\(Int(dims.width))×\(Int(dims.height))\(agent.isMirroring ? " · \(agent.activeCodecLabel)" : "")")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(MirrorTokens.cardSurface, in: Capsule())
                .overlay(Capsule().stroke(MirrorTokens.hairlineBorder, lineWidth: 1))
        }
    }

    @ViewBuilder
    private func chassisView(metrics: PhoneChassisMetrics) -> some View {
        ZStack {
            // Side hardware buttons (power + volume rocker)
            hardwareButtons(metrics: metrics)

            // Outer metal-graphite frame
            RoundedRectangle(cornerRadius: metrics.outerCornerRadius, style: .continuous)
                .fill(MirrorTokens.chassisBody)
                .frame(width: metrics.chassisSize.width, height: metrics.chassisSize.height)
                .overlay(
                    RoundedRectangle(cornerRadius: metrics.outerCornerRadius, style: .continuous)
                        .stroke(MirrorTokens.chassisRim, lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.28), radius: 20, y: 10)

            // Display surface fitted 1:1 to stream dimensions
            ZStack(alignment: metrics.isLandscape ? .leading : .top) {
                screenContent(metrics: metrics)
                    .frame(width: metrics.screenSize.width, height: metrics.screenSize.height)
                    .clipShape(RoundedRectangle(cornerRadius: metrics.innerCornerRadius, style: .continuous))

                // Centered punch-hole camera cutout
                cameraCutout(metrics: metrics)
            }
            .frame(width: metrics.screenSize.width, height: metrics.screenSize.height)
        }
    }

    @ViewBuilder
    private func screenContent(metrics: PhoneChassisMetrics) -> some View {
        if agent.isMirroring {
            let client = agent.streamClient
            MirrorSurfaceView(
                frameSink: agent.frameSink,
                videoSize: agent.effectiveVideoDimensions,
                onControl: { packet in client.sendControl(packet) }
            )
            .overlay(alignment: .bottom) {
                if agent.isPhoneScreenDimmed {
                    Text("Phone OLED turned off · Mirror active")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(.black.opacity(0.65), in: Capsule())
                        .padding(.bottom, 12)
                }
            }
        } else {
            standbyScreen
        }
    }

    private var standbyScreen: some View {
        ZStack {
            Color(red: 0.05, green: 0.055, blue: 0.068)
            VStack(spacing: MirrorTokens.space4) {
                Image(systemName: agent.isConnected ? "iphone.radiowaves.left.and.right" : "iphone")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(agent.isConnected ? MirrorTokens.accent : .white.opacity(0.35))

                VStack(spacing: 6) {
                    Text(standbyHeadline)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                    Text(standbyDetail)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.62))
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 20)

                if let error = agent.mirrorErrorMessage {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(MirrorTokens.danger)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 18)
                }

                if agent.isConnected {
                    Button {
                        agent.toggleMirroring()
                    } label: {
                        Label("Start Screen Mirror", systemImage: "play.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 9)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(MirrorTokens.accent)
                }
            }
        }
    }

    private var standbyHeadline: String {
        if agent.isConnected {
            return agent.deviceName
        }
        if let peer = agent.discoveredPeers.first {
            return "Ready to pair: \(peer.name)"
        }
        if let usb = agent.usbAttached {
            return "USB attached: \(usb.model)"
        }
        return "No active phone session"
    }

    private var standbyDetail: String {
        if agent.isConnected {
            if agent.canMirrorViaAdb {
                return "Mirror right inside this window with mouse, keyboard, and drag-and-drop."
            }
            return "Plug in USB (or connect ADB Wi-Fi) to stream video."
        }
        if let peer = agent.discoveredPeers.first {
            return "Scan the QR code or exchange the 6-digit code on the left to connect with \(peer.name)."
        }
        if agent.usbAttached != nil {
            return "Open the Mirror Continuity app on your phone to complete connection."
        }
        return "Pair your Android phone on the left to mirror its display here."
    }

    private func cameraCutout(metrics: PhoneChassisMetrics) -> some View {
        Circle()
            .fill(Color.black)
            .frame(width: metrics.cameraDiameter, height: metrics.cameraDiameter)
            .overlay(
                Circle()
                    .stroke(Color.white.opacity(0.14), lineWidth: 0.75)
            )
            .overlay(
                Circle()
                    .fill(Color(red: 0.08, green: 0.14, blue: 0.24))
                    .frame(width: metrics.cameraDiameter * 0.42, height: metrics.cameraDiameter * 0.42)
            )
            .padding(.top, metrics.isLandscape ? 0 : metrics.cameraTopOrSideInset)
            .padding(.leading, metrics.isLandscape ? metrics.cameraTopOrSideInset : 0)
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private func hardwareButtons(metrics: PhoneChassisMetrics) -> some View {
        if metrics.isLandscape {
            // Top edge buttons in landscape
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 1.5).fill(MirrorTokens.chassisBody).frame(width: 44, height: 3)
                RoundedRectangle(cornerRadius: 1.5).fill(MirrorTokens.chassisBody).frame(width: 24, height: 3)
            }
            .offset(x: -metrics.chassisSize.width * 0.15, y: -(metrics.chassisSize.height / 2) - 1.5)
        } else {
            // Right edge volume rocker + power button in portrait
            VStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 1.5).fill(MirrorTokens.chassisBody).frame(width: 3, height: 44)
                RoundedRectangle(cornerRadius: 1.5).fill(MirrorTokens.chassisBody).frame(width: 3, height: 24)
            }
            .offset(x: (metrics.chassisSize.width / 2) + 1.5, y: -metrics.chassisSize.height * 0.15)
        }
    }

    private var controlDock: some View {
        HStack(spacing: MirrorTokens.space2) {
            dockButton(icon: "chevron.left", title: "Back") {
                agent.sendNavigationKey(.back)
            }
            dockButton(icon: "circle", title: "Home") {
                agent.sendNavigationKey(.home)
            }
            dockButton(icon: "square.on.square", title: "Recents") {
                agent.sendNavigationKey(.appSwitch)
            }
            Divider().frame(height: 18)
            dockButton(icon: "rotate.right", title: "Rotate") {
                agent.sendRotateDevice()
            }
            dockButton(
                icon: agent.isPhoneScreenDimmed ? "sun.max.fill" : "moon.fill",
                title: agent.isPhoneScreenDimmed ? "Wake OLED" : "OLED Off",
                isActive: agent.isPhoneScreenDimmed
            ) {
                agent.togglePhoneDisplayPower()
            }
            Spacer()
            Button {
                agent.toggleMirroring()
            } label: {
                Label(agent.isMirroring ? "Stop" : "Mirror", systemImage: agent.isMirroring ? "stop.fill" : "play.fill")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(agent.isMirroring ? MirrorTokens.danger : MirrorTokens.accent)
            .controlSize(.small)
        }
        .padding(.horizontal, MirrorTokens.space3)
        .padding(.vertical, MirrorTokens.space2)
        .background(MirrorTokens.cardSurface, in: RoundedRectangle(cornerRadius: MirrorTokens.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: MirrorTokens.cardRadius, style: .continuous)
                .stroke(MirrorTokens.hairlineBorder, lineWidth: 1)
        )
    }

    private func dockButton(icon: String, title: String, isActive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 28, height: 24)
                .foregroundStyle(isActive ? MirrorTokens.accent : .primary)
        }
        .buttonStyle(.plain)
        .help(title)
        .background(isActive ? MirrorTokens.accent.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .disabled(!agent.isMirroring)
    }
}
