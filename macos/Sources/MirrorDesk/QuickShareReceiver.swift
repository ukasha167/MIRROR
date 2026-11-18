import AppKit
import NearbyShare

/// Quick Share receiver inside Mirror, built on NearDrop's `NearbyShare` code.
///
/// NearDrop asks for consent with a notification, which needs an app bundle; Mirror runs
/// from `swift run` without one, so we ask with an alert and show progress in the menu.
/// Files land in ~/Downloads (NearDrop's choice).
@MainActor
public final class QuickShareReceiver: MainAppDelegate {
    public enum State: Equatable, Sendable {
        case off
        case visible
        case waiting(device: String, summary: String)
        case receiving(device: String, summary: String)
        case received(summary: String)
        case failed(device: String, message: String)
    }

    public var onChange: ((State) -> Void)?
    public private(set) var state: State = .off {
        didSet { onChange?(state) }
    }
    private var transfers: [String: (device: String, summary: String)] = [:]

    public init() {}

    /// Starts listening and advertises the Mac over mDNS. NearbyShare has no stop call, so
    /// this stays on until Mirror quits.
    public func start() {
        guard state == .off else { return }
        NearbyConnectionManager.shared.mainAppDelegate = self
        NearbyConnectionManager.shared.becomeVisible()
        state = .visible
    }

    public nonisolated static func summary(files: [String], text: String?) -> String {
        if let text { return text }
        if files.count == 1 { return files[0] }
        return "\(files.count) files"
    }

    // MARK: - MainAppDelegate (called on NearbyShare's queues)

    public nonisolated func obtainUserConsent(for transfer: TransferMetadata, from device: RemoteDeviceInfo) {
        let id = transfer.id
        let name = device.name
        let summary = Self.summary(files: transfer.files.map(\.name), text: transfer.textDescription)
        let pin = transfer.pinCode
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.ask(id: id, device: name, summary: summary, pin: pin) }
        }
    }

    public nonisolated func incomingTransfer(id: String, didFinishWith error: Error?) {
        let message = error.map { "\($0)" }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.finish(id: id, error: message) }
        }
    }

    // MARK: - Main thread

    private func ask(id: String, device: String, summary: String, pin: String?) {
        transfers[id] = (device, summary)
        state = .waiting(device: device, summary: summary)
        let alert = NSAlert()
        alert.messageText = "\(device) wants to send \(summary)"
        alert.informativeText = pin.map { "Check that the phone shows PIN \($0). Files go to Downloads." } ?? "Files go to Downloads."
        alert.addButton(withTitle: "Accept")
        alert.addButton(withTitle: "Decline")
        NSApp.activate()
        let accepted = alert.runModal() == .alertFirstButtonReturn
        NearbyConnectionManager.shared.submitUserConsent(transferID: id, accept: accepted)
        if accepted {
            state = .receiving(device: device, summary: summary)
        } else {
            transfers[id] = nil
            state = .visible
        }
    }

    private func finish(id: String, error: String?) {
        guard let transfer = transfers.removeValue(forKey: id) else { return }
        if let error {
            state = .failed(device: transfer.device, message: error)
        } else {
            state = .received(summary: transfer.summary)
        }
    }
}
