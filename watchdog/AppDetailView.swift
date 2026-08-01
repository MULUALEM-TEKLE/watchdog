//
//  AppDetailView.swift
//  watchdog
//
//  Created by Mulualem Tekle on 21/07/2026.
//

import SwiftUI

struct AppDetailView: View {
    @ObservedObject var store: UsageStore
    let appID: String
    var onBack: () -> Void = {}

    @State private var backHovering = false

    private var app: AppUsage? {
        store.apps.first { $0.id == appID }
    }

    var body: some View {
        VStack(spacing: 0) {
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
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            if let app {
                content(for: app)
            } else {
                Spacer()
                Text("App not found")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    private func content(for app: AppUsage) -> some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Group {
                    if let icon = app.icon {
                        Image(nsImage: icon)
                            .resizable()
                    } else {
                        Image(systemName: "app.dashed")
                            .font(.system(size: 26, weight: .medium))
                            .foregroundStyle(.secondary)
                            .background(
                                RoundedRectangle(cornerRadius: 13, style: .continuous)
                                    .fill(.quaternary.opacity(0.5))
                                    .frame(width: 56, height: 56)
                            )
                    }
                }
                .frame(width: 56, height: 56)
                .opacity(app.isBlocked ? 0.4 : 1)

                Text(app.name)
                    .font(.headline)

                Text(app.totalBytes.byteString)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .monospacedDigit()

                Text("used \(store.window.caption)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 20)
            .padding(.bottom, 16)

            VStack(spacing: 1) {
                statRow(symbol: "arrow.down.circle.fill", label: "Downloaded", value: app.bytesIn.byteString)
                Divider().padding(.leading, 34)
                statRow(symbol: "arrow.up.circle.fill", label: "Uploaded", value: app.bytesOut.byteString)
            }
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.quaternary.opacity(0.4))
            )
            .padding(.horizontal, 16)

            Toggle(isOn: Binding(
                get: { app.isBlocked },
                set: { _ in store.toggleBlock(app.id) }
            )) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Block network access")
                        .font(.system(size: 13))
                    Text(app.id)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .tint(.red)
            .padding(.horizontal, 16)
            .padding(.top, 16)

            hostsSection(for: app)

            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func hostsSection(for app: AppUsage) -> some View {
        let hosts = store.hostUsage(for: app.id)
        if !hosts.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("Top remote hosts · this session")
                    .font(.caption2.weight(.semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 4)

                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(hosts.prefix(15)) { host in
                            HStack {
                                Text(host.host)
                                    .font(.system(size: 12))
                                    .monospacedDigit()
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 8)
                                Text("\(host.bytesOut.byteString) ↑  \(host.bytesIn.byteString) ↓")
                                    .font(.system(size: 11))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
        }
    }

    private func statRow(symbol: String, label: String, value: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(label)
                .font(.system(size: 13))
            Spacer()
            Text(value)
                .font(.system(size: 13))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }
}

#Preview {
    AppDetailView(store: UsageStore(apps: UsageStore.sample), appID: "com.example.browser")
        .frame(width: 320, height: 440)
}
