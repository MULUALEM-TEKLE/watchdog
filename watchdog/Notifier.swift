//
//  Notifier.swift
//  watchdog
//
//  Created by Mulualem Tekle on 21/07/2026.
//
//  Minimal user-notification helper: lazily requests authorization on first
//  use (subsequent calls resolve instantly with the stored decision), then
//  posts a simple banner.
//

import Foundation
import UserNotifications

enum Notifier {
    static func post(title: String, body: String) {
        Task {
            let center = UNUserNotificationCenter.current()
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            try? await center.add(UNNotificationRequest(identifier: UUID().uuidString,
                                                        content: content,
                                                        trigger: nil))
        }
    }
}
