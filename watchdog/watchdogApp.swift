//
//  watchdogApp.swift
//  watchdog
//
//  Created by Mulualem Tekle on 21/07/2026.
//

import SwiftUI

@main
struct watchdogApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = UsageStore.live()
    @StateObject private var network = NetworkStatus()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(store: store, network: network)
        } label: {
            if store.overLimit {
                Image(systemName: "exclamationmark.triangle.fill")
            } else {
                Image("MenuBarIcon")
            }
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        LoginItem.registerOnFirstRun()
        // Menubar-only agent app: no Dock icon.
        NSApp.setActivationPolicy(.accessory)
    }
}
