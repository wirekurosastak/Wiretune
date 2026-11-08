// Copyright (C) 2026 wirekurosastak. Licensed under the GNU AGPL v3 with the additional terms in NOTICE.md.
// SPDX-License-Identifier: AGPL-3.0-only

import AudioToolbox
import Flutter
import Foundation
import UniformTypeIdentifiers

/// Answers `wiretune/pcm` as Android's `PcmDecoder.kt` does: the track given on listening (a file path or a stream URL)
/// decoded by Core Audio for the spectrum, as the app's PCM cache takes it from `ffmpeg` on a computer: 16-bit mono
/// 44.1 kHz, little-endian, in chunks of about a second. One track at a time; cancelling stops it.
///
/// It never touches the audio that plays: a stream is fetched from the server a second time, into a temporary file, as
/// Core Audio reads only files. A format Core Audio can't open (Ogg Opus, for one) leaves the bars still. An error says
/// only what kind it was, never the source, whose URL holds the stream token.
final class PcmDecoder: NSObject, FlutterStreamHandler {
  private var decoding: Decoding?

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    stop()
    guard let source = arguments as? String else {
      events(FlutterEndOfEventStream)
      return nil
    }
    let decoding = Decoding(source: source, events: events)
    self.decoding = decoding
    decoding.start()
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    stop()
    return nil
  }

  func stop() {
    decoding?.stop()
    decoding = nil
  }
}

private final class Decoding {
  private static let rate = 44100

  private let source: String
  private let events: FlutterEventSink
  private let lock = NSLock()
  private var stopped = false
  private var download: URLSessionDownloadTask?

  /// The samples decoded and not sent yet; only the decoding queue touches them.
  private var chunk: [Int16] = []

  init(source: String, events: @escaping FlutterEventSink) {
    self.source = source
    self.events = events
    chunk.reserveCapacity(Self.rate)
  }

  private var isStopped: Bool {
    lock.lock()
    defer { lock.unlock() }
    return stopped
  }

  func stop() {
    lock.lock()
    stopped = true
    let task = download
    download = nil
    lock.unlock()
    task?.cancel()
  }

  func start() {
    if let url = URL(string: source), url.scheme == "http" || url.scheme == "https" {
      fetch(url)
    } else if let url = URL(string: source), url.isFileURL {
      decodeInBackground(url, deleteAfter: false)
    } else {
      decodeInBackground(URL(fileURLWithPath: source), deleteAfter: false)
    }
  }

  private func fetch(_ url: URL) {
    let task = URLSession.shared.downloadTask(with: url) { [self] file, response, error in
      guard let file, error == nil else {
        fail("download failed")
        return
      }
      if let status = (response as? HTTPURLResponse)?.statusCode, status != 200 {
        fail("HTTP \(status)")
        return
      }
      // Named with the type's extension, which helps Core Audio tell the format. The download's own file is deleted
      // when this returns, so it is moved first.
      var name = "wiretune-pcm-\(UUID().uuidString)"
      if let type = response?.mimeType.flatMap({ UTType(mimeType: $0) }), let ext = type.preferredFilenameExtension {
        name += ".\(ext)"
      }
      let copy = FileManager.default.temporaryDirectory.appendingPathComponent(name)
      do {
        try FileManager.default.moveItem(at: file, to: copy)
      } catch {
        fail("no temporary file")
        return
      }
      decodeInBackground(copy, deleteAfter: true)
    }
    lock.lock()
    let go = !stopped
    if go { download = task }
    lock.unlock()
    if go { task.resume() }
  }

  private func decodeInBackground(_ url: URL, deleteAfter: Bool) {
    // The music plays on; this is only for the bars.
    DispatchQueue.global(qos: .utility).async { [self] in
      defer {
        if deleteAfter { try? FileManager.default.removeItem(at: url) }
      }
      if let failure = decode(url) {
        fail(failure)
      } else if !isStopped {
        send()
        post(FlutterEndOfEventStream)
      }
    }
  }

  /// Decodes [url] into chunks: nil when it went through or was stopped, else what kind of error it was.
  private func decode(_ url: URL) -> String? {
    var opened: ExtAudioFileRef?
    guard ExtAudioFileOpenURL(url as CFURL, &opened) == noErr, let file = opened else { return "unsupported file" }
    defer { ExtAudioFileDispose(file) }

    var fileFormat = AudioStreamBasicDescription()
    var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    guard ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileDataFormat, &size, &fileFormat) == noErr else {
      return "no format"
    }
    // Floats at 44.1 kHz with the file's own channels: Core Audio resamples, and the channels are mixed here, as a
    // converter's own mixing of more than two isn't to be relied on.
    let channels = max(Int(fileFormat.mChannelsPerFrame), 1)
    var clientFormat = AudioStreamBasicDescription(
      mSampleRate: Double(Self.rate),
      mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
      mBytesPerPacket: UInt32(4 * channels),
      mFramesPerPacket: 1,
      mBytesPerFrame: UInt32(4 * channels),
      mChannelsPerFrame: UInt32(channels),
      mBitsPerChannel: 32,
      mReserved: 0
    )
    guard ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat, size, &clientFormat) == noErr else {
      return "unsupported format"
    }

    let frames = 4096
    var samples = [Float](repeating: 0, count: frames * channels)
    while !isStopped {
      var count = UInt32(frames)
      let status = samples.withUnsafeMutableBytes { bytes -> OSStatus in
        var buffers = AudioBufferList(
          mNumberBuffers: 1,
          mBuffers: AudioBuffer(
            mNumberChannels: UInt32(channels), mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress))
        return ExtAudioFileRead(file, &count, &buffers)
      }
      guard status == noErr else { return "read failed" }
      if count == 0 { return nil }
      // Each frame's channels mixed into one, -1..1.
      for frame in 0..<Int(count) {
        var sum: Float = 0
        for c in 0..<channels { sum += samples[frame * channels + c] }
        add(sum / Float(channels))
      }
    }
    return nil
  }

  private func add(_ sample: Float) {
    let clamped = sample.isFinite ? min(max(sample, -1), 1) : 0
    chunk.append(Int16(clamped * 32767))
    if chunk.count == Self.rate { send() }
  }

  /// The samples so far, as little-endian bytes (an iPhone's own order), to the app.
  private func send() {
    if chunk.isEmpty { return }
    let bytes = chunk.withUnsafeBytes { Data($0) }
    chunk.removeAll(keepingCapacity: true)
    post(FlutterStandardTypedData(bytes: bytes))
  }

  private func fail(_ kind: String) {
    post(FlutterError(code: "decode", message: kind, details: nil))
  }

  /// Events go to the app on the main thread, and none after a stop.
  private func post(_ event: Any) {
    DispatchQueue.main.async { [self] in
      if !isStopped { events(event) }
    }
  }
}
