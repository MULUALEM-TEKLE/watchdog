//
//  ReportsView.swift
//  watchdog
//
//  Created by Mulualem Tekle on 21/07/2026.
//
//  Graph-based usage report: stacked bars per hour (Today) or per day
//  (This week), peak insight, and per-bucket app breakdown on selection.
//

import SwiftUI
import Charts

struct ReportsView: View {
    @ObservedObject var store: UsageStore
    var onBack: () -> Void = {}

    @State private var scope: ReportScope = .today
    @State private var selectedKey: String?
    @State private var backHovering = false

    private static let palette: [Color] = [.blue, .green, .orange, .purple, .teal]

    /// One stacked segment: an app's (or "Other"'s) bytes within one bucket.
    private struct Slice: Identifiable {
        let bucketKey: String
        let series: String
        let bytes: Int64
        var id: String { "\(bucketKey)|\(series)" }
    }

    var body: some View {
        let buckets = store.reportBuckets(for: scope)

        VStack(spacing: 0) {
            header
            Divider()

            Picker("Scope", selection: $scope) {
                ForEach(ReportScope.allCases) { scope in
                    Text(scope.rawValue).tag(scope)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.top, 12)

            if buckets.allSatisfy({ $0.totalBytes == 0 }) {
                emptyState
            } else {
                chartSection(buckets: buckets)
                Divider()
                breakdownSection(buckets: buckets)
            }
        }
        .onChange(of: scope) { selectedKey = nil }
    }

    private var header: some View {
        HStack {
            Button(action: onBack) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Back")
                        .font(.system(size: 13))
                }
                .foregroundStyle(backHovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            }
            .buttonStyle(.plain)
            .onHover { backHovering = $0 }

            Spacer()

            Text("Reports")
                .font(.system(size: 13, weight: .semibold))

            Spacer()

            // Balances the back button so the title stays centered.
            Color.clear.frame(width: 44, height: 1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Chart

    /// Scope-wide top-5 app names; everything else stacks as "Other".
    private func topNames(_ buckets: [ReportBucket]) -> [String] {
        var totals: [String: Int64] = [:]
        for bucket in buckets {
            for app in bucket.apps {
                totals[app.name, default: 0] += app.totalBytes
            }
        }
        return totals.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(5).map(\.key)
    }

    private func slices(buckets: [ReportBucket], top: [String]) -> [Slice] {
        buckets.flatMap { bucket in
            var bySeries: [String: Int64] = [:]
            for app in bucket.apps {
                bySeries[top.contains(app.name) ? app.name : "Other", default: 0] += app.totalBytes
            }
            // Top apps first so stack order matches the legend; "Other" on top.
            return (top + ["Other"]).compactMap { series in
                bySeries[series].map { Slice(bucketKey: bucket.key, series: series, bytes: $0) }
            }
        }
    }

    @ViewBuilder
    private func chartSection(buckets: [ReportBucket]) -> some View {
        let top = topNames(buckets)
        let hasOther = buckets.contains { bucket in bucket.apps.contains { !top.contains($0.name) } }
        let domain = top + (hasOther ? ["Other"] : [])
        let range = Array(Self.palette.prefix(top.count)) + (hasOther ? [Color.gray] : [])

        Chart(slices(buckets: buckets, top: top)) { slice in
            BarMark(
                x: .value("Bucket", slice.bucketKey),
                y: .value("Bytes", Double(slice.bytes))
            )
            .foregroundStyle(by: .value("App", slice.series))
            // Dim non-selected buckets so the active bucket is visible on the chart.
            .opacity(selectedKey == nil || slice.bucketKey == selectedKey ? 1 : 0.35)
        }
        .chartXScale(domain: buckets.map(\.key))
        .chartForegroundStyleScale(domain: domain, range: range)
        .chartLegend(position: .bottom, spacing: 6)
        .chartXSelection(value: $selectedKey)
        .chartXAxis {
            AxisMarks(values: scope == .today ? ["0", "6", "12", "18"] : buckets.map(\.key)) { value in
                AxisValueLabel {
                    if let key = value.as(String.self) {
                        Text(scope == .today ? key : String(key.prefix(1)))
                            .font(.system(size: 9))
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel {
                    if let bytes = value.as(Double.self) {
                        Text(bytes == 0 ? "0" : Int64(bytes).byteString)
                            .font(.system(size: 9))
                    }
                }
            }
        }
        .font(.system(size: 10))
        // Pin the plot, not the whole chart: legend rows grow downward instead of
        // eating plot height (which jumped between scopes as the legend wrapped).
        .chartPlotStyle { $0.frame(height: 110) }
        .padding(.horizontal, 16)
        .padding(.top, 12)

        if let peak = store.peakSummary(for: scope) {
            Text("Peak \(peak.bucketTitle) · \(peak.totalBytes.byteString) · mostly \(peak.topAppName) (\(Int((peak.share * 100).rounded()))%)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
        }
    }

    // MARK: - Breakdown rows

    /// Selected bucket's apps, or the whole scope merged per app.
    private func breakdownApps(buckets: [ReportBucket]) -> (title: String, apps: [AppUsage]) {
        if let key = selectedKey, let bucket = buckets.first(where: { $0.key == key }) {
            return (bucket.title, bucket.apps.sorted { $0.totalBytes > $1.totalBytes })
        }
        var merged: [String: AppUsage] = [:]
        for bucket in buckets {
            for app in bucket.apps {
                merged[app.id, default: AppUsage(id: app.id, name: app.name, icon: app.icon,
                                                 bytesIn: 0, bytesOut: 0)].bytesIn += app.bytesIn
                merged[app.id]?.bytesOut += app.bytesOut
            }
        }
        return (scope.rawValue, merged.values.sorted { $0.totalBytes > $1.totalBytes })
    }

    @ViewBuilder
    private func breakdownSection(buckets: [ReportBucket]) -> some View {
        let breakdown = breakdownApps(buckets: buckets)
        let maxBytes = breakdown.apps.map(\.totalBytes).max() ?? 0

        HStack {
            Text(breakdown.title)
                .font(.caption2.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            Spacer()
            if selectedKey != nil {
                Button {
                    selectedKey = nil
                } label: {
                    Text("✕ clear")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 2)

        if breakdown.apps.isEmpty {
            Text("No activity in this period.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // ponytail: same ViewThatFits trick as UsageListView — ScrollView
            // content doesn't draw under ImageRenderer.
            ViewThatFits(in: .vertical) {
                VStack(spacing: 0) {
                    rowStack(apps: breakdown.apps, maxBytes: maxBytes)
                    Spacer(minLength: 0)
                }
                ScrollView {
                    rowStack(apps: breakdown.apps, maxBytes: maxBytes)
                }
            }
        }
    }

    private func rowStack(apps: [AppUsage], maxBytes: Int64) -> some View {
        VStack(spacing: 2) {
            ForEach(apps) { app in
                ReportRowView(app: app, maxBytes: maxBytes)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 36, weight: .regular))
                .foregroundStyle(.tertiary)
            Text("No Data Yet")
                .font(.headline)
            Text("Usage will appear here as apps use Wi-Fi.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

/// Same visual language as UsageRowView, minus the block checkbox and chevron.
private struct ReportRowView: View {
    let app: AppUsage
    let maxBytes: Int64

    private var fraction: CGFloat {
        guard maxBytes > 0 else { return 0 }
        return CGFloat(app.totalBytes) / CGFloat(maxBytes)
    }

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let icon = app.icon {
                    Image(nsImage: icon)
                        .resizable()
                } else {
                    Image(systemName: "app.dashed")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(.quaternary.opacity(0.5))
                                .frame(width: 26, height: 26)
                        )
                }
            }
            .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(app.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    Text(app.totalBytes.byteString)
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(.quaternary.opacity(0.6))
                        Capsule()
                            .fill(Color.accentColor)
                            .frame(width: app.totalBytes > 0 ? max(4, geo.size.width * fraction) : 0)
                    }
                }
                .frame(height: 4)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }
}

#Preview {
    ReportsView(store: UsageStore(apps: UsageStore.sample))
        .frame(width: 320, height: 440)
}
