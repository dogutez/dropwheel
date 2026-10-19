@preconcurrency import AVFoundation
import ImageIO
import UniformTypeIdentifiers

enum MediaEngine {
    static let gifSeconds = 15.0
    static let gifFPS = 10.0
    static let gifEdge: CGFloat = 480

    static func convertVideo(_ url: URL, to format: OutputFormat, writingTo destination: URL) async throws {
        let asset = AVURLAsset(url: url)
        guard try await !asset.loadTracks(withMediaType: .video).isEmpty else {
            throw ConversionError.failed("No video track found")
        }
        switch format {
        case .mp4, .mov:
            let type: AVFileType = format == .mp4 ? .mp4 : .mov
            // Re-wrap without re-encoding when the codecs allow it; that is lossless and fast.
            let passthrough = await AVAssetExportSession.compatibility(ofExportPreset: AVAssetExportPresetPassthrough, with: asset, outputFileType: type)
            try await export(asset, preset: passthrough ? AVAssetExportPresetPassthrough : AVAssetExportPresetHighestQuality, as: type, to: destination)
        case .m4a:
            guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else {
                throw ConversionError.failed("This video has no sound")
            }
            try await export(asset, preset: AVAssetExportPresetAppleM4A, as: .m4a, to: destination)
        case .gif:
            try await makeGIF(asset, to: destination)
        default:
            throw ConversionError.unsupported
        }
    }

    static func convertAudio(_ url: URL, to format: OutputFormat, writingTo destination: URL) async throws {
        switch format {
        case .m4a:
            try await export(AVURLAsset(url: url), preset: AVAssetExportPresetAppleM4A, as: .m4a, to: destination)
        case .wav, .aiff:
            try writePCM(url, bigEndian: format == .aiff, to: destination)
        case .flac:
            try writeFLAC(url, to: destination)
        default:
            throw ConversionError.unsupported
        }
    }

    static func fileType(for url: URL) -> (AVFileType, OutputFormat) {
        OutputFormat.mov.matches(extension: url.pathExtension) ? (.mov, .mov) : (.mp4, .mp4)
    }

    /// HEVC at up to 1080p: typically a fraction of a phone recording's size.
    static func compressVideo(_ url: URL, writingTo destination: URL) async throws {
        let asset = AVURLAsset(url: url)
        let (type, _) = fileType(for: url)
        let hevc = await AVAssetExportSession.compatibility(ofExportPreset: AVAssetExportPresetHEVC1920x1080, with: asset, outputFileType: type)
        try await export(asset, preset: hevc ? AVAssetExportPresetHEVC1920x1080 : AVAssetExportPreset1280x720, as: type, to: destination)
    }

    /// Same streams, no metadata: drops location, device, title and creation tags.
    static func cleanVideo(_ url: URL, writingTo destination: URL) async throws {
        let (type, _) = fileType(for: url)
        try await export(AVURLAsset(url: url), preset: AVAssetExportPresetPassthrough, as: type, to: destination, keepMetadata: false)
    }

    /// Exports with location and personal metadata filtered out; `keepMetadata: false`
    /// writes no metadata at all.
    private static func export(_ asset: AVAsset, preset: String, as type: AVFileType, to destination: URL, keepMetadata: Bool = true) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw ConversionError.failed("This file cannot be exported in that format")
        }
        session.metadataItemFilter = .forSharing()
        if !keepMetadata { session.metadata = [] }
        session.shouldOptimizeForNetworkUse = true
        let shared = SharedExportSession(session)
        let monitor = ConversionProgress.handler.map { _ in
            Task {
                for await state in shared.session.states(updateInterval: 0.25) {
                    if case .exporting(let progress) = state { ConversionProgress.report(progress.fractionCompleted) }
                }
            }
        }
        defer { monitor?.cancel() }
        do {
            try await withTaskCancellationHandler {
                try await shared.session.export(to: destination, as: type)
            } onCancel: {
                shared.session.cancelExport()
            }
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw ConversionError.failed(error.localizedDescription)
        }
    }

    private static func writePCM(_ url: URL, bigEndian: Bool, to destination: URL) throws {
        let input: AVAudioFile
        do { input = try AVAudioFile(forReading: url) } catch { throw ConversionError.unreadable }
        let format = input.processingFormat
        let settings: [String: Any] = [
            AVAudioFileTypeKey: bigEndian ? kAudioFileAIFFType : kAudioFileWAVEType,
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: bigEndian,
            AVLinearPCMIsNonInterleaved: false,
        ]
        try copyFrames(from: input, to: AVAudioFile(forWriting: destination, settings: settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved))
    }

    /// Lossless FLAC, 16-bit (or 24-bit when the source is higher resolution).
    private static func writeFLAC(_ url: URL, to destination: URL) throws {
        let input: AVAudioFile
        do { input = try AVAudioFile(forReading: url) } catch { throw ConversionError.unreadable }
        let format = input.processingFormat
        let sourceBits = input.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int ?? 16
        let settings: [String: Any] = [
            AVAudioFileTypeKey: kAudioFileFLACType,
            AVFormatIDKey: kAudioFormatFLAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVEncoderBitDepthHintKey: sourceBits > 16 ? 24 : 16,
        ]
        try copyFrames(from: input, to: AVAudioFile(forWriting: destination, settings: settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved))
    }

    private static func copyFrames(from input: AVAudioFile, to output: AVAudioFile) throws {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 32_768) else {
            throw ConversionError.failed("Could not allocate an audio buffer")
        }
        while input.framePosition < input.length {
            try Task.checkCancellation()
            try input.read(into: buffer)
            if buffer.frameLength == 0 { break }
            try output.write(from: buffer)
            ConversionProgress.report(Double(input.framePosition) / Double(max(input.length, 1)))
        }
    }

    /// First 15 seconds at 10 fps, at most 480 px on the long edge, looping forever.
    private static func makeGIF(_ asset: AVAsset, to destination: URL) async throws {
        let duration = try await asset.load(.duration).seconds
        let length = min(duration.isFinite ? duration : 0, gifSeconds)
        let frameCount = max(1, Int(length * gifFPS))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: gifEdge, height: gifEdge)
        let tolerance = CMTime(seconds: 0.5 / gifFPS, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        guard let gif = CGImageDestinationCreateWithURL(destination as CFURL, UTType.gif.identifier as CFString, frameCount, nil) else {
            throw ConversionError.failed("Could not create the GIF")
        }
        let loop = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]]
        CGImageDestinationSetProperties(gif, loop as CFDictionary)
        let frameProperties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / gifFPS]] as CFDictionary
        for index in 0..<frameCount {
            try Task.checkCancellation()
            let time = CMTime(seconds: Double(index) / gifFPS, preferredTimescale: 600)
            let (image, _) = try await generator.image(at: time)
            CGImageDestinationAddImage(gif, image, frameProperties)
            ConversionProgress.report(Double(index + 1) / Double(frameCount))
        }
        guard CGImageDestinationFinalize(gif) else { throw ConversionError.failed("Could not write the GIF") }
    }
}

/// AVAssetExportSession isn't annotated Sendable, but observing its states and calling
/// `cancelExport()` from another thread is what those APIs are for (they are documented as
/// callable during an export). This box is used only for those two calls.
private final class SharedExportSession: @unchecked Sendable {
    let session: AVAssetExportSession
    init(_ session: AVAssetExportSession) { self.session = session }
}
