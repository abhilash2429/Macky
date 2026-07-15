//
//  VoiceActivityView.swift
//  leanring-buddy
//
//  The voice waveform in the closed notch. Five center-anchored bars in the
//  "wave" silhouette (tallest in the middle). Reads Macky's existing levels —
//  CompanionManager.currentAudioPowerLevel while listening (minimal) and
//  RealtimeClient.playbackAudioLevel while speaking (lively).
//

import AppKit
import SwiftUI

final class VoiceActivitySpectrum: NSView {

    enum BarMode {
        case idle
        case levelDriven
        case pulse(interval: TimeInterval)
    }

    private var barLayers: [CAShapeLayer] = []
    private var currentScales: [CGFloat] = []
    private var pulseTimer: Timer?
    private var currentMode: BarMode = .idle

    private let barCount = 5
    private let barWidth: CGFloat = 3
    private let spacing: CGFloat = 2
    private let totalHeight: CGFloat = 20

    // "wave" silhouette from the reference glyph — tallest in the middle.
    private let shape: [CGFloat] = [0.42, 0.72, 1.0, 0.78, 0.48]
    private let minScale: CGFloat = 0.14

    // false while listening (minimal), true while speaking (lively).
    var speaking: Bool = true

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setupBars()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        setupBars()
    }

    private func setupBars() {
        let totalWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * spacing
        frame.size = CGSize(width: totalWidth, height: totalHeight)

        for i in 0 ..< barCount {
            let xPos = CGFloat(i) * (barWidth + spacing)
            let bar = CAShapeLayer()
            bar.frame = CGRect(x: xPos, y: 0, width: barWidth, height: totalHeight)
            bar.anchorPoint = CGPoint(x: 0.5, y: 0.5)   // center-anchored
            bar.position = CGPoint(x: xPos + barWidth / 2, y: totalHeight / 2)
            bar.fillColor = NSColor.white.cgColor
            bar.masksToBounds = true

            let path = NSBezierPath(
                roundedRect: CGRect(x: 0, y: 0, width: barWidth, height: totalHeight),
                xRadius: barWidth / 2,
                yRadius: barWidth / 2
            )
            bar.path = path.cgPath
            bar.transform = CATransform3DMakeScale(1, minScale, 1)

            barLayers.append(bar)
            currentScales.append(minScale)
            layer?.addSublayer(bar)
        }
    }

    func setMode(_ mode: BarMode) {
        if case .pulse = mode, case .pulse = currentMode { return }
        stopTimer()
        currentMode = mode
        switch mode {
        case .idle:
            animateBars(to: shape.map { _ in 0.18 }, duration: 0.4)
        case .levelDriven:
            break // driven by setAmplitude(_:)
        case .pulse(let interval):
            startPulse(interval: interval)
        }
    }

    /// Feed a normalized 0–1 level (mic RMS while listening, playback RMS while speaking).
    func setAmplitude(_ amplitude: Float) {
        guard case .levelDriven = currentMode else { return }
        let a = CGFloat(min(max(amplitude, 0), 1))
        let scales = (0 ..< barCount).map { i -> CGFloat in
            if speaking {
                // lively — the silhouette rises and falls with the model's audio
                return min(max(shape[i] * (0.30 + a * 0.80), minScale), 1)
            } else {
                // minimal — short bars that bump as the user speaks
                return min(max(0.16 + a * shape[i] * 0.5, minScale), 0.62)
            }
        }
        animateBars(to: scales, duration: 0.07)
    }

    private func startPulse(interval: TimeInterval) {
        randomPulse()
        pulseTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.randomPulse()
        }
    }

    private func randomPulse() {
        let scales = shape.map { s in max(minScale, s * CGFloat.random(in: 0.35 ... 0.7)) }
        animateBars(to: scales, duration: 0.2)
    }

    private func stopTimer() {
        pulseTimer?.invalidate()
        pulseTimer = nil
    }

    private func animateBars(to scales: [CGFloat], duration: CFTimeInterval) {
        for (i, bar) in barLayers.enumerated() {
            guard i < scales.count else { continue }
            let target = scales[i]
            let anim = CABasicAnimation(keyPath: "transform.scale.y")
            anim.fromValue = currentScales[i]
            anim.toValue = target
            anim.duration = duration
            anim.fillMode = .forwards
            anim.isRemovedOnCompletion = false
            bar.add(anim, forKey: "scaleY_\(i)")
            currentScales[i] = target
        }
    }

    deinit { stopTimer() }
}

// MARK: - SwiftUI Wrapper (rebound to Macky's state)

struct VoiceActivityView: NSViewRepresentable {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var realtimeClient: RealtimeClient

    func makeNSView(context: Context) -> VoiceActivitySpectrum {
        VoiceActivitySpectrum()
    }

    func updateNSView(_ nsView: VoiceActivitySpectrum, context: Context) {
        if companionManager.toolCallActive {
            nsView.setMode(.pulse(interval: 0.28))
            return
        }
        switch companionManager.voiceState {
        case .idle:
            nsView.setMode(.idle)
        case .listening:
            nsView.speaking = false
            nsView.setMode(.levelDriven)
            nsView.setAmplitude(Float(companionManager.currentAudioPowerLevel))
        case .responding:
            nsView.speaking = true
            nsView.setMode(.levelDriven)
            nsView.setAmplitude(realtimeClient.playbackAudioLevel)
        case .processing:
            nsView.setMode(.pulse(interval: 0.18))
        }
    }
}
