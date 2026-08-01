//
//  MenuContentView.swift
//  watchdog
//
//  Created by Mulualem Tekle on 21/07/2026.
//

import SwiftUI

struct MenuContentView: View {
    enum Screen: Equatable {
        case list
        case appDetail(String)
        case reports
    }

    @ObservedObject var store: UsageStore
    @ObservedObject var network: NetworkStatus
    @State private var screen: Screen = .list

    var body: some View {
        ZStack {
            switch screen {
            case .list:
                UsageListView(store: store,
                              networkBadge: network.badge,
                              onSelect: { screen = .appDetail($0) },
                              onReports: { screen = .reports })
                    .transition(.move(edge: .leading))
            case .appDetail(let id):
                AppDetailView(store: store, appID: id) {
                    screen = .list
                }
                .transition(.move(edge: .trailing))
            case .reports:
                ReportsView(store: store) {
                    screen = .list
                }
                .transition(.move(edge: .trailing))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: screen)
        .frame(width: 320, height: 440)
        .background(.regularMaterial)
    }
}

#Preview {
    MenuContentView(store: UsageStore(apps: UsageStore.sample), network: NetworkStatus())
}
