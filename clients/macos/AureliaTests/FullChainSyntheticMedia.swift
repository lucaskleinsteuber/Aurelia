import AVFoundation
import AudioToolbox
import CoreMedia
import CoreVideo
import Foundation
import ImageIO

/// Test patterns only. Nothing in this generator opens, copies or processes user media.
/// AVI contains changing BGR frames; Matroska uses native complete JPEG frames.
/// Both have quiet 440 Hz PCM; MP4 uses the native H.264/AAC encoders.
/// All fixtures last 64 seconds, so seeking has real timestamps.
@MainActor
enum FullChainSyntheticMedia {
  struct Fixture {
    let name: String
    let url: URL
    let durationMilliseconds: Int64 = 64_000
    let contentType: String
  }

  enum GenerationError: Error { case failed(String) }

  static func generate(in directory: URL) async throws -> [Fixture] {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let avi = directory.appendingPathComponent("Full Chain AVI 2026.avi")
    let mkv = directory.appendingPathComponent("Full Chain MKV 2026.mkv")
    let mp4 = directory.appendingPathComponent("Full Chain MP4 2026.mp4")
    try makeAVI().write(to: avi, options: .atomic)
    try makeMatroska().write(to: mkv, options: .atomic)
    try await makeMP4(at: mp4)
    guard try topLevelMP4Atoms(at: mp4).last == "moov" else {
      throw GenerationError.failed("mp4_moov_is_not_at_end")
    }
    return [
      Fixture(name: "AVI", url: avi, contentType: "video/x-msvideo"),
      Fixture(name: "MP4", url: mp4, contentType: "video/mp4"),
      Fixture(name: "MKV", url: mkv, contentType: "video/x-matroska"),
    ]
  }

  private static let width: UInt32 = 64
  private static let height: UInt32 = 48
  private static let frameCount: UInt32 = 640
  private static let audioRate: UInt32 = 44_100
  private static let audioSamplesPerFrame: UInt32 = 4_410
  private static var frameBytes: UInt32 { width * height * 3 }

  private static func videoFrame(_ frame: UInt32) -> Data {
    var pixels = Data(capacity: Int(frameBytes))
    for y in 0..<height {
      for x in 0..<width {
        pixels.append(UInt8((x * 4 + frame * 8) % 256))
        pixels.append(UInt8((y * 5 + frame * 3) % 256))
        pixels.append(UInt8((frame * 8) % 256))
      }
    }
    return pixels
  }

  private static func audioFrame(_ frame: UInt32) -> Data {
    var samples = Data(capacity: Int(audioSamplesPerFrame) * 2)
    for offset in 0..<audioSamplesPerFrame {
      let index = frame * audioSamplesPerFrame + offset
      let signal = sin(2 * Double.pi * 440 * Double(index) / Double(audioRate))
      samples.append(little(Int16(signal * 2_000)))
    }
    return samples
  }

  private static func bitmapDescription() -> Data {
    var description = little(UInt32(40))
    description.append(little(width))
    description.append(little(height))
    description.append(little(UInt16(1)))
    description.append(little(UInt16(24)))
    for value: UInt32 in [0, frameBytes, 0, 0, 0, 0] { description.append(little(value)) }
    return description
  }

  private static func makeAVI() -> Data {
    var main = Data()
    for value: UInt32 in [
      100_000, frameBytes * 10 + audioRate * 2, 0, 0x110, frameCount, 0, 2,
      frameBytes, width, height, 0, 0, 0, 0,
    ] { main.append(little(value)) }
    let video = riffChunk(
      "LIST",
      Data("strl".utf8)
        + riffChunk(
          "strh",
          streamHeader(
            type: "vids", handler: "DIB ", scale: 1,
            rate: 10, length: frameCount, sampleSize: 0, buffer: frameBytes))
        + riffChunk("strf", bitmapDescription()))
    var wave = little(UInt16(1))
    wave.append(little(UInt16(1)))
    wave.append(little(audioRate))
    wave.append(little(audioRate * 2))
    wave.append(little(UInt16(2)))
    wave.append(little(UInt16(16)))
    let audio = riffChunk(
      "LIST",
      Data("strl".utf8)
        + riffChunk(
          "strh",
          streamHeader(
            type: "auds", handler: "\0\0\0\0", scale: 2,
            rate: audioRate * 2, length: audioSamplesPerFrame * frameCount,
            sampleSize: 2, buffer: audioSamplesPerFrame * 2))
        + riffChunk("strf", wave))
    let header = riffChunk("LIST", Data("hdrl".utf8) + riffChunk("avih", main) + video + audio)
    var movie = Data("movi".utf8)
    var index = Data()
    for frame in 0..<frameCount {
      for (name, payload) in [("00db", videoFrame(frame)), ("01wb", audioFrame(frame))] {
        index.append(Data(name.utf8))
        index.append(little(UInt32(0x10)))
        index.append(little(UInt32(movie.count)))
        index.append(little(UInt32(payload.count)))
        movie.append(riffChunk(name, payload))
      }
    }
    return riffChunk(
      "RIFF", Data("AVI ".utf8) + header + riffChunk("LIST", movie) + riffChunk("idx1", index))
  }

  private static func streamHeader(
    type: String, handler: String, scale: UInt32, rate: UInt32, length: UInt32,
    sampleSize: UInt32, buffer: UInt32
  ) -> Data {
    var bytes = Data((type + handler).utf8)
    bytes.append(little(UInt32(0)))
    bytes.append(little(UInt16(0)))
    bytes.append(little(UInt16(0)))
    for value: UInt32 in [0, scale, rate, 0, length, buffer, .max, sampleSize] {
      bytes.append(little(value))
    }
    for value: UInt16 in [
      0, 0, type == "vids" ? UInt16(width) : 0, type == "vids" ? UInt16(height) : 0,
    ] {
      bytes.append(little(value))
    }
    return bytes
  }

  private static func makeMatroska() throws -> Data {
    let ebml = element(
      0x1A45_DFA3,
      integer(0x4286, 1) + integer(0x42F7, 1) + integer(0x42F2, 4) + integer(0x42F3, 8)
        + element(0x4282, Data("matroska".utf8)) + integer(0x4287, 4) + integer(0x4285, 2))
    let info = element(
      0x1549_A966,
      integer(0x2AD7B1, 1_000_000) + floating(0x4489, 64_000)
        + element(0x4D80, Data("Aurelia synthetic fixture".utf8))
        + element(0x5741, Data("Aurelia synthetic fixture".utf8)))
    let video = element(
      0xAE,
      integer(0xD7, 1) + integer(0x73C5, 1) + integer(0x83, 1) + integer(0x9C, 0)
        // V_MJPEG carries complete standalone JPEG frames and needs no
        // CodecPrivate. BI_RGB=0 in a VFW header is not a usable Matroska FourCC
        // for VLC, even though the identical bitmap header works in AVI.
        + integer(0x23E383, 100_000_000) + element(0x86, Data("V_MJPEG".utf8))
        + element(0xE0, integer(0xB0, UInt64(width)) + integer(0xBA, UInt64(height))))
    let audio = element(
      0xAE,
      integer(0xD7, 2) + integer(0x73C5, 2) + integer(0x83, 2) + integer(0x9C, 0)
        + element(0x86, Data("A_PCM/INT/LIT".utf8))
        + element(0xE1, floating(0xB5, Double(audioRate)) + integer(0x9F, 1) + integer(0x6264, 16)))
    let tracks = element(0x1654_AE6B, video + audio)
    let headLength = seekHead(info: 0, tracks: 0, cues: 0).count
    var clusters = Data()
    var cues = Data()
    for second: UInt32 in 0..<64 {
      let position = headLength + info.count + tracks.count + clusters.count
      cues.append(
        element(
          0xBB,
          integer(0xB3, UInt64(second * 1_000))
            + element(0xB7, integer(0xF7, 1) + integer(0xF1, UInt64(position)))))
      var blocks = integer(0xE7, UInt64(second * 1_000))
      for frame: UInt32 in 0..<10 {
        let index = second * 10 + frame
        blocks.append(
          simpleBlock(track: 1, time: UInt16(frame * 100), payload: try jpegFrame(index)))
        blocks.append(simpleBlock(track: 2, time: UInt16(frame * 100), payload: audioFrame(index)))
      }
      clusters.append(element(0x1F43_B675, blocks))
    }
    let head = seekHead(
      info: UInt64(headLength), tracks: UInt64(headLength + info.count),
      cues: UInt64(headLength + info.count + tracks.count + clusters.count))
    return ebml + element(0x1853_8067, head + info + tracks + clusters + element(0x1C53_BB6B, cues))
  }

  private static func jpegFrame(_ frame: UInt32) throws -> Data {
    var rgb = Data(capacity: Int(frameBytes))
    for y in 0..<height {
      for x in 0..<width {
        rgb.append(UInt8((frame * 8) % 256))
        rgb.append(UInt8((y * 5 + frame * 3) % 256))
        rgb.append(UInt8((x * 4 + frame * 8) % 256))
      }
    }
    guard let provider = CGDataProvider(data: rgb as CFData),
      let image = CGImage(
        width: Int(width), height: Int(height), bitsPerComponent: 8, bitsPerPixel: 24,
        bytesPerRow: Int(width * 3), space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    else { throw GenerationError.failed("mkv_jpeg_pattern_failed") }
    let bytes = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        bytes, "public.jpeg" as CFString, 1, nil)
    else { throw GenerationError.failed("mkv_jpeg_encoder_unavailable") }
    CGImageDestinationAddImage(
      destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
      throw GenerationError.failed("mkv_jpeg_frame_failed")
    }
    return bytes as Data
  }

  private static func seekHead(info: UInt64, tracks: UInt64, cues: UInt64) -> Data {
    element(
      0x114D_9B74,
      [(UInt64(0x1549_A966), info), (0x1654_AE6B, tracks), (0x1C53_BB6B, cues)]
        .reduce(into: Data()) { bytes, item in
          bytes.append(
            element(
              0x4DBB,
              element(0x53AB, identifier(item.0))
                + element(0x53AC, big(item.1))))
        })
  }

  private static func simpleBlock(track: UInt8, time: UInt16, payload: Data) -> Data {
    var block = Data([0x80 | track])
    block.append(big(time))
    block.append(0x80)
    block.append(payload)
    return element(0xA3, block)
  }

  private static func integer(_ id: UInt64, _ value: UInt64) -> Data {
    var payload = big(value)
    while payload.count > 1 && payload.first == 0 { payload.removeFirst() }
    return element(id, payload)
  }
  private static func floating(_ id: UInt64, _ value: Double) -> Data {
    element(id, big(value.bitPattern))
  }
  private static func identifier(_ value: UInt64) -> Data {
    var bytes = big(value)
    while bytes.count > 1 && bytes.first == 0 { bytes.removeFirst() }
    return bytes
  }
  private static func element(_ id: UInt64, _ payload: Data) -> Data {
    let length = UInt64(payload.count)
    let byteCount = (1...8).first { length < (UInt64(1) << ($0 * 7)) - 1 } ?? 8
    let encodedLength = length | (UInt64(1) << (byteCount * 7))
    return identifier(id) + big(encodedLength).suffix(byteCount) + payload
  }
  private static func riffChunk(_ name: String, _ payload: Data) -> Data {
    var bytes = Data(name.utf8) + little(UInt32(payload.count)) + payload
    if payload.count.isMultiple(of: 2) == false { bytes.append(0) }
    return bytes
  }
  private static func little<T: FixedWidthInteger>(_ value: T) -> Data {
    var encoded = value.littleEndian
    return withUnsafeBytes(of: &encoded) { Data($0) }
  }
  private static func big<T: FixedWidthInteger>(_ value: T) -> Data {
    var encoded = value.bigEndian
    return withUnsafeBytes(of: &encoded) { Data($0) }
  }

  private static func makeMP4(at url: URL) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    writer.shouldOptimizeForNetworkUse = false
    let video = AVAssetWriterInput(
      mediaType: .video,
      outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 160, AVVideoHeightKey: 96,
        AVVideoCompressionPropertiesKey: [
          AVVideoAverageBitRateKey: 180_000, AVVideoMaxKeyFrameIntervalKey: 10,
        ],
      ])
    let adapter = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: video,
      sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
        kCVPixelBufferWidthKey as String: 160, kCVPixelBufferHeightKey as String: 96,
        kCVPixelBufferCGImageCompatibilityKey as String: true,
      ])
    let audio = AVAssetWriterInput(
      mediaType: .audio,
      outputSettings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: Double(audioRate),
        AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000,
      ])
    guard writer.canAdd(video), writer.canAdd(audio) else {
      throw GenerationError.failed("mp4_encoder_unavailable")
    }
    writer.add(video)
    writer.add(audio)
    guard writer.startWriting() else { throw GenerationError.failed("mp4_start_failed") }
    writer.startSession(atSourceTime: .zero)
    // Feed both encoder inputs independently. A file writer can apply muxer
    // backpressure to one input until the other advances, so serial feeding can
    // deadlock even for tiny, otherwise valid audio/video samples.
    let videoTask = Task { @MainActor in
      for frame in 0..<frameCount {
        try await ready(video, writer: writer)
        var pixel: CVPixelBuffer?
        guard let pool = adapter.pixelBufferPool,
          CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixel) == kCVReturnSuccess,
          let pixel
        else { throw GenerationError.failed("mp4_pixel_buffer_failed") }
        CVPixelBufferLockBaseAddress(pixel, [])
        if let base = CVPixelBufferGetBaseAddress(pixel) {
          let row = CVPixelBufferGetBytesPerRow(pixel)
          for y in 0..<96 {
            let line = base.advanced(by: y * row).assumingMemoryBound(to: UInt8.self)
            for x in 0..<160 {
              line[x * 4] = 255
              line[x * 4 + 1] = UInt8((Int(frame) * 8 + x) % 256)
              line[x * 4 + 2] = UInt8((y * 2 + Int(frame) * 3) % 256)
              line[x * 4 + 3] = UInt8((x + y + Int(frame) * 5) % 256)
            }
          }
        }
        CVPixelBufferUnlockBaseAddress(pixel, [])
        guard
          adapter.append(pixel, withPresentationTime: CMTime(value: Int64(frame), timescale: 10))
        else {
          throw GenerationError.failed("mp4_video_append_failed")
        }
      }
      video.markAsFinished()
    }
    let audioTask = Task { @MainActor in
      for frame in 0..<frameCount {
        try await ready(audio, writer: writer)
        guard audio.append(try audioSample(frame)) else {
          throw GenerationError.failed("mp4_audio_append_failed")
        }
      }
      audio.markAsFinished()
    }
    do {
      try await videoTask.value
      try await audioTask.value
      await writer.finishWriting()
      guard writer.status == .completed else { throw GenerationError.failed("mp4_finish_failed") }
    } catch {
      videoTask.cancel()
      audioTask.cancel()
      writer.cancelWriting()
      _ = await videoTask.result
      _ = await audioTask.result
      throw error
    }
  }

  private static func ready(_ input: AVAssetWriterInput, writer: AVAssetWriter) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while !input.isReadyForMoreMediaData {
      try Task.checkCancellation()
      guard writer.status == .writing, ContinuousClock.now < deadline else {
        throw GenerationError.failed(
          "mp4_writer_stalled_\(input.mediaType.rawValue)_status_\(writer.status.rawValue)_code_\((writer.error as NSError?)?.code ?? 0)"
        )
      }
      try await Task.sleep(for: .milliseconds(5))
    }
  }

  private static func audioSample(_ frame: UInt32) throws -> CMSampleBuffer {
    let bytes = audioFrame(frame)
    var block: CMBlockBuffer?
    guard
      CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault, memoryBlock: nil,
        blockLength: bytes.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
        offsetToData: 0, dataLength: bytes.count, flags: 0, blockBufferOut: &block) == noErr,
      let block
    else { throw GenerationError.failed("pcm_buffer_failed") }
    let status = bytes.withUnsafeBytes { pointer in
      CMBlockBufferReplaceDataBytes(
        with: pointer.baseAddress!, blockBuffer: block,
        offsetIntoDestination: 0, dataLength: bytes.count)
    }
    guard status == noErr else { throw GenerationError.failed("pcm_copy_failed") }
    var description = AudioStreamBasicDescription(
      mSampleRate: Double(audioRate),
      mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
      mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1,
      mBitsPerChannel: 16, mReserved: 0)
    var format: CMAudioFormatDescription?
    guard
      CMAudioFormatDescriptionCreate(
        allocator: kCFAllocatorDefault, asbd: &description,
        layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil,
        formatDescriptionOut: &format) == noErr, let format
    else { throw GenerationError.failed("pcm_format_failed") }
    var timing = CMSampleTimingInfo(
      duration: CMTime(value: 1, timescale: Int32(audioRate)),
      presentationTimeStamp: CMTime(
        value: Int64(frame * audioSamplesPerFrame), timescale: Int32(audioRate)),
      decodeTimeStamp: .invalid)
    var size = 2
    var sample: CMSampleBuffer?
    guard
      CMSampleBufferCreateReady(
        allocator: kCFAllocatorDefault, dataBuffer: block,
        formatDescription: format, sampleCount: Int(audioSamplesPerFrame),
        sampleTimingEntryCount: 1,
        sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size,
        sampleBufferOut: &sample) == noErr, let sample
    else { throw GenerationError.failed("pcm_sample_failed") }
    return sample
  }

  private static func topLevelMP4Atoms(at url: URL) throws -> [String] {
    let bytes = try Data(contentsOf: url)
    var atoms: [String] = []
    var offset = 0
    while offset + 8 <= bytes.count {
      let shortLength = bytes[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
      let length: UInt64
      if shortLength == 1 {
        guard offset + 16 <= bytes.count else {
          throw GenerationError.failed("mp4_extended_atom_invalid")
        }
        length = bytes[(offset + 8)..<(offset + 16)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
      } else if shortLength == 0 {
        length = UInt64(bytes.count - offset)
      } else {
        length = UInt64(shortLength)
      }
      guard length >= 8, length <= UInt64(bytes.count - offset) else {
        throw GenerationError.failed("mp4_atom_invalid")
      }
      atoms.append(String(decoding: bytes[(offset + 4)..<(offset + 8)], as: UTF8.self))
      offset += Int(length)
    }
    return atoms
  }
}
