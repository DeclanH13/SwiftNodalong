import AVFoundation
import CoreTransferable
import Foundation
import MetricKit
import Network
import UIKit
import UniformTypeIdentifiers
import os

// MARK: - Field diagnostics
//
// An always-on, **on-device** flight recorder for the question "why did
// playback mysteriously stop while I was out?".
//
// `DiagLog.swift` is debug-only by design and `devicectl --console` needs the
// phone plugged in and unlocked, so none of that helps once the app is in a
// pocket. This is the Release-capable counterpart: a small size-capped file
// recording the events that distinguish the usual causes —
//
//   - iOS killing a backgrounded app (jetsam / memory pressure) — leaves NO
//     crash report; the app just starts fresh next time. Detected by
//     recording the last-known phase + memory and comparing at next launch.
//   - audio interruptions (call, Siri, another app) and route changes
//     (Bluetooth / headphones dropping out),
//   - MusicKit's player going `.paused`/`.stopped` behind our back, play
//     timeouts, skipped tracks, and queue errors,
//   - real crashes, hangs and exit reasons, delivered by MetricKit.
//
// **Privacy contract — read before adding a call.** Nothing here may carry
// track titles, artist/album names, search text, uids, usernames, locations
// or party ids. Only fixed strings and numbers (indexes, counts, seconds,
// MB, enum names, error type/domain/code). The file never leaves the device
// unless the user taps "Share diagnostics" in Profile. This is what keeps it
// compatible with `DiagLog`'s rule that testers' devices don't write user
// data in Release.

/// Thread-safe, size-capped event log. Safe to call from any thread/actor.
enum FieldLog {
    // MARK: Public API

    /// Appends one line. `withMemory` adds the app's memory footprint and the
    /// headroom iOS says is left before it would terminate us — the two
    /// numbers that tell a memory kill apart from everything else.
    static func event(_ category: String, _ message: String, withMemory: Bool = false) {
        let now = Date()
        let uptime = max(0, ProcessInfo.processInfo.systemUptime - launchUptime)
        let mem = withMemory ? " " + memoryDescription() : ""
        queue.async {
            write("\(lineFormatter.string(from: now)) +\(String(format: "%.1f", uptime))s [\(category)] \(message)\(mem)")
        }
    }

    /// `type/domain#code` — never `localizedDescription`, which can embed a
    /// track title or an id in MusicKit/Firestore errors.
    static func tag(_ error: Error) -> String {
        let ns = error as NSError
        return "\(type(of: error))/\(ns.domain)#\(ns.code)"
    }

    /// Mirrors `PlayerViewModel.isPlaying` so the heartbeat and the
    /// next-launch analysis know whether the app *believed* it was playing.
    static func setPlaying(_ playing: Bool) {
        let changed = playingFlag.withLock { old -> Bool in
            defer { old = playing }
            return old != playing
        }
        guard changed else { return }
        event("player", "isPlaying → \(playing)")
        queue.async { saveSnapshot() }
    }

    /// What the audio system looks like right now: the output route's port TYPES,
    /// whether another app is playing audio, and whether iOS is asking us to
    /// stay quiet. Attached to the player-status lines that matter, because
    /// Apple Music plays in a SEPARATE process — this app's own audio-session
    /// interruption notifications never fire for it, so on a pause or an
    /// "interrupted" status this is the closest thing to a cause.
    static func audioSnapshot() -> String {
        let s = AVAudioSession.sharedInstance()
        let route = s.currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ",")
        return "route=\(route.isEmpty ? "none" : route) otherAudioPlaying=\(s.isOtherAudioPlaying) silenceHint=\(s.secondaryAudioShouldBeSilencedHint)"
    }

    /// Footprint in MB, or -1 if the kernel call fails.
    static func footprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return -1 }
        return Int(info.phys_footprint / 1_048_576)
    }

    // MARK: Lifecycle (called once from AppDelegate)

    /// Analyses how the PREVIOUS session ended, then starts recording this
    /// one. Must be called on the main thread.
    static func start() {
        guard !started else { return }
        started = true
        _ = launchUptime   // pin the zero point to launch, not first use
        analysePreviousSession()
        installObservers()
        startHeartbeat()
        startCPUSampler()
        MetricKitSubscriber.shared.start()
    }

    // MARK: Export

    /// Builds the shareable report and returns its file URL.
    static func writeExportFile() throws -> URL {
        let text: String = queue.sync { buildReport() }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nodalong-diagnostics-\(fileStamp(Date())).txt")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Internals

    private static let queue = DispatchQueue(label: "nodalong.fieldlog", qos: .utility)
    private static let maxBytes = 200 * 1024
    private static let launchUptime = ProcessInfo.processInfo.systemUptime
    private static let playingFlag = OSAllocatedUnfairLock(initialState: false)

    // Everything below is touched only on `queue` (or, for `started`, only
    // from the main thread at launch).
    nonisolated(unsafe) private static var started = false
    nonisolated(unsafe) private static var phase = "launching"
    nonisolated(unsafe) private static var heartbeat: DispatchSourceTimer?
    nonisolated(unsafe) private static var lastPathSummary = ""
    // CPU sampling — see `startCPUSampler`. Touched only on `queue`.
    nonisolated(unsafe) private static var cpuSampler: DispatchSourceTimer?
    nonisolated(unsafe) private static var lastCPUSeconds: Double?
    nonisolated(unsafe) private static var lastCPUWall: Double = 0
    nonisolated(unsafe) private static var windowMaxCPU: Double = 0
    nonisolated(unsafe) private static var highCPUSamples = 0

    private static let snapshotKey = "field.lastSnapshot"

    // Formatters are not thread-safe; they're used only on `queue`.
    private static let lineFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        return f
    }()
    private static let fileFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    private static func fileStamp(_ d: Date) -> String { queue.sync { fileFormatter.string(from: d) } }

    private static var directory: URL? {
        guard let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("Diagnostics", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    fileprivate static var metricKitDirectory: URL? { directory }
    private static var logURL: URL? { directory?.appendingPathComponent("field.log") }
    private static var oldLogURL: URL? { directory?.appendingPathComponent("field.old.log") }

    /// Must run on `queue`.
    private static func write(_ line: String) {
        guard let url = logURL, let data = (line + "\n").data(using: .utf8) else { return }
        // Rotate rather than truncate, so the stretch just before a reset is
        // never lost: field.log → field.old.log, keeping ~2× the cap.
        if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int,
           size > maxBytes, let old = oldLogURL {
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.moveItem(at: url, to: old)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    private static func memoryDescription() -> String {
        let headroom = os_proc_available_memory() / 1_048_576
        // The simulator reports 0 headroom; omit rather than mislead.
        return headroom > 0 ? "mem=\(footprintMB())MB headroom=\(headroom)MB" : "mem=\(footprintMB())MB"
    }

    private static func thermalName(_ s: ProcessInfo.ThermalState) -> String {
        switch s {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    // MARK: Snapshot (read at the NEXT launch)

    /// Must run on `queue`.
    private static func saveSnapshot() {
        let info = ProcessInfo.processInfo
        UserDefaults.standard.set([
            "phase": phase,
            "playing": playingFlag.withLock { $0 },
            "memMB": footprintMB(),
            "headroomMB": Int(os_proc_available_memory() / 1_048_576),
            "thermal": thermalName(info.thermalState),
            "ts": Date().timeIntervalSince1970,
        ] as [String: Any], forKey: snapshotKey)
    }

    private static func setPhase(_ p: String) {
        queue.async {
            phase = p
            saveSnapshot()
        }
    }

    // MARK: Previous-session analysis

    private static func analysePreviousSession() {
        let info = ProcessInfo.processInfo
        let bundle = Bundle.main.infoDictionary
        let version = "\(bundle?["CFBundleShortVersionString"] as? String ?? "?")(\(bundle?["CFBundleVersion"] as? String ?? "?"))"

        var verdict = "no previous snapshot (first run with diagnostics, or reinstall)"
        if let prev = UserDefaults.standard.dictionary(forKey: snapshotKey) {
            let prevPhase = prev["phase"] as? String ?? "?"
            let playing = prev["playing"] as? Bool ?? false
            let mem = prev["memMB"] as? Int ?? -1
            let headroom = prev["headroomMB"] as? Int ?? -1
            let thermal = prev["thermal"] as? String ?? "?"
            let ts = prev["ts"] as? Double ?? 0
            let ago = ts > 0 ? Int(Date().timeIntervalSince1970 - ts) : -1
            let last = "last seen \(ago)s ago, mem=\(mem)MB headroom=\(headroom)MB thermal=\(thermal)"
            switch (prevPhase, playing) {
            case ("terminating", _):
                verdict = "previous session: clean terminate (\(last))"
            case ("background", true):
                verdict = "⚠️ previous session ENDED IN BACKGROUND WHILE PLAYING — killed by iOS (memory/jetsam) or force-quit; not a crash (\(last))"
            case ("background", false):
                verdict = "previous session ended in background, not playing — normal iOS reclaim or swipe-away (\(last))"
            case ("active", _), ("inactive", _):
                verdict = "⚠️ previous session ENDED IN FOREGROUND (playing=\(playing)) — crash, watchdog kill or force-quit; a MetricKit report may follow (\(last))"
            default:
                verdict = "previous session ended in phase '\(prevPhase)' playing=\(playing) (\(last))"
            }
        }
        let finalVerdict = verdict
        queue.async {
            write("")
            write("\(lineFormatter.string(from: Date())) ===== LAUNCH app=\(version) ios=\(info.operatingSystemVersionString) lowPower=\(info.isLowPowerModeEnabled) thermal=\(thermalName(info.thermalState)) =====")
            write("\(lineFormatter.string(from: Date())) [launch] \(finalVerdict)")
            saveSnapshot()
        }
    }

    // MARK: Observers

    private static func installObservers() {
        let nc = NotificationCenter.default

        func app(_ name: Notification.Name, _ label: String, phase p: String?) {
            nc.addObserver(forName: name, object: nil, queue: nil) { _ in
                event("app", label, withMemory: true)
                if let p { setPhase(p) }
            }
        }
        app(UIApplication.didBecomeActiveNotification, "didBecomeActive", phase: "active")
        app(UIApplication.willResignActiveNotification, "willResignActive", phase: "inactive")
        app(UIApplication.didEnterBackgroundNotification, "didEnterBackground playing=\(playingFlag.withLock { $0 })", phase: "background")
        app(UIApplication.willEnterForegroundNotification, "willEnterForeground", phase: "inactive")
        app(UIApplication.willTerminateNotification, "willTerminate", phase: "terminating")
        // The single most useful line for a "stopped while I was out" report:
        // a memory warning shortly before a relaunch means iOS reclaimed us.
        nc.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil) { _ in
            event("mem", "MEMORY WARNING playing=\(playingFlag.withLock { $0 })", withMemory: true)
        }

        let session = AVAudioSession.sharedInstance()
        nc.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: nil) { note in
            let info = note.userInfo
            let typeRaw = info?[AVAudioSessionInterruptionTypeKey] as? UInt ?? 99
            let reasonRaw = info?[AVAudioSessionInterruptionReasonKey] as? UInt
            let optRaw = info?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let type = typeRaw == 1 ? "BEGAN" : (typeRaw == 0 ? "ended" : "?")
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: optRaw).contains(.shouldResume)
            let reason: String
            switch reasonRaw {
            case 0?: reason = "default(another app/system audio)"
            case 1?: reason = "appWasSuspended"
            case 2?: reason = "builtInMicMuted"
            case 4?: reason = "routeDisconnected"
            case let r?: reason = "other(\(r))"
            case nil: reason = "n/a"
            }
            event("audio", "interruption \(type) reason=\(reason) shouldResume=\(shouldResume) playing=\(playingFlag.withLock { $0 })", withMemory: true)
        }
        nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: nil) { note in
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
            let reason = AVAudioSession.RouteChangeReason(rawValue: raw).map { r -> String in
                switch r {
                case .newDeviceAvailable: return "newDeviceAvailable"
                case .oldDeviceUnavailable: return "oldDeviceUnavailable"
                case .categoryChange: return "categoryChange"
                case .override: return "override"
                case .wakeFromSleep: return "wakeFromSleep"
                case .noSuitableRouteForCategory: return "noSuitableRoute"
                case .routeConfigurationChange: return "routeConfigurationChange"
                case .unknown: return "unknown"
                @unknown default: return "other(\(raw))"
                }
            } ?? "other(\(raw))"
            // Port TYPES only ("Headphones", "BluetoothA2DPOutput") — never
            // port names, which are the user's device names.
            let prev = (note.userInfo?[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription)?
                .outputs.map { $0.portType.rawValue }.joined(separator: ",") ?? "?"
            let now = session.currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ",")
            event("audio", "routeChange \(reason) \(prev) → \(now) playing=\(playingFlag.withLock { $0 })")
        }
        nc.addObserver(forName: AVAudioSession.mediaServicesWereLostNotification, object: nil, queue: nil) { _ in
            event("audio", "⚠️ MEDIA SERVICES LOST (mediaserverd died)", withMemory: true)
        }
        nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: nil) { _ in
            event("audio", "⚠️ MEDIA SERVICES RESET — audio session must be rebuilt")
        }

        nc.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: nil) { _ in
            event("system", "thermal → \(thermalName(ProcessInfo.processInfo.thermalState))")
        }
        nc.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: nil) { _ in
            event("system", "lowPowerMode → \(ProcessInfo.processInfo.isLowPowerModeEnabled)")
        }

        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            let kind = path.usesInterfaceType(.wifi) ? "wifi"
                : path.usesInterfaceType(.cellular) ? "cellular"
                : path.usesInterfaceType(.wiredEthernet) ? "ethernet" : "other"
            let summary = "\(path.status == .satisfied ? "online" : "OFFLINE") via \(kind) constrained=\(path.isConstrained) expensive=\(path.isExpensive)"
            queue.async {
                guard summary != lastPathSummary else { return }
                lastPathSummary = summary
                write("\(lineFormatter.string(from: Date())) +\(String(format: "%.1f", max(0, ProcessInfo.processInfo.systemUptime - launchUptime)))s [net] \(summary)")
            }
        }
        monitor.start(queue: DispatchQueue(label: "nodalong.fieldlog.net", qos: .utility))
    }

    // MARK: Heartbeat

    /// Every 60s. Always refreshes the snapshot (cheap), and writes a line
    /// only when it carries information: while playing or in the background.
    /// The app only runs in the background when audio is active, so the
    /// LAST heartbeat before a gap is effectively the time of death — and the
    /// mem/headroom trend across heartbeats shows a leak or a spike.
    private static func startHeartbeat() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 60, repeating: 60, leeway: .seconds(5))
        timer.setEventHandler {
            saveSnapshot()
            let playing = playingFlag.withLock { $0 }
            guard playing || phase != "active" else { return }
            write("\(lineFormatter.string(from: Date())) +\(String(format: "%.1f", max(0, ProcessInfo.processInfo.systemUptime - launchUptime)))s [heartbeat] phase=\(phase) playing=\(playing) \(memoryDescription()) cpuMax=\(Int(windowMaxCPU))% thermal=\(thermalName(ProcessInfo.processInfo.thermalState))")
            windowMaxCPU = 0
        }
        timer.resume()
        heartbeat = timer
    }

    // MARK: CPU

    /// Total CPU time (user + system, all threads) this process has used.
    private static func processCPUSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    /// Samples this process's CPU every 10s and flags a sustained spike.
    ///
    /// Added after MetricKit reported `CPU EXCEPTION totalCPU=48s over 49s` for
    /// a backgrounded, playing app that iOS then killed — a hot loop, but the
    /// stack was mostly system frames and nothing in the log said what started
    /// it. This puts the spike in the log WITH the phase, the player state and
    /// the audio route, and the heartbeat carries the worst sample of each
    /// minute (`cpuMax`), so the next one has a timeline instead of a verdict.
    ///
    /// Percent of ONE core, so a multi-threaded burst can exceed 100. The
    /// timer only fires while the process is running, so it costs nothing
    /// while the app is suspended.
    private static func startCPUSampler() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 10, repeating: 10, leeway: .seconds(1))
        timer.setEventHandler {
            let wall = ProcessInfo.processInfo.systemUptime
            let cpu = processCPUSeconds()
            defer { lastCPUSeconds = cpu; lastCPUWall = wall }
            guard let previous = lastCPUSeconds, wall > lastCPUWall else { return }
            let percent = (cpu - previous) / (wall - lastCPUWall) * 100
            windowMaxCPU = max(windowMaxCPU, percent)
            let publishers = PublishCounter.drain()
            if percent >= 70 {
                highCPUSamples += 1
                // The first sample and then every third (~30s), so a long spin
                // is visible without filling the log.
                if highCPUSamples == 1 || highCPUSamples % 3 == 0 {
                    let playing = playingFlag.withLock { $0 }
                    write("\(lineFormatter.string(from: Date())) +\(String(format: "%.1f", max(0, wall - launchUptime)))s [cpu] ⚠️ HIGH CPU \(Int(percent))% of a core, sample #\(highCPUSamples) phase=\(phase) playing=\(playing) \(memoryDescription()) publishes[\(publishers)]")
                }
            } else if highCPUSamples > 0 {
                write("\(lineFormatter.string(from: Date())) +\(String(format: "%.1f", max(0, wall - launchUptime)))s [cpu] back to normal after \(highCPUSamples) high sample(s), now \(Int(percent))%")
                highCPUSamples = 0
            }
        }
        timer.resume()
        cpuSampler = timer
    }

    // MARK: Report

    /// Must run on `queue`.
    private static func buildReport() -> String {
        let info = ProcessInfo.processInfo
        let bundle = Bundle.main.infoDictionary
        var machine = utsname()
        uname(&machine)
        let model = withUnsafePointer(to: &machine.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }

        var out = """
        Nodalong diagnostics
        generated: \(lineFormatter.string(from: Date()))
        app: \(bundle?["CFBundleShortVersionString"] as? String ?? "?") (\(bundle?["CFBundleVersion"] as? String ?? "?"))
        device: \(model)  ios: \(info.operatingSystemVersionString)
        physical memory: \(info.physicalMemory / 1_048_576) MB
        lowPower: \(info.isLowPowerModeEnabled)  thermal: \(thermalName(info.thermalState))

        Contains no track names, usernames, uids or locations.
        Lines marked ⚠️ are the ones worth reading first.

        """

        for (title, url) in [("EARLIER LOG", oldLogURL), ("CURRENT LOG", logURL)] {
            guard let url, let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty else { continue }
            out += "\n==================== \(title) ====================\n\(text)"
        }

        // MetricKit payloads (crashes, hangs, exit-reason counts), newest
        // last. Capped so the report stays shareable.
        if let dir = directory,
           let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter({ $0.lastPathComponent.hasPrefix("metrickit-") })
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            for file in files {
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                let clipped = text.count > 60_000 ? String(text.prefix(60_000)) + "\n…(truncated)" : text
                out += "\n==================== \(file.lastPathComponent) ====================\n\(clipped)\n"
            }
        }
        return out
    }
}

// MARK: - MetricKit

/// Receives the system's own crash / hang / exit-reason reports. iOS delivers
/// these at most once a day, usually the launch AFTER the event, and only for
/// real (TestFlight / App Store / ad-hoc) installs — so absence of a report
/// from an Xcode run proves nothing.
final class MetricKitSubscriber: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = MetricKitSubscriber()

    func start() { MXMetricManager.shared.add(self) }

    /// Daily rollup. The part that matters here is `applicationExitMetrics`:
    /// it counts WHY the app exited, and `memoryResourceLimit` /
    /// `memoryPressure` in the background bucket are exactly the jetsam kills
    /// that otherwise leave no trace at all.
    func didReceive(_ payloads: [MXMetricPayload]) {
        for p in payloads {
            var parts = ["window=\(p.timeStampBegin.formatted(.iso8601.year().month().day()))…\(p.timeStampEnd.formatted(.iso8601.year().month().day()))"]
            if let mem = p.memoryMetrics {
                parts.append("peakMem=\(Int(mem.peakMemoryUsage.converted(to: .megabytes).value))MB")
            }
            if let t = p.applicationTimeMetrics {
                parts.append("bgAudio=\(Int(t.cumulativeBackgroundAudioTime.converted(to: .minutes).value))min")
            }
            if let exits = p.applicationExitMetrics {
                let fg = exits.foregroundExitData
                let bg = exits.backgroundExitData
                parts.append("FG exits: normal=\(fg.cumulativeNormalAppExitCount) memLimit=\(fg.cumulativeMemoryResourceLimitExitCount) watchdog=\(fg.cumulativeAppWatchdogExitCount) badAccess=\(fg.cumulativeBadAccessExitCount) illegal=\(fg.cumulativeIllegalInstructionExitCount) abnormal=\(fg.cumulativeAbnormalExitCount)")
                parts.append("BG exits: normal=\(bg.cumulativeNormalAppExitCount) memLimit=\(bg.cumulativeMemoryResourceLimitExitCount) memPressure=\(bg.cumulativeMemoryPressureExitCount) cpu=\(bg.cumulativeCPUResourceLimitExitCount) watchdog=\(bg.cumulativeAppWatchdogExitCount) bgTaskTimeout=\(bg.cumulativeBackgroundTaskAssertionTimeoutExitCount) badAccess=\(bg.cumulativeBadAccessExitCount) abnormal=\(bg.cumulativeAbnormalExitCount)")
                let killed = bg.cumulativeMemoryResourceLimitExitCount + bg.cumulativeMemoryPressureExitCount
                if killed > 0 {
                    FieldLog.event("metrickit", "⚠️ iOS killed the app for MEMORY \(killed)× while in the background this period")
                }
            }
            FieldLog.event("metrickit", "daily metrics " + parts.joined(separator: " | "))
        }
    }

    /// Crash / hang / CPU-exception reports with call stacks. The summary
    /// goes in the log; the full JSON (with the stack tree) is saved beside
    /// it and included in the shared report.
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for p in payloads {
            for c in p.crashDiagnostics ?? [] {
                FieldLog.event("metrickit", "⚠️ CRASH app=\(c.applicationVersion) signal=\(c.signal?.intValue ?? -1) exceptionType=\(c.exceptionType?.intValue ?? -1) code=\(c.exceptionCode?.intValue ?? -1) reason=\(c.terminationReason ?? "n/a")")
            }
            for h in p.hangDiagnostics ?? [] {
                FieldLog.event("metrickit", "⚠️ HANG \(Int(h.hangDuration.converted(to: .seconds).value))s app=\(h.applicationVersion)")
            }
            for c in p.cpuExceptionDiagnostics ?? [] {
                FieldLog.event("metrickit", "⚠️ CPU EXCEPTION totalCPU=\(Int(c.totalCPUTime.converted(to: .seconds).value))s over \(Int(c.totalSampledTime.converted(to: .seconds).value))s")
            }
            for _ in p.diskWriteExceptionDiagnostics ?? [] {
                FieldLog.event("metrickit", "⚠️ DISK WRITE EXCEPTION")
            }
            saveJSON(p.jsonRepresentation())
        }
    }

    private func saveJSON(_ data: Data) {
        guard let dir = FieldLog.metricKitDirectory else { return }
        let name = "metrickit-diag-\(Int(Date().timeIntervalSince1970)).json"
        try? data.write(to: dir.appendingPathComponent(name))
        // Keep the five newest.
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("metrickit-") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }) ?? []
        for stale in files.dropLast(5) { try? FileManager.default.removeItem(at: stale) }
    }
}

// MARK: - Sharing

/// What Profile's "Share diagnostics" button hands to `ShareLink`. The file
/// is built lazily, at share time, so merely showing the button costs
/// nothing.
struct DiagnosticsReport: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .plainText) { _ in
            SentTransferredFile(try FieldLog.writeExportFile())
        }
    }
}


/// Counts how often key observable properties publish, so a CPU spike can name
/// its source. `FieldLog`'s CPU sampler drains it each sample and attaches the
/// top publishers to any `HIGH CPU` line — a SwiftUI update storm shows up as
/// one object publishing hundreds of times in ten seconds.
enum PublishCounter {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var counts: [String: Int] = [:]

    static func bump(_ name: String) {
        lock.lock(); counts[name, default: 0] += 1; lock.unlock()
    }

    /// Top publishers since the last drain, e.g. `clock.progress=480 isPlaying=2`.
    static func drain() -> String {
        lock.lock(); defer { counts = [:]; lock.unlock() }
        return counts.sorted { $0.value > $1.value }.prefix(6)
            .map { "\($0.key)=\($0.value)" }.joined(separator: " ")
    }
}
