# Watchdog App Store Compliance Migration — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Re-architect Watchdog so it runs **fully sandboxed** with its per-app data measurement (and blocking) provided by a bundled **NEFilterDataProvider app extension**, making the app eligible to pass Mac App Store review.

**Architecture:** Today Watchdog measures traffic by polling `/usr/bin/nettop` and calling `proc_pidpath` from an **unsandboxed** app — both are impossible inside the App Sandbox, so this is a foundational change, not a config tweak. The new design moves all privileged observation into a sandboxed **content-filter app extension** (`.appex`) that sees every socket flow with its owning app's code-signing identity. The extension aggregates per-app byte deltas and writes them to a shared **app-group container**; the sandboxed UI app reads that feed and keeps the entire existing `UsageStore` / `DayLog` / Reports / limits / hotspot / UI stack essentially unchanged. The same extension enforces the block list, so the block toggles finally become real. A bonus: because a content filter runs whenever it is enabled, data collection becomes **always-on even when the menu-bar UI is closed**.

**Tech Stack:** Swift 6, SwiftUI, NetworkExtension (`NEFilterDataProvider`, `NEFilterManager`, `NEFilterReport`, `NEFilterDataVerdict`), Security (`SecTask` for signing identity), App Groups shared container, Swift Testing, Xcode 26.

---

## Prerequisites (human, one-time — cannot be automated by subagents)

These require a **paid Apple Developer Program membership** and the Apple Developer portal / Xcode signing UI. A subagent cannot perform them. Do them first; the code tasks below consume the identifiers they produce.

- [ ] **P1. Enroll in the Apple Developer Program** ($99/yr). Note the **Team ID** (10 chars, e.g. `A1B2C3D4E5`).
- [ ] **P2. Register two explicit App IDs** at developer.apple.com → Identifiers:
  - App: `com.<yourteam>.watchdog` (replace the current placeholder `xar.watchdog`).
  - Extension: `com.<yourteam>.watchdog.filter`.
  - Enable the **Network Extensions** capability on **both** App IDs.
- [ ] **P3. Register an App Group** `group.com.<yourteam>.watchdog` and attach it to **both** App IDs above.
- [ ] **P4. Create App Store provisioning profiles** for both App IDs (or enable Xcode "Automatically manage signing" with the team selected — recommended; it provisions the Network Extension + App Group capabilities automatically).
- [ ] **P5. Record the resolved identifiers** in `Config.xcconfig` (created in Task 1.1) so every later task references them by variable, never by hardcoded string:
  - `DEVELOPMENT_TEAM`, `APP_BUNDLE_ID`, `EXT_BUNDLE_ID`, `APP_GROUP_ID`.
- [ ] **P6. Prepare a public Privacy Policy URL.** Apps using the Network Extension capability **must** provide one at submission. Content is drafted in Task 7.3; it must be hosted at a stable URL you control.

**Definition of "done" for the automated portion of this plan:** the project builds clean, is fully sandboxed, entitlements/provisioning are correct, all pure-logic unit tests pass, `codesign`/`spctl` verification passes, and the manual-QA checklist in Task 8.3 is green on a machine signed into the paid team. Actual App Store *submission* (screenshots, metadata, App Review) is outside code scope and listed as the final human step.

---

## Global Constraints

- **App Sandbox MUST be ON** (`com.apple.security.app-sandbox = true`) for the app target and the extension target. Re-enabling it is the entire point; nothing may depend on it being off.
- **No private APIs, no spawning subprocesses, no `proc_pidpath`, no reading `/usr/bin/nettop`.** These are automatic-rejection triggers under sandbox and/or App Review. Grep gate in Task 4.4 enforces removal.
- **Network Extension packaging = app extension (`.appex`)**, embedded in `Watchdog.app/Contents/PlugIns/`. **Do NOT** use `OSSystemExtensionRequest` / `SystemExtensions.framework` (that is the Developer-ID system-extension path and is disallowed for Mac App Store).
- **Extension entitlement:** `com.apple.developer.networking.networkextension` = `[content-filter-provider]` (the app-extension value — **not** `content-filter-provider-systemextension`).
- **Both targets** carry the App Group entitlement `com.apple.security.application-groups = [$(APP_GROUP_ID)]`.
- **Deployment target:** macOS 15.0 or later (current project is 26.5; keep as-is). `NEFilterReport.bytesInboundCount` requires macOS 10.15+ — satisfied.
- **Swift concurrency:** project sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`. Code that must run off the main actor (extension flow callbacks, container file IO) needs explicit `nonisolated`, matching the existing pattern in `NettopSampler.swift`.
- **No new third-party dependencies.** NetworkExtension, Security, and Foundation only.
- **Identifiers come from `Config.xcconfig` variables**, never hardcoded, so a reviewer/other team can rebuild without editing source.
- **Every existing engine invariant that still applies is preserved** and re-covered by tests: helper processes fold into their parent app; only public-internet hosts count; per-app deltas are non-negative; the block-list key/format contract stays `blockedAppIDs : [String]`.
- **Frequent commits:** one commit per completed task, message prefixed `feat:` / `refactor:` / `chore:` / `test:`.

**Behavioral truth to preserve in all UI copy (no overclaiming to App Review):** the app measures and blocks per-app **internet** traffic locally; it transmits nothing off-device.

---

## File Structure

**New / changed shared model (compiled into BOTH app and extension targets):**
- `WatchdogKit/FlowKey.swift` — app-identity + block-list contract shared by app and extension.
- `WatchdogKit/UsageFeed.swift` — the app-group-container transport (extension writes deltas, app reads them) and its codable payload.
- `WatchdogKit/FlowAggregator.swift` — **pure** per-app delta accounting from flow reports (unit-testable without NetworkExtension).

**Extension target (`WatchdogFilterExtension/`, promoted from scaffold to a real appex):**
- `FilterDataProvider.swift` — rewritten: measures via flow-close reports (+ optional live peek), enforces block list, publishes deltas to `UsageFeed`.
- `Info.plist`, `WatchdogFilterExtension.entitlements` — appex packaging + entitlements.

**App target (`watchdog/`):**
- `UsageModel.swift` — `UsageStore` loses the nettop sampler; gains a `UsageFeed` reader that calls the existing `apply(...)`-style accounting.
- `NettopSampler.swift`, `AppResolver.swift` (proc_pidpath path) — **deleted** or reduced to sandbox-safe icon lookup.
- `FilterController.swift` (was `FilterManager.swift`) — `NEFilterManager`-only enable/disable/status; no `OSSystemExtensionRequest`.
- `OnboardingView.swift` — explains and triggers the one-time content-filter approval.
- `PrivacyInfo.xcprivacy` — required privacy manifest.
- Entitlements: `watchdog.entitlements` (sandbox + app group + network-extension).
- `Config.xcconfig` — team/bundle/group identifiers.

---

## Phase 0 — Baseline & safety net

### Task 0.1: Branch and capture the green baseline

**Files:** none (git + verification only).

- [ ] **Step 1: Create a migration branch**

```bash
cd <repo>
git checkout -b appstore-sandbox-migration
```

- [ ] **Step 2: Confirm the current tree builds and tests pass (records the pre-migration baseline)**

Run:
```bash
xcodebuild -project watchdog.xcodeproj -scheme watchdog -destination 'platform=macOS' -only-testing:watchdogTests test 2>&1 | tail -5
```
Expected: `** TEST SUCCEEDED **` (22 tests).

- [ ] **Step 3: Snapshot the current entitlement/sandbox state for the record**

Run:
```bash
grep -n "ENABLE_APP_SANDBOX" watchdog.xcodeproj/project.pbxproj
```
Expected: two lines showing `ENABLE_APP_SANDBOX = NO;` (the state we are about to reverse).

- [ ] **Step 4: Commit the branch point**

```bash
git commit --allow-empty -m "chore: start App Store sandbox migration branch"
```

---

## Phase 1 — Shared model (compiled into both targets)

The app and the extension are separate processes and separate signed binaries. They cannot share instances — only **data contracts** and **pure logic** files added to both targets' compile-sources. Folder-synchronized groups auto-compile files under `watchdog/`; the shared files live in a new `WatchdogKit/` group that we add to **both** targets' membership in Task 4.1. Until then they compile only where referenced.

### Task 1.1: Create `Config.xcconfig` and the identity contract

**Files:**
- Create: `Config.xcconfig`
- Create: `WatchdogKit/FlowKey.swift`
- Test: `watchdogTests/WatchdogKitTests.swift`

**Interfaces:**
- Produces: `enum BlockListContract { static let appGroupID: String; static let blockedAppIDsKey = "blockedAppIDs" }`, `struct AppIdentity: Codable, Hashable { let bundleID: String; let displayName: String }`, `func foldedBundleID(from signingID: String) -> String`.

- [ ] **Step 1: Write `Config.xcconfig` with placeholder identifiers**

```xcconfig
// Config.xcconfig — fill these from the Prerequisites (P5). No other file hardcodes them.
DEVELOPMENT_TEAM = REPLACE_WITH_TEAM_ID
APP_BUNDLE_ID = com.example.watchdog
EXT_BUNDLE_ID = com.example.watchdog.filter
APP_GROUP_ID = group.com.example.watchdog
```

- [ ] **Step 2: Write the failing test for helper folding**

```swift
// watchdogTests/WatchdogKitTests.swift
import Testing
@testable import watchdog

struct FlowKeyTests {
    @Test func foldsHelperSigningIDsToParent() {
        // Chrome's renderer/helper processes sign as sub-identifiers of the app.
        #expect(foldedBundleID(from: "com.google.Chrome.helper") == "com.google.Chrome")
        #expect(foldedBundleID(from: "com.google.Chrome.helper.Renderer") == "com.google.Chrome")
        // A plain app id is returned unchanged.
        #expect(foldedBundleID(from: "com.apple.Safari") == "com.apple.Safari")
        // Apple daemons keep their own identity.
        #expect(foldedBundleID(from: "com.apple.nsurlsessiond") == "com.apple.nsurlsessiond")
    }
}
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `xcodebuild -project watchdog.xcodeproj -scheme watchdog -destination 'platform=macOS' -only-testing:watchdogTests/FlowKeyTests test 2>&1 | tail -5`
Expected: FAIL — `foldedBundleID` / `BlockListContract` not found.

- [ ] **Step 4: Write `WatchdogKit/FlowKey.swift`**

```swift
//
//  FlowKey.swift
//  WatchdogKit (compiled into BOTH the app and the filter extension)
//
//  The data contract shared across the app/extension process boundary.
//

import Foundation

enum BlockListContract {
    /// Resolved from Config.xcconfig at build time via Info.plist substitution.
    /// Both processes read the same app-group suite, so writes are mutually visible.
    /// (Unlike a *system* extension — which runs as root and sees root's container —
    ///  an app *extension* runs in the user's context, so this shared suite works.)
    static let appGroupID: String = {
        Bundle.main.object(forInfoDictionaryKey: "WatchdogAppGroupID") as? String
            ?? "group.com.example.watchdog"
    }()

    static let blockedAppIDsKey = "blockedAppIDs"
}

/// Stable per-app identity the extension attaches to every flow.
struct AppIdentity: Codable, Hashable {
    let bundleID: String
    let displayName: String
}

/// Folds a code-signing identifier onto its owning app bundle id, matching the
/// old path-based helper folding. Helpers sign as "<parent>.<suffix>"; we strip
/// known helper suffixes so "com.google.Chrome.helper.Renderer" → "com.google.Chrome".
func foldedBundleID(from signingID: String) -> String {
    let helperMarkers = [".helper", ".Helper", ".renderer", ".Renderer", ".gpu", ".plugin"]
    for marker in helperMarkers {
        if let range = signingID.range(of: marker) {
            return String(signingID[..<range.lowerBound])
        }
    }
    return signingID
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `xcodebuild -project watchdog.xcodeproj -scheme watchdog -destination 'platform=macOS' -only-testing:watchdogTests/FlowKeyTests test 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Config.xcconfig WatchdogKit/FlowKey.swift watchdogTests/WatchdogKitTests.swift
git commit -m "feat: shared identity + block-list contract for app/extension"
```

### Task 1.2: Pure per-app flow aggregator (the new accounting core)

**Files:**
- Create: `WatchdogKit/FlowAggregator.swift`
- Test: `watchdogTests/FlowAggregatorTests.swift`

**Interfaces:**
- Consumes: `AppIdentity`, `foldedBundleID` (Task 1.1); `NettopParser.isInternetHost` (existing, in `NettopSampler.swift` — **keep this function**, it is pure and reused; only the process-spawning `NettopSampler.sample()` is deleted later).
- Produces:
  - `struct FlowObservation { let identity: AppIdentity; let remoteHost: String?; let bytesIn: Int64; let bytesOut: Int64 }`
  - `struct AppDelta: Codable { let bundleID: String; let displayName: String; var bytesIn: Int64; var bytesOut: Int64; var hosts: [String: HostBytes] }`, `struct HostBytes: Codable { var bytesIn: Int64; var bytesOut: Int64 }`
  - `final class FlowAggregator { func record(_ obs: FlowObservation); func drainDeltas() -> [AppDelta] }`

This mirrors the semantics of the current `UsageStore.apply(...)` inner loop (internet-only filtering, helper folding, per-host tallies) but takes already-final per-flow byte counts from the extension instead of monotonic socket counters — so there is **no baseline/delta/shrink math** here; each observation is already a delta for a closed (or chunk-bounded) flow.

- [ ] **Step 1: Write the failing tests**

```swift
// watchdogTests/FlowAggregatorTests.swift
import Testing
@testable import watchdog

struct FlowAggregatorTests {
    private func obs(_ bundle: String, _ name: String, host: String?, _ inB: Int64, _ outB: Int64) -> FlowObservation {
        FlowObservation(identity: AppIdentity(bundleID: bundle, displayName: name),
                        remoteHost: host, bytesIn: inB, bytesOut: outB)
    }

    @Test func accumulatesPerAppAndFoldsHelpers() {
        let agg = FlowAggregator()
        agg.record(obs("com.google.Chrome", "Google Chrome", host: "142.250.1.1", 1000, 200))
        agg.record(obs("com.google.Chrome.helper", "Google Chrome Helper", host: "142.250.1.2", 500, 50))
        let deltas = agg.drainDeltas()
        #expect(deltas.count == 1)
        #expect(deltas[0].bundleID == "com.google.Chrome")
        #expect(deltas[0].bytesIn == 1500)
        #expect(deltas[0].bytesOut == 250)
        #expect(deltas[0].hosts.count == 2)
    }

    @Test func dropsLocalAndMulticastHosts() {
        let agg = FlowAggregator()
        agg.record(obs("com.apple.Safari", "Safari", host: "192.168.1.5", 9_000, 9_000))
        agg.record(obs("com.apple.Safari", "Safari", host: nil, 9_000, 9_000))
        agg.record(obs("com.apple.Safari", "Safari", host: "17.253.1.1", 400, 100))
        let deltas = agg.drainDeltas()
        #expect(deltas.count == 1)
        #expect(deltas[0].bytesIn == 400)   // only the public host counted
        #expect(deltas[0].bytesOut == 100)
    }

    @Test func drainClearsState() {
        let agg = FlowAggregator()
        agg.record(obs("com.apple.Safari", "Safari", host: "17.253.1.1", 100, 100))
        _ = agg.drainDeltas()
        #expect(agg.drainDeltas().isEmpty)  // second drain is empty
    }

    @Test func hostBytesAccumulate() {
        let agg = FlowAggregator()
        agg.record(obs("com.apple.Safari", "Safari", host: "17.253.1.1", 100, 10))
        agg.record(obs("com.apple.Safari", "Safari", host: "17.253.1.1", 300, 20))
        let d = agg.drainDeltas()[0]
        #expect(d.hosts["17.253.1.1"]?.bytesIn == 400)
        #expect(d.hosts["17.253.1.1"]?.bytesOut == 30)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -project watchdog.xcodeproj -scheme watchdog -destination 'platform=macOS' -only-testing:watchdogTests/FlowAggregatorTests test 2>&1 | tail -5`
Expected: FAIL — types not defined.

- [ ] **Step 3: Write `WatchdogKit/FlowAggregator.swift`**

```swift
//
//  FlowAggregator.swift
//  WatchdogKit (compiled into BOTH targets)
//
//  Pure per-app byte accounting from already-final flow byte counts.
//  No baseline/delta math: the extension hands us per-flow (or per-chunk)
//  deltas directly, unlike nettop's cumulative socket counters.
//

import Foundation

struct FlowObservation {
    let identity: AppIdentity
    let remoteHost: String?
    let bytesIn: Int64
    let bytesOut: Int64
}

struct HostBytes: Codable, Hashable {
    var bytesIn: Int64
    var bytesOut: Int64
}

struct AppDelta: Codable, Hashable {
    let bundleID: String
    let displayName: String
    var bytesIn: Int64
    var bytesOut: Int64
    var hosts: [String: HostBytes]
}

/// Thread-safe: the extension records from NE callback queues and drains from a timer.
final class FlowAggregator {
    private let lock = NSLock()
    private var byApp: [String: AppDelta] = [:]

    func record(_ obs: FlowObservation) {
        // Internet usage only — reuse the existing, tested classifier.
        guard let host = obs.remoteHost, NettopParser.isInternetHost(host) else { return }
        guard obs.bytesIn + obs.bytesOut > 0 else { return }

        let id = foldedBundleID(from: obs.identity.bundleID)
        lock.lock(); defer { lock.unlock() }

        var entry = byApp[id] ?? AppDelta(bundleID: id, displayName: obs.identity.displayName,
                                          bytesIn: 0, bytesOut: 0, hosts: [:])
        entry.bytesIn += obs.bytesIn
        entry.bytesOut += obs.bytesOut
        var hb = entry.hosts[host] ?? HostBytes(bytesIn: 0, bytesOut: 0)
        hb.bytesIn += obs.bytesIn
        hb.bytesOut += obs.bytesOut
        entry.hosts[host] = hb
        byApp[id] = entry
    }

    /// Returns accumulated deltas since the last drain and resets.
    func drainDeltas() -> [AppDelta] {
        lock.lock(); defer { lock.unlock() }
        let out = Array(byApp.values)
        byApp.removeAll(keepingCapacity: true)
        return out
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild -project watchdog.xcodeproj -scheme watchdog -destination 'platform=macOS' -only-testing:watchdogTests/FlowAggregatorTests test 2>&1 | tail -5`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add WatchdogKit/FlowAggregator.swift watchdogTests/FlowAggregatorTests.swift
git commit -m "feat: pure per-app flow aggregator with internet-only + helper folding"
```

### Task 1.3: App-group container transport (`UsageFeed`)

**Files:**
- Create: `WatchdogKit/UsageFeed.swift`
- Test: `watchdogTests/UsageFeedTests.swift`

**Interfaces:**
- Consumes: `AppDelta` (1.2), `BlockListContract` (1.1).
- Produces:
  - `struct UsageFeed` with `nonisolated static func containerURL() -> URL?`, `nonisolated static func append(_ deltas: [AppDelta], to url: URL)`, `nonisolated static func readAndClear(_ url: URL) -> [AppDelta]`.
  - The transport is a single JSON file in the app-group container the extension appends to and the app drains, guarded by an `NSFileCoordinator` for cross-process safety.

- [ ] **Step 1: Write the failing test (round-trips deltas through a temp file, no real container needed)**

```swift
// watchdogTests/UsageFeedTests.swift
import Testing
import Foundation
@testable import watchdog

struct UsageFeedTests {
    @Test func appendThenReadAndClearRoundTrips() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("feed-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }

        UsageFeed.append([
            AppDelta(bundleID: "com.apple.Safari", displayName: "Safari",
                     bytesIn: 100, bytesOut: 10, hosts: ["17.1.1.1": HostBytes(bytesIn: 100, bytesOut: 10)])
        ], to: tmp)
        UsageFeed.append([
            AppDelta(bundleID: "com.apple.Safari", displayName: "Safari",
                     bytesIn: 50, bytesOut: 5, hosts: ["17.1.1.1": HostBytes(bytesIn: 50, bytesOut: 5)])
        ], to: tmp)

        let first = UsageFeed.readAndClear(tmp)
        #expect(first.reduce(0) { $0 + $1.bytesIn } == 150)   // both appends drained
        let second = UsageFeed.readAndClear(tmp)
        #expect(second.isEmpty)                                // cleared after read
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project watchdog.xcodeproj -scheme watchdog -destination 'platform=macOS' -only-testing:watchdogTests/UsageFeedTests test 2>&1 | tail -5`
Expected: FAIL — `UsageFeed` not found.

- [ ] **Step 3: Write `WatchdogKit/UsageFeed.swift`**

```swift
//
//  UsageFeed.swift
//  WatchdogKit (compiled into BOTH targets)
//
//  Cross-process transport: the extension appends per-app deltas to a JSON
//  array in the shared app-group container; the app drains it on a timer.
//  NSFileCoordinator serializes the two processes' access.
//

import Foundation

enum UsageFeed {
    private static let fileName = "usage-feed.json"

    nonisolated static func containerURL() -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: BlockListContract.appGroupID)?
            .appendingPathComponent(fileName)
    }

    nonisolated static func append(_ deltas: [AppDelta], to url: URL) {
        guard !deltas.isEmpty else { return }
        let coordinator = NSFileCoordinator()
        var coordError: NSError?
        coordinator.coordinate(writingItemAt: url, options: [], error: &coordError) { u in
            var existing = (try? Data(contentsOf: u)).flatMap {
                try? JSONDecoder().decode([AppDelta].self, from: $0)
            } ?? []
            existing.append(contentsOf: deltas)
            if let data = try? JSONEncoder().encode(existing) {
                try? data.write(to: u, options: .atomic)
            }
        }
    }

    nonisolated static func readAndClear(_ url: URL) -> [AppDelta] {
        let coordinator = NSFileCoordinator()
        var result: [AppDelta] = []
        var coordError: NSError?
        coordinator.coordinate(writingItemAt: url, options: [], error: &coordError) { u in
            result = (try? Data(contentsOf: u)).flatMap {
                try? JSONDecoder().decode([AppDelta].self, from: $0)
            } ?? []
            try? FileManager.default.removeItem(at: u)
        }
        return result
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -project watchdog.xcodeproj -scheme watchdog -destination 'platform=macOS' -only-testing:watchdogTests/UsageFeedTests test 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add WatchdogKit/UsageFeed.swift watchdogTests/UsageFeedTests.swift
git commit -m "feat: app-group container transport for extension→app usage feed"
```

---

## Phase 2 — The measuring & blocking extension

### Task 2.1: Add the app-extension target to the Xcode project

**Files:**
- Modify: `watchdog.xcodeproj/project.pbxproj` (via Xcode UI — see steps)
- Modify: `WatchdogFilterExtension/Info.plist` (already correct; verify)

**This task is performed in the Xcode GUI** because hand-editing `project.pbxproj` to add a target is error-prone. A subagent with GUI access follows these steps; otherwise flag for the human operator.

- [ ] **Step 1: Add target** — File ▸ New ▸ Target ▸ macOS ▸ **Network Extension** (or "Content Filter" template if present). Product Name: `WatchdogFilterExtension`. Bundle id: set to `$(EXT_BUNDLE_ID)` after Task 4.1 wires xcconfig; for now `com.example.watchdog.filter`. Embed in the `watchdog` app. Language: Swift.
- [ ] **Step 2: Delete the template-generated `FilterDataProvider.swift`** in the new target and instead add the **existing** `WatchdogFilterExtension/FilterDataProvider.swift` to the target (it is rewritten in Task 2.2). Confirm the target's Info.plist is the existing `WatchdogFilterExtension/Info.plist` (already declares `NEProviderClasses` → `com.apple.networkextension.filter-data` → `$(PRODUCT_MODULE_NAME).FilterDataProvider`).
- [ ] **Step 3: Confirm packaging is app-extension**, not system-extension: the built product must be `WatchdogFilterExtension.appex` inside `Watchdog.app/Contents/PlugIns/`. Verify after first build:

Run:
```bash
xcodebuild -project watchdog.xcodeproj -scheme watchdog -configuration Debug build 2>&1 | tail -3
find ~/Library/Developer/Xcode/DerivedData/watchdog-*/Build/Products/Debug/watchdog.app/Contents/PlugIns -name '*.appex'
```
Expected: `** BUILD SUCCEEDED **` and a path ending `Contents/PlugIns/WatchdogFilterExtension.appex`. **If it is a `.systemextension`, the wrong template was used — redo Step 1.**

- [ ] **Step 4: Commit**

```bash
git add watchdog.xcodeproj/project.pbxproj
git commit -m "chore: add sandboxed content-filter app-extension target"
```

### Task 2.2: Rewrite `FilterDataProvider` to measure + block

**Files:**
- Modify: `WatchdogFilterExtension/FilterDataProvider.swift` (full rewrite)
- Add to extension target membership: `WatchdogKit/FlowKey.swift`, `WatchdogKit/FlowAggregator.swift`, `WatchdogKit/UsageFeed.swift`, and `NettopSampler.swift` **only for `NettopParser.isInternetHost`** (or, cleaner, move `isInternetHost` into `WatchdogKit/FlowKey.swift` in Task 4.3 and add only WatchdogKit to the extension — preferred; note the dependency here).

**Interfaces:**
- Consumes: `FlowAggregator`, `FlowObservation`, `AppIdentity`, `UsageFeed`, `BlockListContract`, `foldedBundleID`.
- Produces: a working `NEFilterDataProvider` subclass. No symbols consumed by other tasks.

**Design (reflecting the verified NetworkExtension semantics):**
- `handleNewFlow` resolves the flow's owning app via `sourceAppAuditToken → SecTask → SecTaskCopySigningIdentifier` (already implemented correctly in the current scaffold; keep it). If the folded id is **blocked**, return `.drop()`. Otherwise return an **allow verdict with `shouldReport = true`** so `handleReport(_:)` fires at flow close with exact `bytesInboundCount` / `bytesOutboundCount`.
- `handleReport(_:)` builds a `FlowObservation` (identity + remote host + the report's byte counts) and calls `aggregator.record(...)`. **`bytesInboundCount` is only non-zero on `event == .flowClosed`** — this is the primary, exact measurement path.
- A repeating `Timer`/`DispatchSourceTimer` (every 2 s) drains the aggregator and appends to `UsageFeed`. This keeps container writes coarse.
- Remote host comes from the flow's `remoteEndpoint` (a hostname/IP string); reuse `NettopParser.isInternetHost` inside the aggregator (already wired in 1.2).
- Block list is loaded from the app-group `UserDefaults(suiteName:)` and refreshed on `handleNewFlow` via a cached value updated by KVO or a periodic reload. (App-extension context — the shared suite works here.)

- [ ] **Step 1: Write the rewritten provider**

```swift
//
//  FilterDataProvider.swift
//  WatchdogFilterExtension
//
//  Sandboxed content-filter app extension. Measures per-app internet bytes via
//  flow-close reports and enforces the block list. Publishes deltas to the app
//  through the shared app-group container (UsageFeed).
//

import NetworkExtension
import Security
import os.log

final class FilterDataProvider: NEFilterDataProvider {
    private let log = Logger(subsystem: "watchdog.filter", category: "provider")
    private let aggregator = FlowAggregator()
    private let defaults = UserDefaults(suiteName: BlockListContract.appGroupID)
    private let blockLock = NSLock()
    private var blocked: Set<String> = []
    private var drainTimer: DispatchSourceTimer?
    private let feedURL = UsageFeed.containerURL()

    override func startFilter(completionHandler: @escaping (Error?) -> Void) {
        reloadBlockList()
        defaults?.addObserver(self, forKeyPath: BlockListContract.blockedAppIDsKey, options: [], context: nil)

        // Observe all outbound sockets; per-flow decisions happen in handleNewFlow.
        let rule = NENetworkRule(remoteNetwork: nil, remotePrefix: 0,
                                 localNetwork: nil, localPrefix: 0,
                                 protocol: .any, direction: .outbound)
        let filterRule = NEFilterRule(networkRule: rule, action: .filterData)
        let settings = NEFilterSettings(rules: [filterRule], defaultAction: .allow)
        apply(settings) { [weak self] error in
            self?.startDrainTimer()
            completionHandler(error)
        }
    }

    override func stopFilter(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        defaults?.removeObserver(self, forKeyPath: BlockListContract.blockedAppIDsKey)
        drainTimer?.cancel(); drainTimer = nil
        drain() // flush the tail
        completionHandler()
    }

    override func handleNewFlow(_ flow: NEFilterFlow) -> NEFilterNewFlowVerdict {
        guard let signingID = signingIdentifier(of: flow) else {
            // Unsigned/unknown binary: allow, and still report so we can count it.
            return reportingAllowVerdict()
        }
        let id = foldedBundleID(from: signingID)
        let isBlocked = blockLock.withLock { blocked.contains(id) }
        if isBlocked {
            log.info("drop \(id, privacy: .public)")
            return .drop()
        }
        return reportingAllowVerdict()
    }

    /// Allow the flow but ask the system to report byte totals when it closes.
    private func reportingAllowVerdict() -> NEFilterNewFlowVerdict {
        let verdict = NEFilterNewFlowVerdict.allow()
        verdict.shouldReport = true
        return verdict
    }

    override func handleReport(_ report: NEFilterReport) {
        // Byte counts are populated only at flow close.
        guard report.event == .flowClosed else { return }
        guard let flow = report.flow else { return }
        let signingID = signingIdentifier(of: flow) ?? "unknown"
        let identity = AppIdentity(bundleID: foldedBundleID(from: signingID),
                                   displayName: displayName(for: signingID))
        aggregator.record(FlowObservation(
            identity: identity,
            remoteHost: remoteHost(of: flow),
            bytesIn: Int64(report.bytesInboundCount),
            bytesOut: Int64(report.bytesOutboundCount)))
    }

    // MARK: - Helpers

    private func startDrainTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in self?.drain() }
        timer.resume()
        drainTimer = timer
    }

    private func drain() {
        guard let feedURL else { return }
        UsageFeed.append(aggregator.drainDeltas(), to: feedURL)
    }

    private func remoteHost(of flow: NEFilterFlow) -> String? {
        guard let socket = flow as? NEFilterSocketFlow else { return nil }
        // remoteEndpoint prints as "host:port" (or "host.port" for IPv6); strip the port.
        guard let endpoint = socket.remoteEndpoint?.description else { return nil }
        if let host = endpoint.split(separator: ":").first, endpoint.filter({ $0 == ":" }).count == 1 {
            return String(host)
        }
        if let dot = endpoint.lastIndex(of: ".") { return String(endpoint[..<dot]) }
        return endpoint
    }

    private func signingIdentifier(of flow: NEFilterFlow) -> String? {
        guard let token = flow.sourceAppAuditToken,
              token.count == MemoryLayout<audit_token_t>.size else { return nil }
        let auditToken = token.withUnsafeBytes { $0.load(as: audit_token_t.self) }
        guard let task = SecTaskCreateWithAuditToken(nil, auditToken) else { return nil }
        return SecTaskCopySigningIdentifier(task, nil) as String?
    }

    /// The signing id doubles as a readable-enough name; the app upgrades it to the
    /// real localized bundle name when it resolves the icon. Keep the last path
    /// component so daemons read reasonably ("nsurlsessiond").
    private func displayName(for signingID: String) -> String {
        foldedBundleID(from: signingID).split(separator: ".").last.map(String.init) ?? signingID
    }

    private func reloadBlockList() {
        let ids = defaults?.stringArray(forKey: BlockListContract.blockedAppIDsKey) ?? []
        blockLock.withLock { blocked = Set(ids) }
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == BlockListContract.blockedAppIDsKey { reloadBlockList() }
    }
}
```

- [ ] **Step 2: Build the extension target**

Run:
```bash
xcodebuild -project watchdog.xcodeproj -scheme watchdog -configuration Debug build 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **`. (Runtime verification of real flow blocking/measuring happens in the manual-QA checklist, Task 8.3 — it requires the provisioned entitlement.)

- [ ] **Step 3: Commit**

```bash
git add WatchdogFilterExtension/FilterDataProvider.swift
git commit -m "feat: content-filter extension measures per-app bytes and blocks flows"
```

---

## Phase 3 — App-side ingestion (replace the sampler)

### Task 3.1: Add a `UsageFeed` reader to `UsageStore`, delete the nettop sampler

**Files:**
- Modify: `watchdog/UsageModel.swift`
- Test: `watchdogTests/EngineTests.swift` (add ingestion test; keep existing delta tests only if the code they cover survives — see Step 1 note)

**Interfaces:**
- Consumes: `UsageFeed.readAndClear`, `AppDelta`.
- Produces: `UsageStore.ingest(_ deltas: [AppDelta])` — folds extension deltas into the existing `session` / `hostTallies` / `dayLog` structures and republishes `apps`.

**Note on existing tests:** the current `UsageStoreDeltaTests` exercise `apply(_ procs: [ProcSample])` (baseline/shrink/grace logic tied to nettop's cumulative counters). Once the sampler is gone, that method and its tests are **obsolete** — delete `apply(_:)`, `ProcSample` handling, and the baseline machinery, and replace those tests with `ingest(_:)` tests. `NettopParser.isInternetHost` stays (used by `FlowAggregator`); the rest of `NettopSampler.swift` is deleted in Task 4.4.

- [ ] **Step 1: Write the failing ingestion test**

```swift
// add to watchdogTests/EngineTests.swift
@MainActor
struct UsageStoreIngestTests {
    private func delta(_ bundle: String, _ name: String, in inB: Int64, out outB: Int64,
                       host: String = "17.253.1.1") -> AppDelta {
        AppDelta(bundleID: bundle, displayName: name, bytesIn: inB, bytesOut: outB,
                 hosts: [host: HostBytes(bytesIn: inB, bytesOut: outB)])
    }

    @Test func ingestAccumulatesSessionTotals() {
        let store = UsageStore()
        store.ingest([delta("com.apple.Safari", "Safari", in: 1000, out: 100)])
        store.ingest([delta("com.apple.Safari", "Safari", in: 500, out: 50)])
        #expect(store.totalBytes == 1650)
        #expect(store.apps.first?.id == "com.apple.Safari")
    }

    @Test func ingestPopulatesHostUsage() {
        let store = UsageStore()
        store.ingest([delta("com.apple.Safari", "Safari", in: 900, out: 100, host: "17.253.1.1")])
        let hosts = store.hostUsage(for: "com.apple.Safari")
        #expect(hosts.first?.host == "17.253.1.1")
        #expect(hosts.first?.bytesIn == 900)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild -project watchdog.xcodeproj -scheme watchdog -destination 'platform=macOS' -only-testing:watchdogTests/UsageStoreIngestTests test 2>&1 | tail -5`
Expected: FAIL — `ingest` not found.

- [ ] **Step 3: Implement `ingest`, remove the sampler task**

In `watchdog/UsageModel.swift`:
- Delete the `samplerTask` property, the `Task.detached` sampler loop in `start()`, and `apply(_ procs:)` plus its baseline/`Baseline` struct/`hasBaselineTick`/`ticks`-for-pruning machinery.
- Replace `start()` with a feed poller:

```swift
func start() {
    guard feedTimer == nil else { return }
    NotificationCenter.default.addObserver(
        forName: NSApplication.willTerminateNotification, object: nil, queue: .main
    ) { [weak self] _ in MainActor.assumeIsolated { self?.dayLog.saveIfDirty() } }

    // The extension writes deltas to the shared container; drain them every second.
    let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
        guard let self, let url = UsageFeed.containerURL() else { return }
        let deltas = UsageFeed.readAndClear(url)
        Task { @MainActor in self.ingest(deltas) }
    }
    RunLoop.main.add(timer, forMode: .common)
    feedTimer = timer
}
```

- Add the ingestion method (mirrors the surviving half of the old `apply`: per-app session tallies, host tallies, day-log fold, daily-limit check, republish):

```swift
func ingest(_ deltas: [AppDelta]) {
    guard !deltas.isEmpty else { return }
    for d in deltas {
        session[d.bundleID, default: Tally(name: d.displayName)].bytesIn += d.bytesIn
        session[d.bundleID, default: Tally(name: d.displayName)].bytesOut += d.bytesOut

        var hosts = hostTallies[d.bundleID] ?? [:]
        for (host, hb) in d.hosts {
            hosts[host, default: HostUsage(host: host, bytesIn: 0, bytesOut: 0)].bytesIn += hb.bytesIn
            hosts[host, default: HostUsage(host: host, bytesIn: 0, bytesOut: 0)].bytesOut += hb.bytesOut
        }
        if hosts.count > 100 {
            for small in hosts.values.sorted(by: { $0.totalBytes < $1.totalBytes }).prefix(hosts.count - 100) {
                hosts.removeValue(forKey: small.host)
            }
        }
        hostTallies[d.bundleID] = hosts
        dayLog.add(id: d.bundleID, name: d.displayName, bytesIn: d.bytesIn, bytesOut: d.bytesOut)
    }
    todayTotalBytes = computedTodayTotal()
    checkDailyLimit(todayTotal: todayTotalBytes)
    saveCounter += 1
    if saveCounter.isMultiple(of: 30) { dayLog.saveIfDirty() }
    rebuild()
}
```

Add `private var feedTimer: Timer?` and `private var saveCounter = 0`; remove the now-unused `ticks` pruning references from the old sampler path only (keep any `ticks` used elsewhere, or rename to `saveCounter`). Keep `toggleBlock`, `resetStatistics`, `rebuild`, `hostUsage`, `computedTodayTotal`, `checkDailyLimit` unchanged.

- [ ] **Step 4: Delete the obsolete `UsageStoreDeltaTests`** (baseline/shrink/grace/empty-sample tests) from `EngineTests.swift` — they test the removed nettop path. Keep `NettopParserTests.classifiesInternetHosts` and `remoteHost`/IPv6 tests (that function survives). Keep `DayLogTests`.

- [ ] **Step 5: Run the full suite**

Run: `xcodebuild -project watchdog.xcodeproj -scheme watchdog -destination 'platform=macOS' -only-testing:watchdogTests test 2>&1 | tail -6`
Expected: `** TEST SUCCEEDED **`, including `UsageStoreIngestTests` and surviving parser/daylog/snapshot tests.

- [ ] **Step 6: Commit**

```bash
git add watchdog/UsageModel.swift watchdogTests/EngineTests.swift
git commit -m "refactor: UsageStore ingests extension feed instead of polling nettop"
```

---

## Phase 4 — Turn the sandbox ON

### Task 4.1: Wire `Config.xcconfig` into build settings and set bundle ids/team

**Files:** Modify: `watchdog.xcodeproj/project.pbxproj` (Xcode UI: Project ▸ Info ▸ Configurations, set both Debug/Release to use `Config.xcconfig` for project-level; or set per-target Base Configuration).

- [ ] **Step 1:** In Xcode, set the project's Debug and Release **Base Configuration** to `Config.xcconfig`.
- [ ] **Step 2:** For the **app** target set `PRODUCT_BUNDLE_IDENTIFIER = $(APP_BUNDLE_ID)`, `DEVELOPMENT_TEAM = $(DEVELOPMENT_TEAM)`. For the **extension** target set `PRODUCT_BUNDLE_IDENTIFIER = $(EXT_BUNDLE_ID)`, same team. Enable "Automatically manage signing" on both.
- [ ] **Step 3:** Add `WatchdogAppGroupID` to **both** targets' Info.plist: key `WatchdogAppGroupID`, value `$(APP_GROUP_ID)` (so `BlockListContract.appGroupID` resolves at runtime).
- [ ] **Step 4: Verify substitution**

Run:
```bash
xcodebuild -project watchdog.xcodeproj -scheme watchdog -showBuildSettings 2>/dev/null | grep -E "PRODUCT_BUNDLE_IDENTIFIER|APP_GROUP_ID|DEVELOPMENT_TEAM" | sort -u
```
Expected: values reflect `Config.xcconfig`, not `xar.watchdog`.

- [ ] **Step 5: Commit**

```bash
git add watchdog.xcodeproj/project.pbxproj watchdog/Info.plist WatchdogFilterExtension/Info.plist
git commit -m "chore: drive bundle ids, team, app group from Config.xcconfig"
```

### Task 4.2: Add entitlements files and enable App Sandbox on both targets

**Files:**
- Create: `watchdog/watchdog.entitlements`
- Modify: `WatchdogFilterExtension/WatchdogFilterExtension.entitlements` (rename/repurpose the existing `extension.entitlements`)
- Modify: `watchdog.xcodeproj/project.pbxproj` (set `CODE_SIGN_ENTITLEMENTS`, `ENABLE_APP_SANDBOX = YES`)

- [ ] **Step 1: Write `watchdog/watchdog.entitlements`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <true/>
    <key>com.apple.security.application-groups</key>
    <array>
        <string>$(APP_GROUP_ID)</string>
    </array>
    <key>com.apple.developer.networking.networkextension</key>
    <array>
        <string>content-filter-provider</string>
    </array>
</dict>
</plist>
```

- [ ] **Step 2: Write `WatchdogFilterExtension/WatchdogFilterExtension.entitlements`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <true/>
    <key>com.apple.security.application-groups</key>
    <array>
        <string>$(APP_GROUP_ID)</string>
    </array>
    <key>com.apple.developer.networking.networkextension</key>
    <array>
        <string>content-filter-provider</string>
    </array>
</dict>
</plist>
```

- [ ] **Step 3:** In Xcode, set `CODE_SIGN_ENTITLEMENTS` for the app target to `watchdog/watchdog.entitlements` and for the extension target to `WatchdogFilterExtension/WatchdogFilterExtension.entitlements`. Set `ENABLE_APP_SANDBOX = YES` on **both** targets (Debug + Release).
- [ ] **Step 4: Delete the stale sample entitlement files** `WatchdogFilterExtension/app.entitlements` and the old `WatchdogFilterExtension/extension.entitlements` (superseded).
- [ ] **Step 5: Verify sandbox flag flipped**

Run:
```bash
grep -c "ENABLE_APP_SANDBOX = YES;" watchdog.xcodeproj/project.pbxproj
```
Expected: `4` (two configs × two targets).

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: enable App Sandbox + app-group + network-extension entitlements"
```

### Task 4.3: Move `isInternetHost` into WatchdogKit; add WatchdogKit + shared files to extension target

**Files:**
- Modify: `WatchdogKit/FlowKey.swift` (append `isInternetHost`)
- Modify: `watchdog/NettopSampler.swift` (remove `isInternetHost`, leave a deprecation-free clean deletion path for Task 4.4)
- Modify: `watchdogTests/EngineTests.swift` (point `classifiesInternetHosts` at the new location — same symbol name, still free function, so tests need only the type import)
- Xcode: add `WatchdogKit/*.swift` to the **extension** target's Compile Sources (they are already in the app target).

- [ ] **Step 1:** Cut the `isInternetHost(_:)` function (and its IPv4/IPv6/CGNAT logic, verbatim) from `NettopParser` in `NettopSampler.swift` and paste it into `WatchdogKit/FlowKey.swift` as a top-level `func isInternetHost(_ host: String) -> Bool`. Update `FlowAggregator` (Task 1.2) call site from `NettopParser.isInternetHost(host)` to `isInternetHost(host)`.
- [ ] **Step 2:** Update `classifiesInternetHosts` test to call `isInternetHost(...)` free function.
- [ ] **Step 3:** In Xcode, add all three `WatchdogKit/*.swift` to the extension target membership (checkbox in the File Inspector). Confirm the extension no longer references any app-only file.
- [ ] **Step 4: Build both targets**

Run: `xcodebuild -project watchdog.xcodeproj -scheme watchdog -configuration Debug build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "refactor: move internet-host classifier into shared WatchdogKit"
```

### Task 4.4: Delete all sandbox-incompatible code and gate it

**Files:**
- Delete: `watchdog/NettopSampler.swift` (now empty of shared logic — the `Process`/`Pipe`/nettop code)
- Delete: `watchdog/AppResolver.swift`'s `proc_pidpath` resolution; replace with sandbox-safe icon-by-bundle-id lookup (Task 6.1 covers the replacement — this task only removes the forbidden call).
- Modify: any references.

- [ ] **Step 1: Delete `NettopSampler.swift`.** Its `ProcSample`/`ConnSample` types and `sample()`/`parse()` are unused after Phase 3. If `NettopParserTests` still references `NettopParser.parse`, delete those specific parser tests too (the CSV parser is gone); keep only `isInternetHost` tests (now in WatchdogKit).
- [ ] **Step 2: Grep-gate — no forbidden symbols remain**

Run:
```bash
grep -rn "proc_pidpath\|/usr/bin/nettop\|Process()\|OSSystemExtension\|SystemExtensions" watchdog WatchdogFilterExtension WatchdogKit --include='*.swift'
```
Expected: **no output.** Any hit is a sandbox/App-Store blocker and must be removed before proceeding.

- [ ] **Step 3: Build + test**

Run: `xcodebuild -project watchdog.xcodeproj -scheme watchdog -destination 'platform=macOS' -only-testing:watchdogTests test 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "refactor: remove nettop/proc_pidpath/system-extension code for sandbox"
```

---

## Phase 5 — Filter management & onboarding

### Task 5.1: Replace `FilterManager` (system-extension activation) with `FilterController` (NEFilterManager only)

**Files:**
- Delete: `WatchdogFilterExtension/FilterManager.swift` (the `OSSystemExtensionRequest` version)
- Create: `watchdog/FilterController.swift`
- Test: none (NEFilterManager needs the provisioned entitlement + user approval; covered by manual QA 8.3). Logic is a thin state wrapper.

**Interfaces:**
- Produces: `@MainActor final class FilterController: ObservableObject { @Published var status: FilterStatus; func enable(); func disable(); func refresh() }`, `enum FilterStatus { case disabled, enabling, enabled, needsApproval, failed(String) }`.

- [ ] **Step 1: Write `watchdog/FilterController.swift`**

```swift
//
//  FilterController.swift
//  watchdog
//
//  Enables/disables the bundled content-filter app extension via NEFilterManager.
//  App Store path: NO OSSystemExtensionRequest — the appex is loaded from the app
//  bundle by the system once the filter configuration is enabled and user-approved.
//

import Foundation
import NetworkExtension
import Combine

enum FilterStatus: Equatable {
    case disabled, enabling, enabled, needsApproval, failed(String)
}

@MainActor
final class FilterController: ObservableObject {
    @Published private(set) var status: FilterStatus = .disabled

    func refresh() {
        NEFilterManager.shared().loadFromPreferences { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                if let error { self.status = .failed(error.localizedDescription); return }
                self.status = NEFilterManager.shared().isEnabled ? .enabled : .disabled
            }
        }
    }

    func enable() {
        status = .enabling
        let manager = NEFilterManager.shared()
        manager.loadFromPreferences { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                if let error { self.status = .failed(error.localizedDescription); return }
                if manager.providerConfiguration == nil {
                    let config = NEFilterProviderConfiguration()
                    config.filterSockets = true
                    config.filterPackets = false
                    manager.providerConfiguration = config
                    manager.localizedDescription = "Watchdog"
                }
                manager.isEnabled = true
                manager.saveToPreferences { saveError in
                    Task { @MainActor in
                        if let saveError {
                            // Users cancelling the system approval land here.
                            self.status = .needsApproval
                            _ = saveError
                        } else {
                            self.status = .enabled
                        }
                    }
                }
            }
        }
    }

    func disable() {
        let manager = NEFilterManager.shared()
        manager.loadFromPreferences { [weak self] _ in
            manager.isEnabled = false
            manager.saveToPreferences { _ in
                Task { @MainActor in self?.status = .disabled }
            }
        }
    }
}
```

- [ ] **Step 2: Build**

Run: `xcodebuild -project watchdog.xcodeproj -scheme watchdog -configuration Debug build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "feat: NEFilterManager-based FilterController (app-extension activation)"
```

### Task 5.2: Onboarding UI + wire controller into the app

**Files:**
- Create: `watchdog/OnboardingView.swift`
- Modify: `watchdog/watchdogApp.swift` (own a `FilterController`, call `refresh()` on launch)
- Modify: `watchdog/MenuContentView.swift` (show onboarding when `status != .enabled`; add an "Enable data monitoring" affordance and a link to why approval is needed)

- [ ] **Step 1: Write `OnboardingView.swift`** — a small SwiftUI view explaining, in plain language, that Watchdog needs to turn on its network filter to measure and block per-app data, with an "Enable" button calling `controller.enable()` and, on `.needsApproval`, guidance text: "Open System Settings ▸ General ▸ Login Items & Extensions ▸ Network Extensions and allow Watchdog." Include a "Learn more" disclosure describing that all analysis stays on the Mac (matches the privacy policy — no overclaiming).

```swift
//
//  OnboardingView.swift
//  watchdog
//

import SwiftUI

struct OnboardingView: View {
    @ObservedObject var controller: FilterController

    var body: some View {
        VStack(spacing: 14) {
            Image("MenuBarIcon").resizable().frame(width: 44, height: 44).opacity(0.9)
            Text("Turn on data monitoring").font(.headline)
            Text("Watchdog uses a macOS network filter to measure and block each app’s internet usage. All analysis stays on your Mac — nothing is sent anywhere.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal, 20)

            switch controller.status {
            case .needsApproval:
                Text("Allow Watchdog in System Settings ▸ General ▸ Login Items & Extensions ▸ Network Extensions, then return here.")
                    .font(.caption).foregroundStyle(.orange).multilineTextAlignment(.center).padding(.horizontal, 20)
                Button("Open System Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
            case .failed(let message):
                Text(message).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center).padding(.horizontal, 20)
                Button("Try Again") { controller.enable() }
            case .enabling:
                ProgressView()
            default:
                Button("Enable") { controller.enable() }.buttonStyle(.borderedProminent)
            }
        }
        .frame(width: 320, height: 440)
        .padding()
    }
}
```

- [ ] **Step 2: In `watchdogApp.swift`**, add `@StateObject private var filter = FilterController()`, call `filter.refresh()` in `applicationDidFinishLaunching`, and pass `filter` into `MenuContentView`.
- [ ] **Step 3: In `MenuContentView.swift`**, branch the root: when `filter.status != .enabled`, show `OnboardingView(controller: filter)`; otherwise show the current `list/appDetail/reports` switch unchanged.
- [ ] **Step 4: Build**

Run: `xcodebuild -project watchdog.xcodeproj -scheme watchdog -configuration Debug build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: onboarding to enable the content filter with clear consent"
```

---

## Phase 6 — Sandbox-safe app resolution & icons

### Task 6.1: Resolve display names and icons from bundle ids under sandbox

**Files:**
- Create: `watchdog/AppResolver.swift` (rewritten, sandbox-safe — replaces the deleted proc_pidpath version)
- Test: `watchdogTests/AppResolverTests.swift`

**Interfaces:**
- Produces: `@MainActor final class AppResolver { func icon(forBundleID id: String) -> NSImage?; func displayName(forBundleID id: String, fallback: String) -> String }`.

**Sandbox note:** direct filesystem reads of other apps' bundles are blocked, but `NSWorkspace.urlForApplication(withBundleIdentifier:)` and `NSWorkspace.icon(forFile:)` route through LaunchServices and are permitted inside the sandbox. This is the supported way to get another app's icon/name without a file-access entitlement. Where LaunchServices cannot resolve a daemon id (e.g. `com.apple.nsurlsessiond`), fall back to a generic icon and the display name the extension supplied.

- [ ] **Step 1: Write the failing test** (resolves a well-known system app that exists on every Mac)

```swift
// watchdogTests/AppResolverTests.swift
import Testing
import AppKit
@testable import watchdog

@MainActor
struct AppResolverTests {
    @Test func resolvesKnownAppNameAndIcon() {
        let r = AppResolver()
        // Finder is present on every macOS install and resolvable via LaunchServices.
        #expect(r.displayName(forBundleID: "com.apple.finder", fallback: "finder") == "Finder")
        #expect(r.icon(forBundleID: "com.apple.finder") != nil)
    }

    @Test func fallsBackForUnresolvableID() {
        let r = AppResolver()
        #expect(r.displayName(forBundleID: "com.nonexistent.daemon.xyz", fallback: "daemon-xyz") == "daemon-xyz")
        #expect(r.icon(forBundleID: "com.nonexistent.daemon.xyz") != nil) // generic icon, never nil
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild -project watchdog.xcodeproj -scheme watchdog -destination 'platform=macOS' -only-testing:watchdogTests/AppResolverTests test 2>&1 | tail -5`
Expected: FAIL — `AppResolver` not found.

- [ ] **Step 3: Write `watchdog/AppResolver.swift`**

```swift
//
//  AppResolver.swift
//  watchdog
//
//  Sandbox-safe: resolves other apps' names/icons via LaunchServices
//  (NSWorkspace), never by reading their bundles directly.
//

import AppKit

@MainActor
final class AppResolver {
    private var iconCache: [String: NSImage] = [:]
    private var nameCache: [String: String] = [:]

    func icon(forBundleID id: String) -> NSImage? {
        if let cached = iconCache[id] { return cached }
        let image: NSImage
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            image = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            image = NSWorkspace.shared.icon(for: .unixExecutable)
        }
        image.size = NSSize(width: 32, height: 32)
        iconCache[id] = image
        return image
    }

    func displayName(forBundleID id: String, fallback: String) -> String {
        if let cached = nameCache[id] { return cached }
        var name = fallback
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            name = FileManager.default.displayName(atPath: url.path)
                .replacingOccurrences(of: ".app", with: "")
        }
        nameCache[id] = name
        return name
    }
}
```

- [ ] **Step 4:** In `UsageStore.rebuild()`, use `resolver.icon(forBundleID:)` and upgrade the display name via `resolver.displayName(forBundleID:fallback:)` (fallback = the name the extension supplied). Confirm `UsageStore` holds an `AppResolver` instance (it already did before the rewrite; re-add if removed).
- [ ] **Step 5: Run tests**

Run: `xcodebuild -project watchdog.xcodeproj -scheme watchdog -destination 'platform=macOS' -only-testing:watchdogTests test 2>&1 | tail -6`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: sandbox-safe app name/icon resolution via LaunchServices"
```

---

## Phase 7 — App Review hygiene

### Task 7.1: Privacy manifest (`PrivacyInfo.xcprivacy`)

**Files:** Create: `watchdog/PrivacyInfo.xcprivacy` (add to app target resources).

Watchdog collects no data off-device and uses no tracking. It reads `UserDefaults` (a "required reason" API) — declare it.

- [ ] **Step 1: Write the manifest**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>NSPrivacyTracking</key>
    <false/>
    <key>NSPrivacyTrackingDomains</key>
    <array/>
    <key>NSPrivacyCollectedDataTypes</key>
    <array/>
    <key>NSPrivacyAccessedAPITypes</key>
    <array>
        <dict>
            <key>NSPrivacyAccessedAPIType</key>
            <string>NSPrivacyAccessedAPICategoryUserDefaults</string>
            <key>NSPrivacyAccessedAPITypeReasons</key>
            <array>
                <string>CA92.1</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
```

- [ ] **Step 2: Verify it is valid plist and bundled**

Run:
```bash
plutil -lint watchdog/PrivacyInfo.xcprivacy
```
Expected: `OK`.

- [ ] **Step 3: Commit**

```bash
git add watchdog/PrivacyInfo.xcprivacy
git commit -m "chore: add privacy manifest (no tracking, no data collection)"
```

### Task 7.2: Login-item consent (no silent auto-registration)

**Files:** Modify: `watchdog/LoginItem.swift`, `watchdog/watchdogApp.swift`, `watchdog/UsageListView.swift`.

App Review dislikes apps that silently make themselves persistent. Remove `registerOnFirstRun()`'s auto-enable; keep the explicit menu toggle and, optionally, offer it in onboarding.

- [ ] **Step 1:** Delete the `registerOnFirstRun()` call from `applicationDidFinishLaunching`. Delete the `registerOnFirstRun()` method (or repurpose it to only *read* status). `SMAppService` login-item registration now happens **only** when the user flips "Start at Login" in the ⋯ menu (already wired) or accepts an optional onboarding checkbox.
- [ ] **Step 2:** Confirm the ⋯ menu "Start at Login" toggle still reads/writes `LoginItem.isEnabled` / `setEnabled`.
- [ ] **Step 3: Grep-gate — no auto-registration on launch**

Run:
```bash
grep -rn "registerOnFirstRun\|SMAppService.mainApp.register" watchdog/watchdogApp.swift
```
Expected: **no output** in `watchdogApp.swift` (registration lives only behind the user toggle).

- [ ] **Step 4: Build + commit**

```bash
xcodebuild -project watchdog.xcodeproj -scheme watchdog -configuration Debug build 2>&1 | tail -1
git add -A
git commit -m "chore: login item only on explicit user opt-in (review compliance)"
```

### Task 7.3: Privacy policy, review notes, and README update

**Files:**
- Create: `docs/PRIVACY.md` (source for the hosted policy — host it at the P6 URL)
- Create: `docs/APP_REVIEW_NOTES.md` (paste into App Store Connect "Notes for Review")
- Modify: `README.md`, `BLOCKING.md` (blocking is no longer "unwired" — it ships in the extension)

- [ ] **Step 1: Write `docs/PRIVACY.md`** stating: Watchdog observes per-app network byte counts and remote host addresses **locally** via a macOS content filter; it stores usage history only in the app's container on the user's Mac; it transmits nothing to any server; it contains no analytics or tracking; users can reset data any time. (This is the truthful basis reviewers verify.)
- [ ] **Step 2: Write `docs/APP_REVIEW_NOTES.md`** explaining for the reviewer: the app is a TripMode/Little-Snitch-style per-app data monitor; it uses the Network Extension content-filter capability solely to (a) count each app's internet bytes and (b) optionally block apps the user disables; the filter makes no external connections; how to test — enable the filter when prompted, generate traffic, observe per-app usage; blocking test — toggle an app off and confirm its traffic stops. Include the demo account note: "No account needed; all functionality is available on first launch after enabling the filter."
- [ ] **Step 3: Update `README.md`** — replace the "monitoring needs no entitlements / blocking is unwired" claims with the new architecture: sandboxed app + bundled content-filter extension; monitoring and blocking both live in the extension; always-on collection whenever the filter is enabled. Update `BLOCKING.md` to reflect that blocking is now implemented (remove the root-container "known limitation" — it applied to the system-extension design; the app-extension shares the user container correctly).
- [ ] **Step 4: Commit**

```bash
git add docs/PRIVACY.md docs/APP_REVIEW_NOTES.md README.md BLOCKING.md
git commit -m "docs: privacy policy, App Review notes, updated architecture docs"
```

### Task 7.4: Menu-bar-only presentation and metadata sanity

**Files:** Modify: `watchdog/Info.plist` (app), build settings.

- [ ] **Step 1:** Confirm `LSUIElement` (Application is agent) is `YES` for the app (menu-bar-only is App-Store-acceptable). Confirm `CFBundleDisplayName = Watchdog`, `CFBundleShortVersionString = 1.0`, `CFBundleVersion = 1`, and a real `NSHumanReadableCopyright`.
- [ ] **Step 2:** Confirm `ITSAppUsesNonExemptEncryption = NO` in the app Info.plist (avoids the export-compliance prompt; true since the app uses no non-exempt crypto).
- [ ] **Step 3: Verify**

Run:
```bash
plutil -p watchdog/Info.plist | grep -E "LSUIElement|CFBundleDisplayName|ITSAppUsesNonExemptEncryption|CFBundleShortVersionString"
```
Expected: all four present with the values above.

- [ ] **Step 4: Commit**

```bash
git add watchdog/Info.plist
git commit -m "chore: app metadata for submission (agent app, version, export compliance)"
```

---

## Phase 8 — Final verification

### Task 8.1: Full sandboxed build, test, and entitlement audit

**Files:** none (verification only).

- [ ] **Step 1: Clean release build of app + embedded extension**

Run:
```bash
xcodebuild -project watchdog.xcodeproj -scheme watchdog -configuration Release clean build 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 2: Confirm the extension is an embedded, sandboxed appex with the right entitlements**

Run:
```bash
APP=$(find ~/Library/Developer/Xcode/DerivedData/watchdog-*/Build/Products/Release -name watchdog.app | head -1)
APPEX="$APP/Contents/PlugIns/WatchdogFilterExtension.appex"
test -d "$APPEX" && echo "appex embedded: yes"
codesign -d --entitlements :- "$APP" 2>/dev/null | grep -E "app-sandbox|application-groups|networkextension"
codesign -d --entitlements :- "$APPEX" 2>/dev/null | grep -E "app-sandbox|application-groups|networkextension"
```
Expected: appex embedded: yes; both binaries show `app-sandbox`, the shared `application-groups`, and `content-filter-provider`.

- [ ] **Step 3: Full test suite**

Run:
```bash
xcodebuild -project watchdog.xcodeproj -scheme watchdog -destination 'platform=macOS' -only-testing:watchdogTests test 2>&1 | tail -6
```
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 4: Forbidden-symbol final gate**

Run:
```bash
grep -rn "proc_pidpath\|/usr/bin/nettop\|Process()\|OSSystemExtension\|ENABLE_APP_SANDBOX = NO" watchdog WatchdogFilterExtension WatchdogKit watchdog.xcodeproj/project.pbxproj --include='*.swift' --include='*.pbxproj'
```
Expected: **no output.**

### Task 8.2: Archive and validate against App Store

**Files:** none (requires the paid team + Xcode Organizer).

- [ ] **Step 1: Archive**

Run:
```bash
xcodebuild -project watchdog.xcodeproj -scheme watchdog -configuration Release archive \
  -archivePath build/Watchdog.xcarchive 2>&1 | tail -3
```
Expected: `** ARCHIVE SUCCEEDED **`.

- [ ] **Step 2: Validate the archive for the App Store** (Xcode ▸ Organizer ▸ Distribute App ▸ App Store Connect ▸ **Validate**, or `xcodebuild -exportArchive` with an App Store export options plist). Fix any validation error (common: entitlement not in provisioning profile → revisit P2–P4; missing privacy manifest → Task 7.1).
- [ ] **Step 3:** Confirm `spctl`/notarization is not required for App Store distribution (it is Apple-signed on the store); for a local Developer-ID smoke test only, `spctl -a -vvv "$APP"` should not reject.

### Task 8.3: Manual QA checklist (requires provisioned machine + paid team)

**These cannot be unit-tested — they need the real entitlement and user approval. Perform on a Mac signed into the paid team.**

- [ ] Launch the app → onboarding appears → click **Enable** → macOS prompts to allow the filter → approve in System Settings → onboarding dismisses, main list appears.
- [ ] Generate traffic (open a website, run a download). Within a few seconds, per-app usage appears with correct app names and icons; totals are plausible (KB/MB, not GB spikes); LAN-only apps do not appear.
- [ ] Open **Reports** → charts render for Today; peak line is sensible.
- [ ] **Block test:** toggle an app off → its new connections are dropped (verify with that app failing to load) → toggle on → traffic resumes.
- [ ] Quit the menu-bar app entirely; generate traffic; relaunch → history reflects the traffic that occurred while the UI was closed (proves always-on extension collection).
- [ ] Set a **daily limit** below current usage → notification fires once; menu-bar icon shows the warning state.
- [ ] Toggle **Start at Login** on/off → verify in System Settings ▸ Login Items.
- [ ] Disable the filter from onboarding/settings → measurement stops cleanly, no crash.
- [ ] Confirm the app never shows a Dock icon (agent app) and the menu-bar glasses icon adapts to light/dark.

### Task 8.4: Merge

- [ ] **Step 1:** With all boxes checked and validation passing, use `superpowers:finishing-a-development-branch` to open a PR or merge `appstore-sandbox-migration`.
- [ ] **Step 2 (human):** In App Store Connect, complete metadata, screenshots, the privacy policy URL (P6), the App Privacy questionnaire (mirrors `PrivacyInfo.xcprivacy`: no data collected), attach `docs/APP_REVIEW_NOTES.md`, and submit.

---

## Self-Review

**Spec coverage:**
- Sandbox ON → Tasks 4.2, 4.4, 8.1 (gates). ✓
- Per-app measurement without nettop/proc_pidpath → Phase 2 (extension) + Phase 3 (ingestion) + 6.1 (icons). ✓
- Blocking becomes real → Task 2.2 (`handleNewFlow` drop). ✓
- App-extension (not system-extension) packaging → Tasks 2.1, 5.1, 8.2. ✓
- Correct entitlements/provisioning → Prerequisites P1–P5, Tasks 4.1–4.2. ✓
- Review hygiene: privacy manifest 7.1, login-item consent 7.2, privacy policy + review notes 7.3, metadata/export-compliance 7.4. ✓
- Preserved behavior/tests: internet-only (1.2/4.3), helper folding (1.1/1.2), day-log/reports/limits/hotspot untouched (Phase 3 keeps them), snapshot tests survive. ✓
- Always-on collection → emergent from the filter design; verified in 8.3. ✓

**Placeholder scan:** identifiers are deliberately vari;`Config.xcconfig` centralizes them (P5); no "TBD"/"add error handling"/"similar to Task N" left. Config/GUI tasks that cannot be unit-tested use explicit `codesign`/`plutil`/`grep`/build verifications as their gate, and the irreducibly-manual filter behaviors are enumerated in 8.3. ✓

**Type consistency:** `AppDelta`/`HostBytes`/`AppIdentity`/`FlowObservation` defined in 1.1–1.2 and consumed unchanged in 2.2, 3.1; `BlockListContract.blockedAppIDsKey`/`appGroupID` consistent across 1.1, 1.3, 2.2; `isInternetHost` relocated once (4.3) with all call sites updated; `FilterStatus`/`FilterController` names match between 5.1 and 5.2. ✓

**Known human-only gates (cannot be automated):** paid membership, portal App IDs/App Group/provisioning (P1–P5), Xcode target creation (2.1) and capability wiring, and the provisioned manual QA (8.3) + submission (8.4). Everything else is subagent-executable with the verifications given.

---

**Plan complete and saved to `docs/superpowers/plans/2026-07-21-appstore-compliance-migration.md`.**
