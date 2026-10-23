import Foundation
import MetricKit
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
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
        /// Not pinging: the app is in the background (iOS) or another app
        /// is in front (Mac), where nobody is waiting on the main thread.
        var paused = false
    }
    /// Wakes the watch when the app comes back.
    private let resumed = DispatchSemaphore(value: 0)

    static var directory: URL? {
        guard let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else { return nil }
        let url = library.appendingPathComponent("Diagnostics", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func start() {
        MainActor.assumeIsolated { Self.launchedAt = Self.processStart ?? .now() }
        MXMetricManager.shared.add(self)
        // Diagnostics iOS already had waiting from an earlier run.
        didReceive(MXMetricManager.shared.pastDiagnosticPayloads)
        // Only while Corres is in use: pinging the main thread ten times a
        // second in the background kept it awake for nothing.
        #if canImport(UIKit)
        setActive(MainActor.assumeIsolated { UIApplication.shared.applicationState != .background })
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.setActive(false)
        }
        center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.setActive(true)
        }
        #else
        setActive(MainActor.assumeIsolated { NSApplication.shared.isActive })
        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.setActive(false)
        }
        center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.setActive(true)
        }
        #endif
        // Its own thread: the watch never returns, and on `queue` it kept
        // every report after it from being written.
        let watcher = Thread { [weak self] in self?.watch() }
        watcher.name = "studio.anwarcreative.corres.hangwatch"
        watcher.qualityOfService = .utility
        watcher.start()
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

    /// Pauses the watch, or picks it up again from now: time spent in the
    /// background isn't a stall.
    private func setActive(_ active: Bool) {
        let wake = lock.withLock { state -> Bool in
            let wasPaused = state.paused
            state.paused = !active
            guard active, wasPaused else { return false }
            state.awaiting = false
            state.stallStart = nil
            state.lastPong = .now()
            return true
        }
        if wake { resumed.signal() }
    }

    private func watch() {
        while true {
            if lock.withLock({ $0.paused }) {
                resumed.wait()
                continue
            }
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
        let at = Date().formatted(.iso8601)
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        queue.async {
            Self.write(["kind": "stall", "milliseconds": milliseconds, "at": at, "build": build, "recent": crumbs], prefix: "stall")
        }
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

    // MARK: Speed

    /// The two numbers that decide how fast Corres feels: launch until mail
    /// is on screen (aim: under a second), and an email tapped until its
    /// text is drawn (aim: under 0.2 seconds). The last 40 of each are
    /// kept with the diagnostics.
    @MainActor private static var marks: [String: DispatchTime] = [:]
    @MainActor private static var timings: [String] = []
    @MainActor private static var launchedAt = processStart ?? DispatchTime.now()

    @MainActor static func start(_ name: String) { marks[name] = .now() }

    /// Starts timing an email being opened, once for that email, from the
    /// moment its screen is asked for (before anything is drawn).
    @MainActor static func startOpening(_ key: String) {
        guard openingKey != key else { return }
        openingKey = key
        marks["open"] = .now()
    }
    @MainActor private static var openingKey: String?
    @MainActor static func closedOpening() { openingKey = nil }

    @MainActor static func finish(_ name: String) {
        guard let started = name == "launch" ? launchedAt : marks.removeValue(forKey: name) else { return }
        let ms = (DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
        log.info("\(name, privacy: .public): \(ms) ms")
        timings.append("\(Date().formatted(.iso8601.time(includingFractionalSeconds: false))) \(name) \(ms) ms")
        if timings.count > 80 { timings.removeFirst(timings.count - 80) }
        if name == "launch" { marks["launch-done"] = .now() }
        // Also on disk, so a development build's numbers can be read
        // straight off the phone.
        let snapshot = timings
        Task.detached(priority: .utility) {
            guard let directory, let data = try? JSONSerialization.data(withJSONObject: snapshot, options: .prettyPrinted) else { return }
            try? data.write(to: directory.appendingPathComponent("timings.json"), options: .atomic)
        }
    }

    @MainActor static var launchMeasured: Bool { marks["launch-done"] != nil }

    /// A point on the way to opening an email, timed from the tap, kept
    /// with the timings so a slow open says where the time went.
    @MainActor static func lap(_ label: String) {
        guard let started = marks["open"] else { return }
        let ms = (DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
        timings.append("\(Date().formatted(.iso8601.time(includingFractionalSeconds: false))) open: \(label) at \(ms) ms")
    }

    /// A point on the way to the first screen, timed from launch, so a slow
    /// launch says where the time went.
    @MainActor static func step(_ name: String) {
        guard !launchMeasured else { return }
        let ms = (DispatchTime.now().uptimeNanoseconds - launchedAt.uptimeNanoseconds) / 1_000_000
        timings.append("\(Date().formatted(.iso8601.time(includingFractionalSeconds: false))) launch: \(name) at \(ms) ms")
    }

    // MARK: Sharing

    /// Every report kept on this device, in one file a tester can send from
    /// Settings: freezes, crashes, and the build and iOS they happened on.
    /// Call stacks and what Corres was doing ("trash 1 thread"), never any
    /// email or address.
    static func diagnosticsFile() -> URL? {
        var reports: [[String: Any]] = []
        if let directory, let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for file in files.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
                guard let data = try? Data(contentsOf: file), let object = try? JSONSerialization.jsonObject(with: data) else { continue }
                reports.append(["file": file.lastPathComponent, "report": object])
            }
        }
        let info = Bundle.main.infoDictionary
        let summary: [String: Any] = [
            "app": "Corres \(info?["CFBundleShortVersionString"] as? String ?? "") (\(info?["CFBundleVersion"] as? String ?? ""))",
            "system": MainActor.assumeIsolated { Platform.systemDescription },
            "model": Self.modelIdentifier,
            "created": Date().formatted(.iso8601),
            "reports": reports,
            "recent": shared.lock.withLock { $0.breadcrumbs },
            "timings": MainActor.assumeIsolated { timings },
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]) else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Corres Diagnostics.json")
        return (try? data.write(to: url, options: .atomic)) != nil ? url : nil
    }

    private static var modelIdentifier: String {
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: &system.machine) { buffer in
            String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    /// When this process started, so launch is timed from the tap, not
    /// from partway through setting up.
    private static var processStart: DispatchTime? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var request: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&request, 4, &info, &size, nil, 0) == 0 else { return nil }
        let started = info.kp_proc.p_un.__p_starttime
        let startedAt = Double(started.tv_sec) + Double(started.tv_usec) / 1_000_000
        let ago = Date().timeIntervalSince1970 - startedAt
        guard ago > 0, ago < 120 else { return nil }
        let now = DispatchTime.now().uptimeNanoseconds
        return DispatchTime(uptimeNanoseconds: now - UInt64(ago * 1_000_000_000))
    }

    // MARK: Failures

    /// Something that went wrong without a freeze: a change the server
    /// refused, a message that wouldn't load. The last 40, each with the
    /// error as it came back, so "Couldn't mark as read" has a cause to
    /// look at. The error only, never the email.
    static func failure(_ what: String, _ error: Error) {
        let entry = "\(Date().formatted(.iso8601)) \(what): \(String(describing: error))"
        log.error("\(entry, privacy: .public)")
        note("failed: \(what)")
        shared.queue.async {
            guard let directory else { return }
            let url = directory.appendingPathComponent("failures.json")
            var entries = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
            entries.append(entry)
            if entries.count > 40 { entries.removeFirst(entries.count - 40) }
            try? JSONEncoder().encode(entries).write(to: url, options: .atomic)
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

/// A stretch of work iOS lets finish after Corres leaves the screen. On
/// the Mac, an activity that keeps App Nap from pausing it halfway.
@MainActor
final class BackgroundWork {
    #if canImport(UIKit)
    private var id: UIBackgroundTaskIdentifier = .invalid
    #else
    private var activity: NSObjectProtocol?
    #endif

    static func begin(_ name: String) -> BackgroundWork {
        let work = BackgroundWork()
        #if canImport(UIKit)
        work.id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak work] in MainActor.assumeIsolated { work?.end() } }
        #else
        work.activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: name)
        #endif
        return work
    }

    func end() {
        #if canImport(UIKit)
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
        #else
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        #endif
    }
}
