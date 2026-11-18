import SwiftUI

/// Split-studio Continuity workspace pairing left-hand controls with an inline phone mirror stage on the right.
public struct DashboardView: View {
    @ObservedObject public var agent: MirrorAppAgent
    @State private var showPairSheetDisclosure = false

    public init(agent: MirrorAppAgent) {
        self.agent = agent
    }

    public var body: some View {
        HStack(spacing: 0) {
            leftSidebar
                .frame(minWidth: 370, idealWidth: 400, maxWidth: 440)
                .background(MirrorTokens.windowBg)

            Divider()

            PhoneMirrorStageView(agent: agent)
                .frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 840, minHeight: 620)
    }

    private var leftSidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MirrorTokens.space4) {
                connectionHeaderCard

                if let otp = agent.activeOTP {
                    OTPPillView(otp: otp) {
                        agent.dismissOTP()
                    }
                }

                if !agent.isConnected {
                    PairingPanelView(agent: agent)
                }

                continuityActionStrip
                DropShelfView(agent: agent)
                NowPlayingWidget(state: agent.mediaState)
                AppLauncherGrid(agent: agent)

                if agent.isConnected {
                    DisclosureGroup("Pair another device", isExpanded: $showPairSheetDisclosure) {
                        PairingPanelView(agent: agent)
                            .padding(.top, MirrorTokens.space2)
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                }
            }
            .padding(MirrorTokens.space4)
        }
    }

    private var connectionHeaderCard: some View {
        HStack(spacing: MirrorTokens.space3) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: agent.isConnected ? "iphone.radiowaves.left.and.right" : "iphone")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(agent.isConnected ? MirrorTokens.accent : .secondary)
                    .frame(width: 40, height: 40)
                    .background(MirrorTokens.raisedSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                Circle()
                    .fill(statusDotColor)
                    .frame(width: 10, height: 10)
                    .overlay(Circle().stroke(MirrorTokens.cardSurface, lineWidth: 2))
                    .offset(x: 2, y: 2)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(agent.deviceName)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)

                Text(statusSubtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(statusSubtitleColor)
                    .lineLimit(2)
            }

            Spacer()

            if agent.isConnected {
                HStack(spacing: 8) {
                    batteryBadge
                    Menu {
                        Button("Refresh Status") {
                            Task { await agent.refreshDeviceState() }
                        }
                        Divider()
                        Button("Unpair Device", role: .destructive) {
                            agent.unpairCurrentDevice()
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            } else {
                Button {
                    Task { await agent.refreshDeviceState() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Check for devices")
            }
        }
        .padding(MirrorTokens.space4)
        .background(MirrorTokens.cardSurface, in: RoundedRectangle(cornerRadius: MirrorTokens.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: MirrorTokens.cardRadius, style: .continuous)
                .stroke(MirrorTokens.hairlineBorder, lineWidth: 1)
        )
    }

    private var batteryBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: agent.isCharging ? "battery.100.bolt" : "battery.75")
                .font(.system(size: 11))
                .foregroundStyle(agent.batteryPercentage <= 20 ? MirrorTokens.warning : MirrorTokens.positive)
            Text("\(agent.batteryPercentage)%")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(MirrorTokens.raisedSurface, in: Capsule())
    }

    private var continuityActionStrip: some View {
        HStack(spacing: MirrorTokens.space2) {
            StudioActionTile(
                title: agent.isMirroring ? "Stop Mirror" : "Screen Mirror",
                systemImage: "macwindow.on.rectangle",
                isActive: agent.isMirroring,
                isEnabled: agent.isConnected
            ) {
                agent.toggleMirroring()
            }

            StudioActionTile(
                title: "Webcam",
                systemImage: "video.fill",
                isActive: agent.isWebcamActive,
                isEnabled: agent.isConnected
            ) {
                agent.toggleWebcam()
            }

            StudioActionTile(
                title: "Finder Drive",
                systemImage: "externaldrive.fill",
                isActive: agent.isFinderVolumeMounted,
                isEnabled: agent.isConnected
            ) {
                agent.toggleFinderVolume()
            }
        }
    }

    private var statusDotColor: Color {
        if agent.isConnected { return MirrorTokens.positive }
        if !agent.discoveredPeers.isEmpty { return MirrorTokens.accent }
        if agent.usbAttached != nil { return MirrorTokens.warning }
        return Color.secondary.opacity(0.45)
    }

    private var statusSubtitle: String {
        if agent.isConnected {
            let suffix = agent.connectionTransportLabel.isEmpty ? "" : " · \(agent.connectionTransportLabel)"
            return "Connected to Mirror Continuity\(suffix)"
        }
        if let peer = agent.discoveredPeers.first {
            let link = peer.isUsb ? "USB" : "Wi-Fi"
            return "Mirror open on \(peer.name) (\(link)) · Pair to connect"
        }
        if let usb = agent.usbAttached {
            return "USB attached (\(usb.model)) · Open Mirror on phone"
        }
        return "Waiting for Mirror Continuity on Android"
    }

    private var statusSubtitleColor: Color {
        if agent.isConnected { return MirrorTokens.positive }
        if !agent.discoveredPeers.isEmpty { return MirrorTokens.accent }
        if agent.usbAttached != nil { return MirrorTokens.warning }
        return .secondary
    }
}

private struct StudioActionTile: View {
    let title: String
    let systemImage: String
    let isActive: Bool
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(isActive ? Color.white : (isEnabled ? MirrorTokens.accent : .secondary))
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isActive ? Color.white : .primary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                isActive ? MirrorTokens.accent : MirrorTokens.cardSurface,
                in: RoundedRectangle(cornerRadius: MirrorTokens.innerRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: MirrorTokens.innerRadius, style: .continuous)
                    .stroke(isActive ? MirrorTokens.accentPressed : MirrorTokens.hairlineBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}
