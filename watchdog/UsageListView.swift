//
//  UsageListView.swift
//  watchdog
//
//  Created by Mulualem Tekle on 21/07/2026.
//

import SwiftUI

struct UsageListView: View {
    @ObservedObject var store: UsageStore
    var networkBadge: String? = nil
    var onSelect: (String) -> Void = { _ in }
    var onReports: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)

            Divider()

            if store.apps.isEmpty {
                emptyState
            } else {
                // ponytail: ViewThatFits — ScrollView content doesn't draw under
                // ImageRenderer, so short lists render as a plain stack and only
                // overflowing lists get wrapped in a ScrollView.
                ViewThatFits(in: .vertical) {
                    VStack(spacing: 0) {
                        rowStack
                        Spacer(minLength: 0)
                    }
                    ScrollView {
                        rowStack
                    }
                }
            }
        }
    }

    private var rowStack: some View {
        VStack(spacing: 2) {
            ForEach(store.sortedApps) { app in
                UsageRowView(
                    app: app,
                    maxBytes: store.maxBytes,
                    onSelect: { onSelect(app.id) }
                )
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(store.totalBytes.byteString)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .monospacedDigit()

                windowPicker

                if store.dailyLimitBytes > 0 {
                    Text("\(store.todayTotalBytes.byteString) of \(store.dailyLimitBytes.byteString) today")
                        .font(.system(size: 10))
                        .monospacedDigit()
                        .foregroundStyle(store.overLimit ? Color.orange : Color.secondary)
                        .padding(.top, 3)
                }

                if let networkBadge {
                    Text(networkBadge)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(.orange.opacity(0.15)))
                        .padding(.top, 3)
                }
            }

            Spacer()

            overflowMenu
        }
    }

    private var windowPicker: some View {
        Menu {
            Picker("Window", selection: $store.window) {
                ForEach(UsageWindow.allCases) { window in
                    Text(window.rawValue).tag(window)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 3) {
                Text(store.window.rawValue)
                    .font(.subheadline)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(.secondary)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var overflowMenu: some View {
        Menu {
            Picker("Sort apps by", selection: $store.sortMode) {
                ForEach(SortMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.inline)
            Divider()
            Menu("Daily Limit") {
                Picker("Daily Limit", selection: $store.dailyLimitBytes) {
                    Text("Off").tag(Int64(0))
                    Text("200 MB").tag(Int64(200_000_000))
                    Text("500 MB").tag(Int64(500_000_000))
                    Text("1 GB").tag(Int64(1_000_000_000))
                    Text("2 GB").tag(Int64(2_000_000_000))
                    Text("5 GB").tag(Int64(5_000_000_000))
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            Divider()
            Button("Reports") { onReports() }
            Divider()
            Toggle("Start at Login", isOn: Binding(
                get: { LoginItem.isEnabled },
                set: { LoginItem.setEnabled($0) }
            ))
            Divider()
            Button("Reset Statistics") { store.resetStatistics() }
            Divider()
            Button("Quit Watchdog") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(.system(size: 36, weight: .regular))
                .foregroundStyle(.tertiary)
            Text("No Wi-Fi Activity")
                .font(.headline)
            Text("Apps will appear here as they use Wi-Fi.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

struct UsageRowView: View {
    let app: AppUsage
    let maxBytes: Int64
    let onSelect: () -> Void

    @State private var hovering = false

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

                usageBar
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .opacity(hovering ? 1 : 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(hovering ? AnyShapeStyle(.quaternary.opacity(0.6)) : AnyShapeStyle(.clear))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onSelect)
    }

    private var usageBar: some View {
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

#Preview {
    UsageListView(store: UsageStore(apps: UsageStore.sample))
        .frame(width: 320, height: 440)
}
