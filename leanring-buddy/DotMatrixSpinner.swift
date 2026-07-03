//
//  DotMatrixSpinner.swift
//  leanring-buddy
//
//  Thinking-state loader for the closed notch. Port of the "DotmSquare12"
//  dot-matrix loader (zzzzshawn/matrix): a 5x5 grid whose dots ripple out from
//  cell (2,2) by Manhattan distance. Center-origin opacity ripple, white dots.
//

import AppKit
import SwiftUI

final class DotMatrixSpinner: NSView {
    private let gridSize = 5
    private let dot: CGFloat = 3
    private let gap: CGFloat = 2
    private let cycle: CFTimeInterval = 1.5
    private let origin = (row: 1, col: 1)   // cell (2,2), zero-based

    override init(frame f: NSRect) { super.init(frame: f); wantsLayer = true; build() }
    required init?(coder c: NSCoder) { super.init(coder: c); wantsLayer = true; build() }

    private func build() {
        let side = CGFloat(gridSize) * dot + CGFloat(gridSize - 1) * gap
        frame.size = CGSize(width: side, height: side)

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        for r in 0 ..< gridSize {
            for c in 0 ..< gridSize {
                let layer = CAShapeLayer()
                let x = CGFloat(c) * (dot + gap)
                let y = CGFloat(gridSize - 1 - r) * (dot + gap)   // AppKit y is bottom-up
                layer.path = CGPath(ellipseIn: CGRect(x: x, y: y, width: dot, height: dot), transform: nil)
                layer.fillColor = NSColor.white.cgColor

                let ring = min(6, abs(r - origin.row) + abs(c - origin.col))

                if reduceMotion {
                    // static silhouette: brighter near the origin, dim at the edges
                    layer.opacity = Float(0.24 + (1.0 - Double(ring) / 6.0) * 0.55)
                } else {
                    layer.opacity = 0.10
                    let a = CAKeyframeAnimation(keyPath: "opacity")
                    a.values   = [0.10, 1.0, 0.24, 0.10]   // 0.625*base, peak, 0.5*(base+mid)
                    a.keyTimes = [0, 0.34, 0.60, 1.0]
                    a.duration = cycle
                    a.beginTime = CACurrentMediaTime() + Double(ring) * 0.16 * cycle
                    a.repeatCount = .infinity
                    a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    layer.add(a, forKey: "ripple")
                }

                self.layer?.addSublayer(layer)
            }
        }
    }
}

struct DotMatrixLoaderView: NSViewRepresentable {
    func makeNSView(context: Context) -> DotMatrixSpinner { DotMatrixSpinner() }
    func updateNSView(_ v: DotMatrixSpinner, context: Context) {}
}
