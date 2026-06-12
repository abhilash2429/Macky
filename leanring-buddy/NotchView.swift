//
//  NotchView.swift
//  leanring-buddy
//
//  SwiftUI content rendered inside the notch panel (see OverlayWindow.swift).
//  Draws a black "notch pill" that stays locked to the notch height and only
//  ever expands HORIZONTALLY: at idle it's the hardware notch width, and while
//  the companion is listening / thinking / speaking it animates out to a wider
//  pill, centered on screen. It never grows downward — the height is fixed at
//  the notch height at all times.
//
//  The enclosing panel is sized to the maximum (expanded) footprint with a clear
//  background, so the area outside this black pill is transparent. That keeps the
//  panel's height and Y position constant while the visible width animates.
//

import SwiftUI

struct NotchView: View {
    @ObservedObject var viewModel: NotchPanelViewModel

    /// Radius for the two bottom corners. The top edge is flush with the screen,
    /// so only the bottom corners round — matching the hardware notch's pill shape.
    private let bottomCornerRadius: CGFloat = 10

    var body: some View {
        let currentWidth = viewModel.isActive ? viewModel.expandedWidth : viewModel.idleWidth

        UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: bottomCornerRadius,
            bottomTrailingRadius: bottomCornerRadius,
            topTrailingRadius: 0,
            style: .continuous
        )
        .fill(Color.black)
        // Fixed notch height; width animates between idle and expanded.
        .frame(width: currentWidth, height: viewModel.notchHeight)
        // Center the pill within the full-width panel so it expands left+right.
        .frame(maxWidth: .infinity, alignment: .center)
        .animation(.spring(response: 0.3), value: viewModel.isActive)
        .ignoresSafeArea()
    }
}
