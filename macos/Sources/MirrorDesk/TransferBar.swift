import AppKit

/// Strip along the bottom of a mirror window: file name, "42 MB of 100 MB", a progress bar
/// and a stop button. Hidden when nothing is sending.
@MainActor
final class TransferBar: NSVisualEffectView {
    private let label = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()
    private let stop = NSButton()
    var onStop: (() -> Void)?
    private var hideWork: DispatchWorkItem?

    static let height: CGFloat = 52

    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        isHidden = true

        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.lineBreakMode = .byTruncatingMiddle
        detail.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        detail.textColor = .secondaryLabelColor
        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        stop.bezelStyle = .circular
        stop.isBordered = false
        stop.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Stop sending")
        stop.contentTintColor = .secondaryLabelColor
        stop.target = self
        stop.action = #selector(stopPressed)

        let text = NSStackView(views: [label, NSView(), detail])
        text.orientation = .horizontal
        let column = NSStackView(views: [text, bar])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 4
        let row = NSStackView(views: [column, stop])
        row.orientation = .horizontal
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.widthAnchor.constraint(equalTo: column.widthAnchor),
            bar.widthAnchor.constraint(equalTo: column.widthAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ event: FileDropQueue.Event) {
        hideWork?.cancel()
        switch event {
        case .progress(let status):
            isHidden = false
            stop.isHidden = false
            let more = status.queued > 0 ? "  (+\(status.queued) more)" : ""
            label.stringValue = "Sending \(status.fileName)\(more)"
            detail.stringValue = "\(Self.bytes(status.sent)) of \(Self.bytes(status.total))"
            bar.doubleValue = status.fraction
        case .finished(let name, _):
            isHidden = false
            stop.isHidden = true
            label.stringValue = "\(name) is in Downloads on the phone"
            detail.stringValue = ""
            bar.doubleValue = 1
        case .failed(let name, let message):
            isHidden = false
            stop.isHidden = true
            label.stringValue = "\(name) not sent"
            detail.stringValue = message
            bar.doubleValue = 0
        case .idle:
            // Leave the last message up long enough to read.
            let work = DispatchWorkItem { [weak self] in self?.isHidden = true }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
        }
    }

    @objc private func stopPressed() { onStop?() }

    static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }
}
