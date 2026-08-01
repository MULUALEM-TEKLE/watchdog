//
//  NettopSampler.swift
//  watchdog
//
//  Created by Mulualem Tekle on 21/07/2026.
//
//  Samples per-process Wi-Fi usage by polling /usr/bin/nettop in CSV mode.
//  Counters are cumulative per socket lifetime; UsageStore turns them into deltas.
//

import Foundation

struct ConnSample: Sendable, Equatable {
    /// Full nettop connection field, e.g. "tcp4 192.168.1.2:50550<->142.250.202.42:443".
    /// Unique enough per socket (local port) to serve as the delta-baseline key.
    let connID: String
    let remoteHost: String?
    let bytesIn: Int64
    let bytesOut: Int64
}

struct ProcSample: Sendable, Equatable {
    let pid: Int32
    let procName: String
    let bytesIn: Int64
    let bytesOut: Int64
    var connections: [ConnSample]
}

enum NettopSampler {
    /// One blocking nettop sample. Safe to call off-main; returns "" on failure.
    nonisolated static func sample() -> String {
        autoreleasepool {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
            process.arguments = ["-x", "-n", "-L", "1", "-t", "wifi",
                                 "-J", "time,interface,state,bytes_in,bytes_out"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return "" }
            // Kill switch: a wedged nettop (sleep/wake, interface teardown) would
            // block the read forever and silently halt sampling. terminate() closes
            // its stdout so the read returns; the loop's next tick recovers.
            DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
                if process.isRunning { process.terminate() }
            }
            // Read before waiting: output exceeds the 64KB pipe buffer.
            // readToEnd (not readDataToEndOfFile): read errors return nil instead
            // of raising an ObjC exception Swift can't catch.
            let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
            process.waitUntilExit()
            try? pipe.fileHandleForReading.close()
            return String(data: data, encoding: .utf8) ?? ""
        }
    }
}

enum NettopParser {
    /// Parses `nettop -x -n -L 1 -J time,interface,state,bytes_in,bytes_out` output:
    /// process rows ("procname.pid") each followed by their connection sub-rows
    /// ("proto local<->remote"). Header and malformed lines are skipped.
    nonisolated static func parse(_ text: String) -> [ProcSample] {
        var result: [ProcSample] = []
        for line in text.split(separator: "\n") {
            // Fixed layout: time,name,interface,state,bytes_in,bytes_out,<trailing empty>
            // — but names may themselves contain commas, so index from both ends.
            let parts = line.split(separator: ",", omittingEmptySubsequences: false)
            guard parts.count >= 7,
                  let bytesIn = Int64(parts[parts.count - 3]),
                  let bytesOut = Int64(parts[parts.count - 2]) else { continue }
            let name = parts[1..<(parts.count - 5)].joined(separator: ",")

            if name.contains("<->") {
                guard !result.isEmpty else { continue }
                result[result.count - 1].connections.append(
                    ConnSample(connID: name, remoteHost: remoteHost(from: name),
                               bytesIn: bytesIn, bytesOut: bytesOut))
            } else {
                // "procname.pid" — names can contain dots, pid is after the LAST dot.
                guard let dot = name.lastIndex(of: "."),
                      let pid = Int32(name[name.index(after: dot)...]) else { continue }
                result.append(ProcSample(pid: pid, procName: String(name[..<dot]),
                                         bytesIn: bytesIn, bytesOut: bytesOut,
                                         connections: []))
            }
        }
        return result
    }

    /// True when the address is a routable public-internet host. Private ranges,
    /// link-local, loopback, multicast, and IPv6 unique-local are LAN traffic
    /// (phone transfers, mDNS, AirPlay…), not internet usage.
    nonisolated static func isInternetHost(_ host: String) -> Bool {
        if host.contains(":") { // IPv6
            let h = host.lowercased()
            // IPv4-mapped: classify the embedded IPv4 address.
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

    /// Extracts the remote address from "proto local<->remote", stripping the port.
    /// nettop separates IPv4 ports with ":" and IPv6 ports with "." (yes, really).
    /// Returns nil for wildcards like "*:*" (unbound/multicast sockets).
    nonisolated static func remoteHost(from connID: String) -> String? {
        guard let range = connID.range(of: "<->") else { return nil }
        let remote = connID[range.upperBound...]
        let host: Substring
        if remote.filter({ $0 == ":" }).count == 1, let colon = remote.lastIndex(of: ":") {
            host = remote[..<colon]
        } else if let dot = remote.lastIndex(of: ".") {
            host = remote[..<dot]
        } else {
            host = remote
        }
        return (host.isEmpty || host == "*") ? nil : String(host)
    }
}
