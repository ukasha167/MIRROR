import Foundation
import CoreMedia
import VideoToolbox
import CoreVideo

/// Errors occurring in VideoToolbox decompression session.
public enum DecoderError: Error, Sendable, CustomStringConvertible {
    case unsupportedCodec(VideoCodec)
    case sessionCreationFailed(OSStatus)
    case decompressionFailed(OSStatus)
    case noFormatDescription
    case invalidBlockBuffer(OSStatus)
    case invalidSampleBuffer(OSStatus)

    public var description: String {
        switch self {
        case .unsupportedCodec(let codec):
            return "DecoderError: Codec \(codec.rawValue) has no hardware acceleration on Apple M1/M2"
        case .sessionCreationFailed(let status):
            return "DecoderError: VTDecompressionSessionCreate failed with OSStatus \(status)"
        case .decompressionFailed(let status):
            return "DecoderError: VTDecompressionSessionDecodeFrame failed with OSStatus \(status)"
        case .noFormatDescription:
            return "DecoderError: Cannot decode frames without active CMVideoFormatDescription"
        case .invalidBlockBuffer(let status):
            return "DecoderError: CMBlockBuffer creation failed with OSStatus \(status)"
        case .invalidSampleBuffer(let status):
            return "DecoderError: CMSampleBuffer creation failed with OSStatus \(status)"
        }
    }
}

/// Native zero-copy H.265/H.264 decoder using Apple VideoToolbox and IOSurface.
public final class VideoToolboxDecoder: @unchecked Sendable {
    private var decompressionSession: VTDecompressionSession?
    private var currentFormatDesc: CMFormatDescription?
    public let codec: VideoCodec
    private let nalParser = NALParser()

    // Thread-safe lock for session recreation and decoding
    private let lock = NSLock()
    private var lastDecodedPixelBuffer: CVPixelBuffer?

    public init(codec: VideoCodec = .h265) throws {
        // Enforce Apple Silicon M1/M2 rule: AV1 lacks hardware acceleration
        if codec == .av1 {
            throw DecoderError.unsupportedCodec(codec)
        }
        self.codec = codec
    }

    deinit {
        invalidate()
    }

    public func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        if let session = decompressionSession {
            VTDecompressionSessionInvalidate(session)
            decompressionSession = nil
        }
        currentFormatDesc = nil
        lastDecodedPixelBuffer = nil
    }

    /// Sets or updates format description when SPS/PPS/VPS parameter sets arrive.
    public func updateFormatDescription(_ desc: CMFormatDescription) throws {
        lock.lock()
        defer { lock.unlock() }

        if let existing = currentFormatDesc, CMFormatDescriptionEqual(existing, otherFormatDescription: desc) {
            return
        }

        if let session = decompressionSession {
            VTDecompressionSessionInvalidate(session)
            decompressionSession = nil
        }

        currentFormatDesc = desc
        try setupDecompressionSession(with: desc)
    }

    private func setupDecompressionSession(with formatDesc: CMFormatDescription) throws {
        // Zero-copy IOSurface backing configuration for Unified Memory GPU rendering
        let destinationPixelBufferAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true
        ]

        var callbackRecord = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: { (
                decompressionOutputRefCon: UnsafeMutableRawPointer?,
                sourceFrameRefCon: UnsafeMutableRawPointer?,
                status: OSStatus,
                infoFlags: VTDecodeInfoFlags,
                imageBuffer: CVImageBuffer?,
                presentationTimeStamp: CMTime,
                presentationDuration: CMTime
            ) in
                guard status == noErr, let buffer = imageBuffer else { return }
                let decoder = Unmanaged<VideoToolboxDecoder>.fromOpaque(decompressionOutputRefCon!).takeUnretainedValue()
                decoder.handleDecodedFrame(buffer)
            },
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
        )

        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDesc,
            decoderSpecification: nil,
            imageBufferAttributes: destinationPixelBufferAttributes as CFDictionary,
            outputCallback: &callbackRecord,
            decompressionSessionOut: &session
        )

        guard status == noErr, let validSession = session else {
            throw DecoderError.sessionCreationFailed(status)
        }

        self.decompressionSession = validSession
    }

    private func handleDecodedFrame(_ imageBuffer: CVImageBuffer) {
        lastDecodedPixelBuffer = imageBuffer
    }

    /// Updates codec parameter sets directly from an Annex B scrcpy config packet.
    public func configureFromAnnexBConfig(_ configData: Data) throws {
        switch codec {
        case .h265:
            guard let params = nalParser.extractHEVCParameterSets(from: configData) else {
                throw NALParserError.missingParameterSets(codec: .h265, reason: "Missing VPS/SPS/PPS in config packet")
            }
            let desc = try nalParser.createHEVCFormatDescription(vps: params.vps, sps: params.sps, pps: params.pps)
            try updateFormatDescription(desc)
        case .h264:
            guard let params = nalParser.extractH264ParameterSets(from: configData) else {
                throw NALParserError.missingParameterSets(codec: .h264, reason: "Missing SPS/PPS in config packet")
            }
            let desc = try nalParser.createH264FormatDescription(sps: params.sps, pps: params.pps)
            try updateFormatDescription(desc)
        case .av1:
            throw DecoderError.unsupportedCodec(.av1)
        }
    }

    /// Decodes an Annex B or AVCC/HVCC NAL payload frame into an IOSurface-backed `CVPixelBuffer`.
    public func decode(nalData: Data, pts: CMTime) throws -> CVPixelBuffer? {
        // Automatically extract inline parameter sets and convert Annex B start codes to 4-byte lengths
        let payloadData: Data
        if nalParser.isAnnexB(nalData) {
            if codec == .h265, let params = nalParser.extractHEVCParameterSets(from: nalData) {
                let desc = try nalParser.createHEVCFormatDescription(vps: params.vps, sps: params.sps, pps: params.pps)
                try updateFormatDescription(desc)
            } else if codec == .h264, let params = nalParser.extractH264ParameterSets(from: nalData) {
                let desc = try nalParser.createH264FormatDescription(sps: params.sps, pps: params.pps)
                try updateFormatDescription(desc)
            }
            payloadData = nalParser.convertAnnexBToLengthPrefixed(nalData, codec: codec, includeParameterSets: false)
        } else {
            payloadData = nalData
        }

        guard !payloadData.isEmpty else { return nil }

        lock.lock()
        defer { lock.unlock() }

        guard let session = decompressionSession, let formatDesc = currentFormatDesc else {
            throw DecoderError.noFormatDescription
        }

        var blockBuffer: CMBlockBuffer?
        let dataLength = payloadData.count

        let memBlock = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: dataLength,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: dataLength,
            flags: 0,
            blockBufferOut: &blockBuffer
        )

        guard memBlock == noErr, let bb = blockBuffer else {
            throw DecoderError.invalidBlockBuffer(memBlock)
        }

        let copyErr = payloadData.withUnsafeBytes { rawPtr -> OSStatus in
            guard let base = rawPtr.baseAddress else { return OSStatus(-1) }
            return CMBlockBufferReplaceDataBytes(
                with: base,
                blockBuffer: bb,
                offsetIntoDestination: 0,
                dataLength: dataLength
            )
        }
        guard copyErr == noErr else {
            throw DecoderError.invalidBlockBuffer(copyErr)
        }

        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )

        let sampleErr = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: bb,
            formatDescription: formatDesc,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: [dataLength],
            sampleBufferOut: &sampleBuffer
        )

        guard sampleErr == noErr, let sb = sampleBuffer else {
            throw DecoderError.invalidSampleBuffer(sampleErr)
        }

        lastDecodedPixelBuffer = nil
        var flagsOut: VTDecodeInfoFlags = []

        let decodeStatus = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sb,
            flags: [._EnableAsynchronousDecompression],
            frameRefcon: nil,
            infoFlagsOut: &flagsOut
        )

        if decodeStatus != noErr {
            throw DecoderError.decompressionFailed(decodeStatus)
        }

        // Wait for synchronous or immediate return
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        return lastDecodedPixelBuffer
    }
}
