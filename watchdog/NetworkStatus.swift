//
//  NetworkStatus.swift
//  watchdog
//
//  Created by Mulualem Tekle on 21/07/2026.
//
//  Watches the system network path for hotspot (expensive) and Low Data Mode
//  (constrained) so the app can flag limited networks the moment they connect.
//

import Combine
import Foundation
import Network

@MainActor
final class NetworkStatus: ObservableObject {
    @Published private(set) var isExpensive = false
    @Published private(set) var isConstrained = false

    /// Header badge label, nil on normal networks.
    var badge: String? {
        if isExpensive { return "Hotspot" }
        if isConstrained { return "Low Data Mode" }
        return nil
    }

    private let monitor = NWPathMonitor()

    init() {
        // ponytail: @Sendable keeps the handler nonisolated under the
        // project-wide MainActor default; it runs on the monitor queue.
        monitor.pathUpdateHandler = { @Sendable [weak self] path in
            let expensive = path.isExpensive
            let constrained = path.isConstrained
            Task { @MainActor [weak self] in
                self?.apply(expensive: expensive, constrained: constrained)
            }
        }
        monitor.start(queue: DispatchQueue(label: "watchdog.networkstatus"))
    }

    private func apply(expensive: Bool, constrained: Bool) {
        // Fires on every false->true edge — including the first reading, which
        // is the connect moment for an already-tethered launch. Never repeats
        // while the state stays continuously expensive.
        if expensive && !isExpensive {
            Notifier.post(title: "Hotspot network detected",
                          body: "Watchdog is monitoring your data.")
        }
        if expensive != isExpensive { isExpensive = expensive }
        if constrained != isConstrained { isConstrained = constrained }
    }
}
