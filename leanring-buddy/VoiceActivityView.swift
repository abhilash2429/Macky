//
//  VoiceActivityView.swift
//  leanring-buddy
//
//  The four-bar voice waveform used in the closed notch. Instead of reading
//  MicrophoneMonitor (which would spin up a SECOND AVAudioEngine and fight
//  BuddyDictationManager for the mic), it reads Speed's existing levels —
//  CompanionManager.currentAudioPowerLevel while listening and
//  RealtimeClient.playbackAudioLevel while speaking.
//

import AppKit
import SwiftUI

// MARK: - NSView

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

    private let barCount = 4
    private let barWidth: CGFloat = 3
    private let spacing: CGFloat = 3
    private let totalHeight: CGFloat = 16

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
        let totalWidth = CGFloat(barCount) * (barWidth + spacing)
        frame.size = CGSize(width: totalWidth, height: totalHeight)

        for i in 0 ..< barCount {
            let xPos = CGFloat(i) * (barWidth + spacing)
            let bar = CAShapeLayer()
            bar.frame = CGRect(x: xPos, y: 0, width: barWidth, height: totalHeight)
            bar.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            bar.position = CGPoint(x: xPos + barWidth / 2, y: totalHeight / 2)
            bar.fillColor = NSColor.white.cgColor
            bar.backgroundColor = NSColor.white.cgColor
            bar.masksToBounds = true
            bar.allowsGroupOpacity = false

            let path = NSBezierPath(
                roundedRect: CGRect(x: 0, y: 0, width: barWidth, height: totalHeight),
                xRadius: barWidth / 2,
                yRadius: barWidth / 2
            )
            bar.path = path.cgPath
            bar.transform = CATransform3DMakeScale(1, 0.2, 1)

            barLayers.append(bar)
            currentScales.append(0.2)
            layer?.addSublayer(bar)
        }
    }

    func setMode(_ mode: BarMode) {
        // Re-applying the same pulse mode shouldn't restart the timer every
        // SwiftUI update tick, or the bars never settle into their rhythm.
        if case .pulse = mode, case .pulse = currentMode { return }

        stopTimer()
        currentMode = mode

        switch mode {
        case .idle:
            animateBars(to: Array(repeating: 0.2, count: barCount), duration: 0.4)
        case .levelDriven:
            break // driven by setAmplitude(_:)
        case .pulse(let interval):
            startPulse(interval: interval)
        }
    }

    /// Feed a normalized 0–1 level (mic RMS or playback RMS) when in .levelDriven.
    func setAmplitude(_ amplitude: Float) {
        guard case .levelDriven = currentMode else { return }
        let offsets: [Float] = [-0.12, 0.18, -0.06, 0.14]
        let scales = offsets.map { offset -> CGFloat in
            CGFloat(min(max(amplitude + offset, 0.15), 1.0))
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
        let scales = (0 ..< barCount).map { _ in CGFloat.random(in: 0.30 ... 0.85) }
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

// MARK: - SwiftUI Wrapper (rebound to Speed's state)

struct VoiceActivityView: NSViewRepresentable {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var realtimeClient: RealtimeClient

    func makeNSView(context: Context) -> VoiceActivitySpectrum {
        VoiceActivitySpectrum()
    }

    func updateNSView(_ nsView: VoiceActivitySpectrum, context: Context) {
        // A tool call (e.g. "looking at your screen") gets the working-pulse even
        // if the underlying voiceState hasn't flipped yet.
        if companionManager.toolCallActive {
            nsView.setMode(.pulse(interval: 0.28))
            return
        }

        switch companionManager.voiceState {
        case .idle:
            nsView.setMode(.idle)
        case .listening:
            nsView.setMode(.levelDriven)
            nsView.setAmplitude(Float(companionManager.currentAudioPowerLevel))
        case .responding:
            nsView.setMode(.levelDriven)
            nsView.setAmplitude(realtimeClient.playbackAudioLevel)
        case .processing:
            nsView.setMode(.pulse(interval: 0.18))
        }
    }
}
