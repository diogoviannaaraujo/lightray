import AppKit

/// A non-interactive HUD; all pointer events continue to the video beneath it.
final class StatisticsOverlay: NSView {
    private let label = NSTextField(wrappingLabelWithString: "Waiting for stream…")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedRed: 0.035, green: 0.065, blue: 0.10, alpha: 0.92).cgColor
        layer?.cornerRadius = 10
        label.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        label.maximumNumberOfLines = 0
        label.isSelectable = false
        label.toolTip = "Capture/convert and encode are host wall-clock durations. Decode and queue use the client clock. Values average successful decoded frames since the previous update; unavailable metrics show a dash. RTT is round-trip time, not one-way or total latency. Display latency is not measured."
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
        setAccessibilityLabel("Stream performance")
    }

    required init?(coder: NSCoder) { fatalError("not used") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func update(_ text: String) { label.stringValue = text }
}
