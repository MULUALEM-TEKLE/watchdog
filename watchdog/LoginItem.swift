//
//  LoginItem.swift
//  watchdog
//
//  Created by Mulualem Tekle on 21/07/2026.
//
//  Start-at-login via SMAppService. Registers the current bundle, so the
//  installed copy in /Applications is what ends up in Login Items.
//

import Foundation
import ServiceManagement

enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("LoginItem toggle failed: \(error.localizedDescription)")
        }
    }

    /// Auto-enable once on first launch; afterwards the user's choice
    /// (menu toggle or System Settings) is respected.
    static func registerOnFirstRun() {
        let key = "didAutoRegisterLoginItem"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        setEnabled(true)
    }
}
