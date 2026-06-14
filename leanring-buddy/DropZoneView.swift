//
//  DropZoneView.swift
//  leanring-buddy
//
//  The affordance shown inside the DropZonePanel while a file is dragged over the
//  notch. Same visual treatment as the history panel: flat top corners (flush with
//  the notch bar's bottom), rounded bottom corners, solid black fill, so it reads
//  as a continuous surface growing out of the bar.
//
//  Text-only "Drop files here" affordance. Live per-file thumbnail previews during
//  an AppKit drag would need async QuickLook thumbnail generation mid-drag, which
//  is non-trivial; the spec pre-authorized this text-only fallback. (TODO: add a
//  thumbnail row if richer previews are wanted.)
//

import SwiftUI

struct DropZoneView: View {
    /// Flat top, rounded bottom — reusing the notch bar's bottom corner radius.
    private var panelShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: NotchPanelController.notchBottomCornerRadius,
            bottomTrailingRadius: NotchPanelController.notchBottomCornerRadius,
            topTrailingRadius: 0,
            style: .continuous
        )
    }

    var body: some View {
        ZStack {
            Color.black

            VStack(spacing: 8) {
                Image(systemName: "arrow.down.doc.fill")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
                Text("Drop files here")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.6))
            }
            .padding(12)
        }
        .clipShape(panelShape)
    }
}

#Preview {
    DropZoneView()
        .frame(width: 200, height: 120)
        .padding(40)
        .background(Color.gray)
}
