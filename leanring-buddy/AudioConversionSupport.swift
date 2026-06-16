//
//  AudioConversionSupport.swift
//  leanring-buddy
//
//  Converts microphone buffers to the PCM16 mono 24 kHz chunks expected by the
//  realtime voice session.
//

import AVFoundation
import Foundation

final class BuddyPCM16AudioConverter {
    private let targetSampleRate: Double
    private let outputFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?

    init(targetSampleRate: Double) {
        self.targetSampleRate = targetSampleRate
        self.outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        )!
    }

    func convertToPCM16Data(from inputBuffer: AVAudioPCMBuffer) -> Data? {
        guard inputBuffer.frameLength > 0 else { return nil }
        let activeConverter = converter(for: inputBuffer.format)
        let ratio = targetSampleRate / inputBuffer.format.sampleRate
        let outputCapacity = AVAudioFrameCount(max(1, ceil(Double(inputBuffer.frameLength) * ratio) + 16))
        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputCapacity) else {
            return nil
        }

        var didProvideInput = false
        var conversionError: NSError?
        activeConverter.convert(to: convertedBuffer, error: &conversionError) { _, outStatus in
            if didProvideInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            didProvideInput = true
            outStatus.pointee = .haveData
            return inputBuffer
        }
        if let conversionError {
            print("⚠️ Audio converter failed: \(conversionError)")
            return nil
        }

        guard let channelData = convertedBuffer.floatChannelData?[0] else { return nil }
        let sampleCount = Int(convertedBuffer.frameLength)
        guard sampleCount > 0 else { return nil }

        var output = Data(capacity: sampleCount * MemoryLayout<Int16>.size)
        for sampleIndex in 0..<sampleCount {
            let clampedSample = max(-1, min(1, channelData[sampleIndex]))
            let intSample = Int16(clampedSample * Float(Int16.max))
            var littleEndianSample = intSample.littleEndian
            withUnsafeBytes(of: &littleEndianSample) { bytes in
                output.append(contentsOf: bytes)
            }
        }
        return output
    }

    private func converter(for inputFormat: AVAudioFormat) -> AVAudioConverter {
        if let converter,
           let converterInputFormat,
           converterInputFormat.sampleRate == inputFormat.sampleRate,
           converterInputFormat.channelCount == inputFormat.channelCount,
           converterInputFormat.commonFormat == inputFormat.commonFormat {
            return converter
        }
        let newConverter = AVAudioConverter(from: inputFormat, to: outputFormat)!
        converter = newConverter
        converterInputFormat = inputFormat
        return newConverter
    }
}
