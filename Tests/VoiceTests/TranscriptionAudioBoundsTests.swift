import Testing
import Foundation
import AVFoundation
@testable import Voice

@Suite("Transcription audio bounds")
struct TranscriptionAudioBoundsTests {
    @Test func nativeCaptureCAFMatchesConverterBitForBit() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: true,
            AVLinearPCMIsBigEndianKey: false
        ]
        let frames = 3 * 16_384 + 773
        do {
            let writer = try AVAudioFile(forWriting: url, settings: settings,
                                         commonFormat: .pcmFormatFloat32, interleaved: false)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: writer.processingFormat,
                                                        frameCapacity: AVAudioFrameCount(frames)))
            buffer.frameLength = AVAudioFrameCount(frames)
            let channel = try #require(buffer.floatChannelData?[0])
            for i in 0..<frames {
                let time = Double(i) / 16_000
                let signal = Float((0.55 + 0.45 * sin(2 * .pi * 3.1 * time)) *
                    (0.7 * sin(2 * .pi * 230 * time) + 0.3 * sin(2 * .pi * 1_940 * time)))
                switch i {
                case 0..<19_000: channel[i] = i.isMultiple(of: 2) ? 0 : -0.0
                case 19_000..<34_000: channel[i] = signal * 0.000_01
                default: channel[i] = signal * 0.17
                }
            }
            try writer.write(from: buffer)
        }
        let file = try AVAudioFile(forReading: url)
        #expect(TranscriptionService.isNativeCaptureCAF(url: url, file: file))
        let native = try TranscriptionService.readSamplesAt16kMono(url: url)
        let converted = try TranscriptionService.readSamplesAt16kMono(url: url, useNativeCAF: false)
        #expect(native.count == frames)
        #expect(converted.count == frames)
        #expect(zip(native, converted).allSatisfy { $0.0.bitPattern == $0.1.bitPattern })
        #expect(native[1].bitPattern == Float(-0.0).bitPattern)
        #expect(native[25_123] != 0 && abs(native[25_123]) < 0.000_02)
        #expect(abs(native.last ?? 0) > 0.001)
    }

    @Test func integerCAFStillUsesConversion() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16,
            sampleRate: 16_000, channels: 1, interleaved: false))
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings,
                                       commonFormat: .pcmFormatInt16, interleaved: false)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 128))
            buffer.frameLength = 128
            let channel = try #require(buffer.int16ChannelData?[0])
            channel.initialize(repeating: 8192, count: 128)
            try file.write(from: buffer)
        }
        let file = try AVAudioFile(forReading: url)
        #expect(!TranscriptionService.isNativeCaptureCAF(url: url, file: file))
        let samples = try TranscriptionService.readSamplesAt16kMono(url: url)
        #expect(samples.count == 128)
        #expect(samples.allSatisfy { $0 == 0.25 })
    }

    @Test func boundedReaderResamplesCompleteSyntheticFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for rate in [16_000.0, 44_100.0, 48_000.0] {
            let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32,
                sampleRate: rate, channels: 2, interleaved: false))
            let file = root.appendingPathComponent("source-\(Int(rate)).wav")
            let frames = AVAudioFrameCount(rate * 1.25)
            do {
                let writer = try AVAudioFile(forWriting: file, settings: format.settings)
                let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
                buffer.frameLength = frames
                for channel in 0..<2 {
                    for i in 0..<Int(frames) { buffer.floatChannelData![channel][i] = 0.2 }
                }
                try writer.write(from: buffer)
            }
            let samples = try TranscriptionService.readSamplesAt16kMono(url: file)
            #expect(abs(samples.count - 20_000) <= 2)
            let allFinite = samples.allSatisfy { $0.isFinite }
            #expect(allFinite)
            #expect(samples.dropFirst(100).dropLast(100).allSatisfy { abs($0 - 0.2) < 0.01 })
        }
    }

    @Test func twoHoursIsAccepted() throws {
        let frames = Int64(48_000 * 2 * 60 * 60)
        #expect(try TranscriptionService.validateAudioMetadata(frameCount: frames, sampleRate: 48_000, channels: 2) == 16_000 * 2 * 60 * 60)
    }

    @Test func rejectsOversizeAndInvalidMetadata() {
        #expect(throws: TranscriptionService.AudioReadError.self) {
            try TranscriptionService.validateAudioMetadata(frameCount: Int64(48_000 * (3 * 60 * 60 + 1)), sampleRate: 48_000, channels: 2)
        }
        for rate in [0.0, Double.nan, Double.infinity] {
            #expect(throws: TranscriptionService.AudioReadError.self) {
                try TranscriptionService.validateAudioMetadata(frameCount: 1, sampleRate: rate, channels: 1)
            }
        }
        #expect(throws: TranscriptionService.AudioReadError.self) {
            try TranscriptionService.validateAudioMetadata(frameCount: -1, sampleRate: 16_000, channels: 1)
        }
        #expect(throws: TranscriptionService.AudioReadError.self) {
            try TranscriptionService.validateAudioMetadata(frameCount: 1, sampleRate: 16_000, channels: 0)
        }
    }
}
