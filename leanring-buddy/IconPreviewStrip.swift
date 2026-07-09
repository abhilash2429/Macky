//
//  IconPreviewStrip.swift
//  leanring-buddy
//
//  A reusable "section preview" row for the notch panel's Home page (used for
//  both the Skills and Connectors sections). Styled to match the boring.notch
//  visual vocabulary used elsewhere in this app (see PanelTabBar.swift and
//  SkillsWindowView.swift) \u2014 system-adaptive colors/materials, not Macky's
//  DesignSystem.swift.
//

import SwiftUI

struct IconPreviewStrip: View {
    struct PreviewIcon: Identifiable {
        let id: String
        let systemName: String?   // SF Symbol fallback/primary icon
        let image: NSImage?       // optional bundled logo image; if present, prefer rendering this over systemName
    }

    let title: String
    let statusText: String?       // e.g. "3 active"; nil to omit
    let icons: [PreviewIcon]
    let onTap: () -> Void

    private static let tileSize: CGFloat = 30
    private static let tileSpacing: CGFloat = 8
    private static let maxIcons = 4

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 8) {
                header
                iconRow
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(.headline, design: .rounded))
                .foregroundColor(.white.opacity(0.9))

            Spacer()

            if let statusText {
                Text(statusText)
                    .font(.system(.footnote, design: .rounded))
                    .foregroundColor(.white.opacity(0.6))
            }
        }
    }

    private var iconRow: some View {
        HStack(spacing: Self.tileSpacing) {
            ForEach(icons.prefix(Self.maxIcons)) { icon in
                IconTile(icon: icon)
            }
            AddTile()
        }
    }
}

private struct IconTile: View {
    let icon: IconPreviewStrip.PreviewIcon

    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color(nsColor: .secondarySystemFill))
            .frame(width: 30, height: 30)
            .overlay {
                if let image = icon.image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 16, height: 16)
                } else if let systemName = icon.systemName {
                    Image(systemName: systemName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white.opacity(0.85))
                }
            }
    }
}

private struct AddTile: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(Color.accentColor.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))
            )
            .frame(width: 30, height: 30)
            .overlay(
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.accentColor)
            )
    }
}

#Preview {
    IconPreviewStrip(
        title: "Skills",
        statusText: "3 active",
        icons: [
            .init(id: "1", systemName: "calendar", image: nil),
            .init(id: "2", systemName: "bell", image: nil),
            .init(id: "3", systemName: "mic", image: nil),
            .init(id: "4", systemName: "gearshape", image: nil),
            .init(id: "5", systemName: "star", image: nil)
        ],
        onTap: { print("tapped") }
    )
    .padding()
}
