//
//  UsageListSnapshotTests.swift
//  watchdogTests
//
//  Created by Mulualem Tekle on 21/07/2026.
//

import Testing
import SwiftUI
import AppKit
@testable import watchdog

@MainActor
struct UsageListSnapshotTests {

    @Test func usageListSnapshot() throws {
        func icon(_ symbol: String) -> NSImage? {
            NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        let apps = [
            AppUsage(id: "com.example.browser", name: "Browser", icon: icon("safari.fill"), bytesIn: 1_500_000_000, bytesOut: 80_000_000),
            AppUsage(id: "com.example.mail", name: "Mail", icon: icon("envelope.fill"), bytesIn: 250_000_000, bytesOut: 40_000_000),
            AppUsage(id: "com.example.music", name: "Music", icon: icon("music.note"), bytesIn: 640_000_000, bytesOut: 5_000_000),
            AppUsage(id: "com.example.build", name: "Builder", icon: icon("hammer.fill"), bytesIn: 2_000_000_000, bytesOut: 30_000_000, isBlocked: true),
            AppUsage(id: "com.example.terminal", name: "Terminal", icon: icon("terminal.fill"), bytesIn: 8_000_000, bytesOut: 2_000_000),
        ]
        let store = UsageStore(apps: apps)

        let view = UsageListView(store: store)
            .frame(width: 320, height: 440)
            .background(Color(nsColor: .windowBackgroundColor))

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2

        let cgImage = try #require(renderer.cgImage)
        let rep = NSBitmapImageRep(cgImage: cgImage)
        let data = try #require(rep.representation(using: .png, properties: [:]))

        // Sandboxed test host: write inside the container's temp dir.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage_list_snapshot.png")
        try data.write(to: url)
        print("SNAPSHOT_PATH: \(url.path)")

        let size = try #require(
            FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int
        )
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(size > 10_240)
    }

    @Test func reportsSnapshot() throws {
        var log = DayLog(hours: [:])
        log.add(id: "com.example.browser", name: "Browser", bytesIn: 900_000_000, bytesOut: 40_000_000)
        log.add(id: "com.example.mail", name: "Mail", bytesIn: 250_000_000, bytesOut: 12_000_000)
        log.add(id: "com.example.music", name: "Music", bytesIn: 640_000_000, bytesOut: 5_000_000)
        log.add(id: "com.example.build", name: "Builder", bytesIn: 400_000_000, bytesOut: 30_000_000)
        log.add(id: "com.example.terminal", name: "Terminal", bytesIn: 80_000_000, bytesOut: 2_000_000)
        log.add(id: "com.example.chat", name: "Chat", bytesIn: 30_000_000, bytesOut: 9_000_000)
        let store = UsageStore(dayLog: log)

        // Whole-scope path: no bucket selection, Today scope by default.
        let view = ReportsView(store: store)
            .frame(width: 320, height: 440)
            .background(Color(nsColor: .windowBackgroundColor))

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2

        let cgImage = try #require(renderer.cgImage)
        let rep = NSBitmapImageRep(cgImage: cgImage)
        let data = try #require(rep.representation(using: .png, properties: [:]))

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("reports_snapshot.png")
        try data.write(to: url)
        print("SNAPSHOT_PATH: \(url.path)")

        let size = try #require(
            FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int
        )
        #expect(size > 10_240)
    }
}
