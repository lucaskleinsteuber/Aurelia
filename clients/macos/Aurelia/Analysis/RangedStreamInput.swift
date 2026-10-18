import Foundation

/// Hands VLC a title's bytes fetched from the server in large ranged requests. VLC treats such a
/// stream like a local file and reads it as fast as it can decode, whereas a network address is
/// read at playback speed. The next chunk is requested while VLC decodes the current one. Bytes
/// pass through memory only; nothing is written to disk.
final class RangedStreamInput: InputStream, @unchecked Sendable {
  static let chunkSize = 4 * 1_024 * 1_024

  private let url: URL
  private let session: URLSession
  private let token: String?
  private let length: Int64
  private var offset: Int64 = 0
  private var buffer = Data()
  private var bufferStart: Int64 = 0
  private var status: Stream.Status = .notOpen
  private var failure: Error?
  /// The next chunk, requested while VLC decodes the current one.
  private var readAhead: Fetch?

  init(url: URL, session: URLSession, token: String?, length: Int64) {
    self.url = url
    self.session = session
    self.token = token
    self.length = length
    super.init(data: Data())
  }

  override func open() { status = .open }
  override func close() {
    status = .closed
    readAhead?.task.cancel()
    readAhead = nil
  }
  override var streamStatus: Stream.Status { status }
  override var streamError: Error? { failure }
  override var hasBytesAvailable: Bool { offset < length && failure == nil }
  override var delegate: StreamDelegate? {
    get { nil }
    set {}
  }
  override func schedule(in aRunLoop: RunLoop, forMode mode: RunLoop.Mode) {}
  override func remove(from aRunLoop: RunLoop, forMode mode: RunLoop.Mode) {}

  override func getBuffer(
    _ buffer: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>,
    length len: UnsafeMutablePointer<Int>
  ) -> Bool { false }

  /// Called on VLC's input thread; it waits while the next chunk is fetched.
  override func read(_ destination: UnsafeMutablePointer<UInt8>, maxLength len: Int) -> Int {
    guard failure == nil else { return -1 }
    guard offset < length else {
      status = .atEnd
      return 0
    }
    if offset < bufferStart || offset >= bufferStart + Int64(buffer.count) {
      guard fill() else { return -1 }
    }
    let start = Int(offset - bufferStart)
    let count = min(len, buffer.count - start)
    buffer.copyBytes(to: destination, from: start..<(start + count))
    offset += Int64(count)
    return count
  }

  override func property(forKey key: Stream.PropertyKey) -> Any? {
    key == .fileCurrentOffsetKey ? NSNumber(value: offset) : nil
  }

  /// VLC seeks by setting the current offset, for example to reach the credits.
  override func setProperty(_ property: Any?, forKey key: Stream.PropertyKey) -> Bool {
    guard key == .fileCurrentOffsetKey, let value = (property as? NSNumber)?.int64Value, value >= 0
    else { return false }
    offset = min(value, length)
    return true
  }

  private func fill() -> Bool {
    let fetch: Fetch
    if let readAhead, readAhead.start == offset {
      fetch = readAhead
    } else {
      // A seek leaves the requested chunk behind.
      readAhead?.task.cancel()
      fetch = request(from: offset)
    }
    readAhead = nil
    fetch.done.wait()
    guard let data = fetch.data, !data.isEmpty else {
      failure = fetch.error ?? URLError(.zeroByteResource)
      status = .error
      return false
    }
    buffer = data
    bufferStart = fetch.start
    let next = fetch.start + Int64(data.count)
    if next < length { readAhead = request(from: next) }
    return true
  }

  private func request(from start: Int64) -> Fetch {
    let end = min(start + Int64(Self.chunkSize), length) - 1
    var request = URLRequest(url: url, timeoutInterval: 30)
    request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
    if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    let fetch = Fetch(start: start)
    fetch.task = session.dataTask(with: request) { data, response, error in
      defer { fetch.done.signal() }
      let status = (response as? HTTPURLResponse)?.statusCode ?? 0
      // Only a ranged answer is accepted, so a whole file is never pulled into memory.
      if let data, error == nil, status == 206 {
        fetch.data = data
      } else {
        fetch.error = error ?? URLError(.badServerResponse)
      }
    }
    fetch.task.resume()
    return fetch
  }

  private final class Fetch: @unchecked Sendable {
    let start: Int64
    let done = DispatchSemaphore(value: 0)
    var task: URLSessionDataTask!
    var data: Data?
    var error: Error?

    init(start: Int64) { self.start = start }
  }
}
