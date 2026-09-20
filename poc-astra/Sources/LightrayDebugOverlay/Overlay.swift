import LightrayStats
import SwiftUI

public struct LinkQualityIndicator: View {
    public var stats: StatsSnapshot
    public init(stats: StatsSnapshot) { self.stats = stats }
    public var body: some View { Label(stats.quality.rawValue.capitalized, systemImage: "network").foregroundStyle(stats.quality == .good ? .green : stats.quality == .degraded ? .orange : .red) }
}
public struct LightrayDebugOverlay: View {
    public var stats: StatsSnapshot
    public init(stats: StatsSnapshot) { self.stats = stats }
    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LinkQualityIndicator(stats: stats)
            Text("RTT \(stats.path.srtt / 1e6, specifier: "%.2f") ms · jitter \(stats.path.jitter / 1e6, specifier: "%.2f") ms")
            Text("Queue \(stats.path.queuingDelay / 1e6, specifier: "%.2f") ms · pacer \(stats.pacerBytes) B")
            Text("Frames \(stats.streams.completed) · NACK \(stats.streams.nacks) · retransmits \(stats.streams.retransmits)")
            Text("\(Double(stats.bitrate) / 1e6, specifier: "%.1f") Mbps\(stats.backstop ? " · loss backstop" : "")")
            Text("Parks \(stats.reconnect.parks) · resumes \(stats.reconnect.resumes) · rebinds \(stats.reconnect.rebinds)")
        }.font(.system(.caption, design: .monospaced)).padding().background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}
