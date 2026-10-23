import Foundation
import MetricKit

/// Apple's own crash and hang reports for Corres (MetricKit), kept with
/// Corres's diagnostics on this device so Send Diagnostics includes them.
/// TestFlight only sends crashes from testers who opted in; these come
/// with every Send Diagnostics. The system hands them over the next time
/// Corres opens. Backtraces and the build, never mail.
final class CrashCollector: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = CrashCollector()

    func start() {
        MXMetricManager.shared.add(self)
        // Daily numbers the system was already holding.
        didReceive(MXMetricManager.shared.pastPayloads)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        guard let directory = HangReporter.directory else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for payload in payloads {
            let stamp = Int(payload.timeStampEnd.timeIntervalSince1970)
            let file = directory.appendingPathComponent("metrickit-\(stamp).json")
            try? payload.jsonRepresentation().write(to: file, options: .atomic)
        }
        Self.keepRecent("metrickit-", in: directory)
    }

    /// Apple's daily numbers for Corres on this device: how long real
    /// launches took (time to first draw, a histogram), resumes, hangs
    /// and memory. Launches from Xcode skip the system's launch cache, so
    /// these, not a debug run, are the true launch times.
    func didReceive(_ payloads: [MXMetricPayload]) {
        guard let directory = HangReporter.directory else { return }
        for payload in payloads {
            let stamp = Int(payload.timeStampEnd.timeIntervalSince1970)
            try? payload.jsonRepresentation().write(to: directory.appendingPathComponent("metrics-\(stamp).json"), options: .atomic)
        }
        Self.keepRecent("metrics-", in: directory)
    }

    /// A few weeks' worth is plenty.
    private static func keepRecent(_ prefix: String, in directory: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        let reports = files.filter { $0.lastPathComponent.hasPrefix(prefix) }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in reports.dropFirst(20) { try? FileManager.default.removeItem(at: old) }
    }
}
