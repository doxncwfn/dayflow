//
//  FrameStore.swift
//  Dayflow
//
//  Stores captured frames as hardware-encoded HEVC segment files instead of
//  one JPEG per capture. Each `screenshots` row points at a segment file plus
//  a frame index; `image(for:)` decodes that frame back out on demand.
//

import AVFoundation
import CoreGraphics
import Darwin
import Foundation
import ImageIO
import VideoToolbox

final class FrameStore: @unchecked Sendable {
  static let shared = FrameStore()

  /// Encoder quality (0...1). 0.55 is the lowest setting that keeps small UI text legible.
  static let encodeQuality: Float = 0.55
  /// A segment is closed after this much wall-clock time or this many frames
  /// (600 frames is ten minutes at the fastest 1 s capture interval).
  static let segmentDuration: TimeInterval = 900
  static let maxFramesPerSegment = 600
  /// Every frame is decodable from at most this many frames back. Smaller means
  /// faster random access for thumbnails at a modest file-size cost.
  static let keyframeInterval = 30

  private let writeQueue = DispatchQueue(label: "com.dayflow.framestore.write", qos: .userInitiated)
  private var writer: SegmentWriter?

  private let readLock = NSLock()
  private var readers: [String: SegmentReader] = [:]
  private var readerOrder: [String] = []
  private let readerCacheLimit = 1
  private var readerEvictWorkItem: DispatchWorkItem?

  private init() {}

  // MARK: - Writing

  /// Path of the segment currently being written, if any. Purge must never delete it.
  var activeSegmentPath: String? {
    writeQueue.sync { writer?.url.path }
  }

  /// Zero-copy path: encodes a GPU-backed `CMSampleBuffer` directly from its `CVImageBuffer`
  /// (`IOSurface`) without allocating a `CGImage` or redrawing into a `CGContext`.
  @discardableResult
  func append(_ sampleBuffer: CMSampleBuffer, capturedAt: Date, idleSecondsAtCapture: Int?) -> Int64? {
    writeQueue.sync {
      autoreleasepool {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0 else { return nil }

        if let current = writer,
          current.needsRotation(forWidth: width, height: height)
        {
          finishWriterLocked()
        }

        if writer == nil {
          let url = StorageManager.shared.nextSegmentURL()
          guard let created = SegmentWriter(url: url, width: width, height: height) else {
            print("❌ FrameStore: could not start segment at \(url.lastPathComponent)")
            return nil
          }
          writer = created
        }

        guard let current = writer else { return nil }
        guard let frameIndex = current.append(pixelBuffer: pixelBuffer) else {
          if current.hasFailed {
            print("❌ FrameStore: writer failed, closing segment")
            finishWriterLocked()
          }
          return nil
        }

        return StorageManager.shared.saveScreenshot(
          segmentPath: current.url.path,
          frameIndex: frameIndex,
          capturedAt: capturedAt,
          idleSecondsAtCapture: idleSecondsAtCapture
        )
      }
    }
  }

  /// Fallback path for `CGImage` inputs (e.g., privacy placeholders).
  /// Encodes one frame and records it in the database. Returns the new screenshot id.
  @discardableResult
  func append(_ image: CGImage, capturedAt: Date, idleSecondsAtCapture: Int?) -> Int64? {
    writeQueue.sync {
      autoreleasepool {
        if let current = writer,
          current.needsRotation(forWidth: image.width, height: image.height)
        {
          finishWriterLocked()
        }

        if writer == nil {
          let url = StorageManager.shared.nextSegmentURL()
          guard let created = SegmentWriter(url: url, width: image.width, height: image.height)
          else {
            print("❌ FrameStore: could not start segment at \(url.lastPathComponent)")
            return nil
          }
          writer = created
        }

        guard let current = writer else { return nil }
        guard let frameIndex = current.append(image) else {
          // A transient "not ready" just drops this frame; a failed writer closes the segment.
          if current.hasFailed {
            print("❌ FrameStore: writer failed, closing segment")
            finishWriterLocked()
          }
          return nil
        }

        return StorageManager.shared.saveScreenshot(
          segmentPath: current.url.path,
          frameIndex: frameIndex,
          capturedAt: capturedAt,
          idleSecondsAtCapture: idleSecondsAtCapture
        )
      }
    }
  }

  /// Finalizes the open segment so it becomes readable. Safe to call when nothing is open.
  func finishCurrentSegment() {
    writeQueue.sync { finishWriterLocked() }
  }

  /// Releases all cached `SegmentReader` decoders and returns purgeable pixel buffer memory to the OS.
  func clearReaders() {
    readLock.lock()
    readerEvictWorkItem?.cancel()
    readerEvictWorkItem = nil
    let activeReaders = Array(readers.values)
    readers.removeAll()
    readerOrder.removeAll()
    readLock.unlock()

    for reader in activeReaders {
      reader.close()
    }
    malloc_zone_pressure_relief(nil, 0)
  }

  /// Must be called on `writeQueue`.
  private func finishWriterLocked() {
    guard let current = writer else { return }
    writer = nil

    let succeeded = current.finish()
    let path = current.url.path
    malloc_zone_pressure_relief(nil, 0)

    if succeeded {
      let attributes = try? FileManager.default.attributesOfItem(atPath: path)
      let bytes = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
      StorageManager.shared.updateScreenshotFileSizes(segmentPath: path, totalBytes: bytes)
    } else {
      print("❌ FrameStore: segment failed to finalize, dropping \(current.url.lastPathComponent)")
      try? FileManager.default.removeItem(at: current.url)
      StorageManager.shared.markScreenshotsDeleted(segmentPath: path)
    }
  }

  /// Drops the most recent segment if a crash left it unreadable. Call once at launch.
  func reconcileAfterLaunch() {
    writeQueue.async {
      autoreleasepool {
        guard let path = StorageManager.shared.mostRecentSegmentPath() else { return }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
          StorageManager.shared.markScreenshotsDeleted(segmentPath: path)
          return
        }
        guard let reader = SegmentReader(url: url) else {
          print(
            "⚠️ FrameStore: unreadable segment from previous run, dropping \(url.lastPathComponent)")
          try? FileManager.default.removeItem(at: url)
          StorageManager.shared.markScreenshotsDeleted(segmentPath: path)
          return
        }
        reader.close()
        // Readable, but a crash between finishWriting and the size update leaves NULL sizes.
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let bytes = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        if bytes > 0 {
          StorageManager.shared.updateScreenshotFileSizes(segmentPath: path, totalBytes: bytes)
        }
      }
    }
  }

  // MARK: - Reading

  /// Decodes the frame for a screenshot row. Legacy JPEG rows are read directly.
  /// Pass `maxPixelSize` to get a downscaled copy for thumbnails.
  func image(for screenshot: Screenshot, maxPixelSize: Int? = nil) -> CGImage? {
    autoreleasepool {
      guard let frameIndex = screenshot.frameIndex else {
        return legacyJPEGImage(at: screenshot.fileURL, maxPixelSize: maxPixelSize)
      }

      // A segment that is still being written has no index yet; close it first.
      if activeSegmentPath == screenshot.filePath {
        finishCurrentSegment()
      }

      readLock.lock()
      defer {
        scheduleReaderEvictionLocked()
        readLock.unlock()
      }

      guard let reader = reader(forPath: screenshot.filePath),
        let image = reader.cgImage(at: frameIndex, maxPixelSize: maxPixelSize)
      else { return nil }

      return Self.downscaled(image, maxPixelSize: maxPixelSize)
    }
  }

  /// Must be called with `readLock` held.
  private func scheduleReaderEvictionLocked() {
    readerEvictWorkItem?.cancel()
    let work = DispatchWorkItem { [weak self] in
      self?.clearReaders()
    }
    readerEvictWorkItem = work
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.5, execute: work)
  }

  /// Must be called with `readLock` held.
  private func reader(forPath path: String) -> SegmentReader? {
    if let existing = readers[path] {
      readerOrder.removeAll { $0 == path }
      readerOrder.append(path)
      return existing
    }

    guard let created = SegmentReader(url: URL(fileURLWithPath: path)) else { return nil }
    readers[path] = created
    readerOrder.append(path)
    while readerOrder.count > readerCacheLimit {
      let evicted = readerOrder.removeFirst()
      if let old = readers.removeValue(forKey: evicted) {
        old.close()
      }
    }
    return created
  }

  private func legacyJPEGImage(at url: URL, maxPixelSize: Int?) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    if let maxPixelSize {
      let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
      ]
      return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
    let options: [CFString: Any] = [kCGImageSourceShouldCacheImmediately: true]
    return CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary)
  }

  static func downscaled(_ image: CGImage, maxPixelSize: Int?) -> CGImage? {
    guard let maxPixelSize, max(image.width, image.height) > maxPixelSize else { return image }
    let scale = Double(maxPixelSize) / Double(max(image.width, image.height))
    let width = max(1, Int((Double(image.width) * scale).rounded()))
    let height = max(1, Int((Double(image.height) * scale).rounded()))
    guard
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)
    else { return nil }
    context.interpolationQuality = .medium
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()
  }
}

// MARK: - Segment writer

/// One HEVC segment file being appended to. Frame N sits at presentation time N seconds.
private final class SegmentWriter {
  let url: URL
  let width: Int
  let height: Int
  private let startedAt = Date()
  private var frameCount = 0

  private var writer: AVAssetWriter?
  private var input: AVAssetWriterInput?
  private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
  private let colorSpace = CGColorSpaceCreateDeviceRGB()

  init?(url: URL, width: Int, height: Int) {
    let bitrateMode: [String: Any] = [
      AVVideoAverageBitRateKey: Self.fallbackBitRate(width: width, height: height),
      AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
    ]
    let qualityMode: [String: Any] = [AVVideoQualityKey: FrameStore.encodeQuality]

    guard
      let started = Self.startWriter(
        url: url, width: width, height: height, codec: .h264, rateControl: bitrateMode)
        ?? Self.startWriter(
          url: url, width: width, height: height, codec: .hevc, rateControl: qualityMode)
    else { return nil }

    self.url = url
    self.width = width
    self.height = height
    self.writer = started.writer
    self.input = started.input
    self.adaptor = started.adaptor
  }

  var hasFailed: Bool { writer?.status == .failed }

  private static func fallbackBitRate(width: Int, height: Int) -> Int {
    // ~1.2 Mbps at 720p, scaled by pixel count. At one frame per 10 s this is tiny on disk.
    max(400_000, Int(1_200_000.0 * Double(width * height) / Double(1280 * 720)))
  }

  private static func startWriter(
    url: URL, width: Int, height: Int, codec: AVVideoCodecType, rateControl: [String: Any]
  ) -> (
    writer: AVAssetWriter, input: AVAssetWriterInput, adaptor: AVAssetWriterInputPixelBufferAdaptor
  )? {
    try? FileManager.default.removeItem(at: url)
    guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return nil }

    var compression = rateControl
    compression[AVVideoMaxKeyFrameIntervalKey] = FrameStore.keyframeInterval
    compression[AVVideoAllowFrameReorderingKey] = false
    compression[AVVideoExpectedSourceFrameRateKey] = 1

    let settings: [String: Any] = [
      AVVideoCodecKey: codec,
      AVVideoWidthKey: width,
      AVVideoHeightKey: height,
      AVVideoCompressionPropertiesKey: compression,
    ]

    let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
    input.expectsMediaDataInRealTime = true
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: input,
      sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
        kCVPixelBufferPoolMinimumBufferCountKey as String: 1,
      ]
    )

    guard writer.canAdd(input) else { return nil }
    writer.add(input)
    guard writer.startWriting() else {
      print("❌ SegmentWriter: startWriting failed: \(String(describing: writer.error))")
      return nil
    }
    writer.startSession(atSourceTime: .zero)
    return (writer, input, adaptor)
  }

  func needsRotation(forWidth newWidth: Int, height newHeight: Int) -> Bool {
    newWidth != width || newHeight != height
      || frameCount >= FrameStore.maxFramesPerSegment
      || Date().timeIntervalSince(startedAt) >= FrameStore.segmentDuration
  }

  /// Zero-copy append directly from a GPU-backed `CVPixelBuffer` (`IOSurface`).
  func append(pixelBuffer: CVPixelBuffer) -> Int? {
    autoreleasepool {
      guard let writer, let input, let adaptor else { return nil }
      guard input.isReadyForMoreMediaData, writer.status == .writing else { return nil }

      let index = frameCount
      let time = CMTime(value: CMTimeValue(index), timescale: 1)
      let appended = adaptor.append(pixelBuffer, withPresentationTime: time)
      if let pool = adaptor.pixelBufferPool {
        CVPixelBufferPoolFlush(pool, .excessBuffers)
      }
      guard appended else { return nil }
      frameCount += 1
      return index
    }
  }

  /// Appends a `CGImage` frame (fallback path) and returns its index within the segment.
  func append(_ image: CGImage) -> Int? {
    autoreleasepool {
      guard let writer, let input, let adaptor else { return nil }
      guard input.isReadyForMoreMediaData, writer.status == .writing else { return nil }
      guard let pixelBuffer = makePixelBuffer(from: image, adaptor: adaptor) else { return nil }

      let index = frameCount
      let time = CMTime(value: CMTimeValue(index), timescale: 1)
      let appended = adaptor.append(pixelBuffer, withPresentationTime: time)
      if let pool = adaptor.pixelBufferPool {
        CVPixelBufferPoolFlush(pool, .excessBuffers)
      }
      guard appended else { return nil }
      frameCount += 1
      return index
    }
  }

  /// Blocks until the file is finalized. Returns false if the writer failed.
  func finish() -> Bool {
    guard let writer, let input else { return false }
    guard writer.status == .writing else {
      self.adaptor = nil
      self.input = nil
      self.writer = nil
      return false
    }
    if let pool = adaptor?.pixelBufferPool {
      CVPixelBufferPoolFlush(pool, .excessBuffers)
    }
    if frameCount > 0 {
      writer.endSession(atSourceTime: CMTime(value: CMTimeValue(frameCount), timescale: 1))
    }
    input.markAsFinished()
    let done = DispatchSemaphore(value: 0)
    writer.finishWriting { done.signal() }
    done.wait()
    if let pool = adaptor?.pixelBufferPool {
      CVPixelBufferPoolFlush(pool, .excessBuffers)
    }
    let succeeded = writer.status == .completed && frameCount > 0
    self.adaptor = nil
    self.input = nil
    self.writer = nil
    return succeeded
  }

  private func makePixelBuffer(
    from image: CGImage, adaptor: AVAssetWriterInputPixelBufferAdaptor
  ) -> CVPixelBuffer? {
    guard let pool = adaptor.pixelBufferPool else { return nil }
    var pixelBuffer: CVPixelBuffer?
    guard
      CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
        == kCVReturnSuccess,
      let buffer = pixelBuffer
    else { return nil }

    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

    guard
      let context = CGContext(
        data: CVPixelBufferGetBaseAddress(buffer),
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
        space: colorSpace,
        bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue
          | CGImageAlphaInfo.premultipliedFirst.rawValue)
    else { return nil }

    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return buffer
  }
}

// MARK: - Segment reader

/// Sequential decoder over one finished segment. Reading forward reuses the open
/// decoder; jumping backwards or far ahead restarts from the nearest keyframe.
private final class SegmentReader {
  private let asset: AVURLAsset
  private let track: AVAssetTrack
  private let naturalSize: CGSize
  private var reader: AVAssetReader?
  private var output: AVAssetReaderTrackOutput?
  private var nextIndex = 0
  private var currentMaxPixelSize: Int?

  private static let maxSequentialSkip = 8

  init?(url: URL) {
    let asset = AVURLAsset(
      url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
    guard let (track, size) = Self.loadVideoTrack(from: asset) else { return nil }
    self.asset = asset
    self.track = track
    self.naturalSize = size
  }

  deinit {
    close()
  }

  func close() {
    reader?.cancelReading()
    reader = nil
    output = nil
  }

  func cgImage(at index: Int, maxPixelSize: Int?) -> CGImage? {
    let canContinue =
      reader?.status == .reading && index >= nextIndex
      && index - nextIndex <= Self.maxSequentialSkip
      && currentMaxPixelSize == maxPixelSize
    if !canContinue {
      guard restart(from: index, maxPixelSize: maxPixelSize) else { return nil }
    }

    guard let output else { return nil }
    var decodedImage: CGImage?
    var shouldStop = false
    while !shouldStop {
      autoreleasepool {
        guard let sample = output.copyNextSampleBuffer() else {
          shouldStop = true
          return
        }
        let seconds = CMSampleBufferGetPresentationTimeStamp(sample).seconds
        let sampleIndex = Int(seconds.rounded())
        nextIndex = sampleIndex + 1
        if sampleIndex == index {
          if let pixelBuffer = CMSampleBufferGetImageBuffer(sample) {
            var cgImg: CGImage?
            VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &cgImg)
            decodedImage = cgImg
          }
          shouldStop = true
        } else if sampleIndex > index {
          shouldStop = true
        }
      }
    }
    return decodedImage
  }

  private func restart(from index: Int, maxPixelSize: Int?) -> Bool {
    close()

    guard let newReader = try? AVAssetReader(asset: asset) else { return false }
    var settings: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ]
    if let maxPixelSize, naturalSize.width > 0, naturalSize.height > 0 {
      let maxDim = max(naturalSize.width, naturalSize.height)
      if maxDim > CGFloat(maxPixelSize) {
        let scale = CGFloat(maxPixelSize) / maxDim
        var w = max(2, Int((naturalSize.width * scale).rounded()))
        var h = max(2, Int((naturalSize.height * scale).rounded()))
        if w % 2 != 0 { w += 1 }
        if h % 2 != 0 { h += 1 }
        settings[kCVPixelBufferWidthKey as String] = w
        settings[kCVPixelBufferHeightKey as String] = h
      }
    }

    let newOutput = AVAssetReaderTrackOutput(
      track: track,
      outputSettings: settings
    )
    newOutput.alwaysCopiesSampleData = false
    guard newReader.canAdd(newOutput) else { return false }
    newReader.add(newOutput)
    newReader.timeRange = CMTimeRange(
      start: CMTime(value: CMTimeValue(index), timescale: 1), duration: .positiveInfinity)
    guard newReader.startReading() else { return false }

    reader = newReader
    output = newOutput
    nextIndex = index
    currentMaxPixelSize = maxPixelSize
    return true
  }

  /// Blocks until the video track is loaded. Callers are already off the main thread.
  private static func loadVideoTrack(from asset: AVURLAsset) -> (AVAssetTrack, CGSize)? {
    final class Result: @unchecked Sendable {
      var track: AVAssetTrack?
      var size: CGSize = .zero
    }
    let result = Result()
    let done = DispatchSemaphore(value: 0)
    asset.loadTracks(withMediaType: .video) { tracks, _ in
      if let first = tracks?.first {
        result.track = first
        result.size = first.naturalSize
      }
      done.signal()
    }
    done.wait()
    guard let track = result.track else { return nil }
    return (track, result.size)
  }
}
