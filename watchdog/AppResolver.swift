//
//  AppResolver.swift
//  watchdog
//
//  Created by Mulualem Tekle on 21/07/2026.
//
//  Maps pids from nettop to a stable app identity (bundle id, display name, icon).
//  Helper processes ("Google Chrome Helper") fold into their owning .app bundle
//  via their executable path, matching how TripMode groups usage.
//

import AppKit
import UniformTypeIdentifiers

@MainActor
final class AppResolver {
    struct Identity {
        let id: String
        let name: String
        let appPath: String?
    }

    // Keyed by "pid.procName": nettop truncates names to 15 chars, but a pid
    // reused by a *same-named* process is the only collision this misses.
    private var identities: [String: Identity] = [:]
    private var pathByID: [String: String] = [:]
    private var iconCache: [String: NSImage] = [:]

    func identity(pid: Int32, procName: String) -> Identity {
        let key = "\(pid).\(procName)"
        if let cached = identities[key] { return cached }

        // ponytail: crude cap against pid-churn growth over weeks of uptime;
        // the cache simply rebuilds itself on the next samples.
        if identities.count > 2000 { identities.removeAll() }

        let identity = resolve(pid: pid, procName: procName)
        identities[key] = identity
        if let appPath = identity.appPath { pathByID[identity.id] = appPath }
        return identity
    }

    func icon(forAppID id: String) -> NSImage? {
        if let cached = iconCache[id] { return cached }
        let icon: NSImage
        if let path = pathByID[id] {
            icon = NSWorkspace.shared.icon(forFile: path)
        } else if !id.hasPrefix("proc:"),
                  let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            // App seen in a previous session's day log but not running now.
            icon = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            icon = NSWorkspace.shared.icon(for: .unixExecutable)
        }
        icon.size = NSSize(width: 32, height: 32)
        iconCache[id] = icon
        return icon
    }

    private func resolve(pid: Int32, procName: String) -> Identity {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else {
            // Process already gone (or unreadable): nettop's truncated name is all we have.
            return Identity(id: "proc:\(procName)", name: procName, appPath: nil)
        }
        let path = String(cString: buffer)

        if let appRange = path.range(of: ".app/") {
            // Outermost .app: folds XPC/helper executables into their parent app.
            let appPath = String(path[..<appRange.lowerBound]) + ".app"
            let name = URL(fileURLWithPath: appPath).deletingPathExtension().lastPathComponent
            let id = Bundle(path: appPath)?.bundleIdentifier ?? "proc:\(name)"
            return Identity(id: id, name: name, appPath: appPath)
        }

        let name = URL(fileURLWithPath: path).lastPathComponent
        return Identity(id: "proc:\(name)", name: name, appPath: nil)
    }
}
