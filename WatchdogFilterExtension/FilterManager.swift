//
//  FilterManager.swift
//  watchdog (app side — drag into the app target when wiring up blocking)
//
//  Activates the system extension and enables the content filter configuration.
//  NOT compiled into any target yet — see BLOCKING.md.
//

import Foundation
import NetworkExtension
import SystemExtensions
import os.log

final class FilterManager: NSObject, ObservableObject {

    /// Bundle identifier of the system extension target you create in Xcode.
    static let extensionBundleID = "com.example.watchdog.WatchdogFilterExtension"

    @Published var status: String = "inactive"

    private let log = Logger(subsystem: "watchdog.app", category: "filter-manager")

    /// Step 1: ask macOS to install/activate the system extension.
    /// The user must approve it in System Settings > General > Login Items & Extensions.
    func activateExtension() {
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: Self.extensionBundleID,
            queue: .main
        )
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
        status = "requesting extension activation…"
    }

    /// Step 2: register and enable the filter configuration.
    /// The user must also approve the content filter in System Settings.
    func enableFilter() {
        let manager = NEFilterManager.shared()
        // NEFilterManager completions arrive on an arbitrary queue;
        // @Published must be touched on the main thread.
        manager.loadFromPreferences { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    self.status = "load failed: \(error.localizedDescription)"
                    return
                }
                if manager.providerConfiguration == nil {
                    let config = NEFilterProviderConfiguration()
                    config.filterSockets = true
                    config.filterPackets = false
                    manager.providerConfiguration = config
                    manager.localizedDescription = "Watchdog"
                }
                manager.isEnabled = true
                manager.saveToPreferences { error in
                    DispatchQueue.main.async {
                        self.status = error.map { "save failed: \($0.localizedDescription)" } ?? "filter enabled"
                    }
                }
            }
        }
    }
}

extension FilterManager: OSSystemExtensionRequestDelegate {

    func request(_ request: OSSystemExtensionRequest,
                 actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        status = "waiting for approval in System Settings"
    }

    func request(_ request: OSSystemExtensionRequest,
                 didFinishWithResult result: OSSystemExtensionRequest.Result) {
        status = "extension activated"
        enableFilter()
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        status = "activation failed: \(error.localizedDescription)"
        log.error("System extension activation failed: \(error.localizedDescription)")
    }
}
