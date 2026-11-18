import AppKit

/// Phase 1 ships NearDrop unchanged as a separate app for Quick Share from the phone.
/// `scripts/build-neardrop.sh` builds it into `build/NearDrop/`.
public enum QuickShareLauncher {
    public static func candidates(repoRoot: String = ScrcpyServer.repoRoot) -> [String] {
        [
            "/Applications/NearDrop.app",
            "\(NSHomeDirectory())/Applications/NearDrop.app",
            "\(repoRoot)/build/NearDrop/NearDrop.app",
        ]
    }

    @MainActor
    public static func open() {
        if let path = candidates().first(where: { FileManager.default.fileExists(atPath: $0) }) {
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: .init())
            return
        }
        let alert = NSAlert()
        alert.messageText = "NearDrop is not installed"
        alert.informativeText = "Run scripts/build-neardrop.sh in the Mirror repository, or install NearDrop from github.com/grishka/NearDrop."
        alert.runModal()
    }
}
