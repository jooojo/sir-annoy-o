import Accelerate
import AVFoundation
import AudioToolbox
import Foundation
import MediaToolbox

struct AudioMotionSnapshot: Equatable {
    var sourceTime: TimeInterval
    var energy: Double
    var low: Double
    var lowMid: Double
    var midHigh: Double
    var high: Double
    var pulse: Double
    var phase: Double

    static let zero = AudioMotionSnapshot(
        sourceTime: 0,
        energy: 0,
        low: 0,
        lowMid: 0,
        midHigh: 0,
        high: 0,
        pulse: 0,
        phase: 0
    )
}

struct AudioAnalysisDiagnostics: Equatable {
    var sourceTime: TimeInterval
    var rmsDecibels: Double
    var lowDecibels: Double
    var lowMidDecibels: Double
    var midHighDecibels: Double
    var highDecibels: Double
    var spectralFlux: Double
    var onsetThreshold: Double
    var onsetCount: Int

    static let zero = AudioAnalysisDiagnostics(
        sourceTime: 0,
        rmsDecibels: -120,
        lowDecibels: -120,
        lowMidDecibels: -120,
        midHighDecibels: -120,
        highDecibels: -120,
        spectralFlux: 0,
        onsetThreshold: 0,
        onsetCount: 0
    )
}

private struct AdaptiveBandEnvelope {
    private var valueDecibels = -120.0
    private var floorDecibels = -78.0
    private var peakDecibels = -36.0
    private var isInitialized = false

    mutating func update(
        decibels: Double,
        deltaTime: TimeInterval,
        attack: TimeInterval,
        release: TimeInterval
    ) -> Double {
        if !isInitialized {
            valueDecibels = decibels
            floorDecibels = min(decibels, -72)
            peakDecibels = max(decibels, -36)
            isInitialized = true
        }

        let envelopeTime = decibels > valueDecibels ? attack : release
        valueDecibels += (decibels - valueDecibels) * smoothingBlend(
            deltaTime: deltaTime,
            timeConstant: envelopeTime
        )

        let floorTime = valueDecibels < floorDecibels ? 0.08 : 8.0
        floorDecibels += (valueDecibels - floorDecibels) * smoothingBlend(
            deltaTime: deltaTime,
            timeConstant: floorTime
        )

        let peakTime = valueDecibels > peakDecibels ? 0.05 : 3.0
        peakDecibels += (valueDecibels - peakDecibels) * smoothingBlend(
            deltaTime: deltaTime,
            timeConstant: peakTime
        )

        floorDecibels = min(floorDecibels, peakDecibels - 18)
        let relative = clamp(
            (valueDecibels - floorDecibels) / max(18, peakDecibels - floorDecibels)
        )
        let silenceGate = smoothStep((valueDecibels + 78) / 30)
        return relative * silenceGate
    }
}

private struct SignalEnvelope {
    private var value = 0.0

    mutating func update(
        target: Double,
        deltaTime: TimeInterval,
        attack: TimeInterval,
        release: TimeInterval
    ) -> Double {
        let timeConstant = target > value ? attack : release
        value += (target - value) * smoothingBlend(
            deltaTime: deltaTime,
            timeConstant: timeConstant
        )
        return value
    }
}

private struct SpectralFluxPeakPicker {
    private(set) var threshold = 0.22
    private(set) var onsetCount = 0

    private var mean = 0.0
    private var deviation = 0.05
    private var previousPreviousFlux = 0.0
    private var previousFlux = 0.0
    private var previousThreshold = 0.22
    private var secondsSinceOnset = 1.0

    mutating func ingest(flux: Double, deltaTime: TimeInterval) -> Double {
        secondsSinceOnset += deltaTime

        var onsetStrength = 0.0
        if previousFlux > previousPreviousFlux,
           previousFlux >= flux,
           previousFlux > previousThreshold,
           secondsSinceOnset >= 0.10 {
            onsetStrength = clamp(
                (previousFlux - previousThreshold) / max(0.75, previousThreshold * 2)
            )
            secondsSinceOnset = 0
            onsetCount += 1
        }

        let meanBlend = smoothingBlend(deltaTime: deltaTime, timeConstant: 0.75)
        let boundedFlux = min(flux, mean + max(0.5, deviation * 4))
        mean += (boundedFlux - mean) * meanBlend
        deviation += (abs(boundedFlux - mean) - deviation) * meanBlend
        threshold = mean + max(0.22, deviation * 1.8)

        previousPreviousFlux = previousFlux
        previousFlux = flux
        previousThreshold = threshold
        return onsetStrength
    }
}

final class AudioFeatureExtractor {
    static let fftSize = 2_048
    static let hopSize = 512

    private(set) var snapshot = AudioMotionSnapshot.zero
    private(set) var diagnostics = AudioAnalysisDiagnostics.zero

    let sampleRate: Double

    private let dft: vDSP.DiscreteFourierTransform<Float>
    private let window: [Float]
    private let zeroImaginary: [Float]
    private let visualBandRanges: [Range<Int>]
    private let noveltyBandRanges: [Range<Int>]

    private var sampleRing = [Float](repeating: 0, count: AudioFeatureExtractor.fftSize)
    private var inputFrame = [Float](repeating: 0, count: AudioFeatureExtractor.fftSize)
    private var windowedFrame = [Float](repeating: 0, count: AudioFeatureExtractor.fftSize)
    private var outputReal = [Float](repeating: 0, count: AudioFeatureExtractor.fftSize)
    private var outputImaginary = [Float](repeating: 0, count: AudioFeatureExtractor.fftSize)
    private var squaredMagnitudes = [Float](
        repeating: 0,
        count: AudioFeatureExtractor.fftSize / 2
    )
    private var currentLogSpectrum: [Double]
    private var previousLogSpectrum: [Double]

    private var writeIndex = 0
    private var totalSamples = 0
    private var samplesSinceAnalysis = 0
    private var hasPreviousSpectrum = false
    private var lastSourceTime = 0.0
    private var flowPhase = 0.0
    private var pulse = 0.0

    private var energyEnvelope = SignalEnvelope()
    private var lowEnvelope = AdaptiveBandEnvelope()
    private var lowMidEnvelope = AdaptiveBandEnvelope()
    private var midHighEnvelope = AdaptiveBandEnvelope()
    private var highEnvelope = AdaptiveBandEnvelope()
    private var peakPicker = SpectralFluxPeakPicker()

    init(sampleRate: Double) {
        self.sampleRate = max(sampleRate, 1)
        dft = try! vDSP.DiscreteFourierTransform<Float>(
            count: Self.fftSize,
            direction: .forward,
            transformType: .complexComplex,
            ofType: Float.self
        )
        window = vDSP.window(
            ofType: Float.self,
            usingSequence: .hanningDenormalized,
            count: Self.fftSize,
            isHalfWindow: false
        )
        zeroImaginary = [Float](repeating: 0, count: Self.fftSize)
        visualBandRanges = Self.makeRanges(
            edges: [40, 180, 700, 3_500, 10_000],
            sampleRate: self.sampleRate
        )
        noveltyBandRanges = Self.makeLogRanges(
            count: 24,
            lowerFrequency: 40,
            upperFrequency: 10_000,
            sampleRate: self.sampleRate
        )
        currentLogSpectrum = [Double](repeating: -120, count: noveltyBandRanges.count)
        previousLogSpectrum = [Double](repeating: -120, count: noveltyBandRanges.count)
    }

    func ingest(_ samples: [Float], sourceStartTime: TimeInterval? = nil) {
        for index in samples.indices {
            let sourceTime = sourceStartTime.map {
                $0 + Double(index) / sampleRate
            }
            ingest(sample: samples[index], sourceTime: sourceTime)
        }
    }

    func ingest(sample: Float, sourceTime: TimeInterval?) {
        sampleRing[writeIndex] = sample
        writeIndex = (writeIndex + 1) % Self.fftSize
        totalSamples += 1
        lastSourceTime = sourceTime ?? (Double(totalSamples - 1) / sampleRate)

        if totalSamples == Self.fftSize {
            samplesSinceAnalysis = 0
            analyzeFrame()
        } else if totalSamples > Self.fftSize {
            samplesSinceAnalysis += 1
            if samplesSinceAnalysis >= Self.hopSize {
                samplesSinceAnalysis -= Self.hopSize
                analyzeFrame()
            }
        }
    }

    func reset() {
        sampleRing.withUnsafeMutableBufferPointer { buffer in
            buffer.initialize(repeating: 0)
        }
        inputFrame.withUnsafeMutableBufferPointer { buffer in
            buffer.initialize(repeating: 0)
        }
        windowedFrame.withUnsafeMutableBufferPointer { buffer in
            buffer.initialize(repeating: 0)
        }
        outputReal.withUnsafeMutableBufferPointer { buffer in
            buffer.initialize(repeating: 0)
        }
        outputImaginary.withUnsafeMutableBufferPointer { buffer in
            buffer.initialize(repeating: 0)
        }
        squaredMagnitudes.withUnsafeMutableBufferPointer { buffer in
            buffer.initialize(repeating: 0)
        }
        currentLogSpectrum.withUnsafeMutableBufferPointer { buffer in
            buffer.initialize(repeating: -120)
        }
        previousLogSpectrum.withUnsafeMutableBufferPointer { buffer in
            buffer.initialize(repeating: -120)
        }

        snapshot = .zero
        diagnostics = .zero
        writeIndex = 0
        totalSamples = 0
        samplesSinceAnalysis = 0
        hasPreviousSpectrum = false
        lastSourceTime = 0
        flowPhase = 0
        pulse = 0
        energyEnvelope = SignalEnvelope()
        lowEnvelope = AdaptiveBandEnvelope()
        lowMidEnvelope = AdaptiveBandEnvelope()
        midHighEnvelope = AdaptiveBandEnvelope()
        highEnvelope = AdaptiveBandEnvelope()
        peakPicker = SpectralFluxPeakPicker()
    }

    private func analyzeFrame() {
        for offset in 0 ..< Self.fftSize {
            inputFrame[offset] = sampleRing[(writeIndex + offset) % Self.fftSize]
        }
        vDSP.multiply(inputFrame, window, result: &windowedFrame)
        dft.transform(
            inputReal: windowedFrame,
            inputImaginary: zeroImaginary,
            outputReal: &outputReal,
            outputImaginary: &outputImaginary
        )

        for index in squaredMagnitudes.indices {
            let real = outputReal[index]
            let imaginary = outputImaginary[index]
            squaredMagnitudes[index] = real * real + imaginary * imaginary
        }

        let rms = rootMeanSquare(inputFrame)
        let rmsDecibels = 20 * log10(max(rms, 0.000_001))
        let lowDecibels = bandDecibels(visualBandRanges[0])
        let lowMidDecibels = bandDecibels(visualBandRanges[1])
        let midHighDecibels = bandDecibels(visualBandRanges[2])
        let highDecibels = bandDecibels(visualBandRanges[3])
        let deltaTime = Double(Self.hopSize) / sampleRate

        let energyTarget = smoothStep((rmsDecibels + 58) / 48)
        let energy = energyEnvelope.update(
            target: energyTarget,
            deltaTime: deltaTime,
            attack: 0.025,
            release: 0.32
        )
        let low = lowEnvelope.update(
            decibels: lowDecibels,
            deltaTime: deltaTime,
            attack: 0.028,
            release: 0.18
        )
        let lowMid = lowMidEnvelope.update(
            decibels: lowMidDecibels,
            deltaTime: deltaTime,
            attack: 0.022,
            release: 0.14
        )
        let midHigh = midHighEnvelope.update(
            decibels: midHighDecibels,
            deltaTime: deltaTime,
            attack: 0.016,
            release: 0.11
        )
        let high = highEnvelope.update(
            decibels: highDecibels,
            deltaTime: deltaTime,
            attack: 0.010,
            release: 0.075
        )

        var spectralFlux = 0.0
        for (index, range) in noveltyBandRanges.enumerated() {
            // Ignore movement below the usable music floor. Tiny FFT leakage in
            // near-silent bands otherwise looks like a large change in dB.
            currentLogSpectrum[index] = max(-72, bandDecibels(range))
            if hasPreviousSpectrum {
                spectralFlux += max(
                    0,
                    currentLogSpectrum[index] - previousLogSpectrum[index]
                )
            }
        }
        if !noveltyBandRanges.isEmpty {
            spectralFlux /= Double(noveltyBandRanges.count)
        }

        var onsetStrength = 0.0
        if hasPreviousSpectrum {
            onsetStrength = peakPicker.ingest(
                flux: spectralFlux,
                deltaTime: deltaTime
            ) * smoothStep((rmsDecibels + 76) / 24)
        }
        swap(&previousLogSpectrum, &currentLogSpectrum)
        hasPreviousSpectrum = true

        pulse *= exp(-deltaTime / 0.13)
        pulse = max(pulse, onsetStrength)
        flowPhase += deltaTime * (0.48 + energy * 0.12 + lowMid * 0.08)

        let centerTime = max(
            0,
            lastSourceTime - Double(Self.fftSize / 2) / sampleRate
        )
        snapshot = AudioMotionSnapshot(
            sourceTime: centerTime,
            energy: energy,
            low: low,
            lowMid: lowMid,
            midHigh: midHigh,
            high: high,
            pulse: pulse,
            phase: flowPhase
        )
        diagnostics = AudioAnalysisDiagnostics(
            sourceTime: centerTime,
            rmsDecibels: rmsDecibels,
            lowDecibels: lowDecibels,
            lowMidDecibels: lowMidDecibels,
            midHighDecibels: midHighDecibels,
            highDecibels: highDecibels,
            spectralFlux: spectralFlux,
            onsetThreshold: peakPicker.threshold,
            onsetCount: peakPicker.onsetCount
        )
    }

    private func bandDecibels(_ range: Range<Int>) -> Double {
        guard !range.isEmpty else { return -120 }
        var power = 0.0
        for index in range {
            power += Double(squaredMagnitudes[index])
        }
        power /= Double(range.count) * Double(Self.fftSize * Self.fftSize)
        return 10 * log10(max(power, 0.000_000_000_001))
    }

    private static func makeRanges(edges: [Double], sampleRate: Double) -> [Range<Int>] {
        guard edges.count >= 2 else { return [] }
        return zip(edges, edges.dropFirst()).map { lower, upper in
            makeRange(
                lowerFrequency: lower,
                upperFrequency: upper,
                sampleRate: sampleRate
            )
        }
    }

    private static func makeLogRanges(
        count: Int,
        lowerFrequency: Double,
        upperFrequency: Double,
        sampleRate: Double
    ) -> [Range<Int>] {
        let safeUpper = min(upperFrequency, sampleRate * 0.49)
        guard count > 0, safeUpper > lowerFrequency else { return [] }
        let ratio = pow(safeUpper / lowerFrequency, 1 / Double(count))
        return (0 ..< count).map { index in
            makeRange(
                lowerFrequency: lowerFrequency * pow(ratio, Double(index)),
                upperFrequency: lowerFrequency * pow(ratio, Double(index + 1)),
                sampleRate: sampleRate
            )
        }
    }

    private static func makeRange(
        lowerFrequency: Double,
        upperFrequency: Double,
        sampleRate: Double
    ) -> Range<Int> {
        let binWidth = sampleRate / Double(Self.fftSize)
        let highestBin = Self.fftSize / 2
        let lower = min(max(1, Int(floor(lowerFrequency / binWidth))), highestBin - 1)
        let upper = min(
            max(lower + 1, Int(ceil(upperFrequency / binWidth))),
            highestBin
        )
        return lower ..< upper
    }
}

final class AudioReactiveLevel: @unchecked Sendable {
    private let accumulator = AudioSignalAccumulator()

    var snapshot: AudioMotionSnapshot {
        accumulator.snapshot
    }

    var diagnostics: AudioAnalysisDiagnostics {
        accumulator.diagnostics
    }

    func reset() {
        accumulator.reset()
    }

    func makeAudioMix(for track: AVAssetTrack) -> AVAudioMix? {
        let retainedAccumulator = Unmanaged.passRetained(accumulator)
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: retainedAccumulator.toOpaque(),
            init: { _, clientInfo, tapStorageOut in
                tapStorageOut.pointee = clientInfo
            },
            finalize: { tap in
                let storage = MTAudioProcessingTapGetStorage(tap)
                Unmanaged<AudioSignalAccumulator>.fromOpaque(storage).release()
            },
            prepare: { tap, _, processingFormat in
                let accumulator = AudioSignalAccumulator.from(tap: tap)
                accumulator.setProcessingFormat(processingFormat.pointee)
            },
            unprepare: nil,
            process: { tap, numberFrames, flags, bufferList, numberFramesOut, flagsOut in
                let accumulator = AudioSignalAccumulator.from(tap: tap)
                if flags & kMTAudioProcessingTapFlag_StartOfStream != 0 {
                    accumulator.reset()
                }

                var sourceTimeRange = CMTimeRange.invalid
                let status = MTAudioProcessingTapGetSourceAudio(
                    tap,
                    numberFrames,
                    bufferList,
                    flagsOut,
                    &sourceTimeRange,
                    numberFramesOut
                )
                guard status == noErr else {
                    numberFramesOut.pointee = 0
                    return
                }

                let startSeconds = CMTimeGetSeconds(sourceTimeRange.start)
                accumulator.consume(
                    bufferList,
                    frameCount: Int(numberFramesOut.pointee),
                    sourceStartTime: startSeconds.isFinite ? startSeconds : nil
                )
            }
        )

        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault,
            &callbacks,
            kMTAudioProcessingTapCreationFlag_PostEffects,
            &tap
        )
        guard status == noErr, let tap else {
            retainedAccumulator.release()
            return nil
        }

        let parameters = AVMutableAudioMixInputParameters(track: track)
        parameters.audioTapProcessor = tap
        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = [parameters]
        return audioMix
    }
}

private final class AudioSignalAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var processingFormat = AudioStreamBasicDescription()
    private var extractor = AudioFeatureExtractor(sampleRate: 48_000)

    var snapshot: AudioMotionSnapshot {
        lock.withLock { extractor.snapshot }
    }

    var diagnostics: AudioAnalysisDiagnostics {
        lock.withLock { extractor.diagnostics }
    }

    static func from(tap: MTAudioProcessingTap) -> AudioSignalAccumulator {
        let storage = MTAudioProcessingTapGetStorage(tap)
        return Unmanaged<AudioSignalAccumulator>.fromOpaque(storage).takeUnretainedValue()
    }

    func setProcessingFormat(_ format: AudioStreamBasicDescription) {
        lock.withLock {
            processingFormat = format
            extractor = AudioFeatureExtractor(sampleRate: format.mSampleRate)
        }
    }

    func reset() {
        lock.withLock {
            extractor.reset()
        }
    }

    func consume(
        _ bufferList: UnsafeMutablePointer<AudioBufferList>,
        frameCount: Int,
        sourceStartTime: TimeInterval?
    ) {
        guard frameCount > 0 else { return }

        lock.withLock {
            let format = processingFormat
            guard format.mFormatID == kAudioFormatLinearPCM else { return }
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            let flags = format.mFormatFlags

            if flags & kAudioFormatFlagIsFloat != 0, format.mBitsPerChannel == 32 {
                consumeFloat32(
                    buffers,
                    frameCount: frameCount,
                    sampleRate: format.mSampleRate,
                    sourceStartTime: sourceStartTime
                )
            } else if flags & kAudioFormatFlagIsSignedInteger != 0,
                      format.mBitsPerChannel == 16 {
                consumeInt16(
                    buffers,
                    frameCount: frameCount,
                    sampleRate: format.mSampleRate,
                    sourceStartTime: sourceStartTime
                )
            } else if flags & kAudioFormatFlagIsSignedInteger != 0,
                      format.mBitsPerChannel == 32 {
                consumeInt32(
                    buffers,
                    frameCount: frameCount,
                    sampleRate: format.mSampleRate,
                    sourceStartTime: sourceStartTime
                )
            }
        }
    }

    private func consumeFloat32(
        _ buffers: UnsafeMutableAudioBufferListPointer,
        frameCount: Int,
        sampleRate: Double,
        sourceStartTime: TimeInterval?
    ) {
        for frame in 0 ..< frameCount {
            var mono = 0.0 as Float
            var contributingChannels = 0
            for buffer in buffers {
                guard let data = buffer.mData else { continue }
                let channels = max(1, Int(buffer.mNumberChannels))
                let samples = data.assumingMemoryBound(to: Float.self)
                let available = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                let offset = frame * channels
                for channel in 0 ..< channels where offset + channel < available {
                    mono += samples[offset + channel]
                    contributingChannels += 1
                }
            }
            guard contributingChannels > 0 else { continue }
            ingest(
                mono / Float(contributingChannels),
                frame: frame,
                sampleRate: sampleRate,
                sourceStartTime: sourceStartTime
            )
        }
    }

    private func consumeInt16(
        _ buffers: UnsafeMutableAudioBufferListPointer,
        frameCount: Int,
        sampleRate: Double,
        sourceStartTime: TimeInterval?
    ) {
        for frame in 0 ..< frameCount {
            var mono = 0.0 as Float
            var contributingChannels = 0
            for buffer in buffers {
                guard let data = buffer.mData else { continue }
                let channels = max(1, Int(buffer.mNumberChannels))
                let samples = data.assumingMemoryBound(to: Int16.self)
                let available = Int(buffer.mDataByteSize) / MemoryLayout<Int16>.size
                let offset = frame * channels
                for channel in 0 ..< channels where offset + channel < available {
                    mono += Float(samples[offset + channel]) / Float(Int16.max)
                    contributingChannels += 1
                }
            }
            guard contributingChannels > 0 else { continue }
            ingest(
                mono / Float(contributingChannels),
                frame: frame,
                sampleRate: sampleRate,
                sourceStartTime: sourceStartTime
            )
        }
    }

    private func consumeInt32(
        _ buffers: UnsafeMutableAudioBufferListPointer,
        frameCount: Int,
        sampleRate: Double,
        sourceStartTime: TimeInterval?
    ) {
        for frame in 0 ..< frameCount {
            var mono = 0.0 as Float
            var contributingChannels = 0
            for buffer in buffers {
                guard let data = buffer.mData else { continue }
                let channels = max(1, Int(buffer.mNumberChannels))
                let samples = data.assumingMemoryBound(to: Int32.self)
                let available = Int(buffer.mDataByteSize) / MemoryLayout<Int32>.size
                let offset = frame * channels
                for channel in 0 ..< channels where offset + channel < available {
                    mono += Float(samples[offset + channel]) / Float(Int32.max)
                    contributingChannels += 1
                }
            }
            guard contributingChannels > 0 else { continue }
            ingest(
                mono / Float(contributingChannels),
                frame: frame,
                sampleRate: sampleRate,
                sourceStartTime: sourceStartTime
            )
        }
    }

    private func ingest(
        _ sample: Float,
        frame: Int,
        sampleRate: Double,
        sourceStartTime: TimeInterval?
    ) {
        let sourceTime = sourceStartTime.map {
            $0 + Double(frame) / sampleRate
        }
        extractor.ingest(sample: sample, sourceTime: sourceTime)
    }
}

private func rootMeanSquare(_ samples: [Float]) -> Double {
    guard !samples.isEmpty else { return 0 }
    var sum = 0.0
    for sample in samples {
        sum += Double(sample * sample)
    }
    return sqrt(sum / Double(samples.count))
}

private func smoothingBlend(
    deltaTime: TimeInterval,
    timeConstant: TimeInterval
) -> Double {
    guard timeConstant > 0 else { return 1 }
    return 1 - exp(-deltaTime / timeConstant)
}

private func clamp(_ value: Double) -> Double {
    min(max(value, 0), 1)
}

private func smoothStep(_ value: Double) -> Double {
    let bounded = clamp(value)
    return bounded * bounded * (3 - 2 * bounded)
}
