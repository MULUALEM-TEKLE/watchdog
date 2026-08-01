//
//  FilterDataProvider.swift
//  WatchdogFilterExtension
//
//  Content filter system extension provider. NOT compiled into any target yet —
//  see BLOCKING.md for how to wire this into a System Extension target in Xcode.
//

import NetworkExtension
import Security
import os.log

/// Shared storage contract between the app UI and this extension.
/// The app writes the block list; the extension only reads it.
///
/// CAVEAT: this contract does NOT work as-is. sysextd launches the extension as
/// root, so this suite resolves to root's group container
/// (/var/root/Library/Group Containers/…), not the user's — the extension never
/// sees the app's writes and the KVO reload never fires. Before wiring up, move
/// the transport to NEFilterProviderConfiguration.vendorConfiguration (re-save
/// the filter preferences on each toggle) or XPC. See BLOCKING.md "Known limitation".
enum BlockListStore {
    static let suiteName = "group.watchdog.shared"
    /// Value: [String] — app signing identifiers (bundle IDs), e.g. "com.apple.Safari".
    static let blockedAppIDsKey = "blockedAppIDs"
}

class FilterDataProvider: NEFilterDataProvider {

    private let log = Logger(subsystem: "watchdog.filter", category: "provider")
    private let defaults = UserDefaults(suiteName: BlockListStore.suiteName)
    // KVO fires on an arbitrary thread while handleNewFlow reads concurrently.
    private let queue = DispatchQueue(label: "watchdog.filter.blocklist")
    private var blockedAppIDs: Set<String> = []

    override func startFilter(completionHandler: @escaping (Error?) -> Void) {
        reloadBlockList()

        // KVO on a shared suite fires when the app process changes the key.
        defaults?.addObserver(self, forKeyPath: BlockListStore.blockedAppIDsKey,
                              options: [], context: nil)

        // Filter all outbound socket traffic; per-flow decisions happen in handleNewFlow.
        let anyHost = NWHostEndpoint(hostname: "0.0.0.0", port: "0")
        let networkRule = NENetworkRule(remoteNetwork: anyHost, remotePrefix: 0,
                                        localNetwork: nil, localPrefix: 0,
                                        protocol: .any, direction: .outbound)
        let filterRule = NEFilterRule(networkRule: networkRule, action: .filterData)
        let settings = NEFilterSettings(rules: [filterRule], defaultAction: .allow)

        apply(settings) { error in
            if let error {
                self.log.error("Failed to apply filter settings: \(error.localizedDescription)")
            }
            completionHandler(error)
        }
    }

    override func stopFilter(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        defaults?.removeObserver(self, forKeyPath: BlockListStore.blockedAppIDsKey)
        completionHandler()
    }

    override func handleNewFlow(_ flow: NEFilterFlow) -> NEFilterNewFlowVerdict {
        // ponytail: signing identifier only; unsigned binaries pass through —
        // they have no stable identity to match against anyway.
        guard let appID = signingIdentifier(of: flow) else { return .allow() }
        let blocked = queue.sync {
            // Prefix match so blocking "com.google.Chrome" also drops
            // "com.google.Chrome.helper" — the app UI folds helpers into their parent.
            blockedAppIDs.contains(appID)
                || blockedAppIDs.contains { appID.hasPrefix($0 + ".") }
        }
        if blocked {
            log.info("Dropping flow from blocked app \(appID, privacy: .public)")
            return .drop()
        }
        return .allow()
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == BlockListStore.blockedAppIDsKey {
            reloadBlockList()
        } else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
        }
    }

    /// macOS has no NEFilterFlow.sourceAppIdentifier (iOS-only); the flow's audit
    /// token → SecTask → code-signing identifier (== bundle id for bundled apps).
    private func signingIdentifier(of flow: NEFilterFlow) -> String? {
        guard let tokenData = flow.sourceAppAuditToken,
              tokenData.count == MemoryLayout<audit_token_t>.size else { return nil }
        let token = tokenData.withUnsafeBytes { $0.load(as: audit_token_t.self) }
        guard let task = SecTaskCreateWithAuditToken(nil, token) else { return nil }
        return SecTaskCopySigningIdentifier(task, nil) as String?
    }

    private func reloadBlockList() {
        let ids = defaults?.stringArray(forKey: BlockListStore.blockedAppIDsKey) ?? []
        queue.sync { blockedAppIDs = Set(ids) }
        log.info("Block list reloaded: \(ids.count) app(s)")
    }
}
