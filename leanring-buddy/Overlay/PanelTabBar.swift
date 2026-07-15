//
//  PanelTabBar.swift
//  leanring-buddy
//
//  A capsule tab bar for the notch panel's header. Ports the matched-geometry
//  sliding-capsule mechanism from boring.notch's TabSelectionView.swift /
//  TabButton.swift, with one deliberate difference: the tab buttons here also
//  render their label text (TabButton.swift accepts a label but never draws
//  it \u2014 that looked vestigial, so this shows icon + label side by side).
//

import SwiftUI

struct PanelTabBar: View {
    struct Tab: Identifiable {
        let id: String
        let icon: String   // SF Symbol name
        let label: String
    }

    let tabs: [Tab]
    let selectedID: String
    let onSelect: (String) -> Void

    @Namespace private var animation

    var body: some View {
        HStack(spacing: 0) {
            ForEach(tabs) { tab in
                PanelTabButton(icon: tab.icon, label: tab.label) {
                    onSelect(tab.id)
                }
                .frame(height: 26)
                .foregroundStyle(tab.id == selectedID ? .white : .gray)
                .background {
                    if tab.id == selectedID {
                        Capsule()
                            .fill(Color(nsColor: .secondarySystemFill))
                            .matchedGeometryEffect(id: "capsule", in: animation)
                    } else {
                        Capsule()
                            .fill(Color.clear)
                            .matchedGeometryEffect(id: "capsule", in: animation)
                            .hidden()
                    }
                }
            }
        }
        .clipShape(Capsule())
    }
}

private struct PanelTabButton: View {
    let icon: String
    let label: String
    let onClick: () -> Void

    var body: some View {
        Button(action: onClick) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(label)
                    .font(.system(.subheadline, design: .rounded))
            }
            .padding(.horizontal, 15)
            .contentShape(Capsule())
        }
        .buttonStyle(PlainButtonStyle())
    }
}

#Preview {
    struct PreviewWrapper: View {
        @State private var selected = "home"

        var body: some View {
            PanelTabBar(
                tabs: [
                    .init(id: "home", icon: "house.fill", label: "Home"),
                    .init(id: "shelf", icon: "tray.fill", label: "Shelf")
                ],
                selectedID: selected,
                onSelect: { selected = $0 }
            )
            .padding()
        }
    }

    return PreviewWrapper()
}
