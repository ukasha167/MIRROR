import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import AppKit
import MirrorCoreBridge

/// Dual-direction pairing card offering Mac QR + 6-digit code AND an input field to enter Android's pair code.
public struct PairingPanelView: View {
    public enum Mode: String, CaseIterable {
        case showQr = "QR Code"
        case enterCode = "Enter Code"
    }

    @ObservedObject var agent: MirrorAppAgent
    @State private var mode: Mode = .showQr
    @State private var pinInput: String = ""
    @State private var selectedPeerId: String = ""
    @State private var manualAddress: String = ""
    @State private var showManualIpField: Bool = false
    @State private var copiedQrHint: Bool = false

    public init(agent: MirrorAppAgent) {
        self.agent = agent
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: MirrorTokens.space3) {
            headerRow

            Picker("Pairing Method", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)

            if mode == .showQr {
                qrAndLocalCodeContent
            } else {
                enterPhoneCodeContent
            }
        }
        .padding(MirrorTokens.space4)
        .background(MirrorTokens.cardSurface, in: RoundedRectangle(cornerRadius: MirrorTokens.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: MirrorTokens.cardRadius, style: .continuous)
                .stroke(MirrorTokens.hairlineBorder, lineWidth: 1)
        )
        .onAppear {
            if selectedPeerId.isEmpty, let first = agent.discoveredPeers.first {
                selectedPeerId = first.id
            }
        }
        .onChange(of: agent.discoveredPeers) { _, peers in
            if selectedPeerId.isEmpty, let first = peers.first {
                selectedPeerId = first.id
            }
        }
    }

    private var headerRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Pair Android Device")
                    .font(.system(size: 14, weight: .semibold))
                Text(mode == .showQr
                     ? "Scan with Mirror on Android or type this code on your phone."
                     : "Enter the 6-digit code shown inside Mirror on your phone.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if mode == .showQr {
                Button {
                    agent.refreshPairingCode()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Rotate pairing QR and code")
            }
        }
    }

    private var qrAndLocalCodeContent: some View {
        HStack(alignment: .center, spacing: MirrorTokens.space3) {
            qrCodeImageView
                .frame(width: 156, height: 156)
                .padding(10)
                .background(Color.white, in: RoundedRectangle(cornerRadius: MirrorTokens.innerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: MirrorTokens.innerRadius, style: .continuous)
                        .stroke(MirrorTokens.hairlineBorder, lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: MirrorTokens.space2) {
                Text("MAC PAIR CODE")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.6)

                Text(ContinuityPairingCodec.formatPin(agent.pairingPin))
                    .font(.system(size: 22, weight: .bold, design: .monospaced).monospacedDigit())
                    .textSelection(.enabled)

                Text("Port \(agent.listeningPort)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)

                if let peer = agent.discoveredPeers.first {
                    Text("\(peer.name) detected (\(peer.isUsb ? "USB" : "Wi-Fi")) · Ready to pair")
                        .font(.system(size: 11))
                        .foregroundStyle(MirrorTokens.accent)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let usb = agent.usbAttached {
                    Text("USB attached (\(usb.model)): open Mirror on Android.")
                        .font(.system(size: 11))
                        .foregroundStyle(MirrorTokens.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button(copiedQrHint ? "Copied QR Payload" : "Copy QR Payload") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(agent.pairingQrPayload, forType: .string)
                    copiedQrHint = true
                }
                .buttonStyle(.link)
                .font(.system(size: 11))
            }
            Spacer(minLength: 0)
        }
    }

    private var enterPhoneCodeContent: some View {
        VStack(alignment: .leading, spacing: MirrorTokens.space3) {
            if !agent.discoveredPeers.isEmpty {
                Picker("Device", selection: $selectedPeerId) {
                    ForEach(agent.discoveredPeers) { peer in
                        Text("\(peer.name) (\(peer.isUsb ? "USB" : "Wi-Fi"))").tag(peer.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            } else {
                Text("No phone auto-discovered yet. Open Mirror on Android or enter its IP below.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: MirrorTokens.space2) {
                TextField("6-digit phone code", text: $pinInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 16, weight: .semibold, design: .monospaced).monospacedDigit())
                    .onChange(of: pinInput) { _, newValue in
                        let filtered = ContinuityPairingCodec.normalizePin(newValue)
                        if filtered != newValue { pinInput = filtered }
                    }
                    .onSubmit { submitPinPairing() }

                Button {
                    submitPinPairing()
                } label: {
                    if agent.isPairingInProgress {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Pair Device")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(MirrorTokens.accent)
                .disabled(pinInput.count != 6 || agent.isPairingInProgress)
            }

            DisclosureGroup("Manual IP / Port", isExpanded: $showManualIpField) {
                TextField("e.g. 192.168.1.42:53319", text: $manualAddress)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(.top, 4)
            }
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(.secondary)

            if let error = agent.pairingErrorMessage {
                Text(error)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(MirrorTokens.danger)
            }
        }
    }

    private func submitPinPairing() {
        let targetId = selectedPeerId.isEmpty ? agent.discoveredPeers.first?.id : selectedPeerId
        agent.pairWithPhoneCode(
            peerId: targetId,
            manualAddress: showManualIpField || agent.discoveredPeers.isEmpty ? manualAddress : nil,
            pinCode: pinInput
        )
    }

    @ViewBuilder
    private var qrCodeImageView: some View {
        if let nsImage = Self.renderQrNSImage(from: agent.pairingQrPayload) {
            Image(nsImage: nsImage)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: "qrcode")
                .font(.system(size: 40))
                .foregroundStyle(.black.opacity(0.6))
        }
    }

    private static func renderQrNSImage(from text: String) -> NSImage? {
        guard let data = text.data(using: .utf8) else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = data
        filter.correctionLevel = "L"
        guard let outputImage = filter.outputImage else { return nil }
        let transformed = outputImage.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let context = CIContext()
        guard let cgImage = context.createCGImage(transformed, from: transformed.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: transformed.extent.width, height: transformed.extent.height))
    }
}
