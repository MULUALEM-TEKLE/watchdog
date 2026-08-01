//
//  EngineTests.swift
//  watchdogTests
//
//  Created by Mulualem Tekle on 21/07/2026.
//

import Testing
import Foundation
@testable import watchdog

struct NettopParserTests {

    // Real captured output: nettop -x -n -L 1 -t wifi -J time,interface,state,bytes_in,bytes_out
    static let fixture = """
    time,,interface,state,bytes_in,bytes_out,
    21:52:17.589736,apsd.603,,,5539,14138,
    21:52:17.587623,tcp4 192.168.143.111:62071<->17.57.146.183:5223,en0,Established,5539,14138,
    21:52:17.589745,mDNSResponder.682,,,58296951,12638063,
    21:52:17.587294,udp6 *.5353<->*.*,en0,,27025905,4296097,
    21:52:17.587274,udp4 *:5353<->*:*,en0,,31271046,8341966,
    21:52:17.589774,Arc.9968,,,2655389,1048992,
    21:52:17.587828,tcp4 192.168.143.111:50550<->142.250.202.42:443,en0,Established,2501480,1004666,
    21:52:17.587229,quic4 192.168.143.111:50938<->34.160.81.0:443,en0,,4848,7953,
    21:52:17.541757,2.1.214.25998,,,15813,197278,
    21:52:17.541764,Code Helper (Pl.52543,,,16022,5621,
    garbage line without commas
    21:52:17.589804,Truncated row,en0
    """

    @Test func parsesRealFixture() {
        let procs = NettopParser.parse(Self.fixture)

        #expect(procs.count == 5)

        #expect(procs[0].procName == "apsd")
        #expect(procs[0].pid == 603)
        #expect(procs[0].bytesIn == 5539)
        #expect(procs[0].bytesOut == 14138)
        #expect(procs[0].connections.count == 1)
        #expect(procs[0].connections[0].remoteHost == "17.57.146.183")

        // Wildcard multicast sockets keep their bytes but have no remote host.
        #expect(procs[1].procName == "mDNSResponder")
        #expect(procs[1].connections.count == 2)
        #expect(procs[1].connections.allSatisfy { $0.remoteHost == nil })

        #expect(procs[2].procName == "Arc")
        #expect(procs[2].connections.map(\.remoteHost) == ["142.250.202.42", "34.160.81.0"])

        // Process names can contain dots — pid is after the LAST dot.
        #expect(procs[3].procName == "2.1.214")
        #expect(procs[3].pid == 25998)
    }

    @Test func parsesTruncatedParenName() {
        let procs = NettopParser.parse("21:52:17.541764,Code Helper (Pl.52543,,,16022,5621,")
        #expect(procs.count == 1)
        #expect(procs[0].procName == "Code Helper (Pl")
        #expect(procs[0].pid == 52543)
    }

    @Test func classifiesInternetHosts() {
        #expect(NettopParser.isInternetHost("8.8.8.8"))
        #expect(NettopParser.isInternetHost("142.250.202.42"))
        #expect(NettopParser.isInternetHost("172.32.0.1"))
        #expect(NettopParser.isInternetHost("100.128.0.1")) // just above CGNAT range
        #expect(NettopParser.isInternetHost("2607:f8b0::200e"))
        #expect(NettopParser.isInternetHost("::ffff:8.8.8.8"))

        #expect(!NettopParser.isInternetHost("192.168.1.4"))
        #expect(!NettopParser.isInternetHost("10.0.0.1"))
        #expect(!NettopParser.isInternetHost("172.16.9.1"))
        #expect(!NettopParser.isInternetHost("169.254.1.1"))
        #expect(!NettopParser.isInternetHost("100.64.0.1"))   // CGNAT (RFC 6598)
        #expect(!NettopParser.isInternetHost("100.100.1.1"))  // Tailscale peer
        #expect(!NettopParser.isInternetHost("::ffff:192.168.1.5"))
        #expect(!NettopParser.isInternetHost("127.0.0.1"))
        #expect(!NettopParser.isInternetHost("224.0.0.251"))
        #expect(!NettopParser.isInternetHost("255.255.255.255"))
        #expect(!NettopParser.isInternetHost("fe80::1"))
        #expect(!NettopParser.isInternetHost("fd00::5"))
        #expect(!NettopParser.isInternetHost("ff02::fb"))
        #expect(!NettopParser.isInternetHost("::1"))
    }

    @Test func extractsIPv6RemoteHost() {
        // IPv6 uses "." before the port; IPv4 uses ":".
        #expect(NettopParser.remoteHost(from: "tcp6 2a00::1.50550<->2607:f8b0::200e.443") == "2607:f8b0::200e")
        #expect(NettopParser.remoteHost(from: "tcp4 1.2.3.4:50550<->5.6.7.8:443") == "5.6.7.8")
        #expect(NettopParser.remoteHost(from: "udp4 *:5353<->*:*") == nil)
    }
}

@MainActor
struct DayLogTests {

    @Test func hourlyBucketsAndTotals() {
        var log = DayLog(hours: [:])
        log.add(id: "a", name: "AppA", bytesIn: 100, bytesOut: 10)
        log.add(id: "a", name: "AppA", bytesIn: 50, bytesOut: 5)
        log.add(id: "b", name: "AppB", bytesIn: 7, bytesOut: 3)

        let buckets = log.hourlyBuckets(forDay: DayLog.dayKey(for: Date()))
        #expect(buckets.count == 24)
        #expect(buckets.map(\.hour) == Array(0..<24))

        let nonEmpty = buckets.filter { !$0.entries.isEmpty }
        #expect(nonEmpty.count == 1)
        #expect(nonEmpty[0].hour == Calendar.current.component(.hour, from: Date()))
        #expect(nonEmpty[0].entries["a"]?.bytesIn == 150)
        #expect(nonEmpty[0].entries["a"]?.bytesOut == 15)
        #expect(nonEmpty[0].entries["b"]?.bytesIn == 7)

        // totals(for:) keeps its day/week/month semantics over hour buckets.
        #expect(log.totals(for: .today)["a"]?.bytesIn == 150)
        #expect(log.totals(for: .today)["b"]?.bytesOut == 3)
        #expect(log.totals(for: .week)["a"]?.bytesIn == 150)
        #expect(log.totals(for: .month)["a"]?.bytesOut == 15)
        #expect(log.totals(for: .live).isEmpty)
    }

    @Test func pruneDropsOldBuckets() {
        var log = DayLog(hours: [
            "2020-01-01 10": ["a": .init(name: "AppA", bytesIn: 1, bytesOut: 1)],
            DayLog.hourKey(for: Date()): ["b": .init(name: "AppB", bytesIn: 2, bytesOut: 2)],
        ])
        log.prune()
        #expect(log.hours.count == 1)
        #expect(log.hours[DayLog.hourKey(for: Date())]?["b"] != nil)
    }

    @Test func dailyBucketsMergePerDay() {
        var log = DayLog(hours: [:])
        log.add(id: "a", name: "AppA", bytesIn: 20, bytesOut: 2)

        let days = log.dailyBuckets(lastNDays: 7)
        #expect(days.count == 7)
        #expect(days.last?.dayKey == DayLog.dayKey(for: Date()))
        #expect(days.last?.entries["a"]?.bytesIn == 20)
        #expect(days.dropLast().allSatisfy { $0.entries.isEmpty })
    }
}

@MainActor
struct UsageStoreDeltaTests {

    private func proc(_ pid: Int32, _ name: String, conns: [(id: String, bytesIn: Int64, bytesOut: Int64)]) -> ProcSample {
        ProcSample(pid: pid, procName: name,
                   bytesIn: conns.reduce(0) { $0 + $1.bytesIn },
                   bytesOut: conns.reduce(0) { $0 + $1.bytesOut },
                   connections: conns.map {
                       ConnSample(connID: $0.id, remoteHost: "1.2.3.4", bytesIn: $0.bytesIn, bytesOut: $0.bytesOut)
                   })
    }

    @Test func firstTickOnlyBaselines() {
        let store = UsageStore()
        store.apply([proc(99999, "fake", conns: [("c1", 5000, 1000)])])
        // Pre-existing cumulative counters must not count as fresh usage.
        #expect(store.totalBytes == 0)
    }

    @Test func growthCountsAsDelta() {
        let store = UsageStore()
        store.apply([proc(99999, "fake", conns: [("c1", 5000, 1000)])])
        store.apply([proc(99999, "fake", conns: [("c1", 7500, 1200)])])
        #expect(store.totalBytes == 2700)
        #expect(store.apps.first?.bytesIn == 2500)
        #expect(store.apps.first?.bytesOut == 200)
    }

    @Test func newSocketAfterBaselineCountsFully() {
        let store = UsageStore()
        store.apply([proc(99999, "fake", conns: [("c1", 100, 100)])])
        store.apply([proc(99999, "fake", conns: [("c1", 100, 100), ("c2", 300, 50)])])
        #expect(store.totalBytes == 350)
    }

    @Test func shrunkCounterRebaselinesWithoutCounting() {
        let store = UsageStore()
        store.apply([proc(99999, "fake", conns: [("c1", 5000, 1000)])])
        // Shrink = replaced socket or nettop glitch: never count, just rebaseline.
        store.apply([proc(99999, "fake", conns: [("c1", 300, 40)])])
        #expect(store.totalBytes == 0)
        store.apply([proc(99999, "fake", conns: [("c1", 800, 40)])])
        #expect(store.totalBytes == 500)
    }

    @Test func vanishedSocketKeepsBaselineWithinGrace() {
        let store = UsageStore()
        store.apply([proc(99999, "fake", conns: [("c1", 5000, 1000)])])
        // c1 transiently missing from a sample must NOT re-count its lifetime later.
        store.apply([proc(88888, "other", conns: [("c9", 0, 0)])])
        store.apply([proc(99999, "fake", conns: [("c1", 5400, 1000)])])
        #expect(store.totalBytes == 400)
    }

    @Test func expiredBaselineRecountsFully() {
        let store = UsageStore()
        store.apply([proc(99999, "fake", conns: [("c1", 100, 0)])])
        for _ in 0..<61 {
            store.apply([proc(88888, "other", conns: [("c9", 0, 0)])])
        }
        // Baseline aged out of the 60-tick grace: reappearing tuple is a new socket.
        store.apply([proc(99999, "fake", conns: [("c1", 150, 0)])])
        #expect(store.totalBytes == 150)
    }

    @Test func emptySampleIsIgnored() {
        let store = UsageStore()
        store.apply([proc(99999, "fake", conns: [("c1", 5000, 1000)])])
        // nettop failure / Wi-Fi blip: must not reset baselines.
        store.apply([])
        store.apply([proc(99999, "fake", conns: [("c1", 5400, 1200)])])
        #expect(store.totalBytes == 600)
    }

    @Test func localTrafficIsIgnored() {
        let store = UsageStore()
        let lan = ProcSample(pid: 99999, procName: "fake", bytesIn: 0, bytesOut: 0, connections: [
            ConnSample(connID: "l1", remoteHost: "192.168.1.50", bytesIn: 100, bytesOut: 100),
            ConnSample(connID: "l2", remoteHost: nil, bytesIn: 100, bytesOut: 100),
        ])
        store.apply([lan])
        let lanGrown = ProcSample(pid: 99999, procName: "fake", bytesIn: 0, bytesOut: 0, connections: [
            ConnSample(connID: "l1", remoteHost: "192.168.1.50", bytesIn: 9000, bytesOut: 9000),
            ConnSample(connID: "l2", remoteHost: nil, bytesIn: 9000, bytesOut: 9000),
        ])
        store.apply([lanGrown])
        #expect(store.totalBytes == 0)
        #expect(store.apps.isEmpty)
    }

    @Test func limitCrossingNotifiesOncePerDay() {
        let defaults = UserDefaults.standard
        let saved = ["dailyLimitBytes", "dailyLimitNotifiedDay"].map { ($0, defaults.object(forKey: $0)) }
        defer { for (key, value) in saved { defaults.set(value, forKey: key) } }
        defaults.removeObject(forKey: "dailyLimitNotifiedDay")

        let store = UsageStore()
        var posts = 0
        store.notify = { _, _ in posts += 1 }
        store.dailyLimitBytes = 1_000

        store.checkDailyLimit(todayTotal: 500)
        #expect(posts == 0)
        store.checkDailyLimit(todayTotal: 1_200)
        #expect(posts == 1)
        // Still over on later ticks the same day: no repeat.
        store.checkDailyLimit(todayTotal: 2_000)
        #expect(posts == 1)
    }

    @Test func raisedLimitRearmsDailyNotification() {
        let defaults = UserDefaults.standard
        let saved = ["dailyLimitBytes", "dailyLimitNotifiedDay"].map { ($0, defaults.object(forKey: $0)) }
        defer { for (key, value) in saved { defaults.set(value, forKey: key) } }
        defaults.removeObject(forKey: "dailyLimitNotifiedDay")

        let store = UsageStore()
        var posts = 0
        store.notify = { _, _ in posts += 1 }
        store.dailyLimitBytes = 1_000
        store.checkDailyLimit(todayTotal: 1_200)
        #expect(posts == 1)
        // Raising the limit re-arms the once-per-day alert for the new threshold.
        store.dailyLimitBytes = 5_000
        store.checkDailyLimit(todayTotal: 4_000)
        #expect(posts == 1)
        store.checkDailyLimit(todayTotal: 6_000)
        #expect(posts == 2)
    }

    @Test func todayTotalIsCachedIncrementally() {
        // Seeded from the log at init…
        let seeded = UsageStore(dayLog: DayLog(hours: [
            DayLog.hourKey(for: Date()): ["a": .init(name: "AppA", bytesIn: 40, bytesOut: 2)],
        ]))
        #expect(seeded.todayTotalBytes == 42)

        // …then tracked from per-tick deltas without rescanning.
        let store = UsageStore(dayLog: DayLog(hours: [:]))
        store.apply([proc(99999, "fake", conns: [("c1", 100, 0)])])
        #expect(store.todayTotalBytes == 0) // first tick only baselines
        store.apply([proc(99999, "fake", conns: [("c1", 600, 100)])])
        #expect(store.todayTotalBytes == 600)
    }

    @Test func hostUsageAggregates() {
        let store = UsageStore()
        store.apply([proc(99999, "fake", conns: [("c1", 0, 0)])])
        store.apply([proc(99999, "fake", conns: [("c1", 900, 100)])])
        let hosts = store.hostUsage(for: store.apps.first!.id)
        #expect(hosts.count == 1)
        #expect(hosts[0].host == "1.2.3.4")
        #expect(hosts[0].bytesIn == 900)
        #expect(hosts[0].bytesOut == 100)
    }
}
