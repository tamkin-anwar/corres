import Foundation
import MetricKit
import UIKit
import os

/// Keeps every hang and crash report iOS hands Corres, so a freeze on a
/// tester's phone leaves a call stack behind instead of just a story.
///
/// Two sources:
/// - MetricKit's diagnostics (hangs, crashes, CPU and disk exceptions),
///   delivered with full call stacks, usually on the next launch.
/// - A small main-thread watch: a background thread checks every 100 ms
///   that the main thread answers, and notes any stall of 250 ms or more
///   with what Corres was doing at the time (`HangReporter.note`).
///
/// Both write JSON into Library/Diagnostics in the app's own container,
/// which a development build exposes to `devicectl`. Nothing leaves the
/// device.
final class HangReporter: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = HangReporter()

    private static let log = Logger(subsystem: "studio.anwarcreative.corres", category: "hangs")
    private let queue = DispatchQueue(label: "studio.anwarcreative.corres.hangs", qos: .utility)
    private let lock = OSAllocatedUnfairLock(initialState: State())

    private struct State {
        var lastPong = DispatchTime.now()
        var awaiting = false
        var stallStart: DispatchTime?
        var breadcrumbs: [String] = []
    }

    private static var directory: URL? {
        guard let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else { return nil }
        let url = library.appendingPathComponent("Diagnostics", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func start() {
        MXMetricManager.shared.add(self)
        // Diagnostics iOS already had waiting from an earlier run.
        didReceive(MXMetricManager.shared.pastDiagnosticPayloads)
        queue.async { [weak self] in self?.watch() }
    }

    /// Records what the app is doing, so a stall report says "swipe to
    /// Trash" rather than only a time. Cheap enough to call on every action.
    static func note(_ event: String) {
        let stamp = Date().formatted(.iso8601.time(includingFractionalSeconds: true))
        shared.lock.withLock { state in
            state.breadcrumbs.append("\(stamp) \(event)")
            if state.breadcrumbs.count > 30 { state.breadcrumbs.removeFirst(state.breadcrumbs.count - 30) }
        }
    }

    // MARK: Main-thread watch

    private func watch() {
        while true {
            let shouldPing = lock.withLock { state -> Bool in
                if state.awaiting {
                    let waited = DispatchTime.now().uptimeNanoseconds - state.lastPong.uptimeNanoseconds
                    if waited >= 250_000_000, state.stallStart == nil { state.stallStart = state.lastPong }
                    return false
                }
                state.awaiting = true
                return true
            }
            if shouldPing {
                DispatchQueue.main.async { [weak self] in self?.pong() }
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    private func pong() {
        let now = DispatchTime.now()
        let finished = lock.withLock { state -> (UInt64, [String])? in
            defer { state.awaiting = false; state.lastPong = now; state.stallStart = nil }
            guard let start = state.stallStart else { return nil }
            return ((now.uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000, state.breadcrumbs)
        }
        guard let (milliseconds, crumbs) = finished else { return }
        Self.log.error("Main thread stalled for \(milliseconds) ms")
        let report: [String: Any] = [
            "kind": "stall",
            "milliseconds": milliseconds,
            "at": Date().formatted(.iso8601),
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
            "recent": crumbs,
        ]
        queue.async { Self.write(report, prefix: "stall") }
    }

    // MARK: MetricKit

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            let data = payload.jsonRepresentation()
            queue.async { Self.write(data: data, prefix: "diagnostic") }
            let hangs = payload.hangDiagnostics?.count ?? 0
            let crashes = payload.crashDiagnostics?.count ?? 0
            Self.log.error("MetricKit diagnostics: \(hangs) hangs, \(crashes) crashes")
        }
    }

    // MARK: Files

    private static func write(_ object: [String: Any], prefix: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else { return }
        write(data: data, prefix: prefix)
    }

    private static func write(data: Data, prefix: String) {
        guard let directory else { return }
        let name = "\(prefix)-\(Int(Date().timeIntervalSince1970 * 1000)).json"
        try? data.write(to: directory.appendingPathComponent(name), options: .atomic)
        prune(directory)
    }

    /// Keeps the newest 50 reports.
    private static func prune(_ directory: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        let sorted = files.sorted { $0.lastPathComponent > $1.lastPathComponent }
        for file in sorted.dropFirst(50) { try? FileManager.default.removeItem(at: file) }
    }
}

/// A stretch of work iOS lets finish after Corres leaves the screen.
@MainActor
final class BackgroundWork {
    private var id: UIBackgroundTaskIdentifier = .invalid

    static func begin(_ name: String) -> BackgroundWork {
        let work = BackgroundWork()
        work.id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak work] in MainActor.assumeIsolated { work?.end() } }
        return work
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
