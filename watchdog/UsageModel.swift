//
//  UsageModel.swift
//  watchdog
//
//  Created by Mulualem Tekle on 21/07/2026.
//

import SwiftUI
import Combine

enum UsageWindow: String, CaseIterable, Identifiable {
    case live = "Live monitor"
    case today = "Today"
    case week = "This week"
    case month = "This month"

    var id: String { rawValue }

    /// Caption for the detail view, e.g. "used this session".
    var caption: String { self == .live ? "this session" : rawValue.lowercased() }
}

enum SortMode: String, CaseIterable, Identifiable {
    case usage = "Usage"
    case name = "Name"

    var id: String { rawValue }
}

enum ReportScope: String, CaseIterable, Identifiable {
    case today = "Today"
    case week = "This week"

    var id: String { rawValue }
}

/// One chart bucket (an hour of today, or a day of this week).
struct ReportBucket: Identifiable {
    /// Unique x-axis value: "0"…"23" for hours, "Mon"…"Sun" for days.
    let key: String
    /// Human label for the peak line: "21:00–22:00" or "Monday".
    let title: String
    let apps: [AppUsage]

    var id: String { key }
    var totalBytes: Int64 { apps.reduce(0) { $0 + $1.totalBytes } }
}

struct PeakSummary {
    let bucketTitle: String
    let totalBytes: Int64
    let topAppName: String
    let share: Double
}

struct AppUsage: Identifiable, Hashable {
    let id: String
    var name: String
    var icon: NSImage?
    var bytesIn: Int64
    var bytesOut: Int64
    var isBlocked: Bool = false

    var totalBytes: Int64 { bytesIn + bytesOut }
}

struct HostUsage: Identifiable, Hashable {
    let host: String
    var bytesIn: Int64
    var bytesOut: Int64

    var id: String { host }
    var totalBytes: Int64 { bytesIn + bytesOut }
}

@MainActor
final class UsageStore: ObservableObject {
    @Published var window: UsageWindow = .live { didSet { rebuild() } }
    @Published var sortMode: SortMode = .usage
    @Published private(set) var apps: [AppUsage] = []

    /// Shared with the (optional) content-filter extension — see WatchdogFilterExtension/.
    static let blockDefaults = UserDefaults(suiteName: "group.watchdog.shared") ?? .standard
    private static let blockedKey = "blockedAppIDs"
    private static let dailyLimitKey = "dailyLimitBytes"
    private static let limitNotifiedDayKey = "dailyLimitNotifiedDay"

    /// Daily data-plan limit in bytes; 0 = off. Monitoring + alerting only, no cutoff.
    @Published var dailyLimitBytes: Int64 = 0 {
        didSet {
            UserDefaults.standard.set(dailyLimitBytes, forKey: Self.dailyLimitKey)
            // A changed limit re-arms the once-per-day alert.
            UserDefaults.standard.removeObject(forKey: Self.limitNotifiedDayKey)
        }
    }

    /// Swappable for tests; posts a user notification by default.
    var notify: (String, String) -> Void = { Notifier.post(title: $0, body: $1) }

    private struct Tally {
        var name: String
        var bytesIn: Int64 = 0
        var bytesOut: Int64 = 0
    }

    private struct Baseline {
        var bytesIn: Int64
        var bytesOut: Int64
        var lastSeen: Int
    }

    private var session: [String: Tally] = [:]
    private var hostTallies: [String: [String: HostUsage]] = [:]
    private var baselines: [String: Baseline] = [:]
    private var hasBaselineTick = false
    private var dayLog: DayLog
    private let resolver = AppResolver()
    private var blocked: Set<String>
    private var samplerTask: Task<Void, Never>?
    private var ticks = 0
    private var todayKey = DayLog.dayKey(for: Date())

    /// Tests and previews inject rows directly; the sampler only runs via `start()`.
    init(apps: [AppUsage] = [], dayLog: DayLog = DayLog()) {
        self.blocked = Set(Self.blockDefaults.stringArray(forKey: Self.blockedKey) ?? [])
        self.apps = apps
        self.dayLog = dayLog
        self.dailyLimitBytes = Int64(UserDefaults.standard.integer(forKey: Self.dailyLimitKey))
        self.todayTotalBytes = computedTodayTotal()
    }

    static func live() -> UsageStore {
        let store = UsageStore()
        store.start()
        return store
    }

    func start() {
        guard samplerTask == nil else { return }
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.dayLog.saveIfDirty() }
        }
        samplerTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                let procs = NettopParser.parse(NettopSampler.sample())
                await MainActor.run { self?.apply(procs) }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    deinit {
        samplerTask?.cancel()
    }

    // MARK: - Accounting

    /// Folds one nettop sample into session, host, and day tallies.
    /// Deltas are tracked per connection: socket counters are monotonic over the
    /// socket's lifetime, unlike process rows which shrink when sockets close.
    func apply(_ procs: [ProcSample]) {
        // An empty sample means nettop failed or Wi-Fi blipped — not "no traffic".
        // Treating it as data would drop every baseline and re-count entire socket
        // lifetimes on the next tick (wildly exaggerated usage).
        guard !procs.isEmpty else { return }

        var tickTotal: Int64 = 0
        for proc in procs {
            var deltaIn: Int64 = 0
            var deltaOut: Int64 = 0
            var hostDeltas: [(host: String, bytesIn: Int64, bytesOut: Int64)] = []

            for conn in proc.connections {
                // Internet usage only: skip LAN, multicast, and wildcard sockets
                // (mDNS, phone-to-Mac transfers, AirPlay…).
                guard let host = conn.remoteHost, NettopParser.isInternetHost(host) else { continue }

                let key = "\(proc.pid)|\(conn.connID)"
                let prev = baselines[key]
                baselines[key] = Baseline(bytesIn: conn.bytesIn, bytesOut: conn.bytesOut, lastSeen: ticks)

                var connIn: Int64 = 0
                var connOut: Int64 = 0
                if let prev {
                    // Counters are monotonic per socket; a shrink means the socket was
                    // replaced or nettop glitched — rebaseline without counting.
                    connIn = max(0, conn.bytesIn - prev.bytesIn)
                    connOut = max(0, conn.bytesOut - prev.bytesOut)
                } else if hasBaselineTick {
                    // Socket opened since the last tick — everything it carried is new.
                    connIn = conn.bytesIn
                    connOut = conn.bytesOut
                }
                // ponytail: sockets that open and close entirely between two ticks are
                // never seen; per-flow capture needs the NE filter extension.

                deltaIn += connIn
                deltaOut += connOut
                if connIn + connOut > 0 {
                    hostDeltas.append((host, connIn, connOut))
                }
            }

            guard deltaIn + deltaOut > 0 else { continue }
            tickTotal += deltaIn + deltaOut
            let identity = resolver.identity(pid: proc.pid, procName: proc.procName)
            session[identity.id, default: Tally(name: identity.name)].bytesIn += deltaIn
            session[identity.id, default: Tally(name: identity.name)].bytesOut += deltaOut

            var hosts = hostTallies[identity.id] ?? [:]
            for delta in hostDeltas {
                hosts[delta.host, default: HostUsage(host: delta.host, bytesIn: 0, bytesOut: 0)].bytesIn += delta.bytesIn
                hosts[delta.host, default: HostUsage(host: delta.host, bytesIn: 0, bytesOut: 0)].bytesOut += delta.bytesOut
            }
            // ponytail: cap host map at 100 entries per app, evicting the smallest.
            if hosts.count > 100 {
                for small in hosts.values.sorted(by: { $0.totalBytes < $1.totalBytes }).prefix(hosts.count - 100) {
                    hosts.removeValue(forKey: small.host)
                }
            }
            hostTallies[identity.id] = hosts

            dayLog.add(id: identity.id, name: identity.name, bytesIn: deltaIn, bytesOut: deltaOut)
        }

        hasBaselineTick = true
        // ponytail: 60-tick grace before dropping a baseline — nettop omits rows
        // transiently, and instant pruning re-counts socket lifetimes on return.
        baselines = baselines.filter { ticks - $0.value.lastSeen <= 60 }
        ticks += 1
        if ticks.isMultiple(of: 30) { dayLog.saveIfDirty() }

        // Cached so the per-tick and per-render paths don't rescan the whole log.
        let day = DayLog.dayKey(for: Date())
        if day == todayKey {
            todayTotalBytes += tickTotal
        } else { // midnight rollover: this tick's deltas already landed in the new day
            todayKey = day
            todayTotalBytes = computedTodayTotal()
        }

        rebuild()
        checkDailyLimit(todayTotal: todayTotalBytes)
    }

    // MARK: - Daily limit

    private(set) var todayTotalBytes: Int64 = 0

    private func computedTodayTotal() -> Int64 {
        dayLog.totals(for: .today).values.reduce(0) { $0 + $1.bytesIn + $1.bytesOut }
    }

    var overLimit: Bool {
        dailyLimitBytes > 0 && todayTotalBytes >= dailyLimitBytes
    }

    /// Posts at most one "limit reached" notification per calendar day.
    func checkDailyLimit(todayTotal: Int64) {
        guard dailyLimitBytes > 0, todayTotal >= dailyLimitBytes else { return }
        let day = DayLog.dayKey(for: Date())
        guard UserDefaults.standard.string(forKey: Self.limitNotifiedDayKey) != day else { return }
        UserDefaults.standard.set(day, forKey: Self.limitNotifiedDayKey)
        notify("Daily data limit reached",
               "\(todayTotal.byteString) used of your \(dailyLimitBytes.byteString) daily limit.")
    }

    private func rebuild() {
        let rows: [String: Tally]
        switch window {
        case .live:
            rows = session
        default:
            rows = dayLog.totals(for: window).mapValues {
                Tally(name: $0.name, bytesIn: $0.bytesIn, bytesOut: $0.bytesOut)
            }
        }
        apps = rows.map { id, tally in
            AppUsage(id: id, name: tally.name, icon: resolver.icon(forAppID: id),
                     bytesIn: tally.bytesIn, bytesOut: tally.bytesOut,
                     isBlocked: blocked.contains(id))
        }
    }

    // MARK: - UI queries

    var sortedApps: [AppUsage] {
        switch sortMode {
        case .usage: apps.sorted { $0.totalBytes > $1.totalBytes }
        case .name: apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    var totalBytes: Int64 {
        apps.reduce(0) { $0 + $1.totalBytes }
    }

    var maxBytes: Int64 {
        apps.map(\.totalBytes).max() ?? 0
    }

    /// Top remote hosts for an app, session-scoped.
    func hostUsage(for id: String) -> [HostUsage] {
        (hostTallies[id]?.values).map { $0.sorted { $0.totalBytes > $1.totalBytes } } ?? []
    }

    // MARK: - Reports

    /// Today → 24 hourly buckets; This week → 7 daily buckets (oldest first).
    func reportBuckets(for scope: ReportScope) -> [ReportBucket] {
        switch scope {
        case .today:
            return dayLog.hourlyBuckets(forDay: DayLog.dayKey(for: Date())).map { hour, entries in
                ReportBucket(key: String(hour),
                             title: String(format: "%02d:00–%02d:00", hour, (hour + 1) % 24),
                             apps: reportApps(from: entries))
            }
        case .week:
            return dayLog.dailyBuckets(lastNDays: 7).map { dayKey, entries in
                let date = DayLog.date(fromDayKey: dayKey) ?? Date()
                return ReportBucket(key: date.formatted(.dateTime.weekday(.abbreviated)),
                                    title: date.formatted(.dateTime.weekday(.wide)),
                                    apps: reportApps(from: entries))
            }
        }
    }

    /// Busiest bucket in the scope, with its top app and that app's share. Nil when no data.
    func peakSummary(for scope: ReportScope) -> PeakSummary? {
        guard let peak = reportBuckets(for: scope).max(by: { $0.totalBytes < $1.totalBytes }),
              peak.totalBytes > 0,
              let top = peak.apps.max(by: { $0.totalBytes < $1.totalBytes }) else { return nil }
        return PeakSummary(bucketTitle: peak.title, totalBytes: peak.totalBytes,
                           topAppName: top.name,
                           share: Double(top.totalBytes) / Double(peak.totalBytes))
    }

    private func reportApps(from entries: [String: DayLog.Entry]) -> [AppUsage] {
        entries.map { id, entry in
            AppUsage(id: id, name: entry.name, icon: resolver.icon(forAppID: id),
                     bytesIn: entry.bytesIn, bytesOut: entry.bytesOut)
        }
    }

    func toggleBlock(_ id: String) {
        if !blocked.insert(id).inserted { blocked.remove(id) }
        Self.blockDefaults.set(Array(blocked).sorted(), forKey: Self.blockedKey)
        rebuild()
    }

    func resetStatistics() {
        session.removeAll()
        hostTallies.removeAll()
        baselines.removeAll()
        hasBaselineTick = false
        rebuild()
    }

    nonisolated static let sample: [AppUsage] = [
        AppUsage(id: "com.example.browser", name: "Safari", icon: nil, bytesIn: 1_180_000_000, bytesOut: 64_000_000),
        AppUsage(id: "com.example.build", name: "Xcode", icon: nil, bytesIn: 2_040_000_000, bytesOut: 31_000_000),
        AppUsage(id: "com.example.music", name: "Music", icon: nil, bytesIn: 774_000_000, bytesOut: 6_200_000),
        AppUsage(id: "com.example.mail", name: "Mail", icon: nil, bytesIn: 310_000_000, bytesOut: 28_000_000),
        AppUsage(id: "com.example.terminal", name: "Terminal", icon: nil, bytesIn: 9_400_000, bytesOut: 2_700_000),
    ]
}

extension Int64 {
    var byteString: String {
        self.formatted(.byteCount(style: .file))
    }
}
