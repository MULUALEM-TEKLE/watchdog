//
//  DayLog.swift
//  watchdog
//
//  Created by Mulualem Tekle on 21/07/2026.
//
//  Per-hour usage totals persisted as JSON so Today / This week / This month
//  survive relaunches, and Reports can chart usage over time.
//  Buckets are keyed "YYYY-MM-DD HH".
//

import Foundation

struct DayLog {
    struct Entry: Codable {
        var name: String
        var bytesIn: Int64
        var bytesOut: Int64
    }

    private(set) var hours: [String: [String: Entry]] = [:]
    private var dirty = false

    static let fileURL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Watchdog/usage.json")

    /// In-memory log for tests and previews; `init()` loads from disk.
    init(hours: [String: [String: Entry]]) {
        self.hours = hours
    }

    init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let loaded = try? JSONDecoder().decode([String: [String: Entry]].self, from: data) {
            // ponytail: old day-keyed files ("YYYY-MM-DD") decode to the same type;
            // drop non-hour keys instead of migrating one evening of dev data.
            hours = loaded.filter { $0.key.count == 13 }
            prune()
        }
    }

    /// Drops buckets older than a year so totals() scans and the JSON file stay
    /// bounded, while "usage since install" reports keep a full year of history.
    mutating func prune(asOf now: Date = Date()) {
        let cutoff = Self.dayKey(for: now.addingTimeInterval(-366 * 86_400))
        // "YYYY-MM-DD HH" keys sort lexicographically, so string compare works.
        hours = hours.filter { $0.key >= cutoff }
    }

    mutating func add(id: String, name: String, bytesIn: Int64, bytesOut: Int64) {
        let hour = Self.hourKey(for: Date())
        hours[hour, default: [:]][id, default: Entry(name: name, bytesIn: 0, bytesOut: 0)].bytesIn += bytesIn
        hours[hour, default: [:]][id, default: Entry(name: name, bytesIn: 0, bytesOut: 0)].bytesOut += bytesOut
        dirty = true
    }

    /// Merged per-app totals for the given window (today / this week / this month).
    func totals(for window: UsageWindow) -> [String: Entry] {
        let calendar = Calendar.current
        let now = Date()
        var merged: [String: Entry] = [:]
        for (hour, entries) in hours {
            guard let date = Self.date(fromDayKey: String(hour.prefix(10))) else { continue }
            let matches = switch window {
            case .live: false
            case .today: calendar.isDate(date, inSameDayAs: now)
            case .week: calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear)
            case .month: calendar.isDate(date, equalTo: now, toGranularity: .month)
            }
            guard matches else { continue }
            Self.merge(entries, into: &merged)
        }
        return merged
    }

    /// All 24 hour buckets of a day, in order; quiet hours are empty dicts.
    func hourlyBuckets(forDay dayKey: String) -> [(hour: Int, entries: [String: Entry])] {
        (0..<24).map { h in (h, hours[String(format: "%@ %02d", dayKey, h)] ?? [:]) }
    }

    /// Per-day merged buckets for the last n days, oldest first, ending today.
    func dailyBuckets(lastNDays n: Int) -> [(dayKey: String, entries: [String: Entry])] {
        let calendar = Calendar.current
        return (0..<n).reversed().map { back in
            let date = calendar.date(byAdding: .day, value: -back, to: Date()) ?? Date()
            let day = Self.dayKey(for: date)
            var merged: [String: Entry] = [:]
            for (_, entries) in hourlyBuckets(forDay: day) {
                Self.merge(entries, into: &merged)
            }
            return (day, merged)
        }
    }

    mutating func saveIfDirty() {
        guard dirty else { return }
        prune()
        guard let data = try? JSONEncoder().encode(hours) else { return }
        let dir = Self.fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: Self.fileURL, options: .atomic)
        dirty = false
    }

    private static func merge(_ entries: [String: Entry], into merged: inout [String: Entry]) {
        for (id, entry) in entries {
            merged[id, default: Entry(name: entry.name, bytesIn: 0, bytesOut: 0)].bytesIn += entry.bytesIn
            merged[id, default: Entry(name: entry.name, bytesIn: 0, bytesOut: 0)].bytesOut += entry.bytesOut
        }
    }

    static func dayKey(for date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func hourKey(for date: Date) -> String {
        let hour = Calendar.current.component(.hour, from: date)
        return String(format: "%@ %02d", dayKey(for: date), hour)
    }

    static func date(fromDayKey key: String) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}
