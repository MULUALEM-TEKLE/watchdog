# App Store Sandbox Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Re-architect Watchdog so the app runs fully App-Sandboxed with all per-app traffic data supplied (and blocking enforced) by an `NEFilterDataProvider` system extension, plus every metadata/consent change needed to pass Mac App Store review.

**Architecture:** Today the app is unsandboxed and polls `nettop` + `proc_pidpath` — both impossible inside the sandbox, and sandbox-off is an automatic App Store rejection. The replacement: the filter extension observes every socket flow (signing identity, remote endpoint, byte counts via `NEFilterReport`), aggregates per-app cumulative counters, and serves `StatsSnapshot` JSON to the app over XPC (`NEMachServiceName`); the sandboxed app polls snapshots, converts them to deltas, and feeds the existing `UsageStore` → `DayLog` → UI pipeline, which survives unchanged. Blocking becomes real (drop verdicts) with the block list delivered via `NEFilterProviderConfiguration.vendorConfiguration`.

**Tech Stack:** Swift 6 (Swift 5 language mode, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`), SwiftUI + MenuBarExtra, NetworkExtension (NEFilterDataProvider system extension), Swift Testing (`import Testing`), no third-party dependencies.

## Global Constraints

- Repo: `/Users/xar/developer/x-code-dev/watchdog`; Xcode project `watchdog.xcodeproj`, scheme `watchdog`.
- Build: `xcodebuild -project watchdog.xcodeproj -scheme watchdog -configuration Debug build 2>&1 | tail -5` → must end `** BUILD SUCCEEDED **`.
- Tests: `xcodebuild -project watchdog.xcodeproj -scheme watchdog -destination "platform=macOS" -only-testing:watchdogTests test 2>&1 | tail -30` → must end with all tests passed / `** TEST SUCCEEDED **`.
- Folder-synchronized groups: any `.swift` file created in `watchdog/` auto-compiles into the app target; files in `watchdogTests/` into the unit-test target. Files in `WatchdogFilterExtension/` compile into NOTHING until a human wires the extension target (Task H2) — subagents must never add that folder to a target.
- Swift Testing only (`import Testing`, `@Test`, `#expect`) — never XCTest.
- Project-wide default actor isolation is MainActor: anything that must run off-main needs explicit `nonisolated`; follow existing patterns.
- No new dependencies. No `Process(...)`, `posix_spawn`, `proc_pidpath`, or libproc anywhere in `watchdog/` when this plan is complete.
- Do not change `PRODUCT_BUNDLE_IDENTIFIER` (`xar.watchdog`) — the human sets the final ID at signing time (Task H1).
- Placeholder identifiers used throughout (human replaces in Task H1/H2): app group `group.watchdog.shared`, mach service `group.watchdog.shared.stats`.
- Commit after every task: `git add -A && git commit -m "<message given in the task>"`.
- Tasks H1–H4 are HUMAN-ONLY (Apple account, Xcode GUI, System Settings). Subagents must skip them and never attempt workarounds.

---

### Task 0: Baseline commit

**Files:** none modified.

- [ ] **Step 1: Verify green baseline**

Run: build + tests (Global Constraints commands). Expected: BUILD SUCCEEDED, TEST SUCCEEDED (22+ tests).

- [ ] **Step 2: Commit everything currently uncommitted**

```bash
cd /Users/xar/developer/x-code-dev/watchdog
git add -A
git commit -m "chore: baseline before App Store sandbox migration (nettop architecture, v1)"
```

---

### Task 1: Shared wire format (`SharedStats.swift`)

**Files:**
- Create: `watchdog/SharedStats.swift`
- Modify: `watchdog/NettopSampler.swift` (delete `isInternetHost` from `NettopParser`)
- Modify: `watchdog/UsageModel.swift:178` (call site `NettopParser.isInternetHost` → `NetClassify.isInternetHost`)
- Modify: `watchdogTests/EngineTests.swift` (`classifiesInternetHosts` test: `NettopParser.` → `NetClassify.`)

**Interfaces:**
- Produces: `struct StatsSnapshot: Codable` (`bootID: UUID`, `seq: UInt64`, `generatedAt: Date`, `apps: [String: StatsSnapshot.AppStat]`), `StatsSnapshot.AppStat` (`bytesIn/bytesOut: Int64`, `hosts: [String: StatsSnapshot.HostStat]`), `StatsSnapshot.HostStat` (`bytesIn/bytesOut: Int64`), `enum SharedStats` constants (`appGroupID`, `machServiceName`, `snapshotFilename`, `vendorKeyBlockedAppIDs`, `vendorKeyWifiOnly`, `snapshotFileURL`), `enum NetClassify { static func isInternetHost(_ host: String) -> Bool }`, `@objc protocol WatchdogStatsXPC`.
- Consumed by: every later task.

- [ ] **Step 1: Write the failing test** — append to `watchdogTests/EngineTests.swift`:

```swift
struct SharedStatsTests {
    @Test func snapshotRoundTrips() throws {
        let snap = StatsSnapshot(
            bootID: UUID(), seq: 7, generatedAt: Date(timeIntervalSince1970: 1_000_000),
            apps: ["com.apple.Safari": .init(bytesIn: 10, bytesOut: 2,
                                             hosts: ["1.2.3.4": .init(bytesIn: 10, bytesOut: 2)])])
        let data = try JSONEncoder().encode(snap)
        let back = try JSONDecoder().decode(StatsSnapshot.self, from: data)
        #expect(back == snap)
        #expect(back.apps["com.apple.Safari"]?.hosts["1.2.3.4"]?.bytesIn == 10)
    }
}
```

- [ ] **Step 2: Run tests, verify the new test FAILS to compile** (`Cannot find 'StatsSnapshot'`).

- [ ] **Step 3: Create `watchdog/SharedStats.swift`**

```swift
//
//  SharedStats.swift
//  watchdog
//
//  Wire format + shared constants between the app and the filter extension.
//  This file must also be added to the WatchdogFilterExtension target when the
//  human wires it in Xcode (Task H2).
//

import Foundation

/// Cumulative per-app counters since the extension launched (`bootID` changes
/// on every extension restart; consumers rebaseline when it does).
struct StatsSnapshot: Codable, Equatable, Sendable {
    struct AppStat: Codable, Equatable, Sendable {
        var bytesIn: Int64
        var bytesOut: Int64
        var hosts: [String: HostStat]
    }

    struct HostStat: Codable, Equatable, Sendable {
        var bytesIn: Int64
        var bytesOut: Int64
    }

    var bootID: UUID
    var seq: UInt64
    var generatedAt: Date
    /// Keyed by code-signing identifier (== bundle id for bundled apps).
    var apps: [String: AppStat]
}

enum SharedStats {
    /// Placeholders — replaced with team-prefixed values in Task H1.
    static let appGroupID = "group.watchdog.shared"
    /// NEMachServiceName must be prefixed by an app group of the extension.
    static let machServiceName = "group.watchdog.shared.stats"
    static let snapshotFilename = "stats-snapshot.json"
    static let vendorKeyBlockedAppIDs = "blockedAppIDs"
    static let vendorKeyWifiOnly = "wifiOnly"

    /// Development/e2e fallback transport: a JSON file the fake feed writes and
    /// the app reads when no extension XPC connection is available. Lives in
    /// the app's own container so it works sandboxed and unprovisioned.
    static var snapshotFileURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Watchdog/\(snapshotFilename)")
    }
}

/// XPC surface the extension exports; the app fetches JSON-encoded StatsSnapshot.
@objc protocol WatchdogStatsXPC {
    func fetchSnapshot(reply: @escaping @Sendable (Data?) -> Void)
}

enum NetClassify {
    /// True when the address is a routable public-internet host. Private ranges,
    /// link-local, loopback, multicast, CGNAT, and IPv6 unique-local are LAN
    /// traffic (phone transfers, mDNS, AirPlay…), not internet usage.
    nonisolated static func isInternetHost(_ host: String) -> Bool {
        if host.contains(":") { // IPv6
            let h = host.lowercased()
            if h.hasPrefix("::ffff:") { return isInternetHost(String(h.dropFirst(7))) }
            if h == "::" || h == "::1" { return false }
            if h.hasPrefix("fe8") || h.hasPrefix("fe9") || h.hasPrefix("fea") || h.hasPrefix("feb") { return false }
            if h.hasPrefix("fc") || h.hasPrefix("fd") || h.hasPrefix("ff") { return false }
            return true
        }
        let octets = host.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4 else { return false } // unrecognized format: don't count it
        switch (octets[0], octets[1]) {
        case (10, _), (127, _), (169, 254), (192, 168): return false
        case (172, 16...31): return false
        case (100, 64...127): return false // CGNAT (RFC 6598) — Tailscale peers etc.
        case (0, _): return false
        default: return octets[0] < 224 // multicast / reserved / broadcast
        }
    }
}
```

- [ ] **Step 4: Move call sites off `NettopParser.isInternetHost`**
  - In `watchdog/NettopSampler.swift`: delete the whole `isInternetHost` function from `NettopParser`.
  - In `watchdog/UsageModel.swift` (inside `apply`, the guard around `conn.remoteHost`): replace `NettopParser.isInternetHost(host)` with `NetClassify.isInternetHost(host)`.
  - In `watchdogTests/EngineTests.swift` `classifiesInternetHosts()`: replace every `NettopParser.isInternetHost` with `NetClassify.isInternetHost`.

- [ ] **Step 5: Run build + tests.** Expected: all pass (23+ tests, including `snapshotRoundTrips`).

- [ ] **Step 6: Commit** — `git add -A && git commit -m "feat: shared StatsSnapshot wire format + NetClassify (extension/app contract)"`

---

### Task 2: Signing-ID-based `AppResolver`

**Files:**
- Modify: `watchdog/AppResolver.swift`
- Test: `watchdogTests/EngineTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces: `AppResolver.identity(forAppID: String) -> Identity` (sandbox-safe; no libproc). The old `identity(pid:procName:)` stays until Task 5 deletes it.

- [ ] **Step 1: Write the failing tests** — append to `watchdogTests/EngineTests.swift`:

```swift
@MainActor
struct AppResolverTests {
    @Test func resolvesInstalledBundleID() {
        let identity = AppResolver().identity(forAppID: "com.apple.Safari")
        #expect(identity.id == "com.apple.Safari")
        #expect(identity.name == "Safari")
    }

    @Test func foldsHelperIntoParentApp() {
        // Helper signing IDs extend the parent bundle id; folding strips
        // trailing components until an installed app matches.
        let identity = AppResolver().identity(forAppID: "com.apple.Safari.helper")
        #expect(identity.id == "com.apple.Safari")
    }

    @Test func unknownIDFallsBackToRawIdentity() {
        let identity = AppResolver().identity(forAppID: "com.nonexistent.zzz9x")
        #expect(identity.id == "com.nonexistent.zzz9x")
        #expect(identity.name == "zzz9x")
    }
}
```

- [ ] **Step 2: Run tests, verify the three new tests fail** (`no member 'identity(forAppID:)'`).

- [ ] **Step 3: Implement** — add to `watchdog/AppResolver.swift` (keep the existing pid method and caches untouched; add one cache + one method):

```swift
    private var byAppID: [String: Identity] = [:]

    /// Sandbox-safe resolution from a code-signing identifier (bundle id).
    /// Helper IDs ("com.google.Chrome.helper") fold into their installed
    /// parent app by stripping trailing components; unmatched IDs keep their
    /// raw id with the last component as display name.
    func identity(forAppID appID: String) -> Identity {
        if let cached = byAppID[appID] { return cached }

        var candidate = appID
        var url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: candidate)
        while url == nil,
              candidate.split(separator: ".").count > 3,
              let dot = candidate.lastIndex(of: ".") {
            candidate = String(candidate[..<dot])
            url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: candidate)
        }

        let identity: Identity
        if let url {
            identity = Identity(id: candidate,
                                name: url.deletingPathExtension().lastPathComponent,
                                appPath: url.path)
            pathByID[candidate] = url.path
        } else {
            let name = appID.split(separator: ".").last.map(String.init) ?? appID
            identity = Identity(id: appID, name: name, appPath: nil)
        }
        byAppID[appID] = identity
        return identity
    }
```

Note: the folding loop requires MORE than 3 components before stripping, so `com.apple.Safari.helper` (4) folds to `com.apple.Safari` but `com.apple.Safari` (3) is never stripped to `com.apple`. `foldsHelperIntoParentApp` relies on this exact boundary.

- [ ] **Step 4: Run build + tests.** Expected: all pass.

- [ ] **Step 5: Commit** — `git commit -am "feat: sandbox-safe AppResolver.identity(forAppID:) with helper folding"`

---

### Task 3: `UsageStore.applyDeltas` (exact-delta ingestion)

**Files:**
- Modify: `watchdog/UsageModel.swift`
- Test: `watchdogTests/EngineTests.swift`

**Interfaces:**
- Consumes: `AppResolver.identity(forAppID:)` (Task 2), `StatsSnapshot.HostStat` (Task 1).
- Produces: `struct AppDelta` (`appID: String`, `bytesIn: Int64`, `bytesOut: Int64`, `hosts: [String: StatsSnapshot.HostStat]`) and `UsageStore.applyDeltas(_ deltas: [AppDelta])`. The old `apply(_:)` stays until Task 5.

- [ ] **Step 1: Write the failing tests** — append inside `UsageStoreDeltaTests`:

```swift
    @Test func applyDeltasAccumulatesSessionAndHosts() {
        let store = UsageStore()
        let delta = AppDelta(appID: "com.nonexistent.zzz9x", bytesIn: 900, bytesOut: 100,
                             hosts: ["8.8.8.8": .init(bytesIn: 900, bytesOut: 100)])
        store.applyDeltas([delta])
        store.applyDeltas([delta])
        #expect(store.totalBytes == 2000)
        let hosts = store.hostUsage(for: "com.nonexistent.zzz9x")
        #expect(hosts.first?.host == "8.8.8.8")
        #expect(hosts.first?.bytesIn == 1800)
    }

    @Test func applyDeltasFoldsHelpersIntoOneRow() {
        let store = UsageStore()
        store.applyDeltas([AppDelta(appID: "com.apple.Safari", bytesIn: 10, bytesOut: 0, hosts: [:]),
                           AppDelta(appID: "com.apple.Safari.helper", bytesIn: 5, bytesOut: 0, hosts: [:])])
        #expect(store.apps.count == 1)
        #expect(store.apps.first?.bytesIn == 15)
    }
```

- [ ] **Step 2: Run tests, verify the two new tests fail to compile** (`Cannot find 'AppDelta'`).

- [ ] **Step 3: Implement** — in `watchdog/UsageModel.swift`, above `UsageStore`:

```swift
/// One tick's worth of fresh usage for one signing identity, already
/// delta-ified by the feed layer (extension counters are exact per flow).
struct AppDelta: Sendable, Equatable {
    let appID: String
    let bytesIn: Int64
    let bytesOut: Int64
    let hosts: [String: StatsSnapshot.HostStat]
}
```

and inside `UsageStore` (next to `apply`):

```swift
    /// Folds exact per-app deltas into session, host, and day tallies.
    func applyDeltas(_ deltas: [AppDelta]) {
        for delta in deltas {
            guard delta.bytesIn + delta.bytesOut > 0 else { continue }
            let identity = resolver.identity(forAppID: delta.appID)
            session[identity.id, default: Tally(name: identity.name)].bytesIn += delta.bytesIn
            session[identity.id, default: Tally(name: identity.name)].bytesOut += delta.bytesOut

            var hosts = hostTallies[identity.id] ?? [:]
            for (host, stat) in delta.hosts {
                hosts[host, default: HostUsage(host: host, bytesIn: 0, bytesOut: 0)].bytesIn += stat.bytesIn
                hosts[host, default: HostUsage(host: host, bytesIn: 0, bytesOut: 0)].bytesOut += stat.bytesOut
            }
            // ponytail: cap host map at 100 entries per app, evicting the smallest.
            if hosts.count > 100 {
                for small in hosts.values.sorted(by: { $0.totalBytes < $1.totalBytes }).prefix(hosts.count - 100) {
                    hosts.removeValue(forKey: small.host)
                }
            }
            hostTallies[identity.id] = hosts

            dayLog.add(id: identity.id, name: identity.name,
                       bytesIn: delta.bytesIn, bytesOut: delta.bytesOut)
            todayTotalCache += delta.bytesIn + delta.bytesOut
        }

        ticks += 1
        if ticks.isMultiple(of: 30) { dayLog.saveIfDirty() }
        rebuild()
        checkDailyLimit(todayTotal: todayTotalBytes)
    }
```

IMPORTANT: read the current `apply(_:)` implementation first and mirror its exact tail (the today-total cache variable name, `checkDailyLimit` call shape, and save cadence may have drifted — copy what `apply` does today, minus the per-connection baseline logic).

- [ ] **Step 4: Run build + tests.** Expected: all pass.

- [ ] **Step 5: Commit** — `git commit -am "feat: UsageStore.applyDeltas — exact-delta ingestion path"`

---

### Task 4: `SnapshotFeed` (snapshot → deltas, bootID rebaseline)

**Files:**
- Create: `watchdog/SnapshotFeed.swift`
- Test: `watchdogTests/EngineTests.swift`

**Interfaces:**
- Consumes: `StatsSnapshot`, `SharedStats.snapshotFileURL`, `WatchdogStatsXPC`, `SharedStats.machServiceName` (Task 1); `AppDelta` (Task 3).
- Produces: `protocol SnapshotSource { func fetch() -> StatsSnapshot? }`, `struct FileSnapshotSource: SnapshotSource`, `final class XPCSnapshotSource: SnapshotSource`, `@MainActor final class SnapshotFeed` with `init(source: SnapshotSource)`, `func poll() -> [AppDelta]`, `func start(deliver: @escaping @MainActor ([AppDelta]) -> Void)`, `func stop()`.

- [ ] **Step 1: Write the failing tests** — append to `watchdogTests/EngineTests.swift`:

```swift
final class StubSource: SnapshotSource {
    var snapshot: StatsSnapshot?
    func fetch() -> StatsSnapshot? { snapshot }
}

@MainActor
struct SnapshotFeedTests {
    private func snap(boot: UUID, seq: UInt64, bytesIn: Int64) -> StatsSnapshot {
        StatsSnapshot(bootID: boot, seq: seq, generatedAt: Date(timeIntervalSince1970: 1),
                      apps: ["com.x.a": .init(bytesIn: bytesIn, bytesOut: 0,
                                              hosts: ["8.8.8.8": .init(bytesIn: bytesIn, bytesOut: 0)])])
    }

    @Test func firstSnapshotOnlyBaselines() {
        let source = StubSource(); let feed = SnapshotFeed(source: source)
        source.snapshot = snap(boot: UUID(), seq: 1, bytesIn: 5000)
        #expect(feed.poll().isEmpty) // pre-launch cumulative history is not fresh usage
    }

    @Test func growthBecomesDelta() {
        let source = StubSource(); let feed = SnapshotFeed(source: source)
        let boot = UUID()
        source.snapshot = snap(boot: boot, seq: 1, bytesIn: 5000)
        _ = feed.poll()
        source.snapshot = snap(boot: boot, seq: 2, bytesIn: 5400)
        let deltas = feed.poll()
        #expect(deltas.count == 1)
        #expect(deltas[0].bytesIn == 400)
        #expect(deltas[0].hosts["8.8.8.8"]?.bytesIn == 400)
    }

    @Test func staleSeqIsIgnored() {
        let source = StubSource(); let feed = SnapshotFeed(source: source)
        let boot = UUID()
        source.snapshot = snap(boot: boot, seq: 2, bytesIn: 5000)
        _ = feed.poll()
        source.snapshot = snap(boot: boot, seq: 2, bytesIn: 9000) // same seq: not a new sample
        #expect(feed.poll().isEmpty)
    }

    @Test func extensionRestartRebaselines() {
        let source = StubSource(); let feed = SnapshotFeed(source: source)
        source.snapshot = snap(boot: UUID(), seq: 9, bytesIn: 5000)
        _ = feed.poll()
        source.snapshot = snap(boot: UUID(), seq: 1, bytesIn: 300) // new bootID: counters reset
        #expect(feed.poll().isEmpty) // rebaseline, never count restart cumulative
        source.snapshot = StatsSnapshot(bootID: source.snapshot!.bootID, seq: 2,
                                        generatedAt: Date(timeIntervalSince1970: 2),
                                        apps: ["com.x.a": .init(bytesIn: 350, bytesOut: 0, hosts: [:])])
        #expect(feed.poll().first?.bytesIn == 50)
    }
}
```

- [ ] **Step 2: Run tests, verify the new suite fails to compile** (`Cannot find 'SnapshotSource'`).

- [ ] **Step 3: Create `watchdog/SnapshotFeed.swift`**

```swift
//
//  SnapshotFeed.swift
//  watchdog
//
//  Converts the extension's cumulative StatsSnapshot stream into AppDeltas.
//  Rebaselines when bootID changes (extension restarted → counters reset).
//

import Foundation

protocol SnapshotSource {
    func fetch() -> StatsSnapshot?
}

/// Development / fake-feed transport: reads the JSON file at
/// SharedStats.snapshotFileURL (written by Design/fake-feed.swift or tests).
struct FileSnapshotSource: SnapshotSource {
    func fetch() -> StatsSnapshot? {
        guard let data = try? Data(contentsOf: SharedStats.snapshotFileURL) else { return nil }
        return try? JSONDecoder().decode(StatsSnapshot.self, from: data)
    }
}

/// Production transport: synchronous XPC fetch from the filter extension.
final class XPCSnapshotSource: SnapshotSource {
    private let connection: NSXPCConnection

    init() {
        connection = NSXPCConnection(machServiceName: SharedStats.machServiceName, options: [])
        connection.remoteObjectInterface = NSXPCInterface(with: WatchdogStatsXPC.self)
        connection.resume()
    }

    deinit { connection.invalidate() }

    func fetch() -> StatsSnapshot? {
        var result: StatsSnapshot?
        let semaphore = DispatchSemaphore(value: 0)
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in semaphore.signal() }
        (proxy as? WatchdogStatsXPC)?.fetchSnapshot { data in
            if let data { result = try? JSONDecoder().decode(StatsSnapshot.self, from: data) }
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 2)
        return result
    }
}

@MainActor
final class SnapshotFeed {
    private let source: SnapshotSource
    private var lastBootID: UUID?
    private var lastSeq: UInt64 = 0
    private var lastApps: [String: StatsSnapshot.AppStat] = [:]
    private var task: Task<Void, Never>?

    init(source: SnapshotSource) {
        self.source = source
    }

    /// One synchronous poll; returns fresh deltas ([] on no news / rebaseline).
    func poll() -> [AppDelta] {
        guard let snap = source.fetch() else { return [] }
        guard snap.bootID == lastBootID else {
            lastBootID = snap.bootID
            lastSeq = snap.seq
            lastApps = snap.apps
            return [] // new extension boot: cumulative counters reset, rebaseline only
        }
        guard snap.seq > lastSeq else { return [] }
        lastSeq = snap.seq

        var deltas: [AppDelta] = []
        for (appID, current) in snap.apps {
            let previous = lastApps[appID]
            let bytesIn = max(0, current.bytesIn - (previous?.bytesIn ?? 0))
            let bytesOut = max(0, current.bytesOut - (previous?.bytesOut ?? 0))
            guard bytesIn + bytesOut > 0 else { continue }
            var hosts: [String: StatsSnapshot.HostStat] = [:]
            for (host, stat) in current.hosts {
                let prev = previous?.hosts[host]
                let hostIn = max(0, stat.bytesIn - (prev?.bytesIn ?? 0))
                let hostOut = max(0, stat.bytesOut - (prev?.bytesOut ?? 0))
                if hostIn + hostOut > 0 { hosts[host] = .init(bytesIn: hostIn, bytesOut: hostOut) }
            }
            deltas.append(AppDelta(appID: appID, bytesIn: bytesIn, bytesOut: bytesOut, hosts: hosts))
        }
        lastApps = snap.apps
        return deltas
    }

    func start(deliver: @escaping @MainActor ([AppDelta]) -> Void) {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                if let deltas = self?.poll(), !deltas.isEmpty { deliver(deltas) }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}
```

Note: `XPCSnapshotSource.fetch()` blocks up to 2s; `SnapshotFeed.start` runs it from a MainActor task, which is acceptable only because `poll()` is also used synchronously by tests — when wiring the real XPC source (Task H3 verification), if UI hitches appear, move the fetch off-main by making `poll` async. Do NOT pre-emptively complicate it now.

- [ ] **Step 4: Run build + tests.** Expected: all pass.

- [ ] **Step 5: Commit** — `git commit -am "feat: SnapshotFeed — snapshot polling, seq/bootID discipline, delta conversion"`

---

### Task 5: Cut over — delete the nettop engine

**Files:**
- Delete: `watchdog/NettopSampler.swift`
- Modify: `watchdog/UsageModel.swift` (